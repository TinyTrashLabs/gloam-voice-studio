import Combine
import Foundation
import GloamVoiceEditing
import GVoiceKit

/// The Studio library (`VoiceLibrary`) as a `VoiceLibraryStore`, so a screen
/// built on GloamVoiceEditing (or GloamVoiceUI's reference editor) edits the
/// Mac's voices with the same rules every app uses.
///
/// Languages are first-class here: a language reference is the voice's take
/// tagged with its language (`VoiceLibrary.addLanguageTake`), listed under
/// `languageReferences(of:)` and never among the emotion versions
/// (`Voice.variantKeys` holds only the untagged takes).
@MainActor
public final class StudioVoiceEditorStore: ObservableObject, VoiceLibraryStore {
    public let library: VoiceLibrary
    @Published public private(set) var voices: [Voice] = []

    public init(library: VoiceLibrary) {
        self.library = library
        reload()
    }

    public var features: VoiceLibraryFeatures {
        [.notes, .avatars, .gain, .packShare, .renditions, .provenance, .languages]
    }

    /// Re-reads the library; call after anything outside this store changed it.
    public func reload() {
        voices = library.list().map(voice(for:))
    }

    private func voice(for meta: VoiceMeta) -> Voice {
        let entry = try? library.entry(meta.slug)
        let avatar = library.avatarURL(meta.slug)
        let modified = avatar.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return Voice(slug: meta.slug, meta: meta, hasMaster: entry?.refURL != nil,
                     hasWindow: entry?.engines["lux-tts"]?["voice.json"] != nil,
                     variantKeys: emotionKeys(of: meta.slug), isStarter: false,
                     avatarURL: avatar, avatarModified: modified)
    }

    /// The take keys that are acted versions: every take not tagged with a language.
    private func emotionKeys(of slug: String) -> [String] {
        library.layout.variantKeys(of: slug).filter { (try? library.meta("\(slug)-\($0)"))?.language == nil }
    }

    // MARK: required

    public func referenceText(of slug: String) -> String? {
        guard let entry = try? library.entry(slug) else { return nil }
        if let window = entry.engines["lux-tts"]?["voice.json"].flatMap({ try? Data(contentsOf: $0) })
            .flatMap({ try? JSONDecoder().decode(ReferenceWindowRendition.self, from: $0) }),
           !window.text.isEmpty { return window.text }
        return entry.refURL == nil ? nil : entry.meta.refText
    }

    public func masterURL(of slug: String) -> URL? { (try? library.entry(slug))?.refURL }

    public func referenceURL(of slug: String) -> URL? {
        guard let entry = try? library.entry(slug) else { return nil }
        return entry.engines["lux-tts"]?["ref.wav"] ?? entry.refURL
    }

    public func update(_ slug: String, _ mutate: (inout VoiceMeta) -> Void) throws {
        let before = try library.meta(slug)
        var after = before
        mutate(&after)
        _ = try library.update(slug, name: after.name != before.name ? after.name : nil,
                               notes: after.notes != before.notes ? (after.notes ?? "") : nil)
        reload()
    }

    public func languages(of slug: String) -> [String] {
        let found = library.languages(of: slug)
        return found.isEmpty ? ["en"] : found
    }

    public func updateTranscript(of voice: Voice, _ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw VoiceStoreError.emptyTranscript }
        _ = try library.update(voice.slug, refText: t)
        reload()
    }

    // MARK: optional

    public func delete(_ voice: Voice) {
        try? library.delete(voice.slug)
        reload()
    }

    public func engineFiles(of slug: String) -> [String: [String: URL]] {
        (try? library.entry(slug))?.engines ?? [:]
    }

    public func setGain(of voice: Voice, _ db: Double) throws {
        _ = try library.setGain(voice.slug, gainDb: db)
        reload()
    }

    public func setAvatar(_ slug: String, imageData: Data) throws {
        try library.saveAvatar(slug, pngData: imageData)
        reload()
    }

    public func removeAvatar(_ slug: String) throws {
        try library.removeAvatar(slug)
        reload()
    }

    // MARK: languages

    public func languageReferences(of slug: String) -> [LanguageReference] {
        let own = (try? library.meta(slug))?.language
        return library.layout.variantKeys(of: slug).compactMap { key -> LanguageReference? in
            guard let (meta, url) = try? library.get("\(slug)-\(key)"), let language = meta.language,
                  language != own else { return nil }
            return LanguageReference(language: language, text: meta.refText, url: url)
        }
        .sorted { $0.language < $1.language }
    }

    public func addLanguageReference(_ slug: String, language: String, wav: Data, transcript: String) throws {
        try library.addLanguageTake(slug, language: language, refWav: wav, refText: transcript)
        reload()
    }

    public func removeLanguageReference(_ slug: String, language: String) throws {
        guard let key = VoiceLibrary.languageKey(language) else { throw StudioError.invalidName(language) }
        let take = "\(slug)-\(key)"
        guard library.locate(take) == .variant(base: slug, key: key) else { return }
        try library.delete(take)
        try library.touchRevision(slug)
        reload()
    }

    // MARK: sharing

    public func packExport(for voice: Voice, includeSource: Bool) -> (@Sendable () throws -> Data)? {
        let library = library, slug = voice.slug
        return { try GVoice.export(slug, from: library, includeSource: includeSource) }
    }
}
