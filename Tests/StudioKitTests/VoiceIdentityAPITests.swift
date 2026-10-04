import CoreGraphics
import EngineKit
import Foundation
import Hummingbird
import HummingbirdTesting
import ImageIO
import XCTest
@testable import StudioKit

/// The voice-identity HTTP routes and MCP tools: persona/notes patches, avatar, language takes,
/// language-aware speech, design-and-save, and pack identity over the wire.
final class VoiceIdentityAPITests: XCTestCase, @unchecked Sendable {
    private var dir: URL!
    private var provider: CapturingProvider!
    private var voices: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("idapi-\(UUID().uuidString)")
        voices = VoiceLibrary(directory: dir)
        provider = CapturingProvider()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func app(backend: BackendID = .qwen17B) -> some ApplicationProtocol {
        Application(router: APIRouter.build(APIDependencies(
            engine: GloamEngine(provider: provider), voices: voices, defaultBackend: backend,
            log: APILog(), defaultVoice: { "" })))
    }

    private func json(_ body: ByteBuffer) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(buffer: body)) as! [String: Any]
    }

    private func send(_ client: some TestClientProtocol, _ uri: String, _ method: HTTPRequest.Method,
                      _ body: Any? = nil) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
        var out: (HTTPResponse.Status, [String: Any]) = (.ok, [:])
        let buffer = try body.map { ByteBuffer(data: try JSONSerialization.data(withJSONObject: $0)) }
        try await client.execute(uri: uri, method: method, body: buffer) { resp in
            out = (resp.status, (try? self.json(resp.body)) ?? [:])
        }
        return out
    }

    private func makePNG(width: Int = 40, height: Int = 60) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.9, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private let b64 = Data([0, 1, 2]).base64EncodedString()

    // MARK: PATCH persona / notes

    func testPatchSetsAndClearsPersonaAndSetsNotes() async throws {
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "hi")
        try await app().test(.router) { client in
            var r = try await self.send(client, "/voices/cruz", .patch,
                ["persona": ["systemPrompt": "You are Cruz.", "tagline": "MC"], "notes": "hyped"])
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual((r.body["persona"] as? [String: Any])?["systemPrompt"] as? String, "You are Cruz.")
            XCTAssertEqual(r.body["notes"] as? String, "hyped")
            XCTAssertEqual(r.body["revision"] as? Int, 3, "persona and notes are each an edit")
            // Absent leaves the persona alone.
            r = try await self.send(client, "/voices/cruz", .patch, ["refText": "hello"])
            XCTAssertNotNil(r.body["persona"])
            // null clears it.
            r = try await self.send(client, "/voices/cruz", .patch, ["persona": NSNull()])
            XCTAssertEqual(r.status, .ok)
            XCTAssertNil(r.body["persona"])
            XCTAssertEqual(r.body["notes"] as? String, "hyped")
            // Empty notes clear.
            r = try await self.send(client, "/voices/cruz", .patch, ["notes": ""])
            XCTAssertNil(r.body["notes"])
        }
    }

    // MARK: avatar

    func testAvatarPutGetDelete() async throws {
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "hi")
        let png = try makePNG()
        try await app().test(.router) { client in
            try await client.execute(uri: "/voices/cruz/avatar", method: .get) { resp in
                XCTAssertEqual(resp.status, .notFound)
            }
            try await client.execute(uri: "/voices/cruz/avatar", method: .put,
                                     body: ByteBuffer(data: png)) { resp in
                XCTAssertEqual(resp.status, .ok)
                XCTAssertEqual(try self.json(resp.body)["revision"] as? Int, 2)
            }
            try await client.execute(uri: "/voices/cruz/avatar", method: .get) { resp in
                XCTAssertEqual(resp.status, .ok)
                XCTAssertEqual(resp.headers[.contentType], "image/png")
                let got = Data(buffer: resp.body)
                XCTAssertEqual(AvatarImageSize.of(got), AvatarImageSize(side: 256))
            }
            let list = try await self.send(client, "/voices", .get)
            XCTAssertEqual((list.body["voices"] as? [[String: Any]])?.first?["hasAvatar"] as? Bool, true)
            try await client.execute(uri: "/voices/cruz/avatar", method: .put,
                                     body: ByteBuffer(string: "not an image")) { resp in
                XCTAssertEqual(resp.status, .badRequest)
            }
            try await client.execute(uri: "/voices/nope/avatar", method: .put,
                                     body: ByteBuffer(data: png)) { resp in
                XCTAssertEqual(resp.status, .notFound)
            }
            let deleted = try await self.send(client, "/voices/cruz/avatar", .delete)
            XCTAssertEqual(deleted.body["ok"] as? Bool, true)
            try await client.execute(uri: "/voices/cruz/avatar", method: .get) { resp in
                XCTAssertEqual(resp.status, .notFound)
            }
        }
    }

    // MARK: language takes + speech

    func testLanguageTakeIsListedAndSpeechUsesItsReference() async throws {
        _ = try voices.save(name: "Benson", refWav: Data([0, 1, 2]), refText: "hello there")
        try voices.setLanguage("benson", "en")
        try await app().test(.router) { client in
            var r = try await self.send(client, "/voices/benson/variants", .post,
                ["language": "es", "refAudio": Data([9, 9, 9]).base64EncodedString(), "refText": "hola amigo"])
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.body["slug"] as? String, "benson-es")
            XCTAssertEqual(r.body["language"] as? String, "es")

            let list = try await self.send(client, "/voices", .get)
            let row = try XCTUnwrap((list.body["voices"] as? [[String: Any]])?.first)
            XCTAssertEqual(row["variants"] as? [String], ["es"])
            XCTAssertEqual(row["languages"] as? [String], ["en", "es"])
            XCTAssertNotNil(row["id"])
            XCTAssertEqual(row["revision"] as? Int, 2)

            // Spanish speech renders from the es take, with the language passed through.
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: ByteBuffer(string:
                #"{"input":"hola","voice":"benson","language":"es-MX","model":"qwen3-1.7b"}"#)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
            XCTAssertEqual(self.provider.model.last?.refText, "hola amigo")
            XCTAssertTrue(self.provider.model.last?.refAudioPath?.contains("variants/es") == true)
            XCTAssertEqual(self.provider.model.last?.language, "es-MX")
            // English (the voice's own language) keeps the voice.
            try await client.execute(uri: "/v1/audio/speech", method: .post, body: ByteBuffer(string:
                #"{"input":"hi","voice":"benson","language":"en","model":"qwen3-1.7b"}"#)) { _ in }
            XCTAssertEqual(self.provider.model.last?.refText, "hello there")

            // Validation.
            r = try await self.send(client, "/voices/benson/variants", .post,
                ["language": "not a tag!", "refAudio": self.b64, "refText": "x"])
            XCTAssertEqual(r.status, .badRequest)
            r = try await self.send(client, "/voices/benson/variants", .post,
                ["language": "fr", "refAudio": self.b64, "refText": " "])
            XCTAssertEqual(r.status, .badRequest)
            r = try await self.send(client, "/voices/nope/variants", .post,
                ["language": "fr", "refAudio": self.b64, "refText": "salut"])
            XCTAssertEqual(r.status, .notFound)
        }
    }

    func testANEBackendAdvertisesLanguage() {
        XCTAssertTrue(BackendID.qwen06BANE.controls.language)
    }

    // MARK: design

    func testDesignRendersOnQwenDesignAndSavesTheVoice() async throws {
        try await app().test(.router) { client in
            let r = try await self.send(client, "/voices/design", .post, [
                "name": "Night Owl", "instruct": "warm, slow, gravelly", "script": "Evening, folks.",
                "language": "english", "persona": ["systemPrompt": "You are the Night Owl."],
            ])
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.body["slug"] as? String, "night-owl")
            XCTAssertEqual(r.body["refText"] as? String, "Evening, folks.")
            XCTAssertEqual((r.body["persona"] as? [String: Any])?["systemPrompt"] as? String,
                           "You are the Night Owl.")
            XCTAssertNotNil(r.body["id"])
            XCTAssertEqual(self.provider.lastBackend, .qwenDesign)
            XCTAssertEqual(self.provider.model.last?.instruct, "warm, slow, gravelly")
            XCTAssertEqual(self.provider.model.last?.language, "english")
            let saved = try self.voices.get("night-owl")
            XCTAssertGreaterThan(try Data(contentsOf: saved.refURL).count, 44)
            XCTAssertTrue(self.voices.capabilities("night-owl").engines.contains("qwen3-design"))

            // Taken name: 409 before any render.
            self.provider.model.last = nil
            let again = try await self.send(client, "/voices/design", .post,
                ["name": "Night Owl", "instruct": "x", "script": "y"])
            XCTAssertEqual(again.status, .conflict)
            XCTAssertNil(self.provider.model.last)
            let bad = try await self.send(client, "/voices/design", .post,
                ["name": "A", "instruct": " ", "script": "y"])
            XCTAssertEqual(bad.status, .badRequest)
        }
    }

    // MARK: export / import identity

    func testExportImportKeepsIdAndRevisionOverHTTP() async throws {
        let made = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "hi")
        try voices.setPersona("cruz", persona: Persona(systemPrompt: "Cruz"))
        try await app().test(.router) { client in
            var pack = Data()
            try await client.execute(uri: "/voices/cruz/export", method: .get) { resp in
                pack = Data(buffer: resp.body)
            }
            _ = try await self.send(client, "/voices/cruz", .delete)
            let r = try await self.send(client, "/voices/import", .post, ["data": pack.base64EncodedString()])
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.body["id"] as? String, made.id)
            XCTAssertEqual(r.body["revision"] as? Int, 2)
        }
    }

    /// A real pack is a few MB (3.5 MB measured), so its base64 JSON is past the framework's 2 MB
    /// `request.decode` default: import, create and patch must take it, not answer 413.
    func testLibraryRoutesAcceptBodiesPastTheDefaultLimit() async throws {
        var rng = SystemRandomNumberGenerator()
        let big = Data((0..<(5 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        _ = try voices.save(name: "Big", refWav: big, refText: "hi")
        let pack = try GVoice.export("big", from: voices)
        XCTAssertGreaterThan(pack.count, 4 * 1024 * 1024)
        try await app().test(.router) { client in
            _ = try await self.send(client, "/voices/big", .delete)
            var r = try await self.send(client, "/voices/import", .post, ["data": pack.base64EncodedString()])
            XCTAssertEqual(r.status, .ok, "\(r.body)")
            XCTAssertEqual(r.body["slug"] as? String, "big")
            r = try await self.send(client, "/voices", .post,
                ["name": "Big Two", "refAudio": big.base64EncodedString(), "refText": "hi"])
            XCTAssertEqual(r.status, .ok, "\(r.body)")
            r = try await self.send(client, "/voices/big", .patch,
                ["refAudio": big.base64EncodedString()])
            XCTAssertEqual(r.status, .ok, "\(r.body)")
            // Not JSON at all is still a clean 400.
            try await client.execute(uri: "/voices/import", method: .post,
                                     body: ByteBuffer(string: "nope")) { resp in
                XCTAssertEqual(resp.status, .badRequest)
            }
            // MCP: the same size of base64 audio goes through transcribe's `audio`.
            let rpc = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "list_voices", "arguments": ["pad": big.base64EncodedString()]],
            ] as [String: Any])
            try await client.execute(uri: "/mcp", method: .post, body: ByteBuffer(data: rpc)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
    }

    // MARK: MCP

    private func call(_ client: some TestClientProtocol, _ tool: String,
                      _ arguments: [String: Any]) async throws -> (isError: Bool, text: String) {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ] as [String: Any])
        var out = (true, "")
        try await client.execute(uri: "/mcp", method: .post, body: ByteBuffer(data: body)) { resp in
            let result = try self.json(resp.body)["result"] as? [String: Any]
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            out = (result?["isError"] as? Bool ?? true, text)
        }
        return out
    }

    private func object(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testMCPVoiceLifecycle() async throws {
        let wavURL = dir.appendingPathComponent("ref.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: wavURL)
        let esURL = dir.appendingPathComponent("es.wav")
        try Data([7, 7, 7]).write(to: esURL)
        let pngURL = dir.appendingPathComponent("face.png")
        try makePNG().write(to: pngURL)
        let packURL = dir.appendingPathComponent("out")

        try await app().test(.router) { client in
            var r = try await self.call(client, "create_voice",
                ["name": "Cruz", "path": wavURL.path, "transcript": "hello"])
            XCTAssertFalse(r.isError, r.text)
            let created = try self.object(r.text)
            XCTAssertEqual(created["slug"] as? String, "cruz")
            XCTAssertNotNil(created["id"])

            r = try await self.call(client, "update_voice", ["voice": "cruz", "notes": "hyped MC",
                "persona": ["systemPrompt": "You are Cruz.", "color": "#FF8800"]])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(try self.object(r.text)["notes"] as? String, "hyped MC")

            r = try await self.call(client, "set_avatar", ["voice": "cruz", "path": pngURL.path])
            XCTAssertFalse(r.isError, r.text)
            r = try await self.call(client, "add_language_take",
                ["voice": "cruz", "language": "es", "path": esURL.path, "transcript": "hola"])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(try self.object(r.text)["language"] as? String, "es")

            r = try await self.call(client, "list_voices", [:])
            let rows = try JSONSerialization.jsonObject(with: Data(r.text.utf8)) as! [[String: Any]]
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual((row["persona"] as? [String: Any])?["color"] as? String, "#FF8800")
            XCTAssertEqual(row["hasNotes"] as? Bool, true)
            XCTAssertEqual(row["languages"] as? [String], ["es"])
            XCTAssertEqual(row["id"] as? String, created["id"] as? String)
            XCTAssertEqual(row["revision"] as? Int, 5)
            XCTAssertEqual(row["hasAvatar"] as? Bool, true)

            r = try await self.call(client, "update_voice", ["voice": "cruz", "persona": NSNull()])
            XCTAssertNil(try self.object(r.text)["persona"])

            r = try await self.call(client, "export_voice", ["voice": "cruz", "path": packURL.path])
            XCTAssertFalse(r.isError, r.text)
            let packFile = packURL.appendingPathExtension("gvoice")
            XCTAssertTrue(FileManager.default.fileExists(atPath: packFile.path))

            r = try await self.call(client, "delete_voice", ["voice": "cruz"])
            XCTAssertFalse(r.isError, r.text)
            r = try await self.call(client, "import_voice", ["path": packFile.path])
            XCTAssertFalse(r.isError, r.text)
            let imported = try self.object(r.text)
            XCTAssertEqual(imported["id"] as? String, created["id"] as? String)
            XCTAssertEqual(imported["revision"] as? Int, 6)

            r = try await self.call(client, "delete_voice", ["voice": "ghost"])
            XCTAssertTrue(r.isError)
            XCTAssertEqual(r.text, "voice 'ghost' not found")
            r = try await self.call(client, "set_avatar", ["voice": "cruz", "path": wavURL.path])
            XCTAssertTrue(r.isError)
        }
    }

    func testMCPDesignVoiceAndSpeakLanguageAndInstruct() async throws {
        _ = try voices.save(name: "Benson", refWav: Data([0, 1, 2]), refText: "hello there")
        try voices.setLanguage("benson", "en")
        try voices.addLanguageTake("benson", language: "es", refWav: Data([5, 5]), refText: "hola")
        try await app().test(.router) { client in
            var r = try await self.call(client, "design_voice",
                ["name": "Owl", "instruct": "soft", "script": "Hush now."])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(try self.object(r.text)["slug"] as? String, "owl")
            XCTAssertEqual(self.provider.lastBackend, .qwenDesign)

            r = try await self.call(client, "speak",
                ["text": "hola", "voice": "benson", "language": "es", "instruct": "calm"])
            XCTAssertFalse(r.isError, r.text)
            XCTAssertEqual(self.provider.model.last?.refText, "hola")
            XCTAssertEqual(self.provider.model.last?.language, "es")
        }
    }
}

/// Square-image check for the avatar test, without pulling GVoiceKit's helpers into the assertion.
private struct AvatarImageSize: Equatable {
    let side: Int
    static func of(_ data: Data) -> AvatarImageSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w == h else { return nil }
        return AvatarImageSize(side: w)
    }
}
