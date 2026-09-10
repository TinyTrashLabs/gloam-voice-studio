import MLX
import MLXFFT
import XCTest

@testable import EngineKit

/// The vocoder's two whole-chunk FFT steps (24k→48k resample, crossover
/// merge). Two things have to hold: they match the MLX-FFT reference they
/// were ported from, and they survive chunks longer than MLX's Metal FFT can
/// take (its four-step path asserts at 2^21 points, which the resample
/// reaches once a chunk passes 2^19 samples ≈ 21.8 s at 24 kHz — three
/// device SIGABRTs on 2026-09-08).
final class LuxVocoderResampleTests: XCTestCase {
    private static let metalFFTCeilingSamples = 1 << 19  // 24 kHz samples that still fit

    // MARK: Reference implementations (MLXFFT, as originally ported)

    private func nextPow2(_ n: Int) -> Int {
        var c = 1
        while c < n { c <<= 1 }
        return c
    }

    private func padLast(_ x: MLXArray, to target: Int) -> MLXArray {
        let n = x.dim(-1)
        guard target != n else { return x }
        var widths = Array(repeating: IntOrPair([0, 0]), count: x.ndim)
        widths[widths.count - 1] = IntOrPair([0, target - n])
        return padded(x, widths: widths)
    }

    private func mlxResample(_ audio: MLXArray, from srcRate: Int, to dstRate: Int) -> MLXArray {
        let n = audio.dim(-1)
        let newN = Int((Double(n) * Double(dstRate) / Double(srcRate)).rounded())
        let paddedN = nextPow2(n)
        let paddedNewN = Int((Double(paddedN) * Double(dstRate) / Double(srcRate)).rounded())
        let spec = MLXFFT.rfft(padLast(audio, to: paddedN), axis: -1)
        let resampled = MLXFFT.irfft(spec, n: paddedNewN, axis: -1)
        return resampled[.ellipsis, 0 ..< newN] * (Float(newN) / Float(n))
    }

    private func mlxCrossover(
        highPath: MLXArray, lowPath: MLXArray, sampleRate: Int, cutoff: Float, transitionBins: Int = 8
    ) -> MLXArray {
        let n = highPath.dim(-1)
        let paddedN = nextPow2(n)
        let specHigh = MLXFFT.rfft(padLast(highPath, to: paddedN), axis: -1)
        let specLow = MLXFFT.rfft(padLast(lowPath, to: paddedN), axis: -1)
        let nBins = specHigh.dim(-1)
        let cutoffBin = Int((cutoff / (Float(sampleRate) / 2.0)) * Float(nBins))
        let half = transitionBins / 2
        let start = max(0, cutoffBin - half)
        let end = min(nBins, cutoffBin + half)
        let width = end - start
        var mask = [Float](repeating: 1.0, count: nBins)
        if width > 0 {
            for i in 0 ..< start { mask[i] = 0 }
            for j in 0 ..< width {
                let t = width == 1 ? Float(0) : Float(j) / Float(width - 1)
                mask[start + j] = t * t * (3.0 - 2.0 * t)
            }
        }
        let maskArray = MLXArray(mask)
        let merged = specHigh * maskArray + specLow * (1.0 - maskArray)
        let result = MLXFFT.irfft(merged, n: paddedN, axis: -1)
        return paddedN == n ? result : result[.ellipsis, 0 ..< n]
    }

    // MARK: Signals

    /// Deterministic noise in [-1, 1), `rows` independent rows.
    private func noise(rows: Int, count: Int, seed: UInt64) -> MLXArray {
        var state = seed
        var flat = [Float](repeating: 0, count: rows * count)
        for i in 0 ..< flat.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            flat[i] = Float(state >> 40) / Float(1 << 23) - 1.0
        }
        return MLXArray(flat).reshaped([rows, count])
    }

    private func sine(hz: Double, sampleRate: Int, count: Int, amplitude: Float = 0.5) -> [Float] {
        (0 ..< count).map { i in
            amplitude * Float(sin(2 * Double.pi * hz * Double(i) / Double(sampleRate)))
        }
    }

    private func maxAbsDiff(_ a: MLXArray, _ b: MLXArray) -> Float {
        XCTAssertEqual(a.shape, b.shape)
        return abs(a - b).max().item(Float.self)
    }

    // MARK: Parity with the MLX reference

    func testResampleMatchesTheMLXReference() {
        let audio = noise(rows: 2, count: 12_345, seed: 7)
        let got = luxFFTResample(audio, from: 24_000, to: 48_000)
        let want = mlxResample(audio, from: 24_000, to: 48_000)
        XCTAssertEqual(got.shape, [2, 24_690])
        XCTAssertLessThan(maxAbsDiff(got, want), 2e-3)
    }

    func testResampleLeavesAMatchingRateAlone() {
        let audio = noise(rows: 1, count: 1_000, seed: 1)
        XCTAssertEqual(maxAbsDiff(luxFFTResample(audio, from: 24_000, to: 24_000), audio), 0)
    }

    func testCrossoverMergeMatchesTheMLXReference() {
        let high = noise(rows: 2, count: 12_345, seed: 11)
        let low = noise(rows: 2, count: 12_345, seed: 13)
        let got = luxCrossoverMergeLinkwitzRiley(
            highPath: high, lowPath: low, sampleRate: 48_000, cutoff: 11_000)
        let want = mlxCrossover(highPath: high, lowPath: low, sampleRate: 48_000, cutoff: 11_000)
        XCTAssertEqual(got.shape, [2, 12_345])
        XCTAssertLessThan(maxAbsDiff(got, want), 2e-3)
    }

    // MARK: Chunks past the Metal FFT ceiling

    func testResampleSurvivesAChunkPastTheMetalFFTCeiling() {
        let n = Self.metalFFTCeilingSamples + 24_000  // ~22.8 s at 24 kHz
        let audio = MLXArray(sine(hz: 440, sampleRate: 24_000, count: n)).reshaped([1, n])

        let out = luxFFTResample(audio, from: 24_000, to: 48_000)

        XCTAssertEqual(out.shape, [1, 2 * n])
        // Still a 440 Hz sine at the new rate: compare the interior (the
        // brick-wall resample rings only at the very ends).
        let want = sine(hz: 440, sampleRate: 48_000, count: 2 * n)
        let got = out.squeezed().asArray(Float.self)
        let interior = 48_000 ..< (2 * n - 48_000)
        let err = interior.map { abs(got[$0] - want[$0]) }.max() ?? .infinity
        XCTAssertLessThan(err, 1e-2)
    }

    func testCrossoverMergeSurvivesAChunkPastTheMetalFFTCeiling() {
        let n = 2 * (Self.metalFFTCeilingSamples + 24_000)  // the 48 kHz twin of the above
        let high = MLXArray(sine(hz: 15_000, sampleRate: 48_000, count: n)).reshaped([1, n])
        let low = MLXArray(sine(hz: 440, sampleRate: 48_000, count: n)).reshaped([1, n])

        let out = luxCrossoverMergeLinkwitzRiley(
            highPath: high, lowPath: low, sampleRate: 48_000, cutoff: 11_000)

        XCTAssertEqual(out.shape, [1, n])
        // Above the cutoff comes from `high`, below from `low`: the merge is
        // the sum of the two sines.
        let got = out.squeezed().asArray(Float.self)
        let wantHigh = sine(hz: 15_000, sampleRate: 48_000, count: n)
        let wantLow = sine(hz: 440, sampleRate: 48_000, count: n)
        let interior = 48_000 ..< (n - 48_000)
        let err = interior.map { abs(got[$0] - (wantHigh[$0] + wantLow[$0])) }.max() ?? .infinity
        XCTAssertLessThan(err, 1e-2)
    }
}
