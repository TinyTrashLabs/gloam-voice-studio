import Foundation

/// Errors from the vocal separation pipeline.
public enum DemucsError: Error, Sendable {

    /// The specified weights directory does not contain the required safetensors file.
    case weightsNotFound(String)

    /// The input audio has an unsupported sample rate (expected 44100 Hz).
    case unsupportedSampleRate(Int)

    /// Failed to read the input audio file.
    case audioReadFailed(Error)

    /// MLX model inference failed during processing.
    case mlxInferenceFailed(Error)

    /// Failed to write the output WAV file.
    case outputWriteFailed(Error)

    /// Separation was cancelled via ``VocalSeparator/cancel()``.
    case cancelled
}

extension DemucsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .weightsNotFound(let path):
            return "Model weights not found at: \(path)"
        case .unsupportedSampleRate(let rate):
            return "Unsupported sample rate: \(rate) Hz (expected 44100)"
        case .audioReadFailed(let error):
            return "Failed to read audio: \(error.localizedDescription)"
        case .mlxInferenceFailed(let error):
            return "MLX inference failed: \(error.localizedDescription)"
        case .outputWriteFailed(let error):
            return "Failed to write output: \(error.localizedDescription)"
        case .cancelled:
            return "Separation was cancelled"
        }
    }
}
