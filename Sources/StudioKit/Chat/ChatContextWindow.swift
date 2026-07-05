import EngineKit
import Foundation

/// Sliding-window history trimming for chat requests. Token counts use a
/// rough chars/4 heuristic — good enough to keep requests inside the model's
/// context; exactness doesn't matter because budgets carry headroom.
public enum ChatContextWindow {
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Keeps a leading system turn unconditionally, then the longest suffix of
    /// the remaining turns that fits `budgetTokens`. The final turn (the user
    /// message being answered) is always kept, even if it alone exceeds budget.
    public static func trim(turns: [ChatTurn], budgetTokens: Int) -> [ChatTurn] {
        guard !turns.isEmpty else { return [] }
        var rest = turns
        var system: [ChatTurn] = []
        if rest.first?.role == .system { system = [rest.removeFirst()] }
        var budget = budgetTokens - system.reduce(0) { $0 + estimateTokens($1.content) }
        var kept: [ChatTurn] = []
        for turn in rest.reversed() {
            let cost = estimateTokens(turn.content)
            if !kept.isEmpty && cost > budget { break }
            kept.insert(turn, at: 0)
            budget -= cost
        }
        return system + kept
    }
}
