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
    case luxTTS = "lux-tts"
    case supertonic
    case pocketTTS = "pocket-tts"
    case dia2

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

    /// On-disk folder name. Qwen embeds the quant so precisions coexist; Dia2
    /// embeds both size and quant (e.g. "dia2@2b-8bit") since it ships two sizes.
    public func diskFolder(quantRaw: String?) -> String {
        switch self {
        case .dia2: "dia2@\(quantRaw ?? "2b-8bit")"
        default: isQwen ? "\(rawValue)@\(quantRaw ?? QwenQuant.q8.rawValue)" : rawValue
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

    public init(temperature: ClosedRange<Float>? = nil, topP: ClosedRange<Float>? = nil,
                topK: ClosedRange<Int>? = nil, repetitionPenalty: ClosedRange<Float>? = nil,
                exaggeration: ClosedRange<Float>? = nil, cfgWeight: ClosedRange<Float>? = nil,
                numSteps: ClosedRange<Int>? = nil, guidanceScale: ClosedRange<Float>? = nil,
                tShift: ClosedRange<Float>? = nil, speed: ClosedRange<Float>? = nil,
                returnSmooth: Bool? = nil, cfgScale: ClosedRange<Float>? = nil) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.repetitionPenalty = repetitionPenalty; self.exaggeration = exaggeration
        self.cfgWeight = cfgWeight
        self.numSteps = numSteps; self.guidanceScale = guidanceScale
        self.tShift = tShift; self.speed = speed; self.returnSmooth = returnSmooth
        self.cfgScale = cfgScale
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
        case .qwen06B, .qwen17B, .luxTTS: true
        case .dia2: false   // optional reference clip is prefix conditioning, not a transcript pair
        default: false
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
        case .luxTTS:
            // NOTE: unlike every other backend here, "YatharthS/LuxTTS" does NOT
            // ship MLX-native weights — it's the torch/ONNX source of truth.
            // LuxSpeechModel's loadModel must run the LuxTTS/convert_weights.py
            // key-remap (weight-norm fold, conv-layout transpose) once and cache
            // the result locally rather than handing this repo id to
            // mlx-audio-swift's generic HF downloader like the other cases do.
            // Total weights ~560MB fp32 (477.5MB decoder + 17.6MB encoder +
            // ~64MB vocoder) — far lighter than the other backends.
            BackendSpec(modelRepo: "YatharthS/LuxTTS",
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
