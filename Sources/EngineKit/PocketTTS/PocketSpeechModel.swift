// PocketSpeechModel.swift
//
// Kyutai Pocket TTS (100M-param CPU TTS with zero-shot voice cloning, CC-BY-4.0
// weights) via sherpa-onnx's offline-TTS C API, so it can be auditioned beside
// LuxTTS / Chatterbox / the rest on one machine.
//
// Why sherpa-onnx instead of driving the raw ONNX graphs like LuxOnnxEngine
// does: Pocket's pipeline is autoregressive — the flow LM threads 18 state
// tensors per step and Mimi's decoder another 56, plus BOS handling, EOS
// sampling off token_scores, and the reference-voice encode. sherpa-onnx
// v1.13.4 ships all of that behind SherpaOnnxOfflineTtsPocketModelConfig, is
// the exact runtime the sibling iOS apps already vendor, and publishes macOS
// binaries. The raw-graph route (Models/pocket-tts/english_2026-04, fetched by
// scripts/fetch-pocket-tts-onnx.sh) stays available as a control for future
// precision comparisons.
//
// Why dlopen instead of linking: the SwiftPM manifest cannot link a fetched,
// gitignored dylib without unsafeFlags, and unsafeFlags would make EngineKit
// unconsumable as a dependency (the iOS app consumes it). So CSherpaOnnx
// vendors only the header (struct layouts), scripts/fetch-pocket-tts.sh drops
// libsherpa-onnx-c-api.dylib next to the model files, and this file resolves
// the five entry points it needs at runtime. A missing dylib is a normal
// "model not fetched" error, not a build break.

import CSherpaOnnx
import Foundation

/// Namespace for the Pocket TTS backend's shared types and file layout.
public enum PocketTTS {
    public enum SynthError: Error, LocalizedError {
        case modelsMissing(String)
        case libraryMissing(String)
        case engineInitFailed(String)
        case emptyAudio
        public var errorDescription: String? {
            switch self {
            case .modelsMissing(let m):
                return "Pocket TTS model files missing: \(m) — download the model in Settings → Models."
            case .libraryMissing(let m):
                return "sherpa-onnx library problem: \(m)"
            case .engineInitFailed(let m): return "sherpa-onnx failed: \(m)"
            case .emptyAudio: return "engine returned no samples"
            }
        }
    }

    /// The dlopen'd runtime, expected beside the model files (its LC_RPATH is
    /// @loader_path, so its bundled libonnxruntime resolves from the same dir).
    public static let libraryFile = "libsherpa-onnx-c-api.dylib"

    /// The dylib shipped inside the app bundle (Contents/Frameworks), signed
    /// with the app. Nil outside an app context (spike CLI, tests) — those
    /// fall back to the copy scripts/fetch-pocket-tts.sh drops in the model dir.
    public static var bundledLibraryURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?
            .appendingPathComponent(libraryFile),
            FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Model members by role, in preference order — the sherpa release tarballs
    /// name quantized graphs `<role>.int8.onnx`, fp32 ones `<role>.onnx`, and
    /// not every role is quantized in every bundle (int8-2026-01-26 ships a
    /// fp32 encoder), so both spellings are accepted per role.
    static let roles: [(role: String, candidates: [String])] = [
        ("lm_flow", ["lm_flow.int8.onnx", "lm_flow.onnx"]),
        ("lm_main", ["lm_main.int8.onnx", "lm_main.onnx"]),
        ("encoder", ["encoder.int8.onnx", "encoder.onnx"]),
        ("decoder", ["decoder.int8.onnx", "decoder.onnx"]),
        ("text_conditioner", ["text_conditioner.int8.onnx", "text_conditioner.onnx"]),
        ("vocab_json", ["vocab.json"]),
        ("token_scores_json", ["token_scores.json"]),
    ]

    static func resolve(role: String, in dir: URL) -> URL? {
        guard let entry = roles.first(where: { $0.role == role }) else { return nil }
        for name in entry.candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// First role with no candidate file in `dir` (the dylib counts as a role —
    /// without it nothing runs); nil when the directory is complete.
    public static func missingModelFile(in dir: URL) -> String? {
        for (role, _) in roles where resolve(role: role, in: dir) == nil { return role }
        if bundledLibraryURL == nil,
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent(libraryFile).path) {
            return libraryFile
        }
        return nil
    }

    /// sherpa-onnx encodes at most this many seconds of reference audio for
    /// Pocket (its own example passes the same cap via `extra`); longer clips
    /// are truncated upstream, so surfacing the cap here keeps expectations
    /// honest rather than silently cloning from a prefix.
    public static let maxReferenceSeconds: Double = 10.0
}

/// Owns strdup'd copies of the strings a sherpa config points at, so the
/// `const char *` fields stay valid across the C call without nesting a dozen
/// `withCString` closures. sherpa copies everything into C++ strings on entry,
/// so freeing on deinit (after the call returns) is safe.
private final class CStringArena {
    private var owned: [UnsafeMutablePointer<CChar>] = []
    func intern(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        owned.append(p)
        return UnsafePointer(p)
    }
    deinit { owned.forEach { free($0) } }
}

/// Drives sherpa-onnx's offline TTS (Pocket family) through dlopen'd C entry
/// points. Thread-safety: sherpa's OfflineTts generate is not documented as
/// reentrant, so all calls serialize on `lock` (GloamEngine serializes anyway;
/// this guards direct users like the spike CLI).
public final class PocketEngine {
    // Handles are intentionally never dlclose'd: ONNX Runtime registers
    // process-lifetime state and one engine per process is the usage model.
    private let tts: OpaquePointer
    public let sampleRate: Int
    private let lock = NSLock()

    private let generateFn: @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<SherpaOnnxGenerationConfig>?,
        SherpaOnnxGeneratedAudioProgressCallbackWithArg?, UnsafeMutableRawPointer?
    ) -> UnsafePointer<SherpaOnnxGeneratedAudio>?
    private let destroyAudioFn: @convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>?) -> Void
    private let destroyTtsFn: @convention(c) (OpaquePointer?) -> Void

    public init(modelDir: URL) throws {
        if let missing = PocketTTS.missingModelFile(in: modelDir) {
            throw PocketTTS.SynthError.modelsMissing(missing)
        }
        let libPath = (PocketTTS.bundledLibraryURL ?? modelDir.appendingPathComponent(PocketTTS.libraryFile)).path
        guard let lib = dlopen(libPath, RTLD_NOW | RTLD_LOCAL) else {
            // Most likely cause on macOS: an invalid code signature (the
            // upstream tarball's libonnxruntime ships with one — dyld SIGKILLs
            // on lazy binding without the fetch script's ad-hoc re-sign).
            let msg = String(cString: dlerror())
            throw PocketTTS.SynthError.libraryMissing(msg)
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let sym = dlsym(lib, name) else {
                throw PocketTTS.SynthError.libraryMissing("missing symbol \(name)")
            }
            return unsafeBitCast(sym, to: T.self)
        }
        let createFn = try symbol(
            "SherpaOnnxCreateOfflineTts",
            as: (@convention(c) (UnsafePointer<SherpaOnnxOfflineTtsConfig>?) -> OpaquePointer?).self)
        let sampleRateFn = try symbol(
            "SherpaOnnxOfflineTtsSampleRate",
            as: (@convention(c) (OpaquePointer?) -> Int32).self)
        generateFn = try symbol(
            "SherpaOnnxOfflineTtsGenerateWithConfig",
            as: (@convention(c) (
                OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<SherpaOnnxGenerationConfig>?,
                SherpaOnnxGeneratedAudioProgressCallbackWithArg?, UnsafeMutableRawPointer?
            ) -> UnsafePointer<SherpaOnnxGeneratedAudio>?).self)
        destroyAudioFn = try symbol(
            "SherpaOnnxDestroyOfflineTtsGeneratedAudio",
            as: (@convention(c) (UnsafePointer<SherpaOnnxGeneratedAudio>?) -> Void).self)
        destroyTtsFn = try symbol(
            "SherpaOnnxDestroyOfflineTts",
            as: (@convention(c) (OpaquePointer?) -> Void).self)

        let arena = CStringArena()
        func path(_ role: String) -> UnsafePointer<CChar> {
            arena.intern(PocketTTS.resolve(role: role, in: modelDir)!.path)
        }
        // Imported C structs zero-initialize by default — the memset(0) the
        // header's usage pattern calls for.
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.pocket.lm_flow = path("lm_flow")
        config.model.pocket.lm_main = path("lm_main")
        config.model.pocket.encoder = path("encoder")
        config.model.pocket.decoder = path("decoder")
        config.model.pocket.text_conditioner = path("text_conditioner")
        config.model.pocket.vocab_json = path("vocab_json")
        config.model.pocket.token_scores_json = path("token_scores_json")
        config.model.num_threads = 4
        config.model.provider = arena.intern("cpu")

        guard let handle = withUnsafePointer(to: &config, { createFn($0) }) else {
            throw PocketTTS.SynthError.engineInitFailed(
                "SherpaOnnxCreateOfflineTts returned NULL for \(modelDir.path)")
        }
        tts = handle
        sampleRate = Int(sampleRateFn(handle))
    }

    deinit { destroyTtsFn(tts) }

    /// One line, one reference. `refSamples` at `refSampleRate` (sherpa
    /// resamples internally); `seed` pins the flow LM's sampling for
    /// reproducible takes.
    public func synthesize(text: String, refSamples: [Float], refSampleRate: Int,
                           refText: String?, seed: UInt64) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let arena = CStringArena()
        var cfg = SherpaOnnxGenerationConfig()
        cfg.speed = 1.0
        cfg.reference_sample_rate = Int32(refSampleRate)
        cfg.reference_audio_len = Int32(refSamples.count)
        if let refText, !refText.isEmpty { cfg.reference_text = arena.intern(refText) }
        cfg.extra = arena.intern(
            "{\"max_reference_audio_len\": \(PocketTTS.maxReferenceSeconds), \"seed\": \(seed)}")

        let audio: UnsafePointer<SherpaOnnxGeneratedAudio>? = refSamples.withUnsafeBufferPointer { buf in
            cfg.reference_audio = buf.baseAddress
            return text.withCString { textPtr in
                withUnsafePointer(to: cfg) { self.generateFn(self.tts, textPtr, $0, nil, nil) }
            }
        }
        guard let audio else {
            throw PocketTTS.SynthError.engineInitFailed("generate returned NULL")
        }
        defer { destroyAudioFn(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let samples = audio.pointee.samples else {
            throw PocketTTS.SynthError.emptyAudio
        }
        return Array(UnsafeBufferPointer(start: samples, count: n))
    }
}

/// SpeechModel adapter so GloamEngine drives Pocket like any other backend.
public final class PocketSpeechModel: SpeechModel, @unchecked Sendable {
    private let engine: PocketEngine
    public var sampleRate: Int { engine.sampleRate }

    public init(modelDir: URL) throws {
        engine = try PocketEngine(modelDir: modelDir)
    }

    public static func load(from dir: URL) throws -> PocketSpeechModel {
        try PocketSpeechModel(modelDir: dir)
    }

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        guard let refPath = request.refAudioPath else {
            throw EngineError.refAudioRequired(.pocketTTS)
        }
        do {
            // Decode via the shared 24 kHz loader (Mimi's native rate, so
            // sherpa's internal resampler is a no-op) — same front door as the
            // LuxTTS ONNX path, so reference handling stays comparable.
            let samples = try LuxOnnx.loadMono24k(URL(fileURLWithPath: refPath))
            // Random per call for take-to-take variety, matching how
            // MLXModelProvider re-seeds MLX's RNG per process; a pinned seed is
            // available on the PocketEngine surface for the spike CLI.
            let seed = UInt64.random(in: 0 ..< 1_000_000)
            return try engine.synthesize(
                text: request.text, refSamples: samples, refSampleRate: LuxOnnx.sampleRate,
                refText: request.refText, seed: seed)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.generationFailed(backend: .pocketTTS, message: "\(error)")
        }
    }
}
