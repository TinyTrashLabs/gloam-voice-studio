import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

private final class StubLangModel: LanguageModel, @unchecked Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "spin it up", toolCalls: [],
                   usage: ChatUsage(promptTokens: 3, completionTokens: 2), wallSeconds: 0)
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
}
