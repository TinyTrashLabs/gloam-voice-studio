import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

final class FakeModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24000
    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        [0.0, 0.25, -0.25, 0.5]
    }
}

final class FakeProvider: ModelProviding, @unchecked Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel { FakeModel() }
    func didEvictModel() {}
}

final class APIServerTests: XCTestCase, @unchecked Sendable {
    var dir: URL!
    var deps: APIDependencies!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("api-\(UUID().uuidString)")
        deps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func app() -> some ApplicationProtocol {
        Application(router: APIRouter.build(deps))
    }

    func json(_ body: ByteBuffer) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(buffer: body)) as! [String: Any]
    }

    func testHealthShape() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try self.json(response.body)
                XCTAssertEqual(body["ok"] as? Bool, true)
                XCTAssertEqual(body["engine"] as? String, "chatterbox-turbo")
                XCTAssertEqual(body["loaded"] as? Bool, false)
                XCTAssertEqual(body["honorsTags"] as? Bool, false)
                XCTAssertEqual((body["loadedBackends"] as? [String]) ?? ["x"], [])
                XCTAssertNotNil(body["memGb"] as? Double)
            }
        }
    }

    func testMiddlewareLogsHealthRequest() async throws {
        let log = await APILog(capacity: 50)
        let logDeps = APIDependencies(
            engine: GloamEngine(provider: FakeProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .chatterboxTurbo,
            log: log)
        let app = Application(router: APIRouter.build(logDeps))
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        // The middleware's `record` hops to @MainActor via Task; poll briefly.
        var entry: APILogEntry?
        for _ in 0..<50 {
            entry = await MainActor.run { log.entries.first(where: { $0.path == "/health" }) }
            if entry != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(entry?.path, "/health")
        XCTAssertEqual(entry?.method, "GET")
        XCTAssertEqual(entry?.status, 200)
    }

    func testVoiceCRUDAndErrorContract() async throws {
        try await app().test(.router) { client in
            // create
            let create = #"{"name":"Cruz","refAudio":"AAEC","refText":"hi"}"#
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try self.json(response.body)
                XCTAssertEqual(body["slug"] as? String, "cruz")
            }
            // duplicate → 409 {"detail": ...}
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { response in
                XCTAssertEqual(response.status, .conflict)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "voice 'cruz' already exists")
            }
            // bad base64 → 400
            try await client.execute(
                uri: "/voices", method: .post,
                body: ByteBuffer(string: #"{"name":"X","refAudio":"@@@"}"#)) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "refAudio is not valid base64")
            }
            // empty name → 400
            try await client.execute(
                uri: "/voices", method: .post,
                body: ByteBuffer(string: #"{"name":"  ","refAudio":"AAEC"}"#)) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "name is empty")
            }
            // list
            try await client.execute(uri: "/voices", method: .get) { response in
                let voices = try self.json(response.body)["voices"] as? [[String: Any]]
                XCTAssertEqual(voices?.count, 1)
            }
            // patch refText
            try await client.execute(uri: "/voices/cruz", method: .patch,
                                     body: ByteBuffer(string: #"{"refText":"new"}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.json(response.body)["refText"] as? String, "new")
            }
            // patch unknown → 404
            try await client.execute(uri: "/voices/nope", method: .patch,
                                     body: ByteBuffer(string: "{}")) { response in
                XCTAssertEqual(response.status, .notFound)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "voice 'nope' not found")
            }
            // ref.wav bytes
            try await client.execute(uri: "/voices/cruz/ref.wav", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(Data(buffer: response.body), Data([0, 1, 2]))
            }
            // delete
            try await client.execute(uri: "/voices/cruz", method: .delete) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.json(response.body)["ok"] as? Bool, true)
            }
            try await client.execute(uri: "/voices/cruz", method: .delete) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testSpeechSynthesizesWav() async throws {
        try await app().test(.router) { client in
            let create = #"{"name":"Cruz","refAudio":"AAEC","refText":"hi"}"#
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { _ in }
            let speech = #"{"input":"hello world","model":"chatterbox-turbo","voice":"cruz"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: speech)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                let wav = Data(buffer: response.body)
                XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
                XCTAssertEqual(wav.count, 44 + 4 * 2)  // FakeModel returns 4 samples
            }
        }
    }

    func testSpeechUnknownVoiceFallsThroughToRefAudioRequired() async throws {
        try await app().test(.router) { client in
            // chatterbox-turbo requires ref audio; unknown voice resolves none → 400
            let speech = #"{"input":"hello","voice":"alloy"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: speech)) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertNotNil(try self.json(response.body)["detail"])
            }
        }
    }

    func testSpeechFishWithoutAckIs403WithNotice() async throws {
        try await app().test(.router) { client in
            let speech = #"{"input":"hello","model":"fish-s2-pro"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: speech)) { response in
                XCTAssertEqual(response.status, .forbidden)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               fishLicenseNotice)
            }
        }
    }

    func testSpeechRejectsNonWavFormatAndEmptyInput() async throws {
        try await app().test(.router) { client in
            try await client.execute(
                uri: "/v1/audio/speech", method: .post,
                body: ByteBuffer(string: #"{"input":"x","response_format":"mp3"}"#)) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "only response_format=wav is supported")
            }
            try await client.execute(
                uri: "/v1/audio/speech", method: .post,
                body: ByteBuffer(string: #"{"input":"  "}"#)) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(try self.json(response.body)["detail"] as? String,
                               "input is empty")
            }
        }
    }

    func testCORSAllowlist() async throws {
        let acao = HTTPField.Name("access-control-allow-origin")!
        try await app().test(.router) { client in
            // Allowed origin → echoed back on the actual response.
            try await client.execute(uri: "/health", method: .get,
                                     headers: [.origin: "https://gloam.fm"]) { response in
                XCTAssertEqual(response.headers[acao], "https://gloam.fm")
            }
            // JSON POST preflight (OPTIONS) for an allowed origin gets the allow headers.
            try await client.execute(uri: "/v1/audio/speech", method: .options, headers: [
                .origin: "https://gloam-app.pages.dev",
                HTTPField.Name("access-control-request-method")!: "POST",
                HTTPField.Name("access-control-request-headers")!: "content-type",
            ]) { response in
                XCTAssertEqual(response.headers[acao], "https://gloam-app.pages.dev")
                XCTAssertNotNil(response.headers[HTTPField.Name("access-control-allow-methods")!])
            }
            // Disallowed origin → no allow-origin header (browser blocks it).
            try await client.execute(uri: "/health", method: .get,
                                     headers: [.origin: "https://evil.example"]) { response in
                XCTAssertNil(response.headers[acao])
            }
        }
    }

    func testLiveServerBindsLoopback() async throws {
        let server = LocalAPIServer(deps: deps)
        let port = 18799
        try await server.start(port: port)
        // poll /health until the listener is up (max ~3s)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var lastError: Error? = nil
        for _ in 0..<30 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                XCTAssertEqual(body["ok"] as? Bool, true)
                await server.stop()
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        await server.stop()
        XCTFail("server never came up: \(String(describing: lastError))")
    }

    func testExportImportOverHTTP() async throws {
        try await app().test(.router) { client in
            let create = #"{"name":"Cruz","refAudio":"AAEC","refText":"hi"}"#
            try await client.execute(uri: "/voices", method: .post,
                                     body: ByteBuffer(string: create)) { _ in }
            var pack = Data()
            try await client.execute(uri: "/voices/cruz/export", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "application/zip")
                XCTAssertEqual(response.headers[.contentDisposition],
                               "attachment; filename=\"cruz.gvoice\"")
                pack = Data(buffer: response.body)
            }
            // delete then re-import the pack
            try await client.execute(uri: "/voices/cruz", method: .delete) { _ in }
            let importBody = try JSONSerialization.data(
                withJSONObject: ["data": pack.base64EncodedString()])
            try await client.execute(uri: "/voices/import", method: .post,
                                     body: ByteBuffer(data: importBody)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.json(response.body)["slug"] as? String, "cruz")
            }
            // import garbage → 400 with archive prefix
            let bad = try JSONSerialization.data(
                withJSONObject: ["data": Data([1, 2, 3]).base64EncodedString()])
            try await client.execute(uri: "/voices/import", method: .post,
                                     body: ByteBuffer(data: bad)) { response in
                XCTAssertEqual(response.status, .badRequest)
                let detail = try self.json(response.body)["detail"] as? String ?? ""
                XCTAssertTrue(detail.hasPrefix("not a valid .gvoice archive"))
            }
        }
    }
}
