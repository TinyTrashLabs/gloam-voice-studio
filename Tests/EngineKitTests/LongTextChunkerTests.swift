import XCTest
@testable import EngineKit

/// Breeze stops at 60 s of speech per call; LongTextChunker keeps every piece
/// it is handed comfortably under that.
final class LongTextChunkerTests: XCTestCase {
    func testShortLineIsOnePieceUnchanged() {
        XCTAssertEqual(LongTextChunker.chunks("  (laugh) Hello there. How are you?  ", maxSeconds: 40),
                       ["(laugh) Hello there. How are you?"])
    }

    func testEmptyLineIsNoPieces() {
        XCTAssertEqual(LongTextChunker.chunks("   \n ", maxSeconds: 40), [])
    }

    func testLongEnglishSplitsOnSentencesAndLosesNoWords() {
        let sentence = "This sentence is here to make the paragraph long enough to need splitting. "
        let text = String(repeating: sentence, count: 40)   // ~200 s estimated
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
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
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
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
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(piece), 40)
            XCTAssertTrue(piece.hasSuffix("。"))
        }
        XCTAssertEqual(pieces.joined(), text)
    }

    func testUnpunctuatedChineseFallsBackToCharacters() {
        let text = String(repeating: "欢迎来到故事时间", count: 40)
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), text)
    }

    func testNumbersVersionsAndDomainsAreNeverSplit() {
        // A Latin stop only ends a sentence when whitespace follows.
        let text = String(repeating: "Growth hit 55.2 percent on v1.2 per example.com today. ", count: 30)
        XCTAssertEqual(LongTextChunker.sentences("It was 55.2 percent. Next.").count, 2)
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertTrue(piece.hasPrefix("Growth"), "a piece starts mid-sentence: \(piece)")
            XCTAssertTrue(piece.hasSuffix("today."))
        }
    }

    func testClosingQuotesStayWithTheirSentence() {
        XCTAssertEqual(LongTextChunker.sentences(#"He said "hi." Then left."#),
                       [#"He said "hi." "#, "Then left."])
    }

    func testSentencesReproduceTheInputExactly() {
        let text = "One. Two!  Three?\n\nFour。五！ Six"
        XCTAssertEqual(LongTextChunker.sentences(text).joined(), text)
    }

    func testMixedCJKRunOnWithASpaceStaysUnderTheCap() {
        // One space used to flip the fallback into word mode and emit a 57 s
        // "word" — past Breeze's 60 s cap at a real speaking rate.
        let text = "我们今天要讲" + String(repeating: "很长的故事", count: 50) + " iPhone "
            + String(repeating: "很长的故事", count: 10)
        let pieces = LongTextChunker.chunks(text, maxSeconds: 40)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces { XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(piece), 40) }
    }

    func testTagsAreNeverCutInHalf() {
        let text = "(clears throat) " + String(repeating: "word ", count: 400)
            + String(repeating: "(clears throat) [叹气] ", count: 20)
        for piece in LongTextChunker.chunks(text, maxSeconds: 40) {
            XCTAssertEqual(piece.filter { $0 == "(" }.count, piece.filter { $0 == ")" }.count, piece)
            XCTAssertEqual(piece.filter { $0 == "[" }.count, piece.filter { $0 == "]" }.count, piece)
        }
    }

    // MARK: - How GloamEngine applies it

    func testUncappedBackendIsAlwaysOnePass() {
        let plan = ProviderRequest(text: String(repeating: "A long sentence here. ", count: 200))
        XCTAssertEqual(GloamEngine.passes(of: plan, backend: .qwen17B).count, 1)
    }

    func testBreezeLongLineBecomesPassesThatKeepEverythingButText() {
        let plan = ProviderRequest(text: String(repeating: "A long sentence goes right here. ", count: 120),
                                   refAudioPath: "/tmp/r.wav", refText: "ref",
                                   temperature: 0.8, instruct: "calm", cfgScale: 5)
        let passes = GloamEngine.passes(of: plan, backend: .breezeTTS2)
        XCTAssertGreaterThan(passes.count, 1)
        for pass in passes {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(pass.text), 40)
            var expected = plan
            expected.text = pass.text
            XCTAssertEqual(pass, expected, "voice, direction and knobs ride every pass")
        }
    }

    func testBreezeShortLineIsOnePassUnchanged() {
        let plan = ProviderRequest(text: "  Hello.  ", instruct: "calm")
        XCTAssertEqual(GloamEngine.passes(of: plan, backend: .breezeTTS2), [plan],
                       "a single pass is the plan itself, untouched")
    }

    func testWindowsLineBreaksEndSentences() {
        XCTAssertEqual(LongTextChunker.sentences("Line one\r\nLine two\r\nLine three"),
                       ["Line one\r\n", "Line two\r\n", "Line three"])
    }

    func testEstimateLeavesRoomForASlowDelivery() {
        // ~126 words at a slow 100 wpm is ~76 s. The estimate must call that
        // well over a 40 s piece, so it gets split before Breeze's 60 s cap.
        let words = String(repeating: "steady narration ", count: 63)
        XCTAssertGreaterThan(LongTextChunker.estimatedSeconds(words), 60)
    }

    func testAnchoredDesignOpensWithAShortPassThenKeepsTheRest() {
        let text = String(repeating: "A long sentence goes right here. ", count: 120)
        let plan = ProviderRequest(text: text, instruct: "a warm narrator")   // design: no reference
        XCTAssertTrue(GloamEngine.needsIdentityAnchor(plan, backend: .breezeTTS2))
        let passes = GloamEngine.passes(of: plan, backend: .breezeTTS2)
        XCTAssertGreaterThan(passes.count, 2)
        XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(passes[0].text),
                                 GloamEngine.anchorSeconds)
        XCTAssertEqual(passes.map(\.text).joined(separator: " ").split(separator: " "),
                       text.split(separator: " "), "nothing lost or reordered")
    }

    func testAnchorNeverEndsMidSentence() {
        // A first sentence past the ~12 s anchor target (~20 s estimated) but
        // well inside a piece. Cutting it would put a gap mid-sentence AND
        // hand the later passes a reference that stops mid-phrase, which a
        // continuation model carries into every seam. It stays whole.
        let opening = String(repeating: "word ", count: 39) + "end."
        let text = opening + " " + String(repeating: "A long sentence goes right here. ", count: 120)
        let plan = ProviderRequest(text: text, instruct: "a warm narrator")
        XCTAssertGreaterThan(LongTextChunker.estimatedSeconds(opening), GloamEngine.anchorSeconds)
        let passes = GloamEngine.passes(of: plan, backend: .breezeTTS2)
        XCTAssertEqual(passes.first?.text, opening)
        XCTAssertEqual(passes.map(\.text).joined(separator: " ").split(separator: " "),
                       text.split(separator: " "), "nothing lost or reordered")
    }

    func testACloneIsNeverReAnchored() {
        let plan = ProviderRequest(text: "x", refAudioPath: "/tmp/r.wav", refText: "ref")
        XCTAssertFalse(GloamEngine.needsIdentityAnchor(plan, backend: .breezeTTS2))
    }
}
