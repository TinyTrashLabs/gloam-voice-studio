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
    /// Free-form record of how a `.gvoice` import's renditions were produced.
    /// Opaque to this build — carried so re-export doesn't drop it. Nil for
    /// voices created locally rather than imported.
    public var provenance: JSONValue?
    /// Local slug of the voice this one is an emotion/style variant of, e.g.
    /// "cruz-hype" carries `variantOf: "cruz"`. Nil for a base (non-variant)
    /// voice. Explicit membership, not inferred from the slug prefix — an
    /// independently-named voice like "dj-nova" must never be mistaken for a
    /// variant of "dj" just because its slug starts with "dj-".
    public var variantOf: String?
    /// Delivery pace, 1.0 = the reference's own pace. Nil means unset — which
    /// is NOT the same as 1.0, because writing a default into every pack would
    /// make "unset" indistinguishable from "deliberately 1.0" on re-export.
    public var pace: Double?
    /// Engine id -> pace override. See `GVoice.pace(for:in:)` for resolution.
    public var enginePace: [String: Double]?
    /// Per-voice loudness trim in dB, on top of the reference standard.
    ///
    /// The standard (`RefLoudness`) makes every voice measure the same. This is
    /// for the part measurement cannot settle: two references at an identical
    /// -17.0 LUFS can still sit differently in a mix, because timbre, delivery
    /// and the material behind them all move perceived level. Taste, in other
    /// words — which is why it is a per-voice trim and not another target.
    ///
    /// Deliberately layered ON TOP of the standard rather than replacing it. A
    /// trim over a working baseline is a small correction most voices leave at
    /// zero; a trim over an unlevelled library would be 34 numbers dialled by
    /// hand to paper over a bug, re-dialled on every import.
    ///
    /// Nil means unset, which is NOT the same as 0 — writing a default into
    /// every pack would make "unset" indistinguishable from "deliberately flat"
    /// on re-export, exactly as `pace` documents above.
    public var gain: Double?

    /// Free-form human description of the voice — what it sounds like, where it
    /// came from. Seeded on the built-in preset packs (Kokoro's per-voicepack
    /// blurbs, SuperTonic's M/F style notes) and editable like any other field,
    /// which is the point: the description belongs to the voice, not to whatever
    /// view happened to be showing it. Nil means unset, as for `pace`/`gain`.
    public var notes: String?

    public init(name: String, slug: String, refText: String, createdAt: String,
                persona: Persona? = nil, provenance: JSONValue? = nil, variantOf: String? = nil,
                pace: Double? = nil, enginePace: [String: Double]? = nil,
                gain: Double? = nil, notes: String? = nil) {
        self.name = name
        self.slug = slug
        self.refText = refText
        self.createdAt = createdAt
        self.persona = persona
        self.provenance = provenance
        self.variantOf = variantOf
        self.pace = pace
        self.enginePace = enginePace
        self.gain = gain
        self.notes = notes
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
        provenance = (try? c.decodeIfPresent(JSONValue.self, forKey: .provenance)) ?? nil
        variantOf = try c.decodeIfPresent(String.self, forKey: .variantOf)
        // Tolerant like the fields above: a malformed pace must not break load.
        pace = (try? c.decodeIfPresent(Double.self, forKey: .pace)) ?? nil
        enginePace = (try? c.decodeIfPresent([String: Double].self, forKey: .enginePace)) ?? nil
        // Tolerant like every field above: a malformed trim must not break load.
        gain = (try? c.decodeIfPresent(Double.self, forKey: .gain)) ?? nil
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil
    }
}

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
        // Dia2 conditions on a word-aligned prefix, not on raw audio, so a
        // reference clip alone is not enough: without the alignment cache in
        // engines/dia2/ there is no prefix and generation would run
        // unconditioned — a different voice, under this voice's name. That is
        // the same silent substitution the preset work removed, so dia2 is
        // deliberately excluded from the generic clone fallback below and must
        // declare itself through the cache.
        guard backend != .dia2 else { return false }
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
        guard !FileManager.default.fileExists(atPath: voiceDir.path) else {
            throw StudioError.voiceExists(slug: slug)
        }
        guard refWav != nil || !engines.isEmpty else {
            throw StudioError.invalidArchive("voice \(slug) has neither reference audio nor engine assets")
        }
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        // Every reference meets the loudness standard on the way in (RefLoudness).
        // A clone is exactly as loud as what it was cloned from and nothing
        // downstream re-levels it, so this write is the one boundary where "gain
        // 1 means the same thing for every voice" can actually be made true —
        // and every voice crosses it exactly once, however it arrived.
        if let refWav { try RefLoudness.normalized(wav: refWav).write(to: voiceDir.appendingPathComponent("ref.wav")) }
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
        let voiceDir = directory.appendingPathComponent(safeSlug)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        if let refWav { try RefLoudness.normalized(wav: refWav).write(to: voiceDir.appendingPathComponent("ref.wav")) }
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

    /// Variant key -> library slug for `slug` and its "<slug>-<x>" siblings.
    ///
    /// Emotion variants live as sibling voices but belong to ONE identity, so a
    /// pack must carry them together — export the base alone and the receiving
    /// end silently loses the voice's emotional range.
    ///
    /// Membership is `meta.variantOf == slug`, not a slug-prefix guess: an
    /// independently-named voice like "dj-nova" must never be swept into an
    /// export of "dj" just because its slug happens to start with "dj-".
    public func variantSlugs(of slug: String) -> [String: String] {
        var found = ["base": slug]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name.hasPrefix("\(slug)-"),
                  let data = try? Data(contentsOf: child.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(VoiceMeta.self, from: data),
                  meta.variantOf == slug
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
                let data = safe.hasSuffix(".wav") ? RefLoudness.normalized(wav: blob) : blob
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
        var meta = try self.meta(slug)
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
                          var variantMeta = try? self.meta("\(slug)-\(suffix)")
                    else { continue }
                    try FileManager.default.moveItem(at: oldDir, to: newDir)
                    variantMeta.slug = "\(newSlug)-\(suffix)"
                    variantMeta.variantOf = newSlug
                    try write(variantMeta, to: newDir)
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
            try RefLoudness.normalized(wav: refWav)
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
        try write(meta, to: directory.appendingPathComponent(slug))
        return meta
    }

    /// Sets (or clears, with nil) the chat persona on a stored voice.
    @discardableResult
    public func setPersona(_ slug: String, persona: Persona?) throws -> VoiceMeta {
        var meta = try self.meta(slug)
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
