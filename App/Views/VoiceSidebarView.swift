import AVFAudio
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let gloamMigrate = Notification.Name("gloamMigrate")
}

struct VoiceSidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var editorPresented = false
    @State private var editingSlug: String?
    @State private var importerPresented = false
    @State private var exportDoc: DataDocument?
    @State private var exportName = ""
    @State private var actionError: String?
    @State private var migratePresented = false
    @State private var refPlayer: AVAudioPlayer?
    @State private var previewingSlug: String?
    @State private var variantBase: VoiceMeta?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedVoiceSlug) {
            Section("Voices") {
                ForEach(voiceList, id: \.slug) { voice in
                    VStack(alignment: .leading) {
                        Text(voice.name)
                        if voice.slug.contains("-") {
                            Text(voice.slug).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(voice.slug)
                    .contextMenu {
                        Button("Edit…") { editingSlug = voice.slug; editorPresented = true }
                        Button("Preview Reference") { previewRef(voice) }
                        Button("New Emotion Variant…") {
                            variantBase = voice
                            editingSlug = nil
                            editorPresented = true
                        }
                        Button("Export…") { export(voice.slug) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(voice.slug) }
                    }
                }
            }
        }
        .accessibilityIdentifier("voice-list")
        .toolbar {
            ToolbarItem {
                Button { editingSlug = nil; editorPresented = true } label: {
                    Label("New Voice", systemImage: "plus")
                }
                .accessibilityIdentifier("new-voice")
            }
            ToolbarItem {
                Button { importerPresented = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $editorPresented, onDismiss: { variantBase = nil }) {
            if let base = variantBase {
                VoiceEditorSheet(editingSlug: nil,
                                 prefilledName: "\(base.name)-hype")
            } else {
                VoiceEditorSheet(editingSlug: editingSlug)
            }
        }
        .fileImporter(isPresented: $importerPresented,
                      allowedContentTypes: [.gvoice, .zip],
                      allowsMultipleSelection: true) { result in
            importPacks(result)
        }
        .fileImporter(isPresented: $migratePresented,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                migrateFromFolder(url)
            }
        }
        .fileExporter(isPresented: .init(get: { exportDoc != nil },
                                         set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .gvoice,
                      defaultFilename: exportName) { _ in exportDoc = nil }
        .alert("Voice Library", isPresented: .init(get: { actionError != nil },
                                                   set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .gloamMigrate)) { _ in
            migratePresented = true
        }
    }

    private var voiceList: [VoiceMeta] {
        _ = model.voicesVersion
        return model.voices.list()
    }

    private func export(_ slug: String) {
        do {
            exportDoc = DataDocument(data: try GVoice.export(slug, from: model.voices))
            exportName = slug
        } catch { actionError = "\(error)" }
    }

    private func delete(_ slug: String) {
        do {
            try model.voices.delete(slug)
            if model.selectedVoiceSlug == slug { model.selectedVoiceSlug = nil }
            model.voicesVersion += 1
        } catch { actionError = "\(error)" }
    }

    private func importPacks(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var failures: [String] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            do { _ = try GVoice.`import`(try Data(contentsOf: url), into: model.voices) }
            catch { failures.append("\(url.lastPathComponent): \(error)") }
        }
        model.voicesVersion += 1
        if !failures.isEmpty { actionError = failures.joined(separator: "\n") }
    }

    private func previewRef(_ voice: VoiceMeta) {
        if previewingSlug == voice.slug {
            refPlayer?.stop()
            refPlayer = nil
            previewingSlug = nil
            return
        }
        guard let (_, refURL) = try? model.voices.get(voice.slug) else { return }
        refPlayer = try? AVAudioPlayer(contentsOf: refURL)
        refPlayer?.play()
        previewingSlug = voice.slug
    }

    private func migrateFromFolder(_ folderURL: URL) {
        guard folderURL.startAccessingSecurityScopedResource() else {
            actionError = "Could not access the selected folder."
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        var failures: [String] = []
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            actionError = "Could not read folder contents."
            return
        }
        for subdir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let metaURL = subdir.appendingPathComponent("meta.json")
            let refURL = subdir.appendingPathComponent("ref.wav")
            guard fm.fileExists(atPath: metaURL.path), fm.fileExists(atPath: refURL.path) else { continue }
            do {
                let metaData = try Data(contentsOf: metaURL)
                let metaJSON = try JSONSerialization.jsonObject(with: metaData) as? [String: Any] ?? [:]
                let name = metaJSON["name"] as? String ?? subdir.lastPathComponent
                let refText = metaJSON["refText"] as? String ?? ""
                let refWav = try Data(contentsOf: refURL)
                _ = try model.voices.save(name: name, refWav: refWav, refText: refText)
            } catch {
                failures.append("\(subdir.lastPathComponent): \(error)")
            }
        }
        model.voicesVersion += 1
        if !failures.isEmpty { actionError = failures.joined(separator: "\n") }
    }
}
