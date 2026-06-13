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

    @ViewBuilder
    private var benchControls: some View {
        @Bindable var model = model

        // ── VOICE picker ────────────────────────────────────────────────────
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

        // ── WRITE zone ──────────────────────────────────────────────────────
        zoneLabel("WRITE")
        HStack(alignment: .top, spacing: 8) {
            TextEditor(text: $model.text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
                .accessibilityIdentifier("line-editor")
            DictationButton(text: $model.text)
        }
        if model.backend.spec.honorsTags {
            TagChipsView(text: $model.text)
        }

        // ── DIRECT zone (inset card) ─────────────────────────────────────────
        Divider().overlay(Color.white.opacity(0.06))
        zoneLabel("DIRECT")
        VStack(alignment: .leading, spacing: 8) {
            // Emotion chips wrap naturally — no ViewThatFits needed
            HStack {
                Text("Emotion").font(.caption).foregroundStyle(Brand.fgDim)
                Spacer()
            }
            emotionPicker
            speedControls

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replace the emotion presets with manual knobs: Temperature controls how adventurous Fish's delivery is; Exaggeration drives Chatterbox's intensity.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Use manual knobs", isOn: $model.useDirectionOverrides)
                        .help("Enable manual temperature and exaggeration controls")
                    if model.useDirectionOverrides {
                        if model.backend.spec.honorsTags {
                            HStack {
                                Text("Temperature")
                                Slider(value: $model.temperatureOverride,
                                       in: 0.3...1.2).frame(width: 160)
                                    .help("How adventurous Fish's delivery is")
                                Text(String(format: "%.2f", model.temperatureOverride))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if model.backend == .chatterbox {
                            HStack {
                                Text("Exaggeration")
                                Slider(value: $model.exaggerationOverride,
                                       in: 0...1).frame(width: 160)
                                    .help("Drive Chatterbox's intensity")
                                Text(String(format: "%.2f", model.exaggerationOverride))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if !model.backend.spec.honorsTags && model.backend != .chatterbox {
                            Text("chatterbox-turbo ignores direction knobs — emotion comes from acted reference variants.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Label("Fine-tune delivery (advanced)", systemImage: "slider.horizontal.3")
            }
            .font(.callout)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))

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
