import Foundation

/// Owns model lifecycle: one model resident at a time, all model work
/// serialized through this actor (MLX streams/graphs are execution-context
/// bound — see SPIKE-RESULTS.md "silent failure when two models load").
public actor GloamEngine {
    private let provider: ModelProviding
    private var resident: (backend: BackendID, model: any SpeechModel)?
    private var ackedLicenses: Set<BackendID> = []
    /// Separate generation lanes for the language model and the speech model.
    /// MLX safely INTERLEAVES two resident-model generations on one GPU (empirically
    /// verified on M5/32GB: 0 corruption, and a short LLM "select" completes in ~2.3s
    /// even while a long TTS synth keeps running) — so a track-select never has to
    /// wait behind a 20s+ voice synth. Each lane still serializes its own kind so two
    /// synths (or two chats) never overlap.
    private var tailLLM: Task<Void, Never>?
    private var tailTTS: Task<Void, Never>?
    /// Model LOADS, by contrast, are NOT safe to overlap (two multi-GB GPU loads
    /// compete and one silently yields nothing — SPIKE-RESULTS.md). This gate
    /// serializes every load across both lanes; generations run free once resident.
    private var loadGate: Task<Void, Never>?
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
        let previous = tailLLM   // serialize chats against each other, not against synths
        let work = Task<ChatResult, Error> { [self] in
            await previous?.value
            let model = try await self.residentLanguageModel(for: backend)
            return try await model.complete(request)
        }
        tailLLM = Task { _ = try? await work.value }
        return try await work.value
    }

    private func residentLanguageModel(for backend: LLMBackendID) async throws -> any LanguageModel {
        if let residentLLM, residentLLM.backend == backend { return residentLLM.model }
        guard languageProvider != nil else { throw EngineError.languageProviderUnavailable }
        // Serialize the load against any other in-flight load (LLM or TTS).
        let previous = loadGate
        let work = Task<any LanguageModel, Error> { [self] in
            _ = await previous?.value
            return try await self.loadLLM(backend)
        }
        loadGate = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Actor-isolated load body — re-checks residency after the load-gate wait
    /// (another waiter may have just loaded the same backend) then loads + stores.
    private func loadLLM(_ backend: LLMBackendID) async throws -> any LanguageModel {
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
        let previous = tailTTS
        let work = Task<Void, Error> { [self] in
            await previous?.value
            _ = try await self.residentModel(for: backend)
        }
        tailTTS = Task { _ = try? await work.value }
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

        // Chain synths against each other (never two synths at once), but NOT against
        // chats — a track-select runs concurrently with this synth (see tailLLM/tailTTS).
        let previous = tailTTS
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
        tailTTS = Task { _ = try? await work.value }
        return try await work.value
    }

    private func residentModel(for backend: BackendID) async throws -> any SpeechModel {
        if let resident, resident.backend == backend { return resident.model }
        // Serialize the load against any other in-flight load (LLM or TTS).
        let previous = loadGate
        let work = Task<any SpeechModel, Error> { [self] in
            _ = await previous?.value
            return try await self.loadSpeech(backend)
        }
        loadGate = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Actor-isolated load body — re-checks residency after the load-gate wait, loads + stores.
    private func loadSpeech(_ backend: BackendID) async throws -> any SpeechModel {
        if let resident, resident.backend == backend { return resident.model }
        unload()
        let model = try await provider.loadModel(backend: backend)
        resident = (backend, model)
        return model
    }
}
