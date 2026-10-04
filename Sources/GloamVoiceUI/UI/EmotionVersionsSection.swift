import SwiftUI

/// The voice's acted versions, inside the editor's `Form`: one row per
/// variant (key, length, play, swipe to delete) and "Add emotion version…",
/// which picks an emotion and opens the recorder on the fixed passage with
/// that emotion's delivery note. The take goes through the same check and
/// transcription as any other before it is kept.
struct EmotionVersionsSection: View {
    let voice: Voice
    @ObservedObject var player: VoicePlayer
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t
    @State private var choosing = false
    @State private var recording: EmotionOption?
    @State private var playingKey: String?
    @State private var errorText: String?

    private var store: any VoiceLibraryStore { host.store }
    /// Language references are not emotions: never listed here, whatever the store's variant keys say.
    private var emotionKeys: [String] {
        let langs = Set(store.languageReferences(of: voice.slug).map(\.language))
        return voice.variantKeys.filter { !langs.contains($0) }
    }
    private var available: [EmotionOption] {
        EmotionVersions.available(existingKeys: emotionKeys, options: store.emotionOptions)
    }

    var body: some View {
        Section {
            ForEach(emotionKeys, id: \.self) { key in
                row(key)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if playingKey == key { player.stop(); playingKey = nil }
                            store.deleteVariant(of: voice, key: key)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            if !available.isEmpty, host.capabilities.canRecord {
                Button("Add emotion version…", systemImage: "theatermasks") { player.stop(); choosing = true }
                    .font(t.sans(14)).tint(t.accent)
                    .confirmationDialog("Which emotion?", isPresented: $choosing, titleVisibility: .visible) {
                        ForEach(available) { emotion in
                            Button(emotion.label) {
                                // Let the dialog finish dismissing before the
                                // cover goes up, or SwiftUI drops one of them.
                                Task { try? await Task.sleep(for: .milliseconds(350)); recording = emotion }
                            }
                        }
                    }
                    // On the button, not the Section: a modifier on a Section
                    // is applied to every row, and several presenters sharing
                    // one binding drop the presentation.
                    .voiceCover(item: $recording) { emotion in
                        TakeRecorderView(
                            title: "\(emotion.key) take", script: EmotionScript.passage,
                            note: emotion.deliveryNote,
                            onDone: { clip, text in
                                recording = nil
                                do {
                                    try store.addVariant(of: voice, key: emotion.key, clip: clip, transcript: text)
                                    try? FileManager.default.removeItem(at: clip)
                                    errorText = nil
                                } catch { errorText = userMessage(for: error) }
                            },
                            onCancel: { recording = nil })
                    }
            }
            if let errorText { Text(errorText).font(t.sans(12)).foregroundStyle(t.peak) }
        } header: {
            Text("Emotion versions").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
        } footer: {
            Text("The same passage read in character — flat, warm, hype — so a script can ask for a mood. Each version travels inside the pack.")
                .font(t.sans(11)).foregroundStyle(t.fgFaint)
        }
        .listRowBackground(t.panel)
    }

    private func row(_ key: String) -> some View {
        let slug = EmotionVersions.slug(base: voice.slug, key: key)
        let playing = player.isPlaying && playingKey == key
        return HStack(spacing: 12) {
            Button {
                if playing { player.stop(); playingKey = nil; return }
                guard let url = store.referenceURL(of: slug) else { return }
                player.stop()
                do { try player.play(fileURL: url, gain: host.outputGain(for: voice)); playingKey = key }
                catch { errorText = userMessage(for: error) }
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(t.ink)
                    .frame(width: 32, height: 32).background(Circle().fill(t.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Stop" : "Play \(key)")
            Text(key.capitalized).font(t.sans(14)).foregroundStyle(t.fg)
            Spacer()
            if let seconds = store.masterSeconds(of: slug) {
                Text(VoiceTime.string(seconds)).font(t.console(12)).foregroundStyle(t.fgFaint)
            }
        }
        .accessibilityIdentifier("emotion-\(key)")
    }
}
