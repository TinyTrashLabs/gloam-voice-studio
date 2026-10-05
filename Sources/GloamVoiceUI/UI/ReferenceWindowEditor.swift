import SwiftUI

/// Where in a long master LuxTTS should listen. The master's waveform with
/// the window marked, two handles, "Propose" (the energy cut the engine
/// would make), "Transcribe window" (on-device), and the words-per-second
/// gate before Save. Saving writes `engines/lux-tts/ref.wav` + `voice.json`
/// with `derivedFrom` as the format describes; "Use whole master" clears it
/// when the master is inside the cap.
public struct ReferenceWindowEditor: View {
    let voice: Voice
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = VoicePlayer()

    @State private var samples: [Float] = []
    @State private var envelope: [Float] = []
    @State private var sourceSeconds = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var text = ""
    /// The last on-device transcription; `by` is "user" once the text differs.
    @State private var heard: String?
    @State private var transcribing = false
    @State private var loading = true
    @State private var note: String?
    @State private var errorText: String?

    private var bounds: ReferenceWindowRule.Bounds { .init(start: start, end: end) }
    private var transcriptProblem: String? { ReferenceWindowRule.transcriptProblem(text, seconds: bounds.seconds) }
    private var canSave: Bool { !loading && !samples.isEmpty && transcriptProblem == nil }

    public init(voice: Voice) { self.voice = voice }

    private var store: any VoiceLibraryStore { host.store }

    public var body: some View {
        Form {
            Section {
                waveform.frame(height: 88).listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                LabeledContent {
                    Text(String(format: "%@ · %.1fs", ReferenceWindowRule.rangeLabel(start: start, end: end), bounds.seconds))
                        .font(t.console(12, .semibold)).foregroundStyle(t.accent)
                } label: { Text("Window").font(t.sans(14)).foregroundStyle(t.fg) }
                // Only once the master is known: a slider whose range is
                // shorter than its step aborts ("max stride must be positive").
                if sourceSeconds >= 1 {
                    Slider(value: Binding(get: { start }, set: { move(start: $0) }), in: 0...sourceSeconds, step: 0.1)
                        .tint(t.accent).accessibilityLabel("Window start")
                    Slider(value: Binding(get: { end }, set: { move(end: $0) }), in: 0...sourceSeconds, step: 0.1)
                        .tint(t.accent).accessibilityLabel("Window end")
                }
                Button(player.isPlaying ? "Stop" : "Play window", systemImage: player.isPlaying ? "stop.fill" : "play.fill") {
                    if player.isPlaying { player.stop(); return }
                    try? player.play(samples: ReferenceWindowRule.slice(samples, sampleRate: ClipImport.sampleRate, bounds: bounds),
                                     sampleRate: ClipImport.sampleRate, gain: host.outputGain(for: voice))
                }
                .font(t.sans(14)).tint(t.accent).disabled(loading)
                Button("Propose", systemImage: "wand.and.stars") { propose() }
                    .font(t.sans(14)).tint(t.accent).disabled(loading)
            } header: {
                Text("Reference window").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            } footer: {
                Text(String(format: "The master runs %.0fs. Without a window each engine picks its own section of it; set one to choose the part yourself. Every render pays for the whole window, so shorter is quicker. Propose starts at the first speech and ends in a pause, %.0fs in.",
                            sourceSeconds, ReferenceWindowRule.proposedSeconds))
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
            Section {
                TextField("What the window says", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(t.sans(13)).foregroundStyle(t.fg).tint(t.accent)
                    .accessibilityIdentifier("window-transcript")
                if let transcriptProblem, !text.isEmpty || !loading {
                    Label(transcriptProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(t.sans(12)).foregroundStyle(t.peak)
                } else if !text.isEmpty {
                    Label(String(format: "%.1f words a second", ReferenceWindowRule.wordsPerSecond(text, seconds: bounds.seconds)),
                          systemImage: "checkmark.seal.fill")
                        .font(t.sans(12)).foregroundStyle(t.fgFaint)
                }
                if let note { Text(note).font(t.sans(12)).foregroundStyle(t.accent) }
                if host.capabilities.transcribe != nil {
                    Button(transcribing ? "Listening…" : "Transcribe window", systemImage: "ear") { transcribe() }
                        .font(t.sans(14)).tint(t.accent).disabled(loading || transcribing)
                }
            } header: {
                Text("Words").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            } footer: {
                Text("The transcript of the window, not of the whole master. It must cover the audio: too few words for the length and the engine's timing runs away.")
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
            if voice.hasWindow {
                Section {
                    Button("Use whole master", systemImage: "rectangle.expand.vertical") { useWholeMaster() }
                        .font(t.sans(14)).tint(t.accent)
                } footer: {
                    Text("Drop the window and let each engine choose its own section of the master.")
                        .font(t.sans(11)).foregroundStyle(t.fgFaint)
                }
                .listRowBackground(t.panel)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .voiceFormStyle()
        .background(t.ground)
        .voiceInlineTitle()
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Window").font(t.masthead(18)).foregroundStyle(t.fg) }
            ToolbarItem(placement: .voiceTrailing) {
                Button("Save") { save() }.disabled(!canSave).font(t.console(13, .semibold)).tint(t.accent)
            }
        }
        .onAppear(perform: load)
        .onDisappear { player.stop() }
        .preferredColorScheme(.dark)
        .alert("Couldn't do that", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var waveform: some View {
        GeometryReader { geo in
            let bins = envelope.count
            ZStack(alignment: .leading) {
                if sourceSeconds > 0 {
                    Rectangle().fill(t.accent.opacity(0.16))
                        .frame(width: geo.size.width * CGFloat((end - start) / sourceSeconds))
                        .offset(x: geo.size.width * CGFloat(start / sourceSeconds))
                }
                Canvas { ctx, size in
                    guard bins > 0 else { return }
                    let w = size.width / CGFloat(bins)
                    for (i, v) in envelope.enumerated() {
                        let at = (Double(i) + 0.5) / Double(bins) * sourceSeconds
                        let inside = at >= start && at <= end
                        let h = max(2, CGFloat(v) * size.height)
                        let rect = CGRect(x: CGFloat(i) * w + w * 0.15, y: (size.height - h) / 2, width: w * 0.7, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(inside ? t.accent : t.fgFaint.opacity(0.6)))
                    }
                }
                if loading {
                    ProgressView().tint(t.accent).frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityLabel("Master waveform")
    }

    // MARK: actions

    private func load() {
        guard let url = store.masterURL(of: voice.slug) else { loading = false; return }
        let stored = store.window(of: voice.slug)
        Task.detached {
            let s = (try? VoiceAudio.loadWav24k(url)) ?? []
            let env = ReferenceWindowRule.envelope(s, bins: 120)
            let seconds = Double(s.count) / Double(ClipImport.sampleRate)
            await MainActor.run {
                samples = s; envelope = env; sourceSeconds = seconds
                if let stored, let d = stored.derivedFrom, abs(d.sourceSeconds - seconds) < 0.5,
                   !ReferenceWindowRule.isStale(stored, master: url) {
                    let b = ReferenceWindowRule.clamp(start: d.startSeconds, end: d.endSeconds, sourceSeconds: seconds, movedStart: false)
                    start = b.start; end = b.end
                    text = stored.text
                    if d.by == "on-device-asr" { heard = stored.text }
                } else {
                    proposeBounds()
                    if seconds <= ReferenceWindowRule.maxSeconds, stored == nil { text = voice.refText }
                }
                loading = false
            }
        }
    }

    private func move(start s: Double) {
        let b = ReferenceWindowRule.clamp(start: s, end: end, sourceSeconds: sourceSeconds, movedStart: true)
        start = b.start; end = b.end
    }

    private func move(end e: Double) {
        let b = ReferenceWindowRule.clamp(start: start, end: e, sourceSeconds: sourceSeconds, movedStart: false)
        start = b.start; end = b.end
    }

    /// The proposed window, ending on a sentence; returns its draft words.
    @discardableResult
    private func proposeBounds() -> String {
        let p = ReferenceWindowRule.propose(samples: samples, sampleRate: ClipImport.sampleRate,
                                            transcript: host.referenceText(for: voice))
        let b = ReferenceWindowRule.clamp(start: p.bounds.start, end: p.bounds.end,
                                          sourceSeconds: sourceSeconds, movedStart: false)
        start = b.start; end = b.end
        return p.text
    }

    private func propose() {
        player.stop()
        let draft = proposeBounds()
        heard = nil
        if host.capabilities.transcribe != nil {
            note = "Proposed: first speech to the end of a sentence. Now transcribe it."
            text = ""
        } else {
            note = "Proposed: first speech to the end of a sentence. Check the words match what's said."
            text = draft
        }
    }

    private func transcribe() {
        guard let transcribeAudio = host.capabilities.transcribe else { return }
        player.stop()
        transcribing = true; note = nil
        let window = ReferenceWindowRule.slice(samples, sampleRate: ClipImport.sampleRate, bounds: bounds)
        Task {
            defer { transcribing = false }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("window-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try VoicePlayer.wavData(samples: window, sampleRate: ClipImport.sampleRate).write(to: tmp)
                let heardText = try await transcribeAudio(tmp)
                text = heardText; heard = heardText
                note = "Heard on \(host.capabilities.deviceNoun). Fix anything wrong, then Save."
            } catch {
                note = error.localizedDescription
            }
        }
    }

    private func save() {
        player.stop()
        do {
            try store.setWindow(of: voice,
                                samples: ReferenceWindowRule.slice(samples, sampleRate: ClipImport.sampleRate, bounds: bounds),
                                text: text,
                                derivedFrom: ReferenceWindowRule.derivedFrom(
                                    bounds: bounds, sourceSeconds: sourceSeconds,
                                    transcribedOnDevice: heard == text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    master: store.masterURL(of: voice.slug)))
            dismiss()
        } catch { errorText = userMessage(for: error) }
    }

    private func useWholeMaster() {
        player.stop()
        do { try store.clearWindow(of: voice); dismiss() }
        catch { errorText = userMessage(for: error) }
    }
}
