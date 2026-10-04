import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// A clone model that streams three chunks (the way qwen3-0.6b-ane does), and renders the same samples whole.
private final class ChunkedSpeechModel: SpeechModel, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: ProviderRequest?
    let sampleRate = 24_000
    static let chunks: [[Float]] = [
        (0..<2_000).map { Float(sin(Double($0) * 0.05)) * 0.5 },
        (0..<1_500).map { Float(sin(Double($0) * 0.07)) * 0.4 },
        (0..<700).map { Float(sin(Double($0) * 0.09)) * 0.3 },
    ]
    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        Self.lastRequest = request
        return Self.chunks.flatMap { $0 }
    }
    func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
        Self.lastRequest = request
        return AsyncThrowingStream { c in
            for chunk in Self.chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private final class ChunkedProvider: ModelProviding, @unchecked Sendable {
    var failure: Error?
    func loadModel(backend: BackendID) async throws -> any SpeechModel {
        if let failure { throw failure }
        return ChunkedSpeechModel()
    }
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

final class SpeechStreamingTests: XCTestCase, @unchecked Sendable {
    private var dir: URL!
    private let provider = ChunkedProvider()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("speech-stream-\(UUID().uuidString)")
        let ref = WAVEncoder.encode(pcm16: PCM16.data(from: (0..<48_000).map { Float(sin(Double($0) * 0.1)) * 0.3 }),
                                    sampleRate: 24_000)
        _ = try VoiceLibrary(directory: dir).save(name: "Titan", refWav: ref, refText: "I am not a toy.")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeDeps(llm: PacedChat? = nil) -> APIDependencies {
        APIDependencies(
            engine: GloamEngine(provider: provider, languageProvider: llm.map(PacedChatProvider.init)),
            voices: VoiceLibrary(directory: dir), defaultBackend: .qwen06BANE,
            defaultLLM: llm == nil ? nil : .qwen3_1_7b)
    }

    private let expectedPCM = PCM16.data(from: ChunkedSpeechModel.chunks.flatMap { $0 })

    private func speech(_ extra: String) -> ByteBuffer {
        ByteBuffer(string: #"{"input":"Hello there.","model":"qwen3-0.6b-ane","voice":"titan"\#(extra)}"#)
    }

    // MARK: framing

    func testStreamHeaderIsOpenEndedAndPCMIsTheChunksInOrder() async throws {
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(#","stream":true"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                let bytes = Data(buffer: response.body)
                XCTAssertEqual(bytes.prefix(4), Data("RIFF".utf8))
                XCTAssertEqual(bytes[4...7], Data([0xFF, 0xFF, 0xFF, 0xFF]))
                XCTAssertEqual(bytes[8...11], Data("WAVE".utf8))
                XCTAssertEqual(bytes[24...27], 24_000.leBytes)               // sample rate
                XCTAssertEqual(bytes[40...43], Data([0xFF, 0xFF, 0xFF, 0xFF])) // data size
                XCTAssertEqual(bytes.dropFirst(44), self.expectedPCM)
            }
        }
    }

    func testStreamFormatAudioAloneStreams() async throws {
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(#","stream_format":"audio""#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(Data(buffer: response.body)[4...7], Data([0xFF, 0xFF, 0xFF, 0xFF]))
            }
        }
    }

    /// The streamed PCM is sample-for-sample the whole-take body (same gain, same quantization).
    func testStreamedPCMEqualsTheNonStreamedWavBody() async throws {
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech("")) { response in
                XCTAssertEqual(response.status, .ok)
                let wav = Data(buffer: response.body)
                XCTAssertEqual(wav.count, 44 + self.expectedPCM.count)
                XCTAssertEqual(wav.dropFirst(44), self.expectedPCM)
                XCTAssertNotEqual(wav[4...7], Data([0xFF, 0xFF, 0xFF, 0xFF]), "the non-stream path keeps its real sizes")
            }
        }
    }

    // MARK: errors surface as statuses, not a broken 200

    func testSSEFormatIsRejected() async throws {
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(#","stream_format":"sse""#)) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testModelNotInstalledIs503BeforeAnyBytes() async throws {
        provider.failure = EngineError.modelNotInstalled(backend: .qwen06BANE, detail: "expected at /nowhere")
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            for extra in [#","stream":true"#, ""] {
                try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(extra)) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, "extra \(extra)")
                    XCTAssertTrue(String(buffer: response.body).contains("/nowhere"))
                }
            }
        }
    }

    func testUnknownVoiceStillA400WhenStreaming() async throws {
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            let body = ByteBuffer(string: #"{"input":"Hi.","model":"qwen3-0.6b-ane","voice":"nobody","stream":true}"#)
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    // MARK: the planner sees the same request

    func testReferenceAndTranscriptReachTheModel() async throws {
        ChunkedSpeechModel.lastRequest = nil
        try await Application(router: APIRouter.build(makeDeps())).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(#","stream":true"#)) { _ in }
        }
        let sent = try XCTUnwrap(ChunkedSpeechModel.lastRequest)
        XCTAssertEqual(sent.refText, "I am not a toy.")
        XCTAssertTrue(sent.refAudioPath?.hasSuffix("ref.wav") == true)
    }

    // MARK: no deadlock with a streamed chat in flight

    func testStreamingSpeechRunsWhileAChatStreamIsInFlight() async throws {
        let llm = PacedChat()
        let deps = makeDeps(llm: llm)
        let chat = Task {
            var deltas = 0
            for try await event in await deps.engine.chatStream(
                backend: .qwen3_1_7b, request: ChatRequest(messages: [.init(role: .user, content: "hi")]))
            { if case .delta = event { deltas += 1 } }
            return deltas
        }
        try await Task.sleep(for: .milliseconds(300))            // the chat is parked between deltas
        let opener = Task { try await Task.sleep(for: .milliseconds(1_500)); llm.open.yield() }
        try await Application(router: APIRouter.build(deps)).test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: self.speech(#","stream":true"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(Data(buffer: response.body).dropFirst(44), self.expectedPCM)
            }
        }
        llm.open.yield()
        opener.cancel()
        let deltas = try await chat.value
        XCTAssertEqual(deltas, 2)
    }
}

private extension Int {
    var leBytes: Data { withUnsafeBytes(of: UInt32(self).littleEndian) { Data($0) } }
}
