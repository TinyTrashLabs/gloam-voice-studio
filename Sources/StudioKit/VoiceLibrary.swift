import Foundation

/// On-disk shape and key names are identical to the Python engine's
/// voices.py meta.json so .gvoice packs interchange cleanly.
public struct VoiceMeta: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var refText: String
    public var createdAt: String

    public init(name: String, slug: String, refText: String, createdAt: String) {
        self.name = name
        self.slug = slug
        self.refText = refText
        self.createdAt = createdAt
    }

    // Foreign archives may omit refText/createdAt; tolerate like Python's dict reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        refText = try c.decodeIfPresent(String.self, forKey: .refText) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// Voice library rooted at an injectable directory (sandbox container in the
/// app, temp dir in tests). Stateless: all state lives on disk.
public struct VoiceLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(name: String, refWav: Data, refText: String) throws -> VoiceMeta {
        let slug = try Slug.slugify(name)
        let voiceDir = directory.appendingPathComponent(slug)
        guard !FileManager.default.fileExists(atPath: voiceDir.path) else {
            throw StudioError.voiceExists(slug: slug)
        }
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        try refWav.write(to: voiceDir.appendingPathComponent("ref.wav"))
        let meta = VoiceMeta(name: name, slug: slug, refText: refText,
                             createdAt: Self.timestamp())
        try write(meta, to: voiceDir)
        return meta
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
