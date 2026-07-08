import Foundation

/// Pure height math for an auto-growing, drag-resizable text editor — kept
/// framework-free so it's unit-testable without SwiftUI.
public enum ExpandableTextHeight {
    /// Auto-grow estimate for a TextEditor: ~18pt per line + 16pt padding,
    /// clamped to [min, max].
    public static func forLineCount(_ lines: Int, min: Double, max: Double) -> Double {
        let estimated = Double(lines) * 18 + 16
        return Swift.min(Swift.max(estimated, min), max)
    }

    /// A manually-dragged height: `base` plus the pointer's drag delta,
    /// clamped to [min, max].
    public static func dragged(base: Double, delta: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(base + delta, min), max)
    }
}
