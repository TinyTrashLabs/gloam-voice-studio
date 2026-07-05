import Foundation

/// Owns model lifecycle: one model resident at a time, all model work
/// serialized through this actor (MLX streams/graphs are execution-context
/// bound — see SPIKE-RESULTS.md "silent failure when two models load").
public actor GloamEngine {
    private let provider: ModelProviding
    private var resident: (backend: BackendID, model: any SpeechModel)?
    private var ackedLicenses: Set<BackendID> = []
    /// Serializes all model work (loads + generations). Actors are reentrant at
    /// await points, so without this two synthesize calls could interleave and
    /// run concurrent GPU work.
    private var tail: Task<Void, Never>?
    private let languageProvider: LanguageModelProviding?
    private var residentLLM: (backend: LLMBackendID, model: any LanguageModel)?

    public init(provider: ModelProviding, languageProvider: LanguageModelProviding? = nil) {
        self.provider = provider
        self.languageProvider = languageProvider
    }

    public func acknowledgeLicense(for backend: BackendID) {
        ackedLicenses.insert(backend)
    }

    public func loadedBackend() -> BackendID? {
        resident?.backend
    }

    /// Waits for all queued model work (loads + generations) to drain. Lets an
    /// external owner (e.g. the gloam.fm shell freeing RAM on a lane switch)
    /// evict models without preempting an in-flight request: quiesce first,
    /// then unload. Work queued AFTER quiesce returns isn't covered — for
    /// eviction that race is benign (a post-eviction request reloads on demand).
    public func quiesce() async {
        await tail?.value
    }

    /// Evicts the resident model and releases accelerator memory.
    /// Takes effect immediately; callers must not unload while a generation is in flight.
    public func unload() {
        guard resident != nil else { return }
        resident = nil
        provider.didEvictModel()
    }

    public func loadedLLM() -> LLMBackendID? { residentLLM?.backend }

    /// Evicts the resident language model and releases accelerator memory.
    public func unloadLLM() {
        guard residentLLM != nil else { return }
        residentLLM = nil
        languageProvider?.didEvictModel()
    }

    public func chat(backend: LLMBackendID, request: ChatRequest) async throws -> ChatResult {
        guard languageProvider != nil else { throw EngineError.languageProviderUnavailable }
        let previous = tail
        let work = Task<ChatResult, Error> { [self] in
            await previous?.value
            let model = try await self.residentLanguageModel(for: backend)
            return try await model.complete(request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Streaming chat. Chained through the same task tail as synthesize/chat so
    /// token generation never overlaps other GPU work. The stream finishes with
    /// an error if no language provider is configured or the model fails.
    public func chatStream(backend: LLMBackendID, request: ChatRequest)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        guard languageProvider != nil else {
            continuation.finish(throwing: EngineError.languageProviderUnavailable)
            return stream
        }
        let previous = tail
        let work = Task { [self] in
            await previous?.value
            do {
                let model = try await self.residentLanguageModel(for: backend)
                for try await event in model.stream(request) {
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        tail = Task { _ = await work.value }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func residentLanguageModel(for backend: LLMBackendID) async throws -> any LanguageModel {
        if let residentLLM, residentLLM.backend == backend { return residentLLM.model }
        guard let languageProvider else { throw EngineError.languageProviderUnavailable }
        unloadLLM()
        let model = try await languageProvider.loadModel(backend: backend)
        residentLLM = (backend, model)
        return model
    }

    /// Loads the model for `backend` (evicting any other resident model)
    /// without synthesizing — backs the UI's explicit Load button. Chained
    /// through the same task tail as synthesize so loads never overlap
    /// in-flight GPU work.
    public func preload(backend: BackendID) async throws {
        if backend.spec.needsLicenseAck && !ackedLicenses.contains(backend) {
            throw EngineError.licenseAckRequired(backend)
        }
        let previous = tail
        let work = Task<Void, Error> { [self] in
            await previous?.value
            _ = try await self.residentModel(for: backend)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    public func synthesize(backend: BackendID, request: SynthesisRequest)
        async throws -> SynthesisResult
    {
        // Fast-fail synchronous checks before entering the task chain.
        if backend.spec.needsLicenseAck && !ackedLicenses.contains(backend) {
            throw EngineError.licenseAckRequired(backend)
        }
        let plan = try RequestPlanner.plan(backend: backend, request: request)

        // Chain model work so concurrent calls never overlap at await points.
        let previous = tail
        let work = Task<SynthesisResult, Error> { [self] in
            await previous?.value
            let model = try await self.residentModel(for: backend)
            let start = Date()
            let raw = try await model.synthesize(plan)
            let wall = Date().timeIntervalSince(start)
            return SynthesisResult(
                samples: SpeedAdjust.apply(raw, speed: request.speed),
                sampleRate: model.sampleRate,
                wallSeconds: wall)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private func residentModel(for backend: BackendID) async throws -> any SpeechModel {
        if let resident, resident.backend == backend {
            return resident.model
        }
        unload()
        let model = try await provider.loadModel(backend: backend)
        resident = (backend, model)
        return model
    }
}
