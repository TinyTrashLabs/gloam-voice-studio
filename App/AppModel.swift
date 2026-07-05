import EngineKit
import Foundation
import Observation
import StudioKit
import SwiftUI

struct AppGenerationError: Error {
    let message: String
}

/// One generated take, ready to play/export.
struct Variant: Identifiable, Equatable {
    let id = UUID()
    let label: String          // "A" / "B"
    let wavData: Data
    let sampleRate: Int
    let seconds: Double
    let wallSeconds: Double
    var rtf: Double { wallSeconds > 0 ? seconds / wallSeconds : 0 }
}

/// A saved/seeded Direction (instruct) description the user can reuse.
struct DirectionPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

@MainActor @Observable
final class AppModel {
    let voices: VoiceLibrary
    let history: HistoryStore
    let engine: GloamEngine
    let downloads: ModelDownloadManager
    let speech: SpeechManager
    private var server: LocalAPIServer?

    // Persisted settings (raw UserDefaults so @Observable views update via model)
    var backend: BackendID {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "defaultBackend")
            // Surface the license prompt the moment an unacknowledged backend is
            // picked — not just when Generate/Load later hits it as an error.
            if backend.spec.needsLicenseAck && !didAckFishLicense {
                licensePromptBackend = backend
            }
        }
    }
    var serverEnabled = false { didSet { Task { await syncServer() } } }
    /// LLM used by the chat tab (and as the API server's default LLM).
    var chatLLM: LLMBackendID {
        didSet {
            UserDefaults.standard.set(chatLLM.rawValue, forKey: "chatLLM")
            Task { await syncServer() }   // keep the route's default in step
        }
    }
    var chatAutoSpeak: Bool {
        didSet { UserDefaults.standard.set(chatAutoSpeak, forKey: "chatAutoSpeak") }
    }
    var serverPort: Int {
        didSet { UserDefaults.standard.set(serverPort, forKey: "serverPort") }
    }
    var didAcceptCloneConsent: Bool {
        didSet { UserDefaults.standard.set(didAcceptCloneConsent, forKey: "didAcceptCloneConsent") }
    }
    var didAckFishLicense: Bool {
        didSet {
            UserDefaults.standard.set(didAckFishLicense, forKey: "didAckFishLicense")
            if didAckFishLicense {
                let engine = engine
                Task { await engine.acknowledgeLicense(for: .fishS2Pro) }
            }
        }
    }

    // Engine residency (mirrored from the engine actor for the toolbar UI)
    var loadedBackend: BackendID?
    var memGB: Double = 0
    var modelOpInFlight = false
    /// The specific backend currently being loaded, so only its row spins
    /// (modelOpInFlight is global and would otherwise spin every Load button).
    var loadingBackend: BackendID?

    // Studio state
    var selectedVoiceSlug: String?
    var text = ""
    var emotion: Emotion = .neutral
    var speed: Float = 1.0
    var variants: [Variant] = []
    var isGenerating = false
    var generationError: String?
    var voicesVersion = 0   // bump to refresh voice lists after library mutations

    // Manual delivery knobs (bound by the Direct pane's Advanced disclosure;
    // gated per backend by ControlSurface.knobs). Initial values == knobDefaults
    // (the Qwen model's own generation defaults), so a fresh app and the Reset
    // button both reproduce the model's stock delivery.
    var temperatureOverride: Float = AppModel.knobDefaults.temperature
    var exaggerationOverride: Float = AppModel.knobDefaults.exaggeration

    // Qwen natural-language controls
    var instruct: String = ""
    var speaker: String = BackendID.qwenPresetSpeakers.first ?? "Vivian"
    var language: String = "auto"
    var qwenTopP: Float = AppModel.knobDefaults.topP
    var qwenTopK: Int = AppModel.knobDefaults.topK
    var qwenRepetitionPenalty: Float = AppModel.knobDefaults.repetitionPenalty

    // Download-on-demand: set when Generate hits a model that isn't downloaded,
    // so the UI can offer to fetch it (instead of a red error). Drives a sheet.
    var downloadPrompt: BackendID?

    // Set when Generate hits a backend that needs a license ack it doesn't have
    // yet — regardless of download state (a backend can be downloaded already
    // but never acknowledged, e.g. if it was fetched via `downloadPrompt` before
    // this gate existed). Drives a sheet distinct from `downloadPrompt`.
    var licensePromptBackend: BackendID?

    // Saved Direction (instruct) descriptions, persisted as JSON in UserDefaults.
    var savedDirections: [DirectionPreset] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(savedDirections) {
                UserDefaults.standard.set(data, forKey: "savedDirections")
            }
        }
    }

    /// Built-in starter descriptions, always available alongside saved ones.
    static let seededDirections: [DirectionPreset] = [
        .init(name: "Excited deep DJ",
              text: "A high-energy radio DJ with a deep, resonant chest voice — booming and warm, "
                  + "fast-paced and hyped, with punchy emphasis and a big confident grin you can hear."),
        .init(name: "Warm late-night host",
              text: "Warm, slightly breathy, unhurried late-night radio host — intimate and calm, "
                  + "with a gentle smile in the voice."),
        .init(name: "Wise old narrator",
              text: "An elderly storyteller, gravelly and slow, with a knowing warmth and "
                  + "deliberate, measured pacing."),
        .init(name: "Hype announcer",
              text: "Explosive arena announcer — huge, punchy and breathless, shouting over the "
                  + "crowd with rising intensity."),
        .init(name: "Soft meditation guide",
              text: "A soft, soothing meditation guide — very calm and slow, low and breathy, "
                  + "with long gentle pauses."),
    ]

    // API request console (shared with the server)
    let apiLog = APILog()

    @ObservationIgnored lazy var script: ScriptModel = ScriptModel(
        app: self,
        store: SessionStore(directory: UITestMode.isActive
            ? UITestMode.tempRoot.appendingPathComponent("Session")
            : StoragePaths.appSupport.appendingPathComponent("Session")))

    static let emotionOrder: [Emotion] = [.flat, .neutral, .warm, .excited, .hype]

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init() {
        let defaults = UserDefaults.standard
        let uiTest = UITestMode.isActive
        let voicesDir = uiTest ? UITestMode.tempRoot.appendingPathComponent("Voices")
                               : StoragePaths.voices
        let historyDir = uiTest ? UITestMode.tempRoot.appendingPathComponent("History")
                                : StoragePaths.history
        voices = VoiceLibrary(directory: voicesDir)
        history = HistoryStore(directory: historyDir)
        downloads = ModelDownloadManager(root: StoragePaths.models, uiTest: uiTest)
        speech = SpeechManager(uiTest: uiTest)
        backend = BackendID.migrating(rawValue: defaults.string(forKey: "defaultBackend") ?? "")
            ?? .fishS2Pro
        serverPort = defaults.object(forKey: "serverPort") as? Int ?? 8790
        didAcceptCloneConsent = uiTest || defaults.bool(forKey: "didAcceptCloneConsent")
        didAckFishLicense = defaults.bool(forKey: "didAckFishLicense")
        chatLLM = defaults.string(forKey: "chatLLM")
            .flatMap(LLMBackendID.init(rawValue:)) ?? .qwen3_1_7b
        chatAutoSpeak = defaults.object(forKey: "chatAutoSpeak") as? Bool ?? true
        if let data = defaults.data(forKey: "savedDirections"),
           let decoded = try? JSONDecoder().decode([DirectionPreset].self, from: data) {
            savedDirections = decoded
        }

        if uiTest {
            engine = GloamEngine(provider: UITestFakeProvider(),
                                 languageProvider: UITestFakeLanguageProvider())
        } else {
            let modelRoot = StoragePaths.models
            engine = GloamEngine(
                provider: MLXModelProvider(modelPathResolver: { backend in
                    // Mirror ModelDownloadManager.directory(for:): Qwen weights live in
                    // quant-suffixed folders (e.g. qwen3-0.6b@8bit), others under rawValue.
                    let quantRaw = backend.isQwen
                        ? (UserDefaults.standard.string(forKey: "qwenQuant.\(backend.rawValue)") ?? "8bit")
                        : nil
                    let dir = modelRoot.appendingPathComponent(backend.diskFolder(quantRaw: quantRaw))
                    let hasConfig = FileManager.default.fileExists(
                        atPath: dir.appendingPathComponent("config.json").path)
                    return hasConfig ? dir.path : nil
                }),
                languageProvider: MLXLanguageModelProvider(modelDirectoryResolver: { backend in
                    // Mirror ModelDownloadManager.llmDirectory(for:).
                    modelRoot.appendingPathComponent(backend.diskFolder)
                }))
        }
        if didAckFishLicense {
            let engine = engine
            Task { await engine.acknowledgeLicense(for: .fishS2Pro) }
        }
        installMemoryPressureHandler()
    }

    // MARK: generation

    func generate(takes: Int) async {
        generationError = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            generationError = "Enter some text first."
            return
        }
        // License needed but never acknowledged — regardless of download state,
        // since a backend can already be downloaded (e.g. via the download-prompt
        // path below, before this gate existed) yet still unacknowledged.
        if backend.spec.needsLicenseAck && !didAckFishLicense {
            licensePromptBackend = backend
            return
        }
        // Model not on disk yet → offer to download it (no red error). The sheet's
        // confirm starts a background download and generates once it's ready.
        if downloads.state(for: backend) != .ready {
            downloadPrompt = backend
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        variants = []
        for take in 0..<max(1, takes) {
            do {
                let result = try await synthesizeLine(
                    text: text, voiceSlug: selectedVoiceSlug,
                    emotion: emotion, speed: speed)
                let pcm = PCM16.data(from: result.samples)
                let seconds = Double(result.samples.count) / Double(result.sampleRate)
                let wav = WAVEncoder.encode(pcm16: pcm, sampleRate: result.sampleRate)
                variants.append(Variant(
                    label: String(UnicodeScalar(65 + take)!),  // A, B, …
                    wavData: wav, sampleRate: result.sampleRate,
                    seconds: seconds, wallSeconds: result.wallSeconds))
            } catch let err as AppGenerationError {
                generationError = err.message
                return
            } catch let error as EngineError {
                generationError = describe(error)
                return
            } catch {
                generationError = "\(error)"
                return
            }
        }
    }

    /// Confirm the license offered by `licensePromptBackend`: acknowledge it,
    /// then either generate right away (already downloaded) or fall into the
    /// same download-and-auto-generate flow as `confirmDownloadFromPrompt`.
    func confirmLicensePrompt() {
        guard let pending = licensePromptBackend else { return }
        licensePromptBackend = nil
        didAckFishLicense = true   // didSet also acks it with the engine
        if downloads.state(for: pending) == .ready {
            if backend == pending { Task { await generate(takes: 1) } }
        } else {
            downloadPrompt = pending
            confirmDownloadFromPrompt()
        }
    }

    func cancelLicensePrompt() { licensePromptBackend = nil }

    /// Confirm the download offered by `downloadPrompt`: start a background
    /// download (progress shows in the toolbar) and auto-generate once ready.
    func confirmDownloadFromPrompt() {
        guard let pending = downloadPrompt else { return }
        downloadPrompt = nil
        downloads.download(pending)
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                switch downloads.state(for: pending) {
                case .ready:
                    if backend == pending { await generate(takes: 1) }
                    return
                case .failed, .notDownloaded:
                    return   // user cancelled or download failed; surfaced in Settings
                case .downloading:
                    continue
                }
            }
        }
    }

    func cancelDownloadPrompt() { downloadPrompt = nil }

    // MARK: Direction presets

    /// Save the current Direction text under `name` (replacing any same-named entry).
    func saveDirection(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !text.isEmpty else { return }
        if let i = savedDirections.firstIndex(where: { $0.name == trimmedName }) {
            savedDirections[i].text = text
        } else {
            savedDirections.append(DirectionPreset(name: trimmedName, text: text))
        }
    }

    func deleteSavedDirection(_ preset: DirectionPreset) {
        savedDirections.removeAll { $0.id == preset.id }
    }

    /// Default delivery-knob values = the Qwen3-TTS model's own generation defaults
    /// (temperature 0.9, top-p 1.0, top-k 0 = off, repetition 1.05) — i.e. the stock
    /// delivery used when no overrides are sent. exaggeration 0.5 is Chatterbox neutral.
    static let knobDefaults = (temperature: Float(0.9), exaggeration: Float(0.5),
                               topP: Float(1.0), topK: 0, repetitionPenalty: Float(1.05))

    /// Restore the Advanced fine-tune sliders to their defaults.
    func resetDeliveryKnobs() {
        temperatureOverride = Self.knobDefaults.temperature
        exaggerationOverride = Self.knobDefaults.exaggeration
        qwenTopP = Self.knobDefaults.topP
        qwenTopK = Self.knobDefaults.topK
        qwenRepetitionPenalty = Self.knobDefaults.repetitionPenalty
    }

    // MARK: model residency

    func refreshEngineStatus() async {
        loadedBackend = await engine.loadedBackend()
        memGB = MemoryFootprint.currentGB()
    }

    func loadModel(_ backend: BackendID) async {
        guard downloads.state(for: backend) == .ready, !modelOpInFlight else { return }
        if backend.spec.needsLicenseAck && !didAckFishLicense {
            licensePromptBackend = backend
            return
        }
        modelOpInFlight = true
        loadingBackend = backend
        defer { modelOpInFlight = false; loadingBackend = nil }
        do { try await engine.preload(backend: backend) }
        catch { generationError = describeAny(error) }
        await refreshEngineStatus()
    }

    func unloadModel() async {
        guard !isGenerating else { return }
        await engine.unload()
        await refreshEngineStatus()
    }

    /// Shared engine path used by single-line mode and script mode.
    /// Throws AppGenerationError for precondition failures so callers show
    /// the same messages the single-line flow does.
    func synthesizeLine(text: String, voiceSlug: String?, emotion: Emotion,
                        speed: Float, recordHistory: Bool = true) async throws -> SynthesisResult {
        guard downloads.state(for: backend) == .ready else {
            throw AppGenerationError(
                message: "Download the \(backend.rawValue) model in Settings first.")
        }
        if backend.spec.needsLicenseAck && !didAckFishLicense {
            throw AppGenerationError(
                message: "Acknowledge the Fish license in Settings first.")
        }
        var refPath: String?
        var refText: String?
        var resolvedVoice: String?
        if let slug = voiceSlug {
            guard let found = try? voices.resolve(slug, emotion: emotion) else {
                throw AppGenerationError(message: "Voice '\(slug)' is missing.")
            }
            refPath = found.refURL.path
            refText = found.meta.refText.isEmpty ? nil : found.meta.refText
            resolvedVoice = found.meta.slug
        }
        if backend.spec.needsRefAudio && refPath == nil {
            throw AppGenerationError(
                message: "This backend needs a voice — pick or create one in the sidebar.")
        }
        let controls = backend.controls
        let request = SynthesisRequest(
            text: text, refAudioPath: refPath, refText: refText,
            emotion: emotion, speed: speed,
            temperatureOverride: controls.knobs.temperature != nil ? temperatureOverride : nil,
            exaggerationOverride: controls.knobs.exaggeration != nil ? exaggerationOverride : nil,
            instruct: controls.instruct != .none ? instruct : nil,
            speaker: controls.presetSpeakers.isEmpty ? nil : speaker,
            language: controls.language ? language : nil,
            topP: controls.knobs.topP != nil ? qwenTopP : nil,
            topK: controls.knobs.topK != nil ? qwenTopK : nil,
            repetitionPenalty: controls.knobs.repetitionPenalty != nil ? qwenRepetitionPenalty : nil)
        let raw = try await engine.synthesize(backend: backend, request: request)
        // Even out loudness: Fish output peaks at ~6–9% full-scale vs Chatterbox's
        // ~95%, so without this Fish takes sound much quieter. Normalize once here
        // so history, A/B variants, and script takes all stay consistent.
        let result = SynthesisResult(
            samples: AudioAssembler.normalizePeak(floats: raw.samples),
            sampleRate: raw.sampleRate, wallSeconds: raw.wallSeconds)
        await refreshEngineStatus()   // synthesis loads implicitly
        if recordHistory {
            _ = try? history.save(
                pcm: PCM16.data(from: result.samples), sampleRate: result.sampleRate,
                text: text, backend: backend.rawValue, voice: resolvedVoice,
                emotion: emotion.rawValue, wallMs: Int(result.wallSeconds * 1000))
        }
        return result
    }

    func describeAny(_ error: Error) -> String {
        if let appError = error as? AppGenerationError { return appError.message }
        if let engineError = error as? EngineError { return describe(engineError) }
        return "\(error)"
    }

    private func describe(_ error: EngineError) -> String {
        switch error {
        case .licenseAckRequired:
            return "Acknowledge the Fish license in Settings first."
        case .refAudioRequired:
            return "This backend needs a reference voice."
        case .generationFailed(_, let message):
            return "Generation failed: \(message)"
        case .invalidSpeed(let s):
            return "Invalid speed \(s)."
        case .instructRequired:
            return "This model needs a Direction (instruct)."
        case .speakerRequired:
            return "Pick a preset speaker for this model."
        case .languageProviderUnavailable:
            return "This model's language provider isn't loaded yet."
        }
    }

    // MARK: server

    private func syncServer() async {
        if serverEnabled {
            // Deps are immutable — rebuild the server when settings change so
            // defaultLLM/defaultBackend stay current.
            await server?.stop()
            server = nil
            if server == nil {
                server = LocalAPIServer(deps: APIDependencies(
                    engine: engine, voices: voices, defaultBackend: backend,
                    defaultLLM: downloads.state(for: chatLLM) == .ready ? chatLLM : nil,
                    log: apiLog))
            }
            try? await server?.start(port: serverPort)
        } else {
            await server?.stop()
            server = nil
        }
    }

    // MARK: memory pressure

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.isGenerating else { return }
            let engine = self.engine
            Task { await engine.unload() }
        }
        source.resume()
        memoryPressureSource = source
    }
}
