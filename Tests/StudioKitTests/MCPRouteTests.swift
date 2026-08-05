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

    /// A library holding one usable voice, "cruz", with a non-empty transcript.
    /// qwen17B (the default test backend) is a cloning model gated by PR #38 /
    /// the MCP fast-follow, so tests whose subject is NOT voice resolution need a
    /// real, speakable voice on hand rather than the old unconditioned free ride.
    private func seededLibrary(_ tag: String, refText: String = "cruz ref") throws -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: refText)
        return voices
    }

    private func makeApp(backend: BackendID = .qwen17B,
                         voices: VoiceLibrary? = nil,
                         defaultVoice: @escaping @Sendable () -> String = { "" }
    ) -> some ApplicationProtocol {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tests-\(UUID().uuidString)")
        let deps = APIDependencies(engine: GloamEngine(provider: ToneProvider()),
                                   voices: voices ?? VoiceLibrary(directory: dir),
                                   defaultBackend: backend,
                                   defaultVoice: defaultVoice)
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
        // qwen17B clones; an explicit resolvable voice is required now that the
        // tool is gated the same as /v1/audio/speech.
        let voices = try seededLibrary("speak-explicit")
        try await makeApp(voices: voices).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hello world","voice":"cruz"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
            let content = result?["content"] as? [[String: Any]] ?? []
            XCTAssertTrue(content.contains { $0["type"] as? String == "audio" },
                          "speak should inline WAV audio content")
        }
    }

    func testSpeakFallsBackToDefaultVoiceWhenOmitted() async throws {
        // Mirrors /v1/audio/speech: an omitted `voice` resolves through the
        // Settings → API server "Default voice" before the cloning-backend gate
        // fires — the tool doesn't have to name a voice on every call.
        let voices = try seededLibrary("speak-default")
        try await makeApp(voices: voices, defaultVoice: { "cruz" }).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hello world"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, false)
        }
    }

    func testUnknownVoiceIsToolError() async throws {
        try await makeApp(voices: try seededLibrary("unknown-voice")).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi","voice":"nope"}}}
            """#)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testOmittedVoiceOnCloningBackendWithNoDefaultIsToolError() async throws {
        // The original invented-speaker bug on the MCP surface: `voice` omitted
        // and no default voice configured used to leave refPath/refText both nil
        // with zero gating, so qwen Base generated UNCONDITIONED while reporting
        // success. It must now refuse explicitly, same as the HTTP endpoint.
        try await makeApp().test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, true)
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
            XCTAssertEqual(text, "qwen3-1.7b requires a 'voice' — call list_voices")
        }
    }

    func testEmptyRefTextOnQwenIsToolError() async throws {
        // A voice saved without a transcript is corrupt for qwen's in-context
        // clone path: nil refText drops it into the same unconditioned branch as
        // no voice at all (BackendID.needsRefText). Fail loudly instead.
        let voices = try seededLibrary("empty-reftext", refText: "")
        try await makeApp(voices: voices).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi","voice":"cruz"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, true)
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
            XCTAssertEqual(text, "voice 'cruz' has an empty reference transcript"
                + " — qwen3-1.7b cannot clone from it")
        }
    }

    func testEmptyRefTextIsFineOnAudioOnlyCloneBackends() async throws {
        // Chatterbox clones from the audio alone — it never reads refText — so a
        // transcript-less voice must keep working there, unchanged from before.
        let voices = try seededLibrary("empty-reftext-cb", refText: "")
        try await makeApp(backend: .chatterboxTurbo, voices: voices).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi","voice":"cruz"}}}
            """#)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, false)
        }
    }

    func testOmittedVoiceOnKokoroDoesNotHitTheCloningGate() async throws {
        // Kokoro has no clone path (`voiceClone == .none`) — an omitted `voice` is
        // not a library slug at all, so the new "requires a 'voice'" gate must not
        // fire there, unchanged per PR #38's decisions. (This tool has a separate,
        // pre-existing gap where it never forwards a preset `speaker`, so a Kokoro
        // call still fails downstream in RequestPlanner — that's unrelated to voice
        // resolution and out of scope here; this only asserts the gate is skipped.)
        try await makeApp(backend: .kokoro).test(.router) { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":8,"method":"tools/call",
             "params":{"name":"speak","arguments":{"text":"hi"}}}
            """#)
            let result = reply["result"] as? [String: Any]
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
            XCTAssertNotEqual(text, "kokoro requires a 'voice' — call list_voices")
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
