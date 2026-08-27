import Foundation

/// Enforces at-most-one resident TTS model across a set of engines.
///
/// Each `GloamEngine` already keeps a single TTS model resident; nothing
/// coordinates residency BETWEEN engines, so an app running a main engine and
/// a parallel chat-speech engine can end up with two full model copies in
/// memory. Callers invoke `willUse(_:)` before queuing render work on an
/// engine; every OTHER engine is quiesced (in-flight work drains) and evicted.
///
/// Deadlock safety: `willUse` must be called BEFORE the caller queues its own
/// work on the target engine — an engine's task tail therefore never contains
/// work that is itself waiting on this actor, so quiescing a peer from here
/// cannot wait on ourselves. Concurrent first-use of two engines can leave a
/// brief two-resident window (both loads already queued); the next `willUse`
/// restores the single-resident steady state.
public actor TTSResidencyPolicy {
    private let engines: [GloamEngine]

    public init(engines: [GloamEngine]) {
        self.engines = engines
    }

    /// Evict the TTS model from every engine except `engine`, waiting for
    /// each peer's queued work to drain first so nothing is evicted
    /// mid-generation.
    public func willUse(_ engine: GloamEngine) async {
        for other in engines where other !== engine {
            guard await other.loadedBackend() != nil else { continue }
            await other.quiesce()
            await other.unload()
        }
    }
}
