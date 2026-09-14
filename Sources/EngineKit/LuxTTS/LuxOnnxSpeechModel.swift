import Foundation

/// LuxTTS on ONNX Runtime, behind the same `SpeechModel` the MLX path
/// implements — so an app can choose a runtime instead of being handed one.
///
/// `LuxEngine` has been in EngineKit all along, but nothing could reach it
/// from a UI: it takes phoneme ids and an encoded prompt, while the apps talk
/// `ProviderRequest`. That gap is why the macOS Studio only ever ran MLX and
/// ONNX lived in the `spike` CLI. This is the adapter that closes it, ported
/// up from gloam-voice-studio-ios, where it had been duplicated.
///
/// The two runtimes are not interchangeable in cost: MLX peaks near 0.7 GB
/// against ONNX's 2.6 GB and runs 1.3–1.6x faster (2026-09-07 device spike),
/// which is why MLX remains the default everywhere it can run. ONNX earns its
/// place where MLX cannot go — the iOS Simulator — and as the A/B reference
/// when a render sounds wrong and the question is whether the runtime is why.
public final class LuxOnnxSpeechModel: SpeechModel, @unchecked Sendable {
    private let engine: LuxEngine
    private let tokenizer: LuxTokenizer

    public var sampleRate: Int { LuxOnnx.sampleRate }

    /// Async for the same reason `LuxSpeechModel.load` is: `MisakiPhonemizer`
    /// resolves its dictionaries off disk. Both runtimes take the SAME front
    /// end and the same bundled token table, so a difference in the audio is
    /// the runtime's doing rather than the text's -- which is the entire point
    /// of being able to switch.
    public static func load(modelDir: URL) async throws -> LuxOnnxSpeechModel {
        let phonemizer: any PhonemizerProviding
        do {
            phonemizer = try await MisakiPhonemizer.prepared()
        } catch {
            throw LuxModelLoadError.phonemizerUnavailable("\(error)")
        }
        return try LuxOnnxSpeechModel(modelDir: modelDir, phonemizer: phonemizer)
    }

    public init(modelDir: URL, phonemizer: any PhonemizerProviding) throws {
        engine = try LuxEngine(modelDir: modelDir)
        tokenizer = try LuxTokenizer(phonemizer: phonemizer)
    }

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        do {
            guard let refPath = request.refAudioPath else {
                throw EngineError.refAudioRequired(.luxTTS)
            }
            // LuxTTS sizes a render from the prompt, so the reference
            // transcript is load-bearing: its characters-per-second IS the
            // voice's reading rate. An empty one is not a neutral default.
            guard let refText = request.refText, !refText.isEmpty else {
                throw EngineError.generationFailed(
                    backend: .luxTTS,
                    message: "lux-tts on ONNX needs the reference transcript")
            }
            let samples = try LuxOnnx.loadMono24k(URL(fileURLWithPath: refPath))
            let promptTokens = try tokenizer.textToTokenIDs(refText).map(Int64.init)
            let prompt = try LuxOnnx.encodePrompt(samples24k: samples, tokens: promptTokens)
            let textIDs = try tokenizer.textToTokenIDs(request.text).map(Int64.init)

            // Defaults match LuxSpeechModel's, so switching runtime does not
            // silently switch sampling settings too.
            let (out, _) = try engine.synthesize(
                textIDs: textIDs,
                prompt: prompt,
                numSteps: request.numSteps ?? 4,
                speed: request.speed ?? 1.0,
                tShift: request.tShift ?? 0.5,
                guidance: request.guidanceScale ?? 3.0,
                dualPath48k: false)
            return out
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.generationFailed(backend: .luxTTS, message: "\(error)")
        }
    }
}

/// Which implementation answers for `.luxTTS`.
///
/// A setting rather than a constant because the two exist to be compared:
/// the macOS Studio surfaces it for testing, and iOS needs ONNX in the
/// Simulator where MLX cannot run at all.
public enum LuxRuntime: String, CaseIterable, Sendable, Codable {
    case mlx
    case onnx

    public var label: String {
        switch self {
        case .mlx: "MLX — the shipping runtime"
        case .onnx: "ONNX — reference for A/B"
        }
    }

    /// MLX everywhere it runs: less memory, faster, and what a listener hears
    /// in a release build.
    public static let `default`: LuxRuntime = .mlx
}
