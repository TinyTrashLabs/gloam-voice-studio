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

private final class GatedDialogueModel: DialogueSpeechModel, @unchecked Sendable {
    let sampleRate = 44_100
    let nonverbalTags: [String] = []
    private let started = AsyncStream<Void>.makeStream()
    private let releaseGate = AsyncStream<Void>.makeStream()

    func waitUntilStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() { releaseGate.continuation.finish() }

    func synthesize(_ request: ProviderRequest) async throws -> [Float] { [0] }

    func synthesizeDialogue(_ request: ProviderDialogueRequest) async throws -> DialogueChunk {
        started.continuation.yield()
        for await _ in releaseGate.stream {}
        return DialogueChunk(samples: [0], words: [])
    }

    func openDialogueSession(_ request: ProviderDialogueRequest) throws -> any DialogueStreaming {
        fatalError("unused")
    }
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

    func testEvictionWaitsForInFlightDialogueBeforeDestroyingModel() async throws {
        let provider = FakeProvider()
        let dialogue = GatedDialogueModel()
        provider.models[.dia2] = dialogue
        let engine = GloamEngine(provider: provider)
        let request = ProviderDialogueRequest(
            DialogueRequest(turns: [DialogueTurn(speaker: 1, text: "hello")], voices: []),
            script: ["[S1] hello"], prefixes: [])

        let rendering = Task {
            try await engine.synthesizeDialogue(backend: .dia2, request: request)
        }
        await dialogue.waitUntilStarted()

        let eviction = Task { await engine.evictTTSWhenIdle() }
        try await Task.sleep(for: .milliseconds(20))
        let stillLoaded = await engine.loadedBackend()
        XCTAssertEqual(stillLoaded, .dia2,
                       "eviction must not destroy Dia2 while its Metal work is running")

        dialogue.release()
        _ = try await rendering.value
        await eviction.value
        let after = await engine.loadedBackend()
        XCTAssertNil(after)
    }
}
