import AVFoundation
import MLX

/// Errors that can occur during audio I/O.
public enum AudioIOError: Error, CustomStringConvertible {
    case formatCreationFailed
    case converterCreationFailed
    case bufferCreationFailed
    case conversionFailed(String)
    case fileReadFailed(String)
    case fileWriteFailed(String)
    case unsupportedChannelCount(Int)

    public var description: String {
        switch self {
        case .formatCreationFailed:
            return "Failed to create target audio format (44.1kHz stereo float32)"
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for sample rate conversion"
        case .bufferCreationFailed:
            return "Failed to allocate PCM buffer"
        case .conversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        case .fileReadFailed(let detail):
            return "Failed to read audio file: \(detail)"
        case .fileWriteFailed(let detail):
            return "Failed to write audio file: \(detail)"
        case .unsupportedChannelCount(let count):
            return "Unsupported channel count: \(count). Expected 1 (mono) or 2 (stereo)."
        }
    }
}

/// Audio file I/O for loading and saving audio compatible with htdemucs.
///
/// htdemucs expects 44.1kHz stereo float32 input.
/// Supports any format readable by AVAudioFile (WAV, MP3, FLAC, M4A, etc.).
public struct AudioIO {

    /// Target sample rate for htdemucs model input.
    public static let targetSampleRate: Double = 44100.0

    /// Target channel count (stereo).
    public static let targetChannels: AVAudioChannelCount = 2

    public init() {}

    /// Load an audio file and convert to 44.1kHz stereo float32 MLXArray.
    ///
    /// - Parameter url: Path to the audio file.
    /// - Returns: Tuple of (MLXArray of shape `[1, 2, samples]`, sample count).
    public func loadAudio(from url: URL) throws -> (MLXArray, Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioIOError.fileReadFailed(error.localizedDescription)
        }

        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.targetSampleRate,
            channels: Self.targetChannels
        ) else {
            throw AudioIOError.formatCreationFailed
        }

        let samples: [Float]

        // If already at target format, read directly
        if file.processingFormat.sampleRate == Self.targetSampleRate
            && file.processingFormat.channelCount == Self.targetChannels
        {
            samples = try readDirectly(file: file)
        } else {
            samples = try convertAudio(file: file, to: targetFormat)
        }

        // Interleaved stereo → [1, 2, samples_per_channel]
        let samplesPerChannel = samples.count / Int(Self.targetChannels)
        let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        let right = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }

        let leftArray = MLXArray(left)
        let rightArray = MLXArray(right)
        let stereo = stacked([leftArray, rightArray], axis: 0)  // [2, samples_per_channel]
        let batched = stereo.expandedDimensions(axis: 0)  // [1, 2, samples_per_channel]

        return (batched, samplesPerChannel)
    }

    /// Save an MLXArray as a WAV file at the target sample rate.
    ///
    /// - Parameters:
    ///   - audio: MLXArray of shape `[1, 2, samples]` or `[2, samples]` or `[1, samples]` or `[samples]`.
    ///   - url: Output file path.
    ///   - sampleRate: Sample rate (default 44100.0).
    public func saveAudio(_ audio: MLXArray, to url: URL, sampleRate: Double = 44100.0) throws {
        MLX.eval(audio)

        // Normalize shape to [channels, samples]
        var normalized: MLXArray
        switch audio.ndim {
        case 1:
            // [samples] → mono
            normalized = audio.expandedDimensions(axis: 0)  // [1, samples]
        case 2:
            // [channels, samples]
            normalized = audio
        case 3:
            // [1, channels, samples]
            normalized = audio.squeezed(axis: 0)
        default:
            throw AudioIOError.fileWriteFailed("Unexpected audio shape: \(audio.shape)")
        }

        let channels = normalized.shape[0]
        let sampleCount = normalized.shape[1]

        guard channels == 1 || channels == 2 else {
            throw AudioIOError.unsupportedChannelCount(channels)
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            throw AudioIOError.formatCreationFailed
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            throw AudioIOError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy data to buffer
        for ch in 0..<channels {
            let channelData = buffer.floatChannelData![ch]
            let channelArray = normalized[ch]
            MLX.eval(channelArray)
            let flat = channelArray.asArray(Float.self)
            for i in 0..<sampleCount {
                channelData[i] = flat[i]
            }
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            throw AudioIOError.fileWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func readDirectly(file: AVAudioFile) throws -> [Float] {
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw AudioIOError.bufferCreationFailed
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw AudioIOError.fileReadFailed(error.localizedDescription)
        }

        return extractInterleavedSamples(from: buffer)
    }

    private func convertAudio(file: AVAudioFile, to targetFormat: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(
            from: file.processingFormat,
            to: targetFormat
        ) else {
            throw AudioIOError.converterCreationFailed
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw AudioIOError.bufferCreationFailed
        }

        do {
            try file.read(into: inputBuffer)
        } catch {
            throw AudioIOError.fileReadFailed(error.localizedDescription)
        }

        // Calculate output frame count
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else {
            throw AudioIOError.bufferCreationFailed
        }

        // Block-based API required for sample rate conversion (Apple TN3136)
        // The callback is invoked synchronously by convert(to:error:withInputFrom:),
        // so these captures are safe despite being flagged by Swift 6 strict concurrency.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let capturedBuffer = inputBuffer
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            consumed = true
            return capturedBuffer
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            throw AudioIOError.conversionFailed(error.localizedDescription)
        }

        return extractInterleavedSamples(from: outputBuffer)
    }

    /// Extract interleaved float32 samples from a buffer.
    /// Standard format buffers are deinterleaved, so we interleave them.
    private func extractInterleavedSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            for ch in 0..<channelCount {
                interleaved[frame * channelCount + ch] = channelData[ch][frame]
            }
        }
        return interleaved
    }
}
