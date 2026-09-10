import AVFAudio
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// The Lab tab: an in-app audio comparison shelf. Clips collected from any
/// source (an agent over MCP, a Finder drop, a "Send to Lab" render) group into
/// named comparisons, and the marks/comments/verdicts a developer leaves while
/// auditioning them are read straight back by the agent over the same in-process
/// `LabStore`. This view is the native replacement for the old throwaway Python
/// lab server — same comparison surface, wired to the shared store.
///
/// It renders only when Lab mode is enabled (Settings → Storage). The store and
/// its groups persist whether or not the tab is showing.
struct LabView: View {
    // A computed accessor rather than a stored `let`: keeps the @Observable
    // reads inside `body`, and sidesteps any main-actor stored-init concern.
    private var store: LabStore { LabStore.shared }
    // Which groups are collapsed. Held here (not in the card) so it survives the
    // frequent store-driven re-renders as marks/comments come and go.
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.state.groups.isEmpty {
                    emptyState
                } else {
                    ForEach(store.state.groups) { group in
                        LabGroupCard(
                            group: group,
                            isCollapsed: collapsed.contains(group.id),
                            toggleCollapsed: {
                                if collapsed.contains(group.id) { collapsed.remove(group.id) }
                                else { collapsed.insert(group.id) }
                            })
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .background(Brand.ink.opacity(0.0))
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LAB")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Brand.fgFaint)
                Text("Audio comparison shelf")
                    .font(.title3.bold())
                    .foregroundStyle(Brand.fg)
            }
            Spacer()
            Button {
                // An empty comparison to drop clips into. Heading and "listen
                // for" are edited in place once it exists.
                store.setGroup(heading: "Untitled comparison")
            } label: {
                Label("New comparison", systemImage: "plus")
            }
            .accessibilityIdentifier("lab-new-comparison")
            .help("Start an empty comparison to collect clips into")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "flask")
                .font(.system(size: 30))
                .foregroundStyle(Brand.fgFaint)
            Text("No comparisons yet.")
                .font(.callout).foregroundStyle(Brand.fgDim)
            Text("Start one above, drop a .wav onto it from Finder, or use “Send to Lab” "
                 + "from Studio or Dialogue. Agents can stage A/Bs here over MCP.")
                .font(.caption).foregroundStyle(Brand.fgFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Group

/// One comparison: an editable heading + "listen for" instruction, its clips as
/// player rows, a verdict, and the requests aimed at the agent.
private struct LabGroupCard: View {
    let group: LabGroup
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    @State private var dropTargeted = false
    @State private var newRequest = ""
    @State private var confirmingDelete = false

    private var store: LabStore { LabStore.shared }
    private var clips: [LabClip] { store.state.clips(of: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headingBlock

            if !isCollapsed {
                Divider().overlay(Color.white.opacity(0.06))

                if clips.isEmpty {
                    Text("No clips yet — drop a .wav here, or send one from Studio/Dialogue.")
                        .font(.caption).foregroundStyle(Brand.fgFaint)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(clips) { clip in
                        LabClipRow(clip: clip)
                    }
                }

                Divider().overlay(Color.white.opacity(0.06))
                verdictBlock
                requestsBlock
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(dropTargeted ? Brand.accent : Color.white.opacity(0.06),
                    lineWidth: dropTargeted ? 2 : 1))
        // Finder drag-drop: dropping .wav URLs onto a group ingests them (the
        // store copies the bytes in, so a source file moving never breaks the
        // comparison).
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            ingest(providers, into: group.id)
        }
        .confirmationDialog("Delete this comparison and all its clips?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete comparison", role: .destructive) { store.deleteGroup(group.id) }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("lab-group-\(group.id)")
    }

    @ViewBuilder
    private var headingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.fgDim)
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help(isCollapsed ? "Expand comparison" : "Collapse comparison")
                .accessibilityLabel(isCollapsed ? "Expand comparison" : "Collapse comparison")
                TextField("What's being compared?", text: Binding(
                    get: { group.heading },
                    set: { store.setGroup(id: group.id, heading: $0, listenFor: group.listenFor) }))
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .foregroundStyle(Brand.fg)
                    .accessibilityIdentifier("lab-heading-\(group.id)")
                if isCollapsed {
                    Text("\(clips.count) clip\(clips.count == 1 ? "" : "s")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Brand.fgFaint)
                }
                Spacer(minLength: 8)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.fgDim)
                .help("Delete this comparison")
                .accessibilityLabel("Delete comparison")
            }
            // The instruction to the listener — what to focus on across the A/B.
            if !isCollapsed {
                TextField("Listen for… (what to focus on in each clip)", text: Binding(
                    get: { group.listenFor },
                    set: { store.setGroup(id: group.id, heading: group.heading, listenFor: $0) }),
                    axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.caption)
                    .foregroundStyle(Brand.fgDim)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .accessibilityIdentifier("lab-listenfor-\(group.id)")
            }
        }
    }

    @ViewBuilder
    private var verdictBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VERDICT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Brand.fgFaint)
            TextField("The decision (e.g. “B wins — ship the baked ref”)", text: Binding(
                get: { group.verdict ?? "" },
                set: { store.setVerdict(groupID: group.id, verdict: $0.isEmpty ? nil : $0) }),
                axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.callout)
                .foregroundStyle(Brand.fg)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke((group.verdict?.isEmpty == false ? Brand.accent : Color.white)
                        .opacity(group.verdict?.isEmpty == false ? 0.3 : 0.08), lineWidth: 1))
                .accessibilityIdentifier("lab-verdict-\(group.id)")
        }
    }

    @ViewBuilder
    private var requestsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REQUESTS FOR THE AGENT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Brand.fgFaint)
            ForEach(group.requests) { req in
                HStack(spacing: 8) {
                    // Tick a request done (or back to open) — it's what the agent
                    // reads as the work list, so its status matters.
                    Button {
                        store.setRequestStatus(groupID: group.id, requestID: req.id,
                                               status: req.status == .open ? .done : .open)
                    } label: {
                        Image(systemName: req.status == .done
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(req.status == .done ? Brand.accent : Brand.fgDim)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(req.status == .done ? "Mark request open" : "Mark request done")
                    Text(req.text)
                        .font(.caption)
                        .strikethrough(req.status == .done)
                        .foregroundStyle(req.status == .done ? Brand.fgFaint : Brand.fgDim)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                TextField("Ask the agent to do something…", text: $newRequest)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit(addRequest)
                    .accessibilityIdentifier("lab-new-request-\(group.id)")
                Button("Add", action: addRequest)
                    .font(.caption)
                    .disabled(newRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addRequest() {
        let text = newRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addRequest(groupID: group.id, text: text)
        newRequest = ""
    }

    /// Copy dropped .wav files into this group. `loadObject(ofClass: URL.self)`
    /// resolves on a background queue, so the actual ingest hops back to the main
    /// actor (the store is `@MainActor`).
    private func ingest(_ providers: [NSItemProvider], into groupID: String) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "wav" else { return }
                let label = url.deletingPathExtension().lastPathComponent
                Task { @MainActor in
                    try? LabStore.shared.putClip(groupID: groupID, label: label,
                                                 contentsOf: url, source: .finder)
                }
            }
        }
        return handled
    }
}

// MARK: - Clip row

/// A single clip's player: transport with a real scrubber and current-time
/// readout, a "◆ Mark" button that pins the playhead with a note, the marks
/// listed below (click to seek+play, × to delete), and a whole-clip comment.
private struct LabClipRow: View {
    let clip: LabClip
    @State private var player = LabClipPlayer()
    @State private var markNote = ""
    @State private var confirmingDelete = false
    @State private var wavData = Data()

    private var store: LabStore { LabStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            transportRow
            markRow
            if !clip.marks.isEmpty { marksList }
            commentField
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .onAppear {
            player.load(store.url(for: clip))
            wavData = (try? Data(contentsOf: store.url(for: clip))) ?? Data()
        }
        .onDisappear { player.stop() }
        .accessibilityIdentifier("lab-clip-\(clip.id)")
    }

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(clip.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Brand.fg)
            sourceChip(clip.source)
            if let d = clip.duration {
                Text(String(format: "%.1fs", d))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.fgFaint)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.fgDim)
            .help("Delete this clip")
            .accessibilityLabel("Delete clip")
            .confirmationDialog("Delete this clip?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete clip", role: .destructive) {
                    player.stop()
                    store.deleteClip(clip.id)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        if let note = clip.note, !note.isEmpty {
            Text(note).font(.caption2).foregroundStyle(Brand.fgDim)
        }
    }

    @ViewBuilder
    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("lab-play-\(clip.id)")
            Text(timeLabel(player.currentTime))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Brand.fgDim)
                .frame(width: 34, alignment: .trailing)
            LabWaveformScrubber(
                wavData: wavData,
                duration: max(player.duration, 0.01),
                currentTime: player.currentTime,
                marks: clip.marks,
                onSeek: { player.seek(to: $0) })
                .frame(height: 40)
                .accessibilityIdentifier("lab-scrub-\(clip.id)")
            Text(timeLabel(player.duration))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Brand.fgFaint)
                .frame(width: 34, alignment: .leading)
        }
    }

    @ViewBuilder
    private var markRow: some View {
        HStack(spacing: 8) {
            Button {
                store.addMark(clipID: clip.id, t: player.currentTime,
                              note: markNote.trimmingCharacters(in: .whitespacesAndNewlines))
                markNote = ""
            } label: {
                Label("Mark", systemImage: "diamond.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.accent)
            .help("Pin the current playhead (\(timeLabel(player.currentTime))) as a timestamp")
            .accessibilityIdentifier("lab-mark-\(clip.id)")
            TextField("note for this timestamp…", text: $markNote)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    store.addMark(clipID: clip.id, t: player.currentTime,
                                  note: markNote.trimmingCharacters(in: .whitespacesAndNewlines))
                    markNote = ""
                }
                .accessibilityIdentifier("lab-mark-note-\(clip.id)")
        }
    }

    @ViewBuilder
    private var marksList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(clip.marks.sorted { $0.t < $1.t }) { mark in
                HStack(spacing: 6) {
                    // Click a mark to jump there and play from it.
                    Button {
                        player.play(from: mark.t)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "diamond.fill").font(.system(size: 7))
                            Text(timeLabel(mark.t))
                                .font(.system(.caption2, design: .monospaced))
                            if !mark.note.isEmpty {
                                Text(mark.note).font(.caption2)
                            }
                        }
                        .foregroundStyle(Brand.fgDim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Seek to \(timeLabel(mark.t)) and play")
                    Spacer(minLength: 0)
                    Button {
                        store.removeMark(clipID: clip.id, markID: mark.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.fgFaint)
                    .accessibilityLabel("Remove mark at \(timeLabel(mark.t))")
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var commentField: some View {
        TextField("Overall comment on this clip…", text: Binding(
            get: { clip.comment ?? "" },
            set: { store.setClipComment(clipID: clip.id, comment: $0.isEmpty ? nil : $0) }),
            axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(.caption)
            .foregroundStyle(Brand.fgDim)
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.07), lineWidth: 1))
            .accessibilityIdentifier("lab-comment-\(clip.id)")
    }

    private func sourceChip(_ source: LabClipSource) -> some View {
        Text(source.rawValue)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .foregroundStyle(Brand.fgFaint)
    }

    private func timeLabel(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Per-clip player

/// The clip's waveform doubling as the scrubber: the peak-bin waveform with the
/// playhead and every pinned mark drawn on top, so a listener can see the shape
/// of the audio and click/drag straight to the spot they want to seek or mark.
private struct LabWaveformScrubber: View {
    let wavData: Data
    let duration: Double
    let currentTime: Double
    let marks: [LabMark]
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Static layer: bg + waveform + pinned marks. None of these
                // depend on `currentTime`, so SwiftUI reuses this subtree
                // untouched while the playhead moves — the WAV decodes once,
                // not on every 10 Hz ticker tick.
                LabWaveformStatic(wavData: wavData, duration: duration, marks: marks, width: w)
                // Playhead — the only piece that tracks `currentTime`.
                Rectangle().fill(Brand.fg)
                    .frame(width: 1.5)
                    .offset(x: CGFloat(min(max(currentTime / duration, 0), 1)) * w)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(Double(min(max(v.location.x / w, 0), 1)) * duration)
            })
        }
    }
}

/// The unchanging part of the scrubber — background, waveform, pinned marks.
/// Split out from `LabWaveformScrubber` so its inputs never include the moving
/// `currentTime`; SwiftUI then skips re-rendering (and re-decoding) it while the
/// playhead advances.
private struct LabWaveformStatic: View {
    let wavData: Data
    let duration: Double
    let marks: [LabMark]
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.04))
            WaveformView(wavData: wavData, color: Brand.fgDim)
                .padding(.horizontal, 2)
            ForEach(marks) { m in
                Rectangle().fill(Brand.accent.opacity(0.7))
                    .frame(width: 1.5)
                    .offset(x: CGFloat(min(max(m.t / duration, 0), 1)) * width)
            }
        }
    }
}

/// AVAudioPlayer-backed transport for one Lab clip. Modelled on `PreviewPlayer`,
/// but per-row and with a ~10 Hz ticker so the scrubber and time readout track
/// the playhead while it plays. One instance lives as `@State` in each clip row.
@MainActor @Observable
final class LabClipPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var ticker: Timer?

    /// Load a clip's wav once; a clip's file is immutable (id-based name), so a
    /// repeat call for the same URL is a no-op.
    func load(_ url: URL) {
        if loadedURL == url, player != nil { return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        loadedURL = url
        duration = p.duration
        currentTime = 0
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0; currentTime = 0 }
            if player.play() { isPlaying = true; startTicker() }
        }
    }

    /// Move the playhead (scrubbing) without changing play/pause state.
    func seek(to t: Double) {
        guard let player, t.isFinite else { return }
        let clamped = min(max(0, t), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Jump to a mark and start playing from it.
    func play(from t: Double) {
        guard let player else { return }
        seek(to: t)
        if !player.isPlaying, player.play() { isPlaying = true; startTicker() }
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        // Runs on the main run loop (we're @MainActor); the hop keeps the
        // isolation checker happy for the non-isolated Timer closure.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
        }
    }
}

// MARK: - Send to Lab (shared)

/// The "Send to Lab" control used by Studio and Dialogue. Offers a new
/// comparison or any existing one to append to, then copies the just-rendered
/// wav into it. Rendered only when Lab mode is on (the caller gates it), so it
/// never appears for a casual user.
struct SendToLabMenu: View {
    /// Suggested clip label (e.g. the line, or "Dialogue take").
    let label: String
    let source: LabClipSource
    /// Pulled lazily so the button always sends the current take.
    let wav: () -> Data?

    private var store: LabStore { LabStore.shared }

    var body: some View {
        Menu {
            Button("New comparison") { send(into: nil) }
            let groups = store.state.groups
            if !groups.isEmpty {
                Divider()
                Section("Add to") {
                    ForEach(groups) { group in
                        Button(group.heading.isEmpty ? "Untitled comparison" : group.heading) {
                            send(into: group.id)
                        }
                    }
                }
            }
        } label: {
            Label("Send to Lab", systemImage: "flask")
        }
        // Default (bordered pull-down) menu style so it sits alongside the
        // Play/Export buttons rather than reading as a borderless link.
        .fixedSize()
        .disabled(wav() == nil)
        .help("Add this take to a Lab comparison")
        .accessibilityIdentifier("send-to-lab")
    }

    private func send(into groupID: String?) {
        guard let wav = wav() else { return }
        let id = groupID ?? store.setGroup(heading: newHeading()).id
        try? store.putClip(groupID: id, label: label, wav: wav, source: source)
    }

    private func newHeading() -> String {
        switch source {
        case .dialogue: "Dialogue comparison"
        case .studio: "Studio comparison"
        default: "New comparison"
        }
    }
}
