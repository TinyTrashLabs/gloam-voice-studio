import Foundation

/// Deterministic transcriber for unit tests and the app's --uitest mode.
public struct FakeTranscriber: Transcriber {
    public let batchResult: String
    public let liveUpdates: [TranscriptUpdate]

    public init(batchResult: String = "fake transcript",
                liveUpdates: [TranscriptUpdate] =
                    [.partial("fake"), .final("fake transcript")]) {
        self.batchResult = batchResult
        self.liveUpdates = liveUpdates
    }

    public func transcribe(audioURL: URL, languageHint: String?) async throws -> Transcript {
        Transcript(text: batchResult, language: "en")
    }

    /// NOTE: updates are emitted only after `audio` finishes — callers must
    /// finish the audio stream (stop the mic) or the stream waits forever.
    public func liveTranscribe(audio: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let updates = liveUpdates
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in audio {}          // drain until mic stops
                for update in updates { continuation.yield(update) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
