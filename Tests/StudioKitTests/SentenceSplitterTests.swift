import XCTest
@testable import StudioKit

final class SentenceSplitterTests: XCTestCase {
    func testBasicSplit() {
        XCTAssertEqual(
            SentenceSplitter.split("Hello there. How are you today? Great!"),
            ["Hello there.", "How are you today?", "Great!"])
    }

    func testAbbreviationsDoNotSplit() {
        XCTAssertEqual(
            SentenceSplitter.split("Dr. Smith arrived. He was late."),
            ["Dr. Smith arrived.", "He was late."])
    }

    func testInitialsDoNotSplit() {
        XCTAssertEqual(
            SentenceSplitter.split("J. R. Hartley wrote it. Truly."),
            ["J. R. Hartley wrote it.", "Truly."])
    }

    func testTrailingTextWithoutTerminatorIsKept() {
        XCTAssertEqual(
            SentenceSplitter.split("First sentence. and then a trailing thought"),
            ["First sentence.", "and then a trailing thought"])
    }

    func testPunctuationRunsStayTogether() {
        XCTAssertEqual(
            SentenceSplitter.split("Really?! Yes... okay."),
            ["Really?!", "Yes...", "okay."])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(SentenceSplitter.split(""), [])
        XCTAssertEqual(SentenceSplitter.split("   \n "), [])
    }

    func testSingleSentenceStaysWhole() {
        XCTAssertEqual(SentenceSplitter.split("Just one line"), ["Just one line"])
    }
}
