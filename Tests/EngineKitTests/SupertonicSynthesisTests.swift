import XCTest
@testable import EngineKit

/// SuperTonic synthesis wiring. The planner-level tests run everywhere; the
/// real-model smoke test loads the converted weights from a local directory
/// and needs Metal + the weights on disk, so it is gated behind
/// ENGINEKIT_LIVE_TESTS=1 (mirroring SpeechKit's SPEECHKIT_LIVE_TESTS gate).
final class SupertonicSynthesisTests: XCTestCase {
    /// Local converted-weights checkout (config.json model_type "supertonic",
    /// four safetensors, unicode_indexer.json, voice_styles/). Overridable so CI
    /// or another machine can point elsewhere.
    private static var localWeightsPath: String {
        ProcessInfo.processInfo.environment["SUPERTONIC_WEIGHTS_DIR"]
            ?? "/Users/david/projects/mlx-audio-swift-supertonic/weights-repo"
    }

    private static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ENGINEKIT_LIVE_TESTS"] == "1"
    }

    // MARK: - Planner-level (no weights needed)

    func testUnknownSpeakerFailsValidationBeforeModelLoad() async {
        // Preset validation must reject a stale/unknown speaker loudly, without
        // loading weights — same rule as Qwen CustomVoice / Kokoro.
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .supertonic)
        do {
            _ = try await engine.synthesize(
                backend: .supertonic,
                request: SynthesisRequest(text: "hi", speaker: "af_heart"))
            XCTFail("expected speakerRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .speakerRequired(.supertonic))
        }
        XCTAssertTrue(provider.loads.isEmpty, "validation must run before model load")
    }

    func testMissingSpeakerFailsValidation() async {
        let engine = GloamEngine(provider: FakeProvider())
        await engine.acknowledgeLicense(for: .supertonic)
        do {
            _ = try await engine.synthesize(
                backend: .supertonic, request: SynthesisRequest(text: "hi"))
            XCTFail("expected speakerRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .speakerRequired(.supertonic))
        }
    }

    func testSynthesizeWithoutLicenseAckThrows() async {
        // Open RAIL-M use restrictions require an explicit ack, like Fish.
        let engine = GloamEngine(provider: FakeProvider())
        do {
            _ = try await engine.synthesize(
                backend: .supertonic,
                request: SynthesisRequest(text: "hi", speaker: "M1"))
            XCTFail("expected licenseAckRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .licenseAckRequired(.supertonic))
        }
    }

    func testValidSpeakerReachesProvider() async throws {
        let provider = FakeProvider()
        let model = FakeModel(sampleRate: 44100)
        provider.models[.supertonic] = model
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .supertonic)
        let result = try await engine.synthesize(
            backend: .supertonic,
            request: SynthesisRequest(text: "hi", speaker: "F3"))
        XCTAssertEqual(result.sampleRate, 44100)
        XCTAssertEqual(model.received.count, 1)
        XCTAssertEqual(model.received.first?.speaker, "F3")
        // No clone / knobs on this backend — the plan must not carry them.
        XCTAssertNil(model.received.first?.refAudioPath)
        XCTAssertNil(model.received.first?.temperature)
        XCTAssertNil(model.received.first?.exaggeration)
    }

    // MARK: - Live model smoke (local weights + Metal)

    func testSupertonicSynthesisSmoke() async throws {
        try XCTSkipUnless(Self.liveTestsEnabled, "set ENGINEKIT_LIVE_TESTS=1 to run")
        let dir = Self.localWeightsPath
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dir + "/config.json"),
            "SuperTonic converted weights not found at \(dir)")

        let provider = MLXModelProvider(modelPathResolver: { backend in
            backend == .supertonic ? dir : nil
        })
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .supertonic)
        let result = try await engine.synthesize(
            backend: .supertonic,
            request: SynthesisRequest(text: "The quick brown fox jumps over the lazy dog.",
                                      speaker: "M1"))
        XCTAssertEqual(result.sampleRate, 44100)
        XCTAssertFalse(result.samples.isEmpty)
        // Sanity: non-silent output of a plausible length (0.5–30 s).
        let peak = result.samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.01, "output should not be silence")
        XCTAssertGreaterThan(result.samples.count, 22_050)
        XCTAssertLessThan(result.samples.count, 44_100 * 30)
    }
}
