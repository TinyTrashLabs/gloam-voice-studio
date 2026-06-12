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

    private let store: SessionStore
    private unowned let app: AppModel

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
        guard let line = session.lines.first(where: { $0.id == lineID }) else { return }
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
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pending.forEach { status[$0.id] = .queued }
        for line in pending {
            await generate(lineID: line.id)
        }
    }

    // MARK: export assembly

    /// Best take per line: starred, else newest. Lines with no takes are skipped.
    func exportPCMs() -> (pcms: [Data], sampleRate: Int)? {
        var pcms: [Data] = []
        var rate = 0
        for line in session.lines {
            let take = line.takes.first { $0.id == line.starredTakeID }
                ?? line.takes.last
            guard let take, let pcm = try? store.takePCM(take.id) else { continue }
            pcms.append(Data(pcm))
            rate = take.sampleRate
        }
        return pcms.isEmpty ? nil : (pcms, rate)
    }
}
