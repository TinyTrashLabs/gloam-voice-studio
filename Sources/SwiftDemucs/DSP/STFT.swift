import MLX
import MLXFFT

/// Short-Time Fourier Transform implementation using MLXFFT primitives.
///
/// Converts a time-domain signal into a complex-valued spectrogram
/// by windowing overlapping frames and applying rfft to each.
///
/// htdemucs uses n_fft=4096, hop_length=1024, Hann window.
enum STFT {

    /// Compute the Short-Time Fourier Transform of a signal.
    ///
    /// - Parameters:
    ///   - signal: Real-valued input of shape `[batch, channels, samples]`.
    ///   - nFFT: FFT size (default 4096).
    ///   - hopLength: Hop size between frames (default 1024).
    ///   - window: Window function array of shape `[nFFT]`.
    /// - Returns: Complex-valued spectrogram of shape `[batch, channels, freq_bins, frames]`
    ///            where `freq_bins = nFFT / 2 + 1`.
    static func stft(
        _ signal: MLXArray,
        nFFT: Int = 4096,
        hopLength: Int = 1024,
        window: MLXArray
    ) -> MLXArray {
        let shape = signal.shape
        let batch = shape[0]
        let channels = shape[1]
        let samples = shape[2]

        // Reshape to [batch * channels, samples] for frame extraction
        let flat = signal.reshaped([batch * channels, samples])

        // Pad signal: center padding with nFFT/2 on each side
        let padAmount = nFFT / 2
        let padded = padded(flat, left: padAmount, right: padAmount)

        let paddedLength = padded.shape[1]

        // Calculate number of frames
        let numFrames = (paddedLength - nFFT) / hopLength + 1

        // Extract frames using strided indexing
        // Build frame indices: for each frame f, extract samples [f*hop .. f*hop+nFFT)
        var frames = [MLXArray]()
        frames.reserveCapacity(numFrames)
        for f in 0..<numFrames {
            let start = f * hopLength
            let frame = padded[0..., start..<(start + nFFT)]  // [batch*channels, nFFT]
            frames.append(frame)
        }
        // Stack to [numFrames, batch*channels, nFFT] then transpose to [batch*channels, numFrames, nFFT]
        var stacked = stacked(frames, axis: 0)
        stacked = stacked.transposed(1, 0, 2)  // [batch*channels, numFrames, nFFT]

        // Apply window: broadcast [nFFT] over frames
        let windowed = stacked * window

        // Apply rfft along the last axis
        let spectrum = MLXFFT.rfft(windowed, axis: -1)  // [batch*channels, numFrames, nFFT/2+1]

        // Reshape to [batch, channels, numFrames, freq_bins] then transpose to [batch, channels, freq_bins, numFrames]
        let freqBins = nFFT / 2 + 1
        let result = spectrum.reshaped([batch, channels, numFrames, freqBins])
        return result.transposed(0, 1, 3, 2)  // [batch, channels, freq_bins, frames]
    }

    /// Zero-pad a 2D array on the last axis.
    private static func padded(_ x: MLXArray, left: Int, right: Int) -> MLXArray {
        let shape = x.shape
        let batch = shape[0]
        if left > 0 {
            let leftPad = MLXArray.zeros([batch, left], dtype: x.dtype)
            let rightPad = MLXArray.zeros([batch, right], dtype: x.dtype)
            return concatenated([leftPad, x, rightPad], axis: 1)
        }
        return x
    }
}
