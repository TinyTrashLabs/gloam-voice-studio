import Foundation

/// Every take a voice carries, laid out the way the editor shows them: one row per language the voice
/// speaks (its home language first), one column per style (Natural, Gloam's five, then any other style a
/// take has). Built from the takes' fields, never from parsing keys, except for packs written before
/// `style` existed (docs/gvoice-format.md, "Choosing a take: language × style").
public struct VoiceTakeGrid: Equatable, Sendable {
    /// Where a take came from, when this app recorded it (`VoiceLibrary.takeOrigin`). Takes an import
    /// brought say nothing: an import copies the pack-wide provenance onto every take, which describes
    /// the pack, not the take.
    public enum Origin: String, Equatable, Sendable {
        case generated, recorded, imported
    }

    /// One take: the voice's default (`base`) or one of its variants.
    public struct Take: Equatable, Sendable {
        /// The variant key ("es-excited"), or "base" for the default take.
        public let key: String
        /// The take's library address ("benson-es-excited"; the voice's own slug for "base").
        public let slug: String
        /// The row it sits in.
        public let row: Row
        /// The column it sits in.
        public let column: Column
        public let refText: String
        public let origin: Origin?
        /// Generator that made it, when `origin` is `.generated` and recorded it ("fish-s2-pro").
        public let engine: String?
        /// The style was read off the key (an older pack with no `style` field).
        public let styleFromLegacyKey: Bool
        /// The voice's own default take, which can't be deleted from here.
        public var isDefault: Bool { key == "base" }
    }

    /// A language the voice speaks.
    public struct Row: Hashable, Sendable {
        /// Normalized BCP-47 tag ("es", "en-us"); nil when the home language is unstated.
        public let language: String?
        public let isHome: Bool
    }

    /// A delivery.
    public struct Column: Hashable, Sendable {
        /// Nil for the voice's natural delivery.
        public let name: String?
        /// Whose names these are: "gloam" for Gloam's five, a declared vocabulary, or nil for a take
        /// named only by its key (an untagged generated expression such as "sad").
        public let vocabulary: String?

        public static let natural = Column(name: nil, vocabulary: nil)
        public static func gloam(_ name: String) -> Column { Column(name: name, vocabulary: "gloam") }

        public var isNatural: Bool { name == nil }
        /// One of Gloam's five styles.
        public var isGloam: Bool { vocabulary == "gloam" && name.map(VoiceTakeGrid.gloamOrder.contains) == true }
        public var title: String { name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Natural" }
    }

    /// Gloam's five, in the order the editor shows them (calm → energetic).
    public static let gloamOrder = ["flat", "neutral", "warm", "excited", "hype"]

    /// The voice's home language, normalized; nil when unstated.
    public let home: String?
    public let rows: [Row]
    public let columns: [Column]
    public let takes: [Take]

    /// The takes in one cell, the default take first. More than one only when a pack carries two takes
    /// with the same language and style; the editor shows them all rather than hide one.
    public func takes(_ row: Row, _ column: Column) -> [Take] {
        takes.filter { $0.row == row && $0.column == column }
    }

    /// Lays out `base` (the voice itself) and its variants (`key`, meta).
    public init(base: VoiceMeta, variants: [(key: String, meta: VoiceMeta)]) {
        let home = base.language.map(Self.normalize)
        let homeRow = Row(language: home, isHome: true)
        self.home = home

        func row(for language: String?) -> Row {
            guard let language else { return homeRow }
            let tag = Self.normalize(language)
            return tag == home ? homeRow : Row(language: tag, isHome: false)
        }
        func column(key: String, meta: VoiceMeta) -> (Column, legacy: Bool) {
            if let style = meta.style { return (Column(name: style.name, vocabulary: style.vocabulary ?? "gloam"), false) }
            if let legacy = VoiceStyle.fromLegacyKey(key) { return (.gloam(legacy.name), true) }
            // A take tagged with a language and no style is that language's natural take. An untagged one
            // with an unknown key is an older acted expression ("sad"), named by its key.
            if meta.language != nil { return (.natural, false) }
            return (Column(name: key, vocabulary: nil), false)
        }

        var built = [Self.take(key: "base", meta: base, row: homeRow, column: .natural, legacy: false)]
        for (key, meta) in variants where key != "base" {
            let (col, legacy) = column(key: key, meta: meta)
            built.append(Self.take(key: key, meta: meta, row: row(for: meta.language), column: col, legacy: legacy))
        }
        takes = built

        var others = Set(built.map(\.row)).subtracting([homeRow]).sorted { ($0.language ?? "") < ($1.language ?? "") }
        others.insert(homeRow, at: 0)
        rows = others

        let extra = Set(built.map(\.column)).filter { !$0.isNatural && !$0.isGloam }
            .sorted { ($0.vocabulary ?? "", $0.name ?? "") < ($1.vocabulary ?? "", $1.name ?? "") }
        columns = [.natural] + Self.gloamOrder.map(Column.gloam) + extra
    }

    private static func take(key: String, meta: VoiceMeta, row: Row, column: Column, legacy: Bool) -> Take {
        let origin = VoiceLibrary.takeOrigin(of: meta)
        return Take(key: key, slug: meta.slug, row: row, column: column, refText: meta.refText,
                    origin: origin.flatMap { Origin(rawValue: $0.origin) }, engine: origin?.engine,
                    styleFromLegacyKey: legacy)
    }

    static func normalize(_ language: String) -> String {
        VoiceLibrary.languageKey(language)
            ?? language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension VoiceLibrary {
    /// The grid of everything `slug` carries, or nil when it isn't a voice (a take address, or unknown).
    public func takeGrid(of slug: String) -> VoiceTakeGrid? {
        guard layout.locate(slug) == .voice(slug), let base = try? meta(slug) else { return nil }
        let variants = layout.variantKeys(of: slug).compactMap { key -> (key: String, meta: VoiceMeta)? in
            (try? meta("\(slug)-\(key)")).map { (key, $0) }
        }
        return VoiceTakeGrid(base: base, variants: variants)
    }

    /// The `provenance` this app writes on a take it saved itself: how it was made and, for a generated
    /// one, by which engine. Kept under its own key so it can't be confused with a pack's provenance.
    public static func takeProvenance(origin: String, engine: String? = nil) -> JSONValue {
        var mark: [String: JSONValue] = ["origin": .string(origin)]
        if let engine { mark["engine"] = .string(engine) }
        return .object(["take": .object(mark)])
    }

    /// Reads back `takeProvenance`; nil when the take doesn't carry it.
    public static func takeOrigin(of meta: VoiceMeta) -> (origin: String, engine: String?)? {
        guard case .object(let provenance)? = meta.provenance,
              case .object(let mark)? = provenance["take"],
              case .string(let origin)? = mark["origin"] else { return nil }
        if case .string(let engine)? = mark["engine"] { return (origin, engine) }
        return (origin, nil)
    }
}
