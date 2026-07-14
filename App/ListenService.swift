import Foundation
import SpeechKit

/// One-shot spoken-utterance capture behind the local API's `listen` tool.
/// Opens the mic, transcribes live with the app's chosen SpeechKit engine, and
/// returns the joined transcript once the speaker pauses for `silenceSeconds`
/// (after saying something) or `maxSeconds` elapses. The server's RequestGate
/// serializes calls, so only one capture — and one microphone — is ever live.
@MainActor
final class ListenService {
    /// In-flight turn state. Safe as instance state because RequestGate admits
    /// one `listen` at a time; both the consumer loop and the watchdog run on
    /// the main actor, so reads/writes never race.
    private var committed = ""
    private var lastActivity = ContinuousClock.now

    func listen(speech: SpeechManager,
                maxSeconds: Double,
                silenceSeconds: Double,
                language: String?) async throws -> String {
        guard await speech.ensureAuthorized() else { throw SpeechError.notAuthorized }

        let mic = MicCapture()
        let audio: AsyncStream<AudioChunk>
        do {
            audio = try mic.start()
        } catch {
            throw (error as? SpeechError) ?? SpeechError.engineUnavailable("\(error)")
        }

        committed = ""
        lastActivity = ContinuousClock.now
        let start = lastActivity
        let transcriber = speech.makeTranscriber()

        // Ends the turn: finishing the mic stream lets the transcriber flush its
        // final(s), which stops the consumer loop below. Fires on trailing
        // silence after speech, or the hard cap.
        let watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let now = ContinuousClock.now
                let hitCap = start.duration(to: now) >= .seconds(maxSeconds)
                let wentQuiet = !self.committed.isEmpty
                    && self.lastActivity.duration(to: now) >= .seconds(silenceSeconds)
                if hitCap || wentQuiet {
                    mic.stop()
                    return
                }
            }
        }
        defer { watchdog.cancel(); mic.stop() }

        do {
            for try await update in transcriber.liveTranscribe(audio: audio) {
                switch update {
                case .final(let text) where !text.isEmpty:
                    committed = committed.isEmpty ? text : committed + " " + text
                    lastActivity = ContinuousClock.now
                case .partial:
                    lastActivity = ContinuousClock.now
                case .final:
                    break
                }
            }
        } catch is CancellationError {
            // Superseded/cancelled: return whatever committed so far.
        }
        return committed
    }
}
