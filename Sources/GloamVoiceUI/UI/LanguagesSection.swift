import SwiftUI

/// The voice's languages, inside the editor's `Form`: the default language (a picker once there is
/// more than one), one row per language reference (name, words, play, swipe to delete), and
/// "Add a language…", which picks from a fixed list and then records or imports a reference with
/// its transcript. A language is its own reference, never an emotion version.
struct LangPick: Identifiable { let code: String; var id: String { code } }

struct LanguagesSection: View {
    let voice: Voice
    @ObservedObject var player: VoicePlayer
    @Binding var defaultLanguage: String
    let showsDefaultPicker: Bool
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t
    @State private var choosing = false
    @State private var picked: String?
    @State private var recording: LangPick?
    @State private var importing = false
    @State private var pendingImport: ClipImport.Imported?
    @State private var pendingText = ""
    @State private var transcribing = false
    @State private var playing: String?
    @State private var errorText: String?

    static let choices: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("pt", "Portuguese"), ("it", "Italian"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]
    static func name(_ code: String) -> String {
        choices.first { $0.code == code }?.name ?? (Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? code)
    }

    private var store: any VoiceLibraryStore { host.store }
    private var refs: [LanguageReference] { store.languageReferences(of: voice.slug) }
    private var available: [(code: String, name: String)] {
        let have = Set(refs.map(\.language))
        return Self.choices.filter { !have.contains($0.code) }
    }

    var body: some View {
        Section {
            let langs = store.languages(of: voice.slug)
            if showsDefaultPicker, langs.count > 1 {
                Picker("Default language", selection: $defaultLanguage) {
                    Text("Automatic").tag("")
                    ForEach(langs, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                .font(t.sans(15)).tint(t.accent)
            }
            ForEach(refs) { ref in
                row(ref)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if playing == ref.language { player.stop(); playing = nil }
                            do { try store.removeLanguageReference(voice.slug, language: ref.language) }
                            catch { errorText = userMessage(for: error) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            if !available.isEmpty {
                Button("Add a language…", systemImage: "globe") { player.stop(); choosing = true }
                    .font(t.sans(14)).tint(t.accent)
                    .accessibilityIdentifier("add-language")
                    .confirmationDialog("Which language?", isPresented: $choosing, titleVisibility: .visible) {
                        ForEach(available, id: \.code) { lang in
                            Button(lang.name) {
                                Task { try? await Task.sleep(for: .milliseconds(350)); picked = lang.code }
                            }
                        }
                    }
                    .confirmationDialog("Reference for \(picked.map(Self.name) ?? "")", isPresented: pickedBinding,
                                        titleVisibility: .visible) {
                        if host.capabilities.canRecord {
                            Button("Record it") {
                                let code = picked
                                picked = nil
                                Task { try? await Task.sleep(for: .milliseconds(350)); recording = code.map(LangPick.init) }
                            }
                        }
                        Button("Import a recording") {
                            importing = true
                        }
                        Button("Cancel", role: .cancel) { picked = nil }
                    }
                    .voiceCover(item: $recording) { pick in
                        let code = pick.code
                        TakeRecorderView(title: "\(Self.name(code)) reference", script: TakeScripts.readLine,
                                         onDone: { clip, text in recording = nil; save(code, clip: clip, text: text) },
                                         onCancel: { recording = nil })
                    }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                        switch result {
                        case .success(let urls): if let u = urls.first { importClip(u) }
                        case .failure(let e): errorText = e.localizedDescription; picked = nil
                        }
                    }
                    .sheet(item: $pendingImport) { imported in
                        TakeTranscriptSheet(
                            title: "What's said in it?",
                            caption: String(format: "%.1fs — the words in this language, exactly as spoken.", imported.seconds),
                            text: $pendingText, busy: transcribing,
                            onSave: { text in
                                pendingImport = nil
                                if let code = picked { save(code, clip: imported.url, text: text) }
                                picked = nil
                            },
                            onCancel: { pendingImport = nil; picked = nil })
                    }
            }
            if let errorText { Text(errorText).font(t.sans(12)).foregroundStyle(t.peak) }
        } header: {
            Text("Languages").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
        } footer: {
            Text("Each language is its own reference recording and transcript, used when the voice speaks it. They travel inside the pack.")
                .font(t.sans(11)).foregroundStyle(t.fgFaint)
        }
        .listRowBackground(t.panel)
    }

    private var pickedBinding: Binding<Bool> {
        Binding(get: { picked != nil && !importing && recording == nil && pendingImport == nil },
                set: { if !$0, !importing, recording == nil, pendingImport == nil { picked = nil } })
    }

    private func row(_ ref: LanguageReference) -> some View {
        let isPlaying = player.isPlaying && playing == ref.language
        return HStack(spacing: 12) {
            Button {
                if isPlaying { player.stop(); playing = nil; return }
                guard let url = ref.url else { return }
                player.stop()
                do { try player.play(fileURL: url, gain: host.outputGain(for: voice)); playing = ref.language }
                catch { errorText = userMessage(for: error) }
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(t.ink)
                    .frame(width: 32, height: 32).background(Circle().fill(t.accent))
            }
            .buttonStyle(.plain)
            .disabled(ref.url == nil)
            .accessibilityLabel(isPlaying ? "Stop" : "Play \(Self.name(ref.language))")
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(ref.language)).font(t.sans(14)).foregroundStyle(t.fg)
                Text(ref.text).font(t.sans(12)).foregroundStyle(t.fgFaint).lineLimit(2)
            }
            Spacer()
        }
        .accessibilityIdentifier("language-\(ref.language)")
    }

    private func save(_ code: String, clip: URL, text: String) {
        do {
            let samples = try VoiceAudio.loadWav24k(clip)
            let wav = VoicePlayer.wavData(samples: samples, sampleRate: 24_000)
            try store.addLanguageReference(voice.slug, language: code, wav: wav,
                                           transcript: text.trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(at: clip)
            errorText = nil
        } catch { errorText = userMessage(for: error) }
    }

    private func importClip(_ src: URL) {
        errorText = nil
        do {
            let prepared = try ClipImport.prepare(src)
            pendingText = ""
            transcribing = true
            Task {
                defer { transcribing = false }
                try? await Task.sleep(for: .milliseconds(350))
                pendingImport = prepared
                if let transcribe = host.capabilities.transcribe {
                    do { pendingText = try await transcribe(prepared.url) }
                    catch { pendingText = ""; errorText = error.localizedDescription }
                }
            }
        } catch { errorText = error.localizedDescription }
    }
}
