import XCTest
@testable import EngineKit

/// A paced stream that emits deltas until the test releases it — models a
/// long-running LLM reply so tests can assert what happens DURING a stream.
private final class GatedStreamModel: LanguageModel, @unchecked Sendable {
    private let gate = AsyncStream<Void>.makeStream()
    func release() { gate.continuation.finish() }
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "x", toolCalls: [],
                   usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)
    }
    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        await onEvent(.delta("d"))
        for await _ in gate.stream {}   // parked until release()
        await onEvent(.finished(ChatResult(
            text: "d", toolCalls: [],
            usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)))
    }
}

private final class GatedLanguageProvider: LanguageModelProviding, @unchecked Sendable {
    let model: GatedStreamModel
    init(model: GatedStreamModel) { self.model = model }
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { model }
    func didEvictModel() {}
}

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

    func testWillUseDoesNotWaitForPeerChatStream() async throws {
        // Studio left a TTS model resident in the main engine; a chat reply is
        // now streaming on that same engine. Evicting for the chat-speech
        // engine must NOT wait for the stream to finish — that would delay the
        // first spoken sentence by the whole LLM reply.
        let llm = GatedStreamModel()
        let main = GloamEngine(provider: FakeProvider(),
                               languageProvider: GatedLanguageProvider(model: llm))
        let chat = GloamEngine(provider: FakeProvider())
        let policy = TTSResidencyPolicy(engines: [main, chat])

        _ = try await main.synthesize(backend: .chatterboxTurbo, request: req)
        let stream = await main.chatStream(backend: .gemma4_e4b, request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()   // first delta arrived — stream is live

        let done = expectation(description: "willUse completes during the stream")
        Task { await policy.willUse(chat); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        let mainTTS = await main.loadedBackend()
        XCTAssertNil(mainTTS, "peer TTS evicted while the LLM stream is still live")

        llm.release()   // let the stream finish cleanly
        while let _ = try await iterator.next() {}
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
