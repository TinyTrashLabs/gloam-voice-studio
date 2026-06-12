import EngineKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var modelsPopover = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VoiceSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                .scrollContentBackground(.hidden)
                .background(Brand.ink2)
        } detail: {
            StudioView()
                .background(Brand.ink)
                .toolbar { mainToolbar }
        }
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

        // 3. API server indicator
        if model.serverEnabled {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("API :\(model.serverPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
            }
        }

        // 4. Settings gear
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
                Text("ready")
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
            if model.modelOpInFlight && !isLoaded && downloadState == .ready {
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
