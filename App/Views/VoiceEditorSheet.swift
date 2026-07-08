import SpeechKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// The clone-a-recording editor: name + reference clip (record / drop /
/// sample) + transcript. Hosted inline by the Create Voice page's
/// "From a recording" mode, and by `VoiceEditorSheet` for the contextual
/// emotion-variant flow.
struct VoiceEditorForm: View {
    let editingSlug: String?
    var prefilledName: String? = nil
    /// Called with the saved voice's slug (nil when updating an existing one).
    var onSaved: (String?) -> Void
    /// When non-nil a Cancel button shows (sheet hosting); inline hosting omits it.
    var onCancel: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var refText = ""
    /// Reference clips — several combine into one steadier reference on save.
    @State private var refClips: [RefClip] = []
    @State private var keepingExistingRef = false
    @State private var showRecorder = false

    struct RefClip: Identifiable {
        let id = UUID()
        let data: Data
        let label: String
    }
    @State private var error: String?
    @State private var transcribing = false
    @State private var transcriptNote: String?
    @State private var avatarVersion = 0
    @State private var avatarImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                let _ = avatarVersion  // depend on version so view refreshes after save/remove
                VoiceAvatarView(
                    slug: editingSlug ?? "",
                    name: name,
                    avatarURL: editingSlug.flatMap { model.voices.avatarURL($0) },
                    size: 72)
                VStack(alignment: .leading, spacing: 6) {
                    if editingSlug != nil {
                        Button("Upload Photo…") { avatarImporterPresented = true }
                            .accessibilityIdentifier("avatar-upload")
                        if let slug = editingSlug, model.voices.avatarURL(slug) != nil {
                            Button("Remove") {
                                try? model.voices.removeAvatar(slug)
                                avatarVersion += 1
                            }
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("avatar-remove")
                        }
                    } else {
                        Text("Save voice first\nto upload a photo")
                            .font(.caption)
                            .foregroundStyle(Brand.fgFaint)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            TextField("Name", text: $name)
                .accessibilityIdentifier("voice-name")
            Text("Reference transcript (what the clip says — improves cloning)")
                .font(.caption).foregroundStyle(.secondary)
            ExpandableTextEditor(text: $refText, accessibilityID: "voice-ref-text")
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            if transcribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing reference…").font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let transcriptNote {
                Text(transcriptNote).font(.caption).foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 8) {
                    if refClips.isEmpty {
                        Text(keepingExistingRef ? "Keeping existing reference" : "No reference yet")
                            .font(.callout)
                    } else {
                        ForEach(refClips) { clip in
                            HStack(spacing: 6) {
                                Image(systemName: "waveform").font(.caption)
                                    .foregroundStyle(Brand.fgDim)
                                Text(clip.label).font(.callout).lineLimit(1)
                                Spacer()
                                Button {
                                    refClips.removeAll { $0.id == clip.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Brand.fgFaint)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this clip")
                            }
                        }
                        if refClips.count > 1 {
                            Text("Clips are combined into one reference — more "
                                 + "material makes a steadier clone.")
                                .font(.caption2).foregroundStyle(Brand.fgFaint)
                        }
                    }
                    HStack {
                        Button(refClips.isEmpty ? "Record…" : "Record another…") {
                            showRecorder = true
                        }
                        if UITestMode.isActive {
                            Button("Use Sample Reference") {
                                addClip(UITestMode.sampleReference(), label: "Sample reference (2.0 s)")
                            }
                            .accessibilityIdentifier("use-sample-ref")
                        }
                        Text("or drop audio files").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadDrop(providers); return true
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                if let onCancel {
                    Button("Cancel") { onCancel() }
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (editingSlug == nil && refClips.isEmpty))
                    .accessibilityIdentifier("voice-save")
            }
        }
        .sheet(isPresented: $showRecorder) {
            RecorderView { data, seconds in
                addClip(data, label: String(format: "Recorded clip (%.1f s)", seconds))
            }
        }
        .onAppear { loadExisting() }
        .fileImporter(
            isPresented: $avatarImporterPresented,
            allowedContentTypes: [.png, .jpeg, .heic, .image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first,
                  let slug = editingSlug else { return }
            url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            guard let raw = try? Data(contentsOf: url),
                  let png = AvatarProcessor.makeAvatarPNG(from: raw) else { return }
            try? model.voices.saveAvatar(slug, pngData: png)
            avatarVersion += 1
        }
    }

    private func addClip(_ data: Data, label: String) {
        refClips.append(RefClip(data: data, label: label))
        autoTranscribe(data)
    }

    private func autoTranscribe(_ clipData: Data) {
        transcribing = true
        transcriptNote = nil
        Task { @MainActor in
            defer { transcribing = false }
            guard await model.speech.ensureAuthorized() else {
                transcriptNote = "Speech permission denied — type the transcript manually."
                return
            }
            do {
                let transcriber = model.speech.makeTranscriber()
                let transcript = try await transcriber.transcribe(
                    wavData: clipData,
                    languageHint: model.speech.effectiveLanguageHint)
                // Append per clip (never clobber what the user typed): the
                // combined reference's transcript is the clips' texts in order.
                let existing = refText.trimmingCharacters(in: .whitespacesAndNewlines)
                refText = existing.isEmpty ? transcript.text
                    : existing + " " + transcript.text
                transcriptNote = "Auto-transcribed — review before saving."
            } catch {
                transcriptNote = "Couldn't auto-transcribe (\(model.describeAny(error))) — type it manually."
            }
        }
    }

    private func loadExisting() {
        guard let slug = editingSlug, let found = try? model.voices.get(slug) else {
            if editingSlug == nil, let prefill = prefilledName {
                name = prefill
            }
            return
        }
        name = found.meta.name
        refText = found.meta.refText
        keepingExistingRef = true
    }

    private func loadDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    do {
                        try RefAudioValidator.validate(url: url)
                        let data = try Data(contentsOf: url)
                        error = nil
                        addClip(data, label: url.lastPathComponent)
                    } catch { self.error = "\(error)" }
                }
            }
        }
    }

    /// The clips resolved into one reference WAV: single clip passes through,
    /// several combine (resampled, normalized, gap-joined); none = nil (edit
    /// mode keeps the existing reference).
    private func resolvedReference() throws -> Data? {
        switch refClips.count {
        case 0: return nil
        case 1: return refClips[0].data
        default:
            return try RefAudioCombiner.combine(
                clips: refClips.map { ($0.data, "") }).wav
        }
    }

    private func save() {
        do {
            let refWav = try resolvedReference()
            if let slug = editingSlug {
                // updateVoice (not voices.update): a rename re-slugs, and the
                // wrapper migrates chats + emotion variants + selection.
                _ = try model.updateVoice(slug, name: name, refText: refText,
                                          refWav: refWav)
                onSaved(nil)
            } else {
                let meta = try model.voices.save(name: name, refWav: refWav ?? Data(),
                                                 refText: refText)
                model.voicesVersion += 1
                onSaved(meta.slug)
            }
        } catch StudioError.voiceExists(let slug) {
            error = "A voice named '\(slug)' already exists."
        } catch { self.error = "\(error)" }
    }
}

/// Sheet wrapper — kept for the contextual "New Emotion Variant…" flow; plain
/// voice creation lives inline on the Create Voice page ("From a recording").
struct VoiceEditorSheet: View {
    let editingSlug: String?
    var prefilledName: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingSlug == nil ? "New Voice" : "Edit Voice").font(.title3.bold())
            VoiceEditorForm(
                editingSlug: editingSlug,
                prefilledName: prefilledName,
                onSaved: { _ in dismiss() },
                onCancel: { dismiss() })
        }
        .padding(20)
        .frame(width: 440)
    }
}
