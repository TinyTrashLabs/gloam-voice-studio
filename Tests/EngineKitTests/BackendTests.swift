import XCTest
@testable import EngineKit

final class BackendTests: XCTestCase {
    func testBackendIDsMatchPythonEngineStrings() {
        XCTAssertEqual(BackendID.chatterbox.rawValue, "chatterbox")
        XCTAssertEqual(BackendID.chatterboxTurbo.rawValue, "chatterbox-turbo")
        XCTAssertEqual(BackendID.fishS2Pro.rawValue, "fish-s2-pro")
        XCTAssertEqual(BackendID.allCases.count, 3)
    }

    func testChatterboxSpec() {
        let spec = BackendID.chatterbox.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/Chatterbox-TTS-fp16")
        XCTAssertEqual(spec.defaultSampleRate, 24000)
        XCTAssertFalse(spec.honorsTags)
        XCTAssertFalse(spec.needsLicenseAck)
        XCTAssertTrue(spec.needsRefAudio)
        XCTAssertTrue(spec.honorsEmotionKnob)
    }

    func testChatterboxTurboSpec() {
        let spec = BackendID.chatterboxTurbo.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/chatterbox-turbo-fp16")
        XCTAssertEqual(spec.defaultSampleRate, 24000)
        XCTAssertFalse(spec.honorsTags)
        XCTAssertFalse(spec.needsLicenseAck)
        XCTAssertTrue(spec.needsRefAudio)
        XCTAssertFalse(spec.honorsEmotionKnob)
    }

    func testFishSpec() {
        let spec = BackendID.fishS2Pro.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/fish-audio-s2-pro-bf16")
        XCTAssertEqual(spec.defaultSampleRate, 44100)
        XCTAssertTrue(spec.honorsTags)
        XCTAssertTrue(spec.needsLicenseAck)
        XCTAssertFalse(spec.needsRefAudio)
        XCTAssertTrue(spec.honorsEmotionKnob)
    }

    func testFishRefAudioSampleRateIsCodecRate() {
        // Fish's S1-DAC codec requires refs at 44.1 kHz (backends.py FISH_CODEC_SAMPLE_RATE).
        XCTAssertEqual(BackendID.fishCodecSampleRate, 44100)
    }
}
