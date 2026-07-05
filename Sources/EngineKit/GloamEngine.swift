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
    ///
    /// Uses the model's consumer-paced stream: between deltas the GPU is idle,
    /// and any synthesis queued via `synthesizeInterleaved` runs there — that's
    /// how chat replies can start speaking while tokens are still generating
    /// without ever running TTS and decode concurrently.
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
            chatStreamActive = true
            do {
                let model = try await self.residentLanguageModel(for: backend)
                try await model.pacedStream(request) { event in
                    continuation.yield(event)
                    await self.drainInterleaved()
                }
                chatStreamActive = false
                // A sentence queued between the last delta and finish must not
                // strand its waiter — run leftovers while we still hold the tail.
                await self.drainInterleaved()
                continuation.finish()
            } catch {
                chatStreamActive = false
                await self.drainInterleaved()
                continuation.finish(throwing: error)
            }
        }
        tail = Task { _ = await work.value }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    // MARK: Interleaved synthesis (speak-while-generating)

    private var chatStreamActive = false
    private var pendingInterleaved:
        [(backend: BackendID, request: SynthesisRequest,
          continuation: CheckedContinuation<SynthesisResult, Error>)] = []

    /// Synthesize a line so it can interleave with an active chat stream: the
    /// request is queued and runs between token pulls (GPU idle slots) inside
    /// the stream's tail task. With no chat stream active it behaves exactly
    /// like `synthesize`. Used by the chat UI to speak sentences while the
    /// reply is still generating.
    public func synthesizeInterleaved(backend: BackendID, request: SynthesisRequest)
        async throws -> SynthesisResult
    {
        guard chatStreamActive else {
            return try await synthesize(backend: backend, request: request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingInterleaved.append((backend, request, continuation))
        }
    }

    /// Test hook: how many interleaved requests are queued right now.
    func _pendingInterleavedCount() -> Int { pendingInterleaved.count }

    /// Runs every queued interleaved synthesis. Called from the chat stream's
    /// tail task between deltas (and once after the stream ends), so it is
    /// already serialized with all other GPU work.
    private func drainInterleaved() async {
        while !pendingInterleaved.isEmpty {
            let item = pendingInterleaved.removeFirst()
            do {
                let result = try await performSynthesis(
                    backend: item.backend, request: item.request)
                item.continuation.resume(returning: result)
            } catch {
                item.continuation.resume(throwing: error)
            }
        }
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

        // Chain model work so concurrent calls never overlap at await points.
        let previous = tail
        let work = Task<SynthesisResult, Error> { [self] in
            await previous?.value
            return try await self.performSynthesis(backend: backend, request: request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// The synthesis body itself — no tail chaining. Callers must already be
    /// serialized: either the task chain (`synthesize`) or the chat stream's
    /// tail task (`drainInterleaved`).
    private func performSynthesis(backend: BackendID, request: SynthesisRequest)
        async throws -> SynthesisResult
    {
        if backend.spec.needsLicenseAck && !ackedLicenses.contains(backend) {
            throw EngineError.licenseAckRequired(backend)
        }
        let plan = try RequestPlanner.plan(backend: backend, request: request)
        let model = try await self.residentModel(for: backend)
        let start = Date()
        let raw = try await model.synthesize(plan)
        let wall = Date().timeIntervalSince(start)
        return SynthesisResult(
            samples: SpeedAdjust.apply(raw, speed: request.speed),
            sampleRate: model.sampleRate,
            wallSeconds: wall)
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
