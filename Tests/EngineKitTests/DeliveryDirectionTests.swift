import XCTest
@testable import EngineKit

/// The words Breeze is handed for each emotion control (`.directed`).
final class DeliveryDirectionTests: XCTestCase {
    func testNeutralSaysNothingAndEveryOtherEmotionSaysSomething() {
        XCTAssertNil(DeliveryDirection.phrase(for: .neutral),
                     "neutral is the model's own read — and keeps Breeze off its CFG pass")
        for emotion in Emotion.allCases where emotion != .neutral {
            XCTAssertFalse((DeliveryDirection.phrase(for: emotion) ?? "").isEmpty, emotion.rawValue)
        }
    }

    func testEmotionPhrasesAreDistinct() {
        let phrases = Emotion.allCases.compactMap(DeliveryDirection.phrase(for:))
        XCTAssertEqual(Set(phrases).count, phrases.count)
    }

    /// Every expression the Create Voice baker offers has tuned wording. The
    /// list mirrors the app's `VoiceExpression` (which lives in the app target).
    func testEveryBakerExpressionHasTunedWording() {
        let bakerExpressions = ["excited", "delight", "angry", "sad", "surprised", "shocked",
                                "whisper", "shouting", "screaming", "laughing", "chuckle",
                                "sigh", "panting", "moaning", "singing"]
        for name in bakerExpressions {
            XCTAssertNotNil(DeliveryDirection.expressions[name], name)
        }
    }

    func testExpressionLookupIsCaseAndWhitespaceTolerant() {
        XCTAssertEqual(DeliveryDirection.phrase(forExpression: "  Whisper "),
                       DeliveryDirection.expressions["whisper"])
        XCTAssertNil(DeliveryDirection.phrase(forExpression: "   "))
    }

    func testUnknownExpressionPassesThroughAsFreeText() {
        XCTAssertEqual(DeliveryDirection.phrase(forExpression: "whisper in a small voice"),
                       "Delivery: whisper in a small voice.")
    }

    func testComposeOrdersDirectionThenExpressionThenEmotion() {
        let composed = DeliveryDirection.compose(direction: "A gravelly old sailor.",
                                                 expression: "whisper", emotion: .warm)
        XCTAssertEqual(composed, "A gravelly old sailor. "
            + DeliveryDirection.expressions["whisper"]! + " "
            + DeliveryDirection.phrase(for: .warm)!)
    }

    func testComposeIsNilWhenThereIsNothingToSay() {
        XCTAssertNil(DeliveryDirection.compose(direction: nil, expression: nil, emotion: .neutral))
        XCTAssertNil(DeliveryDirection.compose(direction: "  ", expression: "", emotion: .neutral))
    }

    func testAPhraseDirectionIsClosedBeforeTheNextPart() {
        // The Studio's own placeholder is a phrase, not a sentence.
        XCTAssertEqual(
            DeliveryDirection.compose(direction: "warm, unhurried late-night radio host",
                                      expression: "whisper", emotion: .neutral),
            "warm, unhurried late-night radio host. " + DeliveryDirection.expressions["whisper"]!)
    }

    func testALoneDirectionIsPassedExactlyAsWritten() {
        XCTAssertEqual(DeliveryDirection.compose(direction: "warm radio host",
                                                 expression: nil, emotion: .neutral),
                       "warm radio host")
    }

    func testFreeTextExpressionNeverGetsADoublePeriod() {
        XCTAssertEqual(DeliveryDirection.phrase(forExpression: "whisper softly."),
                       "Delivery: whisper softly.")
    }

    func testSentenceClosingRespectsExistingPunctuationAndChinese() {
        XCTAssertEqual(DeliveryDirection.sentence("Calm!"), "Calm!")
        XCTAssertEqual(DeliveryDirection.sentence(#"Say "hi.""#), #"Say "hi.""#)
        XCTAssertEqual(DeliveryDirection.sentence("一位温柔的女性"), "一位温柔的女性。")
        XCTAssertEqual(DeliveryDirection.sentence("温柔。"), "温柔。")
        // A trailing pause mark becomes the full stop, never ", ." / "，.".
        XCTAssertEqual(DeliveryDirection.sentence("温柔的女声，"), "温柔的女声。")
        XCTAssertEqual(DeliveryDirection.sentence("calm, slow, "), "calm, slow.")
        XCTAssertEqual(DeliveryDirection.sentence("（低声）"), "（低声）。")
    }
}
