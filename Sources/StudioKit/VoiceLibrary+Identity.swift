import Foundation

/// Voice identity: the stable `id`, the `revision` that says one pack is a newer version of another,
/// per-take languages, and importing a pack with that identity intact. The format side is in
/// docs/gvoice-format.md ("id", "revision", `source.<key>.language`).
extension VoiceLibrary {
    /// The base voice an address belongs to: a voice is its own owner, a take's is the voice it lives in.
    private func owner(of address: String) -> String? {
        switch layout.locate(address) {
        case .voice(let slug)?: return slug
        case .variant(let base, _)?: return base
        case nil: return nil
        }
    }

    /// Bump the revision of the voice that owns `address` (minting its `id` first when it predates ids).
    /// Returns the meta of `address` itself, re-read. A take edit counts as an edit of its voice, because
    /// a take is part of the pack the id names.
    @discardableResult
    func touchRevision(_ address: String) throws -> VoiceMeta {
        guard let base = owner(of: address) else { throw StudioError.voiceNotFound(slug: address) }
        var meta = try self.meta(base)
        if meta.id == nil { meta.id = UUID().uuidString }
        meta.revision = (meta.revision ?? 0) + 1
        try write(meta, to: try folder(base))
        return try self.meta(address)
    }

    /// The voice whose `id` is `id`, if any. Takes carry no id of their own.
    public func voice(withID id: String) -> VoiceMeta? {
        list().first { $0.id == id }
    }

    /// Import hook (GVoicePackStore): the language a voice or take speaks. Not an edit of the voice.
    public func setLanguage(_ slug: String, _ language: String) throws {
        var meta = try self.meta(slug)
        meta.language = language
        try write(meta, to: try folder(slug))
    }

    /// Import hook (GVoicePackStore): the imported voice keeps the id and revision it was exported with.
    /// When another voice here already has that id, this one is a COPY and gets a fresh id ("keep both");
    /// `importPack(update:)` is how a newer version replaces the old one instead.
    public func setIdentity(_ slug: String, id: String, revision: Int?) throws {
        var meta = try self.meta(slug)
        let taken = list().contains { $0.id == id && $0.slug != slug }
        meta.id = taken ? UUID().uuidString : id
        meta.revision = revision ?? meta.revision
        try write(meta, to: try folder(slug))
    }

    /// Normalizes a BCP-47 tag into a take key ("es", "en-us"): lowercase, `_` as `-`. Nil when it is not a
    /// plausible tag (letters and digits in 1...8-character subtags), or is the reserved key "base".
    public static func languageKey(_ language: String) -> String? {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard !tag.isEmpty, tag != "base", parts.count <= 4,
              parts.allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return nil }
        return tag
    }

    /// Adds (or replaces) the voice's take for `language`: a take keyed by the normalized tag, addressed
    /// `"<slug>-<key>"`, tagged with its language so a render in that language can pick it. Returns the
    /// take's meta.
    @discardableResult
    public func addLanguageTake(_ slug: String, language: String, refWav: Data,
                                refText: String) throws -> VoiceMeta {
        guard let key = Self.languageKey(language) else {
            throw StudioError.invalidName(language)
        }
        guard layout.locate(slug) == .voice(slug) else { throw StudioError.voiceNotFound(slug: slug) }
        let base = try meta(slug)
        let take = try saveAt(slug: "\(slug)-\(key)", name: "\(base.name) \(key)", refWav: refWav,
                              refText: refText, variantOf: slug)
        try setLanguage(take.slug, language.trimmingCharacters(in: .whitespacesAndNewlines))
        try touchRevision(slug)
        return try meta(take.slug)
    }

    /// The take of `slug` that speaks `language` (primary subtag match: "es-MX" finds an "es" take),
    /// or nil when the voice has none -- the caller then renders from the voice itself.
    public func take(of slug: String, language: String?) -> (meta: VoiceMeta, refURL: URL)? {
        guard let wanted = Self.primaryLanguage(language),
              layout.locate(slug) == .voice(slug) else { return nil }
        if Self.primaryLanguage((try? meta(slug))?.language) == wanted { return nil }
        for key in layout.variantKeys(of: slug) {
            if let found = try? get("\(slug)-\(key)"),
               Self.primaryLanguage(found.meta.language) == wanted { return found }
        }
        return nil
    }

    /// The languages a voice speaks: its own (when stated) plus those of its takes, as written.
    public func languages(of slug: String) -> [String] {
        var found: [String] = []
        if let own = (try? meta(slug))?.language { found.append(own) }
        for key in layout.variantKeys(of: slug) {
            if let language = (try? meta("\(slug)-\(key)"))?.language { found.append(language) }
        }
        return found
    }

    static func primaryLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return nil }
        let primary = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        // Studio's picker speaks language names ("spanish"); takes are tagged with codes ("es").
        return primary.map { languageNames[$0] ?? $0 }
    }

    private static let languageNames = [
        "english": "en", "chinese": "zh", "japanese": "ja", "korean": "ko", "german": "de",
        "french": "fr", "russian": "ru", "portuguese": "pt", "spanish": "es", "italian": "it",
    ]

    /// Imports a `.gvoice` keeping its identity. A pack whose `id` a voice here already has and whose
    /// `revision` is higher is an update: with `update`, the local voice is replaced by it; otherwise
    /// (or for an equal or older revision) it is kept alongside as a copy with a new id.
    @discardableResult
    public func importPack(_ data: Data, update: Bool = false) throws -> VoiceMeta {
        if update, let manifest = try? GVoice.manifest(of: data), let id = manifest.id,
           let existing = voice(withID: id),
           (manifest.revision ?? 0) > (existing.revision ?? 0) {
            // Import first, remove after: a bad pack must not cost the voice it was meant to update.
            // Parked outside the library so it cannot be listed (or collide) while the new one lands.
            let backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("gloam-replace-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: try folder(existing.slug), to: backup)
            do {
                let meta = try GVoice.import(data, into: self)
                try? FileManager.default.removeItem(at: backup)
                return meta
            } catch {
                try? FileManager.default.moveItem(at: backup, to: directory.appendingPathComponent(existing.slug))
                throw error
            }
        }
        let meta = try GVoice.import(data, into: self)
        // Sync can deliver a take's old standalone pack before its voice.
        try? foldLegacyVariants(log: { _ in })
        return meta
    }
}
