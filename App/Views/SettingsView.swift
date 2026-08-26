import EngineKit
import SpeechKit
import StudioKit
import SwiftUI

/// Stable tab identifiers so other UI (e.g. the toolbar API chip) can deep-link
/// to a specific Settings tab via the shared "settingsTab" AppStorage key.
enum SettingsTab: String {
    case backends, speech, api, console, storage, about
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
            ConsoleSettings().tabItem { Label("Console", systemImage: "terminal") }
                .tag(SettingsTab.console.rawValue)
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
        [.qwen06B, .qwen17B, .qwenDesign, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox,
         .kokoro, .supertonic, .luxTTS, .pocketTTS]

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Generate with", selection: $model.backend) {
                ForEach(backends, id: \.self) { backend in
                    Text(model.hasSufficientRAM(for: backend)
                         ? backend.rawValue
                         : "\(backend.rawValue) (\(model.ramRequirementLabel(minRAMBytes: backend.spec.minRAMBytes)))")
                        .tag(backend)
                        .disabled(!model.hasSufficientRAM(for: backend))
                }
            }
            Section("Models") {
                ForEach(backends, id: \.self) { backend in
                    backendRow(backend)
                }
                Toggle("Keep models loaded under memory pressure", isOn: $model.keepModelsResident)
                    .help("Stay resident through memory-pressure warnings so chat and "
                          + "voice replies never cold-start; models are still released "
                          + "when pressure turns critical. Turn off to free memory eagerly.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(
            get: { model.licensePromptBackend != nil },
            set: { if !$0 { model.cancelLicensePrompt() } })) {
            LicenseSheet()
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
            if !model.hasSufficientRAM(for: backend) {
                Text(model.ramRequirementLabel(minRAMBytes: backend.spec.minRAMBytes).capitalized)
                    .foregroundStyle(.red)
                    .help("This Mac's RAM is below what \(backend.rawValue) needs to run safely.")
                if state != .notDownloaded {
                    Button("Delete") { model.downloads.delete(backend) }
                        .help("Delete this model from disk")
                }
            } else {
                switch state {
                case .notDownloaded:
                    if backend.spec.needsLicenseAck && !model.didAck(backend) {
                        Button("Review License…") { model.licensePromptBackend = backend }
                            .help("Review this model's license before downloading")
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
                    if backend.spec.needsLicenseAck && !model.didAck(backend) {
                        Text("Needs license").foregroundStyle(.orange)
                        Button("Review License…") { model.licensePromptBackend = backend }
                            .help("Acknowledge this model's license to enable generation")
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
    }

    private func sizeLabel(_ backend: BackendID) -> String {
        let bytes = model.downloads.approxBytes(for: backend)
        let license: String = if backend.spec.needsLicenseAck {
            backend == .supertonic
                ? " · Open RAIL-M use restrictions"
                : " · research/personal license"
        } else { "" }
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            + license
    }
}

/// License-acknowledgement sheet for whichever backend is pending in
/// `licensePromptBackend` — Fish shows its research/personal-use notice,
/// SuperTonic its Open RAIL-M use restrictions (via `licenseNotice(for:)`).
struct LicenseSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let backend = model.licensePromptBackend ?? model.backend
        VStack(alignment: .leading, spacing: 14) {
            Text(backend == .supertonic
                 ? "SuperTonic — BigScience Open RAIL-M License"
                 : "Fish Audio Research License")
                .font(.title3.bold())
            Text(licenseNotice(for: backend))
            Text("The weights are downloaded from HuggingFace under your own acceptance; the app never redistributes them.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelLicensePrompt() }
                Button("I Agree to the Use Restrictions") { model.confirmLicensePrompt() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct ServerSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("docsPage") private var docsPage = DocsWindow.Page.guide.rawValue

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Server") {
                Toggle("Enable local API server", isOn: $model.serverEnabled)
                    .accessibilityIdentifier("server-toggle")
                // An obvious, bordered box (the borderless form field read as
                // a static label), with the applied address echoed below — the
                // URL updating IS the save confirmation.
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $model.serverPort,
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .labelsHidden()
                        .help("Press Return to apply — the server rebinds and the "
                              + "address below updates")
                        .onChange(of: model.serverPort) {
                            let clamped = min(max(model.serverPort, 1024), 65_535)
                            if clamped != model.serverPort { model.serverPort = clamped }
                        }
                }
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill").font(.system(size: 7))
                        .foregroundStyle(model.serverEnabled ? Color.green : Color.secondary)
                    Text(model.serverEnabled
                         ? "Serving at http://127.0.0.1:\(model.serverPort)"
                           + (model.serverLANEnabled ? " — and to this network" : "")
                         : "Server off")
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.identity)
                }
                .accessibilityIdentifier("server-status-line")
                Toggle("Allow other devices on this network", isOn: $model.serverLANEnabled)
                    .accessibilityIdentifier("server-lan-toggle")
                if model.serverLANEnabled {
                    Text("⚠️ Anyone on this network with this token can use your voices, "
                         + "the chat model, and the microphone listen tool. Reachable at "
                         + "http://\(ProcessInfo.processInfo.hostName):\(model.serverPort)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack {
                        Text(verbatim: model.serverAuthToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("server-auth-token")
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.serverAuthToken, forType: .string)
                        }
                        .accessibilityIdentifier("copy-server-auth-token")
                        .help("Copy the bearer token")
                    }
                    Text("Other devices must send this token as a Bearer authorization header.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                // Live settings — not disabled while the server runs, unlike
                // Port: the router reads them fresh on every request, so
                // flipping these applies to the next one with no restart.
                Picker("Default model", selection: $model.serverDefaultModel) {
                    Text("Follow Studio engine (\(model.backend.rawValue))").tag("")
                    ForEach(serverModelChoices, id: \.rawValue) { backend in
                        Text(model.hasSufficientRAM(for: backend)
                             ? backend.rawValue
                             : "\(backend.rawValue) (\(model.ramRequirementLabel(minRAMBytes: backend.spec.minRAMBytes)))")
                            .tag(backend.rawValue)
                            .disabled(!model.hasSufficientRAM(for: backend))
                    }
                }
                .accessibilityIdentifier("server-default-model-picker")
                Picker("Default voice", selection: $model.serverDefaultVoice) {
                    Text("Backend voice (no reference)").tag("")
                    ForEach(defaultVoiceLibrary, id: \.slug) { voice in
                        Text(voice.name).tag(voice.slug)
                    }
                }
                .accessibilityIdentifier("server-default-voice-picker")
                Text("Answer API requests that don't name a model or voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chat models (LLM)") {
                Picker("Default chat model", selection: $model.serverDefaultLLM) {
                    Text("Follow Chat tab (\(model.chatLLM.rawValue))").tag("")
                    ForEach(LLMBackendID.allCases, id: \.rawValue) { llm in
                        Text(model.hasSufficientRAM(for: llm)
                             ? llm.rawValue
                             : "\(llm.rawValue) (\(model.ramRequirementLabel(minRAMBytes: llm.minRAMBytes)))")
                            .tag(llm.rawValue)
                            .disabled(!model.hasSufficientRAM(for: llm))
                    }
                }
                .accessibilityIdentifier("server-default-llm-picker")
                Text("Answers /v1/chat/completions requests that don't name a model. Requests can also name any downloaded model directly.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(LLMBackendID.allCases, id: \.self) { llm in
                    llmRow(llm)
                }
            }
            Section("MCP (agents)") {
                Text("An MCP server is mounted at /mcp whenever the API server is on — "
                     + "Claude Code, Cursor, and other MCP agents can browse your voices, "
                     + "speak in them, and transcribe audio.")
                    .font(.caption).foregroundStyle(.secondary)
                let addCommand = "claude mcp add --transport http gloam "
                    + "http://127.0.0.1:\(model.serverPort)/mcp"
                HStack {
                    Text(verbatim: addCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(addCommand, forType: .string)
                    }
                    .accessibilityIdentifier("copy-mcp-command")
                    .help("Copy the Claude Code connect command")
                }
                Button("MCP docs — tools & other clients") {
                    docsPage = DocsWindow.Page.mcp.rawValue
                    openWindow(id: "docs")
                }
                .buttonStyle(.link).font(.caption)
            }
            Section {
                Text(model.serverLANEnabled
                     ? "Bound to all interfaces (0.0.0.0) — OpenAI-compatible. Try:"
                     : "Loopback only (127.0.0.1) — OpenAI-compatible. Try:")
                Text(verbatim: "curl -s http://127.0.0.1:\(model.serverPort)/health")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.downloads.refresh() }
        .task { await model.refreshEngineStatus() }
    }

    /// Download/loaded state row for one chat LLM — mirrors the Backends tab's
    /// model rows so the API-server tab is a complete picture of what
    /// /v1/chat/completions can serve.
    @ViewBuilder
    private func llmRow(_ llm: LLMBackendID) -> some View {
        let state = model.downloads.state(for: llm)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(llm.rawValue)
                Text("≈ " + ByteCountFormatter.string(fromByteCount: llm.approxBytes,
                                                      countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.hasSufficientRAM(for: llm) {
                Text(model.ramRequirementLabel(minRAMBytes: llm.minRAMBytes).capitalized)
                    .foregroundStyle(.red)
                    .help("This Mac's RAM is below what \(llm.rawValue) needs to run safely.")
                if state != .notDownloaded {
                    Button("Delete") { model.downloads.delete(llm) }
                        .help("Delete this model from disk")
                }
            } else {
                switch state {
                case .notDownloaded:
                    Button("Download") { model.downloads.download(llm) }
                        .help("Download this model to your Mac")
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.downloads.cancelDownload(llm) }
                        .help("Cancel the download")
                case .ready:
                    if model.loadedLLM == llm {
                        Text("Loaded").foregroundStyle(.green)
                            .help("Resident in memory — answering requests with no load delay")
                        Button("Unload") { Task { await model.unloadChatLLM() } }
                            .help("Release this model from memory")
                    } else {
                        Text("On disk").foregroundStyle(.secondary)
                            .help("Downloaded — loads into memory on the first request")
                    }
                    Button("Delete") { model.downloads.delete(llm) }
                        .help("Delete this model from disk")
                case .failed(let message):
                    Text(message).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 200)
                    Button("Retry") { model.downloads.download(llm) }
                        .help("Retry the download")
                }
            }
        }
    }

    /// Same curated order as `ModelSettings.backends`. qwen3-design is offered
    /// deliberately even though the Studio picker redirects away from it — an
    /// API caller that always sends `instruct` may want the design model.
    private let serverModelChoices: [BackendID] =
        [.qwen06B, .qwen17B, .qwenDesign, .qwenCustom, .chatterboxTurbo, .fishS2Pro, .chatterbox,
         .luxTTS]

    /// Voice library for the Default voice picker — re-reads on library
    /// mutations elsewhere in the app (bumps `voicesVersion`), same guard
    /// `VoiceSidebarView.voiceList` uses.
    private var defaultVoiceLibrary: [VoiceMeta] {
        _ = model.voicesVersion
        return model.voices.list()
    }

}

/// API request console — its own tab so the API Server form stays a settings
/// form and the log gets room to breathe.
struct ConsoleSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.serverEnabled
                     ? "Requests to http://127.0.0.1:\(model.serverPort)"
                     : "API server is off — enable it in the API Server tab.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.apiLog.clear() }
                    .disabled(model.apiLog.entries.isEmpty)
            }
            if model.apiLog.entries.isEmpty {
                Spacer()
                Text("No requests yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
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
            }
        }
        .padding(12)
        .frame(minHeight: 320)
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
        @Bindable var model = model
        Form {
            ForEach(sizes, id: \.0) { name, bytes in
                LabeledContent(name,
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Button("Recalculate") { recalc() }
            Section("Voice candidates") {
                Stepper("Keep last \(model.foundryCandidateRetentionCap) candidates",
                        value: $model.foundryCandidateRetentionCap, in: 5...500, step: 5)
                    .accessibilityIdentifier("foundry-retention-cap")
                Text("Older qwen3-design candidates beyond this count are pruned automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chat audio") {
                Stepper("Keep last \(model.chatAudioRetentionCap) takes",
                        value: $model.chatAudioRetentionCap, in: 5...500, step: 5)
                    .accessibilityIdentifier("chat-audio-retention-cap")
                Text("Older chat reply takes beyond this count are pruned automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { recalc() }
    }

    private func recalc() {
        sizes = [
            ("Voices", StoragePaths.directorySize(StoragePaths.voices)),
            ("History", StoragePaths.directorySize(StoragePaths.history)),
            ("Voice Candidates", StoragePaths.directorySize(StoragePaths.foundryCandidates)),
            ("Chat Audio", StoragePaths.directorySize(StoragePaths.chatAudio)),
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
