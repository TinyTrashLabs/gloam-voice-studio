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
            // Brand lockup lives top-left in the sidebar — its proper home,
            // rather than floating in the bench where it read as misplaced.
            BrandLockup()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().overlay(Color.white.opacity(0.06))

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
                        // Visible affordances so the common actions aren't buried
                        // in the ⋯ overflow: an inline play-sample (surfaced per
                        // request), a hover-revealed edit pencil, then ⋯ for the
                        // rest. Play stays visible while THIS voice is playing so
                        // you can stop it without re-hovering.
                        let isPlaying = refPlayer.playingID == voice.slug
                        let showControls = hoveredSlug == voice.slug
                            || model.selectedVoiceSlug == voice.slug
                        if showControls || isPlaying {
                            Button { previewRef(voice) } label: {
                                ZStack {
                                    if isPlaying {
                                        EqualizerBars(color: Brand.accent)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Brand.fgDim)
                                    }
                                }
                                .frame(width: 22, height: 22)
                                .background(Circle()
                                    .fill(Color.white.opacity(isPlaying ? 0.08 : 0.0)))
                                .contentShape(Circle())
                            }
                            .buttonStyle(.borderless)
                            .help(isPlaying ? "Stop preview" : "Play sample")
                            .accessibilityIdentifier("play-voice")
                        }
                        if showControls {
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
        Button(refPlayer.playingID == voice.slug ? "Stop Sample" : "Play Sample") {
            previewRef(voice)
        }
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

/// Tiny animated equalizer — three accent bars bobbing at staggered rates,
/// echoing the EQ mark in the GLOAM.FM lockup. Shown in a voice row's play
/// button while that voice's sample is playing, so "now playing" reads as
/// motion, not just a swapped icon.
struct EqualizerBars: View {
    var color: Color = Brand.accent

    // Per-bar (rest height, peak height, beat duration) — different durations
    // keep the bars out of sync so the motion feels organic.
    private let bars: [(min: CGFloat, max: CGFloat, dur: Double)] = [
        (4, 12, 0.52), (8, 14, 0.38), (3, 10, 0.64),
    ]
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 2.5, height: animating ? bars[i].max : bars[i].min)
                    .animation(
                        .easeInOut(duration: bars[i].dur).repeatForever(autoreverses: true),
                        value: animating)
            }
        }
        .frame(width: 14, height: 14)
        .onAppear { animating = true }
    }
}
