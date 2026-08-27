import Foundation

/// Enforces at-most-one resident TTS model across a set of engines.
///
/// Each `GloamEngine` already keeps a single TTS model resident; nothing
/// coordinates residency BETWEEN engines, so an app running a main engine and
/// a parallel chat-speech engine can end up with two full model copies in
/// memory. Callers invoke `willUse(_:)` before queuing render work on an
/// engine; every OTHER engine's TTS model is evicted.
///
/// Eviction is TTS-scoped (`evictTTSWhenIdle`), NOT a full `quiesce()`: an
/// active chat stream parks its whole task on the peer's tail for the entire
/// LLM reply, and waiting on that would stall the first spoken sentence until
/// generation finished — defeating the parallel-speech engine's purpose.
///
/// Whole `willUse` invocations are serialized through a task chain so actor
/// reentrancy can't interleave two hand-offs (evicting an engine after its
/// caller already re-queued work). Deadlock safety: `willUse` must be called
/// BEFORE the caller queues its own work on the target engine, and
/// `evictTTSWhenIdle` waits only on in-flight TTS work — which never waits on
/// this actor — so the chain always drains.
public actor TTSResidencyPolicy {
    private let engines: [GloamEngine]
    private var tail: Task<Void, Never>?

    public init(engines: [GloamEngine]) {
        self.engines = engines
    }

    /// Evict the TTS model from every engine except `engine`, waiting for any
    /// in-flight TTS generation on each peer so nothing is evicted mid-render.
    public func willUse(_ engine: GloamEngine) async {
        let previous = tail
        let work = Task { [engines] in
            await previous?.value
            for other in engines where other !== engine {
                await other.evictTTSWhenIdle()
            }
        }
        tail = work
        await work.value
    }
}
