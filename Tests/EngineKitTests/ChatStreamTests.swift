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

/// Thread-safe yield counter shared between a fake model's producer loop and
/// the test's polling assertions.
private actor YieldCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Emits deltas from an unbounded loop, incrementing `counter` per yield, until
/// its producer Task is cancelled — which happens via `onTermination` when the
/// *consumer* stops iterating. Used to prove that cancelling the consumer of
/// GloamEngine.chatStream actually stops the underlying producer, rather than
/// leaving it running in the background forever.
private final class UnboundedCountingModel: LanguageModel, @unchecked Sendable {
    let counter = YieldCounter()
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "x", toolCalls: [], usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)
    }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let counter = counter
        let producer = Task {
            var i = 0
            while !Task.isCancelled {
                i += 1
                await counter.increment()
                continuation.yield(.delta("d\(i)"))
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms pacing
            }
        }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }
}

private final class SingleModelLanguageProvider: LanguageModelProviding, @unchecked Sendable {
    let model: any LanguageModel
    init(model: any LanguageModel) { self.model = model }
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { model }
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

    /// Cancelling the task that's consuming a chatStream must stop the
    /// underlying producer (onTermination → cancel), not just stop delivering
    /// events to a now-defunct consumer while generation keeps running
    /// unattended in the background.
    func testCancellingConsumerStopsProducer() async throws {
        let model = UnboundedCountingModel()
        let engine = GloamEngine(provider: FakeProvider(),
                                 languageProvider: SingleModelLanguageProvider(model: model))

        let consumer = Task {
            let stream = await engine.chatStream(
                backend: .qwen3_1_7b,
                request: ChatRequest(messages: [ChatTurn(role: .user, content: "hi")]))
            for try await _ in stream {
                // Consume indefinitely until the task is cancelled.
            }
        }

        // Poll (bounded) until at least a few deltas have flowed, so we know
        // the producer is actually running before we cancel it.
        var waited = 0
        while await model.counter.count < 3, waited < 2_000 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            waited += 10
        }
        let countBeforeCancel = await model.counter.count
        XCTAssertGreaterThanOrEqual(countBeforeCancel, 3, "producer never started yielding")

        consumer.cancel()

        // Give cancellation time to propagate through the two stream hops
        // (engine's onTermination → work.cancel(), then the model's own
        // onTermination → producer.cancel()).
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        let countJustAfterCancel = await model.counter.count

        // Poll a bit longer: if the producer were still running, the count
        // would keep climbing. Bounded total wait keeps this deterministic.
        var stableChecks = 0
        var lastCount = countJustAfterCancel
        while stableChecks < 5 {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            let now = await model.counter.count
            XCTAssertEqual(now, lastCount, "yield count grew after the consumer was cancelled")
            lastCount = now
            stableChecks += 1
        }
    }
}
