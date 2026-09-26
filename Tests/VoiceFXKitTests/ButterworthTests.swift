import XCTest
@testable import VoiceFXKit

final class ButterworthTests: XCTestCase {
    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    private func sine(_ hz: Double, sr: Double, n: Int) -> [Float] {
        (0..<n).map { Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
    }

    private func run(_ stage: FXStage, _ input: [Float], sr: Double) -> [Float] {
        stage.prepare(sampleRate: sr, maxBlock: input.count)
        var out = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                stage.process(i.baseAddress!, o.baseAddress!, frames: input.count)
            }
        }
        return out
    }

    /// A lowpass must pass what's below its corner and reject what's above.
    /// Measured on the settled tail, so the filter's startup transient does
    /// not pollute the RMS.
    func testLowpassRejectsAboveCorner() {
        let sr = 48_000.0
        let low = run(ButterworthStage(kind: .lowpass, frequency: 1000),
                      sine(200, sr: sr, n: 9600), sr: sr)
        let high = run(ButterworthStage(kind: .lowpass, frequency: 1000),
                       sine(8000, sr: sr, n: 9600), sr: sr)
        XCTAssertGreaterThan(rms(Array(low[4800...])), 0.6)
        XCTAssertLessThan(rms(Array(high[4800...])), 0.05)
    }

    func testHighpassRejectsBelowCorner() {
        let sr = 48_000.0
        let low = run(ButterworthStage(kind: .highpass, frequency: 1000),
                      sine(100, sr: sr, n: 9600), sr: sr)
        let high = run(ButterworthStage(kind: .highpass, frequency: 1000),
                       sine(8000, sr: sr, n: 9600), sr: sr)
        XCTAssertLessThan(rms(Array(low[4800...])), 0.05)
        XCTAssertGreaterThan(rms(Array(high[4800...])), 0.6)
    }

    /// The property every stage must hold. A filter carries two samples of
    /// state, so a chunk boundary is exactly where a port bug would show.
    func testChunkInvariance() {
        let sr = 48_000.0
        let input = sine(440, sr: sr, n: 4000)
        let expected = run(ButterworthStage(kind: .lowpass, frequency: 1200), input, sr: sr)

        let stage = ButterworthStage(kind: .lowpass, frequency: 1200)
        stage.prepare(sampleRate: sr, maxBlock: 4000)
        var actual = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            actual.withUnsafeMutableBufferPointer { o in
                for size in [1, 13, 256, 3, 999, 1728, 1000] {
                    let n = min(size, input.count - i)
                    if n <= 0 { break }
                    stage.process(inBuf.baseAddress! + i, o.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        for k in 0..<i {
            XCTAssertEqual(actual[k], expected[k], accuracy: 1e-6, "mismatch at \(k)")
        }
    }

    func testResetClearsState() {
        let sr = 48_000.0
        let stage = ButterworthStage(kind: .lowpass, frequency: 1000)
        let input = sine(440, sr: sr, n: 256)
        let first = run(stage, input, sr: sr)
        stage.reset()
        var second = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in
            second.withUnsafeMutableBufferPointer { o in
                stage.process(i.baseAddress!, o.baseAddress!, frames: input.count)
            }
        }
        for k in 0..<input.count {
            XCTAssertEqual(first[k], second[k], accuracy: 1e-6)
        }
    }
}
