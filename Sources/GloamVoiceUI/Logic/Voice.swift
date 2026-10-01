import Foundation
import GVoiceKit

/// One voice as the UI sees it: the pack's metadata plus what the directory
/// holds. A value — derived from disk by the host app's store, never mutated
/// in place.
public struct Voice: Identifiable, Hashable {
    public let slug: String
    public var meta: VoiceMeta
    public let hasMaster: Bool
    public let hasWindow: Bool
    /// Emotion variant keys ("hype", "calm"), empty for a plain voice.
    public let variantKeys: [String]
    /// One of the bundled starter packs (the slug matches a bundled `.gvoice`).
    /// A host with read-only resident voices sets this for them too; whether
    /// such a voice can be deleted is `VoiceLibraryStore.canDelete`.
    public let isStarter: Bool
    /// The pack's `avatar.png`, nil when the voice has none.
    public let avatarURL: URL?
    /// When that file was last written. Part of equality so a replaced
    /// picture at the same path still reads as a changed voice.
    public let avatarModified: Date?

    public init(slug: String, meta: VoiceMeta, hasMaster: Bool, hasWindow: Bool, variantKeys: [String],
                isStarter: Bool, avatarURL: URL?, avatarModified: Date?) {
        self.slug = slug
        self.meta = meta
        self.hasMaster = hasMaster
        self.hasWindow = hasWindow
        self.variantKeys = variantKeys
        self.isStarter = isStarter
        self.avatarURL = avatarURL
        self.avatarModified = avatarModified
    }

    public var id: String { slug }
    public var name: String { meta.name }
    public var refText: String { meta.refText }
    public var tag: String { Self.tag(for: meta.name) }
    /// Notes if there are any; else what tells two clones apart — the day
    /// each was made — since names alone ("Jeff two") did not.
    public var blurb: String {
        if let notes = meta.notes, !notes.trimmingCharacters(in: .whitespaces).isEmpty { return notes }
        if isStarter { return "Included voice" }
        if let day = Self.day(from: meta.createdAt) { return "Cloned on this phone · \(day)" }
        return "Cloned on this phone"
    }

    /// "Sep 8" from the pack's RFC 3339 `createdAt`; nil when it is not a date.
    public static func day(from iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? { parser.formatOptions = [.withInternetDateTime]; return parser.date(from: iso) }()
        guard let date else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Two-letter monogram: initials of the first two words, else the first
    /// two letters. Same rule `ClonedVoice.tag` used, kept so avatars look
    /// the same after the migration.
    public static func tag(for name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return (letters.count >= 2 ? letters : String(name.prefix(2))).uppercased()
    }
}

extension Voice {
    public static func == (lhs: Voice, rhs: Voice) -> Bool {
        lhs.slug == rhs.slug && lhs.meta == rhs.meta && lhs.hasMaster == rhs.hasMaster
            && lhs.hasWindow == rhs.hasWindow && lhs.variantKeys == rhs.variantKeys
            && lhs.isStarter == rhs.isStarter
            && lhs.avatarURL == rhs.avatarURL && lhs.avatarModified == rhs.avatarModified
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(slug) }
}
