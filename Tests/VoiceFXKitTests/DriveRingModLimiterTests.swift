import XCTest
@testable import VoiceFXKit

final class DriveRingModLimiterTests: XCTestCase {
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

    private func chunked(_ stage: FXStage, _ input: [Float],
                         sizes: [Int], sr: Double = 48_000) -> [Float] {
        stage.prepare(sampleRate: sr, maxBlock: input.count)
        var out = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { o in
                for size in sizes {
                    let n = min(size, input.count - i)
                    if n <= 0 { break }
                    stage.process(inBuf.baseAddress! + i, o.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        return out
    }

    /// A waveshaper must add harmonics: a pure sine in, a non-sine out.
    /// Measured as a rise in peak-to-RMS ratio relative to the input.
    func testDriveAddsHarmonics() {
        let input = (0..<4800).map { Float(sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        let out = run(DriveStage(preGain: 3, postGain: 0.5, shape1: 0, shape2: 0), input)
        let outRMS = (out.reduce(0) { $0 + $1 * $1 } / Float(out.count)).squareRoot()
        XCTAssertGreaterThan(outRMS, 0.01, "drive must produce signal")
        // A tanh-shaped sine flattens toward a square, raising RMS relative to peak.
        let peak = out.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(outRMS / peak, 0.72, "shaped output should be fuller than a sine (0.707)")
    }

    /// Ring modulation at f_c against a carrier f_m produces sum and difference
    /// tones and suppresses the original — a fully-wet ring mod of a DC-free
    /// sine should not leave the input untouched.
    func testRingModChangesSignal() {
        let input = (0..<4800).map { Float(sin(2 * Double.pi * 300 * Double($0) / 48_000)) }
        let out = run(RingModStage(frequency: 90, mix: 1.0), input)
        var diff: Float = 0
        for i in 0..<input.count { diff += abs(out[i] - input[i]) }
        XCTAssertGreaterThan(diff / Float(input.count), 0.1, "fully-wet ring mod must alter the signal")
    }

    func testRingModDryMixIsTransparent() {
        let input = (0..<512).map { Float(sin(Double($0) * 0.1)) }
        let out = run(RingModStage(frequency: 90, mix: 0.0), input)
        for i in 0..<input.count {
            XCTAssertEqual(out[i], input[i], accuracy: 1e-6)
        }
    }

    /// The limiter's entire job: nothing leaves above the ceiling.
    func testLimiterNeverExceedsCeiling() {
        let input = (0..<4800).map { Float(3.0 * sin(Double($0) * 0.05)) }
        let out = run(LimiterStage(ceiling: 0.95, releaseSeconds: 0.05), input)
        for (i, v) in out.enumerated() {
            XCTAssertLessThanOrEqual(abs(v), 0.9501, "sample \(i) = \(v) exceeded ceiling")
        }
    }

    func testLimiterLeavesQuietSignalAlone() {
        let input = (0..<512).map { Float(0.1 * sin(Double($0) * 0.05)) }
        let out = run(LimiterStage(ceiling: 0.95, releaseSeconds: 0.05), input)
        for i in 0..<input.count {
            XCTAssertEqual(out[i], input[i], accuracy: 1e-4)
        }
    }

    func testAllThreeAreChunkInvariant() {
        let input = (0..<3000).map { Float(1.4 * sin(Double($0) * 0.03)) }
        let sizes = [1, 9, 256, 777, 1957]
        for makeStage: () -> FXStage in [
            { DriveStage(preGain: 3, postGain: 0.5, shape1: 0, shape2: 0) },
            { RingModStage(frequency: 90, mix: 0.7) },
            { LimiterStage(ceiling: 0.95, releaseSeconds: 0.05) },
        ] {
            let expected = run(makeStage(), input)
            let actual = chunked(makeStage(), input, sizes: sizes)
            for k in 0..<input.count {
                XCTAssertEqual(actual[k], expected[k], accuracy: 1e-6,
                               "\(type(of: makeStage())) mismatch at \(k)")
            }
        }
    }
}
