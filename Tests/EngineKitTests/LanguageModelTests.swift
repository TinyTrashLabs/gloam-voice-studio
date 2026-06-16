import XCTest
@testable import EngineKit

final class LanguageModelTests: XCTestCase {
    func testStripRemovesThinkBlock() {
        let raw = "<think>let me reason about this</think>Play \"One More Time\"."
        XCTAssertEqual(stripThinking(raw), "Play \"One More Time\".")
    }

    func testStripRemovesMultilineThinkBlock() {
        let raw = "<think>\nline one\nline two\n</think>\n\nThe answer."
        XCTAssertEqual(stripThinking(raw), "The answer.")
    }

    func testStripLeavesCleanTextUntouched() {
        XCTAssertEqual(stripThinking("Just a clean line."), "Just a clean line.")
    }

    func testStripHandlesUnterminatedThink() {
        XCTAssertEqual(stripThinking("hello <think>partial"), "hello")
    }

    func testChatRequestDefaults() {
        let r = ChatRequest(messages: [ChatTurn(role: .user, content: "hi")])
        XCTAssertEqual(r.temperature, 0.7)
        XCTAssertNil(r.tools)
        XCTAssertTrue(r.disableThinking)
    }
}
