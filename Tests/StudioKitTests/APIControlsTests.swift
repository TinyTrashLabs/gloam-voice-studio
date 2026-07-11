import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// Captures the ProviderRequest the engine ultimately receives.
final class CapturingModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24000
    var last: ProviderRequest?
    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        last = request
        return [0.0, 0.1]
    }
}
final class CapturingProvider: ModelProviding, @unchecked Sendable {
    let model = CapturingModel()
    var lastBackend: BackendID?
    func loadModel(backend: BackendID) async throws -> any SpeechModel {
        lastBackend = backend
        return model
    }
    func didEvictModel() {}
}

final class APIControlsTests: XCTestCase, @unchecked Sendable {
    func makeDeps(_ provider: CapturingProvider, default def: BackendID = .qwen17B) -> APIDependencies {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apictl-\(UUID().uuidString)")
        return APIDependencies(engine: GloamEngine(provider: provider),
                               voices: VoiceLibrary(directory: dir),
                               defaultBackend: def, log: APILog())
    }

    func testInstructAndLanguageReachEngine() async throws {
        // Direction (instruct) is honored on the design model, not Base (clone-only).
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(makeDeps(provider, default: .qwenDesign)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-design","instruct":"warm radio","language":"english","top_p":0.9}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
            XCTAssertEqual(provider.model.last?.instruct, "warm radio")
            XCTAssertEqual(provider.model.last?.language, "english")
            XCTAssertEqual(provider.model.last?.topP, 0.9)
        }
    }

    func testBaseDoesNotForwardInstruct() async throws {
        // Base is clone-only: instruct in the request must not reach the engine.
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(makeDeps(provider, default: .qwen17B)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","instruct":"warm radio","language":"english"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
            XCTAssertNil(provider.model.last?.instruct)
            XCTAssertEqual(provider.model.last?.language, "english")
        }
    }

    func testDesignWithoutInstructIs400() async throws {
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(makeDeps(provider, default: .qwenDesign)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-design"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String, "qwen3-design requires 'instruct'")
            }
        }
    }

    func testCustomWithoutSpeakerIs400() async throws {
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(makeDeps(provider, default: .qwenCustom)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-custom","instruct":"calm"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String,
                               "qwen3-custom requires a preset 'speaker'")
            }
        }
    }

    func testSpeechLogsExactlyOneEntryPerRequest() async throws {
        let provider = CapturingProvider()
        let log = APILog()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log1-\(UUID())")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B, log: log)
        let app = Application(router: APIRouter.build(deps))

        @Sendable func entryCount() async -> Int { await MainActor.run { log.entries.count } }
        @Sendable func waitForEntries(_ n: Int) async throws {
            for _ in 0..<50 { if await entryCount() >= n { return }; try await Task.sleep(for: .milliseconds(10)) }
        }

        try await app.test(.router) { client in
            // success → 1 entry
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                body: ByteBuffer(string: #"{"input":"hi","model":"qwen3-1.7b","instruct":"warm"}"#)) { r in
                XCTAssertEqual(r.status, .ok)
            }
            try await waitForEntries(1)
            // a 400 (design model needs instruct) → 1 more entry
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                body: ByteBuffer(string: #"{"input":"hi","model":"qwen3-design"}"#)) { r in
                XCTAssertEqual(r.status, .badRequest)
            }
            try await waitForEntries(2)
        }
        // Give any stray async hops a beat; then assert EXACTLY 2 (no duplicates).
        try await Task.sleep(for: .milliseconds(50))
        let count = await entryCount()
        let describe = await MainActor.run { log.entries.map { "\($0.path) \($0.status)" } }
        XCTAssertEqual(count, 2, "expected exactly one entry per request, got \(count): \(describe)")
        // The success entry is status 200, the error entry 400 — verify no duplicate statuses sneaked in.
        let statuses = await MainActor.run { log.entries.map(\.status).sorted() }
        XCTAssertEqual(statuses, [200, 400])
    }

    // MARK: - Default voice (Settings → API server → "Default voice")

    func testDefaultVoiceUsedWhenRequestOmitsVoice() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defvoice-omit-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "cruz ref")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B,
                                   defaultVoice: { "cruz" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            // No "voice" field at all — the default should fill in.
            let body = #"{"input":"hello","model":"qwen3-1.7b"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.model.last?.refText, "cruz ref")
        XCTAssertTrue(provider.model.last?.refAudioPath?.hasSuffix("cruz/ref.wav") == true,
                       "expected cruz's ref.wav, got \(String(describing: provider.model.last?.refAudioPath))")
    }

    func testExplicitVoiceOverridesDefault() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defvoice-override-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "cruz ref")
        _ = try voices.save(name: "Ava", refWav: Data([3, 4, 5]), refText: "ava ref")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B,
                                   defaultVoice: { "cruz" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","voice":"ava"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.model.last?.refText, "ava ref")
    }

    func testEmptyDefaultPreservesRawBackendBehavior() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defvoice-empty-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        // No defaultVoice closure passed — falls back to the "" default.
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertNil(provider.model.last?.refAudioPath)
        XCTAssertNil(provider.model.last?.refText)
    }

    func testDefaultVoiceWithEmotionRoutesToVariant() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defvoice-variant-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Ava", refWav: Data([0, 1, 2]), refText: "ava base")
        _ = try voices.saveAt(slug: "ava-excited", name: "Ava (Excited)",
                              refWav: Data([9, 9, 9]), refText: "ava excited")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B,
                                   defaultVoice: { "ava" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","emotion":"excited"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.model.last?.refText, "ava excited")
    }

    // MARK: - Default model (Settings → API server → "Default model")

    func testDefaultModelUsedWhenRequestOmitsModel() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defmodel-omit-\(UUID())")
        // qwen06B, not fish: fish backends sit behind the license-ack gate
        // (403), which is not what this test is about.
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B,
                                   defaultModel: { "qwen3-0.6b" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.lastBackend, .qwen06B)
    }

    func testExplicitModelOverridesDefaultModel() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defmodel-override-\(UUID())")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B,
                                   defaultModel: { "fish-s2-pro" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.lastBackend, .qwen17B)
    }

    func testEmptyDefaultModelFollowsStudioEngine() async throws {
        let provider = CapturingProvider()
        // No defaultModel closure passed — falls back to defaultBackend.
        let app = Application(router: APIRouter.build(makeDeps(provider, default: .qwen17B)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.lastBackend, .qwen17B)
    }

    func testUnknownDefaultModelFollowsStudioEngine() async throws {
        // A stale persisted raw value (e.g. a removed backend) must not 500 —
        // it falls through to the Studio engine.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defmodel-stale-\(UUID())")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B,
                                   defaultModel: { "retired-backend" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.lastBackend, .qwen17B)
    }

    func testDefaultModelValidatesItsOwnControls() async throws {
        // The resolved default's controls apply: qwen3-design requires
        // `instruct`, so an instruct-less request 400s even though the
        // request itself never named a model.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defmodel-controls-\(UUID())")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B,
                                   defaultModel: { "qwen3-design" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String, "qwen3-design requires 'instruct'")
            }
        }
    }

    func testBusyReturns503() async throws {
        final class SlowModel: SpeechModel, @unchecked Sendable {
            let sampleRate = 24000
            func synthesize(_ request: ProviderRequest) async throws -> [Float] {
                try await Task.sleep(for: .milliseconds(400)); return [0.0]
            }
        }
        final class SlowProvider: ModelProviding, @unchecked Sendable {
            func loadModel(backend: BackendID) async throws -> any SpeechModel { SlowModel() }
            func didEvictModel() {}
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("busy-\(UUID())")
        let deps = APIDependencies(
            engine: GloamEngine(provider: SlowProvider()),
            voices: VoiceLibrary(directory: dir), defaultBackend: .qwen17B,
            gate: RequestGate(maxConcurrent: 1, maxQueued: 1))
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.live) { client in
            // The server processes one request at a time per connection, so each
            // concurrent request needs its own TCP connection for the gate to see
            // them overlap. `client.port` is the live server's bound port.
            let port = try XCTUnwrap(client.port)
            let body = #"{"input":"hello","model":"qwen3-1.7b","instruct":"warm"}"#
            func fire() -> Task<Int, Error> {
                Task {
                    try await TestClient.withClient(host: "localhost", port: port) { c in
                        let req = TestClient.Request("/v1/audio/speech", method: .post,
                                                     authority: "localhost",
                                                     body: ByteBuffer(string: body))
                        let r = try await c.execute(req)
                        return Int(r.status.code)
                    }
                }
            }
            let a = fire(); try await Task.sleep(for: .milliseconds(30))
            let b = fire(); try await Task.sleep(for: .milliseconds(30))
            let c = fire()
            let codes = [try await a.value, try await b.value, try await c.value]
            XCTAssertTrue(codes.contains(503), "expected at least one 503, got \(codes)")
        }
    }
}
