import EngineKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// Dialogue mode: two speakers, one Dia2 pass per planned scene.
///
/// The two things this screen is careful about are the two that cost the user
/// real time if it isn't. Entering the mode swaps the resident TTS model, which
/// is minutes of unloading and loading — so it asks first, in words, instead of
/// starting it behind a spinner. And a speaker's voice is aligned the moment it
/// is picked, not at Generate, so "this voice has no word timings" arrives while
/// the user is still choosing rather than after they have written a scene.
struct DialogueView: View {
    @Environment(AppModel.self) private var model
    @State private var player = PreviewPlayer()
    @State private var exportDoc: DataDocument?
    @State private var voicePickerSpeaker: Int?
    @AppStorage("dialogueInspectorVisible") private var inspectorVisible = true

    private var composer: DialogueComposer { model.dialogue }

    /// Dia2 has to be the resident model before anything here can run. Reading
    /// `residentTTS` rather than `backend` because the question is what is in
    /// memory, not what a picker says.
    private var dia2IsResident: Bool { model.residentTTS == .dia2 }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if dia2IsResident {
                    composerColumn
                } else {
                    modelSwitchGate
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
            // Fixed-width trailing pane, matching StudioView: an
            // HSplitView/`.inspector` renders past the window edge when the
            // window shrinks and takes the sidebar with it.
            if inspectorVisible {
                Divider().overlay(Color.white.opacity(0.06))
                dialogueInspector
                    .frame(width: 300)
                    .background(Brand.ink2.opacity(0.5))
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Dialogue Controls", systemImage: "sidebar.trailing")
                        .foregroundStyle(inspectorVisible ? Brand.accent : Brand.fgDim)
                }
                .help("Toggle the Dia2 controls inspector")
                .accessibilityIdentifier("dialogue-inspector-toggle")
            }
        }
        .fileExporter(isPresented: .init(get: { exportDoc != nil },
                                         set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .wav,
                      defaultFilename: "gloam-dialogue") { _ in exportDoc = nil }
    }

    // MARK: - Model-switch gate

    /// Deliberately a wall, not a spinner. Loading Dia2 evicts whatever TTS
    /// model is resident and pulls a 2B checkpoint off disk; doing that because
    /// someone clicked a tab would be a minutes-long surprise.
    @ViewBuilder
    private var modelSwitchGate: some View {
        let resident = model.residentTTS
        let downloaded = model.downloads.state(for: .dia2) == .ready
        VStack(alignment: .leading, spacing: 14) {
            Text("Dialogue runs on Dia2")
                .font(.title2.bold())
            Text("Dia2 speaks two voices in one pass. It is the only engine here that can, "
                 + "and only one speech model stays in memory at a time.")
                .foregroundStyle(Brand.fgDim)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                if let resident {
                    Label("\(resident.rawValue) is loaded now and will be unloaded.",
                          systemImage: "arrow.down.circle")
                } else {
                    Label("No speech model is loaded right now.",
                          systemImage: "circle.dashed")
                }
                Label("Loading Dia2 takes a while — minutes on a cold start.",
                      systemImage: "clock")
                Label("Switching back to \(resident?.rawValue ?? "another engine") "
                      + "later costs the same again.",
                      systemImage: "arrow.uturn.left")
            }
            .font(.callout)
            .foregroundStyle(Brand.fgDim)

            if !downloaded {
                Text("Dia2 isn't downloaded yet. Get it in Settings → Models, then come back.")
                    .font(.callout)
                    .foregroundStyle(Brand.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(model.loadingBackend == .dia2 ? "Loading Dia2…" : "Load Dia2") {
                    Task {
                        model.backend = .dia2
                        await model.loadModel(.dia2)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!downloaded || model.modelOpInFlight)
                .accessibilityIdentifier("dialogue-load-dia2")
                .help("Unload the current speech model and load Dia2")
                if model.loadingBackend == .dia2 {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.generationError {
                Text(error).font(.callout).foregroundStyle(Brand.peak)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("dialogue-model-gate")
    }

    // MARK: - Composer

    @ViewBuilder
    private var composerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                zoneLabel("CAST")
                HStack(alignment: .top, spacing: 12) {
                    speakerCard(1)
                    speakerCard(2)
                }

                zoneLabel("SCRIPT")
                turnList
                HStack(spacing: 10) {
                    Button { composer.addTurn() } label: {
                        Label("Add turn", systemImage: "plus")
                    }
                    .accessibilityIdentifier("dialogue-add-turn")
                    Spacer()
                }

                zoneLabel("PASSES")
                passPlan

                Divider().overlay(Color.white.opacity(0.06))
                generateRow
                ForEach(composer.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(Brand.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = composer.error {
                    Text(error).font(.callout).foregroundStyle(Brand.peak)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dialogue-error")
                }
                if composer.takeWAV != nil { takeCard }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    /// One speaker: who they are, and whether their clip is ready to condition
    /// with. The alignment state is a first-class row, not a tooltip.
    @ViewBuilder
    private func speakerCard(_ speaker: Int) -> some View {
        let voices = model.voices.list()
        let slug = composer.voices[speaker - 1]
        let selected = slug.flatMap { s in voices.first { $0.slug == s } }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("SPEAKER \(speaker)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(speaker == 1 ? Brand.accent : Brand.violet)
                // Popover, not a Menu: AppKit menus flatten custom SwiftUI, and
                // the avatars collapse to bare monograms (same reason StudioView
                // uses one).
                Button {
                    voicePickerSpeaker = voicePickerSpeaker == speaker ? nil : speaker
                } label: {
                    HStack(spacing: 6) {
                        if let voice = selected {
                            VoiceAvatarView(slug: voice.slug, name: voice.name,
                                            avatarURL: model.voices.avatarURL(voice.slug),
                                            size: 22)
                            Text(voice.name).foregroundStyle(Brand.fg)
                        } else {
                            Text("Choose a voice").foregroundStyle(Brand.fgDim)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(Brand.fgFaint)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dialogue-voice-picker-\(speaker)")
                .popover(isPresented: .init(get: { voicePickerSpeaker == speaker },
                                            set: { if !$0 { voicePickerSpeaker = nil } }),
                         arrowEdge: .bottom) {
                    voicePickerList(voices, speaker: speaker)
                }
                prefixStatus(composer.prefixStates[speaker - 1], speaker: speaker)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// What the eager alignment found. "No reference audio" is deliberately not
    /// styled as an error: the pass still renders, the voice just varies.
    @ViewBuilder
    private func prefixStatus(_ state: DialogueComposer.PrefixState,
                              speaker: Int) -> some View {
        Group {
            switch state {
            case .empty:
                Text("No voice — Dia2 will invent one, differently every take.")
                    .foregroundStyle(Brand.fgFaint)
            case .preparing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding word timings for this clip…").foregroundStyle(Brand.fgDim)
                }
            case .ready(let words, let seconds):
                Label(String(format: "Ready — %d words, %.1fs of reference", words, seconds),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(Brand.accent)
            case .unconditioned(let why):
                Label(why, systemImage: "info.circle")
                    .foregroundStyle(Brand.fgDim)
            case .failed(let why):
                VStack(alignment: .leading, spacing: 4) {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Brand.ember)
                    Button("Try again") { composer.prepare(speaker: speaker) }
                        .font(.caption)
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("dialogue-prefix-status-\(speaker)")
    }

    @ViewBuilder
    private func voicePickerList(_ voices: [VoiceMeta], speaker: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    composer.setVoice(nil, forSpeaker: speaker)
                    voicePickerSpeaker = nil
                } label: {
                    Text("No voice (unconditioned)")
                        .foregroundStyle(Brand.fgDim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(voices, id: \.slug) { voice in
                    Button {
                        composer.setVoice(voice.slug, forSpeaker: speaker)
                        voicePickerSpeaker = nil
                    } label: {
                        HStack(spacing: 8) {
                            VoiceAvatarView(slug: voice.slug, name: voice.name,
                                            avatarURL: model.voices.avatarURL(voice.slug),
                                            size: 22)
                            Text(voice.name).foregroundStyle(Brand.fg)
                            Spacer(minLength: 12)
                            if composer.voices[speaker - 1] == voice.slug {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.accent)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 260, height: 320)
    }

    @ViewBuilder
    private var turnList: some View {
        @Bindable var composer = model.dialogue
        // A plain stack with explicit move buttons rather than a `List` with
        // `onMove`: a List nested inside this ScrollView gets its own scroller
        // and fights the page's. Reordering is rare enough to be a button.
        VStack(spacing: 6) {
            ForEach(Array($composer.turns.enumerated()), id: \.element.id) { index, $turn in
                HStack(alignment: .top, spacing: 8) {
                    Picker("Speaker", selection: $turn.speaker) {
                        Text("S1").tag(1)
                        Text("S2").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 80)
                    .accessibilityIdentifier("dialogue-turn-speaker-\(index)")
                    TextField("What they say", text: $turn.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.09), lineWidth: 1))
                        .accessibilityIdentifier("dialogue-turn-text-\(index)")
                    // Rough seconds per turn, so a turn that will blow the pass
                    // budget is visible while it is being written.
                    Text(String(format: "%.0fs",
                                DialoguePlanner.estimatedSeconds(of: turn.text)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Brand.fgFaint)
                        .padding(.top, 8)
                    VStack(spacing: 2) {
                        Button { composer.moveTurn(at: index, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel("Move turn up")
                        Button { composer.moveTurn(at: index, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == composer.turns.count - 1)
                        .accessibilityLabel("Move turn down")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button { composer.removeTurn(turn.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                    .accessibilityLabel("Remove turn")
                }
                // A seam lands after this turn — the point where the model
                // re-conditions and the voices reset.
                if composer.report.splitAfterLines.contains(index) {
                    HStack(spacing: 6) {
                        Rectangle().fill(Brand.violet.opacity(0.5)).frame(height: 1)
                        Text("PASS BREAK")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Brand.violet)
                        Rectangle().fill(Brand.violet.opacity(0.5)).frame(height: 1)
                    }
                }
            }
        }
        .accessibilityIdentifier("dialogue-turns")
    }

    /// The plan, before generating rather than after. A user who can see "3
    /// passes, seams after turns 4 and 9" can move a line; one who finds out
    /// afterwards can only regenerate.
    @ViewBuilder
    private var passPlan: some View {
        let report = composer.report
        VStack(alignment: .leading, spacing: 6) {
            if report.sceneCount == 0 {
                Text("Nothing to render yet.").font(.callout).foregroundStyle(Brand.fgFaint)
            } else {
                Text(report.sceneCount == 1
                     ? String(format: "One pass, about %.0fs of audio.", report.estimatedSeconds)
                     : String(format: "%d passes, about %.0fs of audio in total.",
                              report.sceneCount, report.estimatedSeconds))
                    .font(.callout)
                    .foregroundStyle(Brand.fg)
                if !report.splitAfterLines.isEmpty {
                    Text("Seams after turn "
                         + report.splitAfterLines.map { "\($0 + 1)" }.joined(separator: ", ")
                         + ". Each pass starts from the reference clips again, so the voices "
                         + "reset there instead of drifting across the whole scene.")
                        .font(.caption).foregroundStyle(Brand.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.overBudgetScenes.isEmpty {
                    Text("One speaker holds the floor past "
                         + String(format: "%.0fs", DialoguePlanner.sceneBudgetSeconds)
                         + " — that pass can't be split without cutting mid-turn, so expect it "
                         + "to drift off the voice. Break the turn up to fix it.")
                        .font(.caption).foregroundStyle(Brand.ember)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ForEach(Array(report.sceneSeconds.enumerated()), id: \.offset) { index, s in
                        Text(String(format: "pass %d · %.0fs", index + 1, s))
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                            .overlay(Capsule().stroke(
                                report.overBudgetScenes.contains(index)
                                    ? Brand.ember.opacity(0.6) : Color.white.opacity(0.12),
                                lineWidth: 1))
                            .foregroundStyle(Brand.fgDim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dialogue-pass-plan")
    }

    @ViewBuilder
    private var generateRow: some View {
        HStack(spacing: 10) {
            Button("Generate") { Task { await composer.generate() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(composer.isGenerating || composer.report.sceneCount == 0)
                .accessibilityIdentifier("dialogue-generate")
                .help("Render the exchange (⌘↩)")
            if composer.isGenerating {
                ProgressView().controlSize(.small)
                Text(composer.progress ?? "Rendering…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
            }
        }
    }

    @ViewBuilder
    private var takeCard: some View {
        if let wav = composer.takeWAV {
            GroupBox {
                HStack(spacing: 12) {
                    WaveformView(wavData: wav).frame(height: 44)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2fs · wall %.1fs",
                                    composer.takeSeconds, composer.takeWallSeconds))
                        Text(String(format: "%.2fx realtime",
                                    composer.takeWallSeconds > 0
                                        ? composer.takeSeconds / composer.takeWallSeconds : 0))
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
                    Button(player.playingID == "dialogue" ? "Stop" : "Play") {
                        player.toggle(id: "dialogue", data: wav)
                    }
                    .accessibilityIdentifier("dialogue-play")
                    Button("Export…") {
                        // Re-encode with the provenance tag for files leaving
                        // the app, exactly as Studio's take export does.
                        exportDoc = DataDocument(data: WAVEncoder.encode(
                            pcm16: Data(wav.dropFirst(44)),
                            sampleRate: BackendID.dia2.spec.defaultSampleRate,
                            provenance: WAVEncoder.provenanceComment))
                    }
                    .accessibilityIdentifier("dialogue-export")
                    .help("Export this take as a WAV file")
                }
                .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Brand.accent.opacity(0.25), lineWidth: 1))
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var dialogueInspector: some View {
        @Bindable var composer = model.dialogue
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                zoneLabel("DIRECT")
                Text("Dia2 samples what is said and how it sounds separately. The text side "
                     + "decides the words and when a speaker changes; the audio side decides "
                     + "the delivery.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)

                knobRow("CFG scale", $composer.cfgScale, 1...10,
                        desc: "How hard the model is held to the reference voices. 6 is the "
                            + "measured sweet spot: lower drifts off the voice, higher clips "
                            + "and shouts.")
                knobRow("Text temperature", $composer.textTemperature, 0.1...2,
                        desc: "Variety in the words and turn-taking. Raise it for looser "
                            + "banter; too high and the speakers start talking over the script.")
                stepperRow("Text top-k", $composer.textTopK, 1...200,
                           desc: "How many candidate tokens the text side considers.")
                knobRow("Audio temperature", $composer.audioTemperature, 0.1...2,
                        desc: "Variety in the delivery. Raise for more expressive reads, at "
                            + "the cost of stability.")
                stepperRow("Audio top-k", $composer.audioTopK, 1...200,
                           desc: "How many candidate codes the audio side considers.")
                stepperRow("Max padding", $composer.maxPadding, 0...30,
                           desc: "Frames of silence a turn may be padded with before the next "
                               + "speaker starts. Higher leaves longer beats between lines.")
                Toggle("Keep prefix audio", isOn: $composer.keepPrefixAudio)
                    .accessibilityIdentifier("dialogue-keep-prefix")
                Text("Prepends each speaker's reference clip to the take, so you can hear "
                     + "exactly what conditioned it. For checking a voice, not for a take you "
                     + "intend to use.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.white.opacity(0.06))
                Text("A pass is capped at "
                     + String(format: "%.0f", DialoguePlanner.sceneBudgetSeconds)
                     + " seconds. Dia2 can generate to about two minutes, but the two "
                     + "speakers start merging around 95s and the voices stop matching their "
                     + "references well before that.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func knobRow(_ label: String, _ value: Binding<Float>,
                         _ range: ClosedRange<Float>, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Slider(value: value, in: range).frame(minWidth: 60, maxWidth: 160)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
            }
            Text(desc).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func stepperRow(_ label: String, _ value: Binding<Int>,
                            _ range: ClosedRange<Int>, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Stepper(value: value, in: range) {
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(value.wrappedValue)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            Text(desc).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func zoneLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(Brand.fgFaint)
    }
}
