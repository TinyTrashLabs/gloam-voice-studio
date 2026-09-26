import Foundation

/// One stage of a voice-effects chain.
///
/// Stages are stateful across calls by design: a stage fed one long buffer and
/// the same stage fed that buffer in chunks must produce identical output.
/// That property is what lets one implementation serve a whole-buffer caller
/// and a streaming caller without a second code path.
///
/// A conformer is a `final class`, never a struct — the state is the point.
public protocol FXStage: AnyObject {
    /// Processing delay this stage introduces, in frames. Valid after `prepare`.
    var latencyFrames: Int { get }

    /// Allocate here, and only here. Called before any `process`; may be
    /// called again to re-prepare at a new rate or block size.
    func prepare(sampleRate: Double, maxBlock: Int)

    /// Transform `frames` samples from `input` into `output`.
    ///
    /// Must not allocate, lock, or block: a realtime driver would call this on
    /// the audio thread. `input` and `output` must not overlap.
    func process(_ input: UnsafePointer<Float>,
                 _ output: UnsafeMutablePointer<Float>,
                 frames: Int)

    /// Clear internal state — filter memory, delay lines, oscillator phase.
    /// Called between utterances, not between chunks of one utterance.
    func reset()
}

public extension FXStage {
    var latencyFrames: Int { 0 }
}
