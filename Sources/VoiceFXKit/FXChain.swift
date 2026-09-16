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
        precondition(maxBlock > 0, "FXChain used before prepare(sampleRate:maxBlock:); call prepare first")
        precondition(frames <= maxBlock, "frames (\(frames)) exceeds maxBlock (\(maxBlock)); call prepare with a larger maxBlock")
        guard !stages.isEmpty else {
            output.update(from: input, count: frames)
            return
        }
        bufA.withUnsafeMutableBufferPointer { a in
            bufB.withUnsafeMutableBufferPointer { b in
                // The chain is the single choke point for non-finite input:
                // sanitise here, once, rather than every stage re-implementing
                // its own NaN/Inf guard. Stateful stages (Butterworth, DC
                // block) have IIR memory that a single non-finite sample
                // would poison permanently, and this runs upstream of every
                // stage, including the first (Butterworth highpass in every
                // preset). DriveStage and ReverbStage keep their own guards
                // too, as defence in depth.
                //
                // Sanitise straight into `b`, the scratch buffer the first
                // stage isn't writing to yet, so no extra buffer is needed.
                for i in 0..<frames {
                    let v = input[i]
                    b[i] = v.isFinite ? v : 0
                }
                // The first stage reads the sanitised copy; every later stage
                // reads what its predecessor wrote. `current` always points at
                // the freshest samples.
                stages[0].process(UnsafePointer(b.baseAddress!), a.baseAddress!, frames: frames)
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
        precondition(maxBlock > 0, "FXChain used before prepare(sampleRate:maxBlock:); call prepare first")
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

    /// Same as `applyWhole`, but compensates for the chain's declared
    /// `latencyFrames` (the pitch shifter's ~120 ms, at any sample rate) so
    /// the returned buffer stays aligned with `input` and has exactly the
    /// same length. Without this, every processed utterance gets leading
    /// silence prepended and loses real audio off its tail — usually masked
    /// by trailing silence in TTS output, but audible on a short or
    /// tightly-trimmed line.
    ///
    /// `latency` zero samples are appended before processing so the chain is
    /// flushed and the tail of real audio emerges; the leading `latency`
    /// samples of the result (which correspond to that flush, not to real
    /// input) are then dropped.
    public func applyWholeLatencyCompensated(_ input: [Float]) -> [Float] {
        let latency = latencyFrames
        guard latency > 0, !input.isEmpty else { return applyWhole(input) }
        var padded = input
        padded.append(contentsOf: [Float](repeating: 0, count: latency))
        let processed = applyWhole(padded)
        guard latency < processed.count else {
            // Pathological case (latency consumes the whole flushed buffer).
            // Returning the untrimmed result beats handing back silence.
            return processed
        }
        return Array(processed[latency...])
    }
}
