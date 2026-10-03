import Foundation

/// Result of a vocal separation operation.
///
/// Contains URLs to the separated audio files, timing information,
/// and performance metrics.
///
/// ```swift
/// let result = try await separator.separateVocals(from: inputURL, to: outputURL)
/// print("Vocals at: \(result.vocalsURL)")
/// print("Processing took \(result.processingTime)s (\(result.realtimeFactor)x realtime)")
/// ```
public struct StemResult: Sendable {

    /// URL to the separated vocals WAV file.
    public let vocalsURL: URL

    /// URL to the accompaniment (everything except vocals) WAV file.
    public let accompanimentURL: URL

    /// Sample rate of the output files (Hz).
    public let sampleRate: Double

    /// Duration of the source audio in seconds.
    public let durationSeconds: Double

    /// Total processing time in milliseconds (includes I/O and inference).
    public let inferenceTimeMs: Double

    // MARK: - Convenience Properties

    /// URL to the primary output file (same as ``vocalsURL``).
    ///
    /// Provided for semantic clarity when using the result generically.
    public var outputURL: URL { vocalsURL }

    /// Total processing time in seconds.
    ///
    /// Equivalent to ``inferenceTimeMs`` / 1000.
    public var processingTime: Double { inferenceTimeMs / 1000.0 }

    /// Real-time factor: how many times faster than real-time.
    ///
    /// Values greater than 1.0 indicate faster-than-realtime processing.
    /// For example, a value of 10.0 means a 60-second song was processed in 6 seconds.
    public var realtimeFactor: Double {
        guard inferenceTimeMs > 0 else { return 0 }
        return (durationSeconds * 1000.0) / inferenceTimeMs
    }
}

// MARK: - Backward Compatibility

/// Deprecated: Use ``StemResult`` instead.
@available(*, deprecated, renamed: "StemResult")
public typealias SeparationOutput = StemResult
