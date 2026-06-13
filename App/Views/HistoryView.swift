import EngineKit
import StudioKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var player = PreviewPlayer()
    @State private var version = 0
    @State private var query = ""
    @State private var confirmClear = false
    @State private var pendingDelete: HistoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Text("History")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Brand.fg)
                    Text("\(model.history.list().count)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.fgFaint)
                }
                Spacer()
                Button("Clear All", role: .destructive) {
                    confirmClear = true
                }
                .confirmationDialog(
                    "Remove all \(model.history.list().count) takes?",
                    isPresented: $confirmClear, titleVisibility: .visible
                ) {
                    Button("Move All to Trash", role: .destructive) {
                        _ = try? model.history.clear(); version += 1
                    }
                    .accessibilityIdentifier("confirm-clear-history")
                } message: {
                    Text("Takes go to the Trash and can be put back from there.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 6)
            TextField("Filter — text, voice, model…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityIdentifier("history-search")
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            List {
                if entries.isEmpty {
                    Text(query.isEmpty ? "No takes yet."
                                       : "No takes match “\(query)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.text ?? "—").lineLimit(2).truncationMode(.tail)
                        tagRow(entry)
                        HStack(spacing: 8) {
                            Button("Load") { reuse(entry) }
                                .accessibilityIdentifier("reuse-entry")
                                .help("Load this take's text, voice & settings back into the editor")
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            Button {
                                if let url = try? model.history.wavURL(entry.id) {
                                    player.toggle(id: entry.id, url: url)
                                }
                            } label: {
                                Image(systemName: player.playingID == entry.id ? "stop.fill" : "play.fill")
                            }
                            .accessibilityIdentifier("play-entry")
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            Button(role: .destructive) {
                                pendingDelete = entry
                            } label: { Image(systemName: "trash") }
                            .accessibilityIdentifier("delete-entry")
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .accessibilityIdentifier("history-list")
        }
        .confirmationDialog(
            "Move this take to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingDelete {
                    try? model.history.delete(entry.id); version += 1
                }
                pendingDelete = nil
            }
            .accessibilityIdentifier("confirm-delete-entry")
        } message: {
            Text(pendingDelete?.text.map { "“\($0)” can be put back from the Trash." }
                 ?? "The take can be put back from the Trash.")
        }
    }

    /// Small capsule chips showing what each take was generated with — model,
    /// voice, emotion — plus a monospaced duration/realtime caption.
    @ViewBuilder
    private func tagRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 4) {
            if let backend = entry.backend {
                chip(backend, tint: Brand.accent)
            }
            if let voice = entry.voice {
                chip(voice, tint: Brand.fgDim)
            }
            if let emotion = entry.emotion, emotion != "neutral" {
                chip(emotion, tint: Brand.fgDim)
            }
            Spacer(minLength: 4)
            Text(durationCaption(entry))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Brand.fgFaint)
        }
    }

    @ViewBuilder
    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
            .foregroundStyle(tint == Brand.accent ? Brand.accent : Brand.fgDim)
    }

    private func durationCaption(_ entry: HistoryEntry) -> String {
        var s = String(format: "%.1fs", entry.seconds)
        if let wallMs = entry.wallMs, wallMs > 0 {
            s += String(format: " · %.2fx", entry.seconds / (Double(wallMs) / 1000))
        }
        return s
    }

    private var entries: [HistoryEntry] {
        _ = version
        let all = model.history.list()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { entry in
            [entry.text, entry.voice, entry.backend, entry.emotion, entry.id]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(q) }
        }
    }

    private func reuse(_ entry: HistoryEntry) {
        model.text = entry.text ?? ""
        model.emotion = entry.emotion.flatMap(Emotion.init(rawValue:)) ?? .neutral
        if let voice = entry.voice { model.selectedVoiceSlug = voice }
        model.backend = BackendID(rawValue: entry.backend ?? "") ?? model.backend
    }
}
