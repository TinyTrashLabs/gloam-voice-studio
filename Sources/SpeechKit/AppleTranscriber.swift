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
            // Hold the task (and through it the request) until a callback
            // resolves the continuation — an orphaned task can drop its
            // callback and hang the await forever.
            let holder = TaskHolder()
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() {
                        holder.task = nil
                        cont.resume(throwing: SpeechError.transcriptionFailed(
                            error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if resumed.claim() {
                    holder.task = nil
                    cont.resume(returning: Transcript(
                        text: result.bestTranscription.formattedString,
                        language: locale.identifier))
                }
            }
        }
    }

    public func liveTranscribe(audio: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let locale = self.locale
        return AsyncThrowingStream { continuation in
            let recognizer: SFSpeechRecognizer
            do { recognizer = try makeRecognizer(locale: locale) }
            catch { continuation.finish(throwing: error); return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true

            // Once a final result (or genuine failure) has settled the
            // stream, late SFSpeech callbacks (e.g. the cancellation-
            // flavored error after endAudio) must be dropped.
            let settled = ResumeGuard()
            let holder = TaskHolder()
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if settled.claim() {
                        continuation.finish(throwing: SpeechError.transcriptionFailed(
                            error.localizedDescription))
                    }
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    if settled.claim() {
                        continuation.yield(.final(result.bestTranscription.formattedString))
                        continuation.finish()
                    }
                } else {
                    continuation.yield(.partial(result.bestTranscription.formattedString))
                }
            }

            let feeder = Task {
                for await chunk in audio {
                    if let buffer = chunk.pcmBuffer() { request.append(buffer) }
                }
                request.endAudio()
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                holder.task?.cancel()
                holder.task = nil
            }
        }
    }

    private func makeRecognizer(locale: Locale) throws -> SFSpeechRecognizer {
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

/// Keeps an SFSpeechRecognitionTask alive until its callback resolves.
final class TaskHolder: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
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
