import SpeechKit
import Foundation
import EngineKit

public struct AlignedWord: Codable, Equatable, Sendable {
    public let w: String
    public let start: Double
    public let end: Double
    public init(w: String, start: Double, end: Double) {
        self.w = w; self.start = start; self.end = end
    }
}

/// Word-level alignment. The real implementation wraps WhisperKit; tests use a
/// fake, so the cache logic is testable without a model download.
public protocol WordAligning: Sendable {
    func align(audioURL: URL, transcript: String?) async throws -> [AlignedWord]
}

public enum Dia2AlignmentError: Error, LocalizedError {
    case noReferenceAudio(String)
    public var errorDescription: String? {
        switch self {
        case .noReferenceAudio(let slug):
            "“\(slug)” has no recorded reference, so Dia2 can't use it as a voice. "
                + "Record or import a clip, or generate without a voice."
        }
    }
}

/// Word timings for a pack's reference clip, cached inside the pack.
///
/// The cache doubles as the pack's Dia2 rendition: writing it into
/// `engines/dia2/` is what makes `capabilities()` report Dia2 support, so
/// alignment and capability can never disagree.
public enum Dia2Alignment {
    static let fileName = "alignment.json"
    static let engineID = "dia2"

    static func url(_ slug: String, in library: VoiceLibrary) -> URL {
        library.directory
            .appendingPathComponent(slug)
            .appendingPathComponent("engines/\(engineID)")
            .appendingPathComponent(fileName)
    }

    public static func cached(_ slug: String, in library: VoiceLibrary) -> [AlignedWord]? {
        guard let data = try? Data(contentsOf: url(slug, in: library)) else { return nil }
        // A corrupt file is not an error: realigning is cheap next to failing.
        return try? JSONDecoder().decode([AlignedWord].self, from: data)
    }

    public static func store(_ words: [AlignedWord], for slug: String,
                             in library: VoiceLibrary) throws {
        let destination = url(slug, in: library)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(words).write(to: destination, options: .atomic)
    }

    public static func resolve(_ slug: String, in library: VoiceLibrary,
                               using aligner: any WordAligning) async throws -> [AlignedWord] {
        if let cached = cached(slug, in: library), !cached.isEmpty { return cached }
        guard let refURL = (try? library.entry(slug))?.refURL else {
            throw Dia2AlignmentError.noReferenceAudio(slug)
        }
        let transcript = (try? library.meta(slug).refText).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let words = try await aligner.align(audioURL: refURL, transcript: transcript)
        try store(words, for: slug, in: library)
        return words
    }
}


/// Word timings from the transcriber SpeechKit already bundles. Kept apart from
/// the protocol so the cache logic stays testable without a model download.
public struct WhisperWordAligner: WordAligning {
    private let transcriber: any Transcriber
    public init(transcriber: any Transcriber) { self.transcriber = transcriber }

    public func align(audioURL: URL, transcript: String?) async throws -> [AlignedWord] {
        // `transcript` is the pack's refText. WhisperKit re-recognises rather
        // than force-aligning to it, so the text is advisory here; a mismatch
        // costs accuracy, not correctness.
        _ = transcript
        return try await transcriber.transcribeWords(audioURL: audioURL, languageHint: "en")
            .map { AlignedWord(w: $0.text, start: $0.start, end: $0.end) }
    }
}
