import XCTest
@testable import EngineKit
import MLXLMCommon

final class ChatSamplingTests: XCTestCase {
    func testSamplerFieldsMapOntoGenerateParameters() {
        let req = ChatRequest(
            messages: [ChatTurn(role: .user, content: "hi")],
            temperature: 0.5, topP: 0.9, maxTokens: 128,
            topK: 40, minP: 0.05,
            repetitionPenalty: 1.1, repetitionContextSize: 64,
            presencePenalty: 0.5, frequencyPenalty: 0.25)
        let params = MLXLanguageModel.generateParameters(for: req)
        XCTAssertEqual(params.maxTokens, 128)
        XCTAssertEqual(params.temperature, 0.5)
        XCTAssertEqual(params.topP, 0.9)
        XCTAssertEqual(params.topK, 40)
        XCTAssertEqual(params.minP, 0.05)
        XCTAssertEqual(params.repetitionPenalty, 1.1)
        XCTAssertEqual(params.repetitionContextSize, 64)
        XCTAssertEqual(params.presencePenalty, 0.5)
        XCTAssertEqual(params.frequencyPenalty, 0.25)
    }

    func testNilSamplerFieldsKeepLibraryDefaults() {
        let req = ChatRequest(messages: [ChatTurn(role: .user, content: "hi")])
        let params = MLXLanguageModel.generateParameters(for: req)
        let defaults = GenerateParameters()
        XCTAssertEqual(params.topK, defaults.topK)
        XCTAssertEqual(params.minP, defaults.minP)
        XCTAssertNil(params.repetitionPenalty)
        XCTAssertNil(params.presencePenalty)
        XCTAssertNil(params.frequencyPenalty)
    }

    func testContextTokensIsPositive() {
        for backend in LLMBackendID.allCases {
            XCTAssertGreaterThanOrEqual(backend.contextTokens, 8_192)
        }
    }
}
