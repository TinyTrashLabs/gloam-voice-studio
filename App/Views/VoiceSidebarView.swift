import EngineKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let gloamMigrate = Notification.Name("gloamMigrate")
}

struct VoiceSidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("studioSection") private var sectionRaw = StudioSection.studio.rawValue
    @State private var expandedBases: Set<String> = []
    @State private var importerPresented = false
    @State private var exportDoc: DataDocument?
    @State private var exportName = ""
    @State private var actionError: String?
    @State private var migratePresented = false
    @State private var refPlayer = PreviewPlayer()
    @State private var hoveredSlug: String?
    @State private var catalogPresented = false
    @State private var pendingDeleteSlug: String?
    @State private var searchText = ""

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

            // Section switching moved to the window toolbar (ContentView's
            // mainToolbar) — the standard scope-control spot, with ⌘1/⌘2/⌘3.
            HStack(alignment: .center) {
                Text("VOICES")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(Brand.fgDim)
                Spacer()
                Button {
                    // One create surface: land on Create Voice in recording
                    // mode instead of a popup (the page hosts both paths).
                    model.editingVoiceSlug = nil
                    model.createVoiceSource = .record
                    sectionRaw = StudioSection.createVoice.rawValue
                } label: {
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
                    // First-run empty state: say what a voice IS and offer all
                    // three ways in, instead of a one-liner pointing at "+".
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No voices yet")
                            .font(.callout.weight(.semibold))
                        Text("A voice is a reusable identity — record a clip, import a .gvoice pack, or grab a free one.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            model.editingVoiceSlug = nil
                            model.createVoiceSource = .record
                            sectionRaw = StudioSection.createVoice.rawValue
                        } label: {
                            Label("Record a voice", systemImage: "mic")
                        }
                        Button { catalogPresented = true } label: {
                            Label("Browse free voices", systemImage: "person.crop.circle.badge.plus")
                        }
                        Button { importerPresented = true } label: {
                            Label("Import .gvoice", systemImage: "square.and.arrow.down")
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("voices-empty-state")
                }
                let groups = filteredGroups
                if groups.isEmpty && !voiceList.isEmpty && !searchText.isEmpty {
                    Text("No voices match “\(searchText)”")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(groups, id: \.base.slug) { group in
                    voiceRow(group.base, isVariant: false, variantCount: group.variants.count)
                    // While searching, matched groups show their variants without
                    // needing a chevron click — the match may BE a variant.
                    if expandedBases.contains(group.base.slug) || !searchText.isEmpty {
                        ForEach(group.variants, id: \.slug) { variant in
                            voiceRow(variant, isVariant: true, variantCount: 0)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search voices")
            .scrollContentBackground(.hidden)
            .fileImporter(isPresented: $importerPresented,
                          allowedContentTypes: [.gvoice, .zip],
                          allowsMultipleSelection: true) { result in
                importPacks(result)
            }
            .accessibilityIdentifier("voice-list")
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
            .confirmationDialog(
                "Delete “\(pendingDeleteSlug.flatMap { try? model.voices.get($0).meta.name } ?? "")”?",
                isPresented: .init(get: { pendingDeleteSlug != nil },
                                   set: { if !$0 { pendingDeleteSlug = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let slug = pendingDeleteSlug { delete(slug) }
                    pendingDeleteSlug = nil
                }
                .accessibilityIdentifier("confirm-delete-voice")
            } message: {
                Text("This permanently deletes the voice and cannot be undone.")
            }
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

    /// One sidebar row. A base voice with acted variants shows a disclosure chevron
    /// and a count badge; variants render indented under their base, labeled by emotion.
    @ViewBuilder
    private func voiceRow(_ voice: VoiceMeta, isVariant: Bool, variantCount: Int) -> some View {
        let isPlaying = refPlayer.playingID == voice.slug
        let showControls = hoveredSlug == voice.slug || model.selectedVoiceSlug == voice.slug
        // Engine-matched enablement: derived from the voice's pack contents
        // (source audio and/or engines/<id>/ renditions). Unrenderable rows
        // stay selectable (editing, persona) but dim and say what they DO work
        // on, so a supertonic-only pack isn't mistaken for broken.
        let caps = model.voices.capabilities(voice.slug)
        let renderable = caps.supports(model.backend)
        HStack(spacing: 8) {
            if isVariant {
                Color.clear.frame(width: 16)
            } else if variantCount > 0 {
                Button { toggleExpanded(voice.slug) } label: {
                    Image(systemName: expandedBases.contains(voice.slug) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.fgDim)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
            } else {
                Color.clear.frame(width: 12)
            }
            VoiceAvatarView(slug: voice.slug, name: voice.name,
                            avatarURL: model.voices.avatarURL(voice.slug),
                            size: isVariant ? 20 : 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(voice.name).font(isVariant ? .callout : .body)
                        .foregroundStyle(renderable ? Brand.fg : Brand.fgFaint)
                    if !renderable && !isVariant {
                        // Minimal indicator — the full engine list lives in the
                        // tooltip, keeping the row quiet (dim name + one glyph).
                        let supported = BackendID.allCases.filter { caps.supports($0) }.map(\.rawValue)
                        Image(systemName: "speaker.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(Brand.fgFaint)
                            .help(supported.isEmpty
                                  ? "\(voice.name)'s pack has no renderable assets."
                                  : "\(voice.name) has no assets \(model.backend.rawValue) can render — it works on: \(supported.joined(separator: ", ")).")
                    }
                    if variantCount > 0 {
                        Text("\(variantCount)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundStyle(Brand.fgDim)
                    }
                }
                if isVariant {
                    Text(variantEmotionLabel(voice.slug)).font(.caption2).foregroundStyle(.secondary)
                } else if voice.slug.contains("-") {
                    Text(voice.slug).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if showControls || isPlaying {
                Button { previewRef(voice) } label: {
                    ZStack {
                        if isPlaying { EqualizerBars(color: Brand.accent) }
                        else {
                            Image(systemName: "play.fill").font(.system(size: 10))
                                .foregroundStyle(Brand.fgDim)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(isPlaying ? 0.08 : 0.0)))
                    .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .help(isPlaying ? "Stop preview" : "Play sample")
                .accessibilityIdentifier("play-voice")
            }
            if showControls && !isVariant {
                Button { openEdit(voice.slug) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless).foregroundStyle(Brand.fgDim)
                .help("Edit this voice (name, reference, emotion variants)")
                .accessibilityIdentifier("edit-voice")
            }
            Menu { voiceActions(voice) } label: {
                Image(systemName: "ellipsis").foregroundStyle(Brand.fgDim)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More actions").accessibilityIdentifier("voice-menu")
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredSlug = voice.slug }
            else if hoveredSlug == voice.slug { hoveredSlug = nil }
        }
        .tag(voice.slug)
        .contextMenu { voiceActions(voice) }
    }

    private func variantEmotionLabel(_ slug: String) -> String {
        guard let dash = slug.lastIndex(of: "-") else { return slug }
        return String(slug[slug.index(after: dash)...]).capitalized
    }

    private func toggleExpanded(_ slug: String) {
        if expandedBases.contains(slug) { expandedBases.remove(slug) } else { expandedBases.insert(slug) }
    }

    /// Open a voice in the Create Voice page's Edit mode (full page, not the modal
    /// sheet). A variant has no page of its own — it opens its base, where it's managed.
    private func openEdit(_ slug: String) {
        model.editingVoiceSlug = voiceBaseSlug(for: slug, in: voiceList) ?? slug
        sectionRaw = StudioSection.createVoice.rawValue
    }

    /// Shared action set for a voice — used by both the row's ⋯ overflow menu
    /// and its right-click context menu so they never drift apart.
    @ViewBuilder
    private func voiceActions(_ voice: VoiceMeta) -> some View {
        Button("Edit…") { openEdit(voice.slug) }
            .help("Edit this voice (name, recording, emotion versions)")
        Button(refPlayer.playingID == voice.slug ? "Stop Sample" : "Play Sample") {
            previewRef(voice)
        }
        .help("Play the reference audio for this voice")
        Button("Export…") { export(voice.slug) }
            .help("Export voice as a .gvoice pack")
        Divider()
        Button("Delete", role: .destructive) { pendingDeleteSlug = voice.slug }
            .help("Permanently delete this voice")
    }

    private var voiceList: [VoiceMeta] {
        _ = model.voicesVersion
        return model.voices.list()
    }

    /// Groups surviving the search filter: a group stays when its base or any
    /// variant matches by name or slug (case-insensitive substring).
    private var filteredGroups: [(base: VoiceMeta, variants: [VoiceMeta])] {
        let groups = groupedVoices(voiceList)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        func matches(_ v: VoiceMeta) -> Bool {
            v.name.localizedCaseInsensitiveContains(query)
                || v.slug.localizedCaseInsensitiveContains(query)
        }
        return groups.filter { matches($0.base) || $0.variants.contains(where: matches) }
    }

    private func export(_ slug: String) {
        do {
            exportDoc = DataDocument(data: try GVoice.export(slug, from: model.voices))
            exportName = slug
        } catch { actionError = model.describeAny(error) }
    }

    private func delete(_ slug: String) {
        do {
            try model.voices.delete(slug)
            if model.selectedVoiceSlug == slug { model.selectedVoiceSlug = nil }
            model.voicesVersion += 1
        } catch { actionError = model.describeAny(error) }
    }

    private func importPacks(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var failures: [String] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            do { _ = try GVoice.`import`(try Data(contentsOf: url), into: model.voices) }
            catch { failures.append("\(url.lastPathComponent): \(model.describeAny(error))") }
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
                failures.append("\(subdir.lastPathComponent): \(model.describeAny(error))")
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
