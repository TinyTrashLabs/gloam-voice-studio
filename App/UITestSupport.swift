import EngineKit
import Foundation

/// Instant fake model so the XCUITest smoke runs without weights or Metal.
final class UITestFakeModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24000
    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        // 0.5 s of quiet 440 Hz sine — audible if played, fast to make.
        (0..<12000).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 24000) }
    }
}

final class UITestFakeProvider: ModelProviding, @unchecked Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel { UITestFakeModel() }
    func didEvictModel() {}
}

/// Instant fake LLM so the chat smoke test runs without weights or Metal.
final class UITestFakeLanguageModel: LanguageModel, @unchecked Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult {
        ChatResult(text: "Hi there! This is a test reply.",
                   toolCalls: [],
                   usage: ChatUsage(promptTokens: 8, completionTokens: 8),
                   wallSeconds: 0.01, tokensPerSecond: 800)
    }
}

final class UITestFakeLanguageProvider: LanguageModelProviding, @unchecked Sendable {
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel {
        UITestFakeLanguageModel()
    }
    func didEvictModel() {}
}

enum UITestMode {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--uitest") }
    static var tempRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gloam-uitest-\(ProcessInfo.processInfo.processIdentifier)")
    }
    /// `.gvoice` packs to import into the throwaway library at launch (`--uitest-import=<path>`,
    /// repeatable), so a UI run can open a real pack without touching the user's library. One argument,
    /// not a flag and a path: AppKit takes a bare path argument as a document to open and then skips
    /// the main window.
    static var importPaths: [String] {
        let flag = "--uitest-import="
        return ProcessInfo.processInfo.arguments.filter { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }
    }
    /// A valid 2 s WAV reference clip for the "Use Sample Reference" button.
    static func sampleReference() -> Data {
        let samples = (0..<88200).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 44100) }
        return WAVEncoderBridge.wav(samples: samples, sampleRate: 44100)
    }
}

import StudioKit
enum WAVEncoderBridge {
    static func wav(samples: [Float], sampleRate: Int) -> Data {
        WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: sampleRate)
    }
}
