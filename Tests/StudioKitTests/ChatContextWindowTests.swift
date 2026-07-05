import XCTest
import EngineKit
@testable import StudioKit

final class ChatContextWindowTests: XCTestCase {
    private func turn(_ role: ChatRole, chars: Int) -> ChatTurn {
        ChatTurn(role: role, content: String(repeating: "x", count: chars))
    }

    func testUnderBudgetKeepsEverything() {
        let turns = [turn(.system, chars: 40), turn(.user, chars: 40), turn(.assistant, chars: 40)]
        XCTAssertEqual(ChatContextWindow.trim(turns: turns, budgetTokens: 1000), turns)
    }

    func testOldestNonSystemTurnsDropFirst() {
        // system(10 tok) + 4×(25 tok). Budget 65 → system + last two fit (10+25+25=60).
        let turns = [turn(.system, chars: 40),
                     turn(.user, chars: 100), turn(.assistant, chars: 100),
                     turn(.user, chars: 100), turn(.assistant, chars: 100)]
        let trimmed = ChatContextWindow.trim(turns: turns, budgetTokens: 65)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed[0].role, .system)
        XCTAssertEqual(trimmed[1], turns[3])
        XCTAssertEqual(trimmed[2], turns[4])
    }

    func testFinalTurnAlwaysKept() {
        let turns = [turn(.system, chars: 40), turn(.user, chars: 10_000)]
        let trimmed = ChatContextWindow.trim(turns: turns, budgetTokens: 20)
        XCTAssertEqual(trimmed.count, 2, "system + oversized final turn must survive")
        XCTAssertEqual(trimmed[1], turns[1])
    }

    func testEmptyInput() {
        XCTAssertEqual(ChatContextWindow.trim(turns: [], budgetTokens: 100), [])
    }

    func testEstimateTokensFloor() {
        XCTAssertEqual(ChatContextWindow.estimateTokens(""), 1)
        XCTAssertEqual(ChatContextWindow.estimateTokens(String(repeating: "a", count: 400)), 100)
    }
}
