import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

final class MCPRouteTests: XCTestCase, @unchecked Sendable {
    private final class ToneModel: SpeechModel, @unchecked Sendable {
        let sampleRate = 24_000
        func synthesize(_ request: ProviderRequest) async throws -> [Float] {
            [Float](repeating: 0.5, count: 2_400)   // 0.1s
        }
    }
    private final class ToneProvider: ModelProviding, @unchecked Sendable {
        func loadModel(backend: BackendID) async throws -> any SpeechModel { ToneModel() }
        func didEvictModel() {}
    }

    private func makeApp() -> some ApplicationProtocol {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tests-\(UUID().uuidString)")
        let deps = APIDependencies(engine: GloamEngine(provider: ToneProvider()),
                                   voices: VoiceLibrary(directory: dir),
                                   defaultBackend: .qwen17B)
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

    func testInitializeAndToolsList() async throws {
        try await makeApp().test(.router) { client in
            let initReply = try await self.rpc(client,
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            let initResult = initReply["result"] as? [String: Any]
            XCTAssertEqual((initResult?["serverInfo"] as? [String: Any])?["name"] as? String,
                           "gloam-voice-studio")
            XCTAssertNotNil(initResult?["protocolVersion"])

            let listReply = try await self.rpc(client,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            let tools = (listReply["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            XCTAssertEqual(tools?.compactMap { $0["name"] as? String }.sorted(),
                           ["list_voices", "listen", "speak", "transcribe"])
        }
    }

    func testSpeakReturnsAudioContent() async throws {
        try await makeApp().test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hello world"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
            let content = result?["content"] as? [[String: Any]] ?? []
            XCTAssertTrue(content.contains { $0["type"] as? String == "audio" },
                          "speak should inline WAV audio content")
        }
    }

    func testUnknownVoiceIsToolError() async throws {
        try await makeApp().test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi","voice":"nope"}}}
            """#)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testNotificationAccepted() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/mcp", method: .post,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            ) { resp in
                XCTAssertEqual(resp.status, .accepted)
            }
        }
    }
}
