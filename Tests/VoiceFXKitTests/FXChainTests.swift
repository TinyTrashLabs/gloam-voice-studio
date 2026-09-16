import XCTest
@testable import VoiceFXKit

final class FXChainTests: XCTestCase {
    /// Two gain stages in series multiply. Proves composition and buffer
    /// hand-off between stages, which every later stage relies on.
    func testChainAppliesStagesInSeries() {
        let chain = FXChain(stages: [GainStage(gain: 2), GainStage(gain: 3)])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        let out = chain.applyWhole([1, 2, 3])
        XCTAssertEqual(out, [6, 12, 18])
    }

    /// The keystone property, proven here on a trivial chain so the harness
    /// exists before any stateful stage does.
    func testWholeBufferEqualsChunked() {
        let input = (0..<1000).map { Float(sin(Double($0) * 0.01)) }
        let whole = FXChain(stages: [GainStage(gain: 0.5)])
        whole.prepare(sampleRate: 48_000, maxBlock: 1000)
        let expected = whole.applyWhole(input)

        let chunked = FXChain(stages: [GainStage(gain: 0.5)])
        chunked.prepare(sampleRate: 48_000, maxBlock: 1000)
        var actual: [Float] = []
        var i = 0
        for size in [1, 7, 64, 3, 200, 500, 229] {
            let n = min(size, input.count - i)
            if n <= 0 { break }
            var outBuf = [Float](repeating: 0, count: n)
            input.withUnsafeBufferPointer { inBuf in
                outBuf.withUnsafeMutableBufferPointer { o in
                    chunked.process(inBuf.baseAddress! + i, o.baseAddress!, frames: n)
                }
            }
            actual += outBuf
            i += n
        }
        XCTAssertEqual(actual.count, i)
        for k in 0..<i {
            XCTAssertEqual(actual[k], expected[k], accuracy: 1e-6)
        }
    }

    func testLatencyIsSumOfStages() {
        let chain = FXChain(stages: [FixedLatencyStage(latencyFrames: 3),
                                     FixedLatencyStage(latencyFrames: 40)])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        XCTAssertEqual(chain.latencyFrames, 43)
    }

    func testEmptyChainPassesThrough() {
        let chain = FXChain(stages: [])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        XCTAssertEqual(chain.applyWhole([1, 2, 3]), [1, 2, 3])
    }
}

/// Declares latency without doing anything to the signal, so latency
/// accounting can be tested independently of any real stage.
private final class FixedLatencyStage: FXStage {
    let latencyFrames: Int
    init(latencyFrames: Int) { self.latencyFrames = latencyFrames }
    func prepare(sampleRate: Double, maxBlock: Int) {}
    func process(_ input: UnsafePointer<Float>,
                 _ output: UnsafeMutablePointer<Float>,
                 frames: Int) {
        output.update(from: input, count: frames)
    }
    func reset() {}
}
