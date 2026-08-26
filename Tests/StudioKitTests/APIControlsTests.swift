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
    /// A library holding one usable voice, "cruz". Cloning backends refuse to
    /// synthesize without a resolved reference, so tests whose subject is NOT voice
    /// resolution (model precedence, instruct gating, the busy gate) need a real
    /// voice on hand rather than the old unconditioned free ride.
    func seededLibrary(_ tag: String) throws -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Cruz", refWav: Data([0, 1, 2]), refText: "cruz ref")
        return voices
    }

    func makeDeps(_ provider: CapturingProvider,
                  default def: BackendID = .qwen17B) throws -> APIDependencies {
        APIDependencies(engine: GloamEngine(provider: provider),
                        voices: try seededLibrary("apictl"),
                        defaultBackend: def, log: APILog(),
                        defaultVoice: { "cruz" })
    }

    func testSupertonicRenditionRendersBakedStyleNotPreset() async throws {
        // A voice whose pack carries engines/supertonic/style.json must speak
        // with that baked style — not silently fall back to preset M1.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendition-\(UUID().uuidString)")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Billie", refWav: nil, refText: "",
                            engines: ["supertonic": ["style.json": Data([1, 2])]])
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .supertonic)
        let deps = APIDependencies(engine: engine, voices: voices,
                                   defaultBackend: .supertonic, log: APILog(),
                                   defaultVoice: { "" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"supertonic","voice":"billie"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
            XCTAssertEqual(provider.model.last?.styleURL?.lastPathComponent, "style.json")
            XCTAssertNil(provider.model.last?.speaker)
        }
    }

    func testVoicesListReportsCapabilities() async throws {
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("caps-\(UUID().uuidString)")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Billie", refWav: nil, refText: "",
                            engines: ["supertonic": ["style.json": Data([1])]])
        _ = try voices.save(name: "Cruz", refWav: Data([1]), refText: "t")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B,
                                   log: APILog(), defaultVoice: { "" })
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            try await client.execute(uri: "/voices", method: .get) { resp in
                XCTAssertEqual(resp.status, .ok)
                let listed = try JSONDecoder().decode(
                    VoicesResponse.self, from: Data(buffer: resp.body))
                let billie = listed.voices.first { $0.meta.slug == "billie" }
                let cruz = listed.voices.first { $0.meta.slug == "cruz" }
                XCTAssertEqual(billie?.engines, ["supertonic"])
                XCTAssertEqual(billie?.hasSource, false)
                XCTAssertEqual(cruz?.engines, [])
                XCTAssertEqual(cruz?.hasSource, true)
            }
        }
    }

    func testInstructAndLanguageReachEngine() async throws {
        // Direction (instruct) is honored on the design model, not Base (clone-only).
        let provider = CapturingProvider()
        let app = Application(router: APIRouter.build(try makeDeps(provider, default: .qwenDesign)))
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
        let app = Application(router: APIRouter.build(try makeDeps(provider, default: .qwen17B)))
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
        let app = Application(router: APIRouter.build(try makeDeps(provider, default: .qwenDesign)))
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
        let app = Application(router: APIRouter.build(try makeDeps(provider, default: .qwenCustom)))
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
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("log1"),
                                   defaultBackend: .qwen17B, log: log,
                                   defaultVoice: { "cruz" })
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

    func testNoVoiceAndNoDefaultOnCloningBackendIs400() async throws {
        // Was `testEmptyDefaultPreservesRawBackendBehavior`, which asserted a 200
        // here. That "raw backend" behavior is the bug: qwen Base with no reference
        // generates UNCONDITIONED, inventing a random speaker per request while
        // reporting success. A cloning backend with nothing to clone now says so.
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
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String, "qwen3-1.7b requires a 'voice'")
            }
        }
        XCTAssertNil(provider.model.last, "the engine must not be reached at all")
    }

    func testUnknownVoiceOnCloningBackendIs400AndLogged() async throws {
        let provider = CapturingProvider()
        let log = APILog()
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("unknown-voice"),
                                   defaultBackend: .qwen17B, log: log)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","voice":"ghost"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String, "voice 'ghost' not found")
            }
        }
        XCTAssertNil(provider.model.last, "the engine must not be reached at all")
        // The failure is on the record, naming the slug — the old `try?` swallowed
        // it and logged a green 200 line for a voice that was never used.
        var entry: APILogEntry?
        for _ in 0..<50 {
            entry = await MainActor.run {
                log.entries.first { $0.path == "/v1/audio/speech" }
            }
            if entry != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(entry?.status, 400)
        XCTAssertEqual(entry?.note, "voice 'ghost' not found")
    }

    func testUnknownVoiceWithEmotionSuffixIs400NamingTheBaseSlug() async throws {
        // The variant probe ("ghost-excited") missing is not itself an error — the
        // 400 must name what the caller actually asked for.
        let provider = CapturingProvider()
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("unknown-variant"),
                                   defaultBackend: .qwen17B)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","voice":"ghost","emotion":"excited"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String, "voice 'ghost' not found")
            }
        }
    }

    func testEmptyRefTextOnQwenIs400() async throws {
        // A voice saved without a transcript is corrupt for qwen's in-context clone
        // path: nil refText drops it into the same unconditioned branch as no voice
        // at all. Fail loudly instead.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-reftext-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Mute", refWav: Data([0, 1, 2]), refText: "")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","voice":"mute"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .badRequest)
                let detail = try JSONSerialization.jsonObject(with: Data(buffer: resp.body))
                    as! [String: Any]
                XCTAssertEqual(detail["detail"] as? String,
                               "voice 'mute' has an empty reference transcript"
                                   + " — qwen3-1.7b cannot clone from it")
            }
        }
        XCTAssertNil(provider.model.last, "the engine must not be reached at all")
    }

    func testEmptyRefTextIsFineOnAudioOnlyCloneBackends() async throws {
        // Chatterbox clones from the audio alone — it never reads refText — so a
        // transcript-less voice must keep working there.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-reftext-cb-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Mute", refWav: Data([0, 1, 2]), refText: "")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .chatterboxTurbo)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"chatterbox-turbo","voice":"mute"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertTrue(provider.model.last?.refAudioPath?.hasSuffix("mute/ref.wav") == true)
        XCTAssertNil(provider.model.last?.refText)
    }

    func testUnknownVoiceOnKokoroStillFallsBackToAPresetVoicepack() async throws {
        // Kokoro has no clone path: its `voice` field IS a voicepack name, so an
        // unknown one keeps falling back to the backend's best-first preset rather
        // than 400. The new contract must not leak onto preset backends.
        let provider = CapturingProvider()
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("kokoro-unknown"),
                                   defaultBackend: .kokoro)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"kokoro","voice":"ghost"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.model.last?.speaker, BackendID.kokoroVoices.first)
        XCTAssertNil(provider.model.last?.refAudioPath)
    }

    func testEmotionVariantMissFallsBackToBaseVoice() async throws {
        // Existing behavior that must keep working: "ava" + an emotion with no acted
        // "ava-<emotion>" clip reads the base voice, it does not 400.
        let provider = CapturingProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-miss-\(UUID())")
        let voices = VoiceLibrary(directory: dir)
        _ = try voices.save(name: "Ava", refWav: Data([0, 1, 2]), refText: "ava base")
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: voices, defaultBackend: .qwen17B)
        let app = Application(router: APIRouter.build(deps))
        try await app.test(.router) { client in
            let body = #"{"input":"hello","model":"qwen3-1.7b","voice":"ava","emotion":"excited"}"#
            try await client.execute(uri: "/v1/audio/speech", method: .post,
                                     body: ByteBuffer(string: body)) { resp in
                XCTAssertEqual(resp.status, .ok)
            }
        }
        XCTAssertEqual(provider.model.last?.refText, "ava base")
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
        // qwen06B, not fish: fish backends sit behind the license-ack gate
        // (403), which is not what this test is about.
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("defmodel-omit"),
                                   defaultBackend: .qwen17B,
                                   defaultVoice: { "cruz" },
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
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("defmodel-override"),
                                   defaultBackend: .qwen17B,
                                   defaultVoice: { "cruz" },
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
        let app = Application(router: APIRouter.build(try makeDeps(provider, default: .qwen17B)))
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
        let deps = APIDependencies(engine: GloamEngine(provider: provider),
                                   voices: try seededLibrary("defmodel-stale"),
                                   defaultBackend: .qwen17B,
                                   defaultVoice: { "cruz" },
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
        let deps = APIDependencies(
            engine: GloamEngine(provider: SlowProvider()),
            voices: try seededLibrary("busy"), defaultBackend: .qwen17B,
            gate: RequestGate(maxConcurrent: 1, maxQueued: 1),
            defaultVoice: { "cruz" })
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
