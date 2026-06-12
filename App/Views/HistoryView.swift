import EngineKit
import StudioKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var player = PreviewPlayer()
    @State private var version = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.title3.bold())
                Spacer()
                Button("Clear All", role: .destructive) {
                    _ = try? model.history.clear(); version += 1
                }
            }
            .padding(14)
            Divider()
            List {
                ForEach(entries, id: \.id) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text ?? "—").lineLimit(2)
                            Text(meta(entry))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reuse") { reuse(entry) }
                            .accessibilityIdentifier("reuse-entry")
                        Button(player.playingID == entry.id ? "Stop" : "Play") {
                            if let url = try? model.history.wavURL(entry.id) {
                                player.toggle(id: entry.id, url: url)
                            }
                        }
                        Button(role: .destructive) {
                            try? model.history.delete(entry.id); version += 1
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
            .accessibilityIdentifier("history-list")
        }
    }

    private var entries: [HistoryEntry] {
        _ = version
        return model.history.list()
    }

    private func meta(_ entry: HistoryEntry) -> String {
        var parts: [String] = [entry.id]
        if let backend = entry.backend { parts.append(backend) }
        if let voice = entry.voice { parts.append(voice) }
        if let emotion = entry.emotion { parts.append(emotion) }
        parts.append(String(format: "%.1fs", entry.seconds))
        if let wallMs = entry.wallMs, wallMs > 0 {
            parts.append(String(format: "%.2fx", entry.seconds / (Double(wallMs) / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    private func reuse(_ entry: HistoryEntry) {
        model.text = entry.text ?? ""
        model.emotion = entry.emotion.flatMap(Emotion.init(rawValue:)) ?? .neutral
        if let voice = entry.voice { model.selectedVoiceSlug = voice }
        model.backend = BackendID(rawValue: entry.backend ?? "") ?? model.backend
    }
}
