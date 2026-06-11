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

    public init(provider: ModelProviding) {
        self.provider = provider
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
