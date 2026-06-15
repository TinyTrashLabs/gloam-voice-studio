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
    func loadModel(backend: BackendID) async throws -> any SpeechModel { model }
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
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(makeDeps(provider)))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","instruct":"warm radio","language":"english","top_p":0.9}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
            XCTAssertEqual(provider.model.last?.instruct, "warm radio")
            XCTAssertEqual(provider.model.last?.language, "english")
            XCTAssertEqual(provider.model.last?.topP, 0.9)
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
