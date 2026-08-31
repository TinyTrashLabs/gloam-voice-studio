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
    @State private var llmPickerOpen = false
    @AppStorage("studioSection") private var sectionRaw = StudioSection.studio.rawValue
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false

    private var section: StudioSection {
        StudioSection(rawValue: sectionRaw) ?? .studio
    }

    var body: some View {
        @Bindable var model = model
        // Standard split view: native sidebar material, collapse button, and a
        // user-draggable divider replace the old fixed-width hand-rolled HStack.
        NavigationSplitView {
            VoiceSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
                // Tint only — the split view supplies the sidebar's own glass.
                .background(Brand.ink2.opacity(0.45))
        } detail: {
            ZStack(alignment: .trailing) {
                Group {
                    switch section {
                    case .studio: StudioView()
                    case .createVoice: CreateVoiceView()
                    case .chat: ChatView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.ink.opacity(0.82))
                .background(WindowGlass())
                if historyVisible {
                    // Floating drawer: overlays the bench (no squeeze), elevated
                    // surface + leading shadow so it reads as sliding on top.
                    HistoryView()
                        .frame(width: 340)
                        .background(Brand.ink2.opacity(0.6))
                        .background(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.4), radius: 14, x: -8, y: 0)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: historyVisible)
        }
        .toolbar { mainToolbar }
        .sheet(isPresented: .constant(!model.didAcceptCloneConsent)) {
            ConsentSheet()
        }
        // First-launch onboarding: fires once, after consent, only when NO
        // engine is on disk yet — the app otherwise assumes its author is
        // driving. Never in UI tests (fake providers, no downloads).
        .sheet(isPresented: Binding(
            get: {
                model.didAcceptCloneConsent && !didShowOnboarding && !UITestMode.isActive
                    && BackendID.allCases.allSatisfy {
                        model.downloads.state(for: $0) == .notDownloaded
                    }
            },
            set: { if !$0 { didShowOnboarding = true } })) {
            OnboardingSheet(dismiss: { didShowOnboarding = true })
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
        // Section switcher — the standard toolbar-level scope control (was a
        // custom segmented picker buried in the sidebar header). ⌘1/2/3 via
        // the View menu (SectionCommands).
        ToolbarItem(placement: .navigation) {
            Picker("Section", selection: Binding(
                get: { section },
                set: { newSection in
                    sectionRaw = newSection.rawValue
                    // Tapping "Create Voice" itself means a fresh create — leave
                    // any in-progress Edit only when opened from a voice.
                    if newSection == .createVoice { model.editingVoiceSlug = nil }
                })) {
                Text("Studio").tag(StudioSection.studio)
                Text("Create Voice").tag(StudioSection.createVoice)
                Text("Chat").tag(StudioSection.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("studio-section-picker")
            .help("Switch between the studio, the voice foundry, and voice chat (⌘1/⌘2/⌘3)")
        }

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

        // 2a. Chat-LLM chooser — the LLM is served on the same OpenAI-compatible
        //     server as the voice engines, so it gets the same first-class picker:
        //     see what's selected/resident, switch, load/unload. Mirrors the
        //     voice-model chip (Button + popover for identical chrome).
        ToolbarItem(placement: .automatic) {
            Button { llmPickerOpen.toggle() } label: { llmStatusChip }
                .buttonStyle(.plain)
                .accessibilityIdentifier("llm-picker")
                .help("Pick chat LLM · load/unload")
                .popover(isPresented: $llmPickerOpen, arrowEdge: .bottom) { llmPickerList }
        }

        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        // 3. API server indicator — clicking selects the API Server tab first
        //    (via shared AppStorage) so Settings opens there, not on whatever
        //    tab was last viewed. Hidden until the server has ever been turned
        //    on — a user who never touches it shouldn't see a permanent
        //    "API off" chip for a developer feature they don't use.
        if model.serverEverEnabled {
            ToolbarItem(placement: .automatic) {
                SettingsLink { apiIndicatorLabel }
                    .buttonStyle(.plain)
                    .help(apiIndicatorHelp)
                    .accessibilityIdentifier("api-indicator")
                    .simultaneousGesture(TapGesture().onEnded {
                        UserDefaults.standard.set(SettingsTab.api.rawValue, forKey: "settingsTab")
                    })
            }
        }

        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        // 4+5. History toggle + settings gear share one pill (icon cluster).
        ToolbarItemGroup(placement: .automatic) {
            // Label (not bare Image) so the overflow menu (») at narrow widths
            // shows a readable title next to the icon, not an unlabeled glyph.
            Button {
                historyVisible.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(historyVisible ? Brand.accent : Brand.fgDim)
            }
            .accessibilityIdentifier("open-history")
            .help("Toggle the history panel (⌘Y)")
            .keyboardShortcut("y", modifiers: .command)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
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
         .supertonic, .luxTTS, .pocketTTS]
    }

    private func modelDisplayName(_ b: BackendID) -> String {
        switch b {
        case .qwen06B: "qwen3-0.6b · clone a voice"
        case .qwen17B: "qwen3-1.7b · clone a voice"
        case .qwenDesign: "qwen3-design · design from text"
        case .qwenCustom: "qwen3-custom · direct a preset voice"
        case .luxTTS: "lux-tts · clone a voice"
        case .pocketTTS: "pocket-tts · clone a voice"
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
            .accessibilityHidden(true)
    }

    /// API server chip: green dot + full loopback address when running, dim dot
    /// + "API off" when not. No custom pill — the OS toolbar capsule is the
    /// chrome. Clicking opens the API Server settings tab.
    @ViewBuilder
    private var apiIndicatorLabel: some View {
        let on = model.serverEnabled && model.serverError == nil
        HStack(spacing: 5) {
            dot(model.serverError != nil ? .red : on ? .green : Brand.fgFaint)
            Text(verbatim: model.serverError != nil ? "API error"
                 : on ? "127.0.0.1:\(model.serverPort)" : "API off")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.fgDim)
                .lineLimit(1)
                .fixedSize()
        }
        // Internal padding so the dot sits inboard of the OS capsule's rounded
        // edge (otherwise it hugs the curve and reads as bleeding over).
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.serverError != nil ? "API server error"
            : on ? "API server running at 127.0.0.1 port \(model.serverPort)" : "API server off")
    }

    private var apiIndicatorHelp: String {
        if let serverError = model.serverError {
            return "Couldn't start on port \(model.serverPort): \(serverError). Open settings"
        }
        return model.serverEnabled
            ? "API server at http://127.0.0.1:\(model.serverPort) — OpenAI-compatible, "
              + "MCP for agents at /mcp. Open settings"
            : "API server off — open settings to enable (OpenAI-compatible API + MCP)"
    }

    /// The toolbar chip: status dot + current backend name + chevron. No custom
    /// pill — the OS toolbar capsule is the chrome.
    @ViewBuilder
    private var modelStatusChip: some View {
        HStack(spacing: 5) {
            // Pairs with the LLM chip's `brain`: at a glance, which chip is the
            // voice and which is the language model.
            Image(systemName: "waveform").font(.system(size: 10))
                .foregroundStyle(Brand.fgFaint)
            dot(statusDot(for: model.backend))
            Text(model.backend.rawValue)
            // What THIS model costs, measured across its own load -- on the
            // control you click to change it, so it's always in view.
            if let gb = model.measuredGB[model.backend.rawValue] {
                Text(String(format: "· %.1f GB", gb))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgFaint)
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.backend.rawValue) model, \(modelStateText(model.backend))"
            + (model.measuredGB[model.backend.rawValue]
                .map { String(format: ", using %.1f gigabytes", $0) } ?? ""))
    }

    /// Status-dot color for a chat LLM, same scheme as the voice backends.
    private func llmStatusDot(for llm: LLMBackendID) -> Color {
        switch model.downloads.state(for: llm) {
        case .ready where model.loadedLLM == llm: return .green
        case .ready: return Brand.fgFaint
        case .downloading: return .yellow
        case .notDownloaded: return .orange
        case .failed: return .red
        }
    }

    private func llmStateText(_ llm: LLMBackendID) -> String {
        switch model.downloads.state(for: llm) {
        case .ready where model.loadedLLM == llm: return "loaded"
        case .ready: return "not loaded"
        case .downloading(let f): return "downloading \(Int(f * 100))%"
        case .notDownloaded: return "not downloaded"
        case .failed: return "failed"
        }
    }

    /// The LLM chip: brain glyph + status dot + current chat LLM + chevron.
    @ViewBuilder
    private var llmStatusChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain").font(.system(size: 10)).foregroundStyle(Brand.fgFaint)
            dot(llmStatusDot(for: model.chatLLM))
            Text(model.chatLLM.rawValue)
            if let gb = model.measuredGB[model.chatLLM.rawValue] {
                Text(String(format: "· %.1f GB", gb))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgFaint)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Brand.fgFaint)
        }
        .font(.caption)
        .foregroundStyle(Brand.fgDim)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.chatLLM.rawValue) chat model, \(llmStateText(model.chatLLM))"
            + (model.measuredGB[model.chatLLM.rawValue]
                .map { String(format: ", using %.1f gigabytes", $0) } ?? ""))
    }

    /// Popover for the LLM chooser: one row per chat LLM (dot + name + state +
    /// checkmark on the selection), a Download button where the model isn't on
    /// disk yet (selection alone never starts a multi-GB fetch), then Unload.
    @ViewBuilder
    private var llmPickerList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(LLMBackendID.allCases, id: \.self) { llm in
                let ramOK = model.hasSufficientRAM(for: llm)
                let state = model.downloads.state(for: llm)
                Button {
                    // Load now rather than deferring to the first reply: until
                    // it's resident there is no dot to go green and no measured
                    // cost to show.
                    if state == .ready {
                        Task { await model.loadChatLLM(llm) }
                    } else {
                        model.chatLLM = llm
                    }
                    llmPickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        dot(llmStatusDot(for: llm))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(llm.rawValue).foregroundStyle(Brand.fg)
                            Text(llmStateText(llm) + " · ≈ "
                                 + ByteCountFormatter.string(fromByteCount: llm.approxBytes,
                                                             countStyle: .file))
                                .font(.caption2).foregroundStyle(Brand.fgDim)
                        }
                        Spacer(minLength: 12)
                        if let gb = model.measuredGB[llm.rawValue], model.loadedLLM == llm {
                            Text(String(format: "%.1f GB", gb))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Brand.fgDim)
                        }
                        if state == .notDownloaded, ramOK {
                            Button("Download") { model.downloads.download(llm) }
                                .font(.caption)
                        }
                        if model.chatLLM == llm {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(model.chatLLM == llm ? Color.white.opacity(0.06) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ramOK)
                .help(ramOK ? "" : "This Mac doesn't have enough RAM for \(llm.rawValue) — \(model.ramRequirementLabel(minRAMBytes: llm.minRAMBytes)).")
            }
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
            if let loaded = model.loadedLLM {
                Button {
                    Task { await model.unloadChatLLM() }
                    llmPickerOpen = false
                } label: {
                    Text("Unload \(loaded.rawValue)")
                        .foregroundStyle(Brand.fgDim)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("No chat model loaded — loads on the first reply")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
                    .padding(.horizontal, 8).padding(.vertical, 2)
            }
        }
        .padding(8)
        .frame(width: 280)
        .background(Brand.ink2.opacity(0.5))
        .task { await model.refreshEngineStatus() }
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
            // Without this the failure mode is silent and alarming: every model
            // reads "not downloaded" on a Mac that has all of them.
            if model.usingFallbackStore {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text("Shared storage unavailable — this build can't reach the "
                         + "app group, so your installed models aren't visible. "
                         + "They haven't been deleted.")
                        .font(.caption2).foregroundStyle(Brand.fgDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 4)
            }
            ForEach(pickerBackends, id: \.self) { b in
                let loaded = model.loadedBackend == b
                let ramOK = model.hasSufficientRAM(for: b)
                Button {
                    // Selection follows residency (see refreshEngineStatus), so
                    // don't move it for a model that can't load yet -- ask first.
                    // Silently kicking off a multi-gigabyte download on a click
                    // is not a thing to do without saying so.
                    guard model.downloads.state(for: b) == .ready else { return }
                    model.backend = b
                    Task { await model.loadModel(b) }
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
                        // What this model is actually costing, right now.
                        if loaded, let gb = model.measuredGB[b.rawValue] {
                            Text(String(format: "%.1f GB", gb))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Brand.fgDim)
                        }
                        if model.downloads.state(for: b) == .notDownloaded, ramOK {
                            Button("Download") { model.downloads.download(b) }
                                .font(.caption)
                        }
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
        }
        .padding(8)
        .frame(width: 260)
        // Translucent over the popover's native glass chrome rather than
        // opaque ink — keeps the tint, lets the system material show.
        .background(Brand.ink2.opacity(0.5))
    }
}

/// Toolbar popover: residency + memory for every backend, mirroring the web
/// studio's "MODELS — one resident at a time" strip.
struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    private let backends: [BackendID] =
        [.qwen06B, .qwen17B, .qwenDesign, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .luxTTS]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models — one loaded at a time")
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
                .accessibilityHidden(true)
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
        case .ready: isLoaded ? "loaded in memory" : "on disk, not loaded"
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

/// One-screen welcome for a fresh install: what the app does, plus a starter
/// engine download so the first Generate isn't a dead end.
struct OnboardingSheet: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    private var starterSize: String {
        ByteCountFormatter.string(
            fromByteCount: model.downloads.approxBytes(for: .kokoro), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandLockup()
            Text("Welcome to Gloam Voice Studio").font(.title2.bold())
            Text("""
            Clone, design, and direct voices — entirely on this Mac. To speak, \
            the studio needs a voice model on disk. kokoro (\(starterSize)) is a \
            good starter: it ships 54 ready-to-speak voices, no license to accept \
            and no recording to clone. You can add or switch models any time in \
            Settings → Models.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                Button("Download Starter Model") {
                    model.downloadStarterEngine()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-download")
            }
        }
        .padding(24)
        .frame(width: 480)
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
