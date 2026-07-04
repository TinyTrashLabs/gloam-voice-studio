import Foundation

/// What callers (UI, API server) ask for.
public struct SynthesisRequest: Sendable, Equatable {
    public var text: String
    public var refAudioPath: String?
    public var refText: String?
    public var emotion: Emotion
    /// Fish inline emotion marker (e.g. "whisper"): the planner renders it as a
    /// leading `[marker]` for `.inlineMarker` backends. nil = none. Ignored by other
    /// backends. Not injected if `text` already begins with a `[marker]`.
    public var emotionMarker: String?
    /// Playback-speed multiplier (1.0 = unchanged). Applied as a time-domain
    /// resample after generation — extreme values shift pitch, same trade-off
    /// as both upstream implementations.
    public var speed: Float
    /// Override emotion's fishTemperature when present (Fish only).
    public var temperatureOverride: Float?
    /// Override emotion's chatterboxExaggeration when present (Chatterbox only).
    public var exaggerationOverride: Float?
    /// Chatterbox (regular) CFG guidance weight; nil = model default (0.5).
    public var cfgWeight: Float?
    /// Upper bound applied to the resolved exaggeration (Chatterbox only). Caps an
    /// expressive emotion/override below the range where timbre degrades. nil = no cap.
    public var exaggerationCeiling: Float?
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
                emotion: Emotion = .neutral, emotionMarker: String? = nil, speed: Float = 1.0,
                temperatureOverride: Float? = nil, exaggerationOverride: Float? = nil,
                cfgWeight: Float? = nil, exaggerationCeiling: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil) {
        self.text = text
        self.refAudioPath = refAudioPath
        self.refText = refText
        self.emotion = emotion
        self.emotionMarker = emotionMarker
        self.speed = speed
        self.temperatureOverride = temperatureOverride
        self.exaggerationOverride = exaggerationOverride
        self.cfgWeight = cfgWeight
        self.exaggerationCeiling = exaggerationCeiling
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
    /// Chatterbox (regular) only: CFG guidance weight (nil = model default 0.5).
    public var cfgWeight: Float?
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
                temperature: Float? = nil, exaggeration: Float? = nil, cfgWeight: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil) {
        self.text = text; self.refAudioPath = refAudioPath; self.refText = refText
        self.temperature = temperature; self.exaggeration = exaggeration; self.cfgWeight = cfgWeight
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
    case languageProviderUnavailable
}

/// Pure translation from user request to provider request, with validation.
enum RequestPlanner {
    static func plan(backend: BackendID, request: SynthesisRequest) throws -> ProviderRequest {
        guard request.speed > 0 else { throw EngineError.invalidSpeed(request.speed) }
        let spec = backend.spec
        let controls = backend.controls
        // Reference voice is only meaningful for clone-capable backends; for
        // voiceClone == .none (qwen3-design/custom) drop it so the model never
        // takes the clone path and ignores a required instruct.
        let allowsClone = controls.voiceClone != .none
        let refAudioPath = allowsClone ? request.refAudioPath : nil
        let refText = allowsClone ? request.refText : nil
        let hasRef = refAudioPath != nil

        if spec.needsRefAudio && !hasRef {
            throw EngineError.refAudioRequired(backend)
        }

        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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

        // Emotion resolves to a model-native knob ONLY when the backend's mechanism
        // is the matching live knob — the single source of truth. (Fish is
        // `.inlineMarker`, not a knob: its emotion is injected into `text` below.)
        let emotionExaggeration: Float? =
            backend.emotionMechanism == .liveKnob(.exaggeration) ? request.emotion.chatterboxExaggeration : nil

        // Fish (.inlineMarker): emotion is a leading `[marker]` in the text — its
        // trained control. Inject the requested marker, but never when the text
        // already begins with a `[…]` marker (a client embedding its own wins, so
        // the gloam.fm DJ can drive markers on the fly without double-stacking).
        let plannedText: String = {
            guard backend.emotionMechanism == .inlineMarker,
                  let marker = clean(request.emotionMarker),
                  !request.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            else { return request.text }
            return "[\(marker)] \(request.text)"
        }()

        return ProviderRequest(
            text: plannedText,
            refAudioPath: refAudioPath,
            refText: refText,
            temperature: knobs.temperature != nil
                ? request.temperatureOverride
                : nil,
            exaggeration: knobs.exaggeration != nil
                ? (request.exaggerationOverride ?? emotionExaggeration)
                    .map { min(request.exaggerationCeiling ?? .greatestFiniteMagnitude, $0) }
                : nil,
            cfgWeight: knobs.cfgWeight != nil ? request.cfgWeight : nil,
            instruct: instruct,
            speaker: speaker,
            language: language,
            topP: knobs.topP != nil ? request.topP : nil,
            topK: knobs.topK != nil ? request.topK : nil,
            repetitionPenalty: knobs.repetitionPenalty != nil ? request.repetitionPenalty : nil
        )
    }
}
