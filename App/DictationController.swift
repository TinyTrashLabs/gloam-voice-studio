import Foundation
import Observation
import SpeechKit

/// One live dictation session bound to a text target. Streams partials into
/// the text (appended at the end; committed on finals), so the user sees
/// words appear as they speak. Whisper engine emits no partials — text
/// arrives when the user stops.
@MainActor @Observable
final class DictationController {
    private(set) var isActive = false
    private(set) var errorMessage: String?

    private var mic: MicCapture?
    private var uiTestContinuation: AsyncStream<AudioChunk>.Continuation?
    private var task: Task<Void, Never>?
    private var committedText = ""
    private var setText: ((String) -> Void)?

    func toggle(speech: SpeechManager,
                getText: @escaping () -> String,
                setText: @escaping (String) -> Void) {
        isActive ? stop() : start(speech: speech, getText: getText, setText: setText)
    }

    private func start(speech: SpeechManager,
                       getText: @escaping () -> String,
                       setText: @escaping (String) -> Void) {
        errorMessage = nil
        self.setText = setText
        let base = getText()
        committedText = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n")
            ? base : base + " "
        isActive = true
        task = Task { @MainActor in
            guard await speech.ensureAuthorized() else {
                fail("Speech permission denied."); return
            }
            let audio: AsyncStream<AudioChunk>
            if UITestMode.isActive {
                // Headless runners have no microphone; FakeTranscriber only
                // needs the stream to finish, which stop() does.
                let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self)
                self.uiTestContinuation = cont
                audio = stream
            } else {
                let mic = MicCapture()
                self.mic = mic
                do { audio = try mic.start() }
                catch {
                    fail((error as? SpeechError)?.errorDescription ?? "\(error)")
                    return
                }
            }
            let transcriber = speech.makeTranscriber()
            do {
                for try await update in transcriber.liveTranscribe(audio: audio) {
                    switch update {
                    case .partial(let text):
                        self.setText?(self.committedText + text)
                    case .final(let text):
                        self.committedText += text
                        self.setText?(self.committedText)
                    }
                }
            } catch {
                fail((error as? SpeechError)?.errorDescription ?? "\(error)")
                return
            }
            self.finishCleanly()
        }
    }

    func stop() {
        // Finishing the audio stream lets the engine emit its final(s);
        // the task ends on its own once the transcriber stream finishes.
        mic?.stop()
        mic = nil
        uiTestContinuation?.finish()
        uiTestContinuation = nil
        isActive = false
    }

    private func finishCleanly() {
        mic?.stop()
        mic = nil
        uiTestContinuation?.finish()
        uiTestContinuation = nil
        isActive = false
        task = nil
        setText = nil
    }

    private func fail(_ message: String) {
        errorMessage = message
        finishCleanly()
    }
}
