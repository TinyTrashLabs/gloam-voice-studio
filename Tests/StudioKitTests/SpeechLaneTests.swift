import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// Interval log shared by the fake models: when each render ran, per backend.
private final class Intervals: @unchecked Sendable {
    struct Span { let backend: BackendID; let start: Date; let end: Date }
    private let lock = NSLock()
    private var spans: [Span] = []
    func add(_ s: Span) { lock.lock(); spans.append(s); lock.unlock() }
    func all(_ backend: BackendID? = nil) -> [Span] {
        lock.lock(); defer { lock.unlock() }
        return spans.filter { backend == nil || $0.backend == backend }.sorted { $0.start < $1.start }
    }
}

/// A clone model whose render takes `delay`, so overlapping and queueing show up in wall time.
private final class SlowModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24_000
    let backend: BackendID
    let log: Intervals
    let delay: Duration
    init(backend: BackendID, log: Intervals, delay: Duration) { self.backend = backend; self.log = log; self.delay = delay }
    private func render() async throws -> [Float] {
        let start = Date()
        try await Task.sleep(for: delay)
        log.add(.init(backend: backend, start: start, end: Date()))
        return (0..<2_400).map { Float(sin(Double($0) * 0.05)) * 0.4 }
    }
    func synthesize(_ request: ProviderRequest) async throws -> [Float] { try await render() }
    func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { c in
            let t = Task {
                do { c.yield(try await self.render()); c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

private final class SlowProvider: ModelProviding, @unchecked Sendable {
    let log: Intervals
    let delay: Duration
    init(log: Intervals, delay: Duration = .milliseconds(500)) { self.log = log; self.delay = delay }
    func loadModel(backend: BackendID) async throws -> any SpeechModel { SlowModel(backend: backend, log: log, delay: delay) }
    func didEvictModel() {}
}

private final class WarmModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24_000
    private let lock = NSLock()
    private var calls: [ProviderRequest] = []
    var warmed: [ProviderRequest] { lock.lock(); defer { lock.unlock() }; return calls }
    func synthesize(_ request: ProviderRequest) async throws -> [Float] { [0.1] }
    func warm(_ request: ProviderRequest) async throws { record(request) }
    private func record(_ r: ProviderRequest) { lock.lock(); calls.append(r); lock.unlock() }
}
private final class WarmProvider: ModelProviding, @unchecked Sendable {
    let model = WarmModel()
    func loadModel(backend: BackendID) async throws -> any SpeechModel { model }
    func didEvictModel() {}
}

private final class PacedChat: LanguageModel, @unchecked Sendable {
    let gate: AsyncStream<Void>
    let open: AsyncStream<Void>.Continuation
    init() { (gate, open) = AsyncStream<Void>.makeStream() }
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "a b", toolCalls: [], usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)
    }
    func pacedStream(_ request: ChatRequest, onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        await onEvent(.delta("a"))
        var it = gate.makeAsyncIterator()
        _ = await it.next()
        await onEvent(.delta(" b"))
        await onEvent(.finished(ChatResult(text: "a b", toolCalls: [], usage: ChatUsage(promptTokens: 0, completionTokens: 0), wallSeconds: 0)))
    }
}
private final class PacedChatProvider: LanguageModelProviding, @unchecked Sendable {
    let model: PacedChat
    init(_ m: PacedChat) { model = m }
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel { model }
    func didEvictModel() {}
}

/// One speech render per engine family at a time: a Neural Engine request and a GPU request overlap, two requests
/// on the same family queue, and a chat stream still interleaves with GPU speech.
final class SpeechLaneTests: XCTestCase, @unchecked Sendable {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("speech-lanes-\(UUID().uuidString)")
        let ref = WAVEncoder.encode(pcm16: PCM16.data(from: (0..<48_000).map { Float(sin(Double($0) * 0.1)) * 0.3 }),
                                    sampleRate: 24_000)
        _ = try VoiceLibrary(directory: dir).save(name: "Titan", refWav: ref, refText: "I am not a toy.")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func deps(_ log: Intervals, twoLanes: Bool = true, llm: PacedChat? = nil,
                      delay: Duration = .milliseconds(500)) -> APIDependencies {
        APIDependencies(
            engine: GloamEngine(provider: SlowProvider(log: log, delay: delay),
                                languageProvider: llm.map(PacedChatProvider.init)),
            voices: VoiceLibrary(directory: dir), defaultBackend: .qwen06BMobile,
            defaultLLM: llm == nil ? nil : .qwen3_1_7b,
            neuralEngine: twoLanes ? GloamEngine(provider: SlowProvider(log: log, delay: delay)) : nil)
    }

    private func body(_ model: BackendID, stream: Bool) -> ByteBuffer {
        ByteBuffer(string: #"{"input":"Hello there.","model":"\#(model.rawValue)","voice":"titan","stream":\#(stream)}"#)
    }

    private func overlap(_ a: Intervals.Span, _ b: Intervals.Span) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    /// Fires `models` at the server at once; returns the wall time until every response is in.
    private func fire(_ app: some ApplicationProtocol, _ models: [BackendID], stream: Bool) async throws -> TimeInterval {
        let t0 = Date()
        try await app.test(.router) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for m in models {
                    group.addTask {
                        try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.body(m, stream: stream)) { r in
                            XCTAssertEqual(r.status, .ok, "\(m.rawValue)")
                            XCTAssertGreaterThan(r.body.readableBytes, 44)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        return Date().timeIntervalSince(t0)
    }

    func testFamilies() {
        XCTAssertEqual(BackendID.qwen06BANE.speechFamily, .neuralEngine)
        for b in BackendID.allCases where b != .qwen06BANE { XCTAssertEqual(b.speechFamily, .gpu, b.rawValue) }
    }

    func testANEAndMLXRequestsOverlap() async throws {
        for stream in [false, true] {
            let log = Intervals()
            let app = Application(router: APIRouter.build(deps(log)))
            let wall = try await fire(app, [.qwen06BANE, .qwen06BMobile], stream: stream)
            let ane = try XCTUnwrap(log.all(.qwen06BANE).first), mlx = try XCTUnwrap(log.all(.qwen06BMobile).first)
            XCTAssertGreaterThan(overlap(ane, mlx), 0.3, "stream=\(stream): the two renders did not overlap")
            XCTAssertLessThan(wall, 0.95, "stream=\(stream): wall \(wall)s is not much below the two renders back to back (1.0 s)")
        }
    }

    func testTwoANERequestsSerialize() async throws {
        for stream in [false, true] {
            let log = Intervals()
            let app = Application(router: APIRouter.build(deps(log)))
            let wall = try await fire(app, [.qwen06BANE, .qwen06BANE], stream: stream)
            let spans = log.all(.qwen06BANE)
            XCTAssertEqual(spans.count, 2)
            XCTAssertLessThan(overlap(spans[0], spans[1]), 0.02, "stream=\(stream): two ANE renders ran at once")
            XCTAssertGreaterThan(wall, 0.95, "stream=\(stream): they were not serialized (wall \(wall)s)")
        }
    }

    func testTwoMLXRequestsStillSerialize() async throws {
        let log = Intervals()
        let app = Application(router: APIRouter.build(deps(log)))
        _ = try await fire(app, [.qwen06BMobile, .qwen06BMobile], stream: false)
        let spans = log.all(.qwen06BMobile)
        XCTAssertEqual(spans.count, 2)
        XCTAssertLessThan(overlap(spans[0], spans[1]), 0.02)
    }

    /// No Neural Engine lane supplied (a bare server, an older host app): everything shares the one lane, as before.
    func testWithoutANELaneEverythingSerializes() async throws {
        let log = Intervals()
        let app = Application(router: APIRouter.build(deps(log, twoLanes: false)))
        _ = try await fire(app, [.qwen06BANE, .qwen06BMobile], stream: false)
        let spans = log.all()
        XCTAssertEqual(spans.count, 2)
        XCTAssertLessThan(overlap(spans[0], spans[1]), 0.02)
    }

    /// The Neural Engine lane is a separate engine: an ANE render must not evict (or wait behind a load of) the
    /// GPU engine's resident model, and vice versa.
    func testLanesKeepTheirOwnResidentModels() async throws {
        let log = Intervals()
        let d = deps(log, delay: .milliseconds(20))
        let app = Application(router: APIRouter.build(d))
        _ = try await fire(app, [.qwen06BMobile], stream: false)
        _ = try await fire(app, [.qwen06BANE], stream: false)
        let gpu = await d.engine.loadedBackend(), neural = await d.neuralEngine?.loadedBackend()
        XCTAssertEqual(gpu, .qwen06BMobile)
        XCTAssertEqual(neural, .qwen06BANE)
    }

    /// A chat stream parked between deltas on the main engine. GPU speech still interleaves into the gap (it runs
    /// at the next delta, the original rule); ANE speech no longer waits for the chat at all, it renders on its own
    /// lane meanwhile. Neither deadlocks and the chat finishes.
    func testChatStreamStillInterleavesAndANEDoesNotWaitForIt() async throws {
        let llm = PacedChat()
        let log = Intervals()
        let d = deps(log, llm: llm, delay: .milliseconds(100))
        let chatDone = Flag()
        let chat = Task {
            var deltas = 0
            for try await event in await d.engine.chatStream(
                backend: .qwen3_1_7b, request: ChatRequest(messages: [.init(role: .user, content: "hi")]))
            { if case .delta = event { deltas += 1 } }
            chatDone.set()
            return deltas
        }
        try await Task.sleep(for: .milliseconds(300))            // parked between deltas
        let app = Application(router: APIRouter.build(d))
        // ANE: answers while the chat is still parked
        let t0 = Date()
        _ = try await fire(app, [.qwen06BANE], stream: true)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "ANE speech waited for the chat stream")
        XCTAssertFalse(chatDone.value, "the chat finished before it was released")
        // GPU: queued into the gap, runs when the chat produces its next delta
        let opener = Task { try await Task.sleep(for: .milliseconds(800)); llm.open.yield() }
        _ = try await fire(app, [.qwen06BMobile], stream: true)
        XCTAssertEqual(log.all().count, 2)
        opener.cancel()
        llm.open.yield()
        let deltas = try await chat.value
        XCTAssertEqual(deltas, 2)
    }

    // MARK: warmup

    func testWarmupPreparesTheVoiceOnTheNeuralLaneOnly() async throws {
        let warm = WarmProvider()
        let main = WarmProvider()
        let d = APIDependencies(engine: GloamEngine(provider: main), voices: VoiceLibrary(directory: dir),
                                defaultBackend: .qwen06BMobile, neuralEngine: GloamEngine(provider: warm))
        try await Application(router: APIRouter.build(d)).test(.router) { client in
            let ok = ByteBuffer(string: #"{"model":"qwen3-0.6b-ane","voice":"titan"}"#)
            try await client.execute(uri: "/v1/audio/warmup", method: .post, body: ok) { r in
                XCTAssertEqual(r.status, .ok)
                let json = try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]
                XCTAssertEqual(json?["model"] as? String, "qwen3-0.6b-ane")
                XCTAssertEqual(json?["voice"] as? String, "titan")
                XCTAssertNotNil(json?["seconds"] as? Double)
            }
            let bad = ByteBuffer(string: #"{"model":"qwen3-0.6b-ane","voice":"nobody"}"#)
            try await client.execute(uri: "/v1/audio/warmup", method: .post, body: bad) { XCTAssertEqual($0.status, .badRequest) }
            let none = ByteBuffer(string: #"{"model":"qwen3-0.6b-ane"}"#)
            try await client.execute(uri: "/v1/audio/warmup", method: .post, body: none) { XCTAssertEqual($0.status, .badRequest) }
        }
        let calls = warm.model.warmed
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.refText, "I am not a toy.")
        XCTAssertTrue(calls.first?.refAudioPath?.hasSuffix("ref.wav") == true)
        XCTAssertEqual(main.model.warmed.count, 0, "the GPU lane was touched")
        let gpuLoaded = await d.engine.loadedBackend()
        XCTAssertNil(gpuLoaded)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
