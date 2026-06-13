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
    @State private var refPlayer = PreviewPlayer()
    @State private var variantBase: VoiceMeta?
    @State private var hoveredSlug: String?
    @State private var catalogPresented = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("VOICES")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(Brand.fgDim)
                Spacer()
                Button { editingSlug = nil; editorPresented = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("new-voice")
                .help("Create a new voice from a recording or audio file")
                Button { importerPresented = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import .gvoice voice packs")
                Button { catalogPresented = true } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Browse free downloadable voices")
                .accessibilityIdentifier("browse-catalog")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            List(selection: $model.selectedVoiceSlug) {
                if voiceList.isEmpty {
                    Text("No voices yet — click + to record or drop a clip.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(voiceList, id: \.slug) { voice in
                    HStack(spacing: 8) {
                        VoiceAvatarView(
                            slug: voice.slug,
                            name: voice.name,
                            avatarURL: model.voices.avatarURL(voice.slug),
                            size: 26)
                        VStack(alignment: .leading) {
                            Text(voice.name)
                            if voice.slug.contains("-") {
                                Text(voice.slug).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        // Visible affordances so actions aren't buried in the
                        // right-click menu: a hover-revealed edit pencil + an
                        // always-present ⋯ overflow that mirrors the context menu.
                        if hoveredSlug == voice.slug || model.selectedVoiceSlug == voice.slug {
                            Button { editingSlug = voice.slug; editorPresented = true } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Brand.fgDim)
                            .help("Edit voice name and reference audio")
                            .accessibilityIdentifier("edit-voice")
                        }
                        Menu {
                            voiceActions(voice)
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Brand.fgDim)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More actions")
                        .accessibilityIdentifier("voice-menu")
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { hoveredSlug = voice.slug }
                        else if hoveredSlug == voice.slug { hoveredSlug = nil }
                    }
                    .tag(voice.slug)
                    .contextMenu { voiceActions(voice) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .fileImporter(isPresented: $importerPresented,
                          allowedContentTypes: [.gvoice, .zip],
                          allowsMultipleSelection: true) { result in
                importPacks(result)
            }
            .accessibilityIdentifier("voice-list")
            .sheet(isPresented: $editorPresented, onDismiss: { variantBase = nil }) {
                if let base = variantBase {
                    VoiceEditorSheet(editingSlug: nil,
                                     prefilledName: "\(base.name)-hype")
                } else {
                    VoiceEditorSheet(editingSlug: editingSlug)
                }
            }
            .sheet(isPresented: $catalogPresented) {
                VoiceCatalogView()
                    .environment(model)
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
            .background(
                Color.clear
                    .frame(width: 0, height: 0)
                    .fileImporter(isPresented: $migratePresented,
                                  allowedContentTypes: [.folder],
                                  allowsMultipleSelection: false) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            migrateFromFolder(url)
                        }
                    }
            )
        }
    }

    /// Shared action set for a voice — used by both the row's ⋯ overflow menu
    /// and its right-click context menu so they never drift apart.
    @ViewBuilder
    private func voiceActions(_ voice: VoiceMeta) -> some View {
        Button("Edit…") { editingSlug = voice.slug; editorPresented = true }
            .help("Edit voice name and reference audio")
        Button("Preview Reference") { previewRef(voice) }
            .help("Play the reference audio for this voice")
        Button("New Emotion Variant…") {
            variantBase = voice
            editingSlug = nil
            editorPresented = true
        }
        .help("Create a variant of this voice for a specific emotion")
        Button("Export…") { export(voice.slug) }
            .help("Export voice as a .gvoice pack")
        Divider()
        Button("Delete", role: .destructive) { delete(voice.slug) }
            .help("Permanently delete this voice")
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
        guard let (_, refURL) = try? model.voices.get(voice.slug) else { return }
        refPlayer.toggle(id: voice.slug, url: refURL)
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
