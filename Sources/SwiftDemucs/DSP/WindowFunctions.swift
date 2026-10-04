import MLX
import Foundation

/// Window function generation for STFT/iSTFT.
enum WindowFunctions {

    /// Generate a periodic Hann window of the given size.
    ///
    /// Matches `torch.hann_window(size, periodic=True)`.
    /// Formula: `w[n] = 0.5 * (1 - cos(2π * n / size))`
    ///
    /// - Parameter size: Window length (typically n_fft).
    /// - Returns: MLXArray of shape `[size]` with float32 values.
    static func hannWindow(size: Int) -> MLXArray {
        let n = MLXArray(Array(0..<size).map { Float($0) })
        let factor = Float(2.0 * Double.pi) / Float(size)
        return 0.5 * (1.0 - cos(n * factor))
    }
}
