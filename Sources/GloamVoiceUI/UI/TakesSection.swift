import SwiftUI
import UniformTypeIdentifiers

/// The recordings a voice is learned from, one row each, inside the
/// Advanced screen's `Form`. State lives in `TakesModel`, shared with the
/// basic screen. A voice that came with a master and no takes shows that
/// master as one read-only row until a take joins it.
public struct TakesSection: View {
    let voice: Voice
    @ObservedObject var model: TakesModel
    @ObservedObject var player: VoicePlayer
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t

    public init(voice: Voice, model: TakesModel, player: VoicePlayer) {
        self.voice = voice; self.model = model; self.player = player
    }

    @State private var playingID: Int?
    @State private var recording = false
    @State private var importing = false
    /// "Import a take" before the host's consent was given: the sheet, then the importer.
    @State private var askingConsent = false
    /// An imported clip waiting for its words.
    @State private var pendingImport: ClipImport.Imported?
    @State private var pendingText = ""
    @State private var transcribing = false
    @State private var editing: VoiceTake?
    @State private var editText = ""
    @State private var errorText: String?

    private var book: VoiceTakes { model.book }

    public var body: some View {
        Section {
            if book.takes.isEmpty, voice.hasMaster {
                masterRow
            }
            ForEach(book.takes) { take in
                takeRow(take)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if playingID == take.id { player.stop(); playingID = nil }
                            model.delete(take)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            // Presentations sit on single rows, never on the Section: a
            // modifier on a Section is applied to every row it holds, and
            // several presenters sharing one binding drop the presentation.
            recordRow
            Button(transcribing ? "Listening to the file…" : "Import a take", systemImage: "square.and.arrow.down") {
                player.stop()
                // The importer opens only after the host's one-time consent.
                if host.capabilities.consent?.isRequired() == true { askingConsent = true } else { importing = true }
            }
            .font(t.sans(14)).tint(t.accent)
            .disabled(transcribing)
            .sheet(isPresented: $askingConsent) {
                if let gate = host.capabilities.consent {
                    gate.sheet(
                        { askingConsent = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { importing = true } },
                        { askingConsent = false })
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let u = urls.first { importClip(u) }
                case .failure(let e): errorText = e.localizedDescription
                }
            }
            .sheet(item: $pendingImport) { imported in
                TakeTranscriptSheet(
                    title: "What's said in it?",
                    caption: String(format: "%.1fs%@ — fix anything wrong; the voice learns from these words as much as the audio.",
                                    imported.seconds, imported.trimmed ? ", trimmed to fit the reference window" : ""),
                    text: $pendingText, busy: transcribing,
                    onSave: { text in pendingImport = nil; model.add(imported.url, text, origin: .imported) },
                    onCancel: { pendingImport = nil })
            }
            if let text = errorText ?? model.errorText {
                Text(text).font(t.sans(12)).foregroundStyle(t.peak)
            }
        } header: {
            Text("Takes").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !book.takes.isEmpty {
                    Text(TakeRules.lengthLine(combinedSeconds: book.combinedSeconds))
                }
                if book.masterStale {
                    Text(model.state.blocker ?? "Save rebuilds the master from these takes.")
                        .foregroundStyle(model.state.blocker == nil ? t.accent : t.peak)
                } else if book.takes.isEmpty {
                    Text("More takes make a steadier voice. Each is checked and transcribed the way a clone recording is; the first take you add keeps the current master as take 1.")
                } else {
                    Text("The master is built from these takes.")
                }
            }
            .font(t.sans(11)).foregroundStyle(t.fgFaint)
        }
        .listRowBackground(t.panel)
    }

    /// "Record a take", plus the sheet that edits a take's words. The sheet
    /// stays when recording is off (a host without a microphone path can
    /// still correct what a take says), on a row of no height.
    @ViewBuilder
    private var recordRow: some View {
        if host.capabilities.canRecord {
            Button("Record a take", systemImage: "mic.badge.plus") { player.stop(); recording = true }
                .font(t.sans(14)).tint(t.accent)
                .voiceCover(isPresented: $recording) {
                    TakeRecorderView(title: "New take", script: TakeScripts.readLine,
                                     onDone: { clip, text in recording = false; model.add(clip, text, origin: .recorded) },
                                     onCancel: { recording = false })
                }
                .sheet(item: $editing) { editSheet($0) }
        } else {
            Color.clear.frame(height: 0).listRowInsets(EdgeInsets())
                .sheet(item: $editing) { editSheet($0) }
        }
    }

    private func editSheet(_ take: VoiceTake) -> some View {
        TakeTranscriptSheet(
            title: "Take \(take.id)", caption: "The words this take says. They must match the audio.",
            text: $editText,
            onSave: { text in editing = nil; model.updateTranscript(take, text) },
            onCancel: { editing = nil })
    }

    // MARK: rows

    private var masterRow: some View {
        HStack(spacing: 12) {
            playButton(id: 0, url: host.store.masterURL(of: voice.slug))
            VStack(alignment: .leading, spacing: 2) {
                Text("Master").font(t.sans(14)).foregroundStyle(t.fg)
                Text(voice.refText).font(t.sans(12)).foregroundStyle(t.fgFaint).lineLimit(2)
            }
            Spacer()
            if let seconds = model.masterSeconds {
                Text(Self.timeString(seconds)).font(t.console(12)).foregroundStyle(t.fgFaint)
            }
        }
    }

    private func takeRow(_ take: VoiceTake) -> some View {
        HStack(spacing: 12) {
            playButton(id: take.id, url: host.store.takeURL(of: voice.slug, id: take.id))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Take \(take.id)").font(t.sans(14)).foregroundStyle(t.fg)
                    Text(Self.timeString(take.seconds)).font(t.console(12)).foregroundStyle(t.fgFaint)
                    if take.origin != .recorded {
                        Text(take.origin == .master ? "master" : "imported")
                            .font(t.console(10)).foregroundStyle(t.fgFaint)
                    }
                }
                Text(take.transcript.isEmpty ? "No words yet — tap to add them" : take.transcript)
                    .font(t.sans(12)).foregroundStyle(take.transcript.isEmpty ? t.peak : t.fgFaint).lineLimit(2)
                hygieneLabel(for: take)
            }
            .contentShape(Rectangle())
            .onTapGesture { editText = take.transcript; editing = take }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("take-row-\(take.id)")
    }

    @ViewBuilder
    private func hygieneLabel(for take: VoiceTake) -> some View {
        switch model.verdicts[take.id] {
        case .good?:
            Label("Good take", systemImage: "checkmark.circle").font(t.sans(11)).foregroundStyle(t.fgFaint)
        case .warning(let why)?:
            Label(why, systemImage: "exclamationmark.triangle").font(t.sans(11)).foregroundStyle(t.violet)
        case .error(let why)?:
            Label(why, systemImage: "exclamationmark.triangle.fill").font(t.sans(11)).foregroundStyle(t.peak)
        case nil:
            EmptyView()
        }
    }

    private func playButton(id: Int, url: URL?) -> some View {
        let playing = player.isPlaying && playingID == id
        return Button {
            if playing { player.stop(); playingID = nil; return }
            guard let url else { return }
            player.stop()
            do { try player.play(fileURL: url); playingID = id } catch { errorText = userMessage(for: error) }
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(t.ink)
                .frame(width: 32, height: 32).background(Circle().fill(t.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Stop" : "Play")
    }

    /// Normalise the file, then hear what it says; the words are shown for
    /// correction before the take is kept, as the clone flow does.
    private func importClip(_ src: URL) {
        errorText = nil
        do {
            let prepared = try ClipImport.prepare(src)
            pendingText = ""
            transcribing = true
            Task {
                defer { transcribing = false }
                // Let the file picker finish dismissing before the sheet
                // goes up, or SwiftUI drops one of the two presentations.
                try? await Task.sleep(for: .milliseconds(350))
                pendingImport = prepared
                if let transcribe = host.capabilities.transcribe {
                    do { pendingText = try await transcribe(prepared.url) }
                    catch { pendingText = ""; errorText = error.localizedDescription }
                }
            }
        } catch { errorText = error.localizedDescription }
    }

    static func timeString(_ seconds: Double) -> String { VoiceTime.string(seconds) }
}

extension ClipImport.Imported: Identifiable {
    public var id: String { url.path }
}

/// The lines people read into the mic. One place, so the clone flow, a new
/// take and an emotion version all agree on what "the script" is.
public enum TakeScripts {
    /// A few seconds of natural speech clones best.
    public static let readLine = "I'm reading this out loud so the app can learn how I speak. I'll keep it natural, the way I'd talk to a friend, and in a few seconds it should have everything it needs."
}
