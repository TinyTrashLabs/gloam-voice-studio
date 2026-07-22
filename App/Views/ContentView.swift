import EngineKit
import SwiftUI

/// Top-level main-pane section. `Studio` speaks with reusable voices; `createVoice`
/// is the Voice Foundry where `qwen3-design` mints new ones; `chat` converses with
/// a voice's persona through a local LLM.
enum StudioSection: String { case studio, createVoice, chat }

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var historyVisible = false
    @State private var modelPickerOpen = false
    @AppStorage("studioSection") private var sectionRaw = StudioSection.studio.rawValue

    private var section: StudioSection {
        StudioSection(rawValue: sectionRaw) ?? .studio
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VoiceSidebarView()
                .frame(width: 248)
                .background(Brand.ink2)
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            Group {
                switch section {
                case .studio: StudioView()
                case .createVoice: CreateVoiceView()
                case .chat: ChatView()
                }
            }
            .frame(maxWidth: .infinity)
            .background(Brand.ink)
            if historyVisible {
                // Floating drawer: elevated surface + leading shadow so it reads
                // as sliding over the bench rather than mirroring the library.
                HistoryView()
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 360)
                    .layoutPriority(-1)
                    .background(Brand.ink2.opacity(0.6))
                    .background(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.4), radius: 14, x: -8, y: 0)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: historyVisible)
        .toolbar { mainToolbar }
        .sheet(isPresented: .constant(!model.didAcceptCloneConsent)) {
            ConsentSheet()
        }
        .sheet(isPresented: Binding(
            get: { model.downloadPrompt != nil },
            set: { if !$0 { model.downloadPrompt = nil } })) {
            if let backend = model.downloadPrompt {
                DownloadPromptSheet(backend: backend)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.licensePromptBackend != nil },
            set: { if !$0 { model.cancelLicensePrompt() } })) {
            LicenseSheet()
        }
    }

    // macOS merges all automatic toolbar items into ONE "Liquid Glass" capsule.
    // We don't draw our own pill backgrounds (that double-chromed and bled over
    // the OS capsule). On macOS 26+, ToolbarSpacer(.fixed) splits the capsule
    // into separate glass pills — the native way to separate the model chip, the
    // API chip, and the icon buttons. On older macOS the spacers are absent and
    // the items share one capsule (acceptable fallback).
    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        // 0. Global download progress — appears only while a model is downloading,
        //    so a background fetch is always visible no matter which screen you're on.
        if let dl = model.downloads.activeDownload {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    ProgressView(value: dl.fraction).frame(width: 56)
                    Text("\(dl.label) \(Int(dl.fraction * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.fgDim)
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 9).padding(.vertical, 2)
                .help("Downloading \(dl.label)…")
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        }

        // 1+2. Model chooser — a Button + popover, NOT a native Menu. Menus
        //      rescale the status dot to the default control icon size (so it
        //      never matched the API dot) and flatten custom views. A popover
        //      renders full SwiftUI, so this chip and the API chip stay identical.
        ToolbarItem(placement: .automatic) {
            Button { modelPickerOpen.toggle() } label: { modelStatusChip }
                .buttonStyle(.plain)
                .accessibilityIdentifier("backend-picker")
                .help("Pick model · load/unload · memory")
                .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) { modelPickerList }
                .task {
                    model.downloads.refresh()
                    await model.refreshEngineStatus()
                }
        }

        // 2b. Resident model + app RAM — always visible so you can see and unload
        //     whatever is loaded, including qwen3-design (the Foundry loads it, but it
        //     isn't in the picker). This is the RAM-management surface on the top bar.
        ToolbarItem(placement: .automatic) { RAMChip() }

        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        // 3. API server indicator — clicking selects the API Server tab first
        //    (via shared AppStorage) so Settings opens there, not on whatever
        //    tab was last viewed.
        ToolbarItem(placement: .automatic) {
            SettingsLink { apiIndicatorLabel }
                .buttonStyle(.plain)
                .help(apiIndicatorHelp)
                .accessibilityIdentifier("api-indicator")
                .simultaneousGesture(TapGesture().onEnded {
                    UserDefaults.standard.set(SettingsTab.api.rawValue, forKey: "settingsTab")
                })
        }

        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        // 4+5. History toggle + settings gear share one pill (icon cluster).
        ToolbarItemGroup(placement: .automatic) {
            Button {
                historyVisible.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(historyVisible ? Brand.accent : Brand.fgDim)
            }
            .accessibilityIdentifier("open-history")
            .help("Toggle the history panel (⌘Y)")
            .keyboardShortcut("y", modifiers: .command)

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("open-settings")
        }
    }

    // Models offered in the chooser, in priority order.
    // Qwen3 (multilingual cloning) and turbo/Fish up top; regular chatterbox is
    // demoted to last for historical reasons (it used to double the line —
    // fixed 2026-07-02: CFG uncond-stream position embeddings, missing [SPACE]
    // tokenization, and uninitialized S3Gen attention biases, all in the vendored
    // mlx-audio-swift fork).
    private var pickerBackends: [BackendID] {
        // qwen3-design is intentionally absent — it's Creation-only, in the Voice
        // Foundry (Create Voice), not a Studio backend. Still downloadable in Settings.
        [.qwen06B, .qwen17B, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox, .kokoro,
         .supertonic]
    }

    private func modelDisplayName(_ b: BackendID) -> String {
        switch b {
        case .qwen06B: "qwen3-0.6b · clone a voice"
        case .qwen17B: "qwen3-1.7b · clone a voice"
        case .qwenDesign: "qwen3-design · design from text"
        case .qwenCustom: "qwen3-custom · direct a preset voice"
        default: b.rawValue
        }
    }

    /// Short status phrase for a backend, shown under its name in the popover.
    private func modelStateText(_ b: BackendID) -> String {
        let loaded = model.loadedBackend == b
        switch model.downloads.state(for: b) {
        case .ready where loaded: return "loaded"
        case .ready: return "not loaded"
        case .downloading(let f): return "downloading \(Int(f * 100))%"
        case .notDownloaded: return "not downloaded"
        case .failed: return "failed"
        }
    }

    /// One status-dot color used everywhere (chip + popover rows + API chip):
    /// green = loaded/active, dim = on disk not loaded, else the download state.
    private func statusDot(for b: BackendID) -> Color {
        let loaded = model.loadedBackend == b
        switch model.downloads.state(for: b) {
        case .ready where loaded: return .green
        case .ready: return Brand.fgFaint
        case .downloading: return .yellow
        case .notDownloaded: return .orange
        case .failed: return .red
        }
    }

    /// 7pt status dot — the single source of truth for every status dot.
    private func dot(_ color: Color) -> some View {
        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
    }

    /// API server chip: green dot + full loopback address when running, dim dot
    /// + "API off" when not. No custom pill — the OS toolbar capsule is the
    /// chrome. Clicking opens the API Server settings tab.
    @ViewBuilder
    private var apiIndicatorLabel: some View {
        let on = model.serverEnabled
        HStack(spacing: 5) {
            dot(on ? .green : Brand.fgFaint)
            Text(verbatim: on ? "127.0.0.1:\(model.serverPort)" : "API off")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.fgDim)
                .lineLimit(1)
                .fixedSize()
        }
        // Internal padding so the dot sits inboard of the OS capsule's rounded
        // edge (otherwise it hugs the curve and reads as bleeding over).
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
    }

    private var apiIndicatorHelp: String {
        model.serverEnabled
            ? "API server at http://127.0.0.1:\(model.serverPort) — open settings"
            : "API server off — open settings to enable"
    }

    /// The toolbar chip: status dot + current backend name + chevron. No custom
    /// pill — the OS toolbar capsule is the chrome.
    @ViewBuilder
    private var modelStatusChip: some View {
        HStack(spacing: 5) {
            dot(statusDot(for: model.backend))
            Text(model.backend.rawValue)
            if model.modelOpInFlight { ProgressView().controlSize(.mini) }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Brand.fgFaint)
        }
        .font(.caption)
        .foregroundStyle(Brand.fgDim)
        .lineLimit(1)
        // Internal padding so the dot sits inboard of the OS capsule's rounded
        // edge (otherwise it hugs the curve and reads as bleeding over).
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        // Make the WHOLE chip tappable — without this the Button only registers on
        // the opaque name text, so clicking the chevron/spacing did nothing.
        .contentShape(Rectangle())
    }

    /// Load/Unload for the Foundry's qwen3-design — residency only (never sets the
    /// Studio backend), so it stays Creation-only while still being manageable here.
    @ViewBuilder
    private var foundryLoadButton: some View {
        if model.loadedBackend == .qwenDesign {
            Button("Unload") { Task { await model.unloadModel() }; modelPickerOpen = false }
                .font(.caption).disabled(model.isGenerating || model.modelOpInFlight)
        } else {
            switch model.downloads.state(for: .qwenDesign) {
            case .ready:
                Button("Load") { Task { await model.loadModel(.qwenDesign) }; modelPickerOpen = false }
                    .font(.caption).disabled(model.modelOpInFlight)
            case .notDownloaded, .failed:
                Button("Download") { model.downloads.download(.qwenDesign) }.font(.caption)
            case .downloading:
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Popover contents for the model chooser: one row per backend (dot + name +
    /// status + checkmark when loaded), then Unload + memory. Selecting a ready
    /// model loads it immediately.
    @ViewBuilder
    private var modelPickerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pickerBackends, id: \.self) { b in
                let loaded = model.loadedBackend == b
                let ramOK = model.hasSufficientRAM(for: b)
                Button {
                    model.backend = b
                    if model.downloads.state(for: b) == .ready {
                        Task { await model.loadModel(b) }
                    }
                    modelPickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        dot(statusDot(for: b))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(modelDisplayName(b)).foregroundStyle(Brand.fg)
                            Text(modelStateText(b))
                                .font(.caption2).foregroundStyle(Brand.fgDim)
                        }
                        Spacer(minLength: 12)
                        if loaded {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(model.backend == b ? Color.white.opacity(0.06) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.modelOpInFlight || !ramOK)
                .help(ramOK ? "" : "This Mac doesn't have enough RAM for \(modelDisplayName(b)) — \(model.ramRequirementLabel(minRAMBytes: b.spec.minRAMBytes)).")
            }
            // Voice Foundry model — residency only. It's Creation-only, so this row
            // loads/unloads qwen3-design WITHOUT making it the Studio speak-backend.
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
            HStack(spacing: 8) {
                dot(statusDot(for: .qwenDesign))
                VStack(alignment: .leading, spacing: 1) {
                    Text("qwen3-design").foregroundStyle(Brand.fg)
                    Text("Create Voice · " + modelStateText(.qwenDesign))
                        .font(.caption2).foregroundStyle(Brand.fgDim)
                }
                Spacer(minLength: 12)
                foundryLoadButton
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
            if let loaded = model.loadedBackend {
                Button {
                    Task { await model.unloadModel() }
                    modelPickerOpen = false
                } label: {
                    Text("Unload \(loaded.rawValue)")
                        .foregroundStyle(Brand.fgDim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isGenerating || model.modelOpInFlight)
            }
            Text(String(format: "App memory: %.2f GB", model.memGB))
                .font(.caption2).foregroundStyle(Brand.fgFaint)
                .padding(.horizontal, 8).padding(.top, 2)
        }
        .padding(8)
        .frame(width: 260)
        .background(Brand.ink2)
    }
}

/// Resident-model + app-RAM chip, as its OWN View so it re-renders reliably when
/// `loadedBackend`/`memGB` change — toolbar content built from a parent's computed
/// property often won't observe @Observable changes. Shows whatever backend is
/// actually loaded (Foundry's qwen3-design, a bake's fish/chatterbox, …); click unloads.
struct RAMChip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        // Pure indicator — NOT a button. Load/unload lives in the model picker
        // popover (the "regular menu"); an accidental click here must never evict a
        // model. Shows the resident model + app RAM at a glance.
        HStack(spacing: 5) {
            Image(systemName: "memorychip").font(.system(size: 10)).foregroundStyle(Brand.fgFaint)
            if let loaded = model.loadedBackend {
                Text(loaded.rawValue).font(.caption).foregroundStyle(Brand.fgDim)
                    .lineLimit(1).fixedSize()
            }
            Text(String(format: "%.1f GB", model.memGB))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Brand.fgDim)
        }
        .padding(.horizontal, 9).padding(.vertical, 2)
        .help(model.loadedBackend != nil
              ? "\(model.loadedBackend!.rawValue) resident · "
                + String(format: "%.2f GB", model.memGB) + " app memory — load/unload in the model picker"
              : String(format: "%.2f GB", model.memGB) + " app memory · no model resident")
        .accessibilityIdentifier("ram-chip")
    }
}

/// Toolbar popover: residency + memory for every backend, mirroring the web
/// studio's "MODELS — one resident at a time" strip.
struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    private let backends: [BackendID] =
        [.qwen06B, .qwen17B, .qwenDesign, .qwenCustom, .chatterboxTurbo, .fishS2Pro]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models — one resident at a time")
                .font(.headline)
            ForEach(backends, id: \.self) { row($0) }
            Divider()
            HStack {
                Text("App memory").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f GB", model.memGB))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.refreshEngineStatus() }
    }

    @ViewBuilder
    private func row(_ backend: BackendID) -> some View {
        let downloadState = model.downloads.state(for: backend)
        let isLoaded = model.loadedBackend == backend
        HStack(spacing: 8) {
            Circle()
                .fill(isLoaded ? .green
                      : downloadState == .ready ? Brand.fgFaint : .orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(backend.rawValue)
                Text(caption(downloadState, isLoaded: isLoaded))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            switch downloadState {
            case .ready where isLoaded:
                Button("Unload") { Task { await model.unloadModel() } }
                    .disabled(model.isGenerating || model.modelOpInFlight)
                    .accessibilityIdentifier("unload-\(backend.rawValue)")
            case .ready:
                Button("Load") { Task { await model.loadModel(backend) } }
                    .disabled(model.modelOpInFlight)
                    .accessibilityIdentifier("load-\(backend.rawValue)")
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 70)
            case .notDownloaded, .failed:
                SettingsLink { Text("Settings…").font(.caption) }
            }
            if model.loadingBackend == backend {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func caption(_ state: ModelDownloadManager.State,
                         isLoaded: Bool) -> String {
        switch state {
        case .ready: isLoaded ? "resident in memory" : "on disk, not loaded"
        case .downloading: "downloading"
        case .notDownloaded: "not downloaded"
        case .failed(let message): message
        }
    }
}

/// Offered when Generate hits a model that isn't downloaded yet. Confirming
/// starts a background download (progress shows in the toolbar) and generates
/// automatically once the model is ready.
struct DownloadPromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let backend: BackendID

    private var sizeText: String {
        ByteCountFormatter.string(
            fromByteCount: model.downloads.approxBytes(for: backend), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download “\(backend.rawValue)”?").font(.title3.bold())
            Text("This model isn’t on your Mac yet (about \(sizeText)). It’ll download in "
                 + "the background — you’ll see progress in the toolbar — and generate "
                 + "automatically once it’s ready.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not Now") { model.cancelDownloadPrompt(); dismiss() }
                Button("Download & Generate") {
                    model.confirmDownloadFromPrompt(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirm-download")
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct ConsentSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you clone a voice").font(.title2.bold())
            Text("""
            Gloam Voice Studio clones voices entirely on this Mac — nothing is \
            uploaded. Only clone voices you have the right to use: your own, or \
            a speaker who has given you permission. Exported audio is tagged as \
            generated.
            """)
            HStack {
                Spacer()
                Button("I Understand") { model.didAcceptCloneConsent = true }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("consent-accept")
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
