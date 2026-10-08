import CryptoKit
import Foundation
import GVoiceKit
import QwenANE

/// `qwen3-0.6b-ane` / `qwen3-1.7b-ane`: Qwen3-TTS on the Neural Engine (Core ML), no MLX, no GPU. One class for
/// both sizes: the size is whatever the model set's host config says (`QwenANE` reads it), and `backend` only
/// picks the set, the voice folder (`engines/qwen3-0.6b/` or `qwen3-1.7b/`), the cache and the error labels. Every
/// behaviour below (talk sessions, break splitting, streaming, warm-up, the section rule) is shared.
///
/// A Studio voice is a reference clip + its transcript. `QwenVoicePrep` turns that into speech-tokenizer
/// codes and a speaker embedding once and caches them on disk next to the model set
/// (`<Application Support>/GloamVoiceStudio/Cache/qwen3-0.6b-ane/<key>`, keyed by the reference's path;
/// QwenVoicePrep itself re-keys by the audio's sha256, the transcript and its prep version, so an edited
/// reference or transcript is recomputed). Streaming delivers each decoded 0.96 s vocoder chunk as it is
/// ready; see `QwenANEEngine.render(onAudio:)` for what is trimmed (leading silence only, internal pauses
/// are left alone on the stream).
///
/// References: the speech encoder takes at most 40 s (20 s on older model sets; read from the model files). A longer
/// master is never refused and never cut while rendering: its section (`engines/qwen3-0.6b/ref.wav`, its exact
/// transcript and span, the codes computed from it) is chosen once at prep time (`QwenVoicePrep.prepareEngineFolder`)
/// and stored in the voice's pack folder; a render reads the stored folder.
@available(macOS 15.0, iOS 18.0, *)
public final class QwenANESpeechModel: SpeechModel, @unchecked Sendable {
    public let sampleRate = 24000
    public let backend: BackendID
    private let kind: QwenEngineFiles.Kind
    private let engine: QwenANEEngine
    private let modelsDirectory: URL
    private let cacheRoot: URL
    private let queue = DispatchQueue(label: "fm.gloam.qwen-ane.render", qos: .userInitiated)
    private let voiceLock = NSLock()
    private var voices: [String: QwenVoiceFiles] = [:]
    /// Open talk sessions by `ProviderRequest.talkSession` (+ voice + language), most recent last. Only touched
    /// on `queue`, which is serial, so it needs no lock.
    private var talkSessions: [(key: String, session: QwenTalkSession)] = []
    /// How many talk sessions stay open; a chat reply needs one, the rest are stale replies.
    static let maxTalkSessions = 4

    /// Maximum reference length, seconds (the speech encoder's fixed input).
    public static let maxReferenceSeconds = Double(QwenVoicePrep.maxSamples) / 24000

    public static func defaultCacheRoot(appSupport: URL = StoragePaths.appSupport) -> URL {
        defaultCacheRoot(for: .qwen06BANE, appSupport: appSupport)
    }

    public static func defaultCacheRoot(for backend: BackendID, appSupport: URL = StoragePaths.appSupport) -> URL {
        (QwenANEModelSet.of(backend) ?? .qwen06).defaultCacheRoot(appSupport: appSupport)
    }

    /// Loads the Core ML models (seconds; blocks the calling thread, so call it off the main thread).
    public init(modelsDirectory: URL, backend: BackendID = .qwen06BANE, cacheRoot: URL? = nil) throws {
        guard let kind = backend.qwenANEKind else {
            throw EngineError.generationFailed(backend: backend, message: "not a Neural Engine backend")
        }
        self.backend = backend
        self.kind = kind
        self.modelsDirectory = modelsDirectory
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot(for: backend)
        do { engine = try QwenANEEngine(modelsDirectory: modelsDirectory) }
        catch { throw EngineError.generationFailed(backend: backend, message: "loading the model set at \(modelsDirectory.path): \(error)") }
        guard engine.speakerDimension == kind.speakerDimension else {
            throw EngineError.generationFailed(
                backend: backend, message: "the model set at \(modelsDirectory.path) is a \(engine.speakerDimension)-wide talker, not \(backend.rawValue)'s")
        }
        // A/B switch for measurements: GLOAM_QWEN_ANE_PREFIX_CACHE=0 renders every line from row 0 (same audio, slower).
        engine.options.prefixCache = ProcessInfo.processInfo.environment["GLOAM_QWEN_ANE_PREFIX_CACHE"] != "0"
    }

    public static func load(backend: BackendID = .qwen06BANE, cacheRoot: URL? = nil) async throws -> QwenANESpeechModel {
        guard let set = QwenANEModelSet.of(backend) else {
            throw EngineError.generationFailed(backend: backend, message: "not a Neural Engine backend")
        }
        let dir = try set.resolve()
        return try await Task.detached(priority: .utility) {
            try QwenANESpeechModel(modelsDirectory: dir, backend: backend, cacheRoot: cacheRoot)
        }.value
    }

    // MARK: voices

    private func voice(for request: ProviderRequest) throws -> QwenVoiceFiles {
        guard let path = request.refAudioPath else { throw EngineError.refAudioRequired(backend) }
        let text = (request.refText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw EngineError.generationFailed(
                backend: backend,
                message: "this voice has no reference transcript; \(backend.rawValue) clones from audio plus its exact text")
        }
        let refURL = URL(fileURLWithPath: path)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let memoKey = "\(path)|\(mtime)|\(text)|\(request.language ?? "")"
        voiceLock.lock()
        if let hit = voices[memoKey] { voiceLock.unlock(); return hit }
        voiceLock.unlock()

        let prepared = try Self.prepare(reference: refURL, transcript: text, language: request.language,
                                        modelsDirectory: modelsDirectory, cacheRoot: cacheRoot, backend: backend)
        voiceLock.lock()
        if voices.count >= 8 { voices.removeAll() }
        voices[memoKey] = prepared
        voiceLock.unlock()
        return prepared
    }

    /// Reference + transcript -> voice, through the shared folder prep (`QwenVoicePrep.prepareEngineFolder`):
    /// a complete `engines/qwen3-0.6b/` is read as it is; a voice without one (an older pack) gets its
    /// section chosen and stored now, then used. A render never cuts anything itself. Every failure
    /// leaves as an `EngineError`. Runs on the render queue, never the main thread (the recognizer
    /// reports back on the main queue).
    static func prepare(reference refURL: URL, transcript: String, language: String? = nil, modelsDirectory: URL, cacheRoot: URL,
                        backend: BackendID = .qwen06BANE) throws -> QwenVoiceFiles {
        let kind = backend.qwenANEKind ?? .qwen06
        let key = SHA256.hash(data: Data(refURL.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let voiceDir = refURL.deletingLastPathComponent()
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let master = try Data(contentsOf: refURL)
                box.result = .success(try await QwenVoicePrep.prepareEngineFolder(
                    voiceDir: voiceDir, masterWAV: master, transcript: transcript, modelsDirectory: modelsDirectory,
                    cacheDirectory: cacheRoot.appendingPathComponent(key, isDirectory: true),
                    kind: kind, language: language,
                    transcribe: ReferenceSections.sectionTranscriber(language: language)).files)
            } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        switch box.result {
        case .success(let files)?: return files
        case .failure(let error as QwenVoicePrepError)?:
            throw EngineError.generationFailed(backend: backend, message: error.localizedDescription)
        case .failure(let error)?:
            throw EngineError.generationFailed(backend: backend, message: "\(error)")
        case nil:
            throw EngineError.generationFailed(backend: backend, message: "voice prep returned nothing")
        }
    }

    private final class Box: @unchecked Sendable { var result: Result<QwenVoiceFiles, Error>? }

    // MARK: synthesis

    /// Target length of one part of a line too long for one render, in `LongTextChunker`'s deliberately slow
    /// estimate (~10 characters/s): about 160 characters, the part size the radio renders a break in.
    static let partSeconds: Double = 14

    /// The line split into the renders it needs: itself when it fits one render, else sentence groups of about
    /// `partSeconds`. `fits` says whether a text's (slowly estimated) speech fits the frames one render has
    /// left for it; the talker's 1024-row window holds the reference codes too, so that depends on the voice.
    static func parts(_ text: String, fits: (String) -> Bool) -> [String] {
        if fits(text) { return [text] }
        let pieces = LongTextChunker.chunks(text, maxSeconds: partSeconds)
        return pieces.isEmpty ? [text] : pieces
    }

    private func parts(of text: String, voice: QwenVoiceFiles, language: String?) -> [String] {
        Self.parts(text) { t in
            guard let cap = try? engine.maxFrames(text: t, voice: voice, language: language) else { return true }
            return LongTextChunker.estimatedSeconds(t) * 12.5 <= Double(cap)    // 12.5 codec frames per second
        }
    }

    /// One performance for a split line (`QwenTalkSession`): one sampler stream, each part conditioned on the
    /// one before it. A random seed unless the request fixes one, so Regenerate still gives a new take.
    static func session(engine: QwenANEEngine, voice: QwenVoiceFiles, language: String?, seed: UInt64?) -> QwenTalkSession {
        QwenTalkSession(engine: engine, voice: voice, language: language,
                        seed: seed ?? QwenReadRules.randomSeed())
    }

    /// The silence between parts: the pass gap every engine's split line uses.
    static var gapSeconds: Double { Double(GloamEngine.passGap(sampleRate: 24000).count) / 24000 }

    private func log(_ part: QwenBreakPart) { NSLog("%@: %@", backend.rawValue, part.logLine) }

    /// The session a request continues, when it names one: the same key, voice and language reuse it (one
    /// sampler stream, each call carrying on from the last), anything else opens a new one with the request's
    /// seed or a random one. Call on `queue` only.
    private func talkSession(for request: ProviderRequest, voice: QwenVoiceFiles) -> QwenTalkSession? {
        guard let name = request.talkSession else { return nil }
        let key = Self.talkSessionKey(name: name, request: request)
        if let i = talkSessions.firstIndex(where: { $0.key == key }) {
            let hit = talkSessions.remove(at: i)
            talkSessions.append(hit)
            return hit.session
        }
        let session = Self.session(engine: engine, voice: voice, language: request.language, seed: request.seed)
        talkSessions.append((key, session))
        if talkSessions.count > Self.maxTalkSessions { talkSessions.removeFirst(talkSessions.count - Self.maxTalkSessions) }
        return session
    }

    /// A session belongs to one voice and language: the same name with another voice is another session.
    static func talkSessionKey(name: String, request: ProviderRequest) -> String {
        [name, request.refAudioPath ?? "", request.refText ?? "", request.language ?? ""].joined(separator: "\u{1F}")
    }

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        let voice = try voice(for: request)
        let text = request.text
        let language = request.language
        let engine = engine
        let seed = request.seed
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                do {
                    let parts = parts(of: text, voice: voice, language: language)
                    if let session = talkSession(for: request, voice: voice) {
                        let b = try session.renderBreak(parts: parts, gapSeconds: Self.gapSeconds, onPart: log)
                        cont.resume(returning: b.samples)
                        return
                    }
                    if parts.count == 1 {
                        let r = try engine.render(text: text, voice: voice, language: language)
                        cont.resume(returning: r.samples)
                        return
                    }
                    let session = Self.session(engine: engine, voice: voice, language: language, seed: seed)
                    let b = try session.renderBreak(parts: parts, gapSeconds: Self.gapSeconds, onPart: log)
                    cont.resume(returning: b.samples)
                } catch {
                    cont.resume(throwing: EngineError.generationFailed(backend: backend, message: "\(error)"))
                }
            }
        }
    }

    /// Prepares the request's voice (reference encoding, cached on disk), the engine's per-voice prompt rows,
    /// talker KV prefix and vocoder priming, and runs three frames through every Core ML function, so the
    /// first real line of the voice skips all of it. A request without a reference voice has nothing to prepare.
    public func warm(_ request: ProviderRequest) async throws {
        guard request.refAudioPath != nil else { return }
        let stopped = StopFlag()
        let engine = engine
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        if stopped.value { cont.resume(returning: ()); return }
                        let voice = try voice(for: request)
                        try engine.warm(voice: voice, cancelled: { stopped.value })
                        cont.resume(returning: ())
                    } catch let e as EngineError {
                        cont.resume(throwing: e)
                    } catch {
                        cont.resume(throwing: EngineError.generationFailed(backend: backend, message: "\(error)"))
                    }
                }
            }
        } onCancel: { stopped.set() }
    }

    public func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let stopped = StopFlag()
            continuation.onTermination = { _ in stopped.set() }
            let engine = engine
            let text = request.text
            let language = request.language
            let seed = request.seed
            // [n, 2n, 12]: a short first chunk that grows back to whole chunks
            let schedule: [Int]? = request.firstChunkFrames.map { n in n >= 12 ? [12] : [n, min(12, 2 * n), 12] }
            // Voice prep can be slow on a voice's first line (encoders on the CPU), so it runs on the queue
            // too, and an error there reaches the consumer before any audio.
            queue.async { [self] in
                do {
                    let voice = try voice(for: request)
                    let parts = parts(of: text, voice: voice, language: language)
                    if let session = talkSession(for: request, voice: voice) {
                        // A line of a longer performance (a chat reply): it carries on from the session's last
                        // line. Streamed, so no redraw.
                        _ = try session.renderBreak(parts: parts, gapSeconds: Self.gapSeconds, firstChunkFrames: schedule,
                                                    cancelled: { stopped.value }, onAudio: { continuation.yield($0) },
                                                    onPart: log)
                    } else if parts.count == 1 {
                        let r = try engine.render(text: text, voice: voice, chunkFrames: schedule, language: language,
                                                  cancelled: { stopped.value }, onAudio: { continuation.yield($0) })
                        if r.stopReason == .contextFull {
                            NSLog("\(backend.rawValue): line hit the 1024-row talker window and was cut short: \(text.prefix(60))")
                        }
                    } else {
                        // Streamed parts cannot be redrawn (their chunks are already out), but they still share
                        // one sampler stream and each continues the one before it.
                        let session = Self.session(engine: engine, voice: voice, language: language, seed: seed)
                        _ = try session.renderBreak(parts: parts, gapSeconds: Self.gapSeconds, firstChunkFrames: schedule,
                                                    cancelled: { stopped.value }, onAudio: { continuation.yield($0) },
                                                    onPart: log)
                    }
                    continuation.finish()
                } catch let e as EngineError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(backend: backend, message: "\(error)"))
                }
            }
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
