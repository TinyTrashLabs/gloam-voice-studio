import Foundation
import ZIPFoundation

/// The one-file voice pack: one identity, its source audio, and per-engine
/// renditions derived from it.
///
/// `docs/gvoice-format.md` in this repo is the source of truth for the format;
/// the Python engine (`voices.py`) conforms to the same document.
public enum GVoice {
    /// Only version this build reads or writes.
    ///
    /// 2 restructured `engines`: a variant now maps to a LIST of member paths
    /// instead of a single one. Under v1 an engine whose rendition needed more
    /// than one file (audio + its transcript, say) wrote every file into the
    /// zip but could name only the last in the manifest, so import silently
    /// dropped the rest. That is a reinterpretation of an existing field, not
    /// an additive change, so it takes a version bump.
    public static let version = 2

    /// Delivery pace for one engine: its own override, else the voice-level
    /// pace, else 1.0. A non-positive value is treated as absent — it would
    /// divide a predicted duration to infinity or flip it negative.
    public static func pace(for engineId: String, in manifest: Manifest) -> Double {
        if let p = manifest.enginePace?[engineId], p > 0 { return p }
        if let p = manifest.pace, p > 0 { return p }
        return 1.0
    }

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
        /// Delivery pace for this voice, 1.0 = the reference's own pace.
        ///
        /// Belongs to the VOICE, not to the listener or the app: a slow,
        /// deliberate reference needs ~1.7 to sound like radio while a brisk
        /// one is already right at 1.0, so no single global setting serves
        /// both. Absent means 1.0.
        public var pace: Double?
        /// engine id -> delivery pace, overriding `pace` for that engine alone.
        ///
        /// Exists because engines do not implement speed the same way. On
        /// `lux-tts` it is native and graph-level, and on `supertonic` it feeds
        /// the duration predictor — both clean. Every other backend gets a
        /// generic time-domain stretch, which is audibly wrong on a voice, so a
        /// pack must be able to say "1.08 here, 1.0 there".
        ///
        /// A reader that ignores this falls back to `pace`, which the format
        /// already calls a valid reading — hence NO `gvoice` bump.
        public var enginePace: [String: Double]?
        /// variant key -> source audio + its transcript
        public var source: [String: Source]?
        /// engine id -> variant key -> pack-relative member paths. A list
        /// because one rendition can be several files; single-file engines
        /// carry a one-element list.
        public var engines: [String: [String: [String]]]?
        /// Free-form, producer-defined record of how the renditions were made.
        /// Opaque to this reader — carried through import/export unchanged.
        public var provenance: JSONValue?
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
            pace: base.meta.pace, enginePace: base.meta.enginePace,
            source: [:], engines: [:], provenance: base.meta.provenance)
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
                    manifest.engines?[engine, default: [:]][key, default: []].append(member)
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

    /// Hard ceilings on an untrusted pack, checked before any bytes are
    /// extracted. Member paths and sizes in a `.gvoice` are attacker-controlled
    /// (a zip someone sent us); without limits a crafted archive could exhaust
    /// memory extracting a single oversized or zip-bomb-style member.
    static let maxEntries = 1000
    static let maxEntryBytes: UInt64 = 200_000_000  // 200 MB — comfortably above any real voice asset

    /// Install a pack, returning the BASE voice's meta.
    ///
    /// Assets whose engine id this build does not recognise are stored anyway —
    /// ignoring an unknown engine must never fail an import, or one pack cannot
    /// serve clients that shipped at different times. Per Rule 1/2, a manifest
    /// entry pointing at a member that isn't actually in the pack degrades to
    /// "skip that one asset," not a hard failure — a single corrupt or missing
    /// entry must not sink an otherwise-importable pack.
    ///
    /// The base variant is fully resolved and written FIRST, before any other
    /// variant touches disk: if the pack has nothing installable as a base,
    /// the whole import throws before creating any partial/orphaned variant
    /// directories, regardless of what order `manifest.variants` lists keys in
    /// (that ordering is attacker-controlled and must not be trusted to put
    /// "base" first).
    public static func `import`(_ data: Data, into library: VoiceLibrary) throws -> VoiceMeta {
        let archive: Archive
        let manifest: Manifest
        do {
            archive = try Archive(data: data, accessMode: .read)
            guard archive.reduce(0, { count, _ in count + 1 }) <= maxEntries else {
                throw StudioError.invalidArchive("pack has too many entries")
            }
            guard let entry = archive["manifest.json"] else {
                throw StudioError.invalidArchive("not a .gvoice pack (no manifest.json)")
            }
            manifest = try JSONDecoder().decode(Manifest.self, from: try extract(entry, from: archive))
        } catch let error as StudioError {
            throw error
        } catch {
            throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)")
        }

        // Readers reject only versions newer than they understand (Rule:
        // additive changes never bump `gvoice`), with one floor: version 1
        // predates the `engines` restructure, so its manifests do not decode
        // here at all. No v1 pack was ever distributed — say so plainly rather
        // than surfacing a decode error, and carry no compatibility path for a
        // version that never shipped.
        guard manifest.gvoice >= 2 else {
            throw StudioError.invalidArchive(
                "this pack is .gvoice version \(manifest.gvoice); version 1 predates the engines "
                + "restructure and cannot be read — rebuild it")
        }
        guard manifest.gvoice <= version else {
            throw StudioError.invalidArchive(
                "unsupported .gvoice version \(manifest.gvoice) (this build reads up to \(version))")
        }
        guard !manifest.name.isEmpty else {
            throw StudioError.invalidArchive("archive manifest.json has no voice name")
        }

        /// nil (not throw) for a member that is missing, unsafe to normalize,
        /// or oversized — callers treat that as "skip this one asset."
        func readOptional(_ member: String) -> Data? {
            let normalized = normalizeMember(member)
            guard let entry = archive[normalized] else { return nil }
            guard entry.uncompressedSize <= maxEntryBytes else { return nil }
            return try? extract(entry, from: archive)
        }

        let sources = manifest.source ?? [:]
        let engines = manifest.engines ?? [:]
        let keys = manifest.variants
            ?? orderedKeys(Set(["base"] + Array(sources.keys) + engines.values.flatMap { Array($0.keys) }))

        /// Resolve one variant's assets. Engine ids and filenames are validated
        /// hard (an unsafe one aborts the whole import, matching
        /// `testImportRejectsPathTraversal`); a dangling *member reference* for
        /// an otherwise-safe path just drops that one asset.
        func resolveVariant(_ key: String) throws -> (ref: Data?, assets: [String: [String: Data]]) {
            let ref = sources[key]?.audio.flatMap(readOptional)
            var assets: [String: [String: Data]] = [:]
            for (engine, perVariant) in engines {
                guard let members = perVariant[key] else { continue }
                let engineID = try safeComponent(engine)
                for member in members {
                    // Audio-driven engines may point back into source/, which
                    // is already read above as the reference.
                    guard !normalizeMember(member).lowercased().hasPrefix("source/") else { continue }
                    let filename = try safeComponent((member as NSString).lastPathComponent)
                    guard let blob = readOptional(member) else { continue }
                    assets[engineID, default: [:]][filename] = blob
                }
            }
            return (ref, assets)
        }

        let (baseRef, baseAssets) = try resolveVariant("base")
        guard baseRef != nil || !baseAssets.isEmpty else {
            throw StudioError.invalidArchive("archive has no base variant to install")
        }
        let baseMeta = try library.save(name: manifest.name, refWav: baseRef,
                                        refText: sources["base"]?.text ?? "",
                                        provenance: manifest.provenance, engines: baseAssets,
                                        pace: manifest.pace, enginePace: manifest.enginePace)

        for key in keys where key != "base" {
            let safeKey = try safeComponent(key)
            let (ref, assets) = try resolveVariant(key)
            guard ref != nil || !assets.isEmpty else { continue }
            try library.saveAt(slug: "\(baseMeta.slug)-\(safeKey)", name: "\(manifest.name) \(key)",
                               refWav: ref, refText: sources[key]?.text ?? "",
                               provenance: manifest.provenance, variantOf: baseMeta.slug, engines: assets)
        }
        return baseMeta
    }

    /// Strips a leading "./" (some writers emit pack-relative paths this way);
    /// zip member lookup is otherwise exact-match.
    private static func normalizeMember(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
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
