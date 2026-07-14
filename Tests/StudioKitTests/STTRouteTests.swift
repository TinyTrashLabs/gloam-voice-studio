import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// Tests for the speech-to-text surface (transcribe / listen) added to the
/// local API. The STT engines are injected as closures on APIDependencies, so
/// these tests drive the routing + JSON shaping with fake transcribers.
final class STTRouteTests: XCTestCase, @unchecked Sendable {
    private final class NoopModel: SpeechModel, @unchecked Sendable {
        let sampleRate = 24_000
        func synthesize(_ request: ProviderRequest) async throws -> [Float] { [0.0] }
    }
    private final class NoopProvider: ModelProviding, @unchecked Sendable {
        func loadModel(backend: BackendID) async throws -> any SpeechModel { NoopModel() }
        func didEvictModel() {}
    }

    private func makeApp(
        transcribe: @escaping @Sendable (Data, String?) async throws -> String
            = { _, _ in "" },
        listen: @escaping @Sendable (Double, Double, String?) async throws -> String
            = { _, _, _ in "" }
    ) -> some ApplicationProtocol {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-tests-\(UUID().uuidString)")
        let deps = APIDependencies(engine: GloamEngine(provider: NoopProvider()),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B,
                                   transcribe: transcribe, listen: listen)
        return Application(router: APIRouter.build(deps))
    }

    private func rpc(_ client: some TestClientProtocol,
                     _ body: String) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        try await client.execute(uri: "/mcp", method: .post,
                                 body: ByteBuffer(string: body)) { resp in
            XCTAssertEqual(resp.status, .ok)
            result = try JSONSerialization.jsonObject(
                with: Data(buffer: resp.body)) as? [String: Any] ?? [:]
        }
        return result
    }

    func testTranscribeToolReturnsText() async throws {
        let app = makeApp(transcribe: { _, _ in "the quick brown fox" })
        try await app.test(.router) { client in
            let audioB64 = Data("fakewav".utf8).base64EncodedString()
            let reply = try await self.rpc(client, """
            {"jsonrpc":"2.0","id":1,"method":"tools/call",
             "params":{"name":"transcribe","arguments":{"audio":"\(audioB64)"}}}
            """)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
            let content = result?["content"] as? [[String: Any]] ?? []
            let text = content.first { $0["type"] as? String == "text" }?["text"] as? String
            XCTAssertEqual(text, "the quick brown fox")
        }
    }

    func testTranscribeToolRejectsMissingAudio() async throws {
        let app = makeApp(transcribe: { _, _ in "should not run" })
        try await app.test(.router) { client in
            let reply = try await self.rpc(client, """
            {"jsonrpc":"2.0","id":1,"method":"tools/call",
             "params":{"name":"transcribe","arguments":{}}}
            """)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testListenToolReturnsTranscript() async throws {
        let app = makeApp(listen: { _, _, _ in "hello from the mic" })
        try await app.test(.router) { client in
            let reply = try await self.rpc(client, """
            {"jsonrpc":"2.0","id":2,"method":"tools/call",
             "params":{"name":"listen","arguments":{}}}
            """)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
            let content = result?["content"] as? [[String: Any]] ?? []
            let text = content.first { $0["type"] as? String == "text" }?["text"] as? String
            XCTAssertEqual(text, "hello from the mic")
        }
    }
}
