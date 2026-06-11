/// A loaded speech model. Conformers are responsible for their own thread-safety
/// (they are `Sendable`); GloamEngine additionally serializes all calls through a
/// task chain, so `synthesize` is never invoked concurrently in practice.
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
