import Foundation

/// Progress update emitted during vocal separation.
///
/// Yielded by ``VocalSeparator/separationStream(from:to:)`` and forwarded
/// to ``DemucsProgressDelegate`` during processing.
public struct DemucsProgress: Sendable {

    /// Overall progress fraction from 0.0 (not started) to 1.0 (complete).
    public let fraction: Float

    /// The current processing stage.
    public let stage: DemucsStage

    /// Wall-clock seconds elapsed since separation began.
    public let elapsedSeconds: Double

    public init(fraction: Float, stage: DemucsStage, elapsedSeconds: Double) {
        self.fraction = fraction
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
    }
}
