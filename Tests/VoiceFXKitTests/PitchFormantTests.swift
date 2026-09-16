import XCTest
@testable import VoiceFXKit

final class PitchFormantTests: XCTestCase {
    private func sine(_ hz: Double, sr: Double = 48_000, n: Int = 48_000) -> [Float] {
        (0..<n).map { Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
    }

    private func run(_ stage: FXStage, _ input: [Float], sr: Double = 48_000) -> [Float] {
        stage.prepare(sampleRate: sr, maxBlock: input.count)
        var out = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                stage.process(i.baseAddress!, o.baseAddress!, frames: input.count)
            }
        }
        return out
    }

    /// Estimate dominant frequency by counting zero crossings on the settled
    /// region. Crude, but enough to prove the shift went the right way and by
    /// roughly the right amount.
    private func dominantHz(_ x: [Float], sr: Double = 48_000) -> Double {
        let settled = Array(x[(x.count / 2)...])
        var crossings = 0
        for i in 1..<settled.count where (settled[i - 1] < 0) != (settled[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2.0 * sr / Double(settled.count)
    }

    func testTransposeDownLowersPitch() {
        let out = run(PitchFormantStage(transposeSemitones: -12,
                                        formantSemitones: 0,
                                        formantBaseHz: 220), sine(440))
        let hz = dominantHz(out)
        XCTAssertEqual(hz, 220, accuracy: 30, "an octave down from 440 should land near 220, got \(hz)")
    }

    func testPassThroughAtZeroShift() {
        let input = sine(440)
        let out = run(PitchFormantStage(transposeSemitones: 0,
                                        formantSemitones: 0,
                                        formantBaseHz: 220), input)
        XCTAssertEqual(dominantHz(out), 440, accuracy: 30)
    }

    func testReportsNonZeroLatency() {
        let stage = PitchFormantStage(transposeSemitones: -7, formantSemitones: -4, formantBaseHz: 220)
        stage.prepare(sampleRate: 48_000, maxBlock: 1024)
        XCTAssertGreaterThan(stage.latencyFrames, 0)
    }

    /// The parallel branch must actually add energy, not replace the dry path.
    func testParallelMixSumsBranchAndDry() {
        let input = sine(440, n: 4800)
        let mixed = run(ParallelMixStage(primary: nil, branch: GainStage(gain: 1.0),
                                         primaryGain: 1.0, branchGain: 1.0), input)
        for i in 0..<input.count {
            XCTAssertEqual(mixed[i], input[i] * 2, accuracy: 1e-5)
        }
    }

    func testParallelMixRespectsGains() {
        let input = sine(440, n: 4800)
        let mixed = run(ParallelMixStage(primary: nil, branch: GainStage(gain: 1.0),
                                         primaryGain: 0.5, branchGain: 0.25), input)
        for i in 0..<input.count {
            XCTAssertEqual(mixed[i], input[i] * 0.75, accuracy: 1e-5)
        }
    }

    /// Both paths must see the SAME input. If the primary's output leaks into
    /// the branch, two shifters compose into one deeper shift instead of two
    /// voices — which is the bug this test exists to catch.
    func testBothPathsReceiveTheSameInput() {
        let input = sine(440, n: 4800)
        let mixed = run(ParallelMixStage(primary: GainStage(gain: 2.0),
                                         branch: GainStage(gain: 3.0),
                                         primaryGain: 1.0, branchGain: 1.0), input)
        // Parallel: 2x + 3x = 5x. Cascaded would be 2x then 3*(2x) = 6x.
        for i in 0..<input.count {
            XCTAssertEqual(mixed[i], input[i] * 5, accuracy: 1e-5)
        }
    }

    /// Chunk invariance for the shifter. Its internal buffering makes this the
    /// stage most likely to break when driven in small blocks.
    func testChunkInvariance() {
        let input = sine(330, n: 12_000)
        let expected = run(PitchFormantStage(transposeSemitones: -5,
                                             formantSemitones: -3,
                                             formantBaseHz: 200), input)
        let stage = PitchFormantStage(transposeSemitones: -5,
                                      formantSemitones: -3,
                                      formantBaseHz: 200)
        stage.prepare(sampleRate: 48_000, maxBlock: 12_000)
        var actual = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            actual.withUnsafeMutableBufferPointer { o in
                for size in [512, 512, 1024, 256, 9_696] {
                    let n = min(size, input.count - i)
                    if n <= 0 { break }
                    stage.process(inBuf.baseAddress! + i, o.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        for k in 0..<i {
            XCTAssertEqual(actual[k], expected[k], accuracy: 1e-4, "mismatch at \(k)")
        }
    }

    // MARK: - Formant direction/effect

    /// A deterministic voice-like signal built source-filter style: a
    /// harmonic source (200 Hz fundamental) shaped by three resonant peaks
    /// at roughly 700 Hz, 1200 Hz and 2600 Hz — a crude vowel-like formant
    /// structure. A bare harmonic comb has no spectral envelope for the
    /// library's formant shift to move; these Gaussian resonance bumps give
    /// it one.
    private func voiceLike(f0: Double = 200, sr: Double = 48_000, n: Int = 48_000) -> [Float] {
        let harmonics = 1...25 // up to ~5 kHz
        let formants: [(center: Double, bandwidth: Double)] = [
            (700, 80), (1200, 90), (2600, 120)
        ]
        func envelope(_ hz: Double) -> Double {
            var gain = 0.15 // floor so non-resonant harmonics still contribute
            for f in formants {
                let d = (hz - f.center) / f.bandwidth
                gain += exp(-0.5 * d * d)
            }
            return gain
        }
        var out = [Float](repeating: 0, count: n)
        for h in harmonics {
            let hz = f0 * Double(h)
            let amp = Float((1.0 / Double(h)) * envelope(hz)) // source rolloff * formant shaping
            for i in 0..<n {
                out[i] += amp * Float(sin(2 * Double.pi * hz * Double(i) / sr))
            }
        }
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for i in 0..<n { out[i] /= peak }
        }
        return out
    }

    /// Naive DFT magnitude at a single frequency bin. O(n) per bin, fine for
    /// the handful of bins a coarse spectral-balance proxy needs.
    private func goertzelMagnitude(_ x: [Float], targetHz: Double, sr: Double) -> Double {
        let n = x.count
        let w = 2 * Double.pi * targetHz / sr
        let coeff = 2 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            s0 = Double(x[i]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(w)
        let imag = s2 * sin(w)
        return (real * real + imag * imag).squareRoot()
    }

    /// Fraction of total energy (summed over 200..5000 Hz in 50 Hz steps)
    /// that falls below ~800 Hz. A simple, deterministic spectral-balance
    /// proxy standing in for a proper formant/envelope analysis.
    private func lowEnergyFraction(_ x: [Float], sr: Double = 48_000) -> Double {
        // Use the settled second half to avoid filter/pitch-shifter onset
        // transients skewing the balance.
        let settled = Array(x[(x.count / 2)...])
        var total = 0.0
        var low = 0.0
        var hz = 200.0
        while hz <= 5000.0 {
            let mag = goertzelMagnitude(settled, targetHz: hz, sr: sr)
            let energy = mag * mag
            total += energy
            if hz < 800 { low += energy }
            hz += 50
        }
        return total > 0 ? low / total : 0
    }

    func testFormantShiftMovesSpectralBalanceInTheRightDirection() {
        let input = voiceLike()

        let down = lowEnergyFraction(run(PitchFormantStage(transposeSemitones: 0,
                                                            formantSemitones: -12,
                                                            formantBaseHz: 0), input))
        let neutral = lowEnergyFraction(run(PitchFormantStage(transposeSemitones: 0,
                                                               formantSemitones: 0,
                                                               formantBaseHz: 0), input))
        let up = lowEnergyFraction(run(PitchFormantStage(transposeSemitones: 0,
                                                          formantSemitones: 12,
                                                          formantBaseHz: 0), input))

        // Real margins, not just inequality, so this can't pass on noise.
        XCTAssertGreaterThan(down, neutral + 0.03,
                              "formants -12 should put noticeably MORE energy below 800 Hz than neutral " +
                              "(down=\(down), neutral=\(neutral))")
        XCTAssertLessThan(up, neutral - 0.03,
                           "formants +12 should put noticeably LESS energy below 800 Hz than neutral " +
                           "(up=\(up), neutral=\(neutral))")
    }

    func testFormantNeutralIsNearPassThrough() {
        let input = voiceLike()
        let neutralFraction = lowEnergyFraction(run(PitchFormantStage(transposeSemitones: 0,
                                                                       formantSemitones: 0,
                                                                       formantBaseHz: 0), input))
        let dryFraction = lowEnergyFraction(input)
        XCTAssertEqual(neutralFraction, dryFraction, accuracy: 0.03,
                        "formantSemitones: 0 should not meaningfully alter spectral balance " +
                        "(neutral=\(neutralFraction), dry=\(dryFraction))")
    }
}
