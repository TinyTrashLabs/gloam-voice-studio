import MLX
import MLXFFT

/// Inverse Short-Time Fourier Transform implementation.
///
/// Reconstructs a time-domain signal from a complex-valued spectrogram
/// using irfft and overlap-add synthesis.
enum ISTFT {

    /// Compute the inverse STFT to reconstruct a time-domain signal.
    ///
    /// - Parameters:
    ///   - spectrogram: Complex-valued input of shape `[batch, channels, freq_bins, frames]`.
    ///   - nFFT: FFT size (default 4096).
    ///   - hopLength: Hop size between frames (default 1024).
    ///   - window: Window function array of shape `[nFFT]`.
    ///   - length: Expected output length. If nil, computed from frame count.
    /// - Returns: Real-valued signal of shape `[batch, channels, samples]`.
    static func istft(
        _ spectrogram: MLXArray,
        nFFT: Int = 4096,
        hopLength: Int = 1024,
        window: MLXArray,
        length: Int? = nil
    ) -> MLXArray {
        let shape = spectrogram.shape
        let batch = shape[0]
        let channels = shape[1]
        // freq_bins = shape[2], frames = shape[3]
        let numFrames = shape[3]

        // Transpose to [batch, channels, frames, freq_bins] for irfft
        let transposed = spectrogram.transposed(0, 1, 3, 2)

        // Reshape to [batch * channels, frames, freq_bins]
        let flat = transposed.reshaped([batch * channels, numFrames, -1])

        // Apply irfft to get real-valued frames: [batch*channels, frames, nFFT]
        let frames = MLXFFT.irfft(flat, n: nFFT, axis: -1)

        // Apply window to each frame
        let windowedFrames = frames * window  // broadcast [nFFT]

        // Overlap-add reconstruction
        let padAmount = nFFT / 2
        let expectedLength = (numFrames - 1) * hopLength + nFFT
        let outputLength = length.map { $0 + 2 * padAmount } ?? expectedLength

        // Perform overlap-add using scatter_add or manual accumulation
        // We'll accumulate into a zero buffer
        var output = MLXArray.zeros([batch * channels, outputLength], dtype: .float32)
        var windowSum = MLXArray.zeros([batch * channels, outputLength], dtype: .float32)

        let windowSquared = window * window  // for normalization

        for f in 0..<numFrames {
            let start = f * hopLength
            let frame = windowedFrames[0..., f, 0...]  // [batch*channels, nFFT]

            // We need to add this frame to output[start:start+nFFT]
            // Since MLX doesn't have scatter_add, we build a padded version and add
            let leftPad = start
            let rightPad = outputLength - start - nFFT
            if rightPad >= 0 {
                let paddedFrame = padArray(frame, left: leftPad, right: rightPad)
                output = output + paddedFrame

                // Window normalization denominator
                let winExpanded = broadcast(
                    windowSquared.expandedDimensions(axis: 0),
                    to: [batch * channels, nFFT]
                )
                let paddedWin = padArray(winExpanded, left: leftPad, right: rightPad)
                windowSum = windowSum + paddedWin
            }
        }

        // Normalize by window sum (avoid division by zero)
        let epsilon = MLXArray(Float(1e-8))
        let normalizer = maximum(windowSum, epsilon)
        output = output / normalizer

        // Remove center padding and trim to requested length
        let trimStart = padAmount
        let trimEnd: Int
        if let length = length {
            trimEnd = trimStart + length
        } else {
            trimEnd = outputLength - padAmount
        }

        let trimmed = output[0..., trimStart..<trimEnd]

        // Reshape back to [batch, channels, samples]
        let outputSamples = trimmed.shape[1]
        return trimmed.reshaped([batch, channels, outputSamples])
    }

    /// Pad a 2D array with zeros on the last axis.
    private static func padArray(_ x: MLXArray, left: Int, right: Int) -> MLXArray {
        let batch = x.shape[0]
        var parts = [MLXArray]()
        if left > 0 {
            parts.append(MLXArray.zeros([batch, left], dtype: x.dtype))
        }
        parts.append(x)
        if right > 0 {
            parts.append(MLXArray.zeros([batch, right], dtype: x.dtype))
        }
        return concatenated(parts, axis: 1)
    }
}
