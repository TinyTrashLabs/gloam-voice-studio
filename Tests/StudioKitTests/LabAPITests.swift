import EngineKit
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// Exercises the Lab MCP tools and the mirrored `/v1/lab/*` HTTP routes against
/// an injected `LabStore` rooted at a temp dir, so tests never touch the real
/// app-support store. DialogueAPITests-style HummingbirdTesting.
final class LabAPITests: XCTestCase, @unchecked Sendable {
    private final class ToneModel: SpeechModel, @unchecked Sendable {
        let sampleRate = 24_000
        func synthesize(_ request: ProviderRequest) async throws -> [Float] { [] }
    }
    private final class ToneProvider: ModelProviding, @unchecked Sendable {
        func loadModel(backend: BackendID) async throws -> any SpeechModel { ToneModel() }
        func didEvictModel() {}
    }

    private var dir: URL!
    private var labDir: URL!
    private var lab: LabStore!
    private var deps: APIDependencies!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-api-\(UUID().uuidString)")
        labDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-store-\(UUID().uuidString)")
        lab = await MainActor.run { LabStore(directory: labDir) }
        deps = APIDependencies(
            engine: GloamEngine(provider: ToneProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            lab: lab)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: labDir)
    }

    private func withApp(
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        try await Application(router: APIRouter.build(deps)).test(.router, body)
    }

    /// A 1s silent WAV at 24 kHz, as the task prescribes.
    private func sampleWAV() -> Data {
        WAVEncoder.encode(pcm16: PCM16.data(from: [Float](repeating: 0, count: 24_000)),
                          sampleRate: 24_000)
    }

    private func rpc(_ client: some TestClientProtocol, _ body: String) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        try await client.execute(uri: "/mcp", method: .post,
                                 body: ByteBuffer(string: body)) { resp in
            XCTAssertEqual(resp.status, .ok)
            result = try JSONSerialization.jsonObject(with: Data(buffer: resp.body)) as? [String: Any] ?? [:]
        }
        return result
    }

    /// The text of a tool result's first content block, parsed as JSON.
    private func resultJSON(_ reply: [String: Any]) throws -> [String: Any] {
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    // MARK: MCP

    /// The primary loop: create a group, push a clip, see it in the list, pin a
    /// mark directly on the store, and read that mark back via lab_read_feedback.
    func testMCPGroupClipListAndFeedbackRoundTrip() async throws {
        let wavB64 = sampleWAV().base64EncodedString()
        try await withApp { client in
            // set_group
            let setReply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call",
             "params":{"name":"lab_set_group","arguments":{"heading":"Baked vs original ref","listen_for":"Benson's identity"}}}
            """#)
            let groupID = try XCTUnwrap(try self.resultJSON(setReply)["id"] as? String)

            // put_clip (base64)
            let putReply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call",
             "params":{"name":"lab_put_clip","arguments":{"group_id":"\#(groupID)","label":"A · original","audio_b64":"\#(wavB64)"}}}
            """#)
            let putJSON = try self.resultJSON(putReply)
            let clipID = try XCTUnwrap(putJSON["clip_id"] as? String)
            XCTAssertEqual((putJSON["duration"] as? NSNumber)?.doubleValue ?? 0, 1.0, accuracy: 0.05)

            // lab_list shows the clip
            let listReply = try await self.rpc(client,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lab_list","arguments":{}}}"#)
            let groups = try XCTUnwrap(try self.resultJSON(listReply)["groups"] as? [[String: Any]])
            let clips = try XCTUnwrap(groups.first?["clips"] as? [[String: Any]])
            XCTAssertEqual(clips.first?["id"] as? String, clipID)
            XCTAssertEqual(clips.first?["label"] as? String, "A · original")
            XCTAssertEqual(clips.first?["source"] as? String, "mcp")

            // A mark pinned in the tab (i.e. directly on the shared store) …
            await MainActor.run { _ = self.lab.addMark(clipID: clipID, t: 0.5, note: "goes thin here") }

            // … is visible to the next read.
            let fbReply = try await self.rpc(client,
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lab_read_feedback","arguments":{}}}"#)
            let fbResult = try XCTUnwrap(fbReply["result"] as? [String: Any])
            let fbText = try XCTUnwrap((fbResult["content"] as? [[String: Any]])?.first?["text"] as? String)
            XCTAssertTrue(fbText.contains("goes thin here"), fbText)
        }
    }

    /// put_clip to a group that doesn't exist is a tool error, not a crash.
    func testMCPPutClipUnknownGroupIsToolError() async throws {
        let wavB64 = sampleWAV().base64EncodedString()
        try await withApp { client in
            let reply = try await self.rpc(client, #"""
            {"jsonrpc":"2.0","id":9,"method":"tools/call",
             "params":{"name":"lab_put_clip","arguments":{"group_id":"nope","label":"A","audio_b64":"\#(wavB64)"}}}
            """#)
            XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    // MARK: HTTP

    /// A group and a clip go in over HTTP; the mirrored list route reads them back.
    func testHTTPCreateGroupPutClipAndList() async throws {
        try await withApp { client in
            // Create the group.
            var groupID = ""
            try await client.execute(uri: "/v1/lab/groups", method: .post,
                body: ByteBuffer(string: #"{"heading":"Split vs single pass"}"#)) { resp in
                XCTAssertEqual(resp.status, .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: resp.body)) as? [String: Any]
                groupID = try XCTUnwrap(json?["id"] as? String)
            }

            // Put a clip by base64.
            let wavB64 = self.sampleWAV().base64EncodedString()
            try await client.execute(uri: "/v1/lab/clips", method: .post,
                body: ByteBuffer(string: #"{"group_id":"\#(groupID)","label":"B · single","audio_b64":"\#(wavB64)"}"#)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }

            // List route shows it.
            try await client.execute(uri: "/v1/lab/list", method: .get) { resp in
                XCTAssertEqual(resp.status, .ok)
                let text = String(buffer: resp.body)
                XCTAssertTrue(text.contains("B · single"), text)
            }
        }
    }

    /// put_clip to an unknown group over HTTP is a 4xx, not a 200 or a crash.
    func testHTTPPutClipUnknownGroupIsFourXX() async throws {
        try await withApp { client in
            let wavB64 = self.sampleWAV().base64EncodedString()
            try await client.execute(uri: "/v1/lab/clips", method: .post,
                body: ByteBuffer(string: #"{"group_id":"nope","label":"A","audio_b64":"\#(wavB64)"}"#)) { resp in
                XCTAssertGreaterThanOrEqual(resp.status.code, 400)
                XCTAssertLessThan(resp.status.code, 500)
            }
        }
    }
}
