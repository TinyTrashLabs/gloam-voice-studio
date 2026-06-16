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
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "defaultBackend") }
    }
    var serverEnabled = false { didSet { Task { await syncServer() } } }
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

    // On emotion-driven backends (fish/chatterbox) the Emotion chips set delivery
    // by default; flipping this opts into the manual temperature/exaggeration knobs
    // instead. On Qwen (no emotion chips) the knobs are always the control.
    var useDirectionOverrides = false

    // Manual delivery knobs (bound by the Direct pane's Advanced disclosure;
    // gated per backend by ControlSurface.knobs). Initial values == knobDefaults
    // (the Qwen model's own generation defaults), so a fresh app and the Reset
    // button both reproduce the model's stock delivery.
    var temperatureOverride: Float = AppModel.knobDefaults.temperature
    var exaggerationOverride: Float = AppModel.knobDefaults.exaggeration

    // Qwen natural-language controls
    var instruct: String = ""
    var speaker: String = "Ryan"   // English male preset — sensible default
    var language: String = "auto"
    var qwenTopP: Float = AppModel.knobDefaults.topP
    var qwenTopK: Int = AppModel.knobDefaults.topK
    var qwenRepetitionPenalty: Float = AppModel.knobDefaults.repetitionPenalty

    // Download-on-demand: set when a not-downloaded model is chosen (load) or hit
    // by Generate (generate), so the UI can offer to fetch it. Drives a sheet.
    enum DownloadIntent { case load, generate }
    var downloadPrompt: BackendID?
    var downloadIntent: DownloadIntent = .generate
    /// Backends with a live download-poll task, so a re-prompt can't double-fire.
    private var downloadPolling: Set<BackendID> = []

    // Saved Direction (instruct) descriptions, persisted as JSON in UserDefaults.
    var savedDirections: [DirectionPreset] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(savedDirections) {
                UserDefaults.standard.set(data, forKey: "savedDirections")
            }
        }
    }

    /// Built-in character descriptions in Qwen's recommended attribute-list format,
    /// always available alongside saved ones (best for qwen3-design).
    static let seededDirections: [DirectionPreset] = [
        .init(name: "DJ · Deep & Fun", text: """
            gender: Male.
            pitch: Deep and low in a warm bass register — lively but never high or thin.
            speed: Fast and lively, upbeat and bouncy.
            volume: Big and projecting, hyping the crowd.
            age: Adult in his 30s.
            accent: General American.
            texture: Deep, warm, rich chest voice with a friendly rasp.
            emotion: Excited, joyful and pumped — having a blast, celebratory.
            tone: Upbeat party hype, fun and infectious — not angry, not theatrical.
            personality: Warm, charismatic, fun-loving showman.
            """),
        .init(name: "DJ · Smooth Drive", text: """
            gender: Male.
            pitch: Deep, low and smooth — steady warm bass.
            speed: Brisk but relaxed, riding the groove.
            volume: Full and confident, easy projection.
            age: Adult in his late 30s.
            accent: General American.
            texture: Rich, velvety, deep chest voice.
            emotion: Upbeat and cool, having fun without forcing it.
            tone: Smooth charismatic drive-time DJ — confident and easy.
            personality: Cool, magnetic, effortlessly charming.
            """),
        .init(name: "DJ · Big Festival", text: """
            gender: Male.
            pitch: Deep and powerful, staying low even when the energy peaks.
            speed: Fast and driving, punchy.
            volume: Huge and booming, filling a stadium.
            age: Adult in his 30s.
            accent: General American.
            texture: Thick, resonant, deep with a warm rasp.
            emotion: Euphoric, fired-up fun — pure celebration, not aggression.
            tone: Massive festival hype-man — joyful and electric.
            personality: Larger-than-life, warm, crowd-loving showman.
            """),
        .init(name: "DJ · Gravelly Party", text: """
            gender: Male.
            pitch: Very low, deep gravelly bass.
            speed: Fast and punchy, driving pace — no dragging.
            volume: Loud and full, hyping the room.
            age: Adult in his 30s to 40s.
            accent: General American.
            texture: Gritty, gravelly, deep and chesty.
            emotion: Pumped, energetic and fun.
            tone: Gritty party MC — rowdy good-time energy, never angry.
            personality: Rugged, charismatic, fun-loving.
            """),
        .init(name: "Wise old narrator", text: """
            gender: Male.
            pitch: Low, steady register.
            speed: Slow, deliberate, measured pacing with thoughtful pauses.
            volume: Calm and even.
            age: Elderly, in his 70s.
            accent: General American English.
            texture: Gravelly and warm.
            emotion: Knowing and reflective.
            tone: Intimate storytelling.
            personality: Wise, patient, grandfatherly.
            """),
        .init(name: "Ogre", text: """
            gender: Male.
            pitch: Extremely low, sub-bass register.
            speed: Slow and lumbering, dragging the vowels.
            volume: Loud and rumbling.
            age: Ageless monster.
            texture: Gravelly, wet, growling rumble.
            emotion: Menacing, dim, irritable.
            tone: Threatening snarl.
            personality: Hulking, brutish, dangerous.
            """),
        .init(name: "Warm late-night host", text: """
            gender: Gender-neutral.
            pitch: Mid-low and smooth.
            speed: Unhurried and relaxed.
            volume: Soft and intimate.
            age: 30s to 40s.
            accent: General American English.
            texture: Warm, slightly breathy.
            emotion: Calm and soothing.
            tone: Intimate and friendly.
            personality: Easygoing and comforting.
            """),
    ]

    /// Quick single-attribute styles — great for layering on a CustomVoice timbre
    /// (qwen3-custom) or as a fast tweak on qwen3-design.
    static let seededStyles: [DirectionPreset] = [
        .init(name: "Very happy", text: "Speak in a very happy, upbeat and cheerful tone."),
        .init(name: "Sad & tearful", text: "Speak with a very sad, tearful voice — slow and trembling."),
        .init(name: "Angry", text: "Speak in a particularly angry, sharp tone."),
        .init(name: "Whisper", text: "Speak in an extremely quiet, secretive whisper."),
        .init(name: "Very slow", text: "Speak at an extremely slow, deliberate pace."),
        .init(name: "Low & deep", text: "Speak in a low, deep register."),
        .init(name: "Excited & fast", text: "Speak fast and energetically, voice rising with excitement."),
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
        if let data = defaults.data(forKey: "savedDirections"),
           let decoded = try? JSONDecoder().decode([DirectionPreset].self, from: data) {
            savedDirections = decoded
        }

        if uiTest {
            engine = GloamEngine(provider: UITestFakeProvider())
        } else {
            let modelRoot = StoragePaths.models
            engine = GloamEngine(provider: MLXModelProvider(modelPathResolver: { backend in
                // Mirror ModelDownloadManager.directory(for:): Qwen weights live in
                // quant-suffixed folders (e.g. qwen3-0.6b@8bit), others under rawValue.
                let quantRaw = backend.isQwen
                    ? (UserDefaults.standard.string(forKey: "qwenQuant.\(backend.rawValue)") ?? "8bit")
                    : nil
                let dir = modelRoot.appendingPathComponent(backend.diskFolder(quantRaw: quantRaw))
                let hasConfig = FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("config.json").path)
                return hasConfig ? dir.path : nil
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
        // Model not on disk yet → offer to download it (no red error). The sheet's
        // confirm starts a background download and generates once it's ready.
        if downloads.state(for: backend) != .ready {
            downloadIntent = .generate
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

    /// Select a model from the chooser. Loads it if downloaded; otherwise offers
    /// to download it (then loads once ready) instead of silently doing nothing.
    func selectModel(_ backend: BackendID) {
        self.backend = backend
        if downloads.state(for: backend) == .ready {
            Task { await loadModel(backend) }
        } else {
            downloadIntent = .load
            downloadPrompt = backend
        }
    }

    /// Confirm the download offered by `downloadPrompt`: start a background
    /// download (progress shows in the toolbar) and, once ready, either load it
    /// or generate — depending on what triggered the prompt.
    func confirmDownloadFromPrompt() {
        guard let pending = downloadPrompt else { return }
        let intent = downloadIntent
        downloadPrompt = nil
        // Don't start a second poll for a model already downloading on our watch —
        // otherwise a re-prompt could fire a duplicate generation when it lands.
        guard !downloadPolling.contains(pending) else { return }
        downloadPolling.insert(pending)
        downloads.download(pending)
        Task {
            defer { downloadPolling.remove(pending) }
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                switch downloads.state(for: pending) {
                case .ready:
                    if backend == pending {
                        switch intent {
                        case .generate: await generate(takes: 1)
                        case .load: await loadModel(pending)
                        }
                    }
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
                        speed: Float) async throws -> SynthesisResult {
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
        // On emotion backends the knobs are an opt-in override; on Qwen (no emotion
        // chips) they're the primary control and always apply. Otherwise the manual
        // values would silently override the Emotion presets.
        let manualKnobs = !controls.emotionChips || useDirectionOverrides
        let request = SynthesisRequest(
            text: text, refAudioPath: refPath, refText: refText,
            emotion: emotion, speed: speed,
            temperatureOverride: (controls.knobs.temperature != nil && manualKnobs) ? temperatureOverride : nil,
            exaggerationOverride: (controls.knobs.exaggeration != nil && manualKnobs) ? exaggerationOverride : nil,
            instruct: controls.instruct != .none ? instruct : nil,
            speaker: controls.presetSpeakers.isEmpty ? nil : speaker,
            language: controls.language ? language : nil,
            topP: (controls.knobs.topP != nil && manualKnobs) ? qwenTopP : nil,
            topK: (controls.knobs.topK != nil && manualKnobs) ? qwenTopK : nil,
            repetitionPenalty: (controls.knobs.repetitionPenalty != nil && manualKnobs) ? qwenRepetitionPenalty : nil)
        let raw = try await engine.synthesize(backend: backend, request: request)
        // Even out loudness: Fish output peaks at ~6–9% full-scale vs Chatterbox's
        // ~95%, so without this Fish takes sound much quieter. Normalize once here
        // so history, A/B variants, and script takes all stay consistent.
        let result = SynthesisResult(
            samples: AudioAssembler.normalizePeak(floats: raw.samples),
            sampleRate: raw.sampleRate, wallSeconds: raw.wallSeconds)
        await refreshEngineStatus()   // synthesis loads implicitly
        _ = try? history.save(
            pcm: PCM16.data(from: result.samples), sampleRate: result.sampleRate,
            text: text, backend: backend.rawValue, voice: resolvedVoice,
            emotion: emotion.rawValue, wallMs: Int(result.wallSeconds * 1000))
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
        }
    }

    // MARK: server

    private func syncServer() async {
        if serverEnabled {
            if server == nil {
                server = LocalAPIServer(deps: APIDependencies(
                    engine: engine, voices: voices, defaultBackend: backend, log: apiLog))
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
