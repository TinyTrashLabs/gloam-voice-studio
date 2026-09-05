import Foundation

/// Rate-limits progress reporting to something a UI can actually draw.
///
/// A download reports bytes far faster than a screen refreshes, and each
/// report costs a full SwiftUI invalidation when it lands on observed state.
/// Reporting every megabyte of a fast download is ~100 updates a second, which
/// saturates the main thread rebuilding a view tree nobody can see change that
/// fast — measured as the cause of choppy scrolling during a model download.
///
/// Both conditions must hold before a report passes: enough time AND enough
/// movement. Time alone still floods a fast download's first seconds; movement
/// alone still floods when the total is large.
///
/// Not thread-safe by design — it belongs to one sequential download loop.
/// `Sendable` conformance would invite sharing it across tasks, where its
/// answers would be wrong.
public struct ProgressThrottle {
    /// Minimum seconds between reports. 0.1 is ten updates a second: faster
    /// than the eye resolves a number changing, far below what the compositor
    /// gives up a frame for.
    public let minimumInterval: Double
    /// Minimum movement, as a fraction of the whole, between reports.
    public let minimumDelta: Double

    private var lastReported: Double = -.infinity
    private var lastAt: Date = .distantPast

    public init(minimumInterval: Double = 0.1, minimumDelta: Double = 0.0025) {
        self.minimumInterval = minimumInterval
        self.minimumDelta = minimumDelta
    }

    /// Whether `fraction` should be reported now.
    ///
    /// `force` is for the terminal report: a download that ends between ticks
    /// must still land on its final value rather than stopping at 0.97.
    public mutating func shouldReport(_ fraction: Double, force: Bool = false,
                                      now: Date = Date()) -> Bool {
        guard !force else {
            lastReported = fraction; lastAt = now
            return true
        }
        // Backwards movement is reported: it means a retry or a recount, and
        // leaving a stale higher number on screen is worse than an extra draw.
        let moved = fraction < lastReported || fraction - lastReported >= minimumDelta
        guard moved, now.timeIntervalSince(lastAt) >= minimumInterval else { return false }
        lastReported = fraction
        lastAt = now
        return true
    }
}
