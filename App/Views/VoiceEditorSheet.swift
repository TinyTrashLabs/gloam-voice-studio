import SpeechKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceEditorSheet: View {
    let editingSlug: String?
    var prefilledName: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
            Text(editingSlug == nil ? "New Voice" : "Edit Voice").font(.title3.bold())
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
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (editingSlug == nil && refData == nil))
                    .accessibilityIdentifier("voice-save")
            }
        }
        .padding(20)
        .frame(width: 440)
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
                _ = try model.voices.update(slug, name: name, refText: refText,
                                            refWav: refData)
            } else {
                _ = try model.voices.save(name: name, refWav: refData ?? Data(),
                                          refText: refText)
            }
            model.voicesVersion += 1
            dismiss()
        } catch StudioError.voiceExists(let slug) {
            error = "A voice named '\(slug)' already exists."
        } catch { self.error = "\(error)" }
    }
}
