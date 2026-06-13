import EngineKit
import SpeechKit
import StudioKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            BackendsSettings().tabItem { Label("Backends", systemImage: "cpu") }
            SpeechSettings().tabItem { Label("Speech", systemImage: "waveform.and.mic") }
            ServerSettings().tabItem { Label("API Server", systemImage: "network") }
            StorageSettings().tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct BackendsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var fishSheetShown = false

    private let backends: [BackendID] = [.chatterboxTurbo, .fishS2Pro]

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Generate with", selection: $model.backend) {
                ForEach(backends, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Section("Models") {
                ForEach(backends, id: \.self) { backend in
                    backendRow(backend)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $fishSheetShown) { FishLicenseSheet() }
        .onAppear { model.downloads.refresh() }
    }

    @ViewBuilder
    private func backendRow(_ backend: BackendID) -> some View {
        let state = model.downloads.state(for: backend)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.rawValue)
                Text(sizeLabel(backend)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .notDownloaded:
                if backend.spec.needsLicenseAck && !model.didAckFishLicense {
                    Button("Review License…") { fishSheetShown = true }
                        .help("Review the research/personal-use license before downloading")
                } else {
                    Button("Download") { model.downloads.download(backend) }
                        .help("Download this model to your Mac")
                }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.downloads.cancelDownload(backend) }
                    .help("Cancel the download")
            case .ready:
                Text("Ready").foregroundStyle(.green)
                Button("Delete") { model.downloads.delete(backend) }
                    .help("Delete this model from disk")
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 200)
                Button("Retry") { model.downloads.download(backend) }
                    .help("Retry the download")
            }
        }
    }

    private func sizeLabel(_ backend: BackendID) -> String {
        let bytes = ModelDownloadManager.approxBytes[backend] ?? 0
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + (backend.spec.needsLicenseAck ? " · research/personal license" : "")
    }
}

struct FishLicenseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fish Audio Research License").font(.title3.bold())
            Text(fishLicenseNotice)
            Text("The weights are downloaded from HuggingFace under your own acceptance; the app never redistributes them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("I Confirm — Personal Use") {
                    model.didAckFishLicense = true
                    model.downloads.download(.fishS2Pro)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct ServerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Enable local API server", isOn: $model.serverEnabled)
                .accessibilityIdentifier("server-toggle")
            TextField("Port", value: $model.serverPort, format: .number.grouping(.never))
                .disabled(model.serverEnabled)
            Section {
                Text("Loopback only (127.0.0.1) — OpenAI-compatible. Try:")
                Text("curl -s http://127.0.0.1:\(model.serverPort)/health")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var sizes: [(String, Int64)] = []

    var body: some View {
        Form {
            ForEach(sizes, id: \.0) { name, bytes in
                LabeledContent(name,
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Button("Recalculate") { recalc() }
        }
        .formStyle(.grouped)
        .onAppear { recalc() }
    }

    private func recalc() {
        sizes = [
            ("Voices", StoragePaths.directorySize(StoragePaths.voices)),
            ("History", StoragePaths.directorySize(StoragePaths.history)),
            ("Models", StoragePaths.directorySize(StoragePaths.models)),
        ]
    }
}

struct SpeechSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var speech = model.speech
        Form {
            Picker("Transcribe with", selection: $speech.engineChoice) {
                ForEach(SpeechManager.EngineChoice.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .accessibilityIdentifier("speech-engine-picker")
            if speech.engineChoice == .whisper && !speech.whisperReady {
                Text("Whisper model not downloaded — Apple speech will be used until it is.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("Language hint (BCP-47, blank = system)",
                      text: $speech.languageHint)
                .help("e.g. en-US, de-DE — used by both engines")
            Section("Whisper models") {
                ForEach(WhisperModelCatalog.models) { whisperRow($0) }
            }
            Section {
                Text("Both engines run entirely on this Mac — audio never leaves it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.speech.whisperModels.refresh() }
    }

    @ViewBuilder
    private func whisperRow(_ entry: WhisperModelCatalog.Model) -> some View {
        @Bindable var speech = model.speech
        let state = model.speech.whisperModels.state(for: entry.variant)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                Text("≈ " + ByteCountFormatter.string(
                        fromByteCount: entry.approxBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .ready {
                Toggle("Use", isOn: Binding(
                    get: { speech.whisperVariant == entry.variant },
                    set: { if $0 { speech.whisperVariant = entry.variant } }))
                    .toggleStyle(.checkbox)
            }
            switch state {
            case .notDownloaded:
                Button("Download") { model.speech.whisperModels.download(entry.variant) }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.speech.whisperModels.cancelDownload(entry.variant) }
            case .ready:
                Text("Ready").foregroundStyle(.green)
                Button("Delete") { model.speech.whisperModels.delete(entry.variant) }
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 200)
                Button("Retry") { model.speech.whisperModels.download(entry.variant) }
            }
        }
    }
}
