import EngineKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

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

        // 2. Model status chip
        modelStatusChip

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

    @ViewBuilder
    private var modelStatusChip: some View {
        let state = model.downloads.state(for: model.backend)
        HStack(spacing: 4) {
            switch state {
            case .ready:
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(Brand.fgDim)

            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(Brand.fgDim)

            case .notDownloaded:
                Circle().fill(.orange).frame(width: 6, height: 6)
                if #available(macOS 14, *) {
                    SettingsLink {
                        Text("Download in Settings…")
                            .font(.caption)
                            .foregroundStyle(Brand.fgDim)
                    }
                } else {
                    Button("Download in Settings…") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.fgDim)
                }

            case .failed:
                Circle().fill(.red).frame(width: 6, height: 6)
                if #available(macOS 14, *) {
                    SettingsLink {
                        Text("Failed — Settings")
                            .font(.caption)
                            .foregroundStyle(Brand.fgDim)
                    }
                } else {
                    Button("Failed — Settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.fgDim)
                }
            }
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
