import MLX
import MLXNN
import MLXRandom
import XCTest

@testable import EngineKit

/// `RelPositionMultiheadAttentionWeights` computes its weights a block of
/// query rows at a time (memory: the full path held ~7 (heads, T, T) tensors
/// per layer). The blocked weights must equal the full path's. An all-false
/// `attnMask` routes a call through the original full computation with
/// identical arithmetic, so it is the reference here.
final class LuxAttentionBlockedTests: XCTestCase {
    private func weights(
        seqLen: Int, batch: Int, rowsPerBlock: Int?, padTail: Int = 0
    ) -> (blocked: MLXArray, full: MLXArray) {
        MLXRandom.seed(7)
        let attn = RelPositionMultiheadAttentionWeights(
            embedDim: 64, posDim: 48, numHeads: 4, queryHeadDim: 32, posHeadDim: 4)
        // Non-trivial weights: the default init is fine, but scale the input
        // so the softmax is not near-uniform.
        let x = MLXRandom.normal([seqLen, batch, 64]) * 2
        let posEmb = CompactRelPositionalEncoding(48)(x)
        var padding: MLXArray? = nil
        if padTail > 0 {
            let row = (0 ..< seqLen).map { $0 >= seqLen - padTail }
            padding = MLXArray(Array(repeating: row, count: batch).flatMap { $0 }, [batch, seqLen])
        }
        attn.rowsPerBlockOverride = rowsPerBlock
        let blocked = attn(x, posEmb: posEmb, keyPaddingMask: padding)
        let noMask = MLXArray.zeros([seqLen, seqLen], dtype: .bool)
        let full = attn(x, posEmb: posEmb, keyPaddingMask: padding, attnMask: noMask)
        eval(blocked, full)
        return (blocked, full)
    }

    private func assertClose(_ a: MLXArray, _ b: MLXArray, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.shape, b.shape, file: file, line: line)
        let diff = MLX.abs(a - b).max().item(Float.self)
        XCTAssertLessThan(diff, 1e-5, "max |blocked - full| = \(diff)", file: file, line: line)
    }

    func testManyUnevenBlocksMatchTheFullPath() {
        // 37 rows per block over 200 frames: five full blocks and a short one.
        let (blocked, full) = weights(seqLen: 200, batch: 1, rowsPerBlock: 37)
        assertClose(blocked, full)
        XCTAssertEqual(MLX.abs(blocked - full).max().item(Float.self), 0)
    }

    func testBlocksThatWouldLeaveARemainderRowMatchTheFullPath() {
        // 7 rows over 50 frames would leave a one-row block; the even split
        // gives 7,7,6,6,6,6,6,6 instead.
        let (blocked, full) = weights(seqLen: 50, batch: 1, rowsPerBlock: 7)
        XCTAssertEqual(MLX.abs(blocked - full).max().item(Float.self), 0)
    }

    func testDefaultBlockingWithBatchAndPaddingMatchesTheFullPath() {
        let (blocked, full) = weights(seqLen: 120, batch: 2, rowsPerBlock: 16, padTail: 9)
        assertClose(blocked, full)
        // And the default sizing (one block at this length).
        let (one, ref) = weights(seqLen: 120, batch: 2, rowsPerBlock: nil, padTail: 9)
        assertClose(one, ref)
    }

    func testRowsSumToOne() {
        let (blocked, _) = weights(seqLen: 90, batch: 1, rowsPerBlock: 20)
        let sums = blocked.sum(axis: -1)
        XCTAssertLessThan(MLX.abs(sums - 1).max().item(Float.self), 1e-5)
    }
}
