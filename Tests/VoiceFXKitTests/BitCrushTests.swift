import XCTest
@testable import VoiceFXKit

final class BitCrushTests: XCTestCase {
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

    /// DC block removes a constant offset while leaving the AC content.
    func testDCBlockRemovesOffset() {
        let input = [Float](repeating: 0.5, count: 4000)
        let out = run(DCBlockStage(), input)
        XCTAssertGreaterThan(abs(out[0]), 0.4, "should pass the initial step")
        XCTAssertLessThan(abs(out[3999]), 0.01, "offset should decay away")
    }

    /// Low bit depth must collapse distinct inputs onto a small set of levels.
    func testBitCrushQuantisesToFewLevels() {
        let input = (0..<2000).map { Float($0) / 2000.0 - 0.5 }
        let out = run(BitCrushStage(bitDepth: 3, targetRate: 48_000), input)
        let levels = Set(out.map { (Double($0) * 10_000).rounded() })
        XCTAssertLessThan(levels.count, 20, "3-bit crush should collapse to few levels, got \(levels.count)")
    }

    /// Reducing the target rate holds samples, so the output has long runs of
    /// identical values that the input does not.
    func testSampleRateReductionHoldsSamples() {
        let input = (0..<2000).map { Float(sin(Double($0) * 0.05)) }
        let out = run(BitCrushStage(bitDepth: 16, targetRate: 4_000), input)
        var maxRun = 1, run_ = 1
        for i in 1..<out.count {
            if out[i] == out[i - 1] { run_ += 1; maxRun = max(maxRun, run_) } else { run_ = 1 }
        }
        XCTAssertGreaterThan(maxRun, 5, "48k→4k should hold each sample ~12 frames")
    }

    func testBitCrushChunkInvariance() {
        let input = (0..<3000).map { Float(sin(Double($0) * 0.02)) }
        let expected = run(BitCrushStage(bitDepth: 6, targetRate: 8_000), input)

        let stage = BitCrushStage(bitDepth: 6, targetRate: 8_000)
        stage.prepare(sampleRate: 48_000, maxBlock: 3000)
        var actual = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            actual.withUnsafeMutableBufferPointer { o in
                for size in [1, 5, 128, 997, 1869] {
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
}
