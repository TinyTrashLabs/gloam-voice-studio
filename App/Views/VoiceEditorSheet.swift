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
    @State private var refData: Data?
    @State private var refDescription = "No reference yet"
    @State private var showRecorder = false
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
            TextEditor(text: $refText).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityIdentifier("voice-ref-text")
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
                    Text(refDescription).font(.callout)
                    HStack {
                        Button("Record…") { showRecorder = true }
                        if UITestMode.isActive {
                            Button("Use Sample Reference") {
                                refData = UITestMode.sampleReference()
                                refDescription = "Sample reference (2.0 s)"
                                autoTranscribe()
                            }
                            .accessibilityIdentifier("use-sample-ref")
                        }
                        Text("or drop an audio file").foregroundStyle(.secondary)
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
                    .disabled(name.isEmpty || (editingSlug == nil && refData == nil))
                    .accessibilityIdentifier("voice-save")
            }
        }
        .sheet(isPresented: $showRecorder) {
            RecorderView { data, seconds in
                refData = data
                refDescription = String(format: "Recorded clip (%.1f s)", seconds)
                autoTranscribe()
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

    private func autoTranscribe() {
        guard let refData,
              refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }   // never clobber text the user typed
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
                    wavData: refData,
                    languageHint: model.speech.effectiveLanguageHint)
                if refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    refText = transcript.text
                    transcriptNote = "Auto-transcribed — review before saving."
                }
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
        refDescription = "Keeping existing reference"
    }

    private func loadDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                do {
                    try RefAudioValidator.validate(url: url)
                    refData = try Data(contentsOf: url)
                    refDescription = url.lastPathComponent
                    error = nil
                    autoTranscribe()
                } catch { self.error = "\(error)" }
            }
        }
    }

    private func save() {
        do {
            if let slug = editingSlug {
                // updateVoice (not voices.update): a rename re-slugs, and the
                // wrapper migrates chats + emotion variants + selection.
                _ = try model.updateVoice(slug, name: name, refText: refText,
                                          refWav: refData)
                onSaved(nil)
            } else {
                let meta = try model.voices.save(name: name, refWav: refData ?? Data(),
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
