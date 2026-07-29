import Foundation
import EngineKit

/// Chat persona attached to a voice. Kept as its own struct so it can later be
/// lifted into a standalone Character entity (spec: personas now, characters later).
public struct Persona: Codable, Equatable, Sendable {
    public var systemPrompt: String
    public var greeting: String?
    public init(systemPrompt: String, greeting: String? = nil) {
        self.systemPrompt = systemPrompt
        self.greeting = greeting
    }
}

/// On-disk shape and key names are identical to the Python engine's
/// voices.py meta.json so .gvoice packs interchange cleanly.
public struct VoiceMeta: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var refText: String
    public var createdAt: String
    public var persona: Persona?

    public init(name: String, slug: String, refText: String, createdAt: String, persona: Persona? = nil) {
        self.name = name
        self.slug = slug
        self.refText = refText
        self.createdAt = createdAt
        self.persona = persona
    }

    // Foreign archives may omit refText/createdAt; tolerate like Python's dict reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        refText = try c.decodeIfPresent(String.self, forKey: .refText) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        // Optional + tolerant: a malformed persona must never break voice load.
        persona = (try? c.decodeIfPresent(Persona.self, forKey: .persona)) ?? nil
    }
}

/// Voice library rooted at an injectable directory (sandbox container in the
/// app, temp dir in tests). Stateless: all state lives on disk.
public struct VoiceLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Save a new voice from reference audio, engine assets, or both.
    ///
    /// `refWav` is optional because a voice is not always a recording: a
    /// Supertonic voice is a pair of baked style tensors, and qwen3-design's
    /// voice is a text description. `engines` maps an engine id to
    /// [filename: bytes] — ids are not validated, since a library that stores an
    /// asset it cannot render is still useful when the pack is bound elsewhere.
    public func save(name: String, refWav: Data?, refText: String,
                     engines: [String: [String: Data]] = [:]) throws -> VoiceMeta {
        let slug = try Slug.slugify(name)
        let voiceDir = directory.appendingPathComponent(slug)
        guard !FileManager.default.fileExists(atPath: voiceDir.path) else {
            throw StudioError.voiceExists(slug: slug)
        }
        guard refWav != nil || !engines.isEmpty else {
            throw StudioError.invalidArchive("voice \(slug) has neither reference audio nor engine assets")
        }
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        if let refWav { try refWav.write(to: voiceDir.appendingPathComponent("ref.wav")) }
        try writeEngines(engines, to: voiceDir)
        let meta = VoiceMeta(name: name, slug: slug, refText: refText,
                             createdAt: Self.timestamp())
        try write(meta, to: voiceDir)
        return meta
    }

    /// Save a voice at a caller-chosen slug, overwriting any existing entry.
    /// Used for variant dirs like `<baseSlug>-excited` where slugify cannot
    /// guarantee the exact suffix format.
    @discardableResult
    public func saveAt(slug: String, name: String, refWav: Data?, refText: String,
                       engines: [String: [String: Data]] = [:]) throws -> VoiceMeta {
        let voiceDir = directory.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        if let refWav { try refWav.write(to: voiceDir.appendingPathComponent("ref.wav")) }
        try writeEngines(engines, to: voiceDir)
        let meta = VoiceMeta(name: name, slug: slug, refText: refText,
                             createdAt: Self.timestamp())
        try write(meta, to: voiceDir)
        return meta
    }

    /// Full accessor: reference audio and engine assets are both optional.
    ///
    /// `get()` still requires ref.wav and is the right call for the synthesis
    /// paths that cannot work without it. Use this one when absence is a valid
    /// answer — packing, listing what a voice can render.
    public func entry(_ slug: String) throws
        -> (meta: VoiceMeta, refURL: URL?, engines: [String: [String: URL]])
    {
        let voiceDir = directory.appendingPathComponent(slug)
        let metaURL = voiceDir.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data)
        else { throw StudioError.voiceNotFound(slug: slug) }
        let refURL = voiceDir.appendingPathComponent("ref.wav")
        let ref = FileManager.default.fileExists(atPath: refURL.path) ? refURL : nil
        var engines: [String: [String: URL]] = [:]
        let root = voiceDir.appendingPathComponent("engines")
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for engineDir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: engineDir, includingPropertiesForKeys: nil)) ?? []
            guard !files.isEmpty else { continue }
            engines[engineDir.lastPathComponent] = Dictionary(
                files.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return (meta, ref, engines)
    }

    /// Variant key -> library slug for `slug` and its "<slug>-<x>" siblings.
    ///
    /// Emotion variants live as sibling voices but belong to ONE identity, so a
    /// pack must carry them together — export the base alone and the receiving
    /// end silently loses the voice's emotional range.
    public func variantSlugs(of slug: String) -> [String: String] {
        var found = ["base": slug]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name.hasPrefix("\(slug)-"),
                  FileManager.default.fileExists(
                    atPath: child.appendingPathComponent("meta.json").path)
            else { continue }
            found[String(name.dropFirst(slug.count + 1))] = name
        }
        return found
    }

    private func writeEngines(_ engines: [String: [String: Data]], to voiceDir: URL) throws {
        for (engine, files) in engines {
            let engineDir = voiceDir.appendingPathComponent("engines")
                .appendingPathComponent(try GVoice.safeComponent(engine))
            try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
            for (filename, blob) in files {
                try blob.write(to: engineDir.appendingPathComponent(try GVoice.safeComponent(filename)))
            }
        }
    }

    public func get(_ slug: String) throws -> (meta: VoiceMeta, refURL: URL) {
        let voiceDir = directory.appendingPathComponent(slug)
        let metaURL = voiceDir.appendingPathComponent("meta.json")
        let refURL = voiceDir.appendingPathComponent("ref.wav")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              FileManager.default.fileExists(atPath: refURL.path),
              let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data)
        else { throw StudioError.voiceNotFound(slug: slug) }
        return (meta, refURL)
    }

    public func list() -> [VoiceMeta] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var metas: [VoiceMeta] = []
        for child in children {
            let metaURL = child.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data)
            else { continue }
            metas.append(meta)
        }
        return metas.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func delete(_ slug: String) throws {
        let voiceDir = directory.appendingPathComponent(slug)
        guard FileManager.default.fileExists(atPath: voiceDir.path) else {
            throw StudioError.voiceNotFound(slug: slug)
        }
        try FileManager.default.removeItem(at: voiceDir)
    }

    /// Emotion suffixes tried in order when resolving a "<slug>-<emotion>"
    /// variant. Cloned reference audio dominates prosody, so an acted clip
    /// per emotion is what actually moves delivery; hype and excited are
    /// near-aliases of each other. Parity with voices._EMOTION_ALIASES.
    private static let emotionAliases: [Emotion: [String]] = [
        .hype: ["hype", "excited"],
        .excited: ["excited", "hype"],
    ]

    /// get(), preferring a "<slug>-<emotion>" variant when one exists.
    /// neutral (and nil) always resolve to the base voice; a missing variant
    /// falls back to base. Throws only if the BASE slug is unknown.
    public func resolve(_ slug: String, emotion: Emotion?) throws
        -> (meta: VoiceMeta, refURL: URL)
    {
        if let emotion, emotion != .neutral {
            for suffix in Self.emotionAliases[emotion] ?? [emotion.rawValue] {
                if let found = try? get("\(slug)-\(suffix)") { return found }
            }
        }
        return try get(slug)
    }

    /// Edit a stored voice in place. Renaming re-slugs (the directory moves);
    /// acted `<slug>-<suffix>` variants move with it for the suffixes the
    /// caller names (the library can't guess which hyphenated siblings are
    /// variants vs. independent voices — "dj-nova" must survive a rename of
    /// "dj"). Callers that re-slug must also migrate their own references
    /// (chat conversations, selection) to the returned meta's slug.
    public func update(_ slug: String, name: String? = nil,
                       refText: String? = nil, refWav: Data? = nil,
                       variantSuffixes: Set<String> = []) throws -> VoiceMeta {
        var (meta, _) = try get(slug)
        var voiceDir = directory.appendingPathComponent(slug)
        if let name, name != meta.name {
            let newSlug = try Slug.slugify(name)
            if newSlug != slug {
                let target = directory.appendingPathComponent(newSlug)
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw StudioError.voiceExists(slug: newSlug)
                }
                try FileManager.default.moveItem(at: voiceDir, to: target)
                voiceDir = target
                for suffix in variantSuffixes {
                    let oldDir = directory.appendingPathComponent("\(slug)-\(suffix)")
                    let newDir = directory.appendingPathComponent("\(newSlug)-\(suffix)")
                    guard FileManager.default.fileExists(atPath: oldDir.path),
                          !FileManager.default.fileExists(atPath: newDir.path),
                          var variantMeta = (try? get("\(slug)-\(suffix)"))?.meta
                    else { continue }
                    try FileManager.default.moveItem(at: oldDir, to: newDir)
                    variantMeta.slug = "\(newSlug)-\(suffix)"
                    try write(variantMeta, to: newDir)
                }
            }
            meta.name = name
            meta.slug = newSlug
        }
        if let refText { meta.refText = refText }
        if let refWav, !refWav.isEmpty {
            try refWav.write(to: voiceDir.appendingPathComponent("ref.wav"))
        }
        try write(meta, to: voiceDir)
        return meta
    }

    /// Sets (or clears, with nil) the chat persona on a stored voice.
    @discardableResult
    public func setPersona(_ slug: String, persona: Persona?) throws -> VoiceMeta {
        var (meta, _) = try get(slug)
        meta.persona = persona
        try write(meta, to: directory.appendingPathComponent(slug))
        return meta
    }

    public func avatarURL(_ slug: String) -> URL? {
        let url = directory.appendingPathComponent(slug).appendingPathComponent("avatar.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func saveAvatar(_ slug: String, pngData: Data) throws {
        let voiceDir = directory.appendingPathComponent(slug)
        guard FileManager.default.fileExists(atPath: voiceDir.path) else {
            throw StudioError.voiceNotFound(slug: slug)
        }
        try pngData.write(to: voiceDir.appendingPathComponent("avatar.png"))
    }

    public func removeAvatar(_ slug: String) throws {
        let url = directory.appendingPathComponent(slug).appendingPathComponent("avatar.png")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func write(_ meta: VoiceMeta, to voiceDir: URL) throws {
        try JSONEncoder().encode(meta).write(to: voiceDir.appendingPathComponent("meta.json"))
    }

    /// "%Y-%m-%dT%H:%M:%SZ" in UTC — Python strftime/gmtime parity.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
