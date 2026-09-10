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

    /// Evenly spaced word timings over the batch transcript.
    ///
    /// The fake stands in for a real transcriber in unit tests and in the
    /// app's UI-test mode, and Dia2 conditioning is built from word timings —
    /// so without this every fake-backed Dia2 path fell through to the
    /// protocol default and threw `wordTimingsUnavailable`. The spacing is
    /// arbitrary but deterministic: what callers exercise is the shape.
    public func transcribeWords(audioURL: URL,
                                languageHint: String? = nil) async throws -> [WordTiming] {
        batchResult.split(separator: " ").enumerated().map { index, word in
            WordTiming(text: String(word),
                       start: Double(index) * 0.5, end: Double(index) * 0.5 + 0.4)
        }
    }
}
