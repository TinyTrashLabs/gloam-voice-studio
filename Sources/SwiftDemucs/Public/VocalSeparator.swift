import Foundation
import MLX
import MLXNN
import os

/// Main entry point for vocal separation using htdemucs v4.
///
/// Initialize once with a weights directory, then reuse for multiple separations.
/// Three API styles are available:
///
/// ### Async/Await (Recommended)
/// ```swift
/// let separator = try await VocalSeparator(weightsDirectory: weightsURL)
/// let result = try await separator.separateVocals(from: inputURL, to: outputDir)
/// print("Vocals at: \(result.vocalsURL)")
/// ```
///
/// ### Delegate
/// ```swift
/// separator.delegate = self
/// separator.separateVocals(from: inputURL, to: outputDir)
/// // Receive callbacks via DemucsProgressDelegate
/// ```
///
/// ### AsyncThrowingStream
/// ```swift
/// for try await progress in separator.separationStream(from: inputURL, to: outputDir) {
///     print("\(progress.stage): \(Int(progress.fraction * 100))%")
/// }
/// ```
public final class VocalSeparator: @unchecked Sendable {

    private let model: HTDemucs
    private let audioIO = AudioIO()
    private let configuration: DemucsConfiguration
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Delegate for receiving progress updates and completion events.
    ///
    /// Set this before calling the delegate-based ``separateVocals(from:to:)-swift.method``.
    /// Callbacks are delivered on the main actor.
    @MainActor public weak var delegate: DemucsProgressDelegate?

    // MARK: - Initialization

    /// Initialize the separator by loading model weights from disk.
    ///
    /// Weight loading is performed eagerly — the model is ready to use
    /// immediately after initialization completes.
    ///
    /// - Parameters:
    ///   - weightsDirectory: Directory containing `htdemucs_ft_vocals.safetensors`.
    ///   - configuration: Processing configuration (default: ``DemucsConfiguration/default``).
    /// - Throws: ``DemucsError/weightsNotFound(_:)`` if weights file is missing.
    public init(
        weightsDirectory: URL,
        configuration: DemucsConfiguration = .default
    ) async throws {
        self.configuration = configuration

        // Validate weights directory
        do {
            try WeightLoader.validateWeightsDirectory(weightsDirectory)
        } catch {
            throw DemucsError.weightsNotFound(weightsDirectory.path)
        }

        // Set GPU cache limit
        MLX.Memory.cacheLimit = configuration.gpuCacheLimit

        // Load model
        let model = HTDemucs()
        do {
            try WeightLoader.loadWeights(
                into: model,
                from: weightsDirectory.appendingPathComponent(WeightLoader.vocalsWeightsFile)
            )
        } catch {
            throw DemucsError.weightsNotFound(
                weightsDirectory.appendingPathComponent(WeightLoader.vocalsWeightsFile).path
            )
        }
        MLX.eval(model.parameters())
        self.model = model
    }

    // MARK: - Style 1: Delegate-Based (Fire-and-Forget)

    /// Start vocal separation, delivering progress and completion via ``delegate``.
    ///
    /// This method returns immediately. Progress updates and the final result
    /// (or error) are delivered through the ``DemucsProgressDelegate`` on the
    /// main actor.
    ///
    /// - Parameters:
    ///   - inputURL: Path to the input audio file (WAV, MP3, FLAC, M4A, etc.).
    ///   - outputURL: Directory where output WAV files will be written.
    public func separateVocals(from inputURL: URL, to outputURL: URL) {
        let separator = self
        Task.detached {
            do {
                let result = try await separator.separateCore(
                    from: inputURL,
                    to: outputURL
                ) { progress in
                    Task { @MainActor in
                        separator.delegate?.demucs(
                            separator,
                            didUpdateProgress: progress.fraction,
                            stage: progress.stage
                        )
                    }
                }
                await MainActor.run {
                    separator.delegate?.demucs(
                        separator,
                        didCompleteWithResult: .success(result)
                    )
                }
            } catch let error as DemucsError {
                await MainActor.run {
                    separator.delegate?.demucs(
                        separator,
                        didCompleteWithResult: .failure(error)
                    )
                }
            } catch {
                await MainActor.run {
                    separator.delegate?.demucs(
                        separator,
                        didCompleteWithResult: .failure(.mlxInferenceFailed(error))
                    )
                }
            }
        }
    }

    // MARK: - Style 2: Async/Await (Recommended)

    /// Separate vocals from an audio file.
    ///
    /// This is the recommended API for most use cases. It suspends until
    /// separation is complete and throws on failure or cancellation.
    ///
    /// ```swift
    /// let result = try await separator.separateVocals(from: inputURL, to: outputDir)
    /// print("Vocals: \(result.vocalsURL)")
    /// print("Speed:  \(result.realtimeFactor)x realtime")
    /// ```
    ///
    /// - Parameters:
    ///   - inputURL: Path to the input audio file (WAV, MP3, FLAC, M4A, etc.).
    ///   - outputURL: Directory where output WAV files will be written.
    /// - Returns: ``StemResult`` with URLs to vocals and accompaniment files.
    /// - Throws: ``DemucsError`` on failure or cancellation.
    public func separateVocals(
        from inputURL: URL,
        to outputURL: URL
    ) async throws -> StemResult {
        try await separateCore(from: inputURL, to: outputURL, progressHandler: nil)
    }

    // MARK: - Style 3: AsyncThrowingStream

    /// Stream progress updates during vocal separation.
    ///
    /// Returns an ``AsyncThrowingStream`` that yields ``DemucsProgress`` values
    /// as separation proceeds. The stream finishes when separation completes.
    /// Cancelling iteration (breaking out of `for await`) triggers ``cancel()``.
    ///
    /// ```swift
    /// for try await progress in separator.separationStream(from: inputURL, to: outputDir) {
    ///     progressBar.value = progress.fraction
    ///     stageLabel.text = progress.stage.rawValue
    /// }
    /// // Separation is complete when the loop exits
    /// ```
    ///
    /// - Parameters:
    ///   - inputURL: Path to the input audio file.
    ///   - outputURL: Directory for output files.
    /// - Returns: Stream of ``DemucsProgress`` updates.
    public func separationStream(
        from inputURL: URL,
        to outputURL: URL
    ) -> AsyncThrowingStream<DemucsProgress, Error> {
        let separator = self
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let result = try await separator.separateCore(
                        from: inputURL,
                        to: outputURL
                    ) { progress in
                        continuation.yield(progress)
                    }
                    // Yield final progress at 1.0
                    continuation.yield(
                        DemucsProgress(
                            fraction: 1.0,
                            stage: .writing,
                            elapsedSeconds: result.processingTime
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                separator.cancel()
                task.cancel()
            }
        }
    }

    // MARK: - Raw Samples

    /// Separate vocals from raw audio samples.
    ///
    /// Use this for in-memory processing without file I/O.
    ///
    /// - Parameter samples: Stereo audio as MLXArray of shape `[1, 2, samples]`.
    /// - Returns: Separated vocals as MLXArray of shape `[1, 2, samples]`.
    /// - Throws: ``DemucsError/mlxInferenceFailed(_:)`` on model failure,
    ///           ``DemucsError/cancelled`` if cancelled.
    public func separate(samples: MLXArray) async throws -> MLXArray {
        cancelFlag.withLock { $0 = false }
        let sampleCount = samples.shape[2]
        return try await separateChunked(
            samples,
            sampleCount: sampleCount,
            startTime: CFAbsoluteTimeGetCurrent(),
            progressHandler: nil
        )
    }

    // MARK: - Cancellation

    /// Cancel the current separation operation.
    ///
    /// If a separation is in progress, it will stop at the next cancellation
    /// checkpoint (between chunks or processing stages) and throw
    /// ``DemucsError/cancelled``. No partial output files are written.
    ///
    /// The cancellation flag resets automatically when a new separation begins.
    public func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    // MARK: - Backward Compatibility

    /// Deprecated: Use ``init(weightsDirectory:configuration:)`` instead.
    @available(*, deprecated, renamed: "init(weightsDirectory:configuration:)")
    public convenience init(
        weightsDirectory: URL,
        config: DemucsConfiguration
    ) async throws {
        try await self.init(weightsDirectory: weightsDirectory, configuration: config)
    }

    /// Deprecated: Use ``separateVocals(from:to:)-1loij`` instead.
    @available(*, deprecated, message: "Use separateVocals(from:to:) instead")
    public func separate(
        audioURL: URL,
        outputDirectory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StemResult {
        try await separateCore(from: audioURL, to: outputDirectory) { demucsProgress in
            progress?(Double(demucsProgress.fraction))
        }
    }

    // MARK: - Core Engine (Private)

    /// Core separation pipeline shared by all three API styles.
    ///
    /// Handles the full workflow: audio loading → chunked inference → file output.
    /// Progress is reported through the optional handler with stage-aware fractions.
    private func separateCore(
        from inputURL: URL,
        to outputDirectory: URL,
        progressHandler: (@Sendable (DemucsProgress) -> Void)?
    ) async throws -> StemResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Reset cancellation flag for this new operation
        cancelFlag.withLock { $0 = false }

        // --- Stage: loading (0.00–0.05) ---
        reportProgress(0.0, stage: .loading, startTime: startTime, handler: progressHandler)

        let audio: MLXArray
        let sampleCount: Int
        do {
            (audio, sampleCount) = try audioIO.loadAudio(from: inputURL)
        } catch {
            throw DemucsError.audioReadFailed(error)
        }
        let durationSeconds = Double(sampleCount) / configuration.sampleRate

        try checkCancelled()

        // --- Stages: stft → encoding → transformer → decoding (0.05–0.90) ---
        reportProgress(0.05, stage: .stft, startTime: startTime, handler: progressHandler)

        let vocals: MLXArray
        do {
            vocals = try await separateChunked(
                audio,
                sampleCount: sampleCount,
                startTime: startTime,
                progressHandler: progressHandler
            )
        } catch let error as DemucsError {
            throw error  // Pass through .cancelled and other DemucsErrors
        } catch is CancellationError {
            throw CancellationError()  // Task-cancellation lane: never launder (C13/CAN-2)
        } catch {
            throw DemucsError.mlxInferenceFailed(error)
        }

        try checkCancelled()

        // --- Stage: writing (0.90–1.00) ---
        reportProgress(0.90, stage: .writing, startTime: startTime, handler: progressHandler)

        // Compute accompaniment = mixture - vocals
        let accompaniment = audio - vocals
        MLX.eval(vocals)
        MLX.eval(accompaniment)

        // Create output directory
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DemucsError.outputWriteFailed(error)
        }

        // Save output files
        let vocalsURL = outputDirectory.appendingPathComponent("vocals.wav")
        let accompanimentURL = outputDirectory.appendingPathComponent("accompaniment.wav")

        do {
            try audioIO.saveAudio(vocals, to: vocalsURL, sampleRate: configuration.sampleRate)
            try audioIO.saveAudio(
                accompaniment,
                to: accompanimentURL,
                sampleRate: configuration.sampleRate
            )
        } catch {
            throw DemucsError.outputWriteFailed(error)
        }

        let inferenceTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        reportProgress(1.0, stage: .writing, startTime: startTime, handler: progressHandler)

        return StemResult(
            vocalsURL: vocalsURL,
            accompanimentURL: accompanimentURL,
            sampleRate: configuration.sampleRate,
            durationSeconds: durationSeconds,
            inferenceTimeMs: inferenceTimeMs
        )
    }

    // MARK: - Chunked Processing (Private)

    /// Process audio in chunks with overlap-add for memory efficiency.
    ///
    /// For audio shorter than one chunk, processes in a single pass.
    /// For longer audio, uses overlapping windows with crossfade blending.
    private func separateChunked(
        _ audio: MLXArray,
        sampleCount: Int,
        startTime: CFAbsoluteTime,
        progressHandler: (@Sendable (DemucsProgress) -> Void)?
    ) async throws -> MLXArray {
        let chunkSamples = Int(configuration.chunkDurationSeconds * configuration.sampleRate)
        let overlapSamples = Int(configuration.overlapSeconds * configuration.sampleRate)

        // Single-chunk fast path
        if sampleCount <= chunkSamples {
            try checkCancelled()
            reportProgress(0.25, stage: .transformer, startTime: startTime, handler: progressHandler)

            let result = model(audio)
            MLX.eval(result)

            reportProgress(0.85, stage: .decoding, startTime: startTime, handler: progressHandler)
            return result
        }

        // Multi-chunk overlap-add
        let stepSize = chunkSamples - overlapSamples
        var output = MLXArray.zeros(like: audio)
        var totalWeight = MLXArray.zeros([1, 1, sampleCount], dtype: .float32)

        // Crossfade windows
        let fadeLength = overlapSamples
        let fadeIn = MLXArray(
            (0..<fadeLength).map { Float($0) / Float(fadeLength) }
        )
        let fadeOut = 1.0 - fadeIn

        var offset = 0
        var chunkIndex = 0
        let totalChunks = (sampleCount + stepSize - 1) / stepSize

        while offset < sampleCount {
            try checkCancelled()

            let end = min(offset + chunkSamples, sampleCount)
            let chunk = audio[0..., 0..., offset..<end]

            // Pad short final chunk
            let chunkLength = end - offset
            let processChunk: MLXArray
            if chunkLength < chunkSamples {
                let padAmount = chunkSamples - chunkLength
                let pad = MLXArray.zeros([1, 2, padAmount], dtype: audio.dtype)
                processChunk = concatenated([chunk, pad], axis: 2)
            } else {
                processChunk = chunk
            }

            // Report stage-aware progress (0.05–0.90 range)
            let chunkFraction = Float(chunkIndex) / Float(totalChunks)
            let overallFraction = 0.05 + chunkFraction * 0.85
            let stage = stageForFraction(overallFraction)
            reportProgress(overallFraction, stage: stage, startTime: startTime, handler: progressHandler)

            // Model inference
            var separated = model(processChunk)
            MLX.eval(separated)

            // Trim padding
            if chunkLength < chunkSamples {
                separated = separated[0..., 0..., ..<chunkLength]
            }

            // Build weight window with crossfade at boundaries
            var weight = MLXArray.ones([1, 1, chunkLength])

            if offset > 0 && fadeLength <= chunkLength {
                let fadeInExpanded = fadeIn[..<min(fadeLength, chunkLength)]
                    .reshaped([1, 1, -1])
                let onesRest = MLXArray.ones([1, 1, chunkLength - fadeLength])
                weight = concatenated([fadeInExpanded, onesRest], axis: 2)
            }
            if end < sampleCount && fadeLength <= chunkLength {
                let onesStart = MLXArray.ones([1, 1, chunkLength - fadeLength])
                let fadeOutExpanded = fadeOut[..<min(fadeLength, chunkLength)]
                    .reshaped([1, 1, -1])
                weight = weight * concatenated([onesStart, fadeOutExpanded], axis: 2)
            }

            // Accumulate weighted output
            let weightedSeparated = separated * broadcast(weight, to: separated.shape)

            let leftPad = offset
            let rightPad = sampleCount - end
            let paddedSeparated = padTensor(weightedSeparated, left: leftPad, right: rightPad)
            let paddedWeight = padTensor(weight, left: leftPad, right: rightPad)

            output = output + paddedSeparated
            totalWeight = totalWeight + paddedWeight

            chunkIndex += 1
            offset += stepSize
        }

        // Normalize by total weight
        let epsilon = MLXArray(Float(1e-8))
        let normalizer = maximum(broadcast(totalWeight, to: output.shape), epsilon)
        return output / normalizer
    }

    // MARK: - Helpers (Private)

    /// Check if cancellation has been requested — either lane.
    ///
    /// Two cancellation lanes, distinct error types by design:
    /// - The wrapping `Task` was cancelled (MLXEngine run-lifecycle / C13 cooperative
    ///   cancellation): throws `CancellationError` UNCHANGED — callers and the engine classify
    ///   cancelled-vs-failed by that type, so it must never be wrapped in `DemucsError`.
    /// - The explicit `cancel()` API set `cancelFlag`: throws ``DemucsError/cancelled``.
    ///
    /// Called per processed chunk in `separateChunked` (and between pipeline stages), so a
    /// cancelled separation bails at the next chunk boundary.
    private func checkCancelled() throws {
        try Task.checkCancellation()
        if cancelFlag.withLock({ $0 }) {
            throw DemucsError.cancelled
        }
    }

    /// Map an overall progress fraction to the corresponding pipeline stage.
    ///
    /// Stage ranges:
    /// - loading:     0.00–0.05
    /// - stft:        0.05–0.10
    /// - encoding:    0.10–0.25
    /// - transformer: 0.25–0.70
    /// - decoding:    0.70–0.90
    /// - writing:     0.90–1.00
    private func stageForFraction(_ fraction: Float) -> DemucsStage {
        switch fraction {
        case ..<0.05: return .loading
        case ..<0.10: return .stft
        case ..<0.25: return .encoding
        case ..<0.70: return .transformer
        case ..<0.90: return .decoding
        default:      return .writing
        }
    }

    /// Send a progress update to the handler.
    private func reportProgress(
        _ fraction: Float,
        stage: DemucsStage,
        startTime: CFAbsoluteTime,
        handler: (@Sendable (DemucsProgress) -> Void)?
    ) {
        guard let handler else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        handler(DemucsProgress(fraction: fraction, stage: stage, elapsedSeconds: elapsed))
    }

    /// Pad a tensor with zeros along the samples axis (axis 2).
    private func padTensor(_ x: MLXArray, left: Int, right: Int) -> MLXArray {
        var parts = [MLXArray]()
        let channels = x.shape[1]
        if left > 0 {
            parts.append(MLXArray.zeros([1, channels, left], dtype: x.dtype))
        }
        parts.append(x)
        if right > 0 {
            parts.append(MLXArray.zeros([1, channels, right], dtype: x.dtype))
        }
        return concatenated(parts, axis: 2)
    }
}
