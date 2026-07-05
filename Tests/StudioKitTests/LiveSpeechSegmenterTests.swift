import XCTest
@testable import StudioKit

final class SplitStreamingTests: XCTestCase {
    func testHoldsBackIncompleteTail() {
        let (complete, remainder) = SentenceSplitter.splitStreaming("Hello there. How are")
        XCTAssertEqual(complete, ["Hello there."])
        XCTAssertEqual(remainder, " How are")
    }

    func testEndOfBufferIsNotABoundary() {
        // "3." could become "3.5" on the next delta.
        let (complete, remainder) = SentenceSplitter.splitStreaming("It costs 3.")
        XCTAssertEqual(complete, [])
        XCTAssertEqual(remainder, "It costs 3.")
    }

    func testBoundaryConfirmedByFollowingWhitespace() {
        let (complete, remainder) = SentenceSplitter.splitStreaming("Done! Next")
        XCTAssertEqual(complete, ["Done!"])
        XCTAssertEqual(remainder, " Next")
    }

    func testAbbreviationDoesNotSplit() {
        let (complete, remainder) = SentenceSplitter.splitStreaming("Ask Dr. Smith about")
        XCTAssertEqual(complete, [])
        XCTAssertEqual(remainder, "Ask Dr. Smith about")
    }

    func testRemainderIsVerbatimSoDeltasConcatenate() {
        let text = "One. Two point"
        let (_, remainder) = SentenceSplitter.splitStreaming(text)
        let (complete, _) = SentenceSplitter.splitStreaming(remainder + " five. Done")
        XCTAssertEqual(complete, ["Two point five."])
    }
}

final class LiveSpeechSegmenterTests: XCTestCase {
    func testSentencesEmergeAcrossDeltas() {
        var seg = LiveSpeechSegmenter()
        XCTAssertEqual(seg.consume("Hey the"), [])
        XCTAssertEqual(seg.consume("re! I'm spinning up"), ["Hey there!"])
        XCTAssertEqual(seg.consume(" the decks. One"), ["I'm spinning up the decks."])
        XCTAssertEqual(seg.finish(finalText: "Hey there! I'm spinning up the decks. One more."),
                       ["One more."])
        XCTAssertFalse(seg.derailed)
    }

    func testThinkBlockNeverReachesAudio() {
        var seg = LiveSpeechSegmenter()
        // Unterminated think: everything held back.
        XCTAssertEqual(seg.consume("<think>plan the reply. Okay."), [])
        XCTAssertEqual(seg.consume("</think>Sure thing! Coming"), ["Sure thing!"])
        XCTAssertEqual(seg.finish(finalText: "Sure thing! Coming right up."),
                       ["Coming right up."])
    }

    func testFinishSpeaksWholeReplyWhenNoBoundariesStreamed() {
        var seg = LiveSpeechSegmenter()
        XCTAssertEqual(seg.consume("Short reply"), [])
        XCTAssertEqual(seg.finish(finalText: "Short reply"), ["Short reply"])
    }

    func testMismatchedFinalTextDerailsInsteadOfDoubleSpeaking() {
        var seg = LiveSpeechSegmenter()
        _ = seg.consume("Alpha beta. Gam")
        // Final text disagrees with the streamed prefix.
        XCTAssertEqual(seg.finish(finalText: "Something else entirely."), [])
        XCTAssertTrue(seg.derailed)
    }

    func testDerailedSegmenterGoesQuiet() {
        var seg = LiveSpeechSegmenter()
        _ = seg.consume("One. Two.")
        _ = seg.finish(finalText: "Mismatch")
        XCTAssertEqual(seg.consume(" more text."), [])
        XCTAssertEqual(seg.finish(finalText: "whatever"), [])
    }
}
