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

    // Manual delivery knobs (bound by the Direct pane's Advanced disclosure;
    // gated per backend by ControlSurface.knobs).
    var temperatureOverride: Float = 0.7
    var exaggerationOverride: Float = 0.5

    // Qwen natural-language controls
    var instruct: String = ""
    var speaker: String = BackendID.qwenPresetSpeakers.first ?? "Vivian"
    var language: String = "auto"
    var qwenTopP: Float = 1.0
    var qwenTopK: Int = 50
    var qwenRepetitionPenalty: Float = 1.05

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
