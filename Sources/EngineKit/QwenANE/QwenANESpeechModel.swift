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
/// master is never refused and never cut while rendering: its section (`engines/qwen3-0.6b/ref.wav`, its exact
/// transcript and span, the codes computed from it) is chosen once at prep time (`QwenVoicePrep.prepareEngineFolder`)
/// and stored in the voice's pack folder; a render reads the stored folder.
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

    /// Reference + transcript -> voice, through the shared folder prep (`QwenVoicePrep.prepareEngineFolder`):
    /// a complete `engines/qwen3-0.6b/` is read as it is; a voice without one (an older pack) gets its
    /// section chosen and stored now, then used. A render never cuts anything itself. Every failure
    /// leaves as an `EngineError`. Runs on the render queue, never the main thread (the recognizer
    /// reports back on the main queue).
    static func prepare(reference refURL: URL, transcript: String, modelsDirectory: URL, cacheRoot: URL) throws -> QwenVoiceFiles {
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
                    transcribe: ReferenceSections.sectionTranscriber(language: nil)).files)
            } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        switch box.result {
        case .success(let files)?: return files
        case .failure(let error as QwenVoicePrepError)?:
            throw EngineError.generationFailed(backend: .qwen06BANE, message: error.localizedDescription)
        case .failure(let error)?:
            throw EngineError.generationFailed(backend: .qwen06BANE, message: "\(error)")
        case nil:
            throw EngineError.generationFailed(backend: .qwen06BANE, message: "voice prep returned nothing")
        }
    }

    private final class Box: @unchecked Sendable { var result: Result<QwenVoiceFiles, Error>? }

    // MARK: synthesis

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        let voice = try voice(for: request)
        let text = request.text
        let language = request.language
        let engine = engine
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let r = try engine.render(text: text, voice: voice, language: language)
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
            let language = request.language
            // [n, 2n, 12]: a short first chunk that grows back to whole chunks
            let schedule: [Int]? = request.firstChunkFrames.map { n in n >= 12 ? [12] : [n, min(12, 2 * n), 12] }
            // Voice prep can be slow on a voice's first line (encoders on the CPU), so it runs on the queue
            // too, and an error there reaches the consumer before any audio.
            queue.async { [self] in
                do {
                    let voice = try voice(for: request)
                    let r = try engine.render(text: text, voice: voice, chunkFrames: schedule, language: language,
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
