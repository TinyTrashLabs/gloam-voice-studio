import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXRandom

/// Production ModelProviding backed by mlx-audio-swift.
/// Must only be used from the GloamEngine actor.
public final class MLXModelProvider: ModelProviding, @unchecked Sendable {
    /// Maps a backend to a local model directory (a path whose config.json
    /// exists), or nil to fall back to the HuggingFace repo id (which makes
    /// mlx-audio-swift download to its own cache). The app injects a resolver
    /// pointing at its managed Caches/Models directory so downloads always go
    /// through the in-app download manager.
    private let modelPathResolver: (@Sendable (BackendID) -> String?)?

    public init(modelPathResolver: (@Sendable (BackendID) -> String?)? = nil) {
        self.modelPathResolver = modelPathResolver
        // MLX's global RNG starts from a fixed default seed, so every fresh
        // process would sample the identical token sequence — the first take
        // after app launch (or every spike run) is otherwise always the same
        // performance for a given text + voice.
        MLXRandom.seed(UInt64.random(in: .min ... .max))
    }

    public func loadModel(backend: BackendID) async throws -> any SpeechModel {
        let source = modelPathResolver?(backend) ?? backend.spec.modelRepo
        let model = try await TTS.loadModel(modelRepo: source)
        return MLXSpeechModel(model: model, backend: backend)
    }

    public func didEvictModel() {
        Memory.clearCache()
    }
}

final class MLXSpeechModel: SpeechModel, @unchecked Sendable {
    private let model: any SpeechGenerationModel
    private let backend: BackendID

    /// Reference-audio reuse: the Qwen model caches its reference context
    /// (speaker embedding + codec tokens — several seconds of GPU work) keyed
    /// by MLXArray IDENTITY, so a freshly-loaded array every call misses it
    /// and repays the full cost per sentence. Keep the loaded array per
    /// (path, mtime) and hand back the SAME instance, so repeat synths with
    /// one voice — chat speaks sentence by sentence — pay it once.
    /// (Idea borrowed from Voicebox's voice-prompt cache, MIT.)
    private struct CachedRef {
        let path: String
        let mtime: Date
        let audio: MLXArray
    }
    private var refCache: [CachedRef] = []
    private let refCacheLock = NSLock()

    init(model: any SpeechGenerationModel, backend: BackendID) {
        self.model = model
        self.backend = backend
    }

    var sampleRate: Int { model.sampleRate }

    private func referenceAudio(for path: String) throws -> MLXArray {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date) ?? .distantPast
        refCacheLock.lock()
        defer { refCacheLock.unlock() }
        if let index = refCache.firstIndex(where: { $0.path == path && $0.mtime == mtime }) {
            let hit = refCache.remove(at: index)
            refCache.insert(hit, at: 0)   // MRU to the front
            return hit.audio
        }
        let (_, audio) = try loadAudioArray(
            from: URL(fileURLWithPath: path), sampleRate: model.sampleRate)
        refCache.insert(CachedRef(path: path, mtime: mtime, audio: audio), at: 0)
        if refCache.count > 4 { refCache.removeLast() }   // a few voices, tiny arrays
        return audio
    }

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        do {
            var refAudio: MLXArray?
            if let path = request.refAudioPath {
                refAudio = try referenceAudio(for: path)
            }
            if let chatterbox = model as? ChatterboxModel {
                chatterbox.emotionAdvOverride = request.exaggeration
                chatterbox.cfgWeightOverride = request.cfgWeight
            }
            var params = model.defaultGenerationParameters
            if let temperature = request.temperature { params.temperature = temperature }
            if let topP = request.topP { params.topP = topP }
            if let topK = request.topK { params.topK = topK }
            if let rep = request.repetitionPenalty { params.repetitionPenalty = rep }

            let audio: MLXArray
            if backend == .qwenCustom, let qwen = model as? Qwen3TTSModel {
                // CustomVoice: stable preset speaker + optional instruct compose.
                audio = try await qwen.generateCustomVoice(
                    text: request.text,
                    speaker: request.speaker ?? "",
                    instruct: request.instruct,
                    language: request.language,
                    generationParameters: params)
            } else {
                // Base/VoiceDesign/Fish/Chatterbox. For Qwen, `voice:` carries the
                // instruct (honored only on the no-ref path — planner already enforced this).
                audio = try await model.generate(
                    text: request.text,
                    voice: backend.isQwen ? request.instruct
                        : backend == .kokoro ? request.speaker
                        : nil,
                    refAudio: refAudio,
                    refText: request.refText,
                    language: request.language,
                    generationParameters: params)
            }
            return audio.asArray(Float.self)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.generationFailed(backend: backend, message: "\(error)")
        }
    }
}
