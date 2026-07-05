import XCTest
@testable import EngineKit

/// Chatterbox regular exposes `cfg_weight` — the CFG guidance/pacing knob (default
/// 0.5; Resemble guidance: lower it as exaggeration rises). Turbo uses a non-CFG
/// basic-Euler solver and has no cfg_weight.
///
/// Chatterbox `language` is deliberately NOT exposed: the vendored mlx-audio-swift
/// port accepts a `language:` argument but never conditions generation on it, so a
/// picker would be a no-op lever. Re-enabling it requires wiring language
/// conditioning in the fork first (tracked with the other fork work).
final class ChatterboxControlsTests: XCTestCase {
    func testChatterboxRegularExposesCfgWeightKnob() {
        XCTAssertNotNil(BackendID.chatterbox.controls.knobs.cfgWeight)
    }

    func testTurboHasNoCfgWeightKnob() {
        XCTAssertNil(BackendID.chatterboxTurbo.controls.knobs.cfgWeight)
    }

    func testChatterboxForwardsCfgWeight() throws {
        let plan = try RequestPlanner.plan(
            backend: .chatterbox,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", cfgWeight: 0.3))
        XCTAssertEqual(plan.cfgWeight, 0.3)
    }

    func testCfgWeightDroppedForBackendWithoutTheKnob() throws {
        let plan = try RequestPlanner.plan(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi", cfgWeight: 0.3))
        XCTAssertNil(plan.cfgWeight)
    }

    func testChatterboxDoesNotExposeLanguage() {
        // The port does not condition on language for chatterbox — no fake lever.
        XCTAssertFalse(BackendID.chatterbox.controls.language)
        XCTAssertFalse(BackendID.chatterboxTurbo.controls.language)
    }
}
