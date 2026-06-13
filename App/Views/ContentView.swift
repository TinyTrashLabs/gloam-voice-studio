import EngineKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var historyVisible = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VoiceSidebarView()
                .frame(width: 248)
                .background(Brand.ink2)
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            StudioView()
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
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            toolbarContent
        }
    }

    @ViewBuilder
    private var toolbarContent: some View {
        @Bindable var model = model

        // 1+2. Merged backend picker + model management in one Menu
        Menu {
            // Pick a model — tapping it selects AND loads it (one resident at a
            // time). Regular `chatterbox` is kept but marked experimental: its T3
            // can fail to emit end-of-speech and repeat the line; turbo supersedes it.
            ForEach([BackendID.fishS2Pro, .chatterboxTurbo, .chatterbox], id: \.self) { b in
                Button {
                    model.backend = b
                    if model.downloads.state(for: b) == .ready {
                        Task { await model.loadModel(b) }
                    }
                } label: {
                    if model.backend == b {
                        Label(modelMenuTitle(b), systemImage: "checkmark")
                    } else {
                        Text(modelMenuTitle(b))
                    }
                }
                .disabled(model.modelOpInFlight)
            }
            Divider()
            if let loaded = model.loadedBackend {
                Button("Unload \(loaded.rawValue)") {
                    Task { await model.unloadModel() }
                }
                .disabled(model.isGenerating || model.modelOpInFlight)
            }
            Text(String(format: "App memory: %.2f GB", model.memGB))
        } label: {
            modelStatusChip
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("backend-picker")
        .help("Pick model · load/unload · memory")
        .task {
            model.downloads.refresh()
            await model.refreshEngineStatus()
        }

        // 3. API server indicator (clickable — opens Settings)
        if model.serverEnabled {
            if #available(macOS 14, *) {
                SettingsLink {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(verbatim: "API :\(model.serverPort)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.fgDim)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.borderless)
                .help("API server running on port \(model.serverPort) — open settings")
                .accessibilityIdentifier("api-indicator")
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(verbatim: "API :\(model.serverPort)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.fgDim)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.borderless)
                .help("API server running on port \(model.serverPort) — open settings")
                .accessibilityIdentifier("api-indicator")
            }
        }

        // 4. History panel toggle
        Button {
            historyVisible.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(historyVisible ? Brand.accent : Color.primary)
        }
        .accessibilityIdentifier("open-history")
        .help("Toggle the history panel (⌘Y)")
        .keyboardShortcut("y", modifiers: .command)

        // 5. Settings gear
        if #available(macOS 14, *) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("open-settings")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("open-settings")
        }
    }

    /// Per-backend menu row title: name (+ "experimental" for regular chatterbox)
    /// and its current state.
    private func modelMenuTitle(_ b: BackendID) -> String {
        let name = b == .chatterbox ? "\(b.rawValue) (experimental)" : b.rawValue
        let loaded = model.loadedBackend == b
        switch model.downloads.state(for: b) {
        case .ready where loaded: return "\(name) — loaded"
        case .ready: return "\(name) — tap to load"
        case .downloading(let f): return "\(name) — \(Int(f * 100))%"
        case .notDownloaded: return "\(name) — get in Settings"
        case .failed: return "\(name) — failed"
        }
    }

    /// Toolbar menu label: a status dot + the CURRENT backend's name, so you can
    /// see at a glance which model is selected and whether it's loaded.
    @ViewBuilder
    private var modelStatusChip: some View {
        let loaded = model.loadedBackend == model.backend
        let dot: Color = {
            switch model.downloads.state(for: model.backend) {
            case .ready where loaded: return .green
            case .ready: return .secondary           // visibly "ready, not loaded"
            case .downloading: return .yellow
            case .notDownloaded: return .orange
            case .failed: return .red
            }
        }()
        HStack(spacing: 4) {
            // Hollow ring when not loaded, solid green when loaded — clear at a glance.
            Circle()
                .fill(loaded ? dot : .clear)
                .overlay(Circle().stroke(dot, lineWidth: loaded ? 0 : 1.5))
                .frame(width: 7, height: 7)
            Text(model.backend.rawValue)
            if model.modelOpInFlight { ProgressView().controlSize(.mini) }
        }
        .font(.caption)
        .foregroundStyle(Brand.fgDim)
        .lineLimit(1)
    }
}

/// Toolbar popover: residency + memory for every backend, mirroring the web
/// studio's "MODELS — one resident at a time" strip.
struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    private let backends: [BackendID] = [.chatterboxTurbo, .fishS2Pro]

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
