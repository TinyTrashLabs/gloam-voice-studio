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
    @State private var historyPresented = false
    @AppStorage("studioMode") private var modeRaw: String = StudioMode.single.rawValue

    private var mode: StudioMode {
        StudioMode(rawValue: modeRaw) ?? .single
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            BrandLockup()
                .padding(.bottom, 4)
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
        .inspector(isPresented: $historyPresented) {
            HistoryView()
                .inspectorColumnWidth(min: 300, ideal: 360)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                benchControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var benchControls: some View {
        @Bindable var model = model
        TextEditor(text: $model.text)
            .font(.system(.body, design: .monospaced))
            .frame(height: 110)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .accessibilityIdentifier("line-editor")
        if model.backend.spec.honorsTags {
            TagChipsView(text: $model.text)
        }

        HStack(spacing: 16) {
            Picker("Emotion", selection: $model.emotion) {
                ForEach(AppModel.emotionOrder, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .help("Pick the emotional read; uses an acted '-emotion' reference variant when one exists")
            HStack(spacing: 6) {
                Text("Speed")
                Slider(value: $model.speed, in: 0.5...2.0, step: 0.05)
                    .frame(width: 140)
                    .help("Adjust speech rate (0.5x–2.0x)")
                Text(String(format: "%.2f×", model.speed))
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }

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
            Button("History") { historyPresented.toggle() }
                .accessibilityIdentifier("open-history")
                .help("Toggle the history panel")
        }

        if let error = model.generationError {
            Text(error).foregroundStyle(.red).font(.callout)
                .accessibilityIdentifier("generation-error")
        }

        VStack(spacing: 10) {
            ForEach(model.variants) { variant in
                variantCard(variant)
            }
        }
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
    }

}
