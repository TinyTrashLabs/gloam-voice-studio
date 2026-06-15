import Foundation

/// What callers (UI, API server) ask for.
public struct SynthesisRequest: Sendable, Equatable {
    public var text: String
    public var refAudioPath: String?
    public var refText: String?
    public var emotion: Emotion
    /// Playback-speed multiplier (1.0 = unchanged). Applied as a time-domain
    /// resample after generation — extreme values shift pitch, same trade-off
    /// as both upstream implementations.
    public var speed: Float
    /// Override emotion's fishTemperature when present (Fish only).
    public var temperatureOverride: Float?
    /// Override emotion's chatterboxExaggeration when present (Chatterbox only).
    public var exaggerationOverride: Float?
    /// Qwen natural-language voice direction (instruct). Honored per backend.
    public var instruct: String?
    /// Qwen CustomVoice preset speaker name.
    public var speaker: String?
    /// Language hint ("auto" or one of the 10 languages); nil = auto.
    public var language: String?
    /// Qwen sampling overrides (nil = model default).
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?

    public init(text: String, refAudioPath: String? = nil, refText: String? = nil,
                emotion: Emotion = .neutral, speed: Float = 1.0,
                temperatureOverride: Float? = nil, exaggerationOverride: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil) {
        self.text = text
        self.refAudioPath = refAudioPath
        self.refText = refText
        self.emotion = emotion
        self.speed = speed
        self.temperatureOverride = temperatureOverride
        self.exaggerationOverride = exaggerationOverride
        self.instruct = instruct
        self.speaker = speaker
        self.language = language
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
    }
}

/// What the model provider receives — emotion already resolved to knobs.
public struct ProviderRequest: Sendable, Equatable {
    public var text: String
    public var refAudioPath: String?
    public var refText: String?
    /// Fish only: sampling temperature. Also used by Qwen.
    public var temperature: Float?
    /// Chatterbox (regular) only: emotion exaggeration.
    public var exaggeration: Float?
    /// Qwen natural-language direction.
    public var instruct: String?
    /// Qwen CustomVoice preset speaker.
    public var speaker: String?
    /// Qwen language hint (nil = auto).
    public var language: String?
    /// Qwen sampling overrides.
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?

    public init(text: String, refAudioPath: String? = nil, refText: String? = nil,
                temperature: Float? = nil, exaggeration: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil) {
        self.text = text; self.refAudioPath = refAudioPath; self.refText = refText
        self.temperature = temperature; self.exaggeration = exaggeration
        self.instruct = instruct; self.speaker = speaker; self.language = language
        self.topP = topP; self.topK = topK; self.repetitionPenalty = repetitionPenalty
    }
}

public struct SynthesisResult: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    /// Generation wall-clock seconds (excludes model load).
    public let wallSeconds: Double

    public init(samples: [Float], sampleRate: Int, wallSeconds: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.wallSeconds = wallSeconds
    }
}

public enum EngineError: Error, Equatable, Sendable {
    case licenseAckRequired(BackendID)
    case refAudioRequired(BackendID)
    case generationFailed(backend: BackendID, message: String)
    case invalidSpeed(Float)
    case instructRequired(BackendID)
    case speakerRequired(BackendID)
}

/// Pure translation from user request to provider request, with validation.
enum RequestPlanner {
    static func plan(backend: BackendID, request: SynthesisRequest) throws -> ProviderRequest {
        guard request.speed > 0 else { throw EngineError.invalidSpeed(request.speed) }
        let spec = backend.spec
        let controls = backend.controls
        let hasRef = request.refAudioPath != nil

        if spec.needsRefAudio && !hasRef {
            throw EngineError.refAudioRequired(backend)
        }

        func clean(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }

        // Instruct: honored only when the backend allows it AND (on clone-capable
        // backends) no reference voice is selected — the library ignores instruct on
        // the clone path, so the plan drops it to stay honest.
        let wantsInstruct = controls.instruct != .none && !(controls.voiceClone != .none && hasRef)
        let instruct = wantsInstruct ? clean(request.instruct) : nil
        if controls.instruct == .required && instruct == nil {
            throw EngineError.instructRequired(backend)
        }

        // Speaker: CustomVoice only; required.
        let speaker = controls.presetSpeakers.isEmpty ? nil : clean(request.speaker)
        if !controls.presetSpeakers.isEmpty && speaker == nil {
            throw EngineError.speakerRequired(backend)
        }

        let language = controls.language ? clean(request.language) : nil
        let knobs = controls.knobs

        return ProviderRequest(
            text: request.text,
            refAudioPath: request.refAudioPath,
            refText: request.refText,
            temperature: knobs.temperature != nil
                ? (request.temperatureOverride ?? (spec.honorsTags ? request.emotion.fishTemperature : nil))
                : nil,
            exaggeration: knobs.exaggeration != nil
                ? (request.exaggerationOverride ?? request.emotion.chatterboxExaggeration)
                : nil,
            instruct: instruct,
            speaker: speaker,
            language: language,
            topP: knobs.topP != nil ? request.topP : nil,
            topK: knobs.topK != nil ? request.topK : nil,
            repetitionPenalty: knobs.repetitionPenalty != nil ? request.repetitionPenalty : nil
        )
    }
}
