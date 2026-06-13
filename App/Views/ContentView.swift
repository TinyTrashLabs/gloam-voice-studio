import EngineKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var modelsPopover = false
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

        // 1. Backend picker
        Picker("Backend", selection: $model.backend) {
            ForEach([BackendID.chatterbox, .chatterboxTurbo, .fishS2Pro], id: \.self) { b in
                Text(b.rawValue).tag(b)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("backend-picker")
        .task { model.downloads.refresh() }

        // 2. Model status → models popover (load/unload + memory)
        Button {
            Task { await model.refreshEngineStatus() }
            modelsPopover = true
        } label: {
            modelStatusChip
        }
        .accessibilityIdentifier("models-button")
        .help("Model residency — load, unload, memory")
        .popover(isPresented: $modelsPopover, arrowEdge: .bottom) {
            ModelManagerView().environment(model)
        }

        // 3. API server indicator (clickable — opens Settings)
        if model.serverEnabled {
            if #available(macOS 14, *) {
                SettingsLink {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("API :\(model.serverPort)")
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
                        Text("API :\(model.serverPort)")
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

    /// Compact one-glance status for the SELECTED backend; details live in
    /// the popover. Kept to a dot + one short word so it can never overflow
    /// the toolbar.
    @ViewBuilder
    private var modelStatusChip: some View {
        let state = model.downloads.state(for: model.backend)
        HStack(spacing: 4) {
            switch state {
            case .ready where model.loadedBackend == model.backend:
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("loaded")
            case .ready:
                Circle().fill(Brand.fgFaint).frame(width: 6, height: 6)
                Text("not loaded")
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("\(Int(fraction * 100))%")
            case .notDownloaded:
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("get")
            case .failed:
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("failed")
            }
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

    private let backends: [BackendID] = [.chatterbox, .chatterboxTurbo, .fishS2Pro]

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
