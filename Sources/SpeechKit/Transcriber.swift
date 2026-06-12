import Foundation

/// Result of a batch transcription.
public struct Transcript: Equatable, Sendable {
    public let text: String
    public let language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }
}

/// Live transcription event. A `.partial` replaces the previous partial;
/// a `.final` commits a segment (partials restart after it).
public enum TranscriptUpdate: Equatable, Sendable {
    case partial(String)
    case final(String)
}

public enum SpeechError: Error, LocalizedError, Equatable {
    case notAuthorized
    case engineUnavailable(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission was denied — enable it in System Settings → Privacy & Security."
        case .engineUnavailable(let why):
            return "Speech engine unavailable: \(why)"
        case .transcriptionFailed(let why):
            return "Transcription failed: \(why)"
        }
    }
}

/// A speech-to-text engine. Implementations: AppleTranscriber (on-device,
/// default), WhisperTranscriber (opt-in), FakeTranscriber (tests/UI tests).
public protocol Transcriber: Sendable {
    /// Whole file in, text out.
    func transcribe(audioURL: URL, languageHint: String?) async throws -> Transcript

    /// Mic (or other) audio in, volatile partials + committed finals out.
    /// The stream finishes after the audio stream finishes and the last
    /// final has been emitted.
    func liveTranscribe(audio: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<TranscriptUpdate, Error>
}

public extension Transcriber {
    /// Convenience for in-memory WAV data (e.g. freshly recorded ref clips):
    /// writes a temp file, transcribes, cleans up.
    func transcribe(wavData: Data, languageHint: String? = nil) async throws -> Transcript {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechkit-\(UUID().uuidString).wav")
        try wavData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(audioURL: url, languageHint: languageHint)
    }
}
