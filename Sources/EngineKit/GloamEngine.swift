import Foundation
import os
import VoiceFXKit

/// Residency + timing log: `log stream --predicate 'subsystem == "fm.gloam.studio"'`.
private let engineLog = Logger(subsystem: "fm.gloam.studio", category: "engine")

/// Owns model lifecycle: one model resident at a time, all model work
/// serialized through this actor (MLX streams/graphs are execution-context
/// bound — see SPIKE-RESULTS.md "silent failure when two models load").
public actor GloamEngine {
    /// All model work (loads, synthesis, chat) runs BELOW default priority.
    ///
    /// The engine shares a process with the gloam.fm shell's WKWebView, whose
    /// MusicKit playback it can starve: a sustained generation window pegged
    /// the process at ~108% CPU and stalled the player mid-song (a
    /// non-deliberate waiting(8) underrun whose recovery seam is the audible
    /// pop — gloam-dj #297, measured 2026-08-22). Utility keeps the scheduler
    /// favoring the audio/media pipeline under pressure.
    ///
    /// CAVEAT (priority escalation): awaiting these tasks from a
    /// higher-priority task boosts them back up for the wait's duration, so
    /// callers that care (the loopback API routes) must themselves run at
    /// utility — see StudioKit's APIRouter.
    public static let modelWorkPriority: TaskPriority = .utility
    private let provider: ModelProviding
    private var resident: (backend: BackendID, model: any SpeechModel)?
    private var ackedLicenses: Set<BackendID> = []
    /// Serializes all model work (loads + generations). Actors are reentrant at
    /// await points, so without this two synthesize calls could interleave and
    /// run concurrent GPU work.
    private var tail: Task<Void, Never>?
    private let languageProvider: LanguageModelProviding?
    private var residentLLM: (backend: LLMBackendID, model: any LanguageModel)?

    /// What each resident model actually cost, keyed by backend rawValue and
    /// measured as the process-footprint delta across its own load. Recorded
    /// HERE rather than at the call site so every path is covered -- picker
    /// preload, first Generate, an API request, a bake. Dropped on eviction:
    /// a model that isn't resident isn't costing anything.
    private var measured: [String: Int64] = [:]

    public func measuredFootprints() -> [String: Int64] { measured }

    /// Records `key`'s cost if the load actually grew the footprint. A flat or
    /// negative delta means something was freed in the same window (a peer
    /// engine evicting, or the allocator returning pages); recording that would
    /// be worse than recording nothing.
    private func record(_ key: String, from before: Int64) {
        let delta = footprint() - before
        if delta > 50_000_000 { measured[key] = delta }
    }

    /// `footprint` is injectable so load measurement can be tested without
    /// depending on process-global memory -- two tests each allocating and
    /// freeing hundreds of megabytes interleave, and one test's free lands
    /// inside another's measurement window.
    public init(provider: ModelProviding,
                languageProvider: LanguageModelProviding? = nil,
                footprint: @escaping @Sendable () -> Int64 = { ProcessFootprint.bytes() }) {
        self.provider = provider
        self.languageProvider = languageProvider
        self.footprint = footprint
    }

    private let footprint: @Sendable () -> Int64

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
        guard let resident else { return }
        engineLog.log("unload TTS \(resident.backend.rawValue, privacy: .public)")
        measured[resident.backend.rawValue] = nil
        self.resident = nil
        provider.didEvictModel()
    }

    /// Evicts the resident TTS model as soon as no TTS work is executing —
    /// without waiting for the rest of the task tail. `quiesce()` drains
    /// EVERYTHING, including an active chat stream whose task parks on `tail`
    /// for the whole LLM reply; TTS eviction must not wait on that (it is
    /// exactly what a cross-engine residency hand-off does mid-stream).
    public func evictTTSWhenIdle() async {
        while ttsBusy {
            await withCheckedContinuation { ttsIdleWaiters.append($0) }
        }
        unload()
    }

    /// True while a TTS load or generation is executing (`performSynthesis`,
    /// including its implicit model load). LLM work never sets this.
    private var ttsBusy = false
    private var ttsIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private func ttsWorkEnded() {
        ttsBusy = false
        let waiters = ttsIdleWaiters
        ttsIdleWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    public func loadedLLM() -> LLMBackendID? { residentLLM?.backend }

    /// Evicts the resident language model and releases accelerator memory.
    public func unloadLLM() {
        guard let residentLLM else { return }
        engineLog.log("unload LLM \(residentLLM.backend.rawValue, privacy: .public)")
        measured[residentLLM.backend.rawValue] = nil
        self.residentLLM = nil
        languageProvider?.didEvictModel()
    }

    public func chat(backend: LLMBackendID, request: ChatRequest) async throws -> ChatResult {
        guard languageProvider != nil else { throw EngineError.languageProviderUnavailable }
        let previous = tail
        let work = Task<ChatResult, Error>(priority: Self.modelWorkPriority) { [self] in
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
        let work = Task(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            chatStreamActive = true
            engineLog.log("chat stream begin (\(backend.rawValue, privacy: .public))")
            do {
                let model = try await self.residentLanguageModel(for: backend)
                try await model.pacedStream(request) { event in
                    continuation.yield(event)
                    await self.drainInterleaved(settling: model)
                }
                chatStreamActive = false
                // A sentence queued between the last delta and finish must not
                // strand its waiter — run leftovers while we still hold the tail.
                await self.drainInterleaved(settling: model)
                engineLog.log("chat stream end")
                continuation.finish()
            } catch {
                chatStreamActive = false
                await self.drainInterleaved(settling: self.residentLLM?.model)
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
    private var pendingInterleavedStreams:
        [(backend: BackendID, request: SynthesisRequest,
          continuation: AsyncThrowingStream<SynthesisChunk, Error>.Continuation)] = []

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

    /// Streaming counterpart to `synthesizeInterleaved`. During a chat stream,
    /// its chunks are produced in the next between-token GPU gap. With no chat
    /// active it uses the ordinary serialized streaming path.
    public func synthesizeStreamInterleaved(backend: BackendID, request: SynthesisRequest)
        -> AsyncThrowingStream<SynthesisChunk, Error>
    {
        guard chatStreamActive else {
            return synthesizeStream(backend: backend, request: request)
        }
        let (stream, continuation) = AsyncThrowingStream<SynthesisChunk, Error>.makeStream()
        pendingInterleavedStreams.append((backend, request, continuation))
        return stream
    }

    /// Test hook: how many interleaved requests are queued right now.
    func _pendingInterleavedCount() -> Int {
        pendingInterleaved.count + pendingInterleavedStreams.count
    }

    /// Runs every queued interleaved synthesis. Called from the chat stream's
    /// tail task between deltas (and once after the stream ends), so it is
    /// already serialized with all other GPU work. `settling` is asked to
    /// finish any computation it pipelined ahead (MLX evals the next token
    /// speculatively) before TTS work touches the GPU — but only when there
    /// is actually work queued, preserving the pipelining win otherwise.
    private func drainInterleaved(settling model: (any LanguageModel)? = nil) async {
        guard !pendingInterleaved.isEmpty || !pendingInterleavedStreams.isEmpty else { return }
        await model?.awaitPendingComputation()
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
        while !pendingInterleavedStreams.isEmpty {
            let item = pendingInterleavedStreams.removeFirst()
            do {
                try await performSynthesisStream(
                    backend: item.backend,
                    request: item.request,
                    continuation: item.continuation)
                item.continuation.finish()
            } catch {
                item.continuation.finish(throwing: error)
            }
        }
    }

    /// Load `backend` into LLM residency without generating -- the LLM analog of
    /// `preload(backend:)`. Without this the chat model only loads on the first
    /// reply, so the app cannot show a real "loaded" state (or measure what the
    /// load actually costs) until the user has already sent a message.
    public func preloadLLM(backend: LLMBackendID) async throws {
        let previous = tail
        let work = Task<Void, Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            _ = try await self.residentLanguageModel(for: backend)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    private func residentLanguageModel(for backend: LLMBackendID) async throws -> any LanguageModel {
        if let residentLLM, residentLLM.backend == backend { return residentLLM.model }
        guard let languageProvider else { throw EngineError.languageProviderUnavailable }
        unloadLLM()
        let start = Date()
        let footprintBefore = footprint()
        engineLog.log("loading LLM \(backend.rawValue, privacy: .public)…")
        let model = try await languageProvider.loadModel(backend: backend)
        engineLog.log("loaded LLM \(backend.rawValue, privacy: .public) in \(String(format: "%.1f", Date().timeIntervalSince(start)), privacy: .public)s")
        residentLLM = (backend, model)
        record(backend.rawValue, from: footprintBefore)
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
        let work = Task<Void, Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            self.ttsBusy = true
            defer { self.ttsWorkEnded() }
            _ = try await self.residentModel(for: backend)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Two voices in one pass. Serialised through the same tail chain as
    /// `synthesize`, because it is the same GPU.
    public func synthesizeDialogue(backend: BackendID, request: ProviderDialogueRequest)
        async throws -> DialogueChunk
    {
        let previous = tail
        let work = Task<DialogueChunk, Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            self.ttsBusy = true
            defer { self.ttsWorkEnded() }
            let model = try await self.residentModel(for: backend)
            guard let dialogue = model as? any DialogueSpeechModel else {
                throw EngineError.generationFailed(
                    backend: backend,
                    message: "\(backend.rawValue) speaks one voice at a time — "
                        + "dialogue needs a two-speaker engine.")
            }
            return try await dialogue.synthesizeDialogue(request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// The nonverbal tags this backend actually knows. Clients render them as
    /// chips; free text would simply be read aloud, which is the whole reason
    /// the list has to come from the model rather than a hardcoded table.
    public func nonverbalTags(backend: BackendID) async throws -> [String] {
        let previous = tail
        let work = Task<[String], Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            let model = try await self.residentModel(for: backend)
            return (model as? any DialogueSpeechModel)?.nonverbalTags ?? []
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Opens a streaming dialogue session. The load is serialised; the session
    /// itself then runs on its own, so `append` can keep feeding it script
    /// while audio is already flowing.
    public func openDialogueSession(backend: BackendID, request: ProviderDialogueRequest)
        async throws -> any DialogueStreaming
    {
        let previous = tail
        let work = Task<any DialogueStreaming, Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            let model = try await self.residentModel(for: backend)
            guard let dialogue = model as? any DialogueSpeechModel else {
                throw EngineError.generationFailed(
                    backend: backend,
                    message: "\(backend.rawValue) speaks one voice at a time — "
                        + "dialogue needs a two-speaker engine.")
            }
            return try dialogue.openDialogueSession(request)
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
        let work = Task<SynthesisResult, Error>(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            return try await self.performSynthesis(backend: backend, request: request)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// Streams independently playable chunks while preserving the engine's
    /// single-model-work invariant. Backends without native streaming inherit
    /// `SpeechModel`'s one-chunk fallback.
    public func synthesizeStream(backend: BackendID, request: SynthesisRequest)
        -> AsyncThrowingStream<SynthesisChunk, Error>
    {
        let (stream, continuation) = AsyncThrowingStream<SynthesisChunk, Error>.makeStream()
        if backend.spec.needsLicenseAck && !ackedLicenses.contains(backend) {
            continuation.finish(throwing: EngineError.licenseAckRequired(backend))
            return stream
        }

        let previous = tail
        let work = Task(priority: Self.modelWorkPriority) { [self] in
            await previous?.value
            do {
                try await self.performSynthesisStream(
                    backend: backend, request: request, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        tail = Task { _ = await work.value }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    private func performSynthesisStream(
        backend: BackendID,
        request: SynthesisRequest,
        continuation: AsyncThrowingStream<SynthesisChunk, Error>.Continuation
    ) async throws {
        // Whole-take post processing is not chunk-safe. Preserve its exact
        // behavior and expose one final chunk until those processors gain
        // stateful streaming implementations.
        if request.speed != 1 || request.fx != nil {
            let result = try await performSynthesis(backend: backend, request: request)
            continuation.yield(SynthesisChunk(
                samples: result.samples, sampleRate: result.sampleRate))
            return
        }

        ttsBusy = true
        defer { ttsWorkEnded() }
        let plan = try RequestPlanner.plan(backend: backend, request: request)
        let model = try await residentModel(for: backend)
        let start = Date()
        var sampleCount = 0
        // A capped backend's long line streams piece by piece: the first
        // sentence group plays while the rest render.
        try await renderPasses(of: plan, backend: backend, model: model, streaming: true) { samples in
            sampleCount += samples.count
            continuation.yield(SynthesisChunk(samples: samples, sampleRate: model.sampleRate))
        }
        let wall = Date().timeIntervalSince(start)
        engineLog.log("synth stream \(request.text.count, privacy: .public) chars → \(String(format: "%.2f", Double(sampleCount) / Double(model.sampleRate)), privacy: .public)s audio in \(String(format: "%.1f", wall), privacy: .public)s")
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
        ttsBusy = true
        defer { ttsWorkEnded() }
        let plan = try RequestPlanner.plan(backend: backend, request: request)
        let model = try await self.residentModel(for: backend)
        let start = Date()
        let raw: [Float]
        if backend.surfaces.contains(.dialogue), let dialogue = model as? any DialogueSpeechModel {
            // A two-speaker engine asked for one line still goes through the
            // dialogue entry point, because that is the ONLY one that accepts a
            // word-aligned prefix. `SpeechModel.synthesize` would run the pass
            // unconditioned and hand back a stranger's voice under the selected
            // voice's name — the exact failure the app refuses everywhere else.
            let script = try DialoguePlanner.script(
                for: DialogueRequest(turns: [DialogueTurn(speaker: 1, text: plan.text)],
                                     voices: []),
                knownTags: [])
            let chunk = try await dialogue.synthesizeDialogue(ProviderDialogueRequest(
                script: script,
                prefixes: [request.dialoguePrefix],
                // Temperature and topK come from the request's knobs. CFG scale
                // does too when a caller sets one; the app's bench only sends
                // its CFG slider for Breeze (the Dialogue composer owns Dia2's),
                // so nil here keeps the model default rather than a
                // silently-zero override.
                temperature: plan.temperature, topK: plan.topK, cfgScale: plan.cfgScale))
            raw = chunk.samples
        } else {
            var joined: [Float] = []
            try await renderPasses(of: plan, backend: backend, model: model, streaming: false) {
                joined.append(contentsOf: $0)
            }
            raw = joined
        }
        let wall = Date().timeIntervalSince(start)
        engineLog.log("synth \(request.text.count, privacy: .public) chars → \(String(format: "%.2f", Double(raw.count) / Double(model.sampleRate)), privacy: .public)s audio in \(String(format: "%.1f", wall), privacy: .public)s")
        // If the plan carries a native `speed` (LuxTTS: applied inside the
        // flow-matching duration conditioning), the provider already handled it —
        // skip the generic post-hoc resample so speed isn't applied twice.
        let postHocSpeed = plan.speed != nil ? 1.0 : request.speed
        var samples = SpeedAdjust.apply(raw, speed: postHocSpeed)
        if let preset = request.fx {
            // Effects run after the speed resample so a preset's tuning is not
            // altered by an unrelated `speed`. Driven through the same block
            // loop a chunked caller would use, so the offline result cannot
            // drift from the streamed one.
            let chain = FXChain.make(from: preset)
            chain.prepare(sampleRate: Double(model.sampleRate), maxBlock: 4096)
            // Compensate for the chain's declared latency (the pitch shifter's
            // ~120 ms) rather than letting a short/tightly-trimmed line lose
            // its tail: pad, flush, and trim back to the original length.
            samples = chain.applyWholeLatencyCompensated(samples)
            engineLog.log("fx \(preset.name, privacy: .public) applied, latency \(chain.latencyFrames, privacy: .public) frames")
        }
        return SynthesisResult(
            samples: samples,
            sampleRate: model.sampleRate,
            wallSeconds: wall)
    }

    /// `plan` as the generation calls it needs: one, or — for a backend whose
    /// per-call cap a long line would hit (`maxSecondsPerPass`) — one per
    /// sentence group, each carrying the same voice, direction and knobs.
    /// Pieces target two thirds of the cap, leaving room for a slow Direction.
    /// When later passes will clone the first (`needsIdentityAnchor`), the
    /// first pass is only the opening sentences (~`anchorSeconds`, but never
    /// less than the whole first sentence when it fits a piece): that
    /// audio becomes the reference, and a short clean clip clones better and
    /// faster than a 40 s one.
    static func passes(of plan: ProviderRequest, backend: BackendID) -> [ProviderRequest] {
        guard let cap = backend.maxSecondsPerPass else { return [plan] }
        let budget = cap * 2 / 3
        var pieces = LongTextChunker.chunks(plan.text, maxSeconds: budget)
        guard pieces.count > 1 else { return [plan] }
        if needsIdentityAnchor(plan, backend: backend),
           var opening = LongTextChunker.chunks(plan.text, maxSeconds: anchorSeconds).first {
            let text = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never end the anchor mid-sentence: a first sentence past the
            // anchor target but within a piece stays whole. Cutting it would
            // put a gap mid-sentence and hand every later pass a reference
            // that stops mid-phrase, which a continuation model carries into
            // each seam.
            if let first = LongTextChunker.sentences(text).first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               first.count > opening.count,
               LongTextChunker.estimatedSeconds(first) <= budget {
                opening = first
            }
            // Chunks and sentences are exact prefixes of the trimmed text, so
            // the rest is what follows the opening.
            pieces = [opening] + LongTextChunker.chunks(
                String(text.dropFirst(opening.count)), maxSeconds: budget)
        }
        return pieces.map { var piece = plan; piece.text = $0; return piece }
    }

    /// Target length of an anchoring first pass (see `passes(of:backend:)`).
    static let anchorSeconds: Double = 12

    /// The breath between pieces of a split line: 150 ms of silence.
    static func passGap(sampleRate: Int) -> [Float] {
        [Float](repeating: 0, count: sampleRate * 15 / 100)
    }

    /// Renders `plan`'s passes in order, handing audio to `emit` as it comes
    /// (per streamed chunk when `streaming`, per pass otherwise) with a
    /// `passGap` between passes. One pass is exactly the old single call.
    ///
    /// Two things only a multi-pass line needs:
    /// - Cancellation is checked before every later pass. A cancelled
    ///   `AsyncThrowingStream` ends quietly rather than throwing, so without
    ///   this each remaining pass would still start — and the default
    ///   `synthesizeStream` runs its pass in a Task nobody cancels — leaving
    ///   several generations racing on one model after the engine went idle.
    /// - Identity is anchored. A pass with no reference (Breeze designing
    ///   from a Direction) invents a new speaker every call, so the first
    ///   pass's audio — written to a temporary WAV, with its text as the
    ///   transcript — becomes the reference for the rest, which keep the
    ///   Direction: one designed voice for the whole line.
    private func renderPasses(
        of plan: ProviderRequest, backend: BackendID, model: any SpeechModel,
        streaming: Bool, emit: ([Float]) -> Void
    ) async throws {
        var passes = Self.passes(of: plan, backend: backend)
        var anchor: URL?
        defer { if let anchor { try? FileManager.default.removeItem(at: anchor) } }
        for index in passes.indices {
            if index > 0 {
                try Task.checkCancellation()
                emit(Self.passGap(sampleRate: model.sampleRate))
            }
            var rendered: [Float] = []
            if streaming {
                for try await samples in model.synthesizeStream(passes[index]) {
                    try Task.checkCancellation()
                    guard !samples.isEmpty else { continue }
                    if index == 0 && passes.count > 1 { rendered.append(contentsOf: samples) }
                    emit(samples)
                }
            } else {
                rendered = try await model.synthesize(passes[index])
                emit(rendered)
            }
            if index == 0, passes.count > 1, Self.needsIdentityAnchor(plan, backend: backend) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-pass-anchor-\(UUID().uuidString).wav")
                try WAVWriter.write(samples: rendered, sampleRate: model.sampleRate, to: url)
                anchor = url
                for later in passes.indices.dropFirst() {
                    passes[later].refAudioPath = url.path
                    passes[later].refText = passes[0].text
                }
            }
        }
    }

    /// Whether later passes must clone the first one to keep one speaker:
    /// no reference of its own, on a backend that can take one.
    static func needsIdentityAnchor(_ plan: ProviderRequest, backend: BackendID) -> Bool {
        plan.refAudioPath == nil && backend.controls.voiceClone != .none
    }

    private func residentModel(for backend: BackendID) async throws -> any SpeechModel {
        if let resident, resident.backend == backend {
            return resident.model
        }
        unload()
        let start = Date()
        let footprintBefore = footprint()
        engineLog.log("loading TTS \(backend.rawValue, privacy: .public)…")
        let model = try await provider.loadModel(backend: backend)
        engineLog.log("loaded TTS \(backend.rawValue, privacy: .public) in \(String(format: "%.1f", Date().timeIntervalSince(start)), privacy: .public)s")
        resident = (backend, model)
        record(backend.rawValue, from: footprintBefore)
        return model
    }
}
