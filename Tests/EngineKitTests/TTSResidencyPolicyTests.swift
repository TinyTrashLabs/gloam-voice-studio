import XCTest
@testable import EngineKit

final class TTSResidencyPolicyTests: XCTestCase {
    private let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")

    func testWillUseEvictsOtherEngineResident() async throws {
        let main = GloamEngine(provider: FakeProvider())
        let chat = GloamEngine(provider: FakeProvider())
        let policy = TTSResidencyPolicy(engines: [main, chat])

        _ = try await main.synthesize(backend: .chatterboxTurbo, request: req)
        let mainLoaded = await main.loadedBackend()
        XCTAssertEqual(mainLoaded, .chatterboxTurbo)

        await policy.willUse(chat)

        let mainAfter = await main.loadedBackend()
        XCTAssertNil(mainAfter, "the other engine's TTS model must be evicted")
    }

    func testWillUseKeepsTargetEngineResident() async throws {
        let main = GloamEngine(provider: FakeProvider())
        let chat = GloamEngine(provider: FakeProvider())
        let policy = TTSResidencyPolicy(engines: [main, chat])

        _ = try await chat.synthesize(backend: .chatterboxTurbo, request: req)
        await policy.willUse(chat)

        let chatAfter = await chat.loadedBackend()
        XCTAssertEqual(chatAfter, .chatterboxTurbo,
                       "the engine about to render keeps its own model")
    }

    func testAlternatingUseLeavesSingleResident() async throws {
        let main = GloamEngine(provider: FakeProvider())
        let chat = GloamEngine(provider: FakeProvider())
        let policy = TTSResidencyPolicy(engines: [main, chat])

        await policy.willUse(main)
        _ = try await main.synthesize(backend: .chatterboxTurbo, request: req)
        await policy.willUse(chat)
        _ = try await chat.synthesize(backend: .qwen17B, request: req)

        let mainLoaded = await main.loadedBackend()
        let chatLoaded = await chat.loadedBackend()
        XCTAssertNil(mainLoaded)
        XCTAssertEqual(chatLoaded, .qwen17B)
    }

    func testWillUseWaitsForInFlightWorkBeforeEvicting() async throws {
        let provider = FakeProvider()
        let slow = OverlapDetectingModel()   // 20ms synthesis
        provider.models[.chatterboxTurbo] = slow
        let main = GloamEngine(provider: provider)
        let chat = GloamEngine(provider: FakeProvider())
        let policy = TTSResidencyPolicy(engines: [main, chat])

        let request = req
        let inflight = Task { try await main.synthesize(backend: .chatterboxTurbo, request: request) }
        try await Task.sleep(for: .milliseconds(5))
        await policy.willUse(chat)

        // The in-flight generation completed normally despite the eviction.
        let result = try await inflight.value
        XCTAssertFalse(result.samples.isEmpty)
        let mainAfter = await main.loadedBackend()
        XCTAssertNil(mainAfter)
    }
}
