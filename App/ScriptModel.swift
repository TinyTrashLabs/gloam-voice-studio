import EngineKit
import Foundation
import Observation
import StudioKit

/// Script-mode state: lines, takes, batch generation. Generation requests run
/// through the same GloamEngine actor (which serializes GPU work), one line at
/// a time, updating per-line status as the queue advances.
@MainActor @Observable
final class ScriptModel {
    enum LineStatus: Equatable { case idle, queued, generating, failed(String) }

    private(set) var session: ScriptSession
    private(set) var status: [UUID: LineStatus] = [:]
    var isBatchRunning = false

    let store: SessionStore
    unowned let app: AppModel

    init(app: AppModel, store: SessionStore) {
        self.app = app
        self.store = store
        self.session = store.load()
    }

    // MARK: line edits (all autosave)

    func addLine() {
        session.lines.append(ScriptLine(text: ""))
        autosave()
    }

    /// A beat of silence between lines. It generates nothing — it is spent at
    /// export, where the gap actually has to exist.
    func addPause(seconds: Double = 1.0) {
        session.lines.append(ScriptLine(text: "", kind: .pause(seconds: seconds)))
        autosave()
    }

    func removeLine(_ id: UUID) {
        if let line = session.lines.first(where: { $0.id == id }) {
            line.takes.forEach { store.deleteTake($0.id) }
        }
        session.lines.removeAll { $0.id == id }
        autosave()
    }

    func moveLines(from source: IndexSet, to destination: Int) {
        session.lines.move(fromOffsets: source, toOffset: destination)
        autosave()
    }

    func update(_ id: UUID, _ mutate: (inout ScriptLine) -> Void) {
        guard let i = session.lines.firstIndex(where: { $0.id == id }) else { return }
        mutate(&session.lines[i])
        autosave()
    }

    func star(_ lineID: UUID, takeID: String) {
        update(lineID) { $0.starredTakeID = takeID }
    }

    func deleteTake(_ lineID: UUID, takeID: String) {
        store.deleteTake(takeID)
        update(lineID) { line in
            line.takes.removeAll { $0.id == takeID }
            if line.starredTakeID == takeID { line.starredTakeID = nil }
        }
    }

    func takeWavData(_ takeID: String) -> Data? {
        guard let url = try? store.takeWavURL(takeID) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func autosave() { try? store.save(session) }

    // MARK: generation

    func generate(lineID: UUID) async {
        guard let line = session.lines.first(where: { $0.id == lineID }),
              line.pauseSeconds == nil else { return }
        status[lineID] = .generating
        do {
            let result = try await app.synthesizeLine(
                text: line.text,
                voiceSlug: line.voiceSlug ?? app.selectedVoiceSlug,
                emotion: line.emotion.flatMap(Emotion.init(rawValue:)) ?? app.emotion,
                speed: line.speed ?? app.speed)
            let pcm = PCM16.data(from: result.samples)
            let take = try store.saveTake(pcm: pcm, sampleRate: result.sampleRate,
                                          wallSeconds: result.wallSeconds)
            update(lineID) { $0.takes.append(take) }
            status[lineID] = .idle
        } catch {
            status[lineID] = .failed(app.describeAny(error))
        }
    }

    func generateAll() async {
        guard !isBatchRunning else { return }
        isBatchRunning = true
        defer { isBatchRunning = false }
        let pending = session.lines.filter {
            $0.pauseSeconds == nil
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pending.forEach { status[$0.id] = .queued }
        for line in pending {
            await generate(lineID: line.id)
        }
    }

    // MARK: export assembly

    /// Best take per line: starred, else newest. Lines with no takes are skipped.
    func exportPCMs() -> (pcms: [Data], sampleRate: Int)? {
        // Silence can only be sized once a take has told us the rate, so the
        // pass collects intents first and materialises them after.
        enum Part { case audio(Data), silence(Double) }
        var parts: [Part] = []
        var rate = 0
        var spokeAnything = false
        for line in session.lines {
            if let seconds = line.pauseSeconds {
                parts.append(.silence(seconds))
                continue
            }
            let take = line.takes.first { $0.id == line.starredTakeID }
                ?? line.takes.last
            guard let take, let pcm = try? store.takePCM(take.id) else { continue }
            parts.append(.audio(Data(pcm)))
            rate = take.sampleRate
            spokeAnything = true
        }
        guard spokeAnything else { return nil }
        let pcms = parts.map { part -> Data in
            switch part {
            case .audio(let data): data
            case .silence(let seconds): Data(count: Int(Double(rate) * seconds) * 2)
            }
        }
        return (pcms, rate)
    }
}

// MARK: - Dialogue scenes

extension ScriptModel {
    /// Lines that have something to say, paired with the voice that will say
    /// it. Indices are positions in `session.lines`, so a scene split can be
    /// reported as a line number.
    var dialogueLines: [(index: Int, voiceSlug: String?)] {
        session.lines.enumerated().compactMap { index, line in
            guard line.pauseSeconds == nil,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (index, line.voiceSlug ?? app.selectedVoiceSlug)
        }
    }

    /// How many Dia2 passes this script needs, and where it breaks.
    var sceneReport: SceneReport { DialoguePlanner.report(for: dialogueLines) }

    func setStatus(_ ids: [UUID], _ status: LineStatus) {
        ids.forEach { self.status[$0] = status }
    }

    /// A whole scene renders as one take, hung off the line it starts at —
    /// splitting it back into per-line takes would cut the overlaps and
    /// turn-taking that are the reason to use Dia2 at all.
    func appendSceneTake(lineID: UUID, samples: [Float], sampleRate: Int,
                         wallSeconds: Double, voices: [String],
                         words: [ScriptWordTiming], note: String?) throws {
        let take = try store.saveTake(pcm: PCM16.data(from: samples),
                                      sampleRate: sampleRate, wallSeconds: wallSeconds,
                                      voices: voices, words: words, note: note)
        update(lineID) { $0.takes.append(take) }
    }
}
