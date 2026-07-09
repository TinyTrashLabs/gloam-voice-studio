import EngineKit
import Foundation
import Observation
import StudioKit
import SwiftUI

struct AppGenerationError: Error {
    let message: String
}

/// One generated take, ready to play/export.
/// Emotional expressions baked as acted `<slug>-<expression>` variants, rendered
/// through Fish's inline `[marker]` mechanism — its real emotion control, unlike
/// `temperature` (just sampling) or `exaggeration` (intensity only). This is Fish
/// S2's full single-word expressive vocabulary: a client (e.g. gloam.fm's DJ) may
/// use only a few, but every voice can carry all of them.
enum VoiceExpression: String, CaseIterable, Sendable {
    case excited, delight, angry, sad, surprised, shocked
    case whisper, shouting, screaming, laughing, chuckle, sigh, panting, moaning, singing
    var label: String { rawValue.capitalized }

    /// Best-effort Chatterbox exaggeration (0–1) for users who can't run Fish.
    /// Chatterbox has only an *intensity* knob — it can't act distinct emotions the
    /// way Fish markers can — so this maps each expression to a calm/intense level.
    var chatterboxExaggeration: Float {
        switch self {
        case .sad, .whisper, .sigh, .moaning: 0.2
        case .chuckle, .panting, .singing: 0.5
        case .excited, .delight, .surprised, .laughing: 0.8
        case .angry, .shocked, .shouting, .screaming: 1.0
        }
    }
}

struct Variant: Identifiable, Equatable {
    let id = UUID()
    let label: String          // "A" / "B"
    let wavData: Data
    let sampleRate: Int
    let seconds: Double
    let wallSeconds: Double
    var rtf: Double { wallSeconds > 0 ? seconds / wallSeconds : 0 }
}

/// One persisted qwen3-design candidate: audio + the prompt that produced it,
/// so it can be revisited after the description/audition-line fields move on
/// (or the app relaunches). Deliberately separate from `Variant` — that type
/// is shared with Studio's unrelated generation-history feature and must not
/// carry Voice-Foundry-specific fields.
struct FoundryCandidate: Identifiable, Equatable {
    let id: String              // == FoundryCandidateEntry.id
    let wavData: Data
    let sampleRate: Int
    let seconds: Double
    let wallSeconds: Double
    let description: String     // the qwen3-design instruct that produced this candidate
    let auditionLine: String
    let language: String?
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
    /// Second engine holding only the chat voice: TTS here overlaps the main
    /// engine's LLM decode instead of interleaving with it. See init.
    let chatSpeechEngine: GloamEngine
    let downloads: ModelDownloadManager
    let speech: SpeechManager
    /// This machine's RAM/chip snapshot, read once at launch (it can't change
    /// while the app runs) — drives RAM-gating in the model pickers.
    let deviceCapabilities: EngineCapabilities
    private var server: LocalAPIServer?
    @ObservationIgnored private var serverSync: Task<Void, Never>?

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
    var serverEnabled = false { didSet { scheduleServerSync() } }
    /// LLM used by the chat tab (and as the API server's default LLM).
    var chatLLM: LLMBackendID {
        didSet {
            UserDefaults.standard.set(chatLLM.rawValue, forKey: "chatLLM")
            scheduleServerSync()   // keep the route's default in step
        }
    }
    /// Keep the resident TTS + LLM loaded through memory-pressure WARNINGS
    /// (evict only on critical). Reloading a model costs ~10s each, so a
    /// warning-level evict between chat turns makes every reply feel like a
    /// cold start. Off = old behavior (evict on any pressure).
    var keepModelsResident: Bool {
        didSet { UserDefaults.standard.set(keepModelsResident, forKey: "keepModelsResident") }
    }
    /// Let the chat model reason (<think>) before answering. Reasoning shows
    /// in the transcript but is always stripped from speech.
    var chatThinking: Bool {
        didSet { UserDefaults.standard.set(chatThinking, forKey: "chatThinking") }
    }
    /// Chat context window (tokens). Caps how much conversation history is
    /// sent per turn — smaller = faster prefill and less memory, larger =
    /// longer memory. Clamped to the model's own limit when building requests.
    var chatContextTokens: Int {
        didSet { UserDefaults.standard.set(chatContextTokens, forKey: "chatContextTokens") }
    }
    /// Retention cap for persisted Voice Foundry candidates (mirrors the
    /// store's on-disk pruning into the in-memory list too).
    var foundryCandidateRetentionCap: Int {
        didSet {
            UserDefaults.standard.set(foundryCandidateRetentionCap, forKey: "foundryCandidateRetentionCap")
            foundryCandidateStore.cap = foundryCandidateRetentionCap
        }
    }
    /// Retention cap for saved chat-reply audio takes.
    var chatAudioRetentionCap: Int {
        didSet {
            UserDefaults.standard.set(chatAudioRetentionCap, forKey: "chatAudioRetentionCap")
            chatAudioStore.cap = chatAudioRetentionCap
        }
    }
    /// Voice engine chat replies render with — independent of the Studio
    /// backend so slow, quality-first studio work (Fish) never makes chat
    /// crawl. Small/fast backends only.
    var chatTTSBackend: BackendID {
        didSet { UserDefaults.standard.set(chatTTSBackend.rawValue, forKey: "chatTTSBackend") }
    }
    /// Measured synthesis speed per TTS backend, as audio-seconds produced per
    /// wall-second (EMA over recent synths on THIS machine). >1 means faster
    /// than realtime — the bar for gapless chat speech. Drives the speed
    /// labels in the chat voice picker.
    private(set) var ttsSpeedEMA: [String: Double] {
        didSet { UserDefaults.standard.set(ttsSpeedEMA, forKey: "ttsSpeedEMA") }
    }

    /// Whether this Mac has enough RAM to safely load/run `backend`.
    func hasSufficientRAM(for backend: BackendID) -> Bool {
        deviceCapabilities.physicalMemoryBytes >= UInt64(backend.spec.minRAMBytes)
    }

    /// Whether this Mac has enough RAM to safely load/run `llm`.
    func hasSufficientRAM(for llm: LLMBackendID) -> Bool {
        deviceCapabilities.physicalMemoryBytes >= UInt64(llm.minRAMBytes)
    }

    /// "needs 16GB RAM" — for the disabled-row label/tooltip in model pickers.
    func ramRequirementLabel(minRAMBytes: Int64) -> String {
        "needs \(minRAMBytes / 1_000_000_000)GB RAM"
    }

    /// Triggers a real download if `backend` isn't on disk yet, and waits for
    /// it to finish (or throws) — the download itself is already
    /// async/background via ModelDownloadManager; this gives callers
    /// something to await instead of hitting a dead-end "download it
    /// yourself" error.
    func ensureLLMReady(_ backend: LLMBackendID) async throws {
        if case .ready = downloads.state(for: backend) { return }
        switch downloads.state(for: backend) {
        case .downloading: break   // already in flight — just wait below
        default: downloads.download(backend)   // .notDownloaded OR .failed → (re)start
        }
        while true {
            switch downloads.state(for: backend) {
            case .ready: return
            case .failed(let message): throw AppGenerationError(message: message)
            default: try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Expand `text` (a short, terse field value) into a fuller version
    /// suited to `kind`, via the user's chosen chat LLM.
    func expand(_ text: String, kind: PromptExpansionKind) async throws -> String {
        try await ensureLLMReady(chatLLM)
        let request = ChatRequest(messages: [
            ChatTurn(role: .system, content: kind.instruction),
            ChatTurn(role: .user, content: text),
        ], maxTokens: 300)
        let result = try await engine.chat(backend: chatLLM, request: request)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recordTTSSpeed(backend: BackendID, audioSeconds: Double, wallSeconds: Double) {
        guard wallSeconds > 0.2, audioSeconds > 0.2 else { return }   // ignore blips
        let ratio = audioSeconds / wallSeconds
        let old = ttsSpeedEMA[backend.rawValue]
        ttsSpeedEMA[backend.rawValue] = old.map { $0 * 0.7 + ratio * 0.3 } ?? ratio
    }

    /// Picker label suffix: measured speed if we have one, else nothing.
    func ttsSpeedLabel(for backend: BackendID) -> String {
        guard let ratio = ttsSpeedEMA[backend.rawValue] else { return "" }
        return String(format: " · %.1f× realtime", ratio)
    }
    /// Render chat speech on the second engine, concurrent with token decode
    /// (gapless). Off = the serialized fallback: synthesis interleaves with
    /// decode in token gaps — safe mode if parallel rendering ever misbehaves.
    var chatParallelSpeech: Bool {
        didSet { UserDefaults.standard.set(chatParallelSpeech, forKey: "chatParallelSpeech") }
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
    var loadedLLM: LLMBackendID?
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
    /// Chatterbox (regular) CFG guidance weight; pairs with exaggeration.
    var cfgWeight: Float = AppModel.knobDefaults.cfgWeight

    // Qwen natural-language controls
    var instruct: String = ""
    var speaker: String = BackendID.qwenPresetSpeakers.first ?? "Vivian"
    var language: String = "auto"
    var qwenTopP: Float = AppModel.knobDefaults.topP
    var qwenTopK: Int = AppModel.knobDefaults.topK
    var qwenRepetitionPenalty: Float = AppModel.knobDefaults.repetitionPenalty

    // MARK: Voice Foundry (Create Voice) — qwen3-design mints a new voice you then
    // save as a reusable clone reference. Its state is separate from the Studio bench.
    static let defaultAuditionLine =
        "Hi there — I'm trying out a brand-new voice. It should sound natural whether "
        + "I'm calm and thoughtful, or bright and full of energy."
    var foundryDescription = ""                     // qwen3-design instruct / Direction
    var foundryAuditionLine = AppModel.defaultAuditionLine
    var foundryLanguage = "auto"
    var foundryCandidates: [FoundryCandidate] = []
    var foundryGenerating = false
    var foundryBaking = false
    var foundryError: String?
    var lastSavedFoundrySlug: String?               // set on save → drives the bake panel
    /// Which creation path the Create Voice page shows. The sidebar's "+"
    /// jumps straight to `.record` (clone a clip); the Foundry default is
    /// `.describe` (design from text). One page, both paths — no popups.
    var createVoiceSource: CreateVoiceSource = .describe

    enum CreateVoiceSource: Sendable { case describe, record }
    /// When non-nil, the Create Voice page opens in Edit mode for this voice.
    var editingVoiceSlug: String?

    /// What to resume once a pending download/license prompt clears.
    /// `.studioGenerate` re-checks Studio's picker before resuming (see
    /// `resumePendingSynthesisAction`) since it's driven by shared, mutable
    /// picker state the user could change while the prompt was up;
    /// `.chatRegenerate` has no equivalent staleness risk — its target
    /// backend is baked into the action itself, chosen from a per-message
    /// menu, not read from shared state.
    enum PendingSynthesisAction: Equatable {
        case studioGenerate
        case chatRegenerate(conversationID: String, messageID: String, backend: BackendID)
    }
    var pendingSynthesisAction: PendingSynthesisAction?

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

    @ObservationIgnored lazy var chat: ChatController = ChatController(
        app: self,
        store: ChatStore(directory: UITestMode.isActive
            ? UITestMode.tempRoot.appendingPathComponent("Chats")
            : StoragePaths.appSupport.appendingPathComponent("Chats")))

    @ObservationIgnored lazy var foundryCandidateStore: FoundryCandidateStore = FoundryCandidateStore(
        directory: UITestMode.isActive
            ? UITestMode.tempRoot.appendingPathComponent("FoundryCandidates")
            : StoragePaths.foundryCandidates,
        cap: foundryCandidateRetentionCap)

    @ObservationIgnored lazy var chatAudioStore: ChatAudioStore = ChatAudioStore(
        directory: UITestMode.isActive
            ? UITestMode.tempRoot.appendingPathComponent("ChatAudio")
            : StoragePaths.chatAudio,
        cap: chatAudioRetentionCap)

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
        deviceCapabilities = EngineCapabilities.current()
        // qwen3-design is Creation-only now (it lives in the Voice Foundry, not the
        // Studio picker) — redirect a persisted design backend to a real clone model.
        let loadedBackend = BackendID.migrating(rawValue: defaults.string(forKey: "defaultBackend") ?? "")
            ?? .fishS2Pro
        backend = loadedBackend == .qwenDesign ? .qwen17B : loadedBackend
        serverPort = defaults.object(forKey: "serverPort") as? Int ?? 8790
        didAcceptCloneConsent = uiTest || defaults.bool(forKey: "didAcceptCloneConsent")
        didAckFishLicense = defaults.bool(forKey: "didAckFishLicense")
        chatLLM = defaults.string(forKey: "chatLLM")
            .flatMap(LLMBackendID.init(rawValue:)) ?? .qwen3_1_7b
        chatAutoSpeak = defaults.object(forKey: "chatAutoSpeak") as? Bool ?? true
        keepModelsResident = defaults.object(forKey: "keepModelsResident") as? Bool ?? true
        // Turbo default: the only engine measured faster than realtime — the
        // bar for gapless chat speech (existing user picks persist).
        chatTTSBackend = BackendID(rawValue: defaults.string(forKey: "chatTTSBackend") ?? "")
            ?? .chatterboxTurbo
        ttsSpeedEMA = defaults.dictionary(forKey: "ttsSpeedEMA") as? [String: Double] ?? [:]
        chatParallelSpeech = defaults.object(forKey: "chatParallelSpeech") as? Bool ?? true
        chatContextTokens = defaults.object(forKey: "chatContextTokens") as? Int ?? 8192
        foundryCandidateRetentionCap = defaults.object(forKey: "foundryCandidateRetentionCap") as? Int ?? 50
        chatAudioRetentionCap = defaults.object(forKey: "chatAudioRetentionCap") as? Int ?? 200
        chatThinking = defaults.bool(forKey: "chatThinking")
        if let data = defaults.data(forKey: "savedDirections"),
           let decoded = try? JSONDecoder().decode([DirectionPreset].self, from: data) {
            savedDirections = decoded
        }

        if uiTest {
            engine = GloamEngine(provider: UITestFakeProvider(),
                                 languageProvider: UITestFakeLanguageProvider())
            chatSpeechEngine = GloamEngine(provider: UITestFakeProvider())
        } else {
            let modelRoot = StoragePaths.models
            // Mirror ModelDownloadManager.directory(for:): Qwen weights live in
            // quant-suffixed folders (e.g. qwen3-0.6b@8bit), others under rawValue.
            let ttsResolver: @Sendable (BackendID) -> String? = { backend in
                let quantRaw = backend.isQwen
                    ? (UserDefaults.standard.string(forKey: "qwenQuant.\(backend.rawValue)") ?? "8bit")
                    : nil
                let dir = modelRoot.appendingPathComponent(backend.diskFolder(quantRaw: quantRaw))
                let hasConfig = FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("config.json").path)
                return hasConfig ? dir.path : nil
            }
            engine = GloamEngine(
                provider: MLXModelProvider(modelPathResolver: ttsResolver),
                languageProvider: MLXLanguageModelProvider(modelDirectoryResolver: { backend in
                    // Mirror ModelDownloadManager.llmDirectory(for:).
                    modelRoot.appendingPathComponent(backend.diskFolder)
                }))
            // Chat speech renders on its OWN engine so TTS inference runs
            // concurrently with the main engine's token decode (verified safe;
            // loads still effectively serialize — the chat TTS loads once, up
            // front). This is what makes spoken replies ~gapless instead of
            // trading 8s of GPU per sentence with the LLM.
            chatSpeechEngine = GloamEngine(
                provider: MLXModelProvider(modelPathResolver: ttsResolver))
        }
        if didAckFishLicense {
            let engine = engine
            Task { await engine.acknowledgeLicense(for: .fishS2Pro) }
        }
        installMemoryPressureHandler()
        foundryCandidates = foundryCandidateStore.list().compactMap { entry -> FoundryCandidate? in
            guard let url = try? foundryCandidateStore.wavURL(entry.id),
                  let wav = try? Data(contentsOf: url) else { return nil }
            return FoundryCandidate(id: entry.id, wavData: wav, sampleRate: entry.sampleRate,
                                     seconds: entry.seconds, wallSeconds: entry.wallSeconds,
                                     description: entry.description, auditionLine: entry.auditionLine,
                                     language: entry.language)
        }
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
            pendingSynthesisAction = .studioGenerate
            licensePromptBackend = backend
            return
        }
        // Model not on disk yet → offer to download it (no red error). The sheet's
        // confirm starts a background download and generates once it's ready.
        if downloads.state(for: backend) != .ready {
            pendingSynthesisAction = .studioGenerate
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
    /// then either resume right away (already downloaded) or fall into the
    /// same download-and-auto-resume flow as `confirmDownloadFromPrompt`.
    func confirmLicensePrompt() {
        guard let pending = licensePromptBackend else { return }
        licensePromptBackend = nil
        didAckFishLicense = true   // didSet also acks it with the engine
        if downloads.state(for: pending) == .ready {
            resumePendingSynthesisAction(matching: pending)
        } else {
            downloadPrompt = pending
            confirmDownloadFromPrompt()
        }
    }

    func cancelLicensePrompt() {
        licensePromptBackend = nil
        pendingSynthesisAction = nil
    }

    /// Confirm the download offered by `downloadPrompt`: start a background
    /// download (progress shows in the toolbar) and auto-resume once ready.
    func confirmDownloadFromPrompt() {
        guard let pending = downloadPrompt else { return }
        downloadPrompt = nil
        downloads.download(pending)
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                switch downloads.state(for: pending) {
                case .ready:
                    resumePendingSynthesisAction(matching: pending)
                    return
                case .failed, .notDownloaded:
                    pendingSynthesisAction = nil
                    return   // user cancelled or download failed; surfaced in Settings
                case .downloading:
                    continue
                }
            }
        }
    }

    func cancelDownloadPrompt() {
        downloadPrompt = nil
        pendingSynthesisAction = nil
    }

    /// Dispatches whatever action was waiting on a download/license prompt
    /// that just cleared for `pending`. `.studioGenerate` preserves the
    /// pre-existing staleness guard (only resumes if Studio's picker still
    /// points at `pending` — the user could have changed it while the
    /// prompt was up); `.chatRegenerate` always resumes, since its target
    /// backend was chosen explicitly and can't have gone stale the same way.
    private func resumePendingSynthesisAction(matching pending: BackendID) {
        let action = pendingSynthesisAction
        pendingSynthesisAction = nil
        switch action {
        case .studioGenerate:
            if backend == pending { Task { await self.generate(takes: 1) } }
        case .chatRegenerate(let conversationID, let messageID, let backend):
            Task { await self.chat.resumeRegenerate(
                conversationID: conversationID, messageID: messageID, backend: backend) }
        case nil:
            break
        }
    }

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
                               cfgWeight: Float(0.5),
                               topP: Float(1.0), topK: 0, repetitionPenalty: Float(1.05))

    /// Restore the Advanced fine-tune sliders to their defaults.
    func resetDeliveryKnobs() {
        temperatureOverride = Self.knobDefaults.temperature
        exaggerationOverride = Self.knobDefaults.exaggeration
        cfgWeight = Self.knobDefaults.cfgWeight
        qwenTopP = Self.knobDefaults.topP
        qwenTopK = Self.knobDefaults.topK
        qwenRepetitionPenalty = Self.knobDefaults.repetitionPenalty
    }

    // MARK: model residency

    func refreshEngineStatus() async {
        loadedBackend = await engine.loadedBackend()
        loadedLLM = await engine.loadedLLM()
        memGB = MemoryFootprint.currentGB()
    }

    /// Evict the resident chat LLM (Unload button in the chat inspector).
    func unloadChatLLM() async {
        await engine.unloadLLM()
        await refreshEngineStatus()
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

    /// Single door for editing a voice: a rename re-slugs, so this carries the
    /// dependents — acted emotion variants move with the voice, and chat
    /// conversations re-point — plus selection/edit-state bookkeeping.
    /// Renaming through `voices.update` directly orphans all of those.
    @discardableResult
    func updateVoice(_ slug: String, name: String? = nil,
                     refText: String? = nil, refWav: Data? = nil) throws -> VoiceMeta {
        let suffixes = Set(VoiceExpression.allCases.map(\.rawValue)
            + Emotion.allCases.map(\.rawValue))
        let meta = try voices.update(slug, name: name, refText: refText,
                                     refWav: refWav, variantSuffixes: suffixes)
        if meta.slug != slug {
            chat.voiceRenamed(from: slug, to: meta.slug)
            if selectedVoiceSlug == slug { selectedVoiceSlug = meta.slug }
            if editingVoiceSlug == slug { editingVoiceSlug = meta.slug }
        }
        voicesVersion += 1
        return meta
    }

    /// Shared engine path used by single-line mode and script mode.
    /// Throws AppGenerationError for precondition failures so callers show
    /// the same messages the single-line flow does.
    /// `interleaved: true` routes through the engine's interleaved path so a
    /// chat sentence can synthesize in the GPU-idle gaps of an active LLM
    /// stream (identical to the normal path when no stream is active).
    /// `backendOverride`/`engineOverride` let chat render with its own voice
    /// engine on the second (parallel) GloamEngine.
    func synthesizeLine(text: String, voiceSlug: String?, emotion: Emotion,
                        speed: Float, recordHistory: Bool = true,
                        interleaved: Bool = false,
                        backendOverride: BackendID? = nil,
                        engineOverride: GloamEngine? = nil) async throws -> SynthesisResult {
        let backend = backendOverride ?? self.backend
        let engine = engineOverride ?? self.engine
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
        // Fish (.inlineMarker) renders emotion from the live [marker] while cloning
        // the BASE voice — so resolve to the base clip, not an acted `-emotion`
        // variant (that path is for the variant-clip backends).
        let resolveEmotion: Emotion = backend.emotionMechanism == .inlineMarker ? .neutral : emotion
        if let slug = voiceSlug {
            guard let found = try? voices.resolve(slug, emotion: resolveEmotion) else {
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
            cfgWeight: controls.knobs.cfgWeight != nil ? cfgWeight : nil,
            instruct: controls.instruct != .none ? instruct : nil,
            speaker: controls.presetSpeakers.isEmpty ? nil : speaker,
            language: controls.language ? language : nil,
            topP: controls.knobs.topP != nil ? qwenTopP : nil,
            topK: controls.knobs.topK != nil ? qwenTopK : nil,
            repetitionPenalty: controls.knobs.repetitionPenalty != nil ? qwenRepetitionPenalty : nil)
        let raw = interleaved
            ? try await engine.synthesizeInterleaved(backend: backend, request: request)
            : try await engine.synthesize(backend: backend, request: request)
        recordTTSSpeed(backend: backend,
                       audioSeconds: Double(raw.samples.count) / Double(raw.sampleRate),
                       wallSeconds: raw.wallSeconds)
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

    // MARK: - Voice Foundry

    /// Generate one qwen3-design candidate speaking the audition line and prepend it
    /// to the candidate list. Each call is a genuinely different voice — that's the
    /// point: design has no stable identity, so you audition several and pick one.
    func generateFoundryCandidate() async {
        foundryError = nil
        let designBackend = BackendID.qwenDesign
        let instruct = foundryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruct.isEmpty else { foundryError = "Describe the voice first."; return }
        let line = foundryAuditionLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { foundryError = "Add an audition line for the voice to speak."; return }
        switch downloads.state(for: designBackend) {
        case .ready: break
        case .notDownloaded:
            downloads.download(designBackend)
            foundryError = "Downloading qwen3-design… press Generate again once it's ready "
                + "(progress is in the toolbar)."
            return
        case .downloading:
            foundryError = "qwen3-design is still downloading — try again once it's ready."
            return
        case .failed(let message):
            foundryError = "qwen3-design download failed: \(message)"
            return
        }
        foundryGenerating = true
        defer { foundryGenerating = false }
        do {
            let request = SynthesisRequest(
                text: line, emotion: .neutral, instruct: instruct,
                language: foundryLanguage == "auto" ? nil : foundryLanguage)
            let raw = try await engine.synthesize(backend: designBackend, request: request)
            let samples = AudioAssembler.normalizePeak(floats: raw.samples)
            let wav = WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: raw.sampleRate)
            let seconds = Double(samples.count) / Double(raw.sampleRate)
            let resolvedLanguage = foundryLanguage == "auto" ? nil : foundryLanguage
            let entry = try foundryCandidateStore.save(
                wav: wav, description: instruct, auditionLine: line, language: resolvedLanguage,
                sampleRate: raw.sampleRate, seconds: seconds, wallSeconds: raw.wallSeconds)
            foundryCandidates.insert(
                FoundryCandidate(id: entry.id, wavData: wav, sampleRate: raw.sampleRate,
                                  seconds: seconds, wallSeconds: raw.wallSeconds,
                                  description: instruct, auditionLine: line, language: resolvedLanguage),
                at: 0)
            if foundryCandidates.count > foundryCandidateRetentionCap {
                foundryCandidates.removeLast(foundryCandidates.count - foundryCandidateRetentionCap)
            }
            await refreshEngineStatus()
        } catch {
            foundryError = describeAny(error)
        }
    }

    /// Save a candidate as a Library voice: its audio becomes ref.wav and the exact
    /// audition line becomes refText, so it clones cleanly. Throws on slug collision.
    /// Uses the candidate's OWN audition line (not the possibly-since-edited live
    /// field) so saving an older candidate still matches what it actually said.
    @discardableResult
    func saveFoundryVoice(_ candidate: FoundryCandidate, name: String) throws -> VoiceMeta {
        let meta = try voices.save(name: name, refWav: candidate.wavData, refText: candidate.auditionLine)
        voicesVersion += 1
        selectedVoiceSlug = meta.slug
        lastSavedFoundrySlug = meta.slug
        return meta
    }

    /// Neutral carrier line spoken by every baked emotion variant. Deliberately
    /// distinct from any voice's reference transcript: cloning a voice while
    /// generating its own transcript makes Fish reproduce the neutral reference
    /// delivery and swamps the `[marker]` (proven in Phase 0). A different line lets
    /// the emotion actually render.
    static let bakeCarrierLine =
        "Let me read you a short line so you can hear how this voice sounds."

    /// Bake acted expression variants of a saved voice by cloning its base clip
    /// through Fish with each emotion's inline `[marker]` — Fish's real emotion
    /// mechanism (temperature/exaggeration produce near-identical takes). Saved as
    /// `<slug>-<expression>` so any backend can clone the acted performance.
    func bakeExpressionVariants(baseSlug: String, expressions: [VoiceExpression],
                                baker: BackendID) async {
        foundryError = nil
        guard let (meta, refURL) = try? voices.get(baseSlug) else {
            foundryError = "Base voice '\(baseSlug)' is missing."; return
        }
        if baker.spec.needsLicenseAck && !didAckFishLicense {
            foundryError = "Baking with \(baker.rawValue) needs its license — acknowledge it in Settings first."
            return
        }
        guard downloads.state(for: baker) == .ready else {
            if case .notDownloaded = downloads.state(for: baker) { downloads.download(baker) }
            foundryError = "Downloading \(baker.rawValue) to bake with — try again once it's ready."
            return
        }
        foundryBaking = true
        loadedBackend = baker   // reflect the baker as resident while it renders
        defer { foundryBaking = false }
        let text = Self.bakeCarrierLine
        let baseRefText = meta.refText.isEmpty ? nil : meta.refText
        for expr in expressions {
            do {
                // Fish renders the emotion from a leading [marker] (a control, not
                // spoken) — injected by the planner from `emotionMarker`. We clone the
                // base voice (refURL/baseRefText) but SPEAK the neutral carrier line,
                // so the marker isn't swamped by the reference's own delivery.
                // Chatterbox has no markers, so fall back to its exaggeration
                // intensity — cruder, but works for users who can't run Fish.
                let request: SynthesisRequest = baker == .fishS2Pro
                    ? SynthesisRequest(text: text, refAudioPath: refURL.path,
                                       refText: baseRefText, emotionMarker: expr.rawValue)
                    : SynthesisRequest(text: text, refAudioPath: refURL.path,
                                       refText: baseRefText,
                                       exaggerationOverride: expr.chatterboxExaggeration)
                let raw = try await engine.synthesize(backend: baker, request: request)
                let samples = AudioAssembler.normalizePeak(floats: raw.samples)
                let wav = WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: raw.sampleRate)
                try voices.saveAt(slug: "\(baseSlug)-\(expr.rawValue)",
                                  name: "\(meta.name) (\(expr.label))", refWav: wav, refText: text)
                await refreshEngineStatus()   // model resident now — update the RAM chip
            } catch {
                foundryError = "Bake failed for \(expr.label): \(describeAny(error))"
                break
            }
        }
        voicesVersion += 1
        await refreshEngineStatus()   // the baker is resident — confirm loadedBackend + memGB
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

    /// Serializes server rebuilds: didSet triggers (serverEnabled, chatLLM) can
    /// fire while a previous stop/start is suspended; chaining prevents two
    /// LocalAPIServers from interleaving and leaking a bound instance.
    private func scheduleServerSync() {
        let previous = serverSync
        serverSync = Task { [weak self] in
            await previous?.value
            await self?.performServerSync()
        }
    }

    private func performServerSync() async {
        if serverEnabled {
            // Deps are immutable — rebuild the server when settings change so
            // defaultLLM/defaultBackend stay current.
            await server?.stop()
            server = nil
            server = LocalAPIServer(deps: APIDependencies(
                engine: engine, voices: voices, defaultBackend: backend,
                defaultLLM: downloads.state(for: chatLLM) == .ready ? chatLLM : nil,
                log: apiLog))
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
            guard let self else { return }
            let critical = self.memoryPressureSource?.data.contains(.critical) == true
            let busy = self.isGenerating || self.chat.isStreaming
                || self.chat.speech.isSpeaking || self.chat.isSynthesizing
            AppLog.memory.log(
                "memory pressure \(critical ? "CRITICAL" : "warning", privacy: .public); busy=\(busy); keepResident=\(self.keepModelsResident)")
            guard !busy else { return }
            // Warnings are routine on a busy Mac; evicting on every one makes
            // each chat turn a ~20s cold start (LLM + TTS reload). Keep both
            // models resident unless it's critical or the user opted out.
            guard critical || !self.keepModelsResident else { return }
            AppLog.memory.log("evicting resident models (pressure)")
            let engine = self.engine
            let chatSpeechEngine = self.chatSpeechEngine
            Task {
                await engine.unload()
                await engine.unloadLLM()
                await chatSpeechEngine.unload()
            }
        }
        source.resume()
        memoryPressureSource = source
    }
}
