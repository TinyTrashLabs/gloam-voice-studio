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
}
