import XCTest
@testable import EngineKit

/// Breeze stops at 60 s of speech per call; LongTextChunker keeps every piece
/// it is handed comfortably under that.
final class LongTextChunkerTests: XCTestCase {
    func testShortLineIsOnePieceUnchanged() {
        XCTAssertEqual(LongTextChunker.chunks("  (laugh) Hello there. How are you?  "),
                       ["(laugh) Hello there. How are you?"])
    }

    func testEmptyLineIsNoPieces() {
        XCTAssertEqual(LongTextChunker.chunks("   \n "), [])
    }

    func testLongEnglishSplitsOnSentencesAndLosesNoWords() {
        let sentence = "This sentence is here to make the paragraph long enough to need splitting. "
        let text = String(repeating: sentence, count: 40)   // ~200 s estimated
        let pieces = LongTextChunker.chunks(text)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(piece), 40)
            XCTAssertTrue(piece.hasSuffix("."), "pieces end on a sentence boundary: \(piece)")
        }
        XCTAssertEqual(pieces.joined(separator: " ").split(separator: " "),
                       text.split(separator: " "))
    }

    func testRunOnSentenceFallsBackToWordBoundaries() {
        let text = String(repeating: "word ", count: 400)   // no terminator at all
        let pieces = LongTextChunker.chunks(text)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(piece), 40)
            XCTAssertFalse(piece.hasPrefix(" ") || piece.hasSuffix(" "))
        }
        XCTAssertEqual(pieces.joined(separator: " ").split(separator: " ").count, 400)
    }

    func testChineseSplitsOnFullWidthStopsAndCountsSlower() {
        // CJK is estimated at ~4.5 chars/s, so far fewer characters fit.
        XCTAssertGreaterThan(LongTextChunker.estimatedSeconds("欢迎来到今晚的故事时间"),
                             LongTextChunker.estimatedSeconds("Welcome to story time"))
        let text = String(repeating: "欢迎来到今晚的故事时间，让我们一起开始吧。", count: 20)
        let pieces = LongTextChunker.chunks(text)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(piece), 40)
            XCTAssertTrue(piece.hasSuffix("。"))
        }
        XCTAssertEqual(pieces.joined(), text)
    }

    func testUnpunctuatedChineseFallsBackToCharacters() {
        let text = String(repeating: "欢迎来到故事时间", count: 40)
        let pieces = LongTextChunker.chunks(text)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), text)
    }
}
