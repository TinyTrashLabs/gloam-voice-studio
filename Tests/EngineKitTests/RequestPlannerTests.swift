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

    func testFishEmotionDoesNotDriveTemperature() throws {
        // Fish emotion is an inline [marker], not the sampling temperature: the
        // emotion enum must not set temperature (only an explicit override does).
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", emotion: .excited))
        XCTAssertNil(plan.temperature)
        XCTAssertNil(plan.exaggeration)
    }

    func testFishTemperatureNilWithoutOverride() throws {
        // No explicit temperatureOverride → Fish leaves temperature at the model
        // default (nil); emotion no longer forces it onto the sampling knob.
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
        XCTAssertNil(plan.temperature)
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

    func testExaggerationCeilingClampsOverride() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      exaggerationOverride: 0.9, exaggerationCeiling: 0.6))
        XCTAssertEqual(plan.exaggeration, 0.6)
    }

    func testExaggerationCeilingClampsEmotion() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      emotion: .hype, exaggerationCeiling: 0.5))
        XCTAssertEqual(plan.exaggeration, 0.5)
    }

    func testExaggerationCeilingIsNoOpWhenAboveResolvedValue() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      exaggerationOverride: 0.4, exaggerationCeiling: 0.9))
        XCTAssertEqual(plan.exaggeration, 0.4)
    }

    func testExaggerationCeilingNoOpWhenAboveEmotionValue() throws {
        // .flat resolves to 0.2, below the 0.5 ceiling → passes through unclamped.
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      emotion: .flat, exaggerationCeiling: 0.5))
        XCTAssertEqual(plan.exaggeration, 0.2)
    }

    func testExaggerationCeilingIgnoredOnTurbo() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      exaggerationOverride: 0.9, exaggerationCeiling: 0.3))
        XCTAssertNil(plan.exaggeration)
    }

    func testQwenBasePassesLanguageAndKnobsButNotInstruct() throws {
        // Base is a clone model: it honors language + sampling knobs, but NOT instruct.
        let req = SynthesisRequest(text: "hi", instruct: "warm radio", language: "english",
                                   topP: 0.9, topK: 40, repetitionPenalty: 1.1)
        let p = try RequestPlanner.plan(backend: .qwen17B, request: req)
        XCTAssertNil(p.instruct, "Base does not take instruct")
        XCTAssertEqual(p.language, "english")
        XCTAssertEqual(p.topP, 0.9)
        XCTAssertEqual(p.topK, 40)
        XCTAssertEqual(p.repetitionPenalty, 1.1)
    }

    func testQwenBaseNeverPassesInstruct() throws {
        // With or without a reference clip, Base never forwards instruct.
        let withRef = try RequestPlanner.plan(
            backend: .qwen17B,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", instruct: "angry"))
        XCTAssertEqual(withRef.refAudioPath, "/tmp/r.wav")
        XCTAssertNil(withRef.instruct)
        let noRef = try RequestPlanner.plan(
            backend: .qwen17B, request: SynthesisRequest(text: "hi", instruct: "angry"))
        XCTAssertNil(noRef.instruct)
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

    func testDesignWhitespaceInstructThrows() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .qwenDesign, request: SynthesisRequest(text: "hi", instruct: "   "))) { error in
            XCTAssertEqual(error as? EngineError, .instructRequired(.qwenDesign))
        }
    }

    func testInstructIsTrimmed() throws {
        let p = try RequestPlanner.plan(
            backend: .qwenDesign, request: SynthesisRequest(text: "hi", instruct: "  warm radio  "))
        XCTAssertEqual(p.instruct, "warm radio")
    }

    func testDesignDropsRefAudioAndKeepsInstruct() throws {
        let p = try RequestPlanner.plan(
            backend: .qwenDesign,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      refText: "ref", instruct: "old wise narrator"))
        XCTAssertNil(p.refAudioPath, "design must not clone")
        XCTAssertNil(p.refText)
        XCTAssertEqual(p.instruct, "old wise narrator")
    }

    func testCustomDropsRefAudio() throws {
        let p = try RequestPlanner.plan(
            backend: .qwenCustom,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      instruct: "calm", speaker: "Dylan"))
        XCTAssertNil(p.refAudioPath)
        XCTAssertEqual(p.speaker, "Dylan")
        XCTAssertEqual(p.instruct, "calm")
    }

    func testKokoroRequiresSpeaker() {
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .kokoro, request: SynthesisRequest(text: "hi"))) { error in
            XCTAssertEqual(error as? EngineError, .speakerRequired(.kokoro))
        }
    }

    func testKokoroResolvesSpeakerAndDropsRefAudioAndInstruct() throws {
        let p = try RequestPlanner.plan(
            backend: .kokoro,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav",
                                      instruct: "warm", speaker: "af_heart"))
        XCTAssertEqual(p.speaker, "af_heart")
        XCTAssertNil(p.refAudioPath)
        XCTAssertNil(p.instruct)
    }

    func testKokoroRejectsSpeakerNotInPresetList() {
        // "Vivian" is a Qwen name, not a Kokoro voicepack — this is the exact
        // shape of a stale speaker surviving an app-launch restore (backend
        // set during AppModel.init, whose didSet never fires) or a chat
        // "Regenerate with…" override that bypasses the Studio bench's reset.
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .kokoro, request: SynthesisRequest(text: "hi", speaker: "Vivian"))) { error in
            XCTAssertEqual(error as? EngineError, .speakerRequired(.kokoro))
        }
    }

    func testCustomRejectsSpeakerNotInPresetList() {
        // Same membership check applies to qwenCustom: "af_heart" is a Kokoro
        // voicepack, not a valid CustomVoice speaker name.
        XCTAssertThrowsError(try RequestPlanner.plan(
            backend: .qwenCustom, request: SynthesisRequest(text: "hi", speaker: "af_heart"))) { error in
            XCTAssertEqual(error as? EngineError, .speakerRequired(.qwenCustom))
        }
    }
}
