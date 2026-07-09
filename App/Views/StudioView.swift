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
    @State private var showSaveDirection = false
    @State private var saveDirectionName = ""
    @State private var lineSelection = NSRange(location: 0, length: 0)
    @AppStorage("studioMode") private var modeRaw: String = StudioMode.single.rawValue

    private var mode: StudioMode {
        StudioMode(rawValue: modeRaw) ?? .single
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    benchControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onChange(of: model.variants.count) { _, count in
                if count > 0 {
                    withAnimation {
                        proxy.scrollTo("variants-anchor", anchor: .top)
                    }
                }
            }
        }
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
                     + "New Emotion Variant, or bake them in Create Voice.")
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
        case .textDriven:
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
                .frame(width: 140)
                .help("Adjust speech rate (0.5x–2.0x)")
            Text(String(format: "%.2f×", model.speed))
                .font(.system(.caption, design: .monospaced))
        }
    }

    /// CustomVoice preset character + language, from the model's spk_id table.
    static let speakerInfo: [String: (desc: String, lang: String)] = [
        "Vivian": ("Bright, slightly edgy young female", "Chinese"),
        "Serena": ("Warm, gentle young female", "Chinese"),
        "Uncle_Fu": ("Seasoned male, low mellow timbre", "Chinese"),
        "Dylan": ("Youthful, clear male", "Beijing dialect"),
        "Eric": ("Lively, slightly husky male", "Sichuan dialect"),
        "Ryan": ("Dynamic male, strong rhythmic drive", "English"),
        "Aiden": ("Sunny American male, clear midrange", "English"),
        "Ono_Anna": ("Playful, light female", "Japanese"),
        "Sohee": ("Warm, emotional female", "Korean"),
    ]

    /// Picker label: "Ryan · English" so the language is visible at a glance.
    static func speakerLabel(_ name: String) -> String {
        if let info = speakerInfo[name] { return "\(name) · \(info.lang)" }
        return name
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
                                in: Float(r.lowerBound)...Float(r.upperBound)).frame(width: 160)
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
                Slider(value: value, in: range).frame(width: 160)
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
            "Pick a built-in Speaker, then describe how it should talk. The identity stays fixed; your Direction shapes the delivery."
        case .fishS2Pro:
            "Clone a voice (optional). Emotion & sounds come from the [tags] above; fine-tune dynamics in Advanced. Free-text Direction isn't supported here."
        case .chatterbox:
            "Clone a voice and shape intensity with Emotion + Exaggeration. Free-text Direction isn't supported here."
        case .chatterboxTurbo:
            "Clone a voice; the emotional read comes from the reference clip. No manual delivery knobs."
        }
    }

    @ViewBuilder
    private var benchControls: some View {
        @Bindable var model = model

        // ── VOICE picker ────────────────────────────────────────────────────
        // Spec §C.1: only show the Voice picker for clone-capable backends.
        // Hide it for voiceClone == .none (qwen3-design/custom).
        if model.backend.controls.voiceClone != .none {
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

        // ── DIRECT zone (inset card) ─────────────────────────────────────────
        Divider().overlay(Color.white.opacity(0.06))
        zoneLabel("DIRECT")
        let controls = model.backend.controls
        VStack(alignment: .leading, spacing: 10) {
            // Per-model explainer so the controls below make sense.
            Text(directExplainer(model.backend))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Speaker (CustomVoice)
            if !controls.presetSpeakers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Speaker").font(.caption).foregroundStyle(Brand.fgDim)
                        Picker("", selection: $model.speaker) {
                            ForEach(controls.presetSpeakers, id: \.self) { name in
                                Text(Self.speakerLabel(name)).tag(name)
                            }
                        }.labelsHidden().frame(width: 220)
                    }
                    // Description of the currently-selected speaker (names alone are opaque).
                    if let info = Self.speakerInfo[model.speaker] {
                        Text("\(info.desc) · \(info.lang)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("A built-in voice identity (fixed timbre) you can't change — only Ryan and "
                         + "Aiden are English. Your Direction below shapes how it speaks.")
                        .font(.caption2).foregroundStyle(Brand.fgFaint)
                }
            }
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
                    }.labelsHidden().frame(width: 160)
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

        // ── ACT zone (no label per spec) ─────────────────────────────────────
        Divider().overlay(Color.white.opacity(0.06))
        HStack(spacing: 10) {
            Button("Generate") { Task { await model.generate(takes: 1) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isGenerating)
                .accessibilityIdentifier("generate")
                .help("Synthesize this line (⌘↩)")
            Button("Generate A/B") { Task { await model.generate(takes: 2) } }
                .disabled(model.isGenerating)
                .help("Two takes to compare")
            if model.isGenerating { ProgressView().controlSize(.small) }
            Spacer()
        }

        if let error = model.generationError {
            Text(error).foregroundStyle(.red).font(.callout)
                .accessibilityIdentifier("generation-error")
        }

        // ── LISTEN / TAKES zone ──────────────────────────────────────────────
        if !model.variants.isEmpty {
            Divider().overlay(Color.white.opacity(0.06))
            zoneLabel("TAKES")
        }
        VStack(spacing: 10) {
            ForEach(model.variants) { variant in
                variantCard(variant)
            }
        }
        .id("variants-anchor")
    }

    /// Popover list for the voice picker: avatar + name per row, with a
    /// checkmark on the current selection. Rendered in a popover so the custom
    /// avatar views actually draw (native menus flatten them).
    @ViewBuilder
    private func voicePickerList(_ voices: [VoiceMeta]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if voices.isEmpty {
                Text("No voices yet — add one in the sidebar.")
                    .font(.callout)
                    .foregroundStyle(Brand.fgDim)
                    .padding(10)
            }
            ForEach(voices, id: \.slug) { voice in
                let selected = model.selectedVoiceSlug == voice.slug
                Button {
                    model.selectedVoiceSlug = voice.slug
                    voicePickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        VoiceAvatarView(
                            slug: voice.slug,
                            name: voice.name,
                            avatarURL: model.voices.avatarURL(voice.slug),
                            size: 22)
                        Text(voice.name).foregroundStyle(Brand.fg)
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
            }
        }
        .padding(6)
        .frame(width: 240)
        .background(Brand.ink2)
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
