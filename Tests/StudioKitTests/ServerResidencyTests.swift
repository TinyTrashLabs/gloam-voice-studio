import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// Thread-safe call flag shared with the deps' prepareTTS closure.
private actor CallFlag {
    private(set) var calls = 0
    func mark() { calls += 1 }
}

/// The server routes render on the app's main engine; the app enforces a
/// single resident TTS model across engines via a prepare hook the routes
/// must run before synthesizing. These tests pin that hook to both
/// synthesis surfaces (OpenAI-compatible speak + MCP speak).
final class ServerResidencyTests: XCTestCase, @unchecked Sendable {
    private func makeApp(flag: CallFlag) -> some ApplicationProtocol {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("residency-\(UUID().uuidString)")
        let deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            prepareTTS: { await flag.mark() })
        return Application(router: APIRouter.build(deps))
    }

    func testSpeakRouteRunsPrepareTTSBeforeSynthesis() async throws {
        let flag = CallFlag()
        let app = makeApp(flag: flag)
        try await app.test(.router) { client in
            let create = #"{"name":"Cruz","refAudio":"AAEC","refText":"hi"}"#
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { _ in }
            let speech = #"{"input":"hello","model":"chatterbox-turbo","voice":"cruz"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: speech)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let calls = await flag.calls
        XCTAssertEqual(calls, 1, "speak route must run the residency hook")
    }

    func testMCPSpeakRunsPrepareTTSBeforeSynthesis() async throws {
        let flag = CallFlag()
        let app = makeApp(flag: flag)
        try await app.test(.router) { client in
            let create = #"{"name":"Cruz","refAudio":"AAEC","refText":"hi"}"#
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { _ in }
            let rpc = #"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hello","voice":"cruz"}}}
            """#
            try await client.execute(uri: "/mcp", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: ByteBuffer(string: rpc)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let calls = await flag.calls
        XCTAssertEqual(calls, 1, "MCP speak must run the residency hook")
    }
}
