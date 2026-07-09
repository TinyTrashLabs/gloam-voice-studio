import XCTest
@testable import EngineKit

final class BackendTests: XCTestCase {
    func testBackendIDsMatchPythonEngineStrings() {
        XCTAssertEqual(BackendID.chatterbox.rawValue, "chatterbox")
        XCTAssertEqual(BackendID.chatterboxTurbo.rawValue, "chatterbox-turbo")
        XCTAssertEqual(BackendID.fishS2Pro.rawValue, "fish-s2-pro")
        XCTAssertEqual(BackendID.allCases.count, 7)
    }

    func testQwenBackendRawValues() {
        XCTAssertEqual(BackendID.qwen06B.rawValue, "qwen3-0.6b")
        XCTAssertEqual(BackendID.qwen17B.rawValue, "qwen3-1.7b")
        XCTAssertEqual(BackendID.qwenDesign.rawValue, "qwen3-design")
        XCTAssertEqual(BackendID.qwenCustom.rawValue, "qwen3-custom")
        XCTAssertEqual(BackendID.allCases.count, 7)
    }

    func testQwenFamilyFlag() {
        XCTAssertTrue(BackendID.qwen06B.isQwen)
        XCTAssertTrue(BackendID.qwenCustom.isQwen)
        XCTAssertFalse(BackendID.fishS2Pro.isQwen)
        XCTAssertFalse(BackendID.chatterbox.isQwen)
    }

    func testLegacyQwenMigration() {
        XCTAssertEqual(BackendID.migrating(rawValue: "qwen3"), .qwen06B)
        XCTAssertEqual(BackendID.migrating(rawValue: "fish-s2-pro"), .fishS2Pro)
        XCTAssertNil(BackendID.migrating(rawValue: "nonsense"))
    }

    func testChatterboxSpec() {
        let spec = BackendID.chatterbox.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/Chatterbox-TTS-fp16")
        XCTAssertEqual(spec.defaultSampleRate, 24000)
        XCTAssertFalse(spec.honorsTags)
        XCTAssertFalse(spec.needsLicenseAck)
        XCTAssertTrue(spec.needsRefAudio)
        XCTAssertEqual(spec.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(BackendID.chatterbox.emotionMechanism, .liveKnob(.exaggeration))
    }

    func testChatterboxTurboSpec() {
        let spec = BackendID.chatterboxTurbo.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/chatterbox-turbo-fp16")
        XCTAssertEqual(spec.defaultSampleRate, 24000)
        XCTAssertFalse(spec.honorsTags)
        XCTAssertFalse(spec.needsLicenseAck)
        XCTAssertTrue(spec.needsRefAudio)
        XCTAssertEqual(spec.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(BackendID.chatterboxTurbo.emotionMechanism, .variantClipOnly)
    }

    func testFishSpec() {
        let spec = BackendID.fishS2Pro.spec
        XCTAssertEqual(spec.modelRepo, "mlx-community/fish-audio-s2-pro-bf16")
        XCTAssertEqual(spec.defaultSampleRate, 44100)
        XCTAssertTrue(spec.honorsTags)
        XCTAssertTrue(spec.needsLicenseAck)
        XCTAssertFalse(spec.needsRefAudio)
        XCTAssertEqual(spec.minRAMBytes, 16_000_000_000)
        XCTAssertEqual(BackendID.fishS2Pro.emotionMechanism, .inlineMarker)
    }

    func testQwenSpecsMinRAM() {
        XCTAssertEqual(BackendID.qwen06B.spec.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(BackendID.qwen17B.spec.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(BackendID.qwenDesign.spec.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(BackendID.qwenCustom.spec.minRAMBytes, 8_000_000_000)
    }

    func testFishRefAudioSampleRateIsCodecRate() {
        // Fish's S1-DAC codec requires refs at 44.1 kHz (backends.py FISH_CODEC_SAMPLE_RATE).
        XCTAssertEqual(BackendID.fishCodecSampleRate, 44100)
    }

    func testQwenQuantSuffixes() {
        XCTAssertEqual(QwenQuant.q8.rawValue, "8bit")
        XCTAssertEqual(QwenQuant.bf16.rawValue, "bf16")
        XCTAssertEqual(QwenQuant.allCases.count, 5)
    }

    func testQwenRepoResolution() {
        XCTAssertEqual(BackendID.qwen06B.modelRepo(quant: .q8),
                       "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")
        XCTAssertEqual(BackendID.qwen17B.modelRepo(quant: .q4),
                       "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit")
        XCTAssertEqual(BackendID.qwenDesign.modelRepo(quant: .bf16),
                       "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16")
        XCTAssertEqual(BackendID.qwenCustom.modelRepo(quant: .q6),
                       "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit")
        // Non-Qwen ignores quant and returns the static repo.
        XCTAssertEqual(BackendID.fishS2Pro.modelRepo(quant: .q8),
                       "mlx-community/fish-audio-s2-pro-bf16")
    }

    func testDiskFolderName() {
        XCTAssertEqual(BackendID.qwen06B.diskFolder(quantRaw: "8bit"), "qwen3-0.6b@8bit")
        XCTAssertEqual(BackendID.qwen17B.diskFolder(quantRaw: nil), "qwen3-1.7b@8bit") // defaults q8
        XCTAssertEqual(BackendID.fishS2Pro.diskFolder(quantRaw: "8bit"), "fish-s2-pro")
    }

    func testControlSurfaces() {
        let base = BackendID.qwen17B.controls
        XCTAssertEqual(base.voiceClone, .optional)
        XCTAssertEqual(base.instruct, .none, "Base is a clone model — no natural-language instruct")
        XCTAssertTrue(base.language)
        XCTAssertNotNil(base.knobs.temperature)
        XCTAssertNotNil(base.knobs.topP)
        XCTAssertTrue(base.presetSpeakers.isEmpty)

        let design = BackendID.qwenDesign.controls
        XCTAssertEqual(design.voiceClone, .none)
        XCTAssertEqual(design.instruct, .required)

        let custom = BackendID.qwenCustom.controls
        XCTAssertEqual(custom.voiceClone, .none)
        XCTAssertEqual(custom.instruct, .optional)
        XCTAssertFalse(custom.presetSpeakers.isEmpty)
        XCTAssertEqual(custom.presetSpeakers.first, "Vivian")

        let fish = BackendID.fishS2Pro.controls
        XCTAssertNotNil(fish.knobs.temperature)
        XCTAssertNil(fish.knobs.topP)

        let cb = BackendID.chatterbox.controls
        XCTAssertEqual(cb.voiceClone, .required)
        XCTAssertNotNil(cb.knobs.exaggeration)

        let turbo = BackendID.chatterboxTurbo.controls
        XCTAssertEqual(turbo.voiceClone, .required)
        XCTAssertNil(turbo.knobs.exaggeration)
        XCTAssertNil(turbo.knobs.temperature)
    }
}
