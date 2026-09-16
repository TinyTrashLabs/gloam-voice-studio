import Foundation

/// An ordered series of `FXStage`s, with the scratch buffers to run them.
///
/// The chain owns two scratch buffers and ping-pongs between them, so stages
/// never alias their own input. Buffers are sized in `prepare`; `process`
/// allocates nothing.
public final class FXChain {
    public let stages: [FXStage]
    private var bufA: [Float] = []
    private var bufB: [Float] = []
    private var maxBlock = 0

    public init(stages: [FXStage]) { self.stages = stages }

    /// Sum of every stage's latency. Valid after `prepare`.
    public var latencyFrames: Int { stages.reduce(0) { $0 + $1.latencyFrames } }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        self.maxBlock = maxBlock
        bufA = [Float](repeating: 0, count: maxBlock)
        bufB = [Float](repeating: 0, count: maxBlock)
        for stage in stages { stage.prepare(sampleRate: sampleRate, maxBlock: maxBlock) }
    }

    public func reset() {
        for stage in stages { stage.reset() }
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        precondition(frames <= maxBlock, "frames (\(frames)) exceeds maxBlock (\(maxBlock)); call prepare with a larger maxBlock")
        guard !stages.isEmpty else {
            output.update(from: input, count: frames)
            return
        }
        bufA.withUnsafeMutableBufferPointer { a in
            bufB.withUnsafeMutableBufferPointer { b in
                // The first stage reads the caller's input; every later stage
                // reads what its predecessor wrote. `current` always points at
                // the freshest samples.
                stages[0].process(input, a.baseAddress!, frames: frames)
                var current = a.baseAddress!
                var other = b.baseAddress!
                for stage in stages.dropFirst() {
                    stage.process(UnsafePointer(current), other, frames: frames)
                    swap(&current, &other)
                }
                output.update(from: current, count: frames)
            }
        }
    }

    /// Convenience for whole-buffer callers. Deliberately loops the same block
    /// path rather than being a separate implementation, so the offline result
    /// cannot drift from the chunked one.
    public func applyWhole(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: input.count)
        var i = 0
        input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                while i < input.count {
                    let n = min(maxBlock, input.count - i)
                    process(inBuf.baseAddress! + i, outBuf.baseAddress! + i, frames: n)
                    i += n
                }
            }
        }
        return out
    }
}
