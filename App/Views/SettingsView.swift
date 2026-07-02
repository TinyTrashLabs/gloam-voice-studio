import EngineKit
import SpeechKit
import StudioKit
import SwiftUI

/// Stable tab identifiers so other UI (e.g. the toolbar API chip) can deep-link
/// to a specific Settings tab via the shared "settingsTab" AppStorage key.
enum SettingsTab: String {
    case backends, speech, api, storage, about
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.backends.rawValue

    var body: some View {
        TabView(selection: $tab) {
            BackendsSettings().tabItem { Label("Backends", systemImage: "cpu") }
                .tag(SettingsTab.backends.rawValue)
            SpeechSettings().tabItem { Label("Speech", systemImage: "waveform.and.mic") }
                .tag(SettingsTab.speech.rawValue)
            ServerSettings().tabItem { Label("API Server", systemImage: "network") }
                .tag(SettingsTab.api.rawValue)
            StorageSettings().tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage.rawValue)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Gloam Voice Studio processes everything on this Mac. There's no account, no analytics, and no data sent to us.")
                    .font(.callout)
            }
            Section {
                Link("Privacy Policy",
                     destination: URL(string: "https://github.com/TinyTrashLabs/gloam-voice-studio/blob/main/PRIVACY.md")!)
                Link("Support & Issues",
                     destination: URL(string: "https://github.com/TinyTrashLabs/gloam-voice-studio/issues")!)
                Link("Source Code",
                     destination: URL(string: "https://github.com/TinyTrashLabs/gloam-voice-studio")!)
            }
        }
        .formStyle(.grouped)
    }
}

struct BackendsSettings: View {
    @Environment(AppModel.self) private var model

    private let backends: [BackendID] =
        [.qwen06B, .qwen17B, .qwenDesign, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox]

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
        .sheet(isPresented: Binding(
            get: { model.licensePromptBackend != nil },
            set: { if !$0 { model.cancelLicensePrompt() } })) {
            FishLicenseSheet()
        }
        .onAppear { model.downloads.refresh() }
    }

    @ViewBuilder
    private func backendRow(_ backend: BackendID) -> some View {
        let state = model.downloads.state(for: backend)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.rawValue)
                Text(sizeLabel(backend)).font(.caption).foregroundStyle(.secondary)
                if backend.isQwen {
                    Picker("Precision", selection: Binding(
                        get: { model.downloads.quant(for: backend) },
                        set: { model.downloads.setQuant($0, for: backend) })) {
                        ForEach(QwenQuant.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                    .disabled({ if case .downloading = state { true } else { false } }())
                }
            }
            Spacer()
            switch state {
            case .notDownloaded:
                if backend.spec.needsLicenseAck && !model.didAckFishLicense {
                    Button("Review License…") { model.licensePromptBackend = backend }
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
                if backend.spec.needsLicenseAck && !model.didAckFishLicense {
                    Text("Needs license").foregroundStyle(.orange)
                    Button("Review License…") { model.licensePromptBackend = backend }
                        .help("Acknowledge the research/personal-use license to enable generation")
                } else {
                    Text("Ready").foregroundStyle(.green)
                }
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
        let bytes = model.downloads.approxBytes(for: backend)
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + (backend.spec.needsLicenseAck ? " · research/personal license" : "")
    }
}

struct FishLicenseSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fish Audio Research License").font(.title3.bold())
            Text(fishLicenseNotice)
            Text("The weights are downloaded from HuggingFace under your own acceptance; the app never redistributes them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelLicensePrompt() }
                Button("I Confirm — Personal Use") { model.confirmLicensePrompt() }
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
                Text(verbatim: "curl -s http://127.0.0.1:\(model.serverPort)/health")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Request console") {
                if model.apiLog.entries.isEmpty {
                    Text("No requests yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Clear") { model.apiLog.clear() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.apiLog.entries) { e in
                                Text(consoleLine(e))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(e.status >= 400 ? .orange : Brand.fgDim)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func consoleLine(_ e: APILogEntry) -> String {
        let t = e.timestamp.formatted(date: .omitted, time: .standard)
        var parts = ["\(t)  \(e.method) \(e.path) → \(e.status)"]
        if let ms = e.durationMs { parts.append("\(ms)ms") }
        if let m = e.model { parts.append(m) }
        if let v = e.voice { parts.append("voice=\(v)") }
        if let i = e.instruct, !i.isEmpty { parts.append("instruct=\"\(i.prefix(40))\"") }
        if let n = e.note { parts.append("(\(n))") }
        return parts.joined(separator: "  ")
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
