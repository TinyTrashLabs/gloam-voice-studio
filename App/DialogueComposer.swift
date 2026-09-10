import EngineKit
import Foundation
import Observation
import OSLog
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
    // These are the reference implementation's own defaults -- text 0.6/50,
    // audio 0.8/50, max padding 6 -- and a Swift render at them matched a
    // Python render word for word (101 words, 34.7s vs 34.4s) on the same
    // script and prefixes. Diverging from them needs a reason and a listen.
    //
    // CFG is the one deliberate exception. The reference defaults to 2.0, but
    // with two prefixed speakers 2.0 produced a 17-second silence and then
    // repeated itself, and 3.0 collapsed into babble 30 seconds in. 6 held.
    // Each of those is a single observation, so treat the number as "6 works,
    // low values were seen to fail", not as a tuned optimum.
    private static let defaults = (
        cfgScale: Float(6), textTemperature: Float(0.6), textTopK: 50,
        audioTemperature: Float(0.8), audioTopK: 50, maxPadding: 6,
        keepPrefixAudio: false)

    var cfgScale: Float = DialogueComposer.defaults.cfgScale
    var textTemperature: Float = DialogueComposer.defaults.textTemperature
    var textTopK: Int = DialogueComposer.defaults.textTopK
    var audioTemperature: Float = DialogueComposer.defaults.audioTemperature
    var audioTopK: Int = DialogueComposer.defaults.audioTopK
    /// 6 is the reference's `StateMachine.max_padding`, not the checkpoint's
    /// `max_pad` of 8. Raising it to 8 stretched the same pass from 35s to 57s
    /// with 2-5s holes between turns; lowering it presses the delivery on.
    var maxPadding: Int = DialogueComposer.defaults.maxPadding
    /// Debug aid: prepends the conditioning clips to the take so you can hear
    /// exactly what the model was given. Never right for a shipped take.
    var keepPrefixAudio = DialogueComposer.defaults.keepPrefixAudio

    func resetGenerationSettings() {
        cfgScale = Self.defaults.cfgScale
        textTemperature = Self.defaults.textTemperature
        textTopK = Self.defaults.textTopK
        audioTemperature = Self.defaults.audioTemperature
        audioTopK = Self.defaults.audioTopK
        maxPadding = Self.defaults.maxPadding
        keepPrefixAudio = Self.defaults.keepPrefixAudio
    }

    /// What one pass actually produced. Kept per take so a bad pass can be
    /// named after the fact — a pass that goes quiet is invisible in a joined
    /// take, and that is exactly the failure worth catching.
    struct PassReport: Identifiable {
        let id = UUID()
        let number: Int
        let turns: Int
        let words: Int
        let seconds: Double
        let wallSeconds: Double
        /// Fraction of the pass below -50 dBFS, in 20ms windows.
        let silentFraction: Double
        /// Re-rolls it took to get this pass. 0 is the ordinary case.
        var attempts: Int = 0
        /// The draw this pass was rendered with, so it can be got back.
        var seed: UInt64 = 0
        /// A pass that is mostly silence did not say its lines.
        static let degradedAbove = 0.5
        var looksDegraded: Bool { silentFraction > Self.degradedAbove }
        var summary: String {
            String(format: "pass %d · %d turns, %d words · %.1fs audio in %.1fs · %.0f%% silent · seed %llu%@",
                   number, turns, words, seconds, wallSeconds, silentFraction * 100, seed,
                   attempts > 0 ? " (re-rolled \(attempts)x)" : "")
        }
    }

    private(set) var passReports: [PassReport] = []

    /// How many times this pass was re-rendered before it was kept.
    /// 0 for the ordinary case.

    static let log = Logger(subsystem: "fm.gloam.studio", category: "dialogue")

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
    /// The seed the last take was rendered with.
    ///
    /// Sampling is otherwise drawn from a process-wide RNG mlx-swift seeds
    /// from the clock, so no two renders of one script are comparable and no
    /// take can be got back. Recording it makes a take reproducible and lets a
    /// single bad pass be re-rolled without disturbing the others.
    private(set) var takeSeed: UInt64 = 0
    /// A pass that collapses is re-rendered with a fresh draw, at most this
    /// many times. Total collapse is rare, so this is a safety net rather than
    /// a quality control -- it cannot see the far commoner failure, a pass that
    /// says every word but drifts off the speaker's timbre.
    private static let collapseRetries = 2

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

    /// Swap the whole script out — what the article importer applies once the
    /// user has approved a generated script. Replaces rather than appends
    /// because a script is one exchange, and interleaving it with whatever was
    /// already typed would produce a conversation nobody wrote.
    func replaceTurns(with new: [Turn]) {
        guard !new.isEmpty else { return }
        turns = new
    }

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
    ///
    /// Cached against the turns it was computed from. The pass plan is read by
    /// the plan strip AND once per turn row (to draw the seam), so on a long
    /// generated script an uncached property re-planned the whole script for
    /// every row of every frame — quadratic work on the main thread, which is
    /// what made scrolling a scripted episode stutter.
    var report: SceneReport {
        if let cached = reportCache, cached.turns == turns { return cached.report }
        let fresh = DialoguePlanner.report(for: lines)
        reportCache = (turns, fresh)
        return fresh
    }
    @ObservationIgnored private var reportCache: (turns: [Turn], report: SceneReport)?

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
                // Same offer the bench makes: the first time this voice meets
                // Dia, ask before spending minutes on Whisper. Declining is not
                // a failure — the pass just won't be conditioned on this voice.
                guard try await app.ensureDiaReady(slug: slug) else {
                    guard !Task.isCancelled else { return }
                    // Declining releases the pick rather than seating an
                    // unprepared voice in the cast: Dia2 would speak the lines
                    // in an invented voice filed under this one's name, which
                    // is the substitution every other path here refuses. Back
                    // to no voice — an unconditioned speaker, stated plainly
                    // and not as an error.
                    voices[index] = nil
                    prefixStates[index] = .unconditioned(
                        "Setup skipped, so this speaker has no voice and will vary "
                        + "between takes. Pick the voice again to set it up.")
                    return
                }
                let prefix = try await app.dialoguePrefix(
                    for: slug, aligner: app.makeDiaAligner(), rate: rate)
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
        passReports = []
        // One number reproduces the whole take; each pass derives its own draw
        // from it, so re-rolling one pass leaves the others exactly as they
        // were.
        takeSeed = UInt64.random(in: .min ... .max)
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
        // Said before the render, not after. Each pass re-conditions from the
        // prefixes; with no prefixes there is nothing to re-condition FROM, so
        // every pass invents its speakers afresh and the voices audibly change
        // at each seam. That looks like a bug and is not one, so name it.
        if scenes.count > 1, !pass.contains(where: { $0 != nil }) {
            notes.append("No conditioning clips, so each of the \(scenes.count) passes invents "
                         + "its own two voices — they will change at every seam. Pick a voice "
                         + "for each speaker to keep them the same throughout.")
        }
        let tags = Set((try? await app.engine.nonverbalTags(backend: .dia2)) ?? [])
        let rate = BackendID.dia2.spec.defaultSampleRate
        var samples: [Float] = []
        let started = Date()

        do {
            let voiceList = voices.map { $0 ?? "none" }.joined(separator: "+")
            let prefixList = pass.map { $0 == nil ? "none" : "\($0!.words.count)w" }
                .joined(separator: "+")
            Self.log.info("take starting: \(scenes.count) passes, \(script.count) turns, voices \(voiceList), prefixes \(prefixList), cfg \(self.cfgScale), padding \(self.maxPadding)")
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
                let passStarted = Date()
                let text = try DialoguePlanner.script(for: request, knownTags: tags)

                // Re-roll a pass that collapsed. The draw is what changes, not
                // the settings: a collapse is one bad sample path, and turning
                // knobs to escape it silently renders the pass to a different
                // specification than its neighbours.
                var levelledChunk: [Float] = []
                var silent = 1.0
                var attempt = 0
                var passSeed = DialogueSeed.pass(take: takeSeed, index: number)
                while true {
                    passSeed = DialogueSeed.pass(take: takeSeed, index: number, attempt: attempt)
                    var seeded = request
                    seeded.seed = passSeed
                    // Must precede queuing work on `engine` (see
                    // TTSResidencyPolicy's deadlock-safety contract).
                    await app.ttsResidency.willUse(app.engine)
                    let chunk = try await app.engine.synthesizeDialogue(
                        backend: .dia2,
                        request: ProviderDialogueRequest(seeded, script: text, prefixes: pass))
                    levelledChunk = Loudness.leveled(chunk.samples, sampleRate: rate)
                    silent = Loudness.silentFraction(levelledChunk, sampleRate: rate)
                    guard silent > PassReport.degradedAbove, attempt < Self.collapseRetries
                    else { break }
                    attempt += 1
                    Self.log.error("pass \(number + 1) came out \(Int(silent * 100))% silent — re-rolling (attempt \(attempt + 1))")
                    progress = "Pass \(number + 1) of \(scenes.count) — re-rolling"
                }
                // Level EACH pass, not the finished join. Passes are separate
                // generations and come out at their own levels; normalising
                // once at the end applies a single gain to all of them, so the
                // differences survive intact and the take gets audibly louder
                // and quieter at every seam. Levelling per pass to the app's
                // own loudness standard is what makes the seam a cut rather
                // than a jump.
                let report = PassReport(
                    number: number + 1, turns: sceneTurns.count,
                    words: sceneTurns.reduce(0) { $0 + $1.text.split(separator: " ").count },
                    seconds: Double(levelledChunk.count) / Double(rate),
                    wallSeconds: Date().timeIntervalSince(passStarted),
                    silentFraction: silent,
                    attempts: attempt, seed: passSeed)
                passReports.append(report)
                if report.looksDegraded {
                    Self.log.error("\(report.summary) — mostly silent, the lines were not spoken")
                } else {
                    Self.log.info("\(report.summary)")
                }
                samples.append(contentsOf: levelledChunk)
            }
        } catch {
            self.error = app.describeAny(error)
            await app.refreshEngineStatus()
            return
        }

        let wall = Date().timeIntervalSince(started)
        // Already at the standard, pass by pass (above). A peak normalise here
        // would undo that work in the one case it matters: a single loud
        // transient in one pass would pull the whole take down around it.
        let levelled = samples
        takeWAV = WAVEncoder.encode(pcm16: PCM16.data(from: levelled), sampleRate: rate)
        takeSeconds = Double(levelled.count) / Double(rate)
        takeWallSeconds = wall
        app.recordTTSSpeed(backend: .dia2, audioSeconds: takeSeconds, wallSeconds: wall)
        if scenes.count > 1 {
            notes.append("Rendered in \(scenes.count) passes. Each pass starts from the "
                         + "reference again, so the seams are where the voices reset.")
        }
        // A pass that went quiet is invisible once the passes are joined, so
        // name it rather than leaving it to be found by ear.
        let degraded = passReports.filter(\.looksDegraded)
        if !degraded.isEmpty {
            let which = degraded.map { "\($0.number)" }.joined(separator: ", ")
            notes.append("Pass \(which) came out mostly silent — those lines were not spoken. "
                         + "This is a known bug in multi-pass renders; a script short enough to "
                         + "fit one pass avoids it.")
        }
        Self.log.info("take finished: \(self.takeSeconds)s audio, \(wall)s wall, \(degraded.count) degraded pass(es)")
        await app.refreshEngineStatus()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
