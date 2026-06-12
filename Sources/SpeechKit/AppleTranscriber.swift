import Foundation
import Speech

/// On-device transcription via SFSpeechRecognizer. The default engine —
/// zero extra downloads, audio never leaves the Mac
/// (`requiresOnDeviceRecognition` is always set).
public final class AppleTranscriber: Transcriber, @unchecked Sendable {
    private let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Must be called from UI before first use; returns whether authorized.
    public static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    public func transcribe(audioURL: URL, languageHint: String?) async throws -> Transcript {
        let locale = languageHint.map(Locale.init(identifier:)) ?? self.locale
        let recognizer = try makeRecognizer(locale: locale)
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // recognitionTask may call back more than once; resume exactly once.
        let resumed = ResumeGuard()
        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() {
                        cont.resume(throwing: SpeechError.transcriptionFailed(
                            error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if resumed.claim() {
                    cont.resume(returning: Transcript(
                        text: result.bestTranscription.formattedString,
                        language: locale.identifier))
                }
            }
        }
    }

    public func liveTranscribe(audio: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<TranscriptUpdate, Error> {
        // Implemented in the next task.
        AsyncThrowingStream { $0.finish(throwing: SpeechError.engineUnavailable(
            "live transcription not implemented yet")) }
    }

    func makeRecognizer(locale: Locale) throws -> SFSpeechRecognizer {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw SpeechError.engineUnavailable(
                "no recognizer for \(locale.identifier)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.engineUnavailable(
                "on-device recognition not supported for \(locale.identifier) — "
                + "add the language under System Settings → Keyboard → Dictation")
        }
        return recognizer
    }
}

/// Tiny lock so completion-handler APIs resume a continuation exactly once.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
