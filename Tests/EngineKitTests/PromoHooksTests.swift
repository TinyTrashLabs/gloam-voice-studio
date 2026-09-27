import XCTest
@testable import EngineKit

final class PromoHooksTests: XCTestCase {
    func testChatRequestCarriesSeedAndKVCap() {
        let r = ChatRequest(messages: [ChatTurn(role: .user, content: "hi")], seed: 7, maxKVSize: 16_384)
        XCTAssertEqual(r.seed, 7)
        XCTAssertEqual(MLXLanguageModel.generateParameters(for: r).maxKVSize, 16_384)
    }
    func testSynthesisRequestCarriesSeed() {
        XCTAssertEqual(SynthesisRequest(text: "x", seed: 42).seed, 42)
    }
    func testSpeakerEmbeddingNeedsAnEncoder() async {
        let engine = GloamEngine(provider: NoEmbeddingProvider())
        do { _ = try await engine.speakerEmbedding(backend: .kokoro, samples: [0, 0, 0], sampleRate: 24_000); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("speaker embedding")) }
    }
    func testSpeakerEmbeddingComesFromTheModel() async throws {
        let engine = GloamEngine(provider: EmbeddingProvider())
        let e = try await engine.speakerEmbedding(backend: .kokoro, samples: [0.1, 0.2], sampleRate: 24_000)
        XCTAssertEqual(e, [2, 0.1])
    }
}

final class NoEmbeddingProvider: ModelProviding, @unchecked Sendable {
    final class M: SpeechModel, @unchecked Sendable { var sampleRate: Int { 24_000 }; func synthesize(_ r: ProviderRequest) async throws -> [Float] { [] } }
    func loadModel(backend: BackendID) async throws -> any SpeechModel { M() }
    func didEvictModel() {}
}

final class EmbeddingProvider: ModelProviding, @unchecked Sendable {
    final class M: SpeechModel, SpeakerEmbedding, @unchecked Sendable {
        var sampleRate: Int { 24_000 }
        func synthesize(_ r: ProviderRequest) async throws -> [Float] { [] }
        func speakerEmbedding(samples: [Float], sampleRate: Int) throws -> [Float] { [Float(samples.count), samples[0]] }
    }
    func loadModel(backend: BackendID) async throws -> any SpeechModel { M() }
    func didEvictModel() {}
}
