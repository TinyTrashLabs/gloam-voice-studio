import XCTest
@testable import EngineKit

/// Dia2 asked for one line must still go through `synthesizeDialogue`, because
/// that is the only entry point carrying a word-aligned prefix. Routing it to
/// `SpeechModel.synthesize` would drop the voice and return an unconditioned
/// pass — a stranger reading the line under the selected voice's name.
private final class RecordingDialogueModel: DialogueSpeechModel, @unchecked Sendable {
    nonisolated(unsafe) static var lastDialogue: ProviderDialogueRequest?
    nonisolated(unsafe) static var singleVoiceCalls = 0

    let sampleRate = 24000
    let nonverbalTags = ["(laughs)"]

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        Self.singleVoiceCalls += 1
        return [0, 0, 0, 0]
    }

    func synthesizeDialogue(_ request: ProviderDialogueRequest) async throws -> DialogueChunk {
        Self.lastDialogue = request
        return DialogueChunk(samples: [0.1, 0.2, 0.3], words: [])
    }

    func openDialogueSession(_ request: ProviderDialogueRequest) throws -> any DialogueStreaming {
        throw EngineError.generationFailed(backend: .dia2, message: "not used here")
    }
}

private final class RecordingProvider: ModelProviding, @unchecked Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel {
        RecordingDialogueModel()
    }
    func didEvictModel() {}
}

final class Dia2SingleVoiceRoutingTests: XCTestCase {
    override func setUp() {
        RecordingDialogueModel.lastDialogue = nil
        RecordingDialogueModel.singleVoiceCalls = 0
    }

    func testSingleLineGoesThroughTheDialoguePathCarryingThePrefix() async throws {
        let engine = GloamEngine(provider: RecordingProvider())
        let prefix = DialoguePrefix(
            samples: [0.4, 0.5],
            words: [AlignedWordTiming(text: "hello", start: 0, end: 0.3)])
        _ = try await engine.synthesize(
            backend: .dia2,
            request: SynthesisRequest(text: "Good evening.", dialoguePrefix: prefix))

        XCTAssertEqual(RecordingDialogueModel.singleVoiceCalls, 0,
                       "dia2 must not take the single-voice path — it drops the voice")
        let sent = try XCTUnwrap(RecordingDialogueModel.lastDialogue)
        XCTAssertEqual(sent.script, ["[S1] Good evening."])
        XCTAssertEqual(sent.prefixes.count, 1)
        XCTAssertEqual(sent.prefixes[0]?.words.first?.text, "hello")
    }

    func testNoPrefixStillGeneratesButUnconditioned() async throws {
        let engine = GloamEngine(provider: RecordingProvider())
        _ = try await engine.synthesize(
            backend: .dia2, request: SynthesisRequest(text: "Hi."))
        let sent = try XCTUnwrap(RecordingDialogueModel.lastDialogue)
        XCTAssertEqual(sent.prefixes.count, 1)
        XCTAssertNil(sent.prefixes[0])
    }

    /// The bench's temperature/topK knobs must reach dia2's audio sampler.
    func testBenchKnobsReachTheDialogueRequest() async throws {
        let engine = GloamEngine(provider: RecordingProvider())
        _ = try await engine.synthesize(
            backend: .dia2,
            request: SynthesisRequest(text: "Hi.", temperatureOverride: 0.9, topK: 42))
        let sent = try XCTUnwrap(RecordingDialogueModel.lastDialogue)
        XCTAssertEqual(sent.temperature, 0.9)
        XCTAssertEqual(sent.topK, 42)
    }
}
