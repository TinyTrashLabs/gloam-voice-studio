import EngineKit
import Foundation
import Observation
import StudioKit
import SwiftUI

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

    // Studio state
    var selectedVoiceSlug: String?
    var text = ""
    var emotion: Emotion = .neutral
    var speed: Float = 1.0
    var variants: [Variant] = []
    var isGenerating = false
    var generationError: String?
    var voicesVersion = 0   // bump to refresh voice lists after library mutations

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
        backend = BackendID(rawValue: defaults.string(forKey: "defaultBackend") ?? "")
            ?? .chatterboxTurbo
        serverPort = defaults.object(forKey: "serverPort") as? Int ?? 8790
        didAcceptCloneConsent = uiTest || defaults.bool(forKey: "didAcceptCloneConsent")
        didAckFishLicense = defaults.bool(forKey: "didAckFishLicense")

        if uiTest {
            engine = GloamEngine(provider: UITestFakeProvider())
        } else {
            let modelRoot = StoragePaths.models
            engine = GloamEngine(provider: MLXModelProvider(modelPathResolver: { backend in
                let dir = modelRoot.appendingPathComponent(backend.rawValue)
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
        guard downloads.state(for: backend) == .ready else {
            generationError = "Download the \(backend.rawValue) model in Settings first."
            return
        }
        if backend.spec.needsLicenseAck && !didAckFishLicense {
            generationError = "Acknowledge the Fish license in Settings first."
            return
        }
        var refPath: String?
        var refText: String?
        var resolvedVoice: String?
        if let slug = selectedVoiceSlug {
            guard let found = try? voices.resolve(slug, emotion: emotion) else {
                generationError = "Voice '\(slug)' is missing."
                return
            }
            refPath = found.refURL.path
            refText = found.meta.refText.isEmpty ? nil : found.meta.refText
            resolvedVoice = found.meta.slug
        }
        if backend.spec.needsRefAudio && refPath == nil {
            generationError = "This backend needs a voice — pick or create one in the sidebar."
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        variants = []
        for take in 0..<max(1, takes) {
            do {
                let request = SynthesisRequest(
                    text: text, refAudioPath: refPath, refText: refText,
                    emotion: emotion, speed: speed)
                let result = try await engine.synthesize(backend: backend, request: request)
                let pcm = PCM16.data(from: result.samples)
                let seconds = Double(result.samples.count) / Double(result.sampleRate)
                let wav = WAVEncoder.encode(pcm16: pcm, sampleRate: result.sampleRate)
                _ = try? history.save(
                    pcm: pcm, sampleRate: result.sampleRate, text: text,
                    backend: backend.rawValue, voice: resolvedVoice,
                    emotion: emotion.rawValue, wallMs: Int(result.wallSeconds * 1000))
                variants.append(Variant(
                    label: String(UnicodeScalar(65 + take)!),  // A, B, …
                    wavData: wav, sampleRate: result.sampleRate,
                    seconds: seconds, wallSeconds: result.wallSeconds))
            } catch let error as EngineError {
                generationError = describe(error)
                return
            } catch {
                generationError = "\(error)"
                return
            }
        }
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
        }
    }

    // MARK: server

    private func syncServer() async {
        if serverEnabled {
            if server == nil {
                server = LocalAPIServer(deps: APIDependencies(
                    engine: engine, voices: voices, defaultBackend: backend))
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
