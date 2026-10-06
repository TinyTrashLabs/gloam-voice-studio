import EngineKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// The Voice page — one surface, two modes. **Create** (default): `qwen3-design`
/// invents a voice from a description; you audition candidates and save one as a
/// Library clone reference. **Edit** (`model.editingVoiceSlug` set): tune an existing
/// voice's identity and (re-)bake its acted emotion variants. Both share the bake
/// panel, save-to-library, and page chrome.
struct CreateVoiceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var player = PreviewPlayer()

    // Create-mode
    @State private var savingCandidate: FoundryCandidate?
    @State private var saveName = ""
    @State private var saveError: String?

    // Which model renders variants. Fish (emotion markers → distinct emotions) is
    // preferred; Chatterbox is the fallback (intensity only) for users without Fish.
    @State private var bakeBaker: BackendID = .fishS2Pro
    @State private var deletingVariantSlug: String?
    @State private var recordingVariant: RecordVariantTarget?

    /// Target of the guided record-a-take flow (sheet item).
    private struct RecordVariantTarget: Identifiable {
        let baseSlug: String
        let baseName: String
        let emotion: Emotion
        var id: String { "\(baseSlug)-\(emotion.rawValue)" }
    }

    // Edit-mode
    @State private var editName = ""
    @State private var editRefText = ""
    /// The home language tag as stored; "" = not stated.
    @State private var editLanguage = ""
    @State private var editReplaceData: Data?
    @State private var editReplaceDesc = "Keeping existing reference"
    @State private var editError: String?
    @State private var avatarVersion = 0
    @State private var avatarImporter = false
    @State private var audioImporter = false

    private var editSlug: String? { model.editingVoiceSlug }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let slug = editSlug { editContent(slug) } else { createContent }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $savingCandidate) { saveSheet($0) }
        .sheet(item: $recordingVariant) { target in
            RecordEmotionVariantSheet(
                baseSlug: target.baseSlug, baseName: target.baseName,
                emotion: target.emotion, onSaved: {})
        }
        .confirmationDialog(
            "Delete this take?",
            isPresented: Binding(get: { deletingVariantSlug != nil },
                                 set: { if !$0 { deletingVariantSlug = nil } }),
            presenting: deletingVariantSlug
        ) { slug in
            Button("Delete Take", role: .destructive) {
                do { try model.voices.deleteTake(slug) } catch { editError = model.describeAny(error) }
                model.voicesVersion += 1
                deletingVariantSlug = nil
            }
            Button("Cancel", role: .cancel) { deletingVariantSlug = nil }
        } message: { _ in
            Text("This permanently removes this take's clip. The voice's own reference is unaffected.")
        }
        .task(id: editSlug) { loadEdit(editSlug) }
    }

    // MARK: - Create mode

    @ViewBuilder private var createContent: some View {
        @Bindable var model = model
        HStack(alignment: .top) {
            header(title: "Create a Voice",
                   subtitle: model.createVoiceSource == .describe
                       ? "Describe a voice, audition takes until one clicks, then save it to your "
                         + "library — every clone model (and the whole app) can reuse it from then on."
                       : "Record or drop a clip of a voice you have the rights to use — it becomes "
                         + "a reusable Library voice for every clone model (and the whole app).")
            Spacer()
            docsHelpButton
        }
        Picker("", selection: $model.createVoiceSource) {
            Text("From a description").tag(AppModel.CreateVoiceSource.describe)
            Text("From a recording").tag(AppModel.CreateVoiceSource.record)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("create-voice-source")
        switch model.createVoiceSource {
        case .describe:
            designModelStrip
            describeCard
            auditionCard
            generateBar
            if let err = model.foundryError { errorText(err) }
            if !model.foundryCandidates.isEmpty { candidatesSection }
            if let slug = model.lastSavedFoundrySlug { manageVariantsPanel(targetSlug: slug, note: true) }
        case .record:
            recordCard
            if let slug = model.lastSavedFoundrySlug { manageVariantsPanel(targetSlug: slug, note: true) }
        }
    }

    /// Inline clone-a-recording editor — the sheet the sidebar "+" used to
    /// open, now living where voice creation lives. Saving selects the new
    /// voice and offers the same variants panel the Foundry flow gets.
    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceEditorForm(editingSlug: nil, onSaved: { slug in
                if let slug {
                    model.lastSavedFoundrySlug = slug
                    model.selectedVoiceSlug = slug
                }
            })
            .padding(14)
        }
        .background(boxBG).overlay(boxStroke)
        .frame(maxWidth: 480)
    }

    private var designModelStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(model.loadedBackend == .qwenDesign ? .green : Brand.fgFaint)
                .frame(width: 7, height: 7)
            Text("qwen3-design").font(.system(.caption, design: .monospaced)).foregroundStyle(Brand.fgDim)
            Text(designStateText).font(.caption2).foregroundStyle(Brand.fgFaint)
            Spacer()
            designLoadButton
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }

    private var designStateText: String {
        if model.loadedBackend == .qwenDesign { return "loaded" }
        switch model.downloads.state(for: .qwenDesign) {
        case .ready: return "on disk, not loaded"
        case .downloading(let f): return "downloading \(Int(f * 100))%"
        case .notDownloaded: return "not downloaded"
        case .failed: return "download failed"
        }
    }

    @ViewBuilder private var designLoadButton: some View {
        if model.loadedBackend == .qwenDesign {
            Button("Unload") { Task { await model.unloadModel() } }
                .font(.caption).disabled(model.isGenerating || model.modelOpInFlight)
        } else {
            switch model.downloads.state(for: .qwenDesign) {
            case .ready:
                Button("Load") { Task { await model.loadModel(.qwenDesign) } }
                    .font(.caption).disabled(model.modelOpInFlight)
            case .notDownloaded, .failed:
                Button("Download") { model.downloads.download(.qwenDesign) }.font(.caption)
            case .downloading:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var describeCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                zoneLabel("DESCRIBE THE VOICE")
                Spacer()
                ExpandButton(text: $model.foundryDescription, kind: .voiceDescription)
            }
            Text("Timbre, age, accent, mood, pace — plain English, ~1–3 sentences.")
                .font(.caption2).foregroundStyle(.secondary)
            ExpandableTextEditor(text: $model.foundryDescription, accessibilityID: "foundry-description")
                .font(.callout).scrollContentBackground(.hidden)
                .padding(6).background(boxBG).overlay(boxStroke)
            if model.foundryDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(#"e.g. "elderly storyteller, gravelly and slow, with a knowing warmth""#)
                    .font(.caption2).italic().foregroundStyle(Brand.fgFaint)
            }
            VoiceDesignBuilder(instruct: $model.foundryDescription)
            HStack {
                Text("Language").font(.caption).foregroundStyle(Brand.fgDim)
                Picker("", selection: $model.foundryLanguage) {
                    ForEach(StudioView.languages, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().frame(width: 160)
            }
        }
    }

    private var auditionCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            zoneLabel("AUDITION LINE")
            Text("What each candidate says while you audition. A varied ~6–8s line makes the "
                 + "cleanest clone reference; edit it or use your own.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ExpandableTextEditor(text: $model.foundryAuditionLine, accessibilityID: "foundry-audition-line")
                .font(.callout).scrollContentBackground(.hidden)
                .padding(6).background(boxBG).overlay(boxStroke)
        }
    }

    private var generateBar: some View {
        HStack(spacing: 10) {
            Button { Task { await model.generateFoundryCandidate() } } label: {
                Label(model.foundryCandidates.isEmpty ? "Generate a candidate" : "Generate another",
                      systemImage: "wand.and.stars")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.foundryGenerating)
            .accessibilityIdentifier("foundry-generate")
            if model.foundryGenerating { ProgressView().controlSize(.small) }
            Spacer()
            if !model.foundryCandidates.isEmpty {
                Text("\(model.foundryCandidates.count) so far — each a different voice")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
            }
        }
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            zoneLabel("CANDIDATES — PICK ONE TO SAVE")
            ForEach(model.foundryCandidates) { candidate in
                FoundryCandidateRow(
                    candidate: candidate, player: player,
                    onSave: { saveName = ""; saveError = nil; savingCandidate = candidate },
                    onUsePrompt: {
                        model.foundryDescription = candidate.description
                        model.foundryAuditionLine = candidate.auditionLine
                        model.foundryLanguage = candidate.language ?? "auto"
                    })
            }
        }
    }

    private func saveSheet(_ candidate: FoundryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save this voice").font(.title3.bold())
            Text("It joins your library as a clone reference — the audition line becomes its "
                 + "transcript, so it clones cleanly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name (e.g. Gravel Narrator)", text: $saveName)
                .textFieldStyle(.roundedBorder).onSubmit { commitSave(candidate) }
                .accessibilityIdentifier("foundry-save-name")
            if let err = saveError { Text(err).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { savingCandidate = nil }
                Button("Save") { commitSave(candidate) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 440)
    }

    private func commitSave(_ candidate: FoundryCandidate) {
        do { try model.saveFoundryVoice(candidate, name: saveName); savingCandidate = nil }
        catch { saveError = model.describeAny(error) }
    }

    // MARK: - Edit mode

    @ViewBuilder private func editContent(_ slug: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            header(title: "Edit Voice", subtitle: "Rename, refine the reference, and manage every take "
                   + "of this voice — its languages and acted styles. The whole app uses them.")
            Spacer()
            docsHelpButton
            Button("Done") { model.editingVoiceSlug = nil }
                .accessibilityIdentifier("edit-done")
        }
        editIdentityCard(slug)
        editReferenceCard(slug)
        manageVariantsPanel(targetSlug: slug, note: false)
        if let err = editError { errorText(err) }
        if let err = model.foundryError { errorText(err) }
        HStack {
            Spacer()
            Button("Save changes") { saveEdit(slug) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("edit-save")
        }
    }

    private func editIdentityCard(_ slug: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            zoneLabel("IDENTITY")
            HStack(spacing: 14) {
                let _ = avatarVersion
                VoiceAvatarView(slug: slug, name: editName,
                                avatarURL: model.voiceAvatarURL(slug), size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Upload Photo…") { avatarImporter = true }
                    if model.voiceAvatarURL(slug) != nil {
                        Button("Remove") {
                            do { try model.voices.removeAvatar(slug); avatarVersion += 1 }
                            catch { editError = model.describeAny(error) }
                        }
                        .foregroundStyle(.red)
                    }
                }.font(.caption)
            }
            TextField("Name", text: $editName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("edit-name")
            HStack(spacing: 8) {
                Text("Home language").font(.caption).foregroundStyle(Brand.fgDim)
                Picker("", selection: $editLanguage) {
                    Text("Not stated").tag("")
                    ForEach(homeLanguageChoices, id: \.self) {
                        Text("\(VoiceTakesPanel.languageName($0)) (\($0))").tag($0)
                    }
                }
                .labelsHidden().frame(width: 200)
                .accessibilityIdentifier("edit-home-language")
                Text("What the reference clip speaks — packs must state it.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
            }
        }
        .fileImporter(isPresented: $avatarImporter,
                      allowedContentTypes: [.png, .jpeg, .heic, .image],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            guard let raw = try? Data(contentsOf: url),
                  let png = AvatarProcessor.makeAvatarPNG(from: raw) else { return }
            do {
                try model.voices.saveAvatar(slug, pngData: png)
                avatarVersion += 1
                model.voicesVersion += 1   // an avatar moves a preset out of Bundled
            }
            catch { editError = model.describeAny(error) }
        }
    }

    private func editReferenceCard(_ slug: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            zoneLabel("REFERENCE CLIP")
            HStack(spacing: 10) {
                if let url = try? model.voices.get(slug).refURL {
                    Button(player.playingID == "ref-\(slug)" ? "Stop" : "Play reference") {
                        player.toggle(id: "ref-\(slug)", url: url)
                    }
                }
                Button("Replace…") { audioImporter = true }
                Text(editReplaceDesc).font(.caption).foregroundStyle(.secondary)
            }
            Text("Reference transcript (what the clip says — improves cloning)")
                .font(.caption2).foregroundStyle(.secondary)
            ExpandableTextEditor(text: $editRefText, accessibilityID: "edit-ref-text")
                .font(.callout).scrollContentBackground(.hidden)
                .padding(6).background(boxBG).overlay(boxStroke)
        }
        .fileImporter(isPresented: $audioImporter,
                      allowedContentTypes: [.audio, .wav, .mpeg4Audio],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try RefAudioValidator.validate(url: url)
                editReplaceData = try Data(contentsOf: url)
                editReplaceDesc = "New reference: \(url.lastPathComponent) (saved on Save)"
                editError = nil
            } catch { editError = model.describeAny(error) }
        }
    }

    /// Common tags, plus the voice's own when it's something else (kept as written).
    private var homeLanguageChoices: [String] {
        VoiceLanguages.common.contains(editLanguage) || editLanguage.isEmpty
            ? VoiceLanguages.common : [editLanguage] + VoiceLanguages.common
    }

    private func loadEdit(_ slug: String?) {
        guard let slug, let found = try? model.voices.get(slug) else { return }
        editName = found.meta.name
        editRefText = found.meta.refText
        editLanguage = found.meta.language ?? ""
        editReplaceData = nil
        editReplaceDesc = "Keeping existing reference"
        editError = nil
    }

    private func saveEdit(_ slug: String) {
        do {
            // updateVoice (not voices.update): a rename re-slugs, and the
            // wrapper migrates chats + emotion variants + selection with it.
            let meta = try model.updateVoice(
                slug, name: editName, refText: editRefText,
                refWav: (editReplaceData?.isEmpty == false) ? editReplaceData : nil)
            try model.voices.setHomeLanguage(meta.slug, editLanguage.isEmpty ? nil : editLanguage)
            model.voicesVersion += 1   // the takes grid re-labels its home row
            model.editingVoiceSlug = meta.slug
            model.selectedVoiceSlug = meta.slug
            editReplaceData = nil
            editReplaceDesc = "Keeping existing reference"
        } catch StudioError.voiceExists(let s) {
            editError = "A voice named '\(s)' already exists."
        } catch { editError = model.describeAny(error) }
    }

    // MARK: - Shared takes grid

    /// Every take of the voice (languages × styles), with the record / generate / add flows per cell.
    /// Used in Create (just-saved voice) and Edit.
    private func manageVariantsPanel(targetSlug: String, note: Bool) -> some View {
        VoiceTakesPanel(
            slug: targetSlug, note: note, player: player, baker: $bakeBaker,
            onRecord: { emotion in
                let baseName = (try? model.voices.meta(targetSlug).name) ?? targetSlug
                recordingVariant = RecordVariantTarget(baseSlug: targetSlug, baseName: baseName, emotion: emotion)
            },
            onDelete: { deletingVariantSlug = $0 })
    }

    // MARK: - Shared chrome

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold()).foregroundStyle(Brand.fg)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var docsHelpButton: some View {
        Button { openWindow(id: "docs") } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.fgDim)
        .help("Open documentation")
        .accessibilityIdentifier("create-voice-docs-help")
        .accessibilityLabel("Open Documentation")
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func zoneLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(2.0).foregroundStyle(Brand.fgFaint)
    }

    private var boxBG: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035))
    }
    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1)
    }
}

/// One generated qwen3-design candidate: waveform + play/save, plus an info
/// toggle revealing the prompt that produced it and a button to reload that
/// prompt into the editable fields above.
private struct FoundryCandidateRow: View {
    let candidate: FoundryCandidate
    let player: PreviewPlayer
    let onSave: () -> Void
    let onUsePrompt: () -> Void

    @State private var expanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    WaveformView(wavData: candidate.wavData).frame(height: 40)
                    Text(String(format: "%.1fs", candidate.seconds))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(Brand.fgDim)
                    Button(player.playingID == candidate.id ? "Stop" : "Play") {
                        player.toggle(id: candidate.id, data: candidate.wavData)
                    }.accessibilityIdentifier("foundry-play")
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(Brand.fgDim)
                    .help("Show the prompt that made this candidate")
                    .accessibilityIdentifier("foundry-info-toggle")
                    .accessibilityLabel("Candidate Details")
                    Button("Save as Voice…", action: onSave)
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("foundry-save")
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.description).font(.caption).foregroundStyle(.secondary)
                        Text("\u{201C}\(candidate.auditionLine)\u{201D}").font(.caption2).italic()
                            .foregroundStyle(Brand.fgFaint)
                        if let language = candidate.language {
                            Text("Language: \(language)").font(.caption2).foregroundStyle(Brand.fgFaint)
                        }
                        Button("Use this prompt", action: onUsePrompt)
                            .font(.caption).accessibilityIdentifier("foundry-use-prompt")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }
}
