/// TTS backends, raw values identical to the Python engine's backend strings
/// so .gvoice metadata and API payloads interoperate.
public enum BackendID: String, CaseIterable, Sendable, Codable {
    case qwen06B = "qwen3-0.6b"
    case qwen17B = "qwen3-1.7b"
    case qwenDesign = "qwen3-design"
    case qwenCustom = "qwen3-custom"
    case chatterbox
    case chatterboxTurbo = "chatterbox-turbo"
    case fishS2Pro = "fish-s2-pro"
    case kokoro
    case supertonic

    /// Fish's S1-DAC codec sample rate — reference audio must be loaded at this
    /// rate; the codec raises on mismatch.
    public static let fishCodecSampleRate = 44100

    /// Qwen3-TTS family — these resolve their repo from a base + quant suffix and
    /// store weights in quant-suffixed directories.
    public var isQwen: Bool {
        switch self {
        case .qwen06B, .qwen17B, .qwenDesign, .qwenCustom: true
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
        return spec.modelRepo
    }

    /// On-disk folder name. Qwen embeds the quant so precisions coexist.
    public func diskFolder(quantRaw: String?) -> String {
        isQwen ? "\(rawValue)@\(quantRaw ?? QwenQuant.q8.rawValue)" : rawValue
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

    public init(temperature: ClosedRange<Float>? = nil, topP: ClosedRange<Float>? = nil,
                topK: ClosedRange<Int>? = nil, repetitionPenalty: ClosedRange<Float>? = nil,
                exaggeration: ClosedRange<Float>? = nil, cfgWeight: ClosedRange<Float>? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.repetitionPenalty = repetitionPenalty; self.exaggeration = exaggeration
        self.cfgWeight = cfgWeight
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
        case .qwen06B, .qwen17B:
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
        case .supertonic:
            ControlSurface(voiceClone: .none, presetSpeakers: Self.supertonicVoices,
                           instruct: .none, language: false, knobs: Knobs())
        }
    }
}

extension BackendID {
    /// How this backend expresses emotion. See `EmotionMechanism`.
    public var emotionMechanism: EmotionMechanism {
        switch self {
        case .qwen06B, .qwen17B: .variantClipOnly   // pure clone; emotion via acted clips
        case .qwenDesign, .qwenCustom: .textDriven   // emotion via instruct/style prompt
        case .fishS2Pro: .inlineMarker               // emotion via leading [marker] text
        case .chatterbox: .liveKnob(.exaggeration)
        case .chatterboxTurbo: .variantClipOnly      // "emotion_adv": false — no knob
        case .kokoro: .none
        case .supertonic: .none                      // no emotion knob, no clone (Slice 1)
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
        case .kokoro:
            BackendSpec(modelRepo: "mlx-community/Kokoro-82M-bf16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        case .supertonic:
            // Weights are BigScience Open RAIL-M (use-based restrictions) — require
            // an explicit ack like Fish. See docs/supertonic-licensing.md.
            BackendSpec(modelRepo: "TinyTrashLabs/supertonic-3-mlx",
                        defaultSampleRate: 44100, honorsTags: false,
                        needsLicenseAck: true, needsRefAudio: false,
                        minRAMBytes: 8_000_000_000)
        }
    }
}
