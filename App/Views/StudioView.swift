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

    /// Same curated order as the toolbar's model picker — used to pick the
    /// best engine to offer when the current one can't render the voice.
    private static let packBarBackendOrder: [BackendID] =
        [.qwen06B, .qwen17B, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox, .kokoro,
         .supertonic, .luxTTS, .pocketTTS]

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
        if let slug = model.selectedVoiceSlug, let meta = try? model.voices.get(slug).meta {
            // Read voicesVersion so a saved transcript re-derives capabilities
            // (and re-lights the engine chips) without reselecting the voice.
            let _ = model.voicesVersion
            let caps = model.voices.capabilities(slug)
            let renderable = caps.supports(model.backend)
            let cloneActive = renderable && !caps.engines.contains(model.backend.rawValue)
            let cloneEngines = Self.packBarBackendOrder
                .filter { $0.controls.voiceClone != .none }.map(\.rawValue)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VoiceAvatarView(slug: slug, name: meta.name,
                                    avatarURL: model.voices.avatarURL(slug), size: 20)
                    Text(meta.name).font(.callout.weight(.semibold))
                    Text("This voice includes:").font(.caption).foregroundStyle(Brand.fgFaint)
                    if caps.hasSource {
                        packChip("voice recording", icon: "mic", active: cloneActive)
                            .help("Reference audio — any cloning engine can speak this voice: "
                                  + cloneEngines.joined(separator: ", "))
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
                    ForEach(caps.engines.sorted(), id: \.self) { engine in
                        packChip(engine, active: engine == model.backend.rawValue)
                            .help("Pre-rendered for \(engine) — speaks this voice with no recording needed")
                    }
                    Spacer(minLength: 0)
                }
                if !renderable {
                    // Every engine that can speak this voice, not one arbitrary
                    // pick: a clone ref unlocks the whole cloning roster, so a
                    // single suggestion would undersell the pack. Baked
                    // renditions sort first and say so.
                    let targets = Self.packBarBackendOrder
                        .filter { caps.supports($0) && model.hasSufficientRAM(for: $0) }
                        .sorted { caps.engines.contains($0.rawValue) && !caps.engines.contains($1.rawValue) }
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Text("\(model.backend.rawValue) can't speak this voice yet")
                            .font(.caption).foregroundStyle(Brand.fgDim)
                        // Engines the pack would support if only the transcript
                        // existed — shown disabled with the reason, so "why not
                        // qwen?" answers itself.
                        let transcriptLocked = Self.packBarBackendOrder.filter {
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    benchControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // TAKES shelf pinned to the bottom of the write column: new takes
            // are always in view without scrolling past the bench.
            if !model.variants.isEmpty {
                Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 8)
                zoneLabel("TAKES")
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.variants) { variant in
                            variantCard(variant)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .padding(.top, 6)
            }
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

    /// hexgrad's own per-voice quality grade (A best, F+ weakest) plus language and
    /// gender, keyed by voicepack name. Source: hexgrad/Kokoro-82M's VOICES.md + the
    /// vendored mlx-audio-swift README (fetched during design). "—" = ungraded there.
    static let kokoroVoiceInfo: [String: (language: String, gender: String, grade: String)] = [
        "af_heart": ("American English", "Female", "A"),
        "af_bella": ("American English", "Female", "A-"),
        "af_nicole": ("American English", "Female", "B-"),
        "af_aoede": ("American English", "Female", "C+"),
        "af_kore": ("American English", "Female", "C+"),
        "af_sarah": ("American English", "Female", "C+"),
        "af_alloy": ("American English", "Female", "C"),
        "af_nova": ("American English", "Female", "C"),
        "af_sky": ("American English", "Female", "C-"),
        "af_jessica": ("American English", "Female", "D"),
        "af_river": ("American English", "Female", "D"),
        "am_fenrir": ("American English", "Male", "C+"),
        "am_michael": ("American English", "Male", "C+"),
        "am_puck": ("American English", "Male", "C+"),
        "am_echo": ("American English", "Male", "D"),
        "am_eric": ("American English", "Male", "D"),
        "am_liam": ("American English", "Male", "D"),
        "am_onyx": ("American English", "Male", "D"),
        "am_santa": ("American English", "Male", "D-"),
        "am_adam": ("American English", "Male", "F+"),
        "bf_emma": ("British English", "Female", "B-"),
        "bf_isabella": ("British English", "Female", "C"),
        "bf_alice": ("British English", "Female", "D"),
        "bf_lily": ("British English", "Female", "D"),
        "bm_fable": ("British English", "Male", "C"),
        "bm_george": ("British English", "Male", "C"),
        "bm_lewis": ("British English", "Male", "D+"),
        "bm_daniel": ("British English", "Male", "D"),
        "ff_siwis": ("French", "Female", "B-"),
        "hf_alpha": ("Hindi", "Female", "C"),
        "hf_beta": ("Hindi", "Female", "C"),
        "hm_omega": ("Hindi", "Male", "C"),
        "hm_psi": ("Hindi", "Male", "C"),
        "if_sara": ("Italian", "Female", "C"),
        "im_nicola": ("Italian", "Male", "C"),
        "jf_alpha": ("Japanese", "Female", "C+"),
        "jf_gongitsune": ("Japanese", "Female", "C"),
        "jf_tebukuro": ("Japanese", "Female", "C"),
        "jf_nezumi": ("Japanese", "Female", "C-"),
        "jm_kumo": ("Japanese", "Male", "C-"),
        "ef_dora": ("Spanish", "Female", "—"),
        "em_alex": ("Spanish", "Male", "—"),
        "em_santa": ("Spanish", "Male", "—"),
        "pf_dora": ("Portuguese", "Female", "—"),
        "pm_alex": ("Portuguese", "Male", "—"),
        "pm_santa": ("Portuguese", "Male", "—"),
        "zf_xiaobei": ("Chinese", "Female", "D"),
        "zf_xiaoni": ("Chinese", "Female", "D"),
        "zf_xiaoxiao": ("Chinese", "Female", "D"),
        "zf_xiaoyi": ("Chinese", "Female", "D"),
        "zm_yunjian": ("Chinese", "Male", "D"),
        "zm_yunxi": ("Chinese", "Male", "D"),
        "zm_yunxia": ("Chinese", "Male", "D"),
        "zm_yunyang": ("Chinese", "Male", "D"),
    ]

    /// Display order for the grouped Kokoro speaker picker — matches the vendored
    /// README's language ordering.
    static let kokoroLanguageOrder = [
        "American English", "British English", "French", "Hindi", "Italian",
        "Japanese", "Spanish", "Portuguese", "Chinese",
    ]

    /// Voicepack names for one language, in `BackendID.kokoroVoices`' order.
    static func kokoroVoices(in language: String) -> [String] {
        BackendID.kokoroVoices.filter { kokoroVoiceInfo[$0]?.language == language }
    }

    /// Picker row label: "af_heart — A" so the grade is visible without opening
    /// the picker or selecting the voice first.
    static func kokoroVoiceLabel(_ name: String) -> String {
        guard let info = kokoroVoiceInfo[name] else { return name }
        return "\(name) — \(info.grade)"
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
            "Pick a built-in Speaker, then describe how it should talk. The identity stays fixed; your Direction shapes the delivery."
        case .fishS2Pro:
            "Clone a voice (optional). Emotion & sounds come from the [tags] above; fine-tune dynamics in Advanced. Free-text Direction isn't supported here."
        case .chatterbox:
            "Clone a voice and shape intensity with Emotion + Exaggeration. Free-text Direction isn't supported here."
        case .chatterboxTurbo:
            "Clone a voice; the emotional read comes from the reference clip. No manual delivery knobs."
        case .kokoro:
            "Pick a preset voice — Kokoro doesn't clone or take free-text direction. Quality "
            + "varies a lot by voice; the grade shown is the model author's own rating."
        case .luxTTS:
            "Clones a voice from a reference clip — the prosody comes entirely from that clip. "
            + "No free-text Direction; tune the flow-matching steps/guidance in Advanced instead."
        case .supertonic:
            "Pick a preset voice — SuperTonic doesn't clone or take free-text direction. "
            + "Fast, multilingual, 44.1 kHz."
        case .pocketTTS:
            "Clones a voice from a reference clip (first ~10s) — the prosody comes from that "
            + "clip. No free-text Direction and no delivery knobs; each take samples fresh."
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

            // Speaker (CustomVoice / Kokoro)
            if !controls.presetSpeakers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    // Label above, picker full-width — the inspector column is
                    // narrow and resizable, so no fixed 220pt row here.
                    Text("Speaker").font(.caption).foregroundStyle(Brand.fgDim)
                    if model.backend == .kokoro {
                        Picker("", selection: $model.speaker) {
                            ForEach(Self.kokoroLanguageOrder, id: \.self) { lang in
                                Section(lang) {
                                    ForEach(Self.kokoroVoices(in: lang), id: \.self) { name in
                                        Text(Self.kokoroVoiceLabel(name)).tag(name)
                                    }
                                }
                            }
                        }.labelsHidden().frame(maxWidth: 260, alignment: .leading)
                    } else {
                        Picker("", selection: $model.speaker) {
                            ForEach(controls.presetSpeakers, id: \.self) { name in
                                Text(Self.speakerLabel(name)).tag(name)
                            }
                        }.labelsHidden().frame(maxWidth: 260, alignment: .leading)
                    }
                    if model.backend == .kokoro {
                        if let info = Self.kokoroVoiceInfo[model.speaker] {
                            Text("\(info.language) · \(info.gender) · Grade \(info.grade)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("A fixed pretrained voicepack — grade is the model author's own "
                             + "quality rating (A best, F+ weakest). No cloning or Direction here.")
                            .font(.caption2).foregroundStyle(Brand.fgFaint)
                    } else if model.backend == .supertonic {
                        Text("A fixed preset voice style (M1–M5 male, F1–F5 female) shipped "
                             + "with the model. No cloning, emotion, or Direction here.")
                            .font(.caption2).foregroundStyle(Brand.fgFaint)
                    } else {
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
