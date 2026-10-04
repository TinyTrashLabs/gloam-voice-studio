import Foundation
import VoiceFXKit

/// What callers (UI, API server) ask for.
public struct SynthesisRequest: Sendable, Equatable {
    public var text: String
    public var refAudioPath: String?
    public var refText: String?
    public var emotion: Emotion
    /// Named expression (e.g. "whisper"). Fish (`.inlineMarker`): rendered as a
    /// leading `[marker]`, not injected if `text` already begins with one.
    /// Breeze (`.directed`): phrased into the instruction (`DeliveryDirection`).
    /// nil = none. Ignored by other backends.
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
    /// Baked per-voice style file from a .gvoice pack's engine rendition
    /// (supertonic: {style_ttl, style_dp} .json). When set on a preset-style
    /// backend it IS the voice — `speaker` is not required. Ignored by
    /// backends without preset styles.
    public var styleURL: URL?
    /// Language hint ("auto" or one of the 10 languages); nil = auto.
    public var language: String?
    /// Qwen sampling overrides (nil = model default).
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?
    /// LuxTTS flow-matching sampling steps override (nil = model default 4).
    public var numStepsOverride: Int?
    /// LuxTTS classifier-free guidance scale override (nil = model default 3.0).
    public var guidanceScaleOverride: Float?
    /// LuxTTS sampling-schedule shift override (nil = model default 0.5).
    public var tShiftOverride: Float?
    /// LuxTTS dual-path 48k output toggle override (nil = model default true).
    public var returnSmoothOverride: Bool?
    /// Breeze classifier-free guidance scale for instructed takes (nil = model
    /// default 4; 1 = off). Honored where `Knobs.cfgScale` is offered.
    public var cfgScaleOverride: Float?
    /// Breeze identity strength: guidance toward the reference voice (nil or 1 =
    /// off). Honored where `Knobs.referenceGuidance` is offered.
    public var referenceGuidanceOverride: Float?
    /// Fixed sampling seed (nil = fresh randomness every take). Honored where
    /// `Knobs.seed` is offered.
    public var seed: UInt64?
    /// Dia2 only: the selected voice's word-aligned conditioning prefix.
    ///
    /// Dia2 does not clone from `refAudioPath` — it conditions on a prefix whose
    /// words carry timings, which only the caller can build (it needs the word
    /// aligner, and EngineKit has no transcriber). Present means "speak as this
    /// voice"; nil means an unconditioned pass, which is a usable read but not
    /// anybody's voice in particular.
    public var dialoguePrefix: DialoguePrefix?
    /// Character-voice effects to apply after generation. nil = untouched
    /// audio, today's behaviour. Applied post-`SpeedAdjust` so a preset's
    /// tuning is not silently altered by an unrelated `speed` value.
    public var fx: FXPreset?
    /// qwen3-0.6b-ane streaming only: frames (80 ms each, 1...12) in the first vocoder chunk. nil = the default 12.
    /// A smaller first chunk puts the first audio out sooner (4 saves about half a second) but leaves less audio
    /// buffered ahead of playback, so the stream only plays without gaps while the render stays faster than real
    /// time. The samples are the same up to Neural Engine rounding (below -40 dBFS).
    public var firstChunkFrames: Int?

    public init(text: String, refAudioPath: String? = nil, refText: String? = nil,
                emotion: Emotion = .neutral, emotionMarker: String? = nil, speed: Float = 1.0,
                temperatureOverride: Float? = nil, exaggerationOverride: Float? = nil,
                cfgWeight: Float? = nil, exaggerationCeiling: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, styleURL: URL? = nil,
                language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil,
                numStepsOverride: Int? = nil, guidanceScaleOverride: Float? = nil,
                tShiftOverride: Float? = nil, returnSmoothOverride: Bool? = nil,
                cfgScaleOverride: Float? = nil,
                referenceGuidanceOverride: Float? = nil, seed: UInt64? = nil,
                dialoguePrefix: DialoguePrefix? = nil,
                fx: FXPreset? = nil,
                firstChunkFrames: Int? = nil) {
        self.firstChunkFrames = firstChunkFrames
        self.dialoguePrefix = dialoguePrefix
        self.fx = fx
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
        self.styleURL = styleURL
        self.language = language
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.numStepsOverride = numStepsOverride
        self.guidanceScaleOverride = guidanceScaleOverride
        self.tShiftOverride = tShiftOverride
        self.returnSmoothOverride = returnSmoothOverride
        self.cfgScaleOverride = cfgScaleOverride
        self.referenceGuidanceOverride = referenceGuidanceOverride
        self.seed = seed
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
    /// Natural-language direction (Qwen Design/Custom; Breeze, where it may
    /// also accompany a reference voice — see `BackendID.instructDirectsClone`).
    public var instruct: String?
    /// Qwen CustomVoice preset speaker.
    public var speaker: String?
    /// Supertonic only: baked custom style file standing in for a preset.
    public var styleURL: URL?
    /// Qwen language hint (nil = auto).
    public var language: String?
    /// Qwen sampling overrides.
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?
    /// LuxTTS only. Non-nil means the provider must apply speed natively (the
    /// flow-matching duration conditioning, not a post-hoc resample) — when set,
    /// GloamEngine skips its generic `SpeedAdjust.apply` for this call so speed
    /// isn't applied twice.
    public var speed: Float?
    /// LuxTTS only: flow-matching sampling steps (nil = model default 4).
    public var numSteps: Int?
    /// LuxTTS only: classifier-free guidance scale (nil = model default 3.0).
    public var guidanceScale: Float?
    /// LuxTTS only: sampling-schedule shift (nil = model default 0.5).
    public var tShift: Float?
    /// LuxTTS only: dual-path 48k output toggle (nil = model default true).
    public var returnSmooth: Bool?
    /// qwen3-0.6b-ane only: frames in the first streamed vocoder chunk (nil = 12).
    public var firstChunkFrames: Int?
    /// Breeze only: classifier-free guidance scale (nil = model default 4).
    public var cfgScale: Float?
    /// Breeze only: identity strength (nil = off).
    public var referenceGuidance: Float?
    /// Fixed sampling seed (nil = random).
    public var seed: UInt64?

    public init(text: String, refAudioPath: String? = nil, refText: String? = nil,
                temperature: Float? = nil, exaggeration: Float? = nil, cfgWeight: Float? = nil,
                instruct: String? = nil, speaker: String? = nil, styleURL: URL? = nil,
                language: String? = nil,
                topP: Float? = nil, topK: Int? = nil, repetitionPenalty: Float? = nil,
                speed: Float? = nil, numSteps: Int? = nil, guidanceScale: Float? = nil,
                tShift: Float? = nil, returnSmooth: Bool? = nil, cfgScale: Float? = nil,
                referenceGuidance: Float? = nil, seed: UInt64? = nil, firstChunkFrames: Int? = nil) {
        self.firstChunkFrames = firstChunkFrames
        self.text = text; self.refAudioPath = refAudioPath; self.refText = refText
        self.temperature = temperature; self.exaggeration = exaggeration; self.cfgWeight = cfgWeight
        self.instruct = instruct; self.speaker = speaker; self.styleURL = styleURL
        self.language = language
        self.topP = topP; self.topK = topK; self.repetitionPenalty = repetitionPenalty
        self.speed = speed; self.numSteps = numSteps; self.guidanceScale = guidanceScale
        self.tShift = tShift; self.returnSmooth = returnSmooth
        self.cfgScale = cfgScale
        self.referenceGuidance = referenceGuidance; self.seed = seed
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

/// One independently playable piece of a streamed synthesis result.
public struct SynthesisChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
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
    /// The backend's model files are not on this machine and cannot be downloaded in-app.
    case modelNotInstalled(backend: BackendID, detail: String)
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let backend, let detail):
            return "\(backend.rawValue) is not installed: \(detail)"
        default:
            return nil
        }
    }
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
        // the clone path, so the plan drops it to stay honest. The exception is a
        // backend whose clone path takes the instruct too (Breeze's "voice
        // direction"), where dropping it would discard the user's Direction.
        let instructSurvivesClone = !(controls.voiceClone != .none && hasRef)
            || backend.instructDirectsClone
        let wantsInstruct = controls.instruct != .none && instructSurvivesClone
        // `.directed` (Breeze): the emotion picker and any expression are
        // phrased into the instruction after the user's own Direction — that
        // instruction IS the model's emotion control.
        let instruct: String? = {
            guard wantsInstruct else { return nil }
            guard backend.emotionMechanism == .directed else { return clean(request.instruct) }
            return DeliveryDirection.compose(direction: clean(request.instruct),
                                             expression: clean(request.emotionMarker),
                                             emotion: request.emotion)
        }()
        if controls.instruct == .required && instruct == nil {
            throw EngineError.instructRequired(backend)
        }

        // Speaker: CustomVoice/Kokoro only; required, and must be a name the
        // backend actually recognizes. A stale speaker from a previously
        // active backend (e.g. app-launch restore, where AppModel.backend's
        // didSet never fires during init and so never gets a chance to reset
        // it; or a chat "Regenerate with…" override, which bypasses the
        // Studio bench's own reset entirely) must fail loudly here instead of
        // reaching the model with an invalid voicepack/name.
        // A baked style file (a .gvoice pack's supertonic rendition) IS the
        // voice on a preset-style backend, so it stands in for the speaker.
        let styleURL = controls.presetSpeakers.isEmpty ? nil : request.styleURL
        let cleanedSpeaker = controls.presetSpeakers.isEmpty ? nil : clean(request.speaker)
        let speaker = cleanedSpeaker.flatMap { controls.presetSpeakers.contains($0) ? $0 : nil }
        if !controls.presetSpeakers.isEmpty && speaker == nil && styleURL == nil {
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
            // The baked style wins over a (possibly stale) preset name.
            speaker: styleURL == nil ? speaker : nil,
            styleURL: styleURL,
            language: language,
            topP: knobs.topP != nil ? request.topP : nil,
            topK: knobs.topK != nil ? request.topK : nil,
            repetitionPenalty: knobs.repetitionPenalty != nil ? request.repetitionPenalty : nil,
            // LuxTTS's native speed reuses the generic `request.speed` slider value
            // (same user-facing knob, backend-native implementation instead of a
            // post-hoc resample) — see GloamEngine.performSynthesis for the other
            // half of this (skipping SpeedAdjust when this is non-nil).
            speed: knobs.speed != nil ? request.speed : nil,
            numSteps: knobs.numSteps != nil ? request.numStepsOverride : nil,
            guidanceScale: knobs.guidanceScale != nil ? request.guidanceScaleOverride : nil,
            tShift: knobs.tShift != nil ? request.tShiftOverride : nil,
            returnSmooth: knobs.returnSmooth != nil
                ? (request.returnSmoothOverride ?? knobs.returnSmooth) : nil,
            // Clamped to the offered range: a 0 or negative scale from an API
            // caller would steer AWAY from the instruction.
            cfgScale: knobs.cfgScale.flatMap { range in
                request.cfgScaleOverride.map { min(max($0, range.lowerBound), range.upperBound) }
            },
            // Clamped the same way; 1 (the floor) is "off", so it is dropped
            // rather than sent as a guidance pass that changes nothing.
            referenceGuidance: knobs.referenceGuidance.flatMap { range in
                request.referenceGuidanceOverride
                    .map { min(max($0, range.lowerBound), range.upperBound) }
                    .flatMap { $0 > 1 ? $0 : nil }
            },
            seed: knobs.seed == true ? request.seed : nil,
            firstChunkFrames: backend == .qwen06BANE ? request.firstChunkFrames.map { min(12, max(1, $0)) } : nil
        )
    }
}
