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

    func testTemperatureOverrideBeatsEmotionOnFish() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", emotion: .warm,
                                      temperatureOverride: 0.95))
        XCTAssertEqual(plan.temperature, 0.95)
    }

    func testTemperatureOverrideIgnoredWhenBackendDoesNotHonorTags() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      temperatureOverride: 0.95))
        XCTAssertNil(plan.temperature)
    }

    func testExaggerationOverrideBeatsEmotionOnChatterbox() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      emotion: .flat, exaggerationOverride: 0.9))
        XCTAssertEqual(plan.exaggeration, 0.9)
    }

    func testExaggerationOverrideIgnoredOnTurbo() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      exaggerationOverride: 0.9))
        XCTAssertNil(plan.exaggeration)
    }

    func testQwenBasePassesInstructAndLanguageAndKnobs() throws {
        let req = SynthesisRequest(text: "hi", instruct: "warm radio", language: "english",
                                   topP: 0.9, topK: 40, repetitionPenalty: 1.1)
        let p = try RequestPlanner.plan(backend: .qwen17B, request: req)
        XCTAssertEqual(p.instruct, "warm radio")
        XCTAssertEqual(p.language, "english")
        XCTAssertEqual(p.topP, 0.9)
        XCTAssertEqual(p.topK, 40)
        XCTAssertEqual(p.repetitionPenalty, 1.1)
    }

    func testQwenBaseCloneWinsDropsInstruct() throws {
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", instruct: "angry")
        let p = try RequestPlanner.plan(backend: .qwen17B, request: req)
        XCTAssertEqual(p.refAudioPath, "/tmp/r.wav")
        XCTAssertNil(p.instruct, "clone path ignores instruct")
    }

    func testDesignRequiresInstruct() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .qwenDesign, request: SynthesisRequest(text: "hi"))) { error in
            XCTAssertEqual(error as? EngineError, .instructRequired(.qwenDesign))
        }
    }

    func testCustomRequiresSpeakerAndComposesInstruct() throws {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .qwenCustom, request: SynthesisRequest(text: "hi", instruct: "calm"))) { error in
            XCTAssertEqual(error as? EngineError, .speakerRequired(.qwenCustom))
        }
        let p = try RequestPlanner.plan(
            backend: .qwenCustom,
            request: SynthesisRequest(text: "hi", instruct: "calm", speaker: "Dylan"))
        XCTAssertEqual(p.speaker, "Dylan")
        XCTAssertEqual(p.instruct, "calm")
    }

    func testNonQwenDropsInstructSpeakerLanguage() throws {
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                   instruct: "x", speaker: "Dylan", language: "english")
        let p = try RequestPlanner.plan(backend: .chatterboxTurbo, request: req)
        XCTAssertNil(p.instruct)
        XCTAssertNil(p.speaker)
        XCTAssertNil(p.language)
    }
}
