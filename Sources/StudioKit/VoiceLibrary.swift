import Foundation
import EngineKit
// Re-exported so the rest of StudioKit -- and its dependents -- keep seeing
// VoiceMeta, Persona, GVoice, RefLoudness and StudioError at the same import
// they always did, now that the format itself lives in its own target.
@_exported import GVoiceKit

/// What a stored voice can actually render, derived from its pack contents on
/// disk (the voice folder IS an exploded .gvoice pack: optional ref.wav source
/// plus optional engines/<engine-id>/ renditions). One shared truth for the
/// sidebar, the pickers, and the API server, so they never disagree about
/// which engines a voice works on.
public struct VoiceCapabilities: Sendable, Equatable {
    /// ref.wav exists — the cross-engine asset every cloning backend consumes.
    public var hasSource: Bool
    /// meta.refText non-empty — required alongside source by the engines whose
    /// clone path is conditioned on the transcript too (see `needsRefText`).
    public var hasRefText: Bool
    /// engines/<id>/ directories holding at least one file. Ids are BackendID
    /// raw values when the pack was baked for this app; unknown ids are
    /// carried but simply never match.
    public var engines: Set<String>

    public init(hasSource: Bool, hasRefText: Bool, engines: Set<String>) {
        self.hasSource = hasSource
        self.hasRefText = hasRefText
        self.engines = engines
    }

    /// Whether `backend` can render this voice: a baked rendition for it, or
    /// source audio on a cloning backend (plus transcript where the engine
    /// conditions on it). qwen3-design mints voices from an instruct rather
    /// than speaking stored ones, so no library voice ever enables it.
    public func supports(_ backend: BackendID) -> Bool {
        guard backend != .qwenDesign else { return false }
        if engines.contains(backend.rawValue) { return true }
        // Dia2 conditions on a word-aligned prefix, not on raw audio. It used
        // to be excluded here, because a pack without the alignment cache in
        // engines/dia2/ had no prefix and would generate unconditioned — a
        // different voice under this voice's name. That exclusion is gone: the
        // callers now BUILD the cache on demand from the source clip (see
        // AppModel.dialoguePrefix / APIRouter.dialoguePrefixes), so source audio
        // is genuinely sufficient. The clip still has to exist, which the
        // generic clone rule below already requires.
        guard backend.controls.voiceClone != .none else { return false }
        return hasSource && (!backend.needsRefText || hasRefText)
    }
}

/// How a pack renders on one engine.
///
/// Two shapes, because a voice's assets are not always files. A cloning or baked
/// voice carries tensors on disk; a preset voice carries only the *name* of a
/// speaker the engine already ships — Kokoro's voicepacks live inside the model,
/// and SuperTonic's style tensors live in the model repo, neither of them in the
/// pack. The `.gvoice` format has always described the second shape
/// (`engines/<id>/voice.json` with a `speaker`, see docs/gvoice-format.md); this
/// is the type that finally reads it.
public enum VoiceRendition: Sendable, Equatable {
    /// A baked style file in the pack (supertonic `style.json`).
    case style(URL)
    /// The engine's own preset speaker name — Kokoro "af_heart", SuperTonic
    /// "M1", qwen3-custom "Dylan". Passed through as `SynthesisRequest.speaker`.
    case builtinSpeaker(String)
}

/// Voice library rooted at an injectable directory (sandbox container in the
/// app, temp dir in tests). Stateless: all state lives on disk.
public struct VoiceLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// One folder per voice, its takes in `<voice>/variants/<key>/`. Every
    /// read and write below resolves a slug through this, so a take address
    /// (`nova-excited`) and a voice address (`nova`) both land in the right
    /// folder — see `PackFolderLayout`.
    public var layout: PackFolderLayout { PackFolderLayout(directory: directory) }

    public func locate(_ address: String) -> PackFolderLayout.Location? { layout.locate(address) }

    /// The folder `slug` lives in — a voice's own, or a take's inside its voice.
    func folder(_ slug: String) throws -> URL {
        guard let url = layout.folder(for: slug) else { throw StudioError.voiceNotFound(slug: slug) }
        return url
    }

    /// Save a new voice from reference audio, engine assets, or both.
    ///
    /// `refWav` is optional because a voice is not always a recording: a
    /// Supertonic voice is a pair of baked style tensors, and qwen3-design's
    /// voice is a text description. `engines` maps an engine id to
    /// [filename: bytes] — ids are not validated, since a library that stores an
    /// asset it cannot render is still useful when the pack is bound elsewhere.
    public func save(name: String, refWav: Data?, refText: String,
                     provenance: JSONValue? = nil,
                     engines: [String: [String: Data]] = [:],
                     pace: Double? = nil,
                     enginePace: [String: Double]? = nil,
                     gain: Double? = nil,
                     notes: String? = nil) throws -> VoiceMeta {
        let slug = try Slug.slugify(name)
        let voiceDir = directory.appendingPathComponent(slug)
        // A take at this address counts too: a top-level folder would win the
        // address and hide it.
        guard !FileManager.default.fileExists(atPath: voiceDir.path), layout.locate(slug) == nil else {
            throw StudioError.voiceExists(slug: slug)
        }
        guard refWav != nil || !engines.isEmpty else {
            throw StudioError.invalidArchive("voice \(slug) has neither reference audio nor engine assets")
        }
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        // Every reference meets the standard on the way in (ReferenceStandard:
        // no cut-off ending, then RefLoudness).
        // A clone is exactly as loud as what it was cloned from and nothing
        // downstream re-levels it, so this write is the one boundary where "gain
        // 1 means the same thing for every voice" can actually be made true —
        // and every voice crosses it exactly once, however it arrived.
        if let refWav { try ReferenceStandard.applied(to: refWav).write(to: voiceDir.appendingPathComponent("ref.wav")) }
        try writeEngines(engines, to: voiceDir)
        let meta = VoiceMeta(name: name, slug: slug, refText: refText,
                             createdAt: Self.timestamp(), provenance: provenance,
                             pace: pace, enginePace: enginePace, gain: gain,
                             notes: notes)
        try write(meta, to: voiceDir)
        return meta
    }

    /// Save a voice at a caller-chosen slug, overwriting any existing entry.
    /// Used for variant dirs like `<baseSlug>-excited` where slugify cannot
    /// guarantee the exact suffix format.
    ///
    /// `slug` must be a single path component — validated here (not just at
    /// the call site) because this is the actual filesystem write boundary,
    /// and `slug` has in the past been built by interpolating an attacker-
    /// controlled `.gvoice` variant key (see `GVoice.import`). Trusting the
    /// caller there once let a crafted pack escape the library directory.
    @discardableResult
    public func saveAt(slug: String, name: String, refWav: Data?, refText: String,
                       provenance: JSONValue? = nil, variantOf: String? = nil,
                       engines: [String: [String: Data]] = [:],
                       notes: String? = nil) throws -> VoiceMeta {
        let safeSlug = try GVoice.safeComponent(slug)
        let voiceDir: URL
        if let base = variantOf, safeSlug.hasPrefix("\(base)-"), safeSlug.count > base.count + 1 {
            // A take is written inside the voice that owns it, never beside it.
            guard layout.locate(base) == .voice(base) else { throw StudioError.voiceNotFound(slug: base) }
            let key = try GVoice.safeComponent(String(safeSlug.dropFirst(base.count + 1)))
            voiceDir = layout.variantDir(base: base, key: key)
        } else {
            voiceDir = directory.appendingPathComponent(safeSlug)
        }
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        if let refWav { try ReferenceStandard.applied(to: refWav).write(to: voiceDir.appendingPathComponent("ref.wav")) }
        try writeEngines(engines, to: voiceDir)
        let meta = VoiceMeta(name: name, slug: safeSlug, refText: refText,
                             createdAt: Self.timestamp(), provenance: provenance, variantOf: variantOf,
                             notes: notes)
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
        let voiceDir = try folder(slug)
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

    /// Derive what `slug` can render from cheap filesystem checks. An unknown
    /// slug reports empty capabilities rather than throwing — callers render
    /// lists where a race with a delete must not crash the row.
    public func capabilities(_ slug: String) -> VoiceCapabilities {
        guard let (meta, refURL, engines) = try? entry(slug) else {
            return VoiceCapabilities(hasSource: false, hasRefText: false, engines: [])
        }
        return VoiceCapabilities(hasSource: refURL != nil,
                                 hasRefText: !meta.refText.isEmpty,
                                 engines: Set(engines.keys))
    }

    /// How `slug` renders on `engine`, or nil if it cannot. An emotion-variant
    /// voice without its own rendition falls back to its base voice's — same
    /// resolution order as reference audio.
    ///
    /// A `voice.json` naming a `speaker` wins over any style file: it is the
    /// explicit statement "render me as the engine's own preset X". Only files
    /// that are NOT `voice.json` are treated as baked styles, because
    /// `voice.json` is also where lux-tts stores its reference window,
    /// qwen3-design its instruct and elevenlabs its voiceId — none of which is a
    /// style, and all of which the previous "first .json in the directory"
    /// heuristic happily returned as one. That heuristic is why a pack carrying
    /// `engines/kokoro/voice.json` used to reach the planner with a styleURL
    /// set, which zeroed the speaker and handed Kokoro `voice: nil`.
    public func rendition(_ slug: String, engine: String) -> VoiceRendition? {
        func direct(_ s: String) -> VoiceRendition? {
            guard let (_, _, engines) = try? entry(s),
                  let files = engines[engine] else { return nil }
            let sorted = files.sorted { $0.key < $1.key }
            if let voiceJSON = files["voice.json"],
               let data = try? Data(contentsOf: voiceJSON),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let speaker = object["speaker"] as? String,
               !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .builtinSpeaker(speaker)
            }
            guard let style = sorted.first(where: {
                $0.value.pathExtension == "json" && $0.key != "voice.json"
            })?.value else { return nil }
            return .style(style)
        }
        if let found = direct(slug) { return found }
        guard let base = (try? entry(slug))?.meta.variantOf else { return nil }
        return direct(base)
    }

    /// The baked style file for `engine` in `slug`'s pack (supertonic:
    /// engines/supertonic/style.json). Nil when the pack renders by preset name
    /// instead — see `rendition(_:engine:)`, which this wraps.
    public func renditionStyleURL(_ slug: String, engine: String) -> URL? {
        if case .style(let url) = rendition(slug, engine: engine) { return url }
        return nil
    }

    /// Variant key -> address for `slug` and the takes inside its folder.
    ///
    /// A voice's takes belong to ONE identity, so a pack carries them together.
    /// Membership is the folder (`<slug>/variants/<key>/`), so an independently
    /// named voice like "dj-nova" can never be swept into an export of "dj".
    public func variantSlugs(of slug: String) -> [String: String] {
        var found = ["base": slug]
        for key in layout.variantKeys(of: slug) { found[key] = "\(slug)-\(key)" }
        return found
    }

    /// Add one file to an existing pack's `engines/<engine>/` folder.
    ///
    /// The narrow write the "Make Dia-compatible" upgrade needs: a preset voice
    /// gains `engines/dia2/ref.wav` — a clip synthesized by its own engine — and
    /// nothing else about the pack changes. Deliberately NOT `update(refWav:)`:
    /// a top-level ref.wav is the cross-engine source asset, and writing one
    /// would claim this synthesized clip is a recording of the voice, making the
    /// preset cloneable on every backend and (per `PresetVoiceSeeder.state`)
    /// no longer bundled.
    ///
    /// Same normalization and same path validation as the bulk `writeEngines`,
    /// since this is the same write boundary reached one file at a time.
    @discardableResult
    public func writeEngineAsset(_ slug: String, engine: String, file: String,
                                 data: Data) throws -> URL {
        let voiceDir = try folder(try GVoice.safeComponent(slug))
        try writeEngines([engine: [file: data]], to: voiceDir)
        return voiceDir.appendingPathComponent("engines")
            .appendingPathComponent(engine).appendingPathComponent(file)
    }

    /// Delete a pack's `engines/<engine>/` folder, if it has one. Used when a
    /// derived rendition goes stale — a preset rebound to a different speaker
    /// invalidates the Dia2 clip baked from the old one.
    public func removeEngineAssets(_ slug: String, engine: String) throws {
        guard let voiceDir = layout.folder(for: try GVoice.safeComponent(slug)) else { return }
        let engineDir = voiceDir
            .appendingPathComponent("engines")
            .appendingPathComponent(try GVoice.safeComponent(engine))
        guard FileManager.default.fileExists(atPath: engineDir.path) else { return }
        try FileManager.default.removeItem(at: engineDir)
    }

    private func writeEngines(_ engines: [String: [String: Data]], to voiceDir: URL) throws {
        for (engine, files) in engines {
            let engineDir = voiceDir.appendingPathComponent("engines")
                .appendingPathComponent(try GVoice.safeComponent(engine))
            try FileManager.default.createDirectory(at: engineDir, withIntermediateDirectories: true)
            for (filename, blob) in files {
                // An engine's REFERENCE audio meets the same standard as the
                // top-level one. The LuxTTS lane writes a derived window here
                // (engines/lux-tts/ref.wav, a trimmed span of source/ref.wav) and
                // renders the clone from THAT file — so levelling only the
                // top-level ref would leave the asset that actually matters at
                // whatever level it happened to be cut at. Everything else in an
                // engine folder (style embeddings, voice.json) passes through:
                // RefLoudness only touches WAV it recognises, so this is safe to
                // apply by name.
                let safe = try GVoice.safeComponent(filename)
                let data = safe.hasSuffix(".wav") ? ReferenceStandard.applied(to: blob) : blob
                try data.write(to: engineDir.appendingPathComponent(safe))
            }
        }
    }

    /// A stored voice's metadata, with no requirement that it have reference
    /// audio.
    ///
    /// The right call for everything that reads or edits a voice's *identity* —
    /// name, notes, persona, loudness trim. `get()` below additionally demands
    /// `ref.wav` and is for the synthesis paths that genuinely cannot work
    /// without it. The split matters now that a pack need not have a reference
    /// at all: the built-in preset voices are name-bound, and under `get()` they
    /// would have been unreadable, unrenamable and unpromotable — which would
    /// have defeated the point of storing them as ordinary voices.
    public func meta(_ slug: String) throws -> VoiceMeta {
        try entry(slug).meta
    }

    public func get(_ slug: String) throws -> (meta: VoiceMeta, refURL: URL) {
        let voiceDir = try folder(slug)
        let metaURL = voiceDir.appendingPathComponent("meta.json")
        let refURL = voiceDir.appendingPathComponent("ref.wav")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              FileManager.default.fileExists(atPath: refURL.path),
              let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data)
        else { throw StudioError.voiceNotFound(slug: slug) }
        return (meta, refURL)
    }

    /// Voices only — a take is never a row; ask `variantSlugs(of:)` for those.
    public func list() -> [VoiceMeta] {
        layout.voiceSlugs()
            .compactMap { try? meta($0) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// A voice goes with every take inside it; a take address removes just
    /// that take.
    public func delete(_ slug: String) throws {
        try FileManager.default.removeItem(at: try folder(slug))
    }

    /// Emotion suffixes tried in order when resolving a "<slug>-<emotion>"
    /// variant. Cloned reference audio dominates prosody, so an acted clip
    /// per emotion is what actually moves delivery; hype and excited are
    /// near-aliases of each other. Parity with voices._EMOTION_ALIASES.
    private static let emotionAliases: [Emotion: [String]] = [
        .hype: ["hype", "excited"],
        .excited: ["excited", "hype"],
    ]

    /// Take keys to try for an emotion word, most specific first: hype and
    /// excited stand in for each other; any other word is tried as itself.
    /// Empty for nil or neutral — those always mean the voice itself.
    public static func emotionSuffixes(_ emotion: String?) -> [String] {
        guard let word = emotion?.lowercased(), !word.isEmpty, word != "neutral" else { return [] }
        if let known = Emotion(rawValue: word) { return emotionAliases[known] ?? [word] }
        return [word]
    }

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

    /// Edit a stored voice in place. Renaming a voice re-slugs it (the folder
    /// moves, its takes inside it) and re-points each take. `variantSuffixes`
    /// is accepted for source compatibility and ignored: membership is the
    /// folder now. Renaming a take changes only its display name. Callers that
    /// re-slug must migrate their own references (chat, selection).
    public func update(_ slug: String, name: String? = nil,
                       refText: String? = nil, refWav: Data? = nil,
                       variantSuffixes: Set<String> = []) throws -> VoiceMeta {
        var meta = try self.meta(slug)
        var voiceDir = try folder(slug)
        let isVoice = layout.locate(slug) == .voice(slug)
        if let name, name != meta.name, !isVoice {
            // A take keeps its address; only its display name changes.
            meta.name = name
        } else if let name, name != meta.name {
            let newSlug = try Slug.slugify(name)
            if newSlug != slug {
                let target = directory.appendingPathComponent(newSlug)
                guard !FileManager.default.fileExists(atPath: target.path), layout.locate(newSlug) == nil else {
                    throw StudioError.voiceExists(slug: newSlug)
                }
                try FileManager.default.moveItem(at: voiceDir, to: target)
                voiceDir = target
                // Takes live inside the folder and moved with it; re-point them.
                for key in layout.variantKeys(of: newSlug) {
                    let takeDir = layout.variantDir(base: newSlug, key: key)
                    guard var takeMeta = try? self.meta("\(newSlug)-\(key)") else { continue }
                    takeMeta.slug = "\(newSlug)-\(key)"
                    takeMeta.variantOf = newSlug
                    try write(takeMeta, to: takeDir)
                }
            }
            meta.name = name
            meta.slug = newSlug
        }
        if let refText { meta.refText = refText }
        if let refWav, !refWav.isEmpty {
            // The standard applies HERE too. This is the third write site for a
            // reference and it was the one that missed — re-recording a voice
            // through `update` dropped it back to whatever level the microphone
            // happened to give, silently undoing the standard for that voice
            // while `save` and `saveAt` still honoured it.
            try ReferenceStandard.applied(to: refWav)
                .write(to: voiceDir.appendingPathComponent("ref.wav"))
        }
        try write(meta, to: voiceDir)
        return meta
    }

    /// Resolved loudness trim for a slug, in dB: its own trim, else the trim of
    /// the base voice it is a variant of, else 0.
    ///
    /// Falls back through `variantOf` for the same reason `enginePace` falls back
    /// to `pace` — a variant is the same identity acted differently, so trimming
    /// "cruz" must move "cruz-hype" too, or every base trim would have to be
    /// repeated across a voice's variants and kept in sync by hand. A variant
    /// that sets its OWN trim still wins, which is what makes the expressive
    /// variants (a shouted take sits hotter than a whispered one) tunable.
    public func gainDb(for slug: String) -> Double {
        guard let meta = try? self.meta(slug) else { return 0 }
        if let g = meta.gain, g.isFinite {
            return max(-GVoice.maxGainDb, min(GVoice.maxGainDb, g))
        }
        guard let base = meta.variantOf, base != slug,
              let baseGain = (try? self.meta(base))?.gain, baseGain.isFinite else { return 0 }
        return max(-GVoice.maxGainDb, min(GVoice.maxGainDb, baseGain))
    }

    /// Sets (or clears, with nil) the per-voice loudness trim, in dB.
    ///
    /// Clamped to ±`GVoice.maxGainDb`. A trim is a correction on top of a voice
    /// that already measures right, so a large one means something else is wrong
    /// — an unclamped field would let a slider undo the standard entirely.
    @discardableResult
    public func setGain(_ slug: String, gainDb: Double?) throws -> VoiceMeta {
        var meta = try self.meta(slug)
        meta.gain = gainDb.map { max(-GVoice.maxGainDb, min(GVoice.maxGainDb, $0)) }
        try write(meta, to: try folder(slug))
        return meta
    }

    /// Sets (or clears, with nil) the chat persona on a stored voice.
    @discardableResult
    public func setPersona(_ slug: String, persona: Persona?) throws -> VoiceMeta {
        var meta = try self.meta(slug)
        meta.persona = persona
        try write(meta, to: try folder(slug))
        return meta
    }

    public func avatarURL(_ slug: String) -> URL? {
        guard let url = layout.folder(for: slug)?.appendingPathComponent("avatar.png") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func saveAvatar(_ slug: String, pngData: Data) throws {
        try pngData.write(to: try folder(slug).appendingPathComponent("avatar.png"))
    }

    public func removeAvatar(_ slug: String) throws {
        guard let url = layout.folder(for: slug)?.appendingPathComponent("avatar.png") else { return }
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

/// Empty by construction: `VoiceLibrary` already declared all four members with
/// these exact signatures before the protocol existed. Extracting the format
/// changed no macOS behaviour, which is the point.
extension VoiceLibrary: GVoicePackStore {}

extension VoiceLibrary {
    /// Fold a library written in the old sibling layout into pack folders
    /// (`LegacyVariantFold`). Backs the whole library up to
    /// `<Voices>.pre-pack-folders` beside it before the first move. Returns how
    /// many takes moved; 0 on an already-folded library.
    @discardableResult
    public func foldLegacyVariants(log: (String) -> Void) throws -> Int {
        let backup = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent).pre-pack-folders")
        return try LegacyVariantFold.run(in: layout, backup: backup, log: log).count
    }
}
