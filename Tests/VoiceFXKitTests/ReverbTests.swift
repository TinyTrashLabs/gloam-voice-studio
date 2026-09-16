import XCTest
@testable import VoiceFXKit

final class ReverbTests: XCTestCase {
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

    /// An impulse in must produce a decaying tail long after the impulse ends.
    /// That tail is the entire point of the stage.
    func testImpulseProducesTail() {
        var input = [Float](repeating: 0, count: 48_000)
        input[0] = 1.0
        let out = run(ReverbStage(feedback: 0.85, lowpassHz: 10_000, mix: 1.0), input)

        let early = out[2_000..<6_000].map { abs($0) }.max() ?? 0
        let late = out[30_000..<34_000].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(early, 1e-4, "reverb should produce energy after the impulse")
        XCTAssertGreaterThan(late, 1e-6, "tail should still be audible at 0.7s")
        XCTAssertLessThan(late, early, "tail must decay, not grow")
    }

    /// Higher feedback must ring longer. Guards against mis-ported feedback.
    func testMoreFeedbackDecaysSlower() {
        var input = [Float](repeating: 0, count: 48_000)
        input[0] = 1.0
        let short = run(ReverbStage(feedback: 0.6, lowpassHz: 10_000, mix: 1.0), input)
        let long = run(ReverbStage(feedback: 0.95, lowpassHz: 10_000, mix: 1.0), input)
        func energy(_ x: [Float]) -> Float {
            x[24_000..<48_000].reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertGreaterThan(energy(long), energy(short) * 2)
    }

    /// Output must stay finite. A NaN here would persist in the delay lines
    /// for the rest of the session.
    func testOutputStaysFinite() {
        let input = (0..<48_000).map { _ in Float.random(in: -1...1) }
        let out = run(ReverbStage(feedback: 0.97, lowpassHz: 12_000, mix: 1.0), input)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testDryMixIsTransparent() {
        let input = (0..<1000).map { Float(sin(Double($0) * 0.05)) }
        let out = run(ReverbStage(feedback: 0.9, lowpassHz: 10_000, mix: 0.0), input)
        for i in 0..<input.count {
            XCTAssertEqual(out[i], input[i], accuracy: 1e-5)
        }
    }

    /// Eight modulated delay lines with fractional read positions — by far the
    /// most state of any stage, and the place a chunking bug would hide.
    func testChunkInvariance() {
        let input = (0..<20_000).map { Float(sin(Double($0) * 0.01)) }
        let expected = run(ReverbStage(feedback: 0.9, lowpassHz: 10_000, mix: 1.0), input)

        let stage = ReverbStage(feedback: 0.9, lowpassHz: 10_000, mix: 1.0)
        stage.prepare(sampleRate: 48_000, maxBlock: 20_000)
        var actual = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            actual.withUnsafeMutableBufferPointer { o in
                for size in [1, 17, 512, 4_099, 15_371] {
                    let n = min(size, input.count - i)
                    if n <= 0 { break }
                    stage.process(inBuf.baseAddress! + i, o.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        for k in 0..<i {
            XCTAssertEqual(actual[k], expected[k], accuracy: 1e-5, "mismatch at \(k)")
        }
    }
}
