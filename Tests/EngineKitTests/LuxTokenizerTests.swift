import XCTest
@testable import EngineKit

/// Reference fixtures generated with the actual LuxTTS Python frontend
/// (zipvoice EnglishTextNormalizer + piper_phonemize 1.4.7, en-us) — see
/// LuxTokenizer.swift's header for the port notes.
final class LuxTokenizerTests: XCTestCase {

    private struct StubPhonemizer: PhonemizerProviding {
        let output: [String]
        func phonemize(_ text: String) throws -> [String] { output }
    }

    private func makeTokenizer(
        phonemizer: any PhonemizerProviding = StubPhonemizer(output: [])
    ) throws -> LuxTokenizer {
        try LuxTokenizer(phonemizer: phonemizer)
    }

    // MARK: vocab

    func testVocabLoadsFromBundle() throws {
        let tok = try makeTokenizer()
        XCTAssertEqual(tok.vocabSize, 360)
        XCTAssertEqual(tok.padID, 0)          // "_"
        XCTAssertEqual(tok.tokenToID["^"], 1)
        XCTAssertEqual(tok.tokenToID["$"], 2)
        XCTAssertEqual(tok.tokenToID[" "], 3) // space is a real token
        XCTAssertEqual(tok.tokenToID["ə"], 59)
    }

    // MARK: ID mapping (exact EmiliaTokenizer semantics)

    func testTokensToIDsDropsOOVAddsNoBOSEOS() throws {
        let tok = try makeTokenizer()
        // "həlˈoʊ." with an OOV token in the middle.
        let ids = tok.tokensToTokenIDs(["h", "ə", "l", "ˈ", "NOT_A_TOKEN", "o", "ʊ", "."])
        XCTAssertEqual(ids, ["h", "ə", "l", "ˈ", "o", "ʊ", "."].map { tok.tokenToID[$0]! })
        XCTAssertFalse(ids.contains(tok.padID))
    }

    func testEnsureNonEmptyFallsBackToPad() throws {
        let tok = try makeTokenizer()
        XCTAssertEqual(tok.ensureNonEmpty([]), [tok.padID])
        XCTAssertEqual(tok.ensureNonEmpty([5]), [5])
    }

    // MARK: normalizer (fixtures = exact Python EnglishTextNormalizer output)

    func testNormalizerMatchesPythonReference() {
        let normalizer = LuxEnglishTextNormalizer()
        let cases: [(String, String)] = [
            ("Hello world, mister king; five years.",
             "Hello world, mister king; five years."),
            ("Mr. King paid $5.50 on the 3rd of May, 2019.",
             "mister. King paid   five  dollars,  fifty  cents  on the  third  of May,  twenty nineteen ."),
            ("It's nine forty-one on Dusk Drive, 101.7 FM.",
             "It's nine forty-one on Dusk Drive,  one hundred one  point  seven  FM."),
            ("90% of 1/2 is 45%.",
             " ninety  percent  of  one half  is  forty-five  percent ."),
            ("I owe £1,000 to Dr. Smith etc.",
             "I owe  one thousand  pounds to doctor. Smith et cetera."),
            ("The year 2000 and 2024 and 1999 and 2150.",
             "The year  two thousand  and  twenty twenty-four  and  nineteen ninety-nine  and  twenty-one fifty ."),
            ("btw the ft is 3/4 done",
             "by the way the fort is  three quarters  done"),
            ("12,345 items cost $12,345.67",
             " twelve thousand, three hundred forty-five  items cost   twelve thousand, three hundred forty-five  dollars,  sixty-seven  cents "),
            ("The 21st of June: 7/8 of the pie?",
             "The  twenty-first  of June:  seven eighth  of the pie?"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(normalizer.normalize(input), expected, "input: \(input)")
        }
    }

    func testMapPunctuations() {
        XCTAssertEqual(LuxTokenizer.mapPunctuations("Testing... “ok”，right？"),
                       "Testing… \"ok\",right?")
    }

    // MARK: segmentation

    func testSegmentationSplitsTagsAndLanguages() {
        let segs = LuxTokenizer.segments(of: "Yes! [S1] hi <ni3> 好")
        XCTAssertEqual(segs.count, 5)
        XCTAssertEqual(segs[0].text, "Yes! ")
        XCTAssertEqual(segs[1].text, "[S1]")
        XCTAssertEqual(segs[3].text, "<ni3>")
        guard case .english = segs[0].language else { return XCTFail() }
        guard case .tag = segs[1].language else { return XCTFail() }
        guard case .pinyin = segs[3].language else { return XCTFail() }
        guard case .chinese = segs[4].language else { return XCTFail() }
    }

    func testDigitOnlyInputProducesNoTokens() throws {
        // Matches the Python reference: a segment with no en/zh characters is
        // skipped entirely (the stub phonemizer is never consulted).
        let tok = try makeTokenizer(phonemizer: StubPhonemizer(output: ["x"]))
        XCTAssertEqual(try tok.textToTokenIDs("12345"), [])
    }

    // MARK: end-to-end with espeak-ng (skipped when no binary is installed)

    func testEndToEndAgainstPiperPhonemizeReference() throws {
        guard let phonemizer = try? EspeakProcessPhonemizer() else {
            throw XCTSkip("espeak-ng not installed (brew install espeak-ng)")
        }
        let tok = try makeTokenizer(phonemizer: phonemizer)

        // piper_phonemize 1.4.7 reference output for
        // "Hello world, mister king; five years."
        let expected = ["h", "ə", "l", "ˈ", "o", "ʊ", " ", "w", "ˈ", "ɜ", "ː", "l",
                        "d", ",", " ", "m", "ˈ", "ɪ", "s", "t", "ɚ", " ", "k", "ˈ",
                        "ɪ", "ŋ", ";", " ", "f", "ˈ", "a", "ɪ", "v", " ", "j", "ˈ",
                        "ɪ", "ɹ", "z", "."]
        let tokens = try tok.textToTokens("Hello world, mister king; five years.")
        XCTAssertEqual(tokens, expected)

        let ids = try tok.textToTokenIDs("Hello world, mister king; five years.")
        XCTAssertEqual(ids, tok.tokensToTokenIDs(expected))
        XCTAssertEqual(ids.count, expected.count)  // nothing in this string is OOV
    }
}
