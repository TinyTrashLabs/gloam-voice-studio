import GVoiceKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// One voice, edited in place. Native `Form`, top to bottom: avatar, name,
/// notes, the reference (play, quality, words, listen and clean up, record
/// another take), an Advanced row, delete. What a new user needs and nothing else; the takes
/// list, window, delivery, emotion versions, renditions and provenance sit
/// behind Advanced (`VoiceAdvancedView`). Every field the `.gvoice` format
/// carries today is on one of the two; consent and licence arrive once the
/// format has them.
public struct VoiceDetailView<Extra: View>: View {
    let slug: String
    private let extraSections: (Voice) -> Extra
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t
    @StateObject private var player = VoicePlayer()
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    /// The words the reference says -- editable, because a take that was
    /// not the script (Ryan, 2026-09-09) must be repairable in place: both
    /// engines condition on this text and disagree with the audio otherwise.
    @State private var transcript = ""
    /// Level, noise, length and clipping of the reference, measured on
    /// appear (RecordingCheck); nil until read.
    @State private var quality: RecordingCheck.Quality?
    @State private var listening = false
    @State private var cleaning = false
    @State private var referenceNote: String?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    @State private var errorText: String?
    @State private var choosingPhoto = false
    #if os(iOS)
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var takingPhoto = false
    /// A photo waiting for its framing. Presented as its own cover once the
    /// picker that produced it has gone.
    @State private var cropping: CropCandidate?
    @State private var pendingCrop: UIImage?
    private struct CropCandidate: Identifiable { let id = UUID(); let image: UIImage }
    #endif
    @StateObject private var share = PackShare()
    /// The takes, shared with the Advanced screen: Save here rebuilds the
    /// master from them just as Save there does.
    @StateObject private var takes = TakesModel()
    @State private var recording = false
    /// "Check this voice": the clone-time check (VoiceQualifier) run on the
    /// master. `voiceCheck` holds every version's score until one is kept.
    private struct VoiceCheckRun { let scored: [VoiceQualifier.Scored]; let quality: RecordingCheck.Quality; let result: Qualification }
    @State private var checkingVoice = false
    @State private var voiceCheck: VoiceCheckRun?
    @State private var voiceCheckNote: String?
    @State private var voiceCheckFailed = false
    @State private var comparingCleanup = false
    /// The running check; cancelled when the screen goes, so it never keeps
    /// rendering or writes a verdict for a screen no one is on.
    @State private var checkTask: Task<Void, Never>?
    /// Advanced is pushed on top (value-driven, so this screen knows): its
    /// push fires onDisappear here, and must not cancel a running check.
    @State private var showingAdvanced = false
    private enum Field { case name, notes, transcript }
    @FocusState private var focused: Field?

    /// A detail screen with nothing of the host's own beside it.
    public init(slug: String) where Extra == EmptyView {
        self.slug = slug
        self.extraSections = { _ in EmptyView() }
    }

    /// `extraSections` are Form sections the host adds under the reference,
    /// above Advanced: the radio app's Pace and "used by hosts", say.
    public init(slug: String, @ViewBuilder extraSections: @escaping (Voice) -> Extra) {
        self.slug = slug
        self.extraSections = extraSections
    }

    private var store: any VoiceLibraryStore { host.store }
    private var features: VoiceLibraryFeatures { store.features }
    private var caps: VoiceEditorCapabilities { host.capabilities }
    private var voice: Voice? { store.voices.first { $0.slug == slug } }
    /// Advanced is worth a row only when something lives behind it.
    private var hasAdvanced: Bool {
        !features.isDisjoint(with: [.takes, .referenceWindow, .pace, .gain, .emotionVersions, .renditions, .provenance])
    }
    private var storedTranscript: String {
        guard let voice else { return "" }
        return host.referenceText(for: voice)
    }
    private var isDirty: Bool {
        guard let voice else { return false }
        return name != voice.name || notes != (voice.meta.notes ?? "")
            || transcript.trimmingCharacters(in: .whitespacesAndNewlines) != storedTranscript
            || takes.state.stale
    }
    /// Save has something to do and nothing stands in its way.
    private var canSave: Bool {
        isDirty && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !(takes.state.stale && takes.state.blocker != nil)
    }

    /// One line on the reference's fitness, from the same measurement the
    /// record act gates on. A voice that fails here is one to re-record or
    /// delete, and the line says which problem to fix.
    @ViewBuilder
    private var qualityLine: some View {
        if let quality {
            if let problem = quality.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(t.sans(12)).foregroundStyle(t.peak)
            } else {
                Label(String(format: "Good take · %.0f dBFS, %.0f dB above the room · %.0fs",
                             quality.speechDb, quality.snrDb, quality.seconds),
                      systemImage: "checkmark.seal.fill")
                    .font(t.sans(12)).foregroundStyle(t.fgFaint)
            }
        }
    }

    /// Transcribe the reference on-device and put the result in the field
    /// (not saved until Save), with a note on how far it is from the script.
    private func listenForWords() {
        guard let voice, let transcribe = caps.transcribe else { return }
        player.stop()
        listening = true; referenceNote = nil
        Task {
            defer { listening = false }
            do {
                guard let url = store.referenceURL(of: voice.slug) else { throw StudioError.voiceNotFound(slug: voice.slug) }
                let heard = try await transcribe(url)
                let match = RecordingCheck.scriptMatch(heard: heard, script: storedTranscript)
                transcript = heard
                referenceNote = match >= RecordingCheck.matchThreshold
                    ? "Heard the same words as the transcript."
                    : String(format: "Heard something different (%.0f%% of the saved words) — check it, then Save.", match * 100)
            } catch {
                referenceNote = error.localizedDescription
            }
        }
    }

    /// Trim and level the reference in place, then re-measure.
    private func cleanUp() {
        guard let voice else { return }
        player.stop()
        cleaning = true; referenceNote = nil
        let before = quality
        Task {
            defer { cleaning = false }
            do {
                try store.cleanReference(of: voice)
                measureReference()
                if let before {
                    referenceNote = String(format: "Cleaned: was %.0fs at %.0f dBFS.", before.seconds, before.speechDb)
                }
            } catch {
                errorText = userMessage(for: error)
            }
        }
    }

    /// Test-render the master (and, when it is noisy, a cleaned version of
    /// it) on this phone's engine, as a new clone is checked. A clean result
    /// is remembered at once; a cleaned winner waits for the person to
    /// compare and choose, since keeping it replaces the master.
    private func checkVoice() {
        guard let voice, let master = store.masterURL(of: voice.slug), let check = caps.voiceCheck else { return }
        player.stop()
        abandonCheck()
        checkingVoice = true; voiceCheckNote = nil; voiceCheck = nil; voiceCheckFailed = false
        let transcript = host.referenceText(for: voice)
        checkTask = Task {
            var made: [ReferenceCandidate] = []
            defer { if !Task.isCancelled { checkingVoice = false } }
            do {
                await check.prepare()
                let (quality, candidates) = await Self.checkCandidates(master: master, transcript: transcript, check: check)
                made = candidates
                let scored = try await VoiceQualifier.score(candidates, renderer: check.renderer,
                                                            checker: check.checker)
                try Task.checkCancellation()
                let r = VoiceQualifier.pick(scored, quality: quality, engine: check.engineName())
                voiceCheck = VoiceCheckRun(scored: scored, quality: quality, result: r.result)
                voiceCheckFailed = !r.result.problems.isEmpty
                if r.winner.kind == .original {
                    remember(r.result)
                    voiceCheckNote = verdictLine(r.result)
                    VoiceQualifier.discardCleaned(candidates)   // the master stays as it is
                } else {
                    voiceCheckNote = "A version with the background noise removed renders better. Compare them, then keep one."
                }
            } catch {
                VoiceQualifier.discardCleaned(made)   // nothing of a failed check is kept
                if Task.isCancelled || error is CancellationError { return }
                voiceCheckNote = "Couldn't check this voice: \(error.localizedDescription)"
            }
        }
    }

    private nonisolated static func checkCandidates(master: URL, transcript: String, check: VoiceCheckCapability) async
        -> (RecordingCheck.Quality, [ReferenceCandidate])
    {
        let q = RecordingCheck.measure((try? VoiceAudio.loadWav24k(master)) ?? [], sampleRate: ClipImport.sampleRate)
        return (q, await check.candidates(master, transcript, q))
    }

    /// Stops a running check and deletes any cleaned version not kept.
    private func abandonCheck() {
        checkTask?.cancel()
        checkTask = nil
        checkingVoice = false
        VoiceQualifier.discardCleaned(voiceCheck?.scored.map(\.candidate) ?? [])
    }

    /// The person's pick after a cleaned version won.
    private func keep(_ kind: ReferenceCandidate.Kind) {
        guard let voice, let run = voiceCheck, let s = run.scored.first(where: { $0.candidate.kind == kind }) else { return }
        let verdict = VoiceQualifier.verdict(for: s, quality: run.quality, engine: run.result.engine)
        do {
            if kind == .cleaned { try store.replaceMasterWithCleaned(of: voice, samples: s.candidate.samples24k) }
            remember(verdict)
            VoiceQualifier.discardCleaned(run.scored.map(\.candidate))
            voiceCheck = nil
            voiceCheckFailed = !verdict.problems.isEmpty
            voiceCheckNote = kind == .cleaned ? "Background noise removed. " + verdictLine(verdict) : verdictLine(verdict)
            measureReference()
        } catch {
            errorText = userMessage(for: error)
        }
    }

    private func verdictLine(_ q: Qualification) -> String {
        guard let first = q.problems.first else { return "Checked: it renders cleanly on \(caps.deviceNoun)." }
        return q.findings.first ?? "The test render \(first.words). Another take usually fixes that."
    }

    /// Dated after any master write, so Compose reads it as current.
    private func remember(_ q: Qualification) {
        do { try VoiceCheckStore.save(q.stamped(Date()), slug: slug) }
        catch { NSLog("[voice] check not saved: %@", String(describing: error)) }
    }

    private func preview(_ kind: ReferenceCandidate.Kind) -> [Float] {
        voiceCheck?.scored.first { $0.candidate.kind == kind }?.preview ?? []
    }

    private func measureReference() {
        guard let voice, let url = store.referenceURL(of: voice.slug) else { return }
        Task.detached {
            let samples = (try? VoiceAudio.loadWav24k(url)) ?? []
            let q = RecordingCheck.measure(samples, sampleRate: ClipImport.sampleRate)
            await MainActor.run { quality = q }
        }
    }

    public var body: some View {
        Form {
            if features.contains(.avatars) { avatarSection }
            Section {
                TextField("Name", text: $name)
                    .font(t.masthead(18)).foregroundStyle(t.fg).tint(t.accent).foregroundStyle(t.accent)
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .notes }
            } header: {
                Text("Name").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
            if features.contains(.notes) {
                Section {
                    TextField("What this voice sounds like", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .font(t.sans(15)).foregroundStyle(t.fg).tint(t.accent).foregroundStyle(t.accent)
                        .focused($focused, equals: .notes)
                } header: {
                    Text("Notes").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
                }
                .listRowBackground(t.panel)
            }
            if let voice {
                Section {
                    LabeledContent {
                        Text(voice.hasWindow ? "Curated window" : "Master recording")
                            .font(t.sans(14)).foregroundStyle(t.fgFaint)
                    } label: {
                        Text("Reference").font(t.sans(14)).foregroundStyle(t.fg)
                    }
                    if takes.state.count > 0 || voice.hasWindow {
                        // Built from the takes' words on Save, or the window's
                        // words (its editor owns them); edit those in Advanced.
                        Text(transcript).font(t.sans(13)).foregroundStyle(t.fgDim)
                            .accessibilityIdentifier("voice-transcript")
                    } else {
                        TextField("What the recording says", text: $transcript, axis: .vertical)
                            .lineLimit(2...6)
                            .font(t.sans(13)).foregroundStyle(t.fg).tint(t.accent).foregroundStyle(t.accent)
                            .focused($focused, equals: .transcript)
                            .accessibilityIdentifier("voice-transcript")
                    }
                    qualityLine
                    if let referenceNote {
                        Text(referenceNote).font(t.sans(12)).foregroundStyle(t.accent)
                    }
                    if takes.state.count == 0, !voice.hasWindow, caps.transcribe != nil {
                        // Hear what it says and put that in the field -- the check
                        // a take recorded before 2026-09-09 never had.
                        Button(listening ? "Listening…" : "Listen for the words", systemImage: "ear") {
                            listenForWords()
                        }
                        .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                        .disabled(listening)
                    }
                    // Trim the silence and level the master in place. Not with
                    // a window: replacing the master drops the window with it.
                    if !voice.hasWindow, features.contains(.cleanup) {
                        Button(cleaning ? "Cleaning up…" : "Clean up recording", systemImage: "wand.and.sparkles") {
                            cleanUp()
                        }
                        .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                        .disabled(cleaning)
                    }
                    // The clone-time check, for a voice that never had it (or
                    // whose master changed). Master only, as Clean up: keeping
                    // a cleaned version replaces the master.
                    if !voice.hasWindow, caps.voiceCheck != nil {
                        Button(checkingVoice ? "Checking… (test-rendering on \(caps.deviceNoun))" : "Check this voice",
                               systemImage: "checkmark.shield") { checkVoice() }
                            .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                            .disabled(checkingVoice)
                            .accessibilityIdentifier("check-voice")
                        if let voiceCheckNote {
                            Text(voiceCheckNote).font(t.sans(12))
                                .foregroundStyle(voiceCheckFailed ? t.peak : t.accent)
                        }
                        if voiceCheck?.result.chosen == .cleaned {
                            // The sheet hangs off this one row, never the Section.
                            Button("Compare with original", systemImage: "waveform") { player.stop(); comparingCleanup = true }
                                .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                                .accessibilityIdentifier("compare-cleanup")
                                .sheet(isPresented: $comparingCleanup) {
                                    CleanupCompareView(original: preview(.original), cleaned: preview(.cleaned),
                                                       onKeepCleaned: { comparingCleanup = false; keep(.cleaned) },
                                                       onUseOriginal: { comparingCleanup = false; keep(.original) })
                                        .presentationDetents([.medium])
                                }
                        }
                    }
                    Button(player.isPlaying ? "Stop" : "Play reference",
                           systemImage: player.isPlaying ? "stop.fill" : "play.fill") {
                        if player.isPlaying { player.stop(); return }
                        if let url = store.referenceURL(of: voice.slug) {
                            try? player.play(fileURL: url, gain: host.outputGain(for: voice))
                        }
                    }
                    .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                    // The one quality lever a new user needs. The recorder
                    // is the take flow's; the list of takes lives in Advanced.
                    if caps.canRecord, features.contains(.takes) {
                        Button("Record another take", systemImage: "mic.badge.plus") { player.stop(); recording = true }
                            .font(t.sans(14)).tint(t.accent).foregroundStyle(t.accent)
                            .accessibilityIdentifier("record-another-take")
                            .voiceCover(isPresented: $recording) {
                                TakeRecorderView(title: "New take", script: TakeScripts.readLine,
                                                 onDone: { clip, text in recording = false; takes.add(clip, text, origin: .recorded) },
                                                 onCancel: { recording = false })
                            }
                    }
                    if features.contains(.takes), let line = TakeRules.countLine(count: takes.state.count, combinedSeconds: takes.state.combinedSeconds,
                                                      stale: takes.state.stale, blocker: takes.state.blocker) {
                        Text(line).font(t.console(11))
                            .foregroundStyle(takes.state.blocker != nil ? t.peak : (takes.state.stale ? t.accent : t.fgFaint))
                            .accessibilityIdentifier("takes-count")
                    }
                    if let text = takes.errorText {
                        Text(text).font(t.sans(12)).foregroundStyle(t.peak)
                    }
                } header: {
                    Text("Reference").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
                } footer: {
                    Text(voice.hasWindow
                         ? "The part of the recording the engine listens to, and its words — chosen in Advanced › Reference window. Another take makes the voice steadier; record somewhere quiet if the last one picked up the room."
                         : takes.state.count > 0
                         ? "The recording this voice is learned from, built from its takes, and the words it says. Another take makes it steadier; record somewhere quiet if the last one picked up the room."
                         : "The recording this voice is learned from, and the words it says — they must match, so fix the text if the take wasn't the script. Another take makes it steadier; record somewhere quiet if the last one picked up the room.")
                        .font(t.sans(11)).foregroundStyle(t.fgFaint)
                }
                .listRowBackground(t.panel)
                // The host's own sections (the radio app's Pace, "used by hosts").
                extraSections(voice)
                if hasAdvanced {
                Section {
                    Button { showingAdvanced = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Advanced").font(t.sans(14)).foregroundStyle(t.fg)
                                Text("Takes, reference window, pace and loudness, emotion versions, what the pack carries.")
                                    .font(t.sans(12)).foregroundStyle(t.fgFaint)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.fgFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("advanced")
                }
                .listRowBackground(t.panel)
                }
                if store.canDelete(voice) {
                    Section {
                        Button("Delete Voice", role: .destructive) { confirmingDelete = true }
                            .font(t.sans(15, .semibold))
                    }
                    .listRowBackground(t.panel)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .voiceFormStyle()
        .background(t.ground)
        .packShareUI(share)
        .voiceInlineTitle()
        .unsavedChangesGuard(isDirty: isDirty, canSave: canSave, confirming: $confirmingDiscard,
                             message: takes.state.stale
                                 ? "The takes are kept either way; the master is only rebuilt when you save."
                                 : "Your edits to this voice haven't been saved.",
                             save: save)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(voice?.name ?? "Voice").font(t.masthead(18)).foregroundStyle(t.fg)
            }
            if let voice, features.contains(.packShare) {
                ToolbarItem(placement: .voiceLeading) { shareMenu(voice) }
            }
            ToolbarItem(placement: .voiceTrailing) {
                Button("Save") { save() }.disabled(!canSave)
                    .font(t.console(13, .semibold)).tint(t.accent).foregroundStyle(t.accent)
            }
            // The keyboard's own way out. Save drops focus too, but a name
            // typed and left alone otherwise had no obvious dismissal.
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }.foregroundStyle(t.accent)
            }
            #endif
        }
        // On the Form, not the row: a destination inside a lazy container
        // is ignored.
        .navigationDestination(isPresented: $showingAdvanced) {
            VoiceAdvancedView(slug: slug, takes: takes)
        }
        #if os(iOS)
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                // `Data` rather than `Image`: UIImage decodes HEIC and keeps
                // the orientation, and the crop step draws it upright.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    // Let the picker finish dismissing before the crop cover
                    // goes up, or SwiftUI drops one of the two presentations.
                    try? await Task.sleep(for: .milliseconds(350))
                    cropping = CropCandidate(image: image)
                } else {
                    errorText = userMessage(for: VoiceStoreError.unreadableImage)
                }
            }
        }
        .voiceCover(isPresented: $takingPhoto, onDismiss: {
            if let image = pendingCrop { pendingCrop = nil; cropping = CropCandidate(image: image) }
        }) {
            CameraPicker { data in pendingCrop = UIImage(data: data) }.ignoresSafeArea()
        }
        .voiceCover(item: $cropping) { candidate in
            AvatarCropView(image: candidate.image,
                           onChoose: { framed in
                               cropping = nil
                               if let png = framed.pngData() { apply(png) }
                           },
                           onCancel: { cropping = nil })
        }
        #else
        // A Mac has no camera sheet and no touch crop: the photo comes from a
        // file, and `AvatarImage` centre-crops it to the pack's square.
        .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { apply(data) }
                else { errorText = userMessage(for: VoiceStoreError.unreadableImage) }
            case .failure(let error):
                errorText = userMessage(for: error)
            }
        }
        #endif
        .onAppear {
            if let voice { name = voice.name; notes = voice.meta.notes ?? ""; takes.bind(store: store, voice: voice) }
            transcript = storedTranscript
            measureReference()
        }
        // Advanced can clean or rebuild the master; measure it again on return.
        .onChange(of: voice) { _, _ in transcript = storedTranscript; measureReference() }
        // The first take adopts the master as take 1 with the master's
        // stored words; an edit still sitting in the transcript field would
        // otherwise be lost to the rebuild, so it rides into that take.
        .onChange(of: takes.state.count) { was, now in
            guard was == 0, now > 0 else { return }
            let edited = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !edited.isEmpty, edited != storedTranscript { takes.carryTranscriptIntoAdoptedMaster(edited) }
            transcript = storedTranscript
        }
        .onDisappear {
            player.stop()
            // Only a real dismissal stops the check -- not something this
            // screen put on top of itself (Advanced, a full-screen cover).
            if !presentingOverSelf { abandonCheck() }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete this voice?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let voice { store.delete(voice) }
                dismiss()
            }
        } message: {
            Text("It is removed from this device. A shared copy is not affected.")
        }
        .alert("Couldn't do that", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    /// The face above the form. The avatar IS the button: tap it for the
    /// two ways in (camera only where one exists) and, once there is a
    /// picture, the way out. A small camera badge says it is tappable.
    private var avatarSection: some View {
        Section {
            Menu {
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                }
                #endif
                Button("Choose Photo", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                if voice?.avatarURL != nil {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        do { try store.removeAvatar(slug) } catch { errorText = userMessage(for: error) }
                    }
                }
            } label: {
                VoiceAvatarView(voice: voice, size: 96)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(t.accent))
                            .overlay(Circle().strokeBorder(t.ink, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice?.avatarURL == nil ? "Add photo" : "Change photo")
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    /// Something this screen put on top of itself (Advanced, a full-screen cover).
    private var presentingOverSelf: Bool {
        #if os(iOS)
        showingAdvanced || recording || takingPhoto || cropping != nil
        #else
        showingAdvanced || recording || choosingPhoto
        #endif
    }

    private func apply(_ imageData: Data) {
        do { try store.setAvatar(slug, imageData: imageData) }
        catch { errorText = userMessage(for: error) }
    }

    private func save() {
        focused = nil
        do {
            try store.update(slug) {
                $0.name = name.trimmingCharacters(in: .whitespaces)
                let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.notes = n.isEmpty ? nil : n
            }
            // A rebuild writes the transcript from the takes' words, so a
            // field edit is only applied when no rebuild is about to run.
            let rebuilding = takes.state.stale && takes.state.blocker == nil
            if let voice, !rebuilding, transcript.trimmingCharacters(in: .whitespacesAndNewlines) != storedTranscript {
                try store.updateTranscript(of: voice, transcript)
            }
            if rebuilding {
                try takes.rebuildMaster()
                transcript = storedTranscript
                measureReference()
            }
        } catch { errorText = userMessage(for: error) }
    }

    /// Two ways to pack under one menu: with the master recording (the
    /// desktop's default for your own voices) or renditions only. A Lux-only
    /// voice has no renditions, so the second is offered only when the pack
    /// has something else to ship. Both go through `PackShare`, which shows
    /// the wait rather than freezing under the tap.
    @ViewBuilder
    private func shareMenu(_ voice: Voice) -> some View {
        Menu {
            Button { share.share(voice, includeSource: true, using: store) } label: {
                Label("With master recording", systemImage: "waveform")
            }
            if !store.engineFiles(of: voice.slug).isEmpty {
                Button { share.share(voice, includeSource: false, using: store) } label: {
                    Label("Renditions only", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .tint(t.accent).foregroundStyle(t.accent)
    }
}
