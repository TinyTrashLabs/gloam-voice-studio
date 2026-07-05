import XCTest
@testable import EngineKit

/// Ordered record of what happened, shared across tasks.
private actor EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
    func contains(_ event: String) -> Bool { events.contains(event) }
}

/// Paced fake: yields "one.", then waits for the test's signal, then "two."
/// and finished. The wait models the GPU-idle gap between token pulls where
/// interleaved synthesis is allowed to run.
private final class GatedPacedModel: LanguageModel, @unchecked Sendable {
    private let gate: AsyncStream<Void>
    let openGate: AsyncStream<Void>.Continuation

    init() {
        (gate, openGate) = AsyncStream<Void>.makeStream()
    }

    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "one. two.", toolCalls: [],
                   usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)
    }

    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        await onEvent(.delta("one."))
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        await onEvent(.delta(" two."))
        await onEvent(.finished(ChatResult(
            text: "one. two.", toolCalls: [],
            usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)))
    }
}

private final class SingleModelLanguageProvider: LanguageModelProviding, @unchecked Sendable {
    let model: any LanguageModel
    init(model: any LanguageModel) { self.model = model }
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { model }
    func didEvictModel() {}
}

final class InterleavedSynthesisTests: XCTestCase {
    /// A synthesis queued mid-stream completes BEFORE the stream finishes —
    /// i.e. it ran in a between-deltas gap, not after the chat released the tail.
    func testInterleavedSynthesisRunsBetweenDeltas() async throws {
        let llm = GatedPacedModel()
        let engine = GloamEngine(provider: FakeProvider(),
                                 languageProvider: SingleModelLanguageProvider(model: llm))
        let log = EventLog()

        let streamTask = Task {
            for try await event in await engine.chatStream(
                backend: .qwen3_1_7b, request: ChatRequest(messages: [.init(role: .user, content: "hi")])) {
                switch event {
                case .delta(let t): await log.add("delta:\(t)")
                case .finished: await log.add("finished")
                }
            }
        }

        // Wait until the first delta arrived (stream is now parked on the gate).
        for _ in 0..<100 {
            if await log.contains("delta:one.") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let synthTask = Task {
            _ = try await engine.synthesizeInterleaved(
                backend: .qwen17B, request: SynthesisRequest(text: "one."))
            await log.add("synth-done")
        }
        // Let the request reach the engine's queue before un-parking the model.
        try await Task.sleep(for: .milliseconds(100))
        llm.openGate.yield()

        try await synthTask.value
        try await streamTask.value

        let events = await log.events
        let synthIdx = try XCTUnwrap(events.firstIndex(of: "synth-done"))
        let finishedIdx = try XCTUnwrap(events.firstIndex(of: "finished"))
        XCTAssertLessThan(synthIdx, finishedIdx,
                          "interleaved synthesis must complete while the stream is active, got \(events)")
    }

    /// With no active chat stream, synthesizeInterleaved is plain synthesize.
    func testInterleavedFallsBackToNormalSynthesisWhenNoChatActive() async throws {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider,
                                 languageProvider: SingleModelLanguageProvider(model: GatedPacedModel()))
        let result = try await engine.synthesizeInterleaved(
            backend: .qwen17B, request: SynthesisRequest(text: "hello"))
        XCTAssertEqual(result.samples, [0.1, 0.2, 0.3])
        let model = try XCTUnwrap(provider.models[.qwen17B] as? FakeModel)
        XCTAssertEqual(model.received.map(\.text), ["hello"])
    }

    /// A failing synthesis rejects its waiter but does not kill the chat stream.
    func testInterleavedSynthesisErrorDoesNotKillStream() async throws {
        let failing = FakeModel()
        failing.errorToThrow = EngineError.languageProviderUnavailable
        let provider = FakeProvider()
        provider.models[.qwen17B] = failing
        let llm = GatedPacedModel()
        let engine = GloamEngine(provider: provider,
                                 languageProvider: SingleModelLanguageProvider(model: llm))
        let log = EventLog()

        let streamTask = Task {
            for try await event in await engine.chatStream(
                backend: .qwen3_1_7b, request: ChatRequest(messages: [.init(role: .user, content: "hi")])) {
                if case .finished = event { await log.add("finished") }
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        let synthTask = Task { () -> Bool in
            do {
                _ = try await engine.synthesizeInterleaved(
                    backend: .qwen17B, request: SynthesisRequest(text: "boom"))
                return false
            } catch { return true }
        }
        try await Task.sleep(for: .milliseconds(100))
        llm.openGate.yield()

        let threw = await synthTask.value
        try await streamTask.value
        XCTAssertTrue(threw, "interleaved synthesis error must reach its waiter")
        let finished = await log.contains("finished")
        XCTAssertTrue(finished, "stream must finish normally despite the synth failure")
    }
}
