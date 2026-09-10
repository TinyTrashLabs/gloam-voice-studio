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
    public static let engineID = "dia2"

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

    /// A Dia2-specific reference and its alignment live together in the pack.
    /// Older packs continue to use the original recording.
    public static func referenceURL(_ slug: String, in library: VoiceLibrary) throws -> URL? {
        let entry = try library.entry(slug)
        return entry.engines[engineID]?["ref.wav"] ?? entry.refURL
    }

    /// What still has to happen before `slug` can condition a Dia2 pass.
    ///
    /// Two things can be missing and they are missing for different reasons, so
    /// the app asks about them as one question and does whichever is needed:
    /// a preset pack has no audio at all (it is a speaker name), while a
    /// recorded voice has audio but no word timings until something aligns it.
    /// `.baked` is the state that must never prompt again.
    public static func readiness(of slug: String, in library: VoiceLibrary) -> Dia2Readiness {
        if let cached = cached(slug, in: library), !cached.isEmpty { return .baked }
        // Nil covers the unknown slug too: nothing to align, and the caller's
        // reference step will report the missing voice properly.
        guard (try? referenceURL(slug, in: library)) ?? nil != nil else { return .needsReference }
        return .needsAlignment
    }

    public static func resolve(_ slug: String, in library: VoiceLibrary,
                               using aligner: any WordAligning) async throws -> [AlignedWord] {
        if let cached = cached(slug, in: library), !cached.isEmpty { return cached }
        guard let refURL = try referenceURL(slug, in: library) else {
            throw Dia2AlignmentError.noReferenceAudio(slug)
        }
        let isDerived = (try? library.entry(slug))?.engines[engineID]?["ref.wav"] != nil
        let transcript = isDerived ? nil : (try? library.meta(slug).refText).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let words = try await aligner.align(audioURL: refURL, transcript: transcript)
        try store(words, for: slug, in: library)
        return words
    }
}


/// What `slug` still needs before Dia2 can speak as it. See
/// `Dia2Alignment.readiness(of:in:)`.
public enum Dia2Readiness: Equatable, Sendable {
    /// Word timings are in the pack. Ready, and never worth asking about.
    case baked
    /// There is a reference clip; it has not been aligned yet.
    case needsAlignment
    /// No reference clip at all — a preset pack. One has to be synthesized
    /// with the voice's own engine before there is anything to align.
    case needsReference
}

public extension Dia2Readiness {
    /// One short line for a voice picker: what picking this voice will cost,
    /// or nil when it costs nothing.
    ///
    /// The two unready states are both pickable and are NOT the same wait —
    /// aligning an existing clip is one Whisper pass, while a preset first has
    /// to have its own engine record a clip (a model swap and a synthesis)
    /// before the aligning starts. Copy lives here rather than in the view so
    /// every surface that offers the pick describes it identically.
    var setupHint: String? {
        switch self {
        case .baked: nil
        case .needsAlignment: "One-time setup on first use"
        case .needsReference: "One-time setup — records a sample first"
        }
    }
}

/// Where Dia2's word timings come from.
///
/// Deliberately NOT the user's dictation engine. `SpeechManager.makeTranscriber()`
/// honours a preference that defaults to Apple's recognizer, which has no word
/// timings — building the Dia2 aligner from it meant every Dia2 generate failed
/// with the protocol's default "This transcriber does not provide word-level
/// timings" unless the user had happened to switch dictation to Whisper. Dia2
/// names Whisper directly and takes no engine choice at all.
public enum Dia2Aligner {
    public static func make(modelFolder: URL) -> any WordAligning {
        WhisperWordAligner(transcriber: WhisperTranscriber(modelFolder: modelFolder))
    }

    /// Stands in when the Whisper model is not on disk. It fails on use rather
    /// than at construction so the non-throwing callers (the API server's
    /// dependency closure) still get an aligner — one that says what is
    /// actually wrong and what to do about it.
    public static func unavailable(variant: String) -> any WordAligning {
        UnavailableWordAligner(variant: variant)
    }
}

public enum Dia2AlignerError: Error, LocalizedError, Equatable {
    case whisperModelMissing(variant: String)
    public var errorDescription: String? {
        switch self {
        case .whisperModelMissing:
            "Dia needs the Whisper speech model to work out a voice's word timings. "
                + "Download it in Settings → Speech, or use “Bake in Dia compatibility” "
                + "on the voice."
        }
    }
}

private struct UnavailableWordAligner: WordAligning {
    let variant: String
    func align(audioURL: URL, transcript: String?) async throws -> [AlignedWord] {
        throw Dia2AlignerError.whisperModelMissing(variant: variant)
    }
}

/// Word timings from the transcriber SpeechKit already bundles. Kept apart from
/// the protocol so the cache logic stays testable without a model download.
public struct WhisperWordAligner: WordAligning {
    /// Visible so callers can assert WHICH transcriber is doing the aligning:
    /// only Whisper provides word timings, and the Dia2 path is required to
    /// use it regardless of the user's dictation preference.
    public let transcriber: any Transcriber
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
