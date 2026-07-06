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

final class SplitterAbbreviationTests: XCTestCase {
    func testDottedAbbreviationsDoNotSplit() {
        XCTAssertEqual(SentenceSplitter.split("See you at 5 p.m. tomorrow, e.g. after work."),
                       ["See you at 5 p.m. tomorrow, e.g. after work."])
    }

    func testPlainAmStillEndsASentence() {
        // "a.m" is matched with its dots — bare "am" must not be swallowed.
        XCTAssertEqual(SentenceSplitter.split("Here I am. Ready now."),
                       ["Here I am.", "Ready now."])
    }

    func testBusinessAbbreviationsDoNotSplit() {
        XCTAssertEqual(SentenceSplitter.split("Acme Inc. was founded on Baker Blvd. in 1999."),
                       ["Acme Inc. was founded on Baker Blvd. in 1999."])
    }
}

final class FadeEdgesTests: XCTestCase {
    func testEdgesFadeAndMiddleUntouched() {
        let samples = [Float](repeating: 1.0, count: 2400)   // 100ms @ 24k
        let faded = AudioAssembler.fadeEdges(samples, sampleRate: 24_000)   // 8ms = 192
        XCTAssertEqual(faded[0], 0, accuracy: 1e-6)
        XCTAssertEqual(faded[faded.count - 1], 0, accuracy: 1e-6)
        XCTAssertLessThan(faded[96], 1.0)                     // mid-ramp
        XCTAssertEqual(faded[1200], 1.0, accuracy: 1e-6)      // middle untouched
        XCTAssertEqual(faded.count, samples.count)
    }

    func testTinyClipDoesNotCrash() {
        XCTAssertEqual(AudioAssembler.fadeEdges([0.5], sampleRate: 24_000).count, 1)
        XCTAssertTrue(AudioAssembler.fadeEdges([], sampleRate: 24_000).isEmpty)
    }
}
