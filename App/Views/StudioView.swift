import EngineKit
import SwiftUI
import UniformTypeIdentifiers
import StudioKit

enum StudioMode: String, CaseIterable {
    case single = "Single Line"
    case script = "Script"
}

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @State private var player = PreviewPlayer()
    @State private var exportDoc: DataDocument?
    @State private var voicePickerOpen = false
    /// Independent from the sidebar's own expansion state — expanding a group in
    /// this popover must not affect (or be affected by) the sidebar.
    @State private var pickerExpandedBases: Set<String> = []
    @State private var showSaveDirection = false
    @State private var saveDirectionName = ""
    @State private var lineSelection = NSRange(location: 0, length: 0)
    @AppStorage("studioMode") private var modeRaw: String = StudioMode.single.rawValue
    @AppStorage("studioInspectorVisible") private var inspectorVisible = true
    @State private var transcribingSlug: String?
    @State private var transcribeError: String?

    private var mode: StudioMode {
        StudioMode(rawValue: modeRaw) ?? .single
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            mainColumn
                .frame(minWidth: 320, maxWidth: .infinity)
            // Fixed-width trailing pane, NOT an HSplitView/`.inspector` — both
            // keep or render their size past the window edge when the window
            // shrinks (the sidebar then slides off the left edge). A fixed
            // 300pt pane + flexible main column fits every window size.
            if inspectorVisible {
                Divider().overlay(Color.white.opacity(0.06))
                studioInspector
                    .frame(width: 300)
                    .background(Brand.ink2.opacity(0.5))
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("Model Controls", systemImage: "sidebar.trailing")
                        .foregroundStyle(inspectorVisible ? Brand.accent : Brand.fgDim)
                }
                .help("Toggle the model controls inspector")
                .accessibilityIdentifier("studio-inspector-toggle")
            }
        }
        .fileExporter(isPresented: .init(get: { exportDoc != nil },
                                         set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .wav,
                      defaultFilename: "gloam-take") { _ in exportDoc = nil }
        .sheet(isPresented: $showSaveDirection) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Direction").font(.title3.bold())
                Text("Save the current Direction text as a reusable preset (saving over a "
                     + "matching name updates it).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Name (e.g. Excited deep DJ)", text: $saveDirectionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSaveDirection() }
                HStack {
                    Spacer()
                    Button("Cancel") { showSaveDirection = false; saveDirectionName = "" }
                    Button("Save") { commitSaveDirection() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saveDirectionName.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22).frame(width: 420)
        }
    }

    /// Auto-transcribe a voice's reference audio into `meta.refText` using the
    /// same STT engine the RECORD flow uses — unlocking the transcript-
    /// conditioned engines (qwen3-0.6b/1.7b, lux-tts) for this pack.
    private func transcribeRef(_ slug: String) {
        transcribingSlug = slug
        transcribeError = nil
        Task {
            defer { transcribingSlug = nil }
            do {
                let (_, refURL) = try model.voices.get(slug)
                let wav = try Data(contentsOf: refURL)
                let transcriber = model.speech.makeTranscriber()
                let hint = model.speech.effectiveLanguageHint
                let text = try await transcriber.transcribe(wavData: wav, languageHint: hint)
                    .text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    transcribeError = "Transcription came back empty — add it by hand in Edit."
                    return
                }
                try model.voices.update(slug, refText: text)
                model.voicesVersion += 1
            } catch {
                transcribeError = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    private func packChip(_ label: String, icon: String? = nil, active: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            if active {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.green)
            }
            Text(label).font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(active ? 0.09 : 0.04)))
        .overlay(Capsule().stroke(active ? Brand.accent.opacity(0.5) : Color.white.opacity(0.1),
                                  lineWidth: 1))
        .foregroundStyle(active ? Brand.fg : Brand.fgDim)
    }

    /// Manifest-driven pack summary for the selected voice: what assets the
    /// pack holds (clone ref + baked engine renditions), which one the active
    /// engine uses, and — on a mismatch — a plain-words warning with a
    /// one-click switch to the pack's best engine. This is the greyed-out
    /// sidebar row explained, where a new user is actually looking.
    @ViewBuilder
    private var voicePackBar: some View {
        if let slug = model.selectedVoiceSlug, let meta = try? model.voices.meta(slug) {
            // Read voicesVersion so a saved transcript re-derives capabilities
            // (and re-lights the engine chips) without reselecting the voice.
            let _ = model.voicesVersion
            let caps = model.voices.capabilities(slug)
            let renderable = caps.supports(model.backend)
            // What can SPEAK this voice, which is not what the pack contains.
            // `engines/` ids answer a different question: they include ids this
            // app cannot render at all (elevenlabs), and ids that mint a voice
            // from an instruct rather than speaking a stored one (qwen3-design).
            // Listing them as the voice's engines told users a Benson pack
            // "included" kokoro, when kokoro only ever speaks its own presets.
            // `supports` is the predicate the sidebar and the mismatch warning
            // below already use — one answer everywhere.
            //
            // Derived from `BackendID.allCases`, never a curated list: add a
            // cloning engine tomorrow and every voice that carries a recording
            // gains it here with no edit to this view. A curated array would
            // silently omit it.
            //
            // Partitioned rather than sorted by a `contains`-pair predicate:
            // that comparator is not a strict weak ordering, which can trap
            // inside Swift's sort.
            let compatible = BackendID.allCases.filter { caps.supports($0) }
            let orderedCompatible = compatible.filter { caps.engines.contains($0.rawValue) }
                + compatible.filter { !caps.engines.contains($0.rawValue) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VoiceAvatarView(slug: slug, name: meta.name,
                                    avatarURL: model.voices.avatarURL(slug), size: 20)
                    Text(meta.name).font(.callout.weight(.semibold))
                    Text("Works with:").font(.caption).foregroundStyle(Brand.fgFaint)
                    ForEach(orderedCompatible, id: \.self) { backend in
                        packChip(backend.rawValue, active: backend == model.backend)
                            .help(caps.engines.contains(backend.rawValue)
                                  ? "Pre-rendered for \(backend.rawValue) — speaks this voice with no recording needed"
                                  : "Cloned from this voice's recording")
                    }
                    if orderedCompatible.isEmpty {
                        Text("no engine can speak this voice yet")
                            .font(.caption2).foregroundStyle(Brand.fgFaint)
                    }
                    if caps.hasSource {
                        // A missing transcript silently halves the cloning
                        // roster (qwen/lux condition on it) — say so, and fix
                        // it in one click via the same STT the RECORD flow uses.
                        if !caps.hasRefText {
                            if transcribingSlug == slug {
                                ProgressView().controlSize(.mini)
                                Text("transcribing…").font(.caption2).foregroundStyle(Brand.fgFaint)
                            } else {
                                Text("transcript missing").font(.caption2).foregroundStyle(Brand.fgFaint)
                                Button("Transcribe") { transcribeRef(slug) }
                                    .font(.caption2).buttonStyle(.borderless)
                                    .foregroundStyle(Brand.accent)
                                    .help("Auto-transcribe the reference audio — unlocks the "
                                          + "transcript-conditioned engines (qwen3, lux-tts)")
                                    .accessibilityIdentifier("pack-bar-transcribe")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !renderable {
                    // Every engine that can speak this voice, not one arbitrary
                    // pick: a clone ref unlocks the whole cloning roster, so a
                    // single suggestion would undersell the pack. Baked
                    // renditions sort first and say so.
                    let affordable = compatible.filter { model.hasSufficientRAM(for: $0) }
                    let targets = affordable.filter { caps.engines.contains($0.rawValue) }
                        + affordable.filter { !caps.engines.contains($0.rawValue) }
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Text("\(model.backend.rawValue) can't speak this voice — nothing will generate")
                            .font(.caption).foregroundStyle(Brand.fgDim)
                        // Engines the pack would support if only the transcript
                        // existed — shown disabled with the reason, so "why not
                        // qwen?" answers itself.
                        let transcriptLocked = BackendID.allCases.filter {
                            !caps.supports($0) && caps.hasSource && $0.needsRefText
                                && $0.controls.voiceClone != .none
                                && model.hasSufficientRAM(for: $0)
                        }
                        if !targets.isEmpty || !transcriptLocked.isEmpty {
                            Menu("Switch engine") {
                                ForEach(targets, id: \.self) { target in
                                    Button(caps.engines.contains(target.rawValue)
                                           ? "\(target.rawValue) — pre-rendered"
                                           : target.rawValue) {
                                        model.backend = target
                                        if model.downloads.state(for: target) == .ready {
                                            Task { await model.loadModel(target) }
                                        }
                                    }
                                }
                                if !transcriptLocked.isEmpty {
                                    Divider()
                                    ForEach(transcriptLocked, id: \.self) { locked in
                                        Button("\(locked.rawValue) needs a transcript of the recording") {}
                                            .disabled(true)
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                            .font(.caption)
                            .accessibilityIdentifier("pack-bar-switch")
                        }
                    }
                }
                if let error = transcribeError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(renderable ? 0.02 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(renderable ? Color.white.opacity(0.05) : Color.orange.opacity(0.25),
                        lineWidth: 1))
            .accessibilityIdentifier("voice-pack-bar")
        }
    }

    /// Center column: mode switch + write/act/takes.
    @ViewBuilder
    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            voicePackBar
            Picker("Mode", selection: Binding(
                get: { StudioMode(rawValue: modeRaw) ?? .single },
                set: { modeRaw = $0.rawValue })) {
                ForEach(StudioMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("studio-mode")
            .help("Switch between single-line and script generation modes")

            if mode == .script {
                ScriptView()
            } else {
                singleModeStack
            }
        }
        .padding(16)
    }

    private func commitSaveDirection() {
        model.saveDirection(named: saveDirectionName)
        saveDirectionName = ""
        showSaveDirection = false
    }

    /// The whole bench scrolls: expanded disclosures (tags, fine-tune) must
    /// never force the stack taller than the window — SwiftUI centers
    /// overflowing stacks, shoving everything off-screen ("blank window").
    @ViewBuilder
    private var singleModeStack: some View {
        @Bindable var model = model
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    benchControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(minHeight: 220)
            // TAKES takes the rest of the column rather than a 240pt shelf at
            // the bottom: the shelf left a band of dead space between the bench
            // and the takes, and hid entirely until the first take existed, so
            // the space was empty in the one state where a hint would help.
            VStack(alignment: .leading, spacing: 0) {
                zoneLabel("TAKES")
                if model.variants.isEmpty {
                    VStack(spacing: 10) {
                        Text("No takes yet — write a line and press Generate (⌘↩).")
                            .font(.caption).foregroundStyle(Brand.fgFaint)
                        SiblingAppsFootnote(campaign: .takesEmptyState)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.variants) { variant in
                                variantCard(variant)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .accessibilityIdentifier("takes-region")
        }
    }

    /// Inspector content: everything about HOW the engine speaks (speaker,
    /// direction, language, delivery, speed, advanced sampling) — the DIRECT
    /// card that used to sit mid-column.
    @ViewBuilder
    private var studioInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                zoneLabel("DIRECT")
                directCard
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var emotionPicker: some View {
        @Bindable var model = model
        FlowLayout(spacing: 6) {
            ForEach(AppModel.emotionOrder, id: \.self) { emotion in
                let selected = model.emotion == emotion
                Button {
                    model.emotion = emotion
                } label: {
                    Text(emotion.rawValue.capitalized)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(selected
                                ? Brand.accent.opacity(0.18)
                                : Color.white.opacity(0.04)))
                        .overlay(
                            Capsule().stroke(selected
                                ? Brand.accent
                                : Color.white.opacity(0.12), lineWidth: 1))
                        .foregroundStyle(selected ? Brand.accent : Brand.fgDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("emotion-chip-\(emotion.rawValue)")
                .help("Pick \(emotion.rawValue) emotional read; uses an acted '-emotion' reference variant when one exists")
            }
        }
    }

    /// The delivery control for the current backend's emotion mechanism: a
    /// continuous model-native knob for `.liveKnob` (what the model actually takes),
    /// the acted-variant emotion picker for `.variantClipOnly`, the live inline
    /// `[marker]` picker for `.inlineMarker` (Fish), nothing for `.textDriven`.
    @ViewBuilder
    private func deliveryControls(_ controls: ControlSurface) -> some View {
        @Bindable var model = model
        switch model.backend.emotionMechanism {
        case .liveKnob(.exaggeration):
            if let r = controls.knobs.exaggeration {
                knobRow("Exaggeration", $model.exaggerationOverride, r,
                        desc: "Emotional intensity — Chatterbox's exaggeration (~0.3–0.7 typical). "
                            + "Lower CFG weight in Advanced as you push this up.")
            }
        case .liveKnob(.temperature):
            if let r = controls.knobs.temperature {
                knobRow("Dynamics", $model.temperatureOverride, r,
                        desc: "Delivery energy — sampling temperature. Higher is livelier and less "
                            + "predictable. Fish's emotion itself comes from the inline [tags] above.")
            }
        case .variantClipOnly:
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Emotion").font(.caption).foregroundStyle(Brand.fgDim); Spacer() }
                emotionPicker
                Text("Switches to an acted “-emotion” voice variant when one exists — add them via "
                     + "New Emotion Variant, or generate them in Create Voice.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .inlineMarker:
            // Emotion lives in the inline `[tags]` above (TagChipsView) — the full,
            // trained Fish vocabulary. No separate picker here (that duplicated it).
            Text("Emotion & sounds: use the [tags] above — click to insert, or type them "
                 + "inline. Dynamics (temperature) is in Advanced.")
                .font(.caption2).foregroundStyle(Brand.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        case .textDriven, .none:
            EmptyView()
        }
    }

    /// Knobs minus the live emotion knob (surfaced as the primary delivery control),
    /// so the Advanced disclosure never shows a second control for the same parameter.
    private func advancedOnlyKnobs(_ k: Knobs, mechanism: EmotionMechanism) -> Knobs {
        var out = k
        if case .liveKnob(let knob) = mechanism {
            switch knob {
            case .temperature: out.temperature = nil
            case .exaggeration: out.exaggeration = nil
            }
        }
        return out
    }

    @ViewBuilder
    private var speedControls: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Text("Speed")
            Slider(value: $model.speed, in: 0.5...2.0, step: 0.05)
                .frame(minWidth: 60, maxWidth: 160)
                .help("Adjust speech rate (0.5x–2.0x)")
            Text(String(format: "%.2f×", model.speed))
                .font(.system(.caption, design: .monospaced))
        }
    }

    static let languages: [(String, String)] = [
        ("auto", "Auto"), ("english", "English"), ("chinese", "Chinese"),
        ("japanese", "Japanese"), ("korean", "Korean"), ("german", "German"),
        ("french", "French"), ("russian", "Russian"), ("portuguese", "Portuguese"),
        ("spanish", "Spanish"), ("italian", "Italian"),
    ]

    private func hasAnyKnob(_ k: Knobs) -> Bool {
        k.temperature != nil || k.topP != nil || k.topK != nil
            || k.repetitionPenalty != nil || k.exaggeration != nil || k.cfgWeight != nil
            || k.numSteps != nil || k.guidanceScale != nil || k.tShift != nil
            || k.speed != nil || k.returnSmooth != nil
    }

    @ViewBuilder
    private func advancedKnobs(_ knobs: Knobs) -> some View {
        @Bindable var model = model
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let r = knobs.temperature {
                    knobRow("Temperature", $model.temperatureOverride, r,
                            desc: "Expressiveness. Low = flat & consistent; high = livelier but less predictable.")
                }
                if let r = knobs.topP {
                    knobRow("Top-p", $model.qwenTopP, r,
                            desc: "Variety of sound choices. Lower = steadier; 1.0 = the full range.")
                }
                if let r = knobs.topK {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Top-k")
                            Slider(value: Binding(
                                get: { Float(model.qwenTopK) },
                                set: { model.qwenTopK = Int($0) }),
                                in: Float(r.lowerBound)...Float(r.upperBound))
                                .frame(minWidth: 60, maxWidth: 160)
                            Text("\(model.qwenTopK)").font(.system(.caption, design: .monospaced))
                        }
                        Text("How many options it considers each step. Lower = constrained; higher = varied.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let r = knobs.repetitionPenalty {
                    knobRow("Repetition", $model.qwenRepetitionPenalty, r,
                            desc: "Higher values reduce stutters and looping artifacts.")
                }
                if let r = knobs.exaggeration {
                    knobRow("Exaggeration", $model.exaggerationOverride, r,
                            desc: "Drives Chatterbox's emotional intensity.")
                }
                if let r = knobs.cfgWeight {
                    knobRow("CFG weight", $model.cfgWeight, r,
                            desc: "Chatterbox guidance strength. Lower it (~0.3) as Exaggeration rises "
                                + "so pacing doesn't rush.")
                }
                if let r = knobs.numSteps {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Steps")
                            Slider(value: Binding(
                                get: { Float(model.luxNumSteps) },
                                set: { model.luxNumSteps = Int($0) }),
                                in: Float(r.lowerBound)...Float(r.upperBound))
                                .frame(minWidth: 60, maxWidth: 160)
                            Text("\(model.luxNumSteps)").font(.system(.caption, design: .monospaced))
                        }
                        Text("Flow-matching sampling steps. 3–4 is the efficient sweet spot; higher "
                             + "trades latency for quality.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let r = knobs.guidanceScale {
                    knobRow("Guidance", $model.luxGuidanceScale, r,
                            desc: "Classifier-free guidance scale — how strongly generation follows "
                                + "the reference identity.")
                }
                if let r = knobs.tShift {
                    knobRow("Schedule shift", $model.luxTShift, r,
                            desc: "Lower reduces pronunciation errors but softens quality, and vice versa.")
                }
                if let r = knobs.speed {
                    knobRow("Pace", $model.speed, r,
                            desc: "LuxTTS's native duration pacing (not a post-hoc resample — no pitch "
                                + "shift). Lower it if a fast reference rushes or drops words.")
                }
                if knobs.returnSmooth != nil {
                    Toggle(isOn: $model.luxReturnSmooth) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sharp 48k output")
                            Text("On = the sharper dual-path 48k vocoder output; off = the smoother "
                                 + "24k-resampled path if you hear metallic artifacts.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to defaults") { model.resetDeliveryKnobs() }
                        .font(.caption)
                        .accessibilityIdentifier("reset-knobs")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Label("Advanced — fine-tune the delivery", systemImage: "slider.horizontal.3")
        }
        .font(.callout)
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
        }
    }

    /// One-line "what this model does" explainer shown under the DIRECT label,
    /// so the available controls make sense for the selected model.
    private func directExplainer(_ b: BackendID) -> String {
        switch b {
        case .qwen06B, .qwen17B:
            "Clones a voice from a reference clip — pick one above. (To steer delivery with words, use qwen3-design or qwen3-custom instead.)"
        case .qwenDesign:
            "Invent a brand-new voice purely from your description — there's no voice to pick or clone."
        case .qwenCustom:
            "Describe how the voice should talk. Pick who is talking in the voice list — "
            + "the identity stays fixed; your Direction shapes the delivery."
        case .fishS2Pro:
            "Clone a voice (optional). Emotion & sounds come from the [tags] above; fine-tune dynamics in Advanced. Free-text Direction isn't supported here."
        case .chatterbox:
            "Clone a voice and shape intensity with Emotion + Exaggeration. Free-text Direction isn't supported here."
        case .chatterboxTurbo:
            "Clone a voice; the emotional read comes from the reference clip. No manual delivery knobs."
        case .kokoro:
            "Kokoro speaks its own fixed voices — choose one in the voice list. It doesn't "
            + "clone or take free-text direction, and quality varies a lot by voice."
        case .luxTTS:
            "Clones a voice from a reference clip — the prosody comes entirely from that clip. "
            + "No free-text Direction; tune the flow-matching steps/guidance in Advanced instead."
        case .supertonic:
            "SuperTonic speaks its own preset voice styles — choose one in the voice list. "
            + "Fast, multilingual, 44.1 kHz. No cloning or free-text direction."
        case .pocketTTS:
            "Clones a voice from a reference clip (first ~10s) — the prosody comes from that "
            + "clip. No free-text Direction and no delivery knobs; each take samples fresh."
        }
    }

    @ViewBuilder
    private var benchControls: some View {
        @Bindable var model = model

        // ── VOICE picker ────────────────────────────────────────────────────
        // Every backend that speaks a stored voice shows the picker — which now
        // includes the preset engines, whose voices used to be chosen from a
        // Speaker menu over in the Direct pane. Only qwen3-design is left out,
        // and it mints a voice from an instruct rather than speaking one.
        if !model.backend.controls.presetSpeakers.isEmpty
            || model.backend.controls.voiceClone != .none {
            zoneLabel("VOICE")
            let voices = model.voices.list()
            // Custom popover dropdown (not a native Menu): AppKit menus flatten
            // custom SwiftUI views, so VoiceAvatarView collapsed to a bare monogram
            // and names dropped. A popover renders full SwiftUI, avatars included.
            Button {
                voicePickerOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let slug = model.selectedVoiceSlug,
                       let voice = voices.first(where: { $0.slug == slug }) {
                        VoiceAvatarView(
                            slug: voice.slug,
                            name: voice.name,
                            avatarURL: model.voices.avatarURL(voice.slug),
                            size: 22)
                        Text(voice.name)
                            .font(.system(.callout, design: .default))
                            .foregroundStyle(Brand.fg)
                    } else {
                        Text("Choose a voice")
                            .foregroundStyle(Brand.fgDim)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Brand.fgFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("voice-picker")
            .popover(isPresented: $voicePickerOpen, arrowEdge: .bottom) {
                voicePickerList(voices)
            }
        }

        // ── WRITE zone ──────────────────────────────────────────────────────
        zoneLabel("WRITE")
        HStack(alignment: .top, spacing: 8) {
            CaretTextEditor(text: $model.text, selection: $lineSelection,
                            axIdentifier: "line-editor")
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
            DictationButton(text: $model.text)
        }
        if model.backend.spec.honorsTags {
            TagChipsView(text: $model.text, selection: $lineSelection)
        }

        // ── ACT zone (no label per spec) ─────────────────────────────────────
        Divider().overlay(Color.white.opacity(0.06))
        // Why generation is blocked, or nil when it isn't. The engine/voice
        // mismatch used to be a note beside a working button, which is how a
        // take could come out in a voice nobody chose; it stops the button now.
        let blockedReason: String? = {
            guard let slug = model.selectedVoiceSlug else {
                return "Pick a voice in the sidebar."
            }
            let _ = model.voicesVersion
            guard !model.voices.capabilities(slug).supports(model.backend) else { return nil }
            let name = (try? model.voices.meta(slug).name) ?? slug
            return "\(model.backend.rawValue) can't speak “\(name)” — switch engine, "
                + "or pick a voice it can render."
        }()
        HStack(spacing: 10) {
            Button("Generate") { Task { await model.generate(takes: 1) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isGenerating || blockedReason != nil)
                .accessibilityIdentifier("generate")
                .help(blockedReason ?? "Synthesize this line (⌘↩)")
            Button("Generate A/B") { Task { await model.generate(takes: 2) } }
                .disabled(model.isGenerating || blockedReason != nil)
                .help(blockedReason ?? "Two takes to compare")
            if model.isGenerating { ProgressView().controlSize(.small) }
            if let blockedReason {
                Text(blockedReason)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("generate-blocked")
            }
            Spacer()
        }

        if let error = model.generationError {
            Text(error).foregroundStyle(.red).font(.callout)
                .accessibilityIdentifier("generation-error")
        }
    }

    /// The DIRECT card — engine-facing controls, rendered in the inspector.
    @ViewBuilder
    private var directCard: some View {
        @Bindable var model = model
        let controls = model.backend.controls
        VStack(alignment: .leading, spacing: 10) {
            // Per-model explainer so the controls below make sense.
            Text(directExplainer(model.backend))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Direction (instruct)
            if controls.instruct != .none {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(controls.instruct == .required ? "Direction (required)" : "Direction")
                            .font(.caption).foregroundStyle(Brand.fgDim)
                        Spacer()
                        Menu {
                            Section("Examples") {
                                ForEach(AppModel.seededDirections) { preset in
                                    Button(preset.name) { model.instruct = preset.text }
                                }
                            }
                            if !model.savedDirections.isEmpty {
                                Section("Saved") {
                                    ForEach(model.savedDirections) { preset in
                                        Menu(preset.name) {
                                            Button("Use") { model.instruct = preset.text }
                                            Button("Delete", role: .destructive) {
                                                model.deleteSavedDirection(preset)
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Save current…") { showSaveDirection = true }
                                .disabled(model.instruct.trimmingCharacters(
                                    in: .whitespacesAndNewlines).isEmpty)
                        } label: {
                            Label("Presets", systemImage: "text.badge.plus").font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityIdentifier("direction-presets")
                        ExpandButton(text: $model.instruct, kind: .direction)
                    }
                    Text("Describe HOW it should sound — character, mood, pace, accent. Plain English, ~1–3 sentences.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $model.instruct)
                        .font(.system(.callout, design: .default))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
                        .accessibilityIdentifier("instruct-editor")
                    if model.instruct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(#"e.g. "warm, slightly breathy, unhurried late-night radio host""#)
                            .font(.caption2).italic().foregroundStyle(Brand.fgFaint)
                    }
                    if controls.voiceClone != .none && model.selectedVoiceSlug != nil {
                        Text("A reference voice is selected — Direction is ignored (clone takes priority). "
                             + "Clear the voice to design by description.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            // Language
            if controls.language {
                HStack {
                    Text("Language").font(.caption).foregroundStyle(Brand.fgDim)
                    Picker("", selection: $model.language) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(maxWidth: 160)
                        .help("Language of your text. Auto detects it.")
                }
            }
            // Delivery — the model-native continuous knob for liveKnob backends
            // (Exaggeration / Dynamics); the acted-variant picker for variantClipOnly;
            // nothing for textDriven (the Direction box is the control).
            deliveryControls(controls)
            speedControls
            // Advanced — remaining sampling knobs. The live knob is surfaced above,
            // so it's filtered out here to avoid two controls for one parameter.
            let advKnobs = advancedOnlyKnobs(controls.knobs, mechanism: model.backend.emotionMechanism)
            if hasAnyKnob(advKnobs) {
                advancedKnobs(advKnobs)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
        // Rebuild the whole pane on model change so the controls (and any retained
        // disclosure/field state) always match the selected model.
        .id(model.backend)
    }

    /// Popover list for the voice picker: avatar + name per row, with a
    /// checkmark on the current selection. Rendered in a popover so the custom
    /// avatar views actually draw (native menus flatten them).
    @ViewBuilder
    private func voicePickerList(_ voices: [VoiceMeta]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if voices.isEmpty {
                    Text("No voices yet — add one in the sidebar.")
                        .font(.callout)
                        .foregroundStyle(Brand.fgDim)
                        .padding(10)
                }
                ForEach(groupedVoices(voices), id: \.base.slug) { group in
                    voicePickerRow(group.base, isVariant: false, variantCount: group.variants.count)
                    if pickerExpandedBases.contains(group.base.slug) {
                        ForEach(group.variants, id: \.slug) { variant in
                            voicePickerRow(variant, isVariant: true, variantCount: 0)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 240)
        .frame(maxHeight: 360)
        // Translucent over the popover's native glass chrome rather than
        // opaque ink — keeps the tint, lets the system material show.
        .background(Brand.ink2.opacity(0.5))
    }

    /// One VOICE-popover row. A base voice with acted variants shows a disclosure
    /// chevron and count badge; variants render indented, same visual language as
    /// the sidebar's `voiceRow` (VoiceSidebarView.swift) but without its hover-only
    /// play/edit/menu controls — this popover only selects.
    @ViewBuilder
    private func voicePickerRow(_ voice: VoiceMeta, isVariant: Bool, variantCount: Int) -> some View {
        let selected = model.selectedVoiceSlug == voice.slug
        // This popover picks the voice the CURRENT backend will speak with, so
        // (unlike the sidebar, where selection also means editing) rows the
        // backend can't render are disabled outright.
        let renderable = model.voices.capabilities(voice.slug).supports(model.backend)
        HStack(spacing: 8) {
            if isVariant {
                Color.clear.frame(width: 16)
            } else if variantCount > 0 {
                Button {
                    if pickerExpandedBases.contains(voice.slug) {
                        pickerExpandedBases.remove(voice.slug)
                    } else {
                        pickerExpandedBases.insert(voice.slug)
                    }
                } label: {
                    Image(systemName: pickerExpandedBases.contains(voice.slug)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.fgDim)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(pickerExpandedBases.contains(voice.slug) ? "Collapse Variants" : "Expand Variants")
            } else {
                Color.clear.frame(width: 12)
            }
            Button {
                model.selectedVoiceSlug = voice.slug
                voicePickerOpen = false
            } label: {
                HStack(spacing: 8) {
                    VoiceAvatarView(
                        slug: voice.slug,
                        name: voice.name,
                        avatarURL: model.voices.avatarURL(voice.slug),
                        size: isVariant ? 18 : 22)
                    Text(voice.name).foregroundStyle(renderable ? Brand.fg : Brand.fgFaint)
                    if !renderable {
                        Text("can't speak this voice")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Brand.fgFaint)
                    }
                    if variantCount > 0 {
                        Text("\(variantCount)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundStyle(Brand.fgDim)
                    }
                    Spacer(minLength: 12)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.accent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.white.opacity(0.07) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!renderable)
            .help(renderable ? "" :
                  "\(voice.name) has no assets \(model.backend.rawValue) can render.")
        }
    }

    /// Tiny monospaced zone eyebrow label.
    @ViewBuilder
    private func zoneLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(Brand.fgFaint)
    }

    @ViewBuilder
    private func variantCard(_ variant: Variant) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                Text(variant.label)
                    .font(.system(.headline, design: .monospaced))
                    .padding(6)
                    .background(Circle().fill(Brand.gradient.opacity(0.25)))
                    .accessibilityIdentifier("variant-badge-\(variant.label)")
                WaveformView(wavData: variant.wavData)
                    .frame(height: 44)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2fs · wall %.2fs", variant.seconds,
                                variant.wallSeconds))
                    Text(String(format: "%.2fx realtime", variant.rtf))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.fgDim)
                Button(player.playingID == variant.id.uuidString ? "Stop" : "Play") {
                    player.toggle(id: variant.id.uuidString, data: variant.wavData)
                }
                .accessibilityIdentifier("play-\(variant.label)")
                Button("Export…") {
                    // Re-encode with the provenance tag for files leaving the app.
                    let pcm = variant.wavData.dropFirst(44)
                    exportDoc = DataDocument(data: WAVEncoder.encode(
                        pcm16: Data(pcm), sampleRate: variant.sampleRate,
                        provenance: WAVEncoder.provenanceComment))
                }
                .help("Export this variant as a WAV file")
            }
            .padding(6)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.accent.opacity(0.25), lineWidth: 1))
    }

}
