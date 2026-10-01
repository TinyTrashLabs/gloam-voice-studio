import EngineKit
import Foundation

/// Qwen3-TTS VoiceDesign: renders auditions of one line from a description
/// (moved from the Mac app's AppModel.generateFoundryCandidate so Promo Studio
/// shares it). Each audition is peak-normalised to 0.98 and saved in the store.
public actor VoiceDesigner {
    let engine: GloamEngine, store: FoundryCandidateStore, backend: BackendID
    public init(engine: GloamEngine, store: FoundryCandidateStore, backend: BackendID = .qwenDesign) {
        self.engine = engine; self.store = store; self.backend = backend
    }

    /// `count` renders of `line` with `instruct = description`, seeds `seed, seed+1, …`;
    /// returned newest first.
    public func audition(description: String, line: String, language: String?, count: Int, seed: UInt64?) async throws -> [FoundryCandidateEntry] {
        let instruct = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [FoundryCandidateEntry] = []
        for i in 0..<max(1, count) {
            try Task.checkCancellation()
            let raw = try await engine.synthesize(backend: backend, request: SynthesisRequest(
                text: text, emotion: .neutral, instruct: instruct, language: language,
                seed: seed.map { $0 &+ UInt64(i) }))
            let samples = Self.normalizePeak(raw.samples)
            let wav = WAVFile.encode(mono: samples, sampleRate: raw.sampleRate)
            out.insert(try store.save(wav: wav, description: instruct, auditionLine: text, language: language,
                                      sampleRate: raw.sampleRate, seconds: Double(samples.count) / Double(raw.sampleRate),
                                      wallSeconds: raw.wallSeconds), at: 0)
        }
        return out
    }

    /// Same rule as StudioKit's AudioAssembler.normalizePeak(floats:target: 0.98).
    static func normalizePeak(_ samples: [Float], target: Float = 0.98) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-6 else { return samples }
        let scale = target / peak
        guard abs(scale - 1) > 1e-3 else { return samples }
        return samples.map { max(-1, min(1, $0 * scale)) }
    }
}
