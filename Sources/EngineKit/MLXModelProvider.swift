import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Production ModelProviding backed by mlx-audio-swift.
/// Must only be used from the GloamEngine actor.
public final class MLXModelProvider: ModelProviding, @unchecked Sendable {
    public init() {}

    public func loadModel(backend: BackendID) async throws -> any SpeechModel {
        let model = try await TTS.loadModel(modelRepo: backend.spec.modelRepo)
        return MLXSpeechModel(model: model, backend: backend)
    }

    public func didEvictModel() {
        Memory.clearCache()
    }
}

final class MLXSpeechModel: SpeechModel, @unchecked Sendable {
    private let model: any SpeechGenerationModel
    private let backend: BackendID

    init(model: any SpeechGenerationModel, backend: BackendID) {
        self.model = model
        self.backend = backend
    }

    var sampleRate: Int { model.sampleRate }

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        do {
            var refAudio: MLXArray?
            if let path = request.refAudioPath {
                // Resample on load: fish refs must hit the 44.1 kHz codec rate,
                // chatterbox refs its 24 kHz — both equal model.sampleRate here.
                (_, refAudio) = try loadAudioArray(
                    from: URL(fileURLWithPath: path), sampleRate: model.sampleRate)
            }
            if let chatterbox = model as? ChatterboxModel {
                chatterbox.emotionAdvOverride = request.exaggeration
            }
            var params = model.defaultGenerationParameters
            if let temperature = request.temperature {
                params.temperature = temperature
            }
            let audio = try await model.generate(
                text: request.text, voice: nil, refAudio: refAudio,
                refText: request.refText, language: nil,
                generationParameters: params)
            return audio.asArray(Float.self)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.generationFailed(backend: backend, message: "\(error)")
        }
    }
}
