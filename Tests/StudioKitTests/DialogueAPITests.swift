import EngineKit
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import StudioKit

/// A two-speaker model that returns a short burst, so the route can be tested
/// without a 2B model on disk.
private final class FakeDialogueModel: DialogueSpeechModel, @unchecked Sendable {
    /// What the route last handed the model. Static because the provider makes
    /// a fresh model per load, and the assertion is about the route.
    nonisolated(unsafe) static var lastDialogue: ProviderDialogueRequest?

    let sampleRate = 24000
    let nonverbalTags = ["(laughs)", "(sighs)"]

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        [0.0, 0.25, -0.25, 0.5]
    }

    func synthesizeDialogue(_ request: ProviderDialogueRequest) async throws -> DialogueChunk {
        Self.lastDialogue = request
        return DialogueChunk(samples: (0 ..< 240).map { Float(sin(Double($0) * 0.1)) },
                      words: [AlignedWordTiming(text: "hello", start: 0, end: 0.2)])
    }

    func openDialogueSession(_ request: ProviderDialogueRequest) throws -> any DialogueStreaming {
        FakeDialogueSession()
    }
}

private struct FakeDialogueSession: DialogueStreaming {
    func append(_ lines: [String]) async {}
    func finish() async {}
    func cancel() async {}
    var audio: AsyncThrowingStream<DialogueChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(DialogueChunk(samples: [Float](repeating: 0.2, count: 240),
                                             words: []))
            continuation.finish()
        }
    }
}

private final class FakeDialogueProvider: ModelProviding, @unchecked Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel { FakeDialogueModel() }
    func didEvictModel() {}
}

final class DialogueAPITests: XCTestCase, @unchecked Sendable {
    private var dir: URL!
    private var deps: APIDependencies!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-api-\(UUID().uuidString)")
        deps = APIDependencies(
            engine: GloamEngine(provider: FakeDialogueProvider()),
            voices: VoiceLibrary(directory: dir),
            defaultBackend: .dia2)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func withDialogueApp(
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        try await Application(router: APIRouter.build(deps)).test(.router, body)
    }

    func testDialogueReturnsAWav() async throws {
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"},{"speaker":2,"text":"Hi"}],
             "voices":["ava","ben"]}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .badRequest,
                               "unknown voices are a 4xx, never a quietly wrong take")
            }
        }
    }

    func testAKnownVoiceWithNoReferenceStillGenerates() async throws {
        _ = try VoiceLibrary(directory: dir).save(
            name: "Ava", refWav: nil, refText: "",
            engines: ["dia2": ["alignment.json": Data("[]".utf8)]])
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"}],"voices":["ava"]}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                XCTAssertTrue(response.body.readableBytes > 44,
                              "expected PCM past the header")
            }
        }
    }

    func testDialogueUsesTheDia2ReferenceAndPairedAlignment() async throws {
        func wav(_ count: Int) -> Data {
            WAVEncoder.encode(pcm16: PCM16.data(from: (0..<count).map {
                Float(sin(Double($0) * 0.1)) * 0.2
            }), sampleRate: 24_000)
        }
        _ = try deps.voices.save(name: "Ava", refWav: wav(4800), refText: "full source",
            engines: ["dia2": ["ref.wav": wav(2400), "alignment.json":
                try JSONEncoder().encode([AlignedWord(w: "clip", start: 0, end: 0.1)])]])
        try await withDialogueApp { client in
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                body: ByteBuffer(string: #"{"turns":[{"speaker":1,"text":"Hello"}],"voices":["ava"]}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                let prefix = FakeDialogueModel.lastDialogue?.prefixes.first ?? nil
                XCTAssertEqual(prefix?.samples.count, 2400)
                XCTAssertEqual(prefix?.words.map(\.text), ["clip"])
            }
        }
    }

    func testNoVoicesGeneratesUnconditioned() async throws {
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"},{"speaker":2,"text":"Hi"}]}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
            }
        }
    }

    func testThirdSpeakerIsAFourHundred() async throws {
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":3,"text":"nope"}],"voices":[]}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testUnknownTagIsAFourHundred() async throws {
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"hi (yodels)"}],"voices":[]}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testAnEmptyScriptIsAFourHundred() async throws {
        try await withDialogueApp { client in
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: #"{"turns":[]}"#)) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testStreamingReturnsAnOpenEndedWav() async throws {
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"}],"stream":true}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.contentType], "audio/wav")
                let bytes = Data(buffer: response.body)
                XCTAssertEqual(bytes.prefix(4), Data("RIFF".utf8))
                XCTAssertEqual(bytes[4...7], Data([0xFF, 0xFF, 0xFF, 0xFF]))
                XCTAssertTrue(bytes.count > 44)
            }
        }
    }

    /// The sampler controls were declared on the body and on the provider
    /// request and joined up nowhere in between, so sending them did nothing.
    func testSamplerControlsReachTheModel() async throws {
        FakeDialogueModel.lastDialogue = nil
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"}],
             "cfg_scale":6.5,"text_temperature":0.45,"text_top_k":31,
             "audio_temperature":0.85,"audio_top_k":67,
             "max_padding":5,"keep_prefix_audio":true}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let sent = try XCTUnwrap(FakeDialogueModel.lastDialogue)
        XCTAssertEqual(sent.cfgScale, 6.5)
        XCTAssertEqual(sent.textTemperature, 0.45)
        XCTAssertEqual(sent.textTopK, 31)
        XCTAssertEqual(sent.audioTemperature, 0.85)
        XCTAssertEqual(sent.audioTopK, 67)
        XCTAssertEqual(sent.maxPadding, 5)
        XCTAssertTrue(sent.keepPrefixAudio)
    }

    /// Passes must not share a draw. Identical seeds would not make two passes
    /// sound alike -- they render different text -- but they would make a
    /// re-roll meaningless, because rerolling one pass would have to reroll
    /// every pass with it.
    func testEachPassOfATakeDrawsItsOwnSeed() {
        let take: UInt64 = 0xDEAD_BEEF
        let passes = (0 ..< 8).map { DialogueSeed.pass(take: take, index: $0) }
        XCTAssertEqual(Set(passes).count, passes.count, "two passes shared a draw")
        // Reproducible: the same take renders the same passes.
        XCTAssertEqual(passes, (0 ..< 8).map { DialogueSeed.pass(take: take, index: $0) })
        // A different take is a different performance throughout.
        XCTAssertNotEqual(passes, (0 ..< 8).map { DialogueSeed.pass(take: take &+ 1, index: $0) })
    }

    /// Retry-on-collapse re-rolls the DRAW for one pass, leaving its
    /// neighbours exactly as they were -- so a rescued pass cannot disturb a
    /// take that was otherwise fine.
    func testARetryChangesOnlyItsOwnPass() {
        let take: UInt64 = 12_345
        let first = DialogueSeed.pass(take: take, index: 2, attempt: 0)
        let retry = DialogueSeed.pass(take: take, index: 2, attempt: 1)
        XCTAssertNotEqual(first, retry)
        XCTAssertEqual(DialogueSeed.pass(take: take, index: 3, attempt: 0),
                       DialogueSeed.pass(take: take, index: 3, attempt: 0))
        // A retry of pass 2 must not collide with any draw pass 3 could take.
        let neighbours = (0 ..< 4).map { DialogueSeed.pass(take: take, index: 3, attempt: $0) }
        XCTAssertFalse(neighbours.contains(retry))
    }

    /// The seed has to survive the hop from the caller's request to the model,
    /// or a take is reproducible in name only.
    func testSeedReachesTheModel() async throws {
        FakeDialogueModel.lastDialogue = nil
        let dialogue = DialogueRequest(
            turns: [DialogueTurn(speaker: 1, text: "Hello")], voices: [], seed: 4_242)
        let sent = ProviderDialogueRequest(dialogue, script: ["[S1] Hello"], prefixes: [])
        XCTAssertEqual(sent.seed, 4_242)
    }

    /// The old field names still have to work: Gloam Radio sends them.
    func testLegacyTemperatureAndTopKStillArrive() async throws {
        FakeDialogueModel.lastDialogue = nil
        try await withDialogueApp { client in
            let body = """
            {"turns":[{"speaker":1,"text":"Hello"}],"temperature":0.7,"top_k":42}
            """
            try await client.execute(uri: "/v1/audio/dialogue", method: .post,
                                     body: ByteBuffer(string: body)) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        let sent = try XCTUnwrap(FakeDialogueModel.lastDialogue)
        XCTAssertEqual(sent.temperature, 0.7)
        XCTAssertEqual(sent.topK, 42)
    }

    func testTagsEndpointListsTheVocabulary() async throws {
        try await withDialogueApp { client in
            try await client.execute(uri: "/v1/audio/dialogue/tags", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("(laughs)"), text)
            }
        }
    }
}
