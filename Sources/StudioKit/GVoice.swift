import Foundation
import ZIPFoundation

/// The one-file voice pack: one identity, its source audio, and per-engine
/// renditions derived from it.
///
/// `docs/gvoice-format.md` in this repo is the source of truth for the format;
/// the Python engine (`voices.py`) conforms to the same document.
public enum GVoice {
    /// Only version this build reads or writes.
    public static let version = 1

    // MARK: manifest

    public struct Manifest: Codable, Equatable, Sendable {
        public struct Source: Codable, Equatable, Sendable {
            public var audio: String?
            public var text: String?
            public init(audio: String?, text: String?) { self.audio = audio; self.text = text }
        }
        public var gvoice: Int
        public var name: String
        public var slug: String?
        public var createdAt: String?
        public var variants: [String]?
        /// variant key -> source audio + its transcript
        public var source: [String: Source]?
        /// engine id -> variant key -> pack-relative member path
        public var engines: [String: [String: String]]?
    }

    // MARK: export

    /// Pack a voice and its emotion variants.
    ///
    /// `includeSource: false` ships only the derived per-engine renditions.
    /// Source audio is the one asset portable across engines, so withholding it
    /// means the recipient gets a voice on the engines you baked for and cannot
    /// re-clone it anywhere else — the right default for packs leaving your own
    /// machines, and the wrong one for your own library.
    public static func export(_ slug: String, from library: VoiceLibrary,
                              includeSource: Bool = true) throws -> Data {
        let variants = library.variantSlugs(of: slug)
        let base = try library.entry(variants["base"] ?? slug)  // throws voiceNotFound

        var manifest = Manifest(
            gvoice: version, name: base.meta.name,
            slug: base.meta.slug.isEmpty ? slug : base.meta.slug,
            createdAt: base.meta.createdAt.isEmpty ? nil : base.meta.createdAt,
            variants: orderedKeys(variants.keys),
            source: [:], engines: [:])
        var entries: [(name: String, data: Data)] = []

        for key in manifest.variants ?? [] {
            guard let vslug = variants[key] else { continue }
            let entry = key == "base" ? base : try library.entry(vslug)
            let suffix = key == "base" ? "" : "-\(key)"
            if includeSource, let refURL = entry.refURL {
                let member = "source/ref\(suffix).wav"
                entries.append((member, try Data(contentsOf: refURL)))
                manifest.source?[key] = Manifest.Source(audio: member, text: entry.meta.refText)
            }
            for (engine, files) in entry.engines {
                for (filename, url) in files {
                    let member = "engines/\(engine)/\(stem(filename, suffix: suffix))"
                    entries.append((member, try Data(contentsOf: url)))
                    manifest.engines?[engine, default: [:]][key] = member
                }
            }
        }

        guard !entries.isEmpty else {
            throw StudioError.invalidArchive("voice \(slug) has nothing to export")
        }
        return try makeArchive(entries: [("manifest.json", try JSONEncoder().encode(manifest))] + entries)
    }

    /// "base" first, then the rest alphabetically. Written out rather than
    /// expressed as a sort predicate: a comparator that is not a strict weak
    /// ordering can trap inside Swift's sort.
    private static func orderedKeys(_ keys: some Collection<String>) -> [String] {
        ["base"] + keys.filter { $0 != "base" }.sorted()
    }

    /// "style.json" + "-hype" -> "style-hype.json"
    private static func stem(_ filename: String, suffix: String) -> String {
        guard !suffix.isEmpty else { return filename }
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return filename + suffix }
        return (filename as NSString).deletingPathExtension + suffix + "." + ext
    }

    // MARK: import

    /// Install a pack, returning the BASE voice's meta.
    ///
    /// Assets whose engine id this build does not recognise are stored anyway —
    /// ignoring an unknown engine must never fail an import, or one pack cannot
    /// serve clients that shipped at different times.
    public static func `import`(_ data: Data, into library: VoiceLibrary) throws -> VoiceMeta {
        let archive: Archive
        let manifest: Manifest
        do {
            archive = try Archive(data: data, accessMode: .read)
            guard let entry = archive["manifest.json"] else {
                throw StudioError.invalidArchive("not a .gvoice pack (no manifest.json)")
            }
            manifest = try JSONDecoder().decode(Manifest.self, from: try extract(entry, from: archive))
        } catch let error as StudioError {
            throw error
        } catch {
            throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)")
        }

        guard manifest.gvoice == version else {
            throw StudioError.invalidArchive(
                "unsupported .gvoice version \(manifest.gvoice) (this build reads \(version))")
        }
        guard !manifest.name.isEmpty else {
            throw StudioError.invalidArchive("archive manifest.json has no voice name")
        }

        func read(_ member: String) throws -> Data {
            guard let entry = archive[member] else {
                throw StudioError.invalidArchive("manifest points at \(member), which is not in the pack")
            }
            return try extract(entry, from: archive)
        }

        let sources = manifest.source ?? [:]
        let engines = manifest.engines ?? [:]
        let keys = manifest.variants
            ?? orderedKeys(Set(["base"] + Array(sources.keys) + engines.values.flatMap { Array($0.keys) }))

        var baseMeta: VoiceMeta?
        for key in keys {
            let source = sources[key]
            let ref = try source?.audio.map(read)
            var assets: [String: [String: Data]] = [:]
            for (engine, perVariant) in engines {
                // Audio-driven engines point back into source/, already read above.
                guard let member = perVariant[key], !member.hasPrefix("source/") else { continue }
                let engineID = try safeComponent(engine)
                let filename = try safeComponent((member as NSString).lastPathComponent)
                var bucket = assets[engineID] ?? [:]
                bucket[filename] = try read(member)
                assets[engineID] = bucket
            }
            guard ref != nil || !assets.isEmpty else { continue }
            if key == "base" {
                baseMeta = try library.save(name: manifest.name, refWav: ref,
                                            refText: source?.text ?? "", engines: assets)
            } else {
                let baseSlug = baseMeta?.slug ?? (try Slug.slugify(manifest.name))
                try library.saveAt(slug: "\(baseSlug)-\(key)", name: "\(manifest.name) \(key)",
                                   refWav: ref, refText: source?.text ?? "", engines: assets)
            }
        }

        guard let baseMeta else {
            throw StudioError.invalidArchive("archive has no base variant to install")
        }
        return baseMeta
    }

    // MARK: helpers

    /// Reject a path component that could escape the voice directory. Member
    /// paths inside a pack are attacker-controlled — the manifest is just JSON
    /// in a zip someone sent us.
    static func safeComponent(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\")
        else { throw StudioError.invalidArchive("unsafe path component: \(name)") }
        return name
    }

    static func makeArchive(entries: [(name: String, data: Data)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (name, data) in entries {
            let bytes = data
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(bytes.count),
                compressionMethod: .deflate
            ) { position, size -> Data in
                let start = Int(position)
                let end = min(start + size, bytes.count)
                return bytes.subdata(in: start..<end)
            }
        }
        guard let out = archive.data else {
            throw StudioError.invalidArchive("zip create failed")
        }
        return out
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }
}
