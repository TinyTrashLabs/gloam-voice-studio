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
}
