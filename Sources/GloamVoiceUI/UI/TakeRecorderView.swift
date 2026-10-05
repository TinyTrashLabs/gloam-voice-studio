import SwiftUI

/// Record one take for a voice that already exists: the line to read, the
/// orb, and the same check the clone flow makes before it trusts a
/// recording (`RecordingCheck`, then on-device transcription -- the script
/// if it was read, what was heard if it was not). No clone, no preview, no
/// naming: the take joins the voice and Save rebuilds the master.
///
/// `script` is the line on screen and the transcript when it is read as
/// written; `note` sits above it (an emotion's delivery note, or nothing).
public struct TakeRecorderView: View {
    let title: String
    let script: String
    var note: String? = nil
    /// The take on disk and the words it says.
    var onDone: (_ clip: URL, _ transcript: String) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t

    public init(title: String, script: String, note: String? = nil,
                onDone: @escaping (_ clip: URL, _ transcript: String) -> Void,
                onCancel: @escaping () -> Void) {
        self.title = title; self.script = script; self.note = note
        self.onDone = onDone; self.onCancel = onCancel
    }

    /// Its own file, not the clone flow's durable one (see `CloneRecorder.url`).
    @StateObject private var rec = CloneRecorder(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).caf"))
    @State private var checking = false
    @State private var problem: String?
    /// The ad-lib route: what was heard, shown for correction.
    @State private var heard: String?
    @State private var correction = ""
    @State private var clip: URL?
    /// The host's one-time consent sheet (`ConsentGate`), when it has one.
    @State private var needsConsent = false

    public var body: some View {
        ZStack {
            t.ground
            VStack(spacing: 0) {
                HStack {
                    Button(action: { rec.stop(); onCancel() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(t.fgDim)
                            .frame(width: 38, height: 38).background(Circle().fill(t.panel))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(title.uppercased()).font(t.console(10, .medium)).tracking(2.4).foregroundStyle(t.fgDim)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 18).padding(.top, 12)
                if heard != nil { correctionAct } else { recordAct }
            }
        }
        .preferredColorScheme(.dark)
        // The mic prompt waits for consent: it must not stack on the sheet.
        .onAppear {
            if host.needsConsent { needsConsent = true } else { rec.prewarm() }
        }
        .onDisappear { rec.stop() }
        .sheet(isPresented: $needsConsent) {
            host.consentView(
                    onAccept: { needsConsent = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { rec.prewarm() } },
                    onCancel: { needsConsent = false; rec.stop(); onCancel() })
        }
    }

    private var recordAct: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Read the line").font(t.mastheadItalic(28)).foregroundStyle(t.fg)
                Text("Tap record, read it through, tap again to finish.")
                    .font(t.console(11)).foregroundStyle(t.fgFaint).multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            if let note {
                Text(note).font(t.sans(13, .semibold)).foregroundStyle(t.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 26)
            }
            ScrollView {
                Text("“\(script)”")
                    .font(t.masthead(18)).foregroundStyle(t.fg.opacity(0.95))
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18).fill(t.panel))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(t.panelStroke, lineWidth: 1))
                    .padding(.horizontal, 22)
            }
            .frame(maxHeight: 260)
            Spacer(minLength: 0)
            LiveWaveform(levels: rec.levels, active: rec.isRecording).frame(height: 56).padding(.horizontal, 26)
            Text(rec.isRecording ? timeString(rec.elapsed) : (checking ? "CHECKING…" : (rec.denied ? "Microphone access needed" : "READY")))
                .font(t.console(13, .medium)).tracking(2)
                .foregroundStyle(rec.denied ? .red.opacity(0.85) : (rec.isRecording ? t.accent : t.fgFaint))
                .contentTransition(.numericText())
            if let problem, !rec.isRecording {
                Text(problem).font(t.sans(12)).foregroundStyle(t.peak)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            RecordOrb(recording: rec.isRecording) {
                guard !checking else { return }
                if rec.isRecording { rec.stop(); check() } else { problem = nil; rec.start() }
            }
            .opacity(checking ? 0.5 : 1)
            Text(rec.isRecording ? "Tap to finish" : "Tap to record")
                .font(t.console(10)).tracking(1).foregroundStyle(t.fgFaint)
            Spacer(minLength: 16)
        }
    }

    private var correctionAct: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("That wasn't the line").font(t.mastheadItalic(28)).foregroundStyle(t.fg)
                Text("This is what was heard. Fix anything wrong — the voice learns from these words as much as the audio.")
                    .font(t.console(11)).foregroundStyle(t.fgFaint)
                    .multilineTextAlignment(.center).lineSpacing(3).padding(.horizontal, 26)
            }
            .padding(.top, 10)
            TextEditor(text: $correction)
                .scrollContentBackground(.hidden)
                .font(t.console(13)).foregroundStyle(t.fg).tint(t.accent)
                .padding(10).frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 14).fill(t.ink))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(t.panelStroke, lineWidth: 1))
                .padding(.horizontal, 22)
                .accessibilityIdentifier("take-correction")
            Spacer(minLength: 0)
            Button {
                guard let clip else { return }
                onDone(clip, correction)
            } label: {
                Text("Use this take")
                    .font(t.console(13, .semibold)).foregroundStyle(t.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 13).fill(t.accent))
            }
            .buttonStyle(.plain)
            .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .padding(.horizontal, 22)
            Button("Record again") { heard = nil; correction = ""; clip = nil }
                .font(t.console(10)).foregroundStyle(t.fgDim).padding(.bottom, 16)
        }
    }

    /// Same gate as `CloneStudioView.checkRecording`: hygiene first, then
    /// the words. Read as written → the script is the transcript; anything
    /// else → correction with what was heard; no recogniser → the script.
    private func check() {
        guard let url = rec.lastURL else { problem = "No recording found."; return }
        checking = true; problem = nil
        Task {
            defer { checking = false }
            do {
                let samples = try VoiceAudio.loadWav24k(url)
                let quality = RecordingCheck.measure(samples, sampleRate: ClipImport.sampleRate)
                if let why = quality.problem { problem = why; return }
                let text: String
                do {
                    guard let transcribe = host.capabilities.transcribe else { throw VoiceEditorUnsupported("transcribe") }
                    text = try await transcribe(url)
                } catch {
                    NSLog("[take] transcription unavailable (%@); trusting the script", error.localizedDescription)
                    onDone(url, script)
                    return
                }
                let match = RecordingCheck.scriptMatch(heard: text, script: script)
                NSLog("[take] script match %.2f: %@", match, text)
                if match >= RecordingCheck.matchThreshold {
                    onDone(url, script)
                } else {
                    clip = url; correction = text; heard = text
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func timeString(_ t: Double) -> String {
        String(format: "%01d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// Edit what one take says. Also the correction step for an imported take:
/// the transcription lands here before the take is added.
public struct TakeTranscriptSheet: View {
    let title: String
    var caption: String? = nil
    @Binding var text: String
    var busy = false
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @Environment(\.voiceEditorTheme) private var t

    public init(title: String, caption: String? = nil, text: Binding<String>, busy: Bool = false,
                onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title; self.caption = caption; _text = text; self.busy = busy
        self.onSave = onSave; self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What the take says", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .font(t.sans(14)).foregroundStyle(t.fg).tint(t.accent)
                        .disabled(busy)
                        .accessibilityIdentifier("take-transcript")
                } footer: {
                    if let caption {
                        Text(caption).font(t.sans(11)).foregroundStyle(t.fgFaint)
                    }
                }
                .listRowBackground(t.panel)
            }
            .scrollContentBackground(.hidden)
            .voiceFormStyle()
            .background(t.ground)
            .voiceInlineTitle()
            .toolbar {
                ToolbarItem(placement: .principal) { Text(title).font(t.masthead(17)).foregroundStyle(t.fg) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).tint(t.accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text) }
                        .tint(t.accent)
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
