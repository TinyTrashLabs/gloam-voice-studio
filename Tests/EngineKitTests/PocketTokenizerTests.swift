// PocketTokenizerTests.swift
//
// Parity tests for the hand-rolled SentencePiece unigram tokenizer against
// Python `sentencepiece` ground truth. The expected id arrays below were
// produced by:
//
//   sp = sentencepiece.SentencePieceProcessor("tokenizer.model")
//   sp.encode(text, out_type=int)
//
// on Models/pocket-tts/english_2026-04/tokenizer.model. Token-for-token
// equality matters: the flow LM was trained on exactly these ids, and one
// wrong piece shifts every downstream sentence-boundary split.
//
// Skipped (not failed) when the gitignored model bundle has not been fetched.

import XCTest
@testable import EngineKit

final class PocketTokenizerTests: XCTestCase {
    static let modelPath = URL(fileURLWithPath: "Models/pocket-tts/english_2026-04/tokenizer.model")

    private func makeTokenizer() throws -> PocketTokenizer {
        guard FileManager.default.fileExists(atPath: Self.modelPath.path) else {
            throw XCTSkip("pocket-tts bundle not fetched (scripts/fetch-pocket-tts-onnx.sh)")
        }
        return try PocketTokenizer(modelPath: Self.modelPath)
    }

    func testMatchesPythonSentencePiece() throws {
        let tok = try makeTokenizer()
        XCTAssertEqual(tok.vocabSize, 4000)
        // (text, python sentencepiece ids)
        let cases: [(String, [Int])] = [
            ("Hello world. I am Kyutai's Pocket TTS.",
             [2994, 578, 263, 268, 686, 862, 327, 805, 1537, 264, 261, 1456, 603, 597, 602, 854, 640, 263]),
            ("The quick brown fox jumps over the lazy dog.",
             [364, 976, 3683, 521, 1923, 1609, 261, 408, 265, 697, 690, 327, 1497, 263]),
            // Double space + digits: exercises the '▁'-only piece and numerals
            // (remove_extra_whitespaces is OFF for this model).
            ("Isn't  it weird? Cafe No5",
             [268, 261, 306, 264, 274, 260, 275, 1395, 292, 1130, 1273, 500, 437]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(tok.encode(text), expected, "mismatch for: \(text)")
        }
    }

    func testDecodeRoundTrip() throws {
        let tok = try makeTokenizer()
        let text = "The quick brown fox jumps over the lazy dog."
        XCTAssertEqual(tok.decode(tok.encode(text)), text)
    }

    func testByteFallbackForUnknownCharacters() throws {
        let tok = try makeTokenizer()
        // 'ω' is outside the 4000-piece vocab: it must byte-fallback to
        // <0xCF><0x89> (python ids below), not drop, and decode back intact.
        let text = "Hi \u{03C9}!"
        XCTAssertEqual(tok.encode(text), [1445, 260, 211, 141, 682])
        XCTAssertEqual(tok.decode(tok.encode(text)), text)
    }
}
