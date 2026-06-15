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

public struct BackendSpec: Sendable, Equatable {
    public let modelRepo: String
    public let defaultSampleRate: Int
    /// Inline [laughing]/[pause]-style tags in text are honored by the model.
    public let honorsTags: Bool
    /// Weights are under the Fish Audio Research License — require an explicit ack.
    public let needsLicenseAck: Bool
    /// chatterbox family: a reference clip is always required. fish: stock voice OK.
    public let needsRefAudio: Bool
    /// Whether the backend honors an emotion-exaggeration knob. chatterbox → true,
    /// chatterboxTurbo → false (turbo ignores exaggeration upstream), fishS2Pro → true
    /// (emotion is expressed via temperature).
    public let honorsEmotionKnob: Bool
}

extension BackendID {
    public var spec: BackendSpec {
        switch self {
        case .qwen06B:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        honorsEmotionKnob: false)
        case .qwen17B:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        honorsEmotionKnob: false)
        case .qwenDesign:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        honorsEmotionKnob: false)
        case .qwenCustom:
            BackendSpec(modelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: false,
                        honorsEmotionKnob: false)
        case .chatterbox:
            BackendSpec(modelRepo: "mlx-community/Chatterbox-TTS-fp16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        honorsEmotionKnob: true)
        case .chatterboxTurbo:
            BackendSpec(modelRepo: "mlx-community/chatterbox-turbo-fp16",
                        defaultSampleRate: 24000, honorsTags: false,
                        needsLicenseAck: false, needsRefAudio: true,
                        honorsEmotionKnob: false)
        case .fishS2Pro:
            BackendSpec(modelRepo: "mlx-community/fish-audio-s2-pro-bf16",
                        defaultSampleRate: 44100, honorsTags: true,
                        needsLicenseAck: true, needsRefAudio: false,
                        honorsEmotionKnob: true)
        }
    }
}
