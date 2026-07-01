import XCTest
@testable import EngineKit

final class FakeLanguageModel: LanguageModel, @unchecked Sendable {
    let reply: String
    init(reply: String) { self.reply = reply }
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: reply, toolCalls: [],
                   usage: ChatUsage(promptTokens: 1, completionTokens: 1),
                   wallSeconds: 0)
    }
}

final class FakeLanguageProvider: LanguageModelProviding, @unchecked Sendable {
    var loads: [LLMBackendID] = []
    var evictions = 0
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel {
        loads.append(backend)
        return FakeLanguageModel(reply: "hello from \(backend.rawValue)")
    }
    func didEvictModel() { evictions += 1 }
}

final class GloamEngineLLMTests: XCTestCase {
    func testChatThrowsWhenNoLanguageProvider() async {
        let engine = GloamEngine(provider: FakeProvider())   // FakeProvider from GloamEngineTests
        do {
            _ = try await engine.chat(backend: .qwen3_1_7b,
                                      request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? EngineError, .languageProviderUnavailable)
        }
    }

    func testChatLoadsAndReplies() async throws {
        let lang = FakeLanguageProvider()
        let engine = GloamEngine(provider: FakeProvider(), languageProvider: lang)
        let result = try await engine.chat(
            backend: .gemma4_e4b,
            request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(result.text, "hello from gemma4-e4b")
        XCTAssertEqual(lang.loads, [.gemma4_e4b])
    }

    func testLLMResidencyReusedAcrossCalls() async throws {
        let lang = FakeLanguageProvider()
        let engine = GloamEngine(provider: FakeProvider(), languageProvider: lang)
        _ = try await engine.chat(backend: .gemma4_e4b, request: .init(messages: [ChatTurn(role: .user, content: "a")]))
        _ = try await engine.chat(backend: .gemma4_e4b, request: .init(messages: [ChatTurn(role: .user, content: "b")]))
        XCTAssertEqual(lang.loads, [.gemma4_e4b], "same backend should load once")
        let loaded = await engine.loadedLLM()
        XCTAssertEqual(loaded, .gemma4_e4b)
    }

    func testTTSAndLLMCoexist() async throws {
        let lang = FakeLanguageProvider()
        let speech = FakeProvider()
        let engine = GloamEngine(provider: speech, languageProvider: lang)
        _ = try await engine.preload(backend: .chatterboxTurbo)
        _ = try await engine.chat(backend: .qwen3_1_7b, request: .init(messages: [ChatTurn(role: .user, content: "hi")]))
        // Loading the LLM must NOT evict the resident TTS model.
        let tts = await engine.loadedBackend()
        let llm = await engine.loadedLLM()
        XCTAssertEqual(tts, .chatterboxTurbo)
        XCTAssertEqual(llm, .qwen3_1_7b)
    }
}
