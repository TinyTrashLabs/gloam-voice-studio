import Foundation

/// What a host app does that the editor cannot: engine renders, recognition,
/// the consent it owes before a microphone opens. Every member is optional; a
/// section that needs a capability the host did not provide is not drawn.
public struct VoiceEditorCapabilities {
    /// On-device transcription of an audio file (ASR). Absent: "Listen for the
    /// words" and "Transcribe window" are hidden, a recorded take is trusted to
    /// say the script, and an imported take starts with empty words to type.
    public var transcribe: (@Sendable (URL) async throws -> String)?
    /// "Check this voice": test-renders the master (and a noise-cleaned
    /// version of it) the way the voice is used and judges the result.
    /// Absent: the row is hidden.
    public var voiceCheck: VoiceCheckCapability?
    /// Recording a take with the microphone. False hides "Record another
    /// take", "Record a take" and "Add emotion version…".
    public var canRecord = true
    /// Asked once before a microphone or a file importer opens for a take.
    public var consent: ConsentGate?
    /// "this phone" in the editor's copy; "this Mac" on a Mac host.
    public var deviceNoun = "this phone"

    public init(transcribe: (@Sendable (URL) async throws -> String)? = nil,
                voiceCheck: VoiceCheckCapability? = nil,
                canRecord: Bool = true,
                consent: ConsentGate? = nil,
                deviceNoun: String = "this phone") {
        self.transcribe = transcribe
        self.voiceCheck = voiceCheck
        self.canRecord = canRecord
        self.consent = consent
        self.deviceNoun = deviceNoun
    }

    public static let none = VoiceEditorCapabilities(canRecord: false)
}

/// The engine half of "Check this voice". The editor owns the flow (candidates
/// → scoring → the person's pick); the host owns the engine.
public struct VoiceCheckCapability {
    /// Bring the render engine up (the Studio app activates its ONNX engine).
    public var prepare: @Sendable () async -> Void
    /// The original master, plus a noise-cleaned version when the take's noise
    /// makes one worth offering and the host ships a denoiser.
    public var candidates: @Sendable (_ master: URL, _ transcript: String, _ quality: RecordingCheck.Quality) async
        -> [ReferenceCandidate]
    public var renderer: TestRenderer
    public var checker: PartChecker
    /// Name of the engine that rendered, stored with the verdict.
    public var engineName: @Sendable () -> String

    public init(prepare: @escaping @Sendable () async -> Void,
                candidates: @escaping @Sendable (URL, String, RecordingCheck.Quality) async -> [ReferenceCandidate],
                renderer: TestRenderer, checker: PartChecker,
                engineName: @escaping @Sendable () -> String) {
        self.prepare = prepare; self.candidates = candidates
        self.renderer = renderer; self.checker = checker; self.engineName = engineName
    }
}

/// A one-time question a host asks before audio is added to a voice (the
/// Studio app's "whose voice is this?"). Headless: the editor asks
/// `isRequired`, and carries on only once the person agreed, at which point
/// it calls `accept` so the host can record that. How the question is put is
/// the app's screen (GloamVoiceUI's `VoiceEditorHost.consentSheet`).
public struct ConsentGate {
    public var isRequired: @MainActor () -> Bool
    /// The person agreed. A host whose own consent screen already records
    /// the answer leaves this empty.
    public var accept: @MainActor () -> Void

    public init(isRequired: @escaping @MainActor () -> Bool,
                accept: @escaping @MainActor () -> Void = {}) {
        self.isRequired = isRequired
        self.accept = accept
    }
}
