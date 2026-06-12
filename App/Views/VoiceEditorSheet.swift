import StudioKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceEditorSheet: View {
    let editingSlug: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var refText = ""
    @State private var refData: Data?
    @State private var refDescription = "No reference yet"
    @State private var showRecorder = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingSlug == nil ? "New Voice" : "Edit Voice").font(.title3.bold())
            TextField("Name", text: $name)
                .accessibilityIdentifier("voice-name")
            Text("Reference transcript (what the clip says — improves cloning)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $refText).frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

            GroupBox {
                VStack(spacing: 8) {
                    Text(refDescription).font(.callout)
                    HStack {
                        Button("Record…") { showRecorder = true }
                        if UITestMode.isActive {
                            Button("Use Sample Reference") {
                                refData = UITestMode.sampleReference()
                                refDescription = "Sample reference (2.0 s)"
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
            }
        }
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let slug = editingSlug, let found = try? model.voices.get(slug) else { return }
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
