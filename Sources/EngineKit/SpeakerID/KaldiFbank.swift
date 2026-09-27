import Accelerate
import Foundation

/// Kaldi-compatible log-mel filterbank (kaldi-native-fbank's defaults as sherpa-onnx uses them for speaker
/// embedding models): 16 kHz, 25 ms frames every 10 ms, snip_edges false (reflected edges), DC removed,
/// pre-emphasis 0.97, Povey window, 512-point power spectrum, 80 mel bins from 20 Hz to 7600 Hz (sherpa-onnx's
/// high_freq −400), log.
public enum KaldiFbank {
    public static let sampleRate = 16_000
    public static let frameLength = 400, frameShift = 160, fftSize = 512, melBins = 80

    /// Frames × 80, row-major. `samples` are 16 kHz floats in −1…1; `scaleToInt16` multiplies by 32768 first
    /// (WeSpeaker models set normalize_samples = 0, i.e. they expect int16-range input).
    public static func compute(_ samples: [Float], scaleToInt16: Bool = true, highFreq: Double = -400) -> (features: [Float], frames: Int) {
        let n = samples.count
        let frames = (n + frameShift / 2) / frameShift
        guard frames > 0, n > 0 else { return ([], 0) }
        let x = scaleToInt16 ? samples.map { $0 * 32768 } : samples
        let window = povey
        let bank = highFreq == -400 ? melBank : bankFor(highFreq)
        let half = fftSize / 2
        var out = [Float](repeating: 0, count: frames * melBins)
        let log2n = vDSP_Length(9)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        var frame = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half + 1)
        for f in 0..<frames {
            let start = f * frameShift + frameShift / 2 - frameLength / 2
            for i in 0..<frameLength {
                var s = start + i
                if s < 0 { s = -s - 1 } else if s >= n { s = 2 * n - 1 - s }
                frame[i] = x[max(0, min(n - 1, s))]
            }
            for i in frameLength..<fftSize { frame[i] = 0 }
            // remove DC, pre-emphasis, window
            var mean: Float = 0; vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            for i in 0..<frameLength { frame[i] -= mean }
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            for i in 0..<frameLength { frame[i] *= window[i] }
            // real FFT (packed): re/im halves
            frame.withUnsafeBufferPointer { fp in
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
            // vDSP's forward real FFT is 2× the textbook DFT: power = (re² + im²) / 4
            power[0] = (re[0] * re[0]) / 4
            power[half] = (im[0] * im[0]) / 4
            for k in 1..<half { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            for m in 0..<melBins {
                var e: Float = 0
                for (k, w) in bank[m] { e += power[k] * w }
                out[f * melBins + m] = log(max(e, Float.ulpOfOne))
            }
        }
        return (out, frames)
    }

    static let povey: [Float] = (0..<frameLength).map { i in
        Float(pow(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameLength - 1)), 0.85))
    }

    /// Triangular filters in mel space (Kaldi's `MelBanks`), as sparse (fft bin, weight) lists.
    static let melBank: [[(Int, Float)]] = bankFor(-400)
    /// `high` ≤ 0 means Nyquist + high (sherpa-onnx's default −400 → 7600 Hz).
    static func bankFor(_ highFreq: Double) -> [[(Int, Float)]] {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let low = 20.0, high = highFreq > 0 ? highFreq : Double(sampleRate) / 2 + highFreq
        let ml = mel(low), mh = mel(high), delta = (mh - ml) / Double(melBins + 1)
        let binHz = Double(sampleRate) / Double(fftSize)
        return (0..<melBins).map { m in
            let left = ml + Double(m) * delta, center = left + delta, right = center + delta
            var row: [(Int, Float)] = []
            for k in 0..<(fftSize / 2) {
                let v = mel(binHz * Double(k))
                if v > left && v < right {
                    let w = v <= center ? (v - left) / (center - left) : (right - v) / (right - center)
                    row.append((k, Float(w)))
                }
            }
            return row
        }
    }
}
