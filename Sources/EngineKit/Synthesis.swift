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

    public init(text: String, refAudioPath: String? = nil, refText: String? = nil,
                emotion: Emotion = .neutral, speed: Float = 1.0,
                temperatureOverride: Float? = nil, exaggerationOverride: Float? = nil) {
        self.text = text
        self.refAudioPath = refAudioPath
        self.refText = refText
        self.emotion = emotion
        self.speed = speed
        self.temperatureOverride = temperatureOverride
        self.exaggerationOverride = exaggerationOverride
    }
}

/// What the model provider receives — emotion already resolved to knobs.
public struct ProviderRequest: Sendable, Equatable {
    public var text: String
    public var refAudioPath: String?
    public var refText: String?
    /// Fish only: sampling temperature.
    public var temperature: Float?
    /// Chatterbox (regular) only: emotion exaggeration.
    public var exaggeration: Float?
}

public struct SynthesisResult: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    /// Generation wall-clock seconds (excludes model load).
    public let wallSeconds: Double
}

public enum EngineError: Error, Equatable, Sendable {
    case licenseAckRequired(BackendID)
    case refAudioRequired(BackendID)
    case generationFailed(backend: BackendID, message: String)
    case invalidSpeed(Float)
}

/// Pure translation from user request to provider request, with validation.
enum RequestPlanner {
    static func plan(backend: BackendID, request: SynthesisRequest) throws -> ProviderRequest {
        guard request.speed > 0 else { throw EngineError.invalidSpeed(request.speed) }
        let spec = backend.spec
        if spec.needsRefAudio && request.refAudioPath == nil {
            throw EngineError.refAudioRequired(backend)
        }
        return ProviderRequest(
            text: request.text,
            refAudioPath: request.refAudioPath,
            refText: request.refText,
            temperature: spec.honorsTags ? (request.temperatureOverride ?? request.emotion.fishTemperature) : nil,
            exaggeration: backend == .chatterbox ? (request.exaggerationOverride ?? request.emotion.chatterboxExaggeration) : nil
        )
    }
}
