import Foundation

/// Which of several text fields a click-to-insert chip should write into.
///
/// One text box needs no such rule; a list of them does. Clicking a tag chip is
/// a click somewhere other than the text, so by the time the insert happens the
/// field the user was writing in may no longer hold focus — the answer has to
/// fall back to the one that held it last.
public enum TagInsertionTarget {
    /// The focused field, else the last one that had focus, else nothing.
    ///
    /// A remembered field that no longer exists resolves to nothing rather than
    /// to a neighbour. Inserting into a line the user never chose is quiet and
    /// wrong, which is worse than a chip that declines to do anything.
    public static func resolve<ID: Hashable>(focused: ID?, lastFocused: ID?,
                                             existing: [ID]) -> ID? {
        let present = Set(existing)
        if let focused, present.contains(focused) { return focused }
        if let lastFocused, present.contains(lastFocused) { return lastFocused }
        return nil
    }
}
