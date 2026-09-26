import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

private final class StubLangModel: LanguageModel, @unchecked Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "spin it up", toolCalls: [],
                   usage: ChatUsage(promptTokens: 3, completionTokens: 2), wallSeconds: 0, tokensPerSecond: nil)
    }
}
private final class StubLangProvider: LanguageModelProviding, @unchecked Sendable {
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { StubLangModel() }
    func didEvictModel() {}
}

final class ChatRouteTests: XCTestCase, @unchecked Sendable {
    func testChatCompletionHappyPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider(), languageProvider: StubLangProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            defaultLLM: .qwen3_1_7b)
        let app = Application(router: APIRouter.build(deps))
        let body = ByteBuffer(string: """
        {"messages":[{"role":"user","content":"hype the crowd"}]}
        """)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as! [String: Any]
                let choices = obj["choices"] as! [[String: Any]]
                let message = choices[0]["message"] as! [String: Any]
                XCTAssertEqual(message["content"] as? String, "spin it up")
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testChatCompletionWithNoUserMessageIs400() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider(), languageProvider: StubLangProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            defaultLLM: .qwen3_1_7b)
        let app = Application(router: APIRouter.build(deps))
        // messages present, but no user turn → must be 400, not 503
        let body = ByteBuffer(string: #"{"messages":[{"role":"system","content":"be brief"}]}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testChatCompletionWithoutLLMConfigured() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider()),  // no language provider
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo)               // defaultLLM nil
        let app = Application(router: APIRouter.build(deps))
        let body = ByteBuffer(string: #"{"messages":[{"role":"user","content":"hi"}]}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func testChatCompletionForModelWithoutWeightsIsServiceUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-missing-weights-\(UUID().uuidString)")
        let modelDir = root.appendingPathComponent(LLMBackendID.gemma4_26b.diskFolder)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let languageProvider = MLXLanguageModelProvider { backend in
            root.appendingPathComponent(backend.diskFolder)
        }
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider(), languageProvider: languageProvider),
            voices: VoiceLibrary(directory: root.appendingPathComponent("voices")),
            defaultBackend: .chatterboxTurbo,
            defaultLLM: .qwen3_1_7b)
        let app = Application(router: APIRouter.build(deps))
        let body = ByteBuffer(string: #"{"model":"gemma4-26b","messages":[{"role":"user","content":"hi"}]}"#)

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
            }
        }
    }

    /// `stream: true` answers as server-sent events: a role-bearing first
    /// chunk, content deltas, a stop chunk with usage, then `[DONE]`.
    func testChatCompletionStreamsServerSentEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider(), languageProvider: StubLangProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            defaultLLM: .qwen3_1_7b)
        let app = Application(router: APIRouter.build(deps))
        let body = ByteBuffer(string: #"{"stream":true,"messages":[{"role":"user","content":"hype the crowd"}]}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                                     headers: [.contentType: "application/json"], body: body) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "text/event-stream")
                let text = String(buffer: response.body)
                let frames = text.components(separatedBy: "\n\n").filter { $0.hasPrefix("data: ") }.map { $0.dropFirst(6) }
                XCTAssertEqual(frames.last, "[DONE]")
                let chunks = try frames.dropLast().map {
                    try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(String($0).utf8))
                }
                XCTAssertEqual(chunks.first?.choices[0].delta.role, "assistant")
                XCTAssertEqual(chunks.compactMap { $0.choices[0].delta.content }.joined(), "spin it up")
                XCTAssertEqual(chunks.last?.choices[0].finish_reason, "stop")
                XCTAssertEqual(chunks.last?.usage?.completion_tokens, 2)
                XCTAssertTrue(chunks.allSatisfy { $0.object == "chat.completion.chunk" })
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }
}
