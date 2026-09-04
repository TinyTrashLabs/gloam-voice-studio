import EngineKit
import Foundation
import Observation
import StudioKit

/// Dialogue-mode state: the two speakers, their turns, the Dia2 controls, and
/// the take that comes out.
///
/// Kept apart from `ScriptModel` on purpose. Script mode is a list of lines
/// that each become their own take; a dialogue is one exchange that Dia2
/// renders whole, and its unit of work is a *pass*, not a line. Sharing a model
/// between the two would mean one of them lying about what a row is.
@MainActor @Observable
final class DialogueComposer {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// 1 or 2 — Dia2 has exactly two speaker tokens.
        var speaker: Int
        var text: String = ""
    }

    /// What a speaker's voice can contribute to the pass. A voice with no
    /// recorded reference is `unconditioned`, not `failed`: Dia2 renders it
    /// fine, the voice simply varies between takes. Saying so up front is the
    /// whole point of preparing eagerly.
    enum PrefixState: Equatable {
        case empty
        case preparing
        case ready(words: Int, seconds: Double)
        case unconditioned(String)
        case failed(String)
    }

    var turns: [Turn] = [Turn(speaker: 1), Turn(speaker: 2)]
    /// Index 0 is speaker 1, index 1 is speaker 2.
    var voices: [String?] = [nil, nil]
    private(set) var prefixStates: [PrefixState] = [.empty, .empty]

    // MARK: controls
    //
    // Defaults are the checkpoint's own, except CFG: 6 is what the measured
    // renders held their voice at. Below ~4 the take drifts off the reference;
    // above ~8 it clips and shouts.
    var cfgScale: Float = 6
    var textTemperature: Float = 0.8
    var textTopK: Int = 40
    var audioTemperature: Float = 0.9
    var audioTopK: Int = 50
    var maxPadding: Int = 4
    /// Debug aid: prepends the conditioning clips to the take so you can hear
    /// exactly what the model was given. Never right for a shipped take.
    var keepPrefixAudio = false

    // MARK: take
    var isGenerating = false
    /// "Pass 2 of 4" while rendering, nil otherwise.
    var progress: String?
    var error: String?
    /// Non-fatal things the user needs told about the take they just got.
    var notes: [String] = []
    var takeWAV: Data?
    var takeSeconds: Double = 0
    var takeWallSeconds: Double = 0

    unowned let app: AppModel
    /// Cached prefixes by slug, so re-picking a voice does not realign it.
    private var prefixes: [String: DialoguePrefix] = [:]
    private var prepareTasks: [Int: Task<Void, Never>] = [:]

    init(app: AppModel) { self.app = app }

    // MARK: composition

    func addTurn() {
        // Alternating is what a dialogue is; the picker can still override it.
        let next = turns.last.map { $0.speaker == 1 ? 2 : 1 } ?? 1
        turns.append(Turn(speaker: next))
    }

    func removeTurn(_ id: UUID) { turns.removeAll { $0.id == id } }

    /// Swap a turn with its neighbour. Reordering matters because a seam only
    /// lands where the speaker changes — moving a turn moves the seam.
    func moveTurn(at index: Int, by offset: Int) {
        let target = index + offset
        guard turns.indices.contains(index), turns.indices.contains(target) else { return }
        turns.swapAt(index, target)
    }

    /// The script as the planner sees it. `speakerID` is the S1/S2 tag rather
    /// than the voice slug, so an exchange with no voices assigned still has
    /// turn boundaries for a seam to land on.
    var lines: [DialogueLine] {
        turns.enumerated().compactMap { index, turn in
            guard !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return DialogueLine(index: index,
                                voiceSlug: voices[safe: turn.speaker - 1] ?? nil,
                                text: turn.text,
                                speakerID: "S\(turn.speaker)")
        }
    }

    /// How many passes this will take, where the seams fall, and how long each
    /// pass runs — shown before generating, because after is too late.
    var report: SceneReport { DialoguePlanner.report(for: lines) }

    // MARK: voices

    func setVoice(_ slug: String?, forSpeaker speaker: Int) {
        let index = speaker - 1
        guard voices.indices.contains(index) else { return }
        voices[index] = slug
        prepare(speaker: speaker)
    }

    /// Resolve a speaker's conditioning clip NOW, not at Generate.
    ///
    /// Aligning a `.gvoice` pulls in the transcriber and takes real time the
    /// first time. Doing it lazily means the user writes a whole scene, hits
    /// Generate, and only then finds out this voice has no word timings — so
    /// it happens the moment they pick the voice, with the wait shown.
    func prepare(speaker: Int) {
        let index = speaker - 1
        guard prefixStates.indices.contains(index) else { return }
        prepareTasks[speaker]?.cancel()
        guard let slug = voices[index] else {
            prefixStates[index] = .empty
            return
        }
        if let cached = prefixes[slug] {
            prefixStates[index] = state(for: cached)
            return
        }
        prefixStates[index] = .preparing
        prepareTasks[speaker] = Task {
            let rate = Double(BackendID.dia2.spec.defaultSampleRate)
            do {
                let prefix = try await app.dialoguePrefix(
                    for: slug, aligner: await app.makeAligner(), rate: rate)
                guard !Task.isCancelled else { return }
                prefixes[slug] = prefix
                prefixStates[index] = state(for: prefix)
            } catch let error as Dia2AlignmentError {
                guard !Task.isCancelled else { return }
                // No reference clip is a fact about the voice, not a failure:
                // Dia2 will speak the lines, it just invents the voice.
                prefixStates[index] = .unconditioned(error.localizedDescription)
            } catch {
                guard !Task.isCancelled else { return }
                prefixStates[index] = .failed(app.describeAny(error))
            }
        }
    }

    private func state(for prefix: DialoguePrefix) -> PrefixState {
        guard !prefix.words.isEmpty else {
            return .unconditioned("No word timings for this clip, so it conditions nothing — "
                                  + "the voice will vary between takes.")
        }
        let rate = Double(BackendID.dia2.spec.defaultSampleRate)
        return .ready(words: prefix.words.count,
                      seconds: Double(prefix.samples.count) / rate)
    }

    // MARK: generation

    /// Renders the exchange, one Dia2 pass per planned scene, and joins the
    /// passes end to end.
    ///
    /// Each pass re-conditions from the original reference audio, which is
    /// exactly why splitting is worth its seam: drift resets at every seam
    /// instead of accumulating across the whole scene.
    func generate() async {
        guard !isGenerating else { return }
        error = nil; notes = []
        let script = lines
        guard !script.isEmpty else {
            error = "Nothing to say — write a line first."
            return
        }
        guard app.downloads.state(for: .dia2) == .ready else {
            error = "Download the dia2 model in Settings → Models first."
            return
        }

        isGenerating = true
        defer { isGenerating = false; progress = nil }

        // Prefixes must be indexed by SPEAKER, not by order of appearance: a
        // pass that happens to open on speaker 2 would otherwise hand Dia2 the
        // wrong voice for both of them.
        var pass: [DialoguePrefix?] = voices.map { $0.flatMap { prefixes[$0] } }
        // Dia2 cannot condition speaker 2 alone, so a missing first prefix
        // drops the second rather than misassigning it.
        if (pass.first ?? nil) == nil {
            if pass.contains(where: { $0 != nil }) {
                notes.append("Speaker 1 has no conditioning clip, so speaker 2's was dropped "
                             + "too — Dia2 cannot condition the second voice alone.")
            }
            pass = pass.map { _ in nil }
        }

        let scenes = DialoguePlanner.scenes(for: script)
        let tags = Set((try? await app.engine.nonverbalTags(backend: .dia2)) ?? [])
        let rate = BackendID.dia2.spec.defaultSampleRate
        var samples: [Float] = []
        let started = Date()

        do {
            for (number, scene) in scenes.enumerated() {
                progress = "Pass \(number + 1) of \(scenes.count)"
                let sceneTurns = scene.lines.map {
                    DialogueTurn(speaker: turns[$0].speaker, text: turns[$0].text)
                }
                let request = DialogueRequest(
                    turns: sceneTurns, voices: voices,
                    cfgScale: cfgScale,
                    textTemperature: textTemperature, textTopK: textTopK,
                    audioTemperature: audioTemperature, audioTopK: audioTopK,
                    maxPadding: maxPadding, keepPrefixAudio: keepPrefixAudio)
                let text = try DialoguePlanner.script(for: request, knownTags: tags)
                // Must precede queuing work on `engine` (see
                // TTSResidencyPolicy's deadlock-safety contract).
                await app.ttsResidency.willUse(app.engine)
                let chunk = try await app.engine.synthesizeDialogue(
                    backend: .dia2,
                    request: ProviderDialogueRequest(request, script: text, prefixes: pass))
                samples.append(contentsOf: chunk.samples)
            }
        } catch {
            self.error = app.describeAny(error)
            await app.refreshEngineStatus()
            return
        }

        let wall = Date().timeIntervalSince(started)
        let levelled = AudioAssembler.normalizePeak(floats: samples)
        takeWAV = WAVEncoder.encode(pcm16: PCM16.data(from: levelled), sampleRate: rate)
        takeSeconds = Double(levelled.count) / Double(rate)
        takeWallSeconds = wall
        app.recordTTSSpeed(backend: .dia2, audioSeconds: takeSeconds, wallSeconds: wall)
        if scenes.count > 1 {
            notes.append("Rendered in \(scenes.count) passes. Each pass starts from the "
                         + "reference again, so the seams are where the voices reset.")
        }
        await app.refreshEngineStatus()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
