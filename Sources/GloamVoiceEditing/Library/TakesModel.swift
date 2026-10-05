import Foundation
import Combine

/// What the takes tell the editor: whether Save has work to do (the master
/// is stale), what stops it if anything does, and how much there is.
public struct TakesState: Equatable {
    public var stale = false
    public var blocker: String?
    public var count = 0
    public var combinedSeconds = 0.0
}

/// The takes of one voice as the editor sees them, shared by the basic
/// screen (a record button and a count line) and the Advanced screen (the
/// full list). Adds, deletes and transcript edits land on disk at once (a
/// take is not something to lose to a missed Save); hygiene is measured
/// off the main thread and published as it arrives.
@MainActor
public final class TakesModel: ObservableObject {
    @Published public private(set) var book = VoiceTakes()
    @Published public private(set) var verdicts: [Int: TakeRules.Verdict] = [:]
    @Published public private(set) var masterSeconds: Double?
    @Published public var errorText: String?

    private var store: (any VoiceLibraryStore)?
    public private(set) var voice: Voice?

    public init() {}
    /// Two reloads close together start two measurements; only the latest
    /// may publish, or an older, shorter result could land last.
    private var measureGeneration = 0

    public var state: TakesState {
        let ordered = book.takes.compactMap { verdicts[$0.id] }
        let measured = ordered.count == book.takes.count
        return TakesState(
            stale: book.masterStale,
            blocker: book.masterStale
                ? (measured ? TakeRules.saveBlocker(verdicts: ordered, combinedSeconds: book.combinedSeconds) : "Checking the takes…")
                : nil,
            count: book.takes.count,
            combinedSeconds: book.combinedSeconds)
    }

    public func bind(store: any VoiceLibraryStore, voice: Voice) {
        self.store = store
        self.voice = voice
        reload()
    }

    public func reload() {
        guard let store, let voice else { return }
        book = store.takes(of: voice)
        measure()
        if book.takes.isEmpty, let master = store.masterURL(of: voice.slug) {
            Task.detached { [weak self] in
                let n = (try? VoiceAudio.loadWav24k(master).count) ?? 0
                await MainActor.run { self?.masterSeconds = Double(n) / Double(ClipImport.sampleRate) }
            }
        }
    }

    private func measure() {
        guard let store, let voice else { return }
        let ids = book.takes.map(\.id)
        let urls = Dictionary(uniqueKeysWithValues: ids.map { ($0, store.takeURL(of: voice.slug, id: $0)) })
        let known = verdicts
        measureGeneration += 1
        let generation = measureGeneration
        Task.detached { [weak self] in
            var out = known
            for id in ids where out[id] == nil {
                let samples = (try? VoiceAudio.loadWav24k(urls[id]!)) ?? []
                out[id] = TakeRules.verdict(for: RecordingCheck.measure(samples, sampleRate: ClipImport.sampleRate))
            }
            let kept = out.filter { ids.contains($0.key) }
            await MainActor.run {
                guard let self, self.measureGeneration == generation else { return }
                self.verdicts = kept
            }
        }
    }

    /// A recorded or imported clip joins the takes; the file in the temp
    /// directory has done its job once stored.
    public func add(_ clip: URL, _ text: String, origin: VoiceTake.Origin) {
        guard let store, let voice else { return }
        do {
            try store.addTake(to: voice, clip: clip, transcript: text, origin: origin)
            try? FileManager.default.removeItem(at: clip)
            errorText = nil
            reload()
        } catch { errorText = userMessage(for: error) }
    }

    public func delete(_ take: VoiceTake) {
        guard let store, let voice else { return }
        do { try store.deleteTake(from: voice, id: take.id); reload() }
        catch { errorText = userMessage(for: error) }
    }

    public func updateTranscript(_ take: VoiceTake, _ text: String) {
        guard let store, let voice else { return }
        do { try store.updateTake(of: voice, id: take.id, transcript: text); reload() }
        catch { errorText = userMessage(for: error) }
    }

    /// The master, rebuilt from the takes (Save). Throws what the store throws.
    public func rebuildMaster() throws {
        guard let store, let voice else { return }
        try store.rebuildMaster(of: voice)
        reload()
    }

    /// An edit pending in the editor's transcript field when the first take
    /// adopted the master rides into that take, so the rebuild keeps it.
    public func carryTranscriptIntoAdoptedMaster(_ edited: String) {
        guard let store, let voice, let first = book.takes.first, first.origin == .master else { return }
        try? store.updateTake(of: voice, id: first.id, transcript: edited)
        reload()
    }
}
