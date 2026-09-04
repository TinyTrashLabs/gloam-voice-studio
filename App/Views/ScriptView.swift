import EngineKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

struct ScriptView: View {
    @Environment(AppModel.self) private var model
    @State private var player = PreviewPlayer()
    @State private var exportSheet = false

    var body: some View {
        let script = model.script
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Add Line") { script.addLine() }
                    .accessibilityIdentifier("add-line")
                    .help("Add a new script line")
                Button("Add Pause") { script.addPause() }
                    .accessibilityIdentifier("add-pause")
                    .help("Add a beat of silence between lines")
                Button(script.isBatchRunning ? "Generating…" : generateAllTitle) {
                    Task {
                        if model.backend == .dia2 {
                            await model.generateDialogueScenes()
                        } else {
                            await script.generateAll()
                        }
                    }
                }
                .disabled(script.isBatchRunning)
                .accessibilityIdentifier("generate-all")
                .help(model.backend == .dia2
                      ? "Generate every scene as a two-voice pass"
                      : "Generate all lines in the script")
                if script.isBatchRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Export…") { exportSheet = true }
                    .disabled(script.session.lines.allSatisfy { $0.takes.isEmpty })
                    .accessibilityIdentifier("script-export")
                    .help("Export all lines as a stitched WAV")
            }
            sceneBanner
            List {
                ForEach(script.session.lines) { line in
                    LineRow(line: line, playingTake: Binding(get: { player.playingID }, set: { _ in }), play: { id in
                        if let data = model.script.takeWavData(id) {
                            player.toggle(id: id, data: data)
                        }
                    })
                }
                .onMove { script.moveLines(from: $0, to: $1) }
            }
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $exportSheet) { ScriptExportSheet() }
    }

    private var generateAllTitle: String {
        model.backend == .dia2 ? "Generate Scenes" : "Generate All"
    }

    /// Dia2 speaks two voices per pass, so a three-person script is split. Say
    /// so before the button is pressed rather than explaining it afterwards.
    @ViewBuilder private var sceneBanner: some View {
        if model.backend == .dia2 {
            let report = model.script.sceneReport
            if report.sceneCount > 1 {
                let numbers = report.splitAfterLines.map { String($0 + 1) }
                Text("This script needs \(report.sceneCount) passes — Dia2 speaks two "
                     + "voices at a time. New scenes start after line "
                     + numbers.joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(Brand.fgDim)
                    .accessibilityIdentifier("dialogue-scene-report")
            }
        }
    }
}

private struct LineRow: View {
    let line: ScriptLine
    @Binding var playingTake: String?
    let play: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        if let seconds = line.pauseSeconds {
            pauseRow(seconds)
        } else {
            speechRow
        }
    }

    private func pauseRow(_ seconds: Double) -> some View {
        let script = model.script
        return HStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .foregroundStyle(Brand.fgDim)
                .accessibilityHidden(true)
            Text("Pause").foregroundStyle(Brand.fgDim)
            Stepper(String(format: "%.1fs", seconds),
                    value: Binding(
                        get: { seconds },
                        set: { v in script.update(line.id) { $0.kind = .pause(seconds: v) } }),
                    in: 0.1...10, step: 0.1)
                .frame(maxWidth: 160)
                .accessibilityIdentifier("pause-seconds")
            Spacer()
            Button(role: .destructive) { script.removeLine(line.id) } label: {
                Image(systemName: "trash")
            }
            .help("Delete this pause")
            .accessibilityLabel("Delete Line")
        }
        .padding(.vertical, 4)
    }

    private var speechRow: some View {
        let script = model.script
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .help("Takes & direction")
                .accessibilityIdentifier("expand-line")
                .accessibilityLabel(expanded ? "Collapse Takes & Direction" : "Expand Takes & Direction")
                statusDot
                TextField("Line text", text: Binding(
                    get: { line.text },
                    set: { text in script.update(line.id) { $0.text = text } }),
                    axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("script-line-text")
                DictationButton(text: Binding(
                    get: { line.text },
                    set: { text in script.update(line.id) { $0.text = text } }))
                let lineStatus = script.status[line.id] ?? .idle
                if case .generating = lineStatus {
                    ProgressView().controlSize(.small)
                } else if case .queued = lineStatus {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await script.generate(lineID: line.id) } } label: {
                        Image(systemName: "waveform.badge.plus")
                    }
                    .help("Generate this line")
                    .accessibilityIdentifier("generate-line")
                    .accessibilityLabel("Generate This Line")
                }
                Button(role: .destructive) { script.removeLine(line.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this line")
                .accessibilityLabel("Delete Line")
            }
            if case .failed(let message) = script.status[line.id] ?? .idle {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if expanded {
                directionRow
                takesList
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusDot: some View {
        let status = model.script.status[line.id] ?? .idle
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }

    private func statusColor(_ status: ScriptModel.LineStatus) -> Color {
        switch status {
        case .idle: line.takes.isEmpty ? Brand.fgFaint : Brand.accent
        case .queued: .yellow
        case .generating: .orange
        case .failed: .red
        }
    }

    private var directionRow: some View {
        let script = model.script
        return HStack(spacing: 10) {
            Picker("Voice", selection: Binding(
                get: { line.voiceSlug ?? "" },
                set: { v in script.update(line.id) { $0.voiceSlug = v.isEmpty ? nil : v } })) {
                Text("Session voice").tag("")
                ForEach(model.voices.list(), id: \.slug) {
                    Text($0.name).tag($0.slug)
                }
            }
            .frame(maxWidth: 180)
            Picker("Emotion", selection: Binding(
                get: { line.emotion ?? "" },
                set: { e in script.update(line.id) { $0.emotion = e.isEmpty ? nil : e } })) {
                Text("Default").tag("")
                ForEach(AppModel.emotionOrder, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0.rawValue)
                }
            }
            .frame(maxWidth: 160)
            Spacer()
        }
        .font(.caption)
    }

    @ViewBuilder private var takesList: some View {
        let script = model.script
        ForEach(line.takes) { take in
            HStack(spacing: 8) {
                Button {
                    script.star(line.id, takeID: take.id)
                } label: {
                    Image(systemName: line.starredTakeID == take.id
                          ? "star.fill" : "star")
                }
                .help("Use this take in exports")
                .accessibilityIdentifier("star-take")
                .accessibilityLabel(line.starredTakeID == take.id ? "Starred Take" : "Star This Take")
                if let wav = script.takeWavData(take.id) {
                    WaveformView(wavData: wav).frame(width: 160, height: 24)
                }
                Text(String(format: "%.2fs · %.2fx", take.seconds,
                            take.wallSeconds > 0 ? take.seconds / take.wallSeconds : 0))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
                Button(playingTake == take.id ? "Stop" : "Play") { play(take.id) }
                    .font(.caption)
                Button(role: .destructive) {
                    script.deleteTake(line.id, takeID: take.id)
                } label: { Image(systemName: "trash") }
                .controlSize(.small)
                .help("Delete this take")
                .accessibilityLabel("Delete Take")
                Spacer()
            }
            .padding(.leading, 16)
        }
    }
}

struct ScriptExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gapSeconds = 0.6
    @State private var normalize = true
    @State private var exportDoc: DataDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Script").font(.title3.bold())
            Text("Stitches the starred (or newest) take of every line into one WAV.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Gap between lines")
                Slider(value: $gapSeconds, in: 0...2, step: 0.1).frame(width: 160)
                Text(String(format: "%.1fs", gapSeconds))
                    .font(.system(.caption, design: .monospaced))
            }
            Toggle("Peak-normalize output", isOn: $normalize)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export WAV…") { buildExport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .fileExporter(isPresented: .init(get: { exportDoc != nil },
                                         set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .wav,
                      defaultFilename: "gloam-script") { _ in
            exportDoc = nil
            dismiss()
        }
    }

    private func buildExport() {
        guard let (pcms, rate) = model.script.exportPCMs() else { return }
        var stitched = AudioAssembler.stitch(pcms, sampleRate: rate,
                                             gapSeconds: gapSeconds)
        if normalize { stitched = AudioAssembler.normalizePeak(stitched) }
        exportDoc = DataDocument(data: WAVEncoder.encode(
            pcm16: stitched, sampleRate: rate,
            provenance: WAVEncoder.provenanceComment))
    }
}
