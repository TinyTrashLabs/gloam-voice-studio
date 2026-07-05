import XCTest
@testable import EngineKit

/// Emits real incremental deltas — exercises the streaming path end to end.
final class StreamingFakeModel: LanguageModel, @unchecked Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "Hello", toolCalls: [],
                   usage: ChatUsage(promptTokens: 1, completionTokens: 2), wallSeconds: 0)
    }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        Task {
            continuation.yield(.delta("Hel"))
            continuation.yield(.delta("lo"))
            continuation.yield(.finished(ChatResult(
                text: "Hello", toolCalls: [],
                usage: ChatUsage(promptTokens: 1, completionTokens: 2),
                wallSeconds: 0, tokensPerSecond: 42)))
            continuation.finish()
        }
        return stream
    }
}

final class StreamingFakeProvider: LanguageModelProviding, @unchecked Sendable {
    var loads: [LLMBackendID] = []
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel {
        loads.append(backend)
        return StreamingFakeModel()
    }
    func didEvictModel() {}
}

final class ChatStreamTests: XCTestCase {
    func testStreamYieldsDeltasThenFinished() async throws {
        let engine = GloamEngine(provider: FakeProvider(),
                                 languageProvider: StreamingFakeProvider())
        var deltas: [String] = []
        var finished: ChatResult?
        let stream = await engine.chatStream(
            backend: .qwen3_1_7b,
            request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
        for try await event in stream {
            switch event {
            case .delta(let d): deltas.append(d)
            case .finished(let r): finished = r
            }
        }
        XCTAssertEqual(deltas, ["Hel", "lo"])
        XCTAssertEqual(finished?.text, "Hello")
        XCTAssertEqual(finished?.tokensPerSecond, 42)
    }

    func testDefaultStreamImplementationWrapsComplete() async throws {
        // FakeLanguageModel (GloamEngineLLMTests.swift) doesn't override stream —
        // the protocol-extension default must emit one delta + finished.
        let model = FakeLanguageModel(reply: "one-shot")
        var events: [ChatEvent] = []
        for try await event in model.stream(
            ChatRequest(messages: [ChatTurn(role: .user, content: "hi")])) {
            events.append(event)
        }
        guard events.count == 2,
              case .delta(let d) = events[0],
              case .finished(let r) = events[1] else {
            return XCTFail("expected [delta, finished], got \(events)")
        }
        XCTAssertEqual(d, "one-shot")
        XCTAssertEqual(r.text, "one-shot")
    }

    func testChatStreamThrowsWithoutLanguageProvider() async {
        let engine = GloamEngine(provider: FakeProvider())
        let stream = await engine.chatStream(
            backend: .qwen3_1_7b,
            request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
        do {
            for try await _ in stream { XCTFail("no events expected") }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? EngineError, .languageProviderUnavailable)
        }
    }

    func testChatStreamReusesResidentModel() async throws {
        let provider = StreamingFakeProvider()
        let engine = GloamEngine(provider: FakeProvider(), languageProvider: provider)
        for _ in 0..<2 {
            let stream = await engine.chatStream(
                backend: .qwen3_1_7b,
                request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
            for try await _ in stream {}
        }
        XCTAssertEqual(provider.loads, [.qwen3_1_7b], "same backend should load once")
    }
}
