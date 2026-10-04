import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// A TTS model whose render parks until the test releases it — models a long
/// synthesis so tests can assert what an unload does DURING it.
private final class GatedSpeechModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24_000
    private let started = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var gated = false

    /// Only renders after `arm()` park; the preload/first render passes through.
    func arm() { lock.withLock { gated = true } }
    func release() { gate.continuation.finish() }
    func waitUntilStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        if lock.withLock({ gated }) {
            started.continuation.yield()
            for await _ in gate.stream {}
        }
        return [0, 0.25, -0.25, 0.5]
    }
}

private final class GatedSpeechProvider: ModelProviding, @unchecked Sendable {
    let model = GatedSpeechModel()
    func loadModel(backend: BackendID) async throws -> any SpeechModel { model }
    func didEvictModel() {}
}

/// A paced chat stream that emits one delta then parks until released.
private final class GatedChatModel: LanguageModel, @unchecked Sendable {
    private let gate = AsyncStream<Void>.makeStream()
    func release() { gate.continuation.finish() }
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "x", toolCalls: [],
                   usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)
    }
    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        await onEvent(.delta("d"))
        for await _ in gate.stream {}
        await onEvent(.finished(ChatResult(
            text: "d", toolCalls: [],
            usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)))
    }
}

private final class GatedChatProvider: LanguageModelProviding, @unchecked Sendable {
    let model = GatedChatModel()
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { model }
    func didEvictModel() {}
}

/// Records when the test let the in-flight work go, so a response can prove
/// it only arrived afterwards.
private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

final class ModelUnloadTests: XCTestCase, @unchecked Sendable {
    private let tts = BackendID.chatterboxTurbo
    private let llm = LLMBackendID.qwen3_1_7b
    private let synthRequest = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")

    private func makeDeps(speech: GatedSpeechProvider = GatedSpeechProvider(),
                          chat: GatedChatProvider = GatedChatProvider(),
                          log: APILog = APILog(),
                          authToken: @escaping @Sendable () -> String? = { nil }) -> APIDependencies {
        APIDependencies(
            engine: GloamEngine(provider: speech, languageProvider: chat),
            voices: VoiceLibrary(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("unload-\(UUID().uuidString)")),
            defaultBackend: tts, defaultLLM: llm, log: log, authToken: authToken)
    }

    /// Both a TTS and an LLM model resident.
    private func loadBoth(_ deps: APIDependencies) async throws {
        try await deps.engine.preload(backend: tts)
        try await deps.engine.preloadLLM(backend: llm)
    }

    private func unload(_ client: some TestClientProtocol, body: String?,
                        headers: HTTPFields = [:],
                        check: @escaping (TestResponse, [String: Any]) async throws -> Void) async throws {
        try await client.execute(uri: "/v1/models/unload", method: .post, headers: headers,
                                 body: body.map { ByteBuffer(string: $0) }) { response in
            let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body))
                as? [String: Any]) ?? [:]
            try await check(response, json)
        }
    }

    func testDefaultTargetUnloadsBoth() async throws {
        let deps = makeDeps()
        try await loadBoth(deps)
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: nil) { response, json in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [self.llm.rawValue, self.tts.rawValue])
                XCTAssertNotNil(json["memGb"] as? Double)
            }
            // An empty JSON object is also "all" — and now nothing is resident.
            try await self.unload(client, body: "{}") { response, json in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [])
            }
        }
        let ttsAfter = await deps.engine.loadedBackend()
        let llmAfter = await deps.engine.loadedLLM()
        XCTAssertNil(ttsAfter)
        XCTAssertNil(llmAfter)
    }

    func testTTSTargetLeavesLLMResident() async throws {
        let deps = makeDeps()
        try await loadBoth(deps)
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: #"{"target":"tts"}"#) { response, json in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [self.tts.rawValue])
            }
        }
        let ttsAfter = await deps.engine.loadedBackend()
        let llmAfter = await deps.engine.loadedLLM()
        XCTAssertNil(ttsAfter)
        XCTAssertEqual(llmAfter, llm)
    }

    func testLLMTargetLeavesTTSResident() async throws {
        let deps = makeDeps()
        try await loadBoth(deps)
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: #"{"target":"llm"}"#) { response, json in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [self.llm.rawValue])
            }
        }
        let ttsAfter = await deps.engine.loadedBackend()
        let llmAfter = await deps.engine.loadedLLM()
        XCTAssertEqual(ttsAfter, tts)
        XCTAssertNil(llmAfter)
    }

    func testBadTargetIs400AndUnloadsNothing() async throws {
        let deps = makeDeps()
        try await loadBoth(deps)
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: #"{"target":"gpu"}"#) { response, json in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(json["detail"] as? String, "target must be one of: tts, llm, all")
            }
            try await self.unload(client, body: "not json") { response, json in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertNotNil(json["detail"] as? String)
            }
        }
        let ttsAfter = await deps.engine.loadedBackend()
        let llmAfter = await deps.engine.loadedLLM()
        XCTAssertEqual(ttsAfter, tts)
        XCTAssertEqual(llmAfter, llm)
    }

    func testTTSUnloadWaitsForInFlightRender() async throws {
        let speech = GatedSpeechProvider()
        let deps = makeDeps(speech: speech)
        speech.model.arm()
        let engine = deps.engine, backend = tts, request = synthRequest
        let render = Task { try await engine.synthesize(backend: backend, request: request) }
        await speech.model.waitUntilStarted()

        let released = Flag()
        let releaser = Task {
            try await Task.sleep(for: .milliseconds(150))
            let stillLoaded = await engine.loadedBackend()
            XCTAssertEqual(stillLoaded, backend, "must not evict mid-render")
            await released.set()
            speech.model.release()
        }
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: #"{"target":"tts"}"#) { response, json in
                let wasReleased = await released.isSet
                XCTAssertTrue(wasReleased, "unload answered before the render finished")
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [backend.rawValue])
            }
        }
        try await releaser.value
        let result = try await render.value
        XCTAssertFalse(result.samples.isEmpty, "the in-flight render completes normally")
        let after = await engine.loadedBackend()
        XCTAssertNil(after)
    }

    func testLLMUnloadWaitsForActiveChatStream() async throws {
        let chat = GatedChatProvider()
        let deps = makeDeps(chat: chat)
        let engine = deps.engine, model = llm
        let stream = await engine.chatStream(
            backend: model, request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()   // first delta — the reply is live

        let released = Flag()
        let releaser = Task {
            try await Task.sleep(for: .milliseconds(150))
            let stillLoaded = await engine.loadedLLM()
            XCTAssertEqual(stillLoaded, model, "must not unload mid-reply")
            await released.set()
            chat.model.release()
        }
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: #"{"target":"llm"}"#) { response, json in
                let wasReleased = await released.isSet
                XCTAssertTrue(wasReleased, "unload answered before the chat reply finished")
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(json["unloaded"] as? [String], [model.rawValue])
            }
        }
        try await releaser.value
        var finished = false
        while let event = try await iterator.next() {
            if case .finished = event { finished = true }
        }
        XCTAssertTrue(finished, "the chat reply ran to completion")
    }

    func testUnloadIsLoggedAndRequiresTokenInLANMode() async throws {
        let log = APILog(capacity: 50)
        let deps = makeDeps(log: log, authToken: { "sekrit" })
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await self.unload(client, body: nil) { response, _ in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await self.unload(client, body: nil,
                                  headers: [.authorization: "Bearer sekrit"]) { response, _ in
                XCTAssertEqual(response.status, .ok)
            }
        }
        // The middleware's `record` hops to @MainActor via Task; poll briefly.
        var entry: APILogEntry?
        for _ in 0..<50 {
            entry = await MainActor.run {
                log.entries.first { $0.path == "/v1/models/unload" && $0.status == 200 }
            }
            if entry != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(entry?.method, "POST")
    }

    func testMCPUnloadModelsTool() async throws {
        let deps = makeDeps()
        try await loadBoth(deps)
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            let rpc = #"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call",
             "params":{"name":"unload_models","arguments":{"target":"tts"}}}
            """#
            try await client.execute(uri: "/mcp", method: .post,
                                     body: ByteBuffer(string: rpc)) { response in
                XCTAssertEqual(response.status, .ok)
                let reply = try JSONSerialization.jsonObject(
                    with: Data(buffer: response.body)) as? [String: Any]
                let result = reply?["result"] as? [String: Any]
                XCTAssertEqual(result?["isError"] as? Bool, false)
                let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                XCTAssertEqual(body?["unloaded"] as? [String], [self.tts.rawValue])
                XCTAssertNotNil(body?["memGb"] as? Double)
            }
            let bad = #"""
            {"jsonrpc":"2.0","id":8,"method":"tools/call",
             "params":{"name":"unload_models","arguments":{"target":"gpu"}}}
            """#
            try await client.execute(uri: "/mcp", method: .post,
                                     body: ByteBuffer(string: bad)) { response in
                let reply = try JSONSerialization.jsonObject(
                    with: Data(buffer: response.body)) as? [String: Any]
                XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true)
            }
        }
        let llmAfter = await deps.engine.loadedLLM()
        XCTAssertEqual(llmAfter, llm, "target=tts leaves the LLM alone")
    }
}
