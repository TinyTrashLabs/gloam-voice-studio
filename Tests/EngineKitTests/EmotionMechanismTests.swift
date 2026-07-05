import XCTest
@testable import EngineKit

/// The single source of truth for how each backend expresses emotion, consumed by
/// both the request planner (which knob emotion resolves to) and the UI (which
/// emotion control to render). Replaces the dead `honorsEmotionKnob` flag and the
/// `honorsTags` proxy the planner used to gate emotion→temperature.
final class EmotionMechanismTests: XCTestCase {
    // MARK: per-backend classification

    func testQwenBaseIsVariantClipOnly() {
        // Base is a pure clone: no model-native emotion. Emotion only via acted clips.
        XCTAssertEqual(BackendID.qwen06B.emotionMechanism, .variantClipOnly)
        XCTAssertEqual(BackendID.qwen17B.emotionMechanism, .variantClipOnly)
    }

    func testQwenDesignAndCustomAreTextDriven() {
        // Design/Custom steer emotion through the free-text instruct/style prompt,
        // not a chip — the Direction box is the control.
        XCTAssertEqual(BackendID.qwenDesign.emotionMechanism, .textDriven)
        XCTAssertEqual(BackendID.qwenCustom.emotionMechanism, .textDriven)
    }

    func testFishUsesInlineMarker() {
        // Fish emotion is a leading [marker] in the text (its trained control), NOT
        // the sampling temperature. temperature stays a plain sampling knob.
        XCTAssertEqual(BackendID.fishS2Pro.emotionMechanism, .inlineMarker)
    }

    func testChatterboxRegularUsesExaggerationKnob() {
        XCTAssertEqual(BackendID.chatterbox.emotionMechanism, .liveKnob(.exaggeration))
    }

    func testChatterboxTurboIsVariantClipOnly() {
        // Turbo has no exaggeration ("emotion_adv": false); emotion only via acted clips.
        XCTAssertEqual(BackendID.chatterboxTurbo.emotionMechanism, .variantClipOnly)
    }

    // MARK: planner resolves the emotion knob FROM the mechanism (not honorsTags)

    // MARK: inline-marker (Fish): emotion is a leading [marker] injected into text

    func testInlineMarkerPrependsBracketMarker() throws {
        // The Studio picks an expression; the planner renders it as Fish's trained
        // [marker] control at the sentence start.
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "Hello there.", emotionMarker: "whisper"))
        XCTAssertEqual(plan.text, "[whisper] Hello there.")
    }

    func testInlineMarkerWithoutMarkerPassesTextThrough() throws {
        // The DJ app embeds its own markers and sends no emotionMarker — verbatim.
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: "[excited] Ship it!"))
        XCTAssertEqual(plan.text, "[excited] Ship it!")
    }

    func testInlineMarkerDoesNotDoubleInjectWhenTextAlreadyHasMarker() throws {
        // If the caller already embedded a leading marker, the client's marker wins —
        // never stack two brackets.
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "[angry] No!", emotionMarker: "whisper"))
        XCTAssertEqual(plan.text, "[angry] No!")
    }

    func testInlineMarkerEmotionDoesNotDriveTemperature() throws {
        // Fish emotion is the marker, not the sampling temperature: the emotion enum
        // must not hijack temperature (only an explicit override sets it).
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro,
            request: SynthesisRequest(text: "hi", emotion: .excited, emotionMarker: "angry"))
        XCTAssertNil(plan.temperature)
    }

    func testNonInlineBackendIgnoresEmotionMarker() throws {
        // A stray emotionMarker on a non-Fish backend must not alter the text.
        let plan = try RequestPlanner.plan(
            backend: .qwen17B,
            request: SynthesisRequest(text: "Hello.", emotionMarker: "whisper"))
        XCTAssertEqual(plan.text, "Hello.")
    }

    func testLiveKnobExaggerationMapsEmotionToExaggeration() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", emotion: .hype))
        XCTAssertEqual(plan.exaggeration, Emotion.hype.chatterboxExaggeration)
        XCTAssertNil(plan.temperature)
    }

    func testVariantClipOnlyMapsEmotionToNoLiveKnob() throws {
        // Base has a sampling-temperature knob, but emotion must NOT drive it.
        let base = try RequestPlanner.plan(
            backend: .qwen17B, request: SynthesisRequest(text: "hi", emotion: .hype))
        XCTAssertNil(base.exaggeration)
        XCTAssertNil(base.temperature)
        // Turbo has neither knob.
        let turbo = try RequestPlanner.plan(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", emotion: .hype))
        XCTAssertNil(turbo.exaggeration)
        XCTAssertNil(turbo.temperature)
    }

    func testTextDrivenMapsEmotionToNoLiveKnob() throws {
        // Design steers emotion via instruct; the emotion enum must not touch a knob.
        let plan = try RequestPlanner.plan(
            backend: .qwenDesign,
            request: SynthesisRequest(text: "hi", emotion: .hype, instruct: "gentle old narrator"))
        XCTAssertNil(plan.temperature)
        XCTAssertNil(plan.exaggeration)
    }
}
