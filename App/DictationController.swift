import Foundation
import Observation
import SpeechKit

/// One live dictation session bound to a text target. Streams partials into
/// the text (appended at the end; committed on finals). Whisper emits no
/// partials — its text arrives after stop(), while `isProcessing` is true.
@MainActor @Observable
final class DictationController {
    private(set) var isActive = false      // mic open
    private(set) var isProcessing = false  // stopped, final text still pending
    private(set) var errorMessage: String?

    private var mic: MicCapture?
    private var uiTestContinuation: AsyncStream<AudioChunk>.Continuation?
    private var task: Task<Void, Never>?
    private var session = UUID()

    func toggle(speech: SpeechManager,
                getText: @escaping () -> String,
                setText: @escaping (String) -> Void) {
        isActive ? stop() : start(speech: speech, getText: getText, setText: setText)
    }

    private func start(speech: SpeechManager,
                       getText: @escaping () -> String,
                       setText: @escaping (String) -> Void) {
        // Restarting drops any still-draining previous session — its pending
        // final would otherwise race the new session on the same field.
        task?.cancel()
        mic?.stop(); mic = nil
        uiTestContinuation?.finish(); uiTestContinuation = nil

        let token = UUID()
        session = token
        errorMessage = nil
        isActive = true
        isProcessing = false
        let base = getText()
        task = Task { @MainActor in
            // Session-local text state: a later session can never cross wires.
            // Separators are added lazily by joined(_:), so committed is the
            // base text untouched until the first utterance lands.
            var committed = base
            guard await speech.ensureAuthorized() else {
                self.fail("Speech permission denied.", token: token); return
            }
            let audio: AsyncStream<AudioChunk>
            if UITestMode.isActive {
                // Headless runners have no microphone; FakeTranscriber only
                // needs the stream to finish, which stop() does.
                let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self)
                if self.session == token { self.uiTestContinuation = cont }
                else { cont.finish() }
                audio = stream
            } else {
                let mic = MicCapture()
                do {
                    audio = try mic.start()
                    if self.session == token { self.mic = mic } else { mic.stop() }
                } catch {
                    self.fail((error as? SpeechError)?.errorDescription ?? "\(error)",
                              token: token)
                    return
                }
            }
            let transcriber = speech.makeTranscriber()
            do {
                // Utterance commits arrive as repeated .finals (one per pause)
                // — join them with a space, added lazily so the field never
                // carries a trailing space.
                func joined(_ text: String) -> String {
                    committed.isEmpty || committed.hasSuffix(" ") || committed.hasSuffix("\n")
                        ? text : " " + text
                }
                for try await update in transcriber.liveTranscribe(audio: audio) {
                    switch update {
                    case .partial(let text):
                        setText(committed + joined(text))
                    case .final(let text) where !text.isEmpty:
                        committed += joined(text)
                        setText(committed)
                    case .final:
                        setText(committed)
                    }
                }
            } catch is CancellationError {
                return   // superseded session: drop silently, touch no state
            } catch {
                self.fail((error as? SpeechError)?.errorDescription ?? "\(error)",
                          token: token)
                return
            }
            self.finish(token: token)
        }
    }

    func stop() {
        // Finishing the audio stream lets the engine emit its final(s); the
        // task drains them into the field, then finish(token:) cleans up.
        mic?.stop(); mic = nil
        uiTestContinuation?.finish(); uiTestContinuation = nil
        isActive = false
        isProcessing = task != nil
    }

    /// Hard teardown: no pending final may write into the field afterwards.
    /// Used when the host consumes the text NOW (e.g. chat send fires while
    /// dictating) — a late final would resurrect the already-sent draft.
    func cancel() {
        session = UUID()   // orphan any in-flight session's callbacks
        task?.cancel(); task = nil
        mic?.stop(); mic = nil
        uiTestContinuation?.finish(); uiTestContinuation = nil
        isActive = false
        isProcessing = false
    }

    private func finish(token: UUID) {
        guard session == token else { return }
        isActive = false
        isProcessing = false
        task = nil
    }

    private func fail(_ message: String, token: UUID) {
        guard session == token else { return }
        errorMessage = message
        mic?.stop(); mic = nil
        uiTestContinuation?.finish(); uiTestContinuation = nil
        isActive = false
        isProcessing = false
        task = nil
    }
}
