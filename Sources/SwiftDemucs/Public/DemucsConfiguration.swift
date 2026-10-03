import Foundation

/// Configuration for the ``VocalSeparator``.
///
/// Controls chunking behaviour, GPU memory usage, and processing parameters.
/// For most use cases, the ``default`` configuration is recommended:
///
/// ```swift
/// let separator = try await VocalSeparator(
///     weightsDirectory: weightsURL,
///     configuration: .default
/// )
/// ```
///
/// Customise for specific hardware or memory constraints:
/// ```swift
/// let config = DemucsConfiguration(gpuCacheLimit: 256 * 1024 * 1024)
/// let separator = try await VocalSeparator(
///     weightsDirectory: weightsURL,
///     configuration: config
/// )
/// ```
public struct DemucsConfiguration: Sendable {

    /// GPU memory cache limit in bytes. Default: 512 MB.
    public var gpuCacheLimit: Int

    /// Duration of each processing chunk in seconds.
    ///
    /// Longer chunks use more memory but may produce better results at boundaries.
    /// Default: 30 seconds.
    public var chunkDurationSeconds: Double

    /// Overlap between adjacent chunks in seconds for crossfade blending.
    ///
    /// Default: 0.5 seconds.
    public var overlapSeconds: Double

    /// Target sample rate. htdemucs expects 44100 Hz.
    public var sampleRate: Double

    // MARK: - Model Constants (read-only)

    /// FFT window size used by the spectral branch. Always 4096.
    public var nFFT: Int { 4096 }

    /// Hop length (stride) for STFT frames. Always 1024.
    public var hopLength: Int { 1024 }

    /// Number of output sources (stems). Always 4 in htdemucs.
    public var channels: Int { 4 }

    /// Number of cross-transformer layers. Always 5 in htdemucs.
    public var transformerLayers: Int { 5 }

    // MARK: - Defaults

    /// Default configuration suitable for most Apple Silicon hardware.
    ///
    /// - GPU cache: 512 MB
    /// - Chunk duration: 30 s
    /// - Overlap: 0.5 s
    /// - Sample rate: 44100 Hz
    public static let `default` = DemucsConfiguration()

    // MARK: - Initializer

    /// Create a configuration with custom values.
    ///
    /// - Parameters:
    ///   - gpuCacheLimit: GPU memory cache limit in bytes (default: 512 MB).
    ///   - chunkDurationSeconds: Duration of each processing chunk (default: 30 s).
    ///   - overlapSeconds: Overlap between chunks for crossfade (default: 0.5 s).
    ///   - sampleRate: Target sample rate (default: 44100 Hz).
    public init(
        gpuCacheLimit: Int = 512 * 1024 * 1024,
        chunkDurationSeconds: Double = 30.0,
        overlapSeconds: Double = 0.5,
        sampleRate: Double = 44100.0
    ) {
        self.gpuCacheLimit = gpuCacheLimit
        self.chunkDurationSeconds = chunkDurationSeconds
        self.overlapSeconds = overlapSeconds
        self.sampleRate = sampleRate
    }
}

// MARK: - Backward Compatibility

/// Deprecated: Use ``DemucsConfiguration`` instead.
@available(*, deprecated, renamed: "DemucsConfiguration")
public typealias DemucsConfig = DemucsConfiguration
