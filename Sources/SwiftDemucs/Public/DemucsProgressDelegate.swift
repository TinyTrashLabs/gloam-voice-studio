import Foundation

/// Delegate protocol for receiving vocal separation progress and completion events.
///
/// Conform to this protocol to receive callbacks during the delegate-based
/// (fire-and-forget) API style. All callbacks are dispatched on the main actor.
///
/// ```swift
/// class ViewModel: DemucsProgressDelegate {
///     func demucs(_ separator: VocalSeparator,
///                 didUpdateProgress progress: Float,
///                 stage: DemucsStage) {
///         self.progress = progress
///         self.stageLabel = stage.rawValue
///     }
///
///     func demucs(_ separator: VocalSeparator,
///                 didCompleteWithResult result: Result<StemResult, DemucsError>) {
///         switch result {
///         case .success(let stem):
///             self.outputURL = stem.outputURL
///         case .failure(let error):
///             self.errorMessage = error.localizedDescription
///         }
///     }
/// }
/// ```
@MainActor
public protocol DemucsProgressDelegate: AnyObject {

    /// Called periodically as separation progresses.
    ///
    /// - Parameters:
    ///   - separator: The ``VocalSeparator`` instance performing the separation.
    ///   - progress: Overall progress fraction from 0.0 to 1.0.
    ///   - stage: The current processing ``DemucsStage``.
    func demucs(
        _ separator: VocalSeparator,
        didUpdateProgress progress: Float,
        stage: DemucsStage
    )

    /// Called exactly once when separation finishes (either successfully or with an error).
    ///
    /// - Parameters:
    ///   - separator: The ``VocalSeparator`` instance that completed.
    ///   - result: A ``Result`` containing either the ``StemResult`` or a ``DemucsError``.
    func demucs(
        _ separator: VocalSeparator,
        didCompleteWithResult result: Result<StemResult, DemucsError>
    )
}
