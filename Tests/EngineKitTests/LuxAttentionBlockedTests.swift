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

    /// Applying the weights a row block at a time (the layer's path) gives
    /// the whole-tensor product: rows of a matmul are independent, only the
    /// GEMM tiling (rounding) can differ.
    func testRowBlocksApplyLikeTheWholeWeights() {
        MLXRandom.seed(7)
        let attn = RelPositionMultiheadAttentionWeights(
            embedDim: 64, posDim: 48, numHeads: 4, queryHeadDim: 32, posHeadDim: 4)
        let (seqLen, batch) = (Int(ProcessInfo.processInfo.environment["LUXBLOCKS_T"] ?? "") ?? 300, 1)
        let x = MLXRandom.normal([seqLen, batch, 64]) * 2
        let posEmb = CompactRelPositionalEncoding(48)(x)
        attn.rowsPerBlockOverride = seqLen == 300 ? 37 : nil
        let scores = attn.scores(x, posEmb: posEmb)
        let v = MLXRandom.normal([4, batch, seqLen, 12])
        let whole = matmul(scores.weights(), v)
        let blocks = scores.evaluatedBlocks()
        if seqLen == 300 { XCTAssertEqual(blocks.blocks.count, 9) }
        let blocked = blocks.apply(v)
        // NonlinAttention's use: head 0 against its own one-head values.
        let v1 = MLXRandom.normal([1, batch, seqLen, 36])
        let head0 = blocks.apply(v1, heads: 0 ..< 1)
        let whole0 = matmul(scores.weights()[0 ..< 1], v1)
        eval(whole, blocked, head0, whole0)
        let rel = (MLX.abs(blocked - whole).max() / MLX.abs(whole).max()).item(Float.self)
        XCTAssertLessThan(rel, 1e-6, "max |blocked - whole| / max |whole| = \(rel)")
        let rel0 = (MLX.abs(head0 - whole0).max() / MLX.abs(whole0).max()).item(Float.self)
        XCTAssertLessThan(rel0, 1e-6)
        print("LUXBLOCKS rel diff \(rel), head0 \(rel0)")
    }
}
