import Foundation
import GVoiceKit

/// Which silicon a backend renders on. Requests on different families can run at the same time (a
/// GPU render and a Neural Engine render do not contend), requests on one family queue.
public enum SpeechFamily: String, Sendable, CaseIterable {
    /// MLX (Metal GPU), plus every other backend that is not on the Neural Engine.
    case gpu
    /// Core ML on the Neural Engine: `qwen3-0.6b-ane`, `qwen3-1.7b-ane`.
    case neuralEngine
}

/// TTS backends, raw values identical to the Python engine's backend strings
/// so .gvoice metadata and API payloads interoperate.
public enum BackendID: String, CaseIterable, Sendable, Codable {
    // Declaration order IS presentation order: every picker derives from
    // `allCases.filter { $0.surfaces.contains(...) }` (see `surfaces`), so this
    // list is the one place model ordering is decided. Raw values are the
    // Python engine's backend strings and are what persists, so reordering here
    // is safe for stored settings and .gvoice metadata.
    case qwen06B = "qwen3-0.6b"
    /// The phone bake of 0.6B Base: a 4-bit/g64 talker text embedding and an F16
    /// codec, shrunk by `scratch-mlx/shrink_qwen_mlx.py` in the iOS app. Ships at
    /// one fixed precision, so it has no Precision picker (`availableQuants` is
    /// empty) and its weights live in a bare folder.
    case qwen06BMobile = "qwen3-0.6b-mobile"
    /// Qwen3-TTS 0.6B Base on the Apple Neural Engine (Core ML, macOS 15+), no MLX and no GPU:
    /// the model for realtime use beside a GPU-bound LLM, and the only one that STREAMS the first
    /// words of a line while the rest renders. Its model set (`tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE`)
    /// downloads into `QwenANEModelLocation.defaultDirectory`. Clone-only: a voice needs a reference
    /// transcript. It is not `isQwen`: that flag means "MLX Qwen, repo + quant folders".
    case qwen06BANE = "qwen3-0.6b-ane"
    case qwen17B = "qwen3-1.7b"
    /// Qwen3-TTS 1.7B Base on the Neural Engine: the same runtime as `qwen06BANE` (QwenANE reads the model
    /// set's size from its host config), bigger model, better clones, slower (about real time on an M5, so
    /// it streams only just ahead of playback). Model set `tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE`.
    case qwen17BANE = "qwen3-1.7b-ane"
    case qwenDesign = "qwen3-design"
    case qwenCustom = "qwen3-custom"
    case chatterboxTurbo = "chatterbox-turbo"
    case fishS2Pro = "fish-s2-pro"
    /// BreezeBlue's Breeze TTS 2 (3B, English + Chinese). Clones from a
    /// reference pair, designs a voice from a Direction alone, and — the only
    /// backend that does both at once — lets a Direction steer a cloned voice
    /// ("voice direction"). See `instructDirectsClone`.
    case breezeTTS2 = "breeze-tts-2"
    // Demoted below turbo/Fish for historical reasons (it used to double the
    // line — fixed 2026-07-02 in the vendored mlx-audio-swift fork: CFG
    // uncond-stream position embeddings, missing [SPACE] tokenization, and
    // uninitialized S3Gen attention biases).
    case chatterbox
    case kokoro
    case supertonic
    case luxTTS = "lux-tts"
    case pocketTTS = "pocket-tts"
    case dia2

    /// Fish's S1-DAC codec sample rate — reference audio must be loaded at this
    /// rate; the codec raises on mismatch.
    public static let fishCodecSampleRate = 44100

    /// The silicon this backend's render runs on; see `SpeechFamily`.
    public var speechFamily: SpeechFamily { isQwenANE ? .neuralEngine : .gpu }

    /// The Qwen3-TTS builds that run on the Neural Engine (`QwenANE`), whatever their size.
    public var isQwenANE: Bool { self == .qwen06BANE || self == .qwen17BANE }

    /// Which prepared-voice folder (`engines/qwen3-0.6b/` or `qwen3-1.7b/`) this ANE build reads and writes; nil for any other backend.
    public var qwenANEKind: QwenEngineFiles.Kind? {
        switch self {
        case .qwen06BANE: .qwen06
        case .qwen17BANE: .qwen17
        default: nil
        }
    }

    /// Qwen3-TTS family — these resolve their repo from a base + quant suffix and
    /// store weights in quant-suffixed directories.
    public var isQwen: Bool {
        switch self {
        case .qwen06B, .qwen06BMobile, .qwen17B, .qwenDesign, .qwenCustom: true
        default: false
        }
    }

    /// Like `init(rawValue:)` but maps the retired `"qwen3"` raw value (was
    /// 0.6B-Base-8bit) to `.qwen06B` so persisted settings/history survive.
    public static func migrating(rawValue: String) -> BackendID? {
        if rawValue == "qwen3" { return .qwen06B }
        return BackendID(rawValue: rawValue)
    }
}

/// User-selectable Qwen3-TTS precision. Raw value is the HF repo suffix.
public enum QwenQuant: String, CaseIterable, Sendable {
    case q4 = "4bit", q5 = "5bit", q6 = "6bit", q8 = "8bit", bf16

    /// Rough size multiplier vs the 8-bit reference, for the disk preflight.
    public var sizeMultiplier: Double {
        switch self {
        case .q4: 0.6
        case .q5: 0.72
        case .q6: 0.82
        case .q8: 1.0
        case .bf16: 2.0
        }
    }
}

extension BackendID {
    /// Qwen repo base (everything before the quant suffix); nil for non-Qwen.
    public var qwenRepoBase: String? {
        switch self {
        case .qwen06B: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-"
        case .qwen06BMobile: nil   // ours, fixed precision — see `spec.modelRepo`
        case .qwen06BANE, .qwen17BANE: nil      // not an MLX repo
        case .qwen17B: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-"
        case .qwenDesign: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-"
        case .qwenCustom: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-"
        default: nil
        }
    }

    /// Resolved HF repo id. Qwen: base + quant suffix (defaults 8-bit).
    /// Non-Qwen: the static `spec.modelRepo` (quant ignored).
    public func modelRepo(quant: QwenQuant?) -> String {
        if let base = qwenRepoBase { return base + (quant ?? .q8).rawValue }
        if self == .breezeTTS2 { return Self.breezeRepo(quant: quant) }
        return spec.modelRepo
    }

    /// mlx-community's Breeze conversions. The bf16 one is the bare repo name
    /// (no suffix), unlike Qwen's `-bf16`. A precision mlx-community does not
    /// publish (5/6-bit) falls back to the 8-bit default rather than to a repo
    /// that 404s.
    public static func breezeRepo(quant: QwenQuant?) -> String {
        let base = "mlx-community/Breeze-TTS-2-mlx"
        switch quant ?? defaultQuant {
        case .bf16: return base
        case .q4: return base + "-4bit"
        default: return base + "-8bit"
        }
    }

    /// Precisions this backend can be downloaded at. Empty = it ships at one
    /// fixed precision, so callers must hide the Precision picker entirely
    /// (see `SettingsView.backendRow`) and `diskFolder` drops the `@quant`.
    /// Non-empty is also what makes the download manager persist a choice and
    /// quant-suffix the folder, so this is the one place that decides it.
    public var availableQuants: [QwenQuant] {
        switch self {
        case .qwen06BMobile: []            // one published bake, no choice to offer
        // mlx-community publishes exactly these three conversions.
        case .breezeTTS2: [.q4, .q8, .bf16]
        default: isQwen ? QwenQuant.allCases : []
        }
    }

    /// The precision a backend with `availableQuants` downloads at until the
    /// user picks another. 8-bit everywhere it is offered.
    public static let defaultQuant: QwenQuant = .q8

    /// The precision actually in effect given what the user stored (the raw
    /// value persisted under `qwenQuant.<backend>`): nil for a backend with no
    /// Precision picker; the default when nothing — or a precision this
    /// backend doesn't offer — was stored. The ONE rule both the download
    /// manager and the app's load resolver use, so they can never point at
    /// different folders.
    public func effectiveQuant(stored raw: String?) -> QwenQuant? {
        guard !availableQuants.isEmpty else { return nil }
        let stored = raw.flatMap(QwenQuant.init(rawValue:))
        return stored.flatMap { availableQuants.contains($0) ? $0 : nil } ?? Self.defaultQuant
    }

    /// Where the chosen precision is persisted. Keeps its historical `qwenQuant.`
    /// prefix so existing Qwen choices survive.
    public var quantDefaultsKey: String { "qwenQuant.\(rawValue)" }

    /// `effectiveQuant(stored:)` read straight from `defaults` — what the
    /// downloader and the load resolver both call.
    public func effectiveQuant(in defaults: UserDefaults) -> QwenQuant? {
        effectiveQuant(stored: defaults.string(forKey: quantDefaultsKey))
    }

    /// Measured download size at a precision, when it doesn't scale with
    /// `QwenQuant.sizeMultiplier`. Breeze's 682 MB audio tokenizer is
    /// unquantized in every conversion, so scaling its 8-bit size by Qwen's
    /// multipliers is ~10% short at 4-bit and ~20% long at bf16 — which the
    /// disk preflight then trusts. Sizes are the mlx-community repo totals.
    public func measuredDownloadBytes(quant: QwenQuant) -> Int64? {
        switch (self, quant) {
        case (.breezeTTS2, .q4): 3_042_732_998
        case (.breezeTTS2, .q8): 4_602_695_993
        case (.breezeTTS2, .bf16): 7_625_567_994
        default: nil
        }
    }

    /// On-disk folder name. Qwen embeds the quant so precisions coexist; Dia2
    /// embeds both size and quant (e.g. "dia2@2b-8bit") since it ships two sizes.
    /// dia2's folder encodes size as well as precision (`dia2@2b-8bit`), so a
    /// bare Qwen quant like "8bit" is not a valid value for it — callers pass
    /// nil and take the default. See `ModelDownloadManager.directory(for:)`.
    public func diskFolder(quantRaw: String?) -> String {
        switch self {
        case .dia2: "dia2@\(quantRaw ?? "2b-8bit")"
        default:
            !availableQuants.isEmpty
                ? "\(rawValue)@\(quantRaw ?? Self.defaultQuant.rawValue)"
                : rawValue
        }
    }
}

extension BackendID {
    /// All 54 Kokoro voicepacks, grouped by language (American English, British
    /// English, French, Hindi, Italian, Japanese, Spanish, Portuguese, Chinese) and,
    /// within each language, ordered by hexgrad's own VOICES.md quality grade
    /// (best first). Source: hexgrad/Kokoro-82M's VOICES.md + the vendored
    /// mlx-audio-swift README's per-language voice lists (fetched during design,
    /// not from training-data memory).
    public static let kokoroVoices: [String] = [
        // American English
        "af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah",
        "af_alloy", "af_nova", "af_sky", "af_jessica", "af_river",
        "am_fenrir", "am_michael", "am_puck", "am_echo", "am_eric", "am_liam",
        "am_onyx", "am_santa", "am_adam",
        // British English
        "bf_emma", "bf_isabella", "bf_alice", "bf_lily",
        "bm_fable", "bm_george", "bm_lewis", "bm_daniel",
        // French
        "ff_siwis",
        // Hindi
        "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        // Italian
        "if_sara", "im_nicola",
        // Japanese
        "jf_alpha", "jf_gongitsune", "jf_tebukuro", "jf_nezumi", "jm_kumo",
        // Spanish
        "ef_dora", "em_alex", "em_santa",
        // Portuguese
        "pf_dora", "pm_alex", "pm_santa",
        // Chinese
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    /// SuperTonic 3's 10 preset voice styles, as shipped in the converted-weights
    /// repo's voice_styles/ directory (Supertone/supertonic-3 presets).
    public static let supertonicVoices: [String] = [
        "M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5",
    ]
}

/// Which sampling sliders a backend exposes in the Advanced disclosure.
/// A nil range hides that knob.
public struct Knobs: Sendable, Equatable {
    public var temperature: ClosedRange<Float>?
    public var topP: ClosedRange<Float>?
    public var topK: ClosedRange<Int>?
    public var repetitionPenalty: ClosedRange<Float>?
    public var exaggeration: ClosedRange<Float>?
    /// Chatterbox (regular) CFG guidance weight. Resemble default 0.5; lower it as
    /// exaggeration rises to keep pacing from rushing. Turbo has no CFG → no knob.
    public var cfgWeight: ClosedRange<Float>?
    /// LuxTTS: flow-matching sampling steps. Doc default 4; "3-4 is best for
    /// efficiency" per upstream, higher trades latency for quality.
    public var numSteps: ClosedRange<Int>?
    /// LuxTTS: classifier-free guidance scale for the flow-matching decoder.
    public var guidanceScale: ClosedRange<Float>?
    /// LuxTTS: sampling-schedule shift. Doc default 0.5; "lower for less possible
    /// pronunciation errors but worse quality and vice versa."
    public var tShift: ClosedRange<Float>?
    /// LuxTTS: output pacing multiplier applied to the predicted duration. Doc
    /// default 1.0; lower slows delivery (useful when fast references rush/drop
    /// words at 1.0).
    public var speed: ClosedRange<Float>?
    /// LuxTTS: dual-path 48k output toggle. `true` (doc default) = the sharper,
    /// slightly noisier 48k path; `false` = the smoother 24k-resampled path. Not
    /// a range — nil hides the toggle, same as every other knob here.
    public var returnSmooth: Bool?
    /// Dia2: classifier-free guidance scale. Higher tracks the text more closely at
    /// the cost of naturalness.
    public var cfgScale: ClosedRange<Float>?
    /// Breeze: identity strength, guidance toward the reference voice (the fork's
    /// `BreezeTTSModel.referenceGuidanceOverride`). 1 = off. Only acts on a cloned
    /// take; costs an extra model pass per frame.
    public var referenceGuidance: ClosedRange<Float>?
    /// Whether a fixed sampling seed is honoured (same seed + same settings =
    /// the same take). Not a range: nil hides the control.
    public var seed: Bool?

    public init(temperature: ClosedRange<Float>? = nil, topP: ClosedRange<Float>? = nil,
                topK: ClosedRange<Int>? = nil, repetitionPenalty: ClosedRange<Float>? = nil,
                exaggeration: ClosedRange<Float>? = nil, cfgWeight: ClosedRange<Float>? = nil,
                numSteps: ClosedRange<Int>? = nil, guidanceScale: ClosedRange<Float>? = nil,
                tShift: ClosedRange<Float>? = nil, speed: ClosedRange<Float>? = nil,
                returnSmooth: Bool? = nil, cfgScale: ClosedRange<Float>? = nil,
                referenceGuidance: ClosedRange<Float>? = nil, seed: Bool? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.repetitionPenalty = repetitionPenalty; self.exaggeration = exaggeration
        self.cfgWeight = cfgWeight
        self.numSteps = numSteps; self.guidanceScale = guidanceScale
        self.tShift = tShift; self.speed = speed; self.returnSmooth = returnSmooth
        self.cfgScale = cfgScale
        self.referenceGuidance = referenceGuidance; self.seed = seed
    }
}

/// Dia2 ships in two sizes rather than one model at several quants, so the
/// disk folder and repo carry both.
public enum Dia2Size: String, Sendable, CaseIterable, Codable {
    case b2 = "2b"
    case b1 = "1b"

    public var displayName: String {
        switch self {
        case .b2: "2B — best quality"
        case .b1: "1B — lighter, faster"
        }
    }

    /// 2B fp32 is 7.7GB; bf16 halves that and 8-bit halves it again. These are
    /// the floors below which the model and a chat LLM stop coexisting.
    public var minRAMBytes: Int64 {
        switch self {
        case .b2: 16_000_000_000
        case .b1: 8_000_000_000
        }
    }
}

public extension BackendID {
    static func dia2Repo(size: Dia2Size, quant: QwenQuant?) -> String {
        "tinytrashlabs/dia2-\(size.rawValue)-mlx-\((quant ?? .q8).rawValue)"
    }
}

/// Which model-native scalar a `.liveKnob` backend drives for emotion.
public enum EmotionKnob: Sendable, Equatable { case exaggeration, temperature }

/// Single source of truth for how a backend expresses emotion. Consumed by BOTH
/// the request planner (which knob, if any, the emotion enum resolves to) and the
/// UI (which emotion control to render). Replaces the dead `honorsEmotionKnob`
/// flag and the `honorsTags` proxy the planner previously used to gate
/// emotion→temperature (honorsTags means "honors inline [tags]", unrelated).
public enum EmotionMechanism: Sendable, Equatable {
    /// Emotion steered by free-text instruct/style (qwen Design/Custom) — no chip;
    /// the Direction box is the control.
    case textDriven
    /// A model-native emotion scalar (fish temperature, chatterbox exaggeration).
    case liveKnob(EmotionKnob)
    /// Emotion only via acted `<slug>-<emotion>` reference clips (qwen Base, turbo).
    case variantClipOnly
    /// Emotion via a leading inline `[marker]` in the text — Fish's trained control
    /// (e.g. `[whisper] …`). The planner injects it; the model reads it as literal
    /// text and never speaks it.
    case inlineMarker
    /// No emotion control at all — a fixed preset-voicepack model (Kokoro) with no
    /// clone, no knob, and no acted-variant convention to fall back on.
    case none
    /// Delivery is steered by inline `(laughs)`-style tags drawn from the model's
    /// own vocabulary; the app offers them as chips rather than free text.
    case dialogueTags
    /// Emotion is PHRASED into the model's natural-language direction (Breeze):
    /// the Emotion picker and an expression ("whisper", "angry", …) each become
    /// a sentence the planner appends to whatever Direction the user wrote —
    /// see `DeliveryDirection`. Unlike `.textDriven`, the picker is live, and it
    /// works alongside a cloned voice. Acted `-emotion` clips are still used
    /// when they exist; the caller then sends `.neutral` so the clip's
    /// performance isn't directed a second time.
    case directed
}

/// Data-driven description of a backend's Direct-pane controls. The UI renders
/// from this; the request planner validates/gates against it.
public struct ControlSurface: Sendable, Equatable {
    public enum Requirement: Sendable, Equatable { case none, optional, required }
    public var voiceClone: Requirement
    public var presetSpeakers: [String]
    public var instruct: Requirement
    public var language: Bool
    public var knobs: Knobs

    public init(voiceClone: Requirement, presetSpeakers: [String] = [],
                instruct: Requirement, language: Bool, knobs: Knobs) {
        self.voiceClone = voiceClone; self.presetSpeakers = presetSpeakers
        self.instruct = instruct; self.language = language
        self.knobs = knobs
    }
}

extension BackendID {
    /// Documented CustomVoice preset speakers (1.7B). Authoritative source is the
    /// loaded model's `talkerConfig.spkId`; this is the picker list.
    public static let qwenPresetSpeakers =
        ["Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna", "Sohee"]

    /// Shared Qwen sampling knob ranges (Base/Design/Custom).
    private static let qwenKnobs = Knobs(
        temperature: 0.5...1.2, topP: 0.5...1.0, topK: 0...100, repetitionPenalty: 1.0...1.5)

    public var controls: ControlSurface {
        switch self {
        case .qwen06BANE, .qwen17BANE:
            // Clone-only (no unconditioned mode on the ANE build), and the on-device sampler
            // exposes no knobs, so there are none to offer. The language hint (es, en, …) reaches
            // `QwenANEEngine.render`; nil still means auto-detect.
            ControlSurface(voiceClone: .required, instruct: .none, language: true, knobs: Knobs())
        case .qwen06B, .qwen06BMobile, .qwen17B:
            // Base is a voice-cloning model (text + reference audio). It does NOT
            // take a natural-language instruct — that's VoiceDesign/CustomVoice only.
            ControlSurface(voiceClone: .optional, instruct: .none,
                           language: true, knobs: Self.qwenKnobs)
        case .qwenDesign:
            ControlSurface(voiceClone: .none, instruct: .required,
                           language: true, knobs: Self.qwenKnobs)
        case .qwenCustom:
            ControlSurface(voiceClone: .none, presetSpeakers: Self.qwenPresetSpeakers,
                           instruct: .optional, language: true,
                           knobs: Self.qwenKnobs)
        case .fishS2Pro:
            ControlSurface(voiceClone: .optional, instruct: .none,
                           language: false,
                           knobs: Knobs(temperature: 0.3...1.2))
        case .breezeTTS2:
            // Clone, design (Direction with no voice), or both. Language is
            // read from the text itself — the model's prompt has no language
            // slot, and the Swift port ignores the generic `language` argument.
            //
            // Every sampler the Swift port reads. Top-p/top-k/repetition and
            // CFG are bound to Breeze's OWN app state (AppModel.breeze*), not
            // the Qwen sliders' — those default to top-k off / repetition
            // 1.05, which would quietly replace Breeze's top-k 50 /
            // repetition 1.1. Temperature is shared: its 0.9 default is
            // Breeze's too. CFG only acts on instructed takes (design,
            // direction, emotion); 1 turns it off.
            ControlSurface(voiceClone: .optional, instruct: .optional,
                           language: false,
                           knobs: Knobs(temperature: 0.5...1.2, topP: 0.5...1.0,
                                        topK: 1...100, repetitionPenalty: 1.0...1.5,
                                        cfgScale: 1.0...8.0, referenceGuidance: 1.0...4.0,
                                        seed: true))
        case .chatterbox:
            ControlSurface(voiceClone: .required, instruct: .none,
                           language: false,
                           knobs: Knobs(exaggeration: 0...1, cfgWeight: 0...1))
        case .chatterboxTurbo:
            ControlSurface(voiceClone: .required, instruct: .none,
                           language: false, knobs: Knobs())
        case .kokoro:
            ControlSurface(voiceClone: .none, presetSpeakers: Self.kokoroVoices,
                           instruct: .none, language: false, knobs: Knobs())
        case .luxTTS:
            // Cloning-only — no stock voices, no instruct. English only for now
            // (the ported tokenizer stubs Chinese pending a jieba/pypinyin port).
            ControlSurface(voiceClone: .required, instruct: .none,
                           language: false,
                           knobs: Knobs(numSteps: 1...10, guidanceScale: 0...5,
                                       tShift: 0...1, speed: 0.5...1.5,
                                       returnSmooth: true))
        case .supertonic:
            ControlSurface(voiceClone: .none, presetSpeakers: Self.supertonicVoices,
                           instruct: .none, language: false, knobs: Knobs())
        case .pocketTTS:
            // Cloning-only, like LuxTTS. No sampling knobs surfaced: sherpa's
            // Pocket path exposes only a seed (varied per take) — flow steps /
            // guidance are fixed inside the runtime.
            ControlSurface(voiceClone: .required, instruct: .none,
                           language: false, knobs: Knobs())
        case .dia2:
            ControlSurface(
                voiceClone: .optional,      // unconditioned works; voices then vary
                presetSpeakers: [],
                instruct: .none,            // delivery comes from inline tags
                language: false,            // English only
                knobs: Knobs(temperature: 0.1 ... 1.5,
                             topK: 1 ... 200,
                             cfgScale: 1.0 ... 8.0))
        }
    }
}

extension BackendID {
    /// Whether the clone path is conditioned on the reference TRANSCRIPT as well as
    /// the reference audio — i.e. whether an empty `refText` silently un-clones the
    /// request.
    ///
    /// Qwen Base's in-context branch needs BOTH (`refAudio` *and* `refText`, see
    /// Qwen3TTS.generateVoiceDesign); with either missing it falls through to the
    /// unconditioned branch and invents a random speaker. LuxTTS's ported tokenizer
    /// has no ASR fallback, so it throws outright. Chatterbox, Pocket and Fish clone
    /// from the audio alone — a blank transcript there costs some quality at worst,
    /// so their voices must keep working without one.
    public var needsRefText: Bool {
        switch self {
        case .qwen06B, .qwen06BMobile, .qwen06BANE, .qwen17BANE, .qwen17B, .luxTTS: true
        // Breeze prompts with "[S0]<transcript>" ahead of the reference codes,
        // and the Swift port throws outright on a reference with no transcript.
        case .breezeTTS2: true
        case .dia2: false   // optional reference clip is prefix conditioning, not a transcript pair
        default: false
        }
    }
}

extension BackendID {
    /// Whether a Direction (`instruct`) is honored ALONGSIDE a reference voice.
    ///
    /// Every other instruct-capable backend either has no clone path at all
    /// (qwen3-design/custom) or drops the instruct the moment a reference is
    /// present, so the planner strips it there to stay honest. Breeze's
    /// "voice direction" is exactly that pairing — keep the cloned identity,
    /// steer tone/pace/emotion with words — so it must survive the planner.
    public var instructDirectsClone: Bool {
        switch self {
        case .breezeTTS2: true
        default: false
        }
    }

    /// Whether the backend can invent a voice from a Direction alone: it takes
    /// an instruct AND cloning is optional (Breeze). The Studio lets such a
    /// backend generate with no voice selected once a Direction is written,
    /// and the API treats an `instruct` with no `voice` as design rather than
    /// reaching for the Settings default voice. (qwen3-design also designs,
    /// but has no clone path — it never had a voice to leave out.)
    public var designsFromDirection: Bool {
        controls.instruct != .none && controls.voiceClone == .optional
    }

    /// Inline sounds a backend documents but does not list in an
    /// `added_tokens.json` the tag catalog can read off disk. Empty = ask the
    /// model directory (Dia2) or offer the free-form list (Fish).
    ///
    /// Breeze: the events from its model card, in the bracket style each
    /// language uses — English in parentheses (a `[bracketed]` English tag is
    /// read aloud), Chinese in square brackets.
    public var fixedNonverbalTags: [String] {
        switch self {
        case .breezeTTS2: ["(laugh)", "(sigh)", "(cough)", "(clears throat)",
                           "[笑]", "[叹气]", "[咳嗽]", "[清嗓子]"]
        default: []
        }
    }

    /// The most speech one generation call can produce before the model's
    /// token cap ends it mid-sentence, or nil when that is not a practical
    /// limit. GloamEngine splits longer text into sentence pieces under it
    /// (`LongTextChunker`). Breeze: 750 codec frames at 12.5 frames/s. Qwen
    /// shares the codec but allows 4096 frames (~5.5 min), which no line
    /// reaches. Exhaustive so a new backend has to answer the question.
    public var maxSecondsPerPass: Double? {
        switch self {
        case .breezeTTS2: 60
        case .qwen06B, .qwen06BMobile, .qwen17B, .qwenDesign, .qwenCustom,
             .chatterboxTurbo, .fishS2Pro, .chatterbox, .kokoro, .supertonic,
             .luxTTS, .pocketTTS, .dia2: nil
        // A real limit, but not a fixed one: the 1024-row talker window holds
        // the reference codes too, so the room left depends on the voice.
        // QwenANESpeechModel splits a line past it itself and renders the parts
        // through one QwenTalkSession, so each part continues the one before.
        case .qwen06BANE, .qwen17BANE: nil
        }
    }

}

extension BackendID {
    /// How this backend expresses emotion. See `EmotionMechanism`.
    public var emotionMechanism: EmotionMechanism {
        switch self {
        case .qwen06B, .qwen06BMobile, .qwen06BANE, .qwen17BANE, .qwen17B: .variantClipOnly   // pure clone; emotion via acted clips
        case .qwenDesign, .qwenCustom: .textDriven   // emotion via instruct/style prompt
        case .fishS2Pro: .inlineMarker               // emotion via leading [marker] text
        case .breezeTTS2: .directed                  // emotion is phrased into its instruction
        case .chatterbox: .liveKnob(.exaggeration)
        case .chatterboxTurbo: .variantClipOnly      // "emotion_adv": false — no knob
        case .kokoro: .none
        case .luxTTS: .variantClipOnly               // prosody comes entirely from the ref clip
        case .supertonic: .none                      // no emotion knob, no clone (Slice 1)
        case .pocketTTS: .variantClipOnly            // prosody comes entirely from the ref clip
        case .dia2: .dialogueTags
        }
    }
}

public struct BackendSpec: Sendable, Equatable {
    public let modelRepo: String
    public let defaultSampleRate: Int
    /// Inline [laughing]/[pause]-style tags in text are honored by the model.
    public let honorsTags: Bool
    /// Weights are under the Fish Audio Research License — require an explicit ack.
    public let needsLicenseAck: Bool
    /// chatterbox family: a reference clip is always required. fish: stock voice OK.
    public let needsRefAudio: Bool
    /// Minimum physical RAM (decimal bytes) to safely load/run this backend.
    public let minRAMBytes: Int64
}

extension BackendID {
    public var spec: BackendSpec {
        switch self {
        case .qwen06B:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .qwen06BMobile:
            // 885 MB on disk against 0.6B-8bit's 1.9 GB. Same 24 kHz clone model,
            // so every capability above matches .qwen06B.
            BackendSpec(modelRepo: "tinytrashlabs/Qwen3-TTS-12Hz-0.6B-Base-4bit-mobile",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .qwen06BANE:
            // `.mlmodelc` folders + host/ + vochead/, 2.07 GB, fetched by the in-app downloader into
            // `QwenANEModelLocation.defaultDirectory` (not the quant-folder layout of the MLX bakes).
            BackendSpec(modelRepo: "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 8_000_000_000)
        case .qwen17BANE:
            // The 0.6B set's layout (`.mlmodelc` folders + host/ + vochead/), 1.7B weights: 4 talker chunks, a 2048-wide
            // host, the 1.7B speaker encoder. The vocoder pieces and the speech encoder are the 0.6B set's own files.
            BackendSpec(modelRepo: "tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 8_000_000_000)
        case .qwen17B:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .qwenDesign:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .qwenCustom:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .chatterbox:
            BackendSpec(modelRepo: "mlx-community/Chatterbox-TTS-fp16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 8_000_000_000)
        case .chatterboxTurbo:
            BackendSpec(modelRepo: "mlx-community/chatterbox-turbo-fp16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 8_000_000_000)
        case .fishS2Pro:
            BackendSpec(modelRepo: "mlx-community/fish-audio-s2-pro-bf16",
                        defaultSampleRate: 44100, honorsTags: true,
                        needsLicenseAck: true, needsRefAudio: false,
                        minRAMBytes: 16_000_000_000)
        case .breezeTTS2:
            // BreezeBlue Research and Non-Commercial License — require an ack
            // like Fish. honorsTags is FALSE: it means free-form `[marker]`
            // tags (what /health tells API clients they may send), and Breeze
            // reads a bracketed English tag aloud. Its own sounds come from
            // `fixedNonverbalTags`, which drives the TAGS chips instead. The
            // repo here is the 8-bit default; the
            // precision picker resolves the others via `breezeRepo(quant:)`.
            // RAM floor: 4.6 GB of 8-bit weights plus a 3B backbone's two KV
            // caches (CFG runs a conditional and an unconditional pass) leave
            // an 8 GB Mac nothing for the app or a chat model — same floor as
            // Fish.
            BackendSpec(modelRepo: "mlx-community/Breeze-TTS-2-mlx-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: true, needsRefAudio: false,
                        minRAMBytes: 16_000_000_000)
        case .kokoro:
            BackendSpec(modelRepo: "mlx-community/Kokoro-82M-bf16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .luxTTS:
            // This used to point at "YatharthS/LuxTTS", which ships torch and
            // ONNX but no MLX-native weights — so `directory(for:)` filled with
            // model.pt and .onnx files, LuxSpeechModel.load went looking for
            // lux_model.safetensors, found nothing, and every shipped Mac build
            // threw "lux-tts weights are not installed — this model is not
            // downloadable in-app". It only worked on machines where someone
            // had run LuxTTS/convert_weights.py by hand and left the result in
            // the group container.
            //
            // tinytrashlabs/LuxTTS-mlx is that conversion, published once
            // (Apache-2.0, inherited from upstream), so the generic HF
            // downloader can do what it does for every other backend. ~529 MB
            // fp32: 468 MB model + 61 MB vocoder, plus config.json and
            // tokens.txt. fp32 on purpose — fp16 is indistinguishable on a long
            // clean reference and audibly worse on a short phone recording,
            // which is the case that matters for cloning.
            BackendSpec(modelRepo: "tinytrashlabs/LuxTTS-mlx",
                        defaultSampleRate: 48000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 2_000_000_000)
        case .supertonic:
            // Weights are BigScience Open RAIL-M (use-based restrictions) — require
            // an explicit ack like Fish. See docs/supertonic-licensing.md.
            BackendSpec(modelRepo: "tinytrashlabs/supertonic-3-mlx",
                        defaultSampleRate: 44100, honorsTags: false,
                        needsLicenseAck: true, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .pocketTTS:
            // "kyutai/pocket-tts" is the upstream source of truth (PyTorch,
            // CC-BY-4.0) but NOT what runs here: the runnable artifacts are a
            // sherpa-onnx int8 export, mirrored to this public HF repo so the
            // standard HF-snapshot downloader (like every other backend) can
            // fetch the weights (~210MB int8). The sherpa-onnx dylib itself is
            // bundled inside the app (see PocketTTS.bundledLibraryURL), not
            // downloaded here.
            BackendSpec(modelRepo: "csukuangfj2/sherpa-onnx-pocket-tts-int8-2026-01-26",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        minRAMBytes: 2_000_000_000)
        case .dia2:
            // Apache 2.0, English only, two speakers. Tags are the emotion
            // control, so honorsTags is true. RAM floor is the 2B default;
            // choosing 1B relaxes it via Dia2Size.minRAMBytes.
            BackendSpec(modelRepo: "tinytrashlabs/dia2-2b-mlx-8bit",
                        defaultSampleRate: 24000, honorsTags: true,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 16_000_000_000)
        }
    }
}

/// The places in the app a backend can show up. See `BackendID.surfaces`.
public struct BackendSurfaces: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The Studio engine chooser: the toolbar model popover and Settings →
    /// Models "Generate with".
    public static let studio = BackendSurfaces(rawValue: 1 << 0)
    /// The Dialogue composer's two-speaker engine.
    public static let dialogue = BackendSurfaces(rawValue: 1 << 1)
    /// Voice Foundry (Create Voice) — loaded for creation without becoming the
    /// Studio speak-backend.
    public static let creation = BackendSurfaces(rawValue: 1 << 2)
    /// Can speak a chat reply unattended (no per-line human input required).
    public static let chatVoice = BackendSurfaces(rawValue: 1 << 3)
    /// Offered as the HTTP API's "Default model".
    public static let apiServer = BackendSurfaces(rawValue: 1 << 4)
    /// Listed in Settings → Models with a Download button.
    public static let downloadable = BackendSurfaces(rawValue: 1 << 5)
}

extension BackendID {
    /// Where this backend appears in the UI.
    ///
    /// Deliberately a standalone exhaustive switch rather than a `BackendSpec`
    /// field: a field needs a default, and a default is exactly what let `dia2`
    /// ship invisible — downloadable nowhere, pickable nowhere, while the
    /// Dialogue screen pointed at a Settings list it wasn't in. Adding a case to
    /// `BackendID` now fails to compile until someone answers this question.
    ///
    /// Every picker derives from `BackendID.allCases.filter`, so declaration
    /// order in the enum IS presentation order. Curated lists are gone.
    public var surfaces: BackendSurfaces {
        switch self {
        case .qwen06B, .qwen06BMobile, .qwen17B, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox:
            [.studio, .chatVoice, .apiServer, .downloadable]
        case .breezeTTS2:
            // Not `.creation`: the Voice Foundry is built around qwen3-design
            // specifically. Breeze designs from a Direction in the Studio
            // instead (no voice selected), and over the API with `instruct`.
            [.studio, .chatVoice, .apiServer, .downloadable]
        case .qwenDesign:
            // Creation-only: it needs a typed Direction per line, so it can
            // neither be the Studio speak-backend nor answer chat unattended.
            // Still offered to the API, where a caller always sends `instruct`.
            [.creation, .apiServer, .downloadable]
        case .qwen06BANE, .qwen17BANE:
            // Renders on the Neural Engine lane wherever it is picked (Studio, chat, API), so it runs
            // beside a GPU-bound chat LLM. Clone-only: voices without a transcript are disabled per voice.
            [.studio, .chatVoice, .apiServer, .downloadable]
        case .luxTTS:
            [.studio, .chatVoice, .apiServer, .downloadable]
        case .kokoro, .supertonic, .pocketTTS:
            // These were absent from `.apiServer` only because the curated
            // array this switch replaced never listed them. Nothing about them
            // is unfit to serve over HTTP, so the omission was drift rather
            // than a rule — added 2026-09-05.
            [.studio, .chatVoice, .apiServer, .downloadable]
        case .dia2:
            // Two voices in one pass — Dialogue only. NOT `.studio`: a single
            // S1-only prefix clones the target voice too weakly to ship (the
            // conditioning is provably applied — DIA2_TRACE shows the reference
            // audio + aligned transcript reach the model — but Dia2 still speaks
            // in a different voice; inherent, not a wiring bug). Revisit in #56.
            // Not a chat voice either: a reply needs its prefix aligned first,
            // which is not unattended.
            [.dialogue, .downloadable]
        }
    }

    /// True when this backend's model folder is one a user also keeps their own files in (the Neural
    /// Engine set's folder holds hand-prepared `voices/`, and the loader can be pointed at it by hand), so
    /// a re-download only cleans the repo's own top-level folders. See `HFSnapshotLayout.prune`.
    public var sharesFolderWithUser: Bool { isQwenANE }

    /// Backends appearing on `surface`, in declaration order.
    public static func on(_ surface: BackendSurfaces) -> [BackendID] {
        allCases.filter { $0.surfaces.contains(surface) }
    }
}
