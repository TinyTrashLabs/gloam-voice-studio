/// A loaded speech model. Implementations are NOT Sendable — they must be
/// owned and called only by the GloamEngine actor (MLX binds compiled graphs
/// to their execution context; serializing on one actor is the Swift
/// equivalent of the Python engine's single MLX worker thread).
public protocol SpeechModel: AnyObject, Sendable {
    var sampleRate: Int { get }
    func synthesize(_ request: ProviderRequest) async throws -> [Float]
}

/// Loads models. Real implementation wraps mlx-audio-swift; tests use fakes.
public protocol ModelProviding: Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel
    /// Called after a model is dropped, to release accelerator memory.
    func didEvictModel()
}
