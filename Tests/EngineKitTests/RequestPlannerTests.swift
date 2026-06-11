import XCTest
@testable import EngineKit

final class RequestPlannerTests: XCTestCase {
    func testChatterboxMapsEmotionToExaggerationNotTemperature() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/ref.wav", emotion: .hype))
        XCTAssertEqual(plan.exaggeration, 1.0)
        XCTAssertNil(plan.temperature)
    }

    func testChatterboxTurboGetsNoExaggeration() throws {
        // Turbo ignores exaggeration upstream; don't pretend to set it.
        let plan = try RequestPlanner.plan(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/ref.wav", emotion: .hype))
        XCTAssertNil(plan.exaggeration)
        XCTAssertNil(plan.temperature)
    }

    func testFishMapsEmotionToTemperature() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", emotion: .excited))
        XCTAssertEqual(plan.temperature, 0.9)
        XCTAssertNil(plan.exaggeration)
    }

    func testDefaultEmotionIsNeutral() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
        XCTAssertEqual(plan.temperature, Emotion.neutral.fishTemperature)
    }

    func testChatterboxWithoutRefThrows() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .chatterbox, request: SynthesisRequest(text: "hi"))) { error in
            XCTAssertEqual(error as? EngineError, .refAudioRequired(.chatterbox))
        }
    }

    func testFishWithoutRefIsFine() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
        XCTAssertNil(plan.refAudioPath)
    }

    func testInlineTagsPassThroughUntouched() throws {
        let text = "[laughing] You won't believe [pause] this."
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: text))
        XCTAssertEqual(plan.text, text)
    }

    func testRefTextForwarded() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", refText: "transcript"))
        XCTAssertEqual(plan.refText, "transcript")
        XCTAssertEqual(plan.refAudioPath, "/tmp/r.wav")
    }

    func testZeroSpeedThrowsInvalidSpeed() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", speed: 0))) { error in
            XCTAssertEqual(error as? EngineError, .invalidSpeed(0))
        }
    }

    func testNegativeSpeedThrowsInvalidSpeed() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", speed: -1))) { error in
            XCTAssertEqual(error as? EngineError, .invalidSpeed(-1))
        }
    }
}
