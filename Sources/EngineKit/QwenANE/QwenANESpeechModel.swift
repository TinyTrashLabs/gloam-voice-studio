import CryptoKit
import Foundation
import GVoiceKit
import QwenANE

/// `qwen3-0.6b-ane`: Qwen3-TTS 0.6B on the Neural Engine (Core ML), no MLX, no GPU.
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
/// master is never refused: the voice's own `lux-tts` window (`engines/lux-tts/ref.wav` + the transcript of that
/// window) is used when it fits, otherwise `LuxReferenceWindow.pick` cuts one (first speech to a pause, at most 30 s)
/// and its transcript comes from the window itself. The audio is never cut without a matching transcript.
@available(macOS 15.0, iOS 18.0, *)
public final class QwenANESpeechModel: SpeechModel, @unchecked Sendable {
    public let sampleRate = 24000
    private let engine: QwenANEEngine
    private let modelsDirectory: URL
    private let cacheRoot: URL
    private let queue = DispatchQueue(label: "fm.gloam.qwen-ane.render", qos: .userInitiated)
    private let voiceLock = NSLock()
    private var voices: [String: QwenVoiceFiles] = [:]

    /// Maximum reference length, seconds (the speech encoder's fixed input).
    public static let maxReferenceSeconds = Double(QwenVoicePrep.maxSamples) / 24000

    public static func defaultCacheRoot(appSupport: URL = StoragePaths.appSupport) -> URL {
        appSupport.appendingPathComponent("GloamVoiceStudio/Cache/\(QwenANEModelLocation.folderName)", isDirectory: true)
    }

    /// Loads the Core ML models (seconds; blocks the calling thread, so call it off the main thread).
    public init(modelsDirectory: URL, cacheRoot: URL = QwenANESpeechModel.defaultCacheRoot()) throws {
        self.modelsDirectory = modelsDirectory
        self.cacheRoot = cacheRoot
        do { engine = try QwenANEEngine(modelsDirectory: modelsDirectory) }
        catch { throw EngineError.generationFailed(backend: .qwen06BANE, message: "loading the model set at \(modelsDirectory.path): \(error)") }
        // A/B switch for measurements: GLOAM_QWEN_ANE_PREFIX_CACHE=0 renders every line from row 0 (same audio, slower).
        engine.options.prefixCache = ProcessInfo.processInfo.environment["GLOAM_QWEN_ANE_PREFIX_CACHE"] != "0"
    }

    public static func load(cacheRoot: URL = QwenANESpeechModel.defaultCacheRoot()) async throws -> QwenANESpeechModel {
        let dir = try QwenANEModelLocation.resolve()
        return try await Task.detached(priority: .utility) {
            try QwenANESpeechModel(modelsDirectory: dir, cacheRoot: cacheRoot)
        }.value
    }

    // MARK: voices

    private func voice(for request: ProviderRequest) throws -> QwenVoiceFiles {
        guard let path = request.refAudioPath else { throw EngineError.refAudioRequired(.qwen06BANE) }
        let text = (request.refText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw EngineError.generationFailed(
                backend: .qwen06BANE,
                message: "this voice has no reference transcript; qwen3-0.6b-ane clones from audio plus its exact text")
        }
        let refURL = URL(fileURLWithPath: path)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let memoKey = "\(path)|\(mtime)|\(text)"
        voiceLock.lock()
        if let hit = voices[memoKey] { voiceLock.unlock(); return hit }
        voiceLock.unlock()

        let prepared = try Self.prepare(reference: refURL, transcript: text, modelsDirectory: modelsDirectory, cacheRoot: cacheRoot)
        voiceLock.lock()
        if voices.count >= 8 { voices.removeAll() }
        voices[memoKey] = prepared
        voiceLock.unlock()
        return prepared
    }

    /// Reference + transcript -> voice, windowing a reference longer than the encoder takes (`prepareWindow`).
    /// Every failure leaves as an `EngineError`.
    static func prepare(reference refURL: URL, transcript: String, modelsDirectory: URL, cacheRoot: URL) throws -> QwenVoiceFiles {
        // The voice folder's own `engines/qwen3-0.6b/` (docs/gvoice-format.md): a pack that carried a
        // prepared voice lands here on import, and a voice prepared on this Mac is written back so the
        // next export carries it. Used only when it matches the audio about to be prepared.
        let voiceDir = refURL.deletingLastPathComponent()
        func prep(_ url: URL, _ text: String, audioMember: String, store: Bool) throws -> QwenVoiceFiles {
            let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let wav = try Data(contentsOf: url)
            let r = try QwenVoicePrep.prepared(fromPack: Self.storedPackFiles(in: voiceDir), referenceWAV: wav, transcript: text,
                                               cacheDirectory: cacheRoot.appendingPathComponent(key, isDirectory: true),
                                               modelsDirectory: modelsDirectory)
            if r.origin == .computed, store { Self.storePackFiles(r, audio: audioMember, in: voiceDir) }
            return r.files
        }
        do {
            do {
                return try prep(refURL, transcript, audioMember: "source/ref.wav", store: true)
            } catch QwenVoicePrepError.referenceTooLong {
                return try prepareWindow(of: refURL, transcript: transcript, modelsDirectory: modelsDirectory,
                                         cacheRoot: cacheRoot, prep: prep)
            }
        } catch let error as QwenVoicePrepError {
            throw EngineError.generationFailed(backend: .qwen06BANE, message: error.localizedDescription)
        }
    }

    /// A master longer than the encoder takes: the section of it the encoder can hold, with its own transcript.
    /// The voice's stored `lux-tts` window when it fits; otherwise a freshly cut one, kept as the voice's window
    /// when it is a transcription of the cut (the same window LuxTTS would pick), or in the cache when its
    /// transcript is only a slice of the master's.
    private static func prepareWindow(
        of refURL: URL, transcript: String, modelsDirectory: URL, cacheRoot: URL,
        prep: (URL, String, String, Bool) throws -> QwenVoiceFiles
    ) throws -> QwenVoiceFiles {
        let voiceDir = refURL.deletingLastPathComponent()
        let limitSeconds = Double(QwenVoicePrep.encoderLimitSamples(modelsDirectory: modelsDirectory)) / 24000
        let stored = LuxReferenceWindow.storedRendition(forReference: refURL)
        if let window = stored {
            let windowURL = voiceDir.appendingPathComponent("engines/lux-tts")
                .appendingPathComponent((window.audio as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: windowURL.path) {
                do { return try prep(windowURL, window.text, "engines/lux-tts/" + windowURL.lastPathComponent, true) }
                catch QwenVoicePrepError.referenceTooLong {}   // a 30 s lux window on a 20 s encoder: cut a shorter one
            }
        }
        let maxSeconds = min(limitSeconds, LuxReferenceWindow.maxSeconds)
        let master = try LuxOnnx.loadMono24k(refURL)
        guard let window = pickBlocking(samples: master, refText: transcript, maxSeconds: maxSeconds) else {
            throw EngineError.generationFailed(backend: .qwen06BANE, message: "no reference window could be cut")
        }
        if !window.approximate, stored == nil, maxSeconds == LuxReferenceWindow.maxSeconds {
            LuxReferenceWindow.store(window, forReference: refURL, sampleRate: 24000)
            let name = LuxReferenceWindow.renditionAudioName
            return try prep(voiceDir.appendingPathComponent("engines/lux-tts").appendingPathComponent(name),
                            window.text, "engines/lux-tts/" + name, true)
        }
        let key = SHA256.hash(data: Data(refURL.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let windows = cacheRoot.appendingPathComponent("windows", isDirectory: true)
        try? FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        let url = windows.appendingPathComponent("\(key).wav")
        try WAVWriter.write(samples: window.samples, sampleRate: 24000, to: url)
        return try prep(url, window.text, "engines/lux-tts/ref.wav", false)
    }

    /// `LuxReferenceWindow.pick` is async (an on-device recognition pass); voice prep runs on the render queue,
    /// a private serial queue that nothing in the pick waits on, so it can block here. (Never call this on the
    /// main thread: the recognizer reports back on the main queue.)
    private static func pickBlocking(samples: [Float], refText: String, maxSeconds: Double) -> LuxReferenceWindow.Window? {
        final class Box: @unchecked Sendable { var value: LuxReferenceWindow.Window? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await LuxReferenceWindow.pick(samples: samples, sampleRate: 24000, refText: refText, maxSeconds: maxSeconds)
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// The voice folder's `engines/qwen3-0.6b/` files, or nil when absent or unusable (the caller then
    /// prepares as usual).
    static func storedPackFiles(in voiceDir: URL) -> QwenEngineFiles? {
        let dir = voiceDir.appendingPathComponent(QwenEngineFiles.directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var files: [String: Data] = [:]
        for n in names {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)), d.count <= QwenEngineFiles.maxNPYBytes else { continue }
            files[n] = d
        }
        return try? QwenEngineFiles.decode(files: files)
    }

    /// Writes a freshly computed voice next to the reference so exports include it. Best effort, and
    /// base voices only: a take's files carry a `-<key>` suffix on export that this plain layout does not.
    static func storePackFiles(_ r: QwenVoicePrep.Prepared, audio: String, in voiceDir: URL) {
        guard !voiceDir.pathComponents.contains("variants"),
              let payload = try? r.enginePayload(audio: audio), let files = try? payload.files() else { return }
        let dir = voiceDir.appendingPathComponent(QwenEngineFiles.directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // voice.json is the commit marker: gone first, written last.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(QwenEngineFiles.voiceFile))
        for (name, data) in files where name != QwenEngineFiles.voiceFile {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        if let voice = files[QwenEngineFiles.voiceFile] {
            try? voice.write(to: dir.appendingPathComponent(QwenEngineFiles.voiceFile), options: .atomic)
        }
    }

    // MARK: synthesis

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        let voice = try voice(for: request)
        let text = request.text
        let engine = engine
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try engine.render(text: text, voice: voice)
                    cont.resume(returning: r.samples)
                } catch {
                    cont.resume(throwing: EngineError.generationFailed(backend: .qwen06BANE, message: "\(error)"))
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
                        cont.resume(throwing: EngineError.generationFailed(backend: .qwen06BANE, message: "\(error)"))
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
            // [n, 2n, 12]: a short first chunk that grows back to whole chunks
            let schedule: [Int]? = request.firstChunkFrames.map { n in n >= 12 ? [12] : [n, min(12, 2 * n), 12] }
            // Voice prep can be slow on a voice's first line (encoders on the CPU), so it runs on the queue
            // too, and an error there reaches the consumer before any audio.
            queue.async { [self] in
                do {
                    let voice = try voice(for: request)
                    let r = try engine.render(text: text, voice: voice, chunkFrames: schedule,
                                              cancelled: { stopped.value }, onAudio: { continuation.yield($0) })
                    if r.stopReason == .contextFull {
                        NSLog("qwen3-0.6b-ane: line hit the 1024-row talker window and was cut short: \(text.prefix(60))")
                    }
                    continuation.finish()
                } catch let e as EngineError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(backend: .qwen06BANE, message: "\(error)"))
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
