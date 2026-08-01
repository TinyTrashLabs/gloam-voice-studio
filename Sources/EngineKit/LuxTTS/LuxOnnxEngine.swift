// LuxOnnxEngine.swift
//
// LuxTTS on ONNX Runtime (CPU), so this repo can run the SAME int8 graphs the
// iOS apps ship — gloam-voice-studio-ios and gloam-dj — beside the native MLX
// implementation in LuxModel/LuxSolver/LuxVocoder.
//
// The point is comparison. MLX here runs fp32 weights converted by
// convert_weights.py; iOS runs `text_encoder_int8.onnx` + `fm_decoder_int8.onnx`
// + `vocos.onnx` on CPU, because iOS forbids GPU submission while backgrounded
// and an MLX synth on a locked screen crashes an audio app. Those are different
// engines at different precisions, and until now there was no way to hear them
// on one machine against one reference.
//
// Ported from gloam-dj's App/LuxOnnx.swift. Two deliberate differences: the
// model directory is passed in rather than read from Bundle.main, and
// tokenization is NOT included — callers supply token ids, so this can share
// LuxTokenizer with the MLX path and leave the engine as the only variable.
//
// Pipeline (luxtts-onnx `LuxTTSOnnx.generate`): text_encoder -> fm_decoder ODE
// loop -> vocos, with the dual-path 48 kHz + 24 kHz Linkwitz-Riley merge in
// vDSP.

import Accelerate
import AVFoundation
import Foundation
// ORT is a macOS-only dependency here — see Package.swift. iOS consumers of
// EngineKit vendor their own ONNX Runtime and must not pull in a second.
// COnnxRuntime is the header-only C API surface; the binary framework is
// still linked through the "onnxruntime" SwiftPM product.
#if os(macOS)
import COnnxRuntime
#endif

/// Namespace for the ONNX LuxTTS path's shared types.
public enum LuxOnnx {
    /// Reference-voice encoding. NOT a single vector: the decoder conditions on
    /// the reference's phoneme ids + log-mel frames + RMS.
    public struct Prompt: Sendable, Hashable {
        public let tokens: [Int64]     // phoneme ids of the reference transcript
        public let features: [Float]   // [frames * 100] log-mel * 0.1, row-major (t, mel)
        public let frames: Int
        public let rms: Float          // pre-normalization RMS, for output volume matching

        public init(tokens: [Int64], features: [Float], frames: Int, rms: Float) {
            self.tokens = tokens; self.features = features
            self.frames = frames; self.rms = rms
        }
    }

    public enum SynthError: Error, LocalizedError {
        case modelsMissing(String)
        case engineInitFailed(String)
        case emptyText
        case badPrompt(String)
        case referenceTooLong(Double)
        case emptyAudio
        public var errorDescription: String? {
            switch self {
            case .modelsMissing(let m): return "LuxTTS ONNX models missing: \(m)"
            case .engineInitFailed(let m): return "ONNX Runtime failed: \(m)"
            case .emptyText: return "no tokenizable text"
            case .badPrompt(let m): return "bad LuxTTS voice prompt: \(m)"
            case .referenceTooLong(let s):
                return String(format: "Reference clip is %.0fs — keep it under %.0fs.",
                              s, LuxOnnx.maxReferenceSeconds)
            case .emptyAudio: return "engine returned no samples"
            }
        }
    }

    /// Files the ONNX path needs in its model directory.
    /// Files that must be present whatever precision the graphs were exported
    /// at. The two model stems are resolved separately — see `modelFile`.
    public static let requiredFiles = ["vocos.onnx"]
    public static let modelStems = ["text_encoder", "fm_decoder"]

    /// fp32 first, then int8. The iOS app ships fp32 (`text_encoder.onnx`) and
    /// this repo previously demanded the int8 names, so pointing the bench at
    /// the app's own weights failed with "models missing" — the one comparison
    /// the bench exists to make.
    public static func modelFile(_ stem: String, in dir: URL) -> String? {
        for name in ["\(stem).onnx", "\(stem)_int8.onnx"]
        where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            return name
        }
        return nil
    }

    /// First required file missing from `dir`; nil when complete.
    public static func missingModelFile(in dir: URL) -> String? {
        for f in requiredFiles
        where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
            return f
        }
        for stem in modelStems where modelFile(stem, in: dir) == nil {
            return "\(stem).onnx"
        }
        return nil
    }

    /// Converts a user-facing pace into the `speed` the graph wants.
    ///
    /// The text encoder sizes the WHOLE sequence:
    ///     F = promptFrames/promptTokens × (promptTokens + textTokens) / speed
    /// and the audio you hear is what is left after the prompt region:
    ///     generated = F − promptFrames
    ///
    /// So `speed` divides the prompt region too, and the entire reduction lands
    /// on the generated part. With a 28.5s reference that is a 3.3× lever:
    /// asking for 1.08 produced audio 24% shorter, and 1.25 produced 65%
    /// shorter — a Pace slider built on this would mean something different for
    /// every voice, because the leverage grows with reference length.
    ///
    /// Note generated(1.0) = ratio × textTokens exactly (the ratio × promptTokens
    /// term IS promptFrames and cancels). So for a target of `pace`× faster:
    ///     want   = ratio × textTokens / pace
    ///     speed  = (promptFrames + ratio × textTokens) / (promptFrames + want)
    /// which is what this returns. pace 1.10 then means 10% shorter output for
    /// any voice, any reference length.
    static func graphSpeed(pace: Float, promptFrames: Int, promptTokens: Int, textTokens: Int) -> Float {
        guard pace > 0, promptFrames > 0, promptTokens > 0, textTokens > 0 else { return pace }
        let ratio = Float(promptFrames) / Float(promptTokens)
        let generated = ratio * Float(textTokens)
        let want = generated / pace
        guard want > 0 else { return pace }
        let raw = (Float(promptFrames) + generated) / (Float(promptFrames) + want)
        // Clamp what the GRAPH sees, not what the user asks for. The flow
        // matcher slurs past roughly 1.25 here, and that limit is a property of
        // the model — whereas the pace a given limit corresponds to depends on
        // reference length. Clamping the graph keeps every voice clean while
        // letting the pace control stay linear and generous.
        return min(1.18, max(0.75, raw))
    }

    /// Longest reference clip we will encode. NOT a truncation point: truncating
    /// audio while keeping the whole transcript makes the text encoder think the
    /// reference held more speech than it could hear, and every line comes out
    /// rushed.
    public static let maxReferenceSeconds: Double = 30.0

    /// The rate LuxTTS's mel front end works at.
    public static var sampleRate: Int { LuxMel.sampleRate }

    /// Decode any audio file to mono float at 24 kHz. The ONNX path carries no
    /// MLX dependency, so it cannot borrow MLXAudioCore's loader.
    public static func loadMono24k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(LuxMel.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw SynthError.badPrompt("\(url.lastPathComponent): unsupported audio format") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(file.length) * ratio).rounded(.up)) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SynthError.badPrompt("\(url.lastPathComponent): could not allocate output")
        }
        var readError: Error?
        var convertError: NSError?
        // Bounded by framePosition: reading past the end throws a bridged nil
        // NSError rather than returning zero frames, which is indistinguishable
        // from a real decode failure.
        let status = converter.convert(to: out, error: &convertError) { want, outStatus in
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { outStatus.pointee = .endOfStream; return nil }
            let n = AVAudioFrameCount(min(Int64(max(want, 4096)), remaining))
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else {
                outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: chunk, frameCount: n) } catch {
                readError = error; outStatus.pointee = .endOfStream; return nil
            }
            outStatus.pointee = .haveData
            return chunk
        }
        if let readError { throw readError }
        if let convertError { throw convertError }
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData else {
            throw SynthError.badPrompt("\(url.lastPathComponent): decoded to no audio")
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Encode a 24 kHz mono reference plus the token ids of its transcript into a
    /// reusable prompt. Pure mel + arithmetic; no ORT session runs.
    ///
    /// Tokens are supplied rather than derived so this shares LuxTokenizer with
    /// the MLX path — the whole point being to compare engines, not phonemizers.
    public static func encodePrompt(samples24k: [Float], tokens: [Int64]) throws -> Prompt {
        var audio = samples24k
        guard !audio.isEmpty else { throw SynthError.badPrompt("empty reference audio") }
        guard !tokens.isEmpty else { throw SynthError.emptyText }
        audio = LuxMel.trimAndFade(audio)
        audio = LuxMel.removeDC(audio)
        let seconds = Double(audio.count) / Double(LuxMel.sampleRate)
        guard seconds <= maxReferenceSeconds else { throw SynthError.referenceTooLong(seconds) }
        let (normed, rms) = LuxMel.rmsNormUp(audio)
        let (mel, T) = LuxMel.features(normed)
        return Prompt(tokens: tokens, features: mel, frames: T, rms: rms)
    }
}



/// Drives the three LuxTTS graphs through ONNX Runtime's **C** API — the same
/// surface gloam-dj and gloam-voice-studio-ios use via their vendored
/// xcframeworks. This used to go through the SwiftPM Objective-C wrapper, but
/// that surface hides every memory-lifecycle knob (DisableCpuMemArena,
/// DisableMemPattern, RunOptions arena shrinkage), and the arena's default
/// kNextPowerOfTwo growth took a single 12.6 s render to a **4.35 GB** peak
/// RSS — the same behavior that jetsam-killed the iOS app at 3.4 GB. The C
/// header is vendored in COnnxRuntime; the framework linked is unchanged.
/// Same runtime, same graphs, same CPU execution provider, and the arithmetic
/// below is byte-for-byte the iOS port's.
#if os(macOS)
public final class LuxEngine {
    let api: OrtApi
    private var env: OpaquePointer?
    private var allocator: UnsafeMutablePointer<OrtAllocator>?
    /// Kept alive for the session lifetime (one options object per role).
    private var optionsPool: [OpaquePointer] = []
    private var textEncoder: OpaquePointer?
    private var fmDecoder: OpaquePointer?
    private var vocos: OpaquePointer?
    private var teIn: [String] = [], teOut: [String] = []
    private var fmIn: [String] = [], fmOut: [String] = []
    private var voIn: [String] = [], voOut: [String] = []
    let featDim: Int

    /// Very short text can predict fewer total frames than the prompt occupies;
    /// edge-pad so generation is non-empty (same guard as the Python port).
    static let minGenFrames = 16
    /// Reference level the output is matched back down to when the reference
    /// itself was quieter than this.
    static let targetRMS: Float = 0.1

    public init(modelDir: URL) throws {
        if let missing = LuxOnnx.missingModelFile(in: modelDir) {
            throw LuxOnnx.SynthError.modelsMissing(missing)
        }
        guard let base = OrtGetApiBase(), let apiPtr = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw LuxOnnx.SynthError.engineInitFailed("OrtGetApiBase/GetApi returned NULL")
        }
        api = apiPtr.pointee
        featDim = LuxMel.nMels
        self.modelDir = modelDir

        try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gloam-lux", &env))
        try check(api.GetAllocatorWithDefaultOptions(&allocator))
        try registerSharedArena()

        // Arena shrinkage after every Run: non-initial arena chunks are
        // returned once a run completes, so memory held between renders is the
        // weights plus the initial chunk, not the largest render ever seen.
        // Allocation lifecycle only — measured bit-identical output.
        try check(api.CreateRunOptions(&runOpts))
        try "cpu:0".withCString { v in
            try "memory.enable_memory_arena_shrinkage".withCString { k in
                try check(api.AddRunConfigEntry(runOpts, k, v))
            }
        }

        textEncoder = try makeSession(modelDir,
            LuxOnnx.modelFile("text_encoder", in: modelDir) ?? "text_encoder.onnx")
        fmDecoder = try makeSession(modelDir,
            LuxOnnx.modelFile("fm_decoder", in: modelDir) ?? "fm_decoder.onnx")
        // vocos is NOT loaded here — see the lazy load in synthesize(). Its
        // weights/prepack buffers (~80 MB) would otherwise sit resident inside
        // the fm_decoder peak window, which is where memory actually runs out.

        // Input order is load-bearing — the graphs are fed positionally below.
        (teIn, teOut) = try ioNames(textEncoder!)
        (fmIn, fmOut) = try ioNames(fmDecoder!)
        guard teIn.count >= 4, fmIn.count >= 5 else {
            throw LuxOnnx.SynthError.engineInitFailed(
                "unexpected session I/O arity (te \(teIn.count) in, fm \(fmIn.count) in)")
        }
    }

    private let modelDir: URL
    /// Run options carrying the arena-shrinkage config; reused for every Run.
    private var runOpts: OpaquePointer?

    /// Bench-only stage timing hook: (stage name, seconds). Pure observation —
    /// when nil (the default, and always in the apps) nothing is measured and
    /// the render path is unchanged. spike's lux-bench sets it to find where a
    /// render's wall time actually goes.
    public var stageLog: ((String, Double) -> Void)?

    @inline(__always)
    private func timed<R>(_ stage: String, _ body: () throws -> R) rethrows -> R {
        guard let stageLog else { return try body() }
        let t0 = DispatchTime.now()
        let r = try body()
        stageLog(stage, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
        return r
    }

    /// One env-level CPU **arena with kSameAsRequested growth**, shared by all
    /// three sessions via `session.use_env_allocators`.
    ///
    /// Why not the default per-session arena: its kNextPowerOfTwo strategy
    /// doubles the chunk size on every extension, so the fm_decoder's ~1.8 GB
    /// of transient attention tensors (F ≈ 3.9k frames off a 28 s reference)
    /// ballooned into 4.35 GB of arena that was never returned. Measured on
    /// the same 12.6 s render: 4.35 GB → 2.55 GB peak RSS, bit-identical
    /// output, same wall time. Why not `DisableCpuMemArena`: per-op malloc
    /// frees land in the macOS malloc large cache, which holds the freed pages
    /// dirty anyway (measured 3.0 GB peak) — an arena we control beats both.
    ///
    /// ORT's env is a process singleton and an allocator can only be
    /// registered on it once; a second LuxEngine in the same process finds it
    /// already registered and that existing arena is exactly what it should
    /// use, so that status is success, not failure.
    private func registerSharedArena() throws {
        var memInfo: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo))
        defer { if let m = memInfo { api.ReleaseMemoryInfo(m) } }
        var arenaCfg: OpaquePointer?
        try "arena_extend_strategy".withCString { key in
            var keyPtrs: [UnsafePointer<CChar>?] = [key]
            var vals: [size_t] = [1]  // kSameAsRequested
            try check(api.CreateArenaCfgV2(&keyPtrs, &vals, 1, &arenaCfg))
        }
        defer { if let c = arenaCfg { api.ReleaseArenaCfg(c) } }
        if let status = api.CreateAndRegisterAllocator(env, memInfo, arenaCfg) {
            let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? ""
            api.ReleaseStatus(status)
            if !message.contains("already registered") {
                throw LuxOnnx.SynthError.engineInitFailed(message)
            }
        }
    }

    private func makeSession(_ dir: URL, _ file: String) throws -> OpaquePointer? {
        var opts: OpaquePointer?
        try check(api.CreateSessionOptions(&opts))
        guard let o = opts else { throw LuxOnnx.SynthError.engineInitFailed("CreateSessionOptions NULL") }
        optionsPool.append(o)
        try check(api.SetSessionGraphOptimizationLevel(o, ORT_ENABLE_ALL))
        // Memory patterns pre-plan one consolidated allocation for a run's
        // whole activation set, which held ~1.3 GB beyond what is ever live at
        // once on this graph (measured 4.35 GB → 3.02 GB from this knob alone,
        // bit-identical). NOTE: SetIntraOpNumThreads and disable_prepacking
        // were both tried here and REJECTED — each changes the output bytes
        // (different GEMM partitioning / packed-kernel rounding).
        try check(api.DisableMemPattern(o))
        try "1".withCString { v in
            try "session.use_env_allocators".withCString { k in
                try check(api.AddSessionConfigEntry(o, k, v))
            }
        }
        var s: OpaquePointer?
        try dir.appendingPathComponent(file).path.withCString { cPath in
            try check(api.CreateSession(env, cPath, o, &s))
        }
        return s
    }

    private func ioNames(_ session: OpaquePointer) throws -> ([String], [String]) {
        var nIn = 0, nOut = 0
        try check(api.SessionGetInputCount(session, &nIn))
        try check(api.SessionGetOutputCount(session, &nOut))
        var ins: [String] = [], outs: [String] = []
        for i in 0..<nIn {
            var c: UnsafeMutablePointer<CChar>?
            try check(api.SessionGetInputName(session, i, allocator, &c))
            if let c {
                ins.append(String(cString: c))
                try check(api.AllocatorFree(allocator, UnsafeMutableRawPointer(c)))
            }
        }
        for i in 0..<nOut {
            var c: UnsafeMutablePointer<CChar>?
            try check(api.SessionGetOutputName(session, i, allocator, &c))
            if let c {
                outs.append(String(cString: c))
                try check(api.AllocatorFree(allocator, UnsafeMutableRawPointer(c)))
            }
        }
        return (ins, outs)
    }

    deinit {
        for s in [textEncoder, fmDecoder, vocos] { if let s { api.ReleaseSession(s) } }
        for o in optionsPool { api.ReleaseSessionOptions(o) }
        if let r = runOpts { api.ReleaseRunOptions(r) }
        if let e = env { api.ReleaseEnv(e) }
    }


    public func synthesize(textIDs: [Int64], prompt: LuxOnnx.Prompt, numSteps: Int, speed: Float,
                    tShift: Float, guidance: Float, dualPath48k: Bool) throws -> (samples: [Float], sampleRate: Int) {
        let steps = max(1, numSteps)
        let mel = LuxMel.nMels

        // ---- text encoder ----
        // prompt_features_len and speed are rank-0 scalars, confirmed against
        // the exported int8 graphs (shape [] int64 / float32).
        let tokensT = try makeInt64Tensor(textIDs, shape: [1, Int64(textIDs.count)])
        let promptT = try makeInt64Tensor(prompt.tokens, shape: [1, Int64(prompt.tokens.count)])
        let featLenT = try makeInt64Tensor([Int64(prompt.frames)], shape: [])
        // NO 1.3 multiplier. The encoder sizes the WHOLE sequence as
        //   F = promptFrames / promptTokens * (promptTokens + textTokens) / speed
        // so dividing by 1.3 shrinks the prompt region too, and the generated
        // audio is whatever survives: F - promptFrames. Measured against this
        // graph, a 120-token line off a 27 s reference yields 1.57 s with the
        // multiplier and 10.20 s without; a 40-token line goes NEGATIVE and
        // falls back to minGenFrames — a fragment. The longer the reference,
        // the more it eats, which is why this got worse once references stopped
        // being truncated. Without it, output holds at ~0.085 s/token across
        // every reference length.
        // `speed` from callers is a PACE: 1.10 means "10% faster to listen to".
        // The graph wants something else — see LuxOnnx.graphSpeed.
        let graphSpeed = LuxOnnx.graphSpeed(
            pace: speed, promptFrames: prompt.frames,
            promptTokens: prompt.tokens.count, textTokens: textIDs.count)
        let speedT = try makeFloatTensor([graphSpeed], shape: [])
        let te = try timed("text_encoder") {
            try run(textEncoder, inputs: [(teIn[0], tokensT), (teIn[1], promptT),
                                          (teIn[2], featLenT), (teIn[3], speedT)],
                    outputs: [teOut[0]])
        }
        releaseValue(tokensT); releaseValue(promptT); releaseValue(featLenT); releaseValue(speedT)
        let tcShape = tensorShape(te[0])
        var cond = tensorFloats(te[0]); releaseValue(te[0])
        guard tcShape.count == 3, tcShape[2] > 0 else {
            throw LuxOnnx.SynthError.engineInitFailed("text_condition shape \(tcShape)")
        }
        var F = tcShape[1]; let D = tcShape[2]
        // Same guard as the Python port: very short text can predict fewer total
        // frames than the prompt occupies; edge-pad so generation is non-empty.
        let required = prompt.frames + Self.minGenFrames
        if F < required {
            let lastRow = Array(cond[(F - 1) * D ..< F * D])
            for _ in F..<required { cond.append(contentsOf: lastRow) }
            F = required
        }

        // ---- ODE time schedule ----
        var ts = [Float](repeating: 0, count: steps + 1)
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            ts[i] = tShift * t / (1 + (tShift - 1) * t)
        }

        // ---- initial noise + speech condition ----
        var rng = GaussianRNG(seed: 42)
        var x = [Float](repeating: 0, count: F * featDim)
        for i in 0..<x.count { x[i] = Float(rng.nextGaussian()) }
        var speech = [Float](repeating: 0, count: F * mel)
        let copyFrames = min(prompt.frames, F)
        for t in 0..<copyFrames {
            for j in 0..<mel { speech[t * mel + j] = prompt.features[t * mel + j] }
        }

        // ---- flow-matching ODE loop ----
        let condT = try makeFloatTensor(cond, shape: [1, Int64(F), Int64(D)])
        let speechT = try makeFloatTensor(speech, shape: [1, Int64(F), Int64(mel)])
        let guidT = try makeFloatTensor([guidance], shape: [])
        defer { releaseValue(condT); releaseValue(speechT); releaseValue(guidT) }
        for step in 0..<steps {
            let tCur = ts[step], tNext = ts[step + 1]
            let tT = try makeFloatTensor([tCur], shape: [])
            let xT = try makeFloatTensor(x, shape: [1, Int64(F), Int64(featDim)])
            let o = try timed("fm_step\(step)") {
                try run(fmDecoder, inputs: [(fmIn[0], tT), (fmIn[1], xT), (fmIn[2], condT),
                                            (fmIn[3], speechT), (fmIn[4], guidT)],
                        outputs: [fmOut[0]])
            }
            releaseValue(tT); releaseValue(xT)
            let v = tensorFloats(o[0]); releaseValue(o[0])
            guard v.count == x.count else {
                throw LuxOnnx.SynthError.engineInitFailed("fm_decoder returned \(v.count) values for \(x.count)")
            }
            // Anchor-based update: blend the x0/x1 predictions toward t_next.
            if step < steps - 1 {
                for i in 0..<x.count {
                    let x1 = x[i] + (1 - tCur) * v[i]
                    let x0 = x[i] - tCur * v[i]
                    x[i] = (1 - tNext) * x0 + tNext * x1
                }
            } else {
                for i in 0..<x.count { x[i] += (1 - tCur) * v[i] }
            }
        }

        // ---- drop the prompt frames, vocode the generated tail ----
        let promptLen = min(prompt.frames, F - 1)
        let Tgen = F - promptLen
        var vin = [Float](repeating: 0, count: featDim * Tgen)
        for t in 0..<Tgen {
            let src = (promptLen + t) * featDim
            for j in 0..<featDim { vin[j * Tgen + t] = x[src + j] / LuxMel.featScale }
        }
        // vocos lives only for the vocode itself: created here, after the ODE
        // loop's arena high-water mark has passed, and released right after.
        // Loading it costs a fraction of a second against a multi-second
        // render, and keeps its ~80 MB out of the fm_decoder peak window
        // (measured 2.60 GB → 2.55 GB peak on the 12.6 s bench).
        if vocos == nil {
            try timed("vocos_load") {
                vocos = try makeSession(modelDir, "vocos.onnx")
                (voIn, voOut) = try ioNames(vocos!)
                guard voIn.count >= 1, voOut.count >= 2 else {
                    throw LuxOnnx.SynthError.engineInitFailed("unexpected vocos I/O arity (\(voOut.count) out)")
                }
            }
        }
        let vinT = try makeFloatTensor(vin, shape: [1, Int64(featDim), Int64(Tgen)])
        let vo = try timed("vocos_run") {
            try run(vocos, inputs: [(voIn[0], vinT)], outputs: [voOut[0], voOut[1]])
        }
        releaseValue(vinT)
        if let s = vocos {
            api.ReleaseSession(s)
            vocos = nil
            voIn = []; voOut = []
        }
        let a48 = tensorFloats(vo[0])
        let a24 = tensorFloats(vo[1])
        releaseValue(vo[0]); releaseValue(vo[1])

        var out: [Float]
        let rate: Int
        if dualPath48k {
            out = LuxMel.crossoverMerge(a48, a24); rate = 48000
        } else {
            out = a24; rate = LuxMel.sampleRate
        }
        for i in 0..<out.count { out[i] = min(1, max(-1, out[i])) }
        if prompt.rms < Self.targetRMS {
            let g = prompt.rms / Self.targetRMS
            for i in 0..<out.count { out[i] *= g }
        }
        return (out, rate)
    }

    // MARK: ORT helpers (same shapes as the iOS port's)

    func check(_ status: OrtStatusPtr?) throws {
        guard let s = status else { return }
        let message = api.GetErrorMessage(s).map { String(cString: $0) } ?? "unknown ORT error"
        api.ReleaseStatus(s)
        throw LuxOnnx.SynthError.engineInitFailed(message)
    }

    func makeTensor<T>(_ data: [T], shape: [Int64], type: ONNXTensorElementDataType) throws -> OpaquePointer {
        var value: OpaquePointer?
        try shape.withUnsafeBufferPointer { shp in
            try check(api.CreateTensorAsOrtValue(allocator, shp.baseAddress, shape.count, type, &value))
        }
        guard let v = value else { throw LuxOnnx.SynthError.engineInitFailed("CreateTensorAsOrtValue returned NULL") }
        if !data.isEmpty {
            var raw: UnsafeMutableRawPointer?
            try check(api.GetTensorMutableData(v, &raw))
            data.withUnsafeBufferPointer { src in
                if let b = src.baseAddress {
                    raw!.copyMemory(from: b, byteCount: data.count * MemoryLayout<T>.stride)
                }
            }
        }
        return v
    }

    private func makeInt64Tensor(_ values: [Int64], shape: [Int64]) throws -> OpaquePointer {
        try makeTensor(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
    }

    private func makeFloatTensor(_ values: [Float], shape: [Int64]) throws -> OpaquePointer {
        try makeTensor(values, shape: shape, type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
    }

    /// Multi-output run: returns outputs in the order requested.
    private func run(_ session: OpaquePointer?,
                     inputs: [(String, OpaquePointer)],
                     outputs: [String]) throws -> [OpaquePointer] {
        let inNames: [UnsafePointer<CChar>?] = inputs.map { UnsafePointer(strdup($0.0)) }
        let outNames: [UnsafePointer<CChar>?] = outputs.map { UnsafePointer(strdup($0)) }
        defer {
            for p in inNames { free(UnsafeMutablePointer(mutating: p)) }
            for p in outNames { free(UnsafeMutablePointer(mutating: p)) }
        }
        var inVals: [OpaquePointer?] = inputs.map { $0.1 }
        var outVals = [OpaquePointer?](repeating: nil, count: outputs.count)
        var mutIn = inNames
        var mutOut = outNames
        try check(api.Run(session, runOpts, &mutIn, &inVals, inputs.count, &mutOut, outputs.count, &outVals))
        return try outVals.map {
            guard let v = $0 else { throw LuxOnnx.SynthError.engineInitFailed("Run produced NULL output") }
            return v
        }
    }

    private func tensorFloats(_ value: OpaquePointer) -> [Float] {
        var info: OpaquePointer?
        guard api.GetTensorTypeAndShape(value, &info) == nil, let inf = info else { return [] }
        defer { api.ReleaseTensorTypeAndShapeInfo(inf) }
        var count = 0
        guard api.GetTensorShapeElementCount(inf, &count) == nil else { return [] }
        var raw: UnsafeMutableRawPointer?
        guard api.GetTensorMutableData(value, &raw) == nil, let r = raw else { return [] }
        return Array(UnsafeBufferPointer(start: r.bindMemory(to: Float.self, capacity: count), count: count))
    }

    private func tensorShape(_ value: OpaquePointer) -> [Int] {
        var info: OpaquePointer?
        guard api.GetTensorTypeAndShape(value, &info) == nil, let inf = info else { return [] }
        defer { api.ReleaseTensorTypeAndShapeInfo(inf) }
        var dims = 0
        guard api.GetDimensionsCount(inf, &dims) == nil else { return [] }
        var shape = [Int64](repeating: 0, count: dims)
        guard api.GetDimensions(inf, &shape, dims) == nil else { return [] }
        return shape.map(Int.init)
    }

    private func releaseValue(_ v: OpaquePointer) { api.ReleaseValue(v) }
}



// MARK: - Mel features + dual-path merge (ports of the numpy front/back ends)

/// LuxTTS audio math: VocosFbank-matched log-mel extraction (n_fft=1024,
/// hop=256, 100 HTK mels, norm=None, magnitude) and the Linkwitz-Riley
/// crossover that merges the vocoder's 48 kHz + 24 kHz paths.
#endif  // os(macOS) — LuxEngine needs ONNX Runtime

public enum LuxMel {
    public static let sampleRate = 24000
    static let nFFT = 1024, hop = 256, nMels = 100, freqBins = 513
    static let featScale: Float = 0.1

    /// Port of `rms_norm`: scale UP to the target only, never down. Returns the
    /// (possibly scaled) audio + the original RMS for output volume matching.
    static func rmsNormUp(_ audio: [Float], target: Float = 0.01) -> ([Float], Float) {
        var ss = 0.0
        for v in audio { ss += Double(v) * Double(v) }
        let rms = Float((ss / Double(max(1, audio.count))).squareRoot())
        guard rms > 1e-8, rms < target else { return (audio, rms) }
        let g = target / rms
        return (audio.map { $0 * g }, rms)
    }

    /// Leading and trailing room tone inflates the frame count without adding
    /// any tokens, which skews the frames-per-token ratio the duration
    /// predictor runs on. A short fade avoids the click a hard cut would leave.
    static func trimAndFade(_ samples: [Float], sampleRate: Int = LuxMel.sampleRate,
                            thresholdDB: Float = -42, keepSilenceMs: Float = 35,
                            fadeMs: Float = 12) -> [Float] {
        guard !samples.isEmpty, let peak = samples.map({ abs($0) }).max(), peak > 1e-8 else {
            return samples
        }
        let threshold = peak * pow(10, thresholdDB / 20)
        guard let firstActive = samples.firstIndex(where: { abs($0) > threshold }),
              let lastActive = samples.lastIndex(where: { abs($0) > threshold })
        else { return samples }

        let keep = max(0, Int(Float(sampleRate) * max(keepSilenceMs, 0) / 1000))
        let start = max(0, firstActive - keep)
        let end = min(samples.count, lastActive + keep + 1)
        guard end - start > 8 else { return samples }
        var trimmed = Array(samples[start..<end])

        let fadeSamples = max(0, Int(Float(sampleRate) * max(fadeMs, 0) / 1000))
        if fadeSamples > 1, trimmed.count > fadeSamples * 2 {
            for i in 0..<fadeSamples {
                let ramp = Float(i) / Float(fadeSamples)
                trimmed[i] *= ramp
                trimmed[trimmed.count - 1 - i] *= ramp
            }
        }
        return trimmed
    }

    /// Remove DC bias (matches the macOS engine and LuxTTS-mlx) before mel.
    static func removeDC(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        return samples.map { $0 - mean }
    }

    /// librosa.filters.mel(sr=24000, n_fft=1024, n_mels=100, htk=True, norm=None):
    /// plain triangular filters on the HTK mel scale, no Slaney area norm.
    static let melBasis: [Float] = {
        func hzToMel(_ f: Double) -> Double { 2595.0 * log10(1.0 + f / 700.0) }
        func melToHz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }
        let fMax = Double(sampleRate) / 2
        let mMax = hzToMel(fMax)
        let hzPts = (0...(nMels + 1)).map { melToHz(mMax * Double($0) / Double(nMels + 1)) }
        var basis = [Float](repeating: 0, count: nMels * freqBins)
        for m in 0..<nMels {
            let f0 = hzPts[m], f1 = hzPts[m + 1], f2 = hzPts[m + 2]
            for k in 0..<freqBins {
                let f = fMax * Double(k) / Double(freqBins - 1)
                let w = min((f - f0) / max(f1 - f0, 1e-10), (f2 - f) / max(f2 - f1, 1e-10))
                if w > 0 { basis[m * freqBins + k] = Float(w) }
            }
        }
        return basis
    }()

    /// Port of `extract_mel_features`: magnitude STFT (center=True, zero pad —
    /// librosa ≥ 0.10's default pad_mode) → HTK mel → log(clip 1e-7) → × 0.1.
    /// Returns `[T * 100]` row-major (t, mel) ready for the `[1, T, 100]` input.
    static func features(_ audio: [Float]) -> (mel: [Float], T: Int) {
        let pad = nFFT / 2
        var y = [Float](repeating: 0, count: pad)
        y.append(contentsOf: audio)
        y.append(contentsOf: [Float](repeating: 0, count: pad))
        if y.count < nFFT { y.append(contentsOf: [Float](repeating: 0, count: nFFT - y.count)) }
        let T = 1 + (y.count - nFFT) / hop

        // periodic Hann (fftbins=True): w[i] = 0.5 - 0.5 cos(2πi/N)
        var hann = [Float](repeating: 0, count: nFFT)
        for i in 0..<nFFT { hann[i] = 0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(nFFT)) }

        let log2n = vDSP_Length(10)  // 1024
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let half = nFFT / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: nFFT)

        // magnitude matrix [freqBins, T]
        var mag = [Float](repeating: 0, count: freqBins * T)
        for t in 0..<T {
            let off = t * hop
            for i in 0..<nFFT { windowed[i] = y[off + i] * hann[i] }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wb in
                        wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                            vDSP_ctoz(cb, 2, &sc, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip packs DC in realp[0], Nyquist in imagp[0]; scale 2 vs true DFT.
                    let dc = rp[0] * 0.5, nyq = ip[0] * 0.5
                    mag[0 * T + t] = abs(dc)
                    mag[512 * T + t] = abs(nyq)
                    for k in 1..<half {
                        let re = rp[k] * 0.5, im = ip[k] * 0.5
                        mag[k * T + t] = sqrtf(re * re + im * im)
                    }
                }
            }
        }

        // mel = melBasis[100,513] @ mag[513,T] → [100, T]
        var melCT = [Float](repeating: 0, count: nMels * T)
        melBasis.withUnsafeBufferPointer { mb in
            mag.withUnsafeBufferPointer { mg in
                melCT.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(mb.baseAddress!, 1, mg.baseAddress!, 1, out.baseAddress!, 1,
                              vDSP_Length(nMels), vDSP_Length(T), vDSP_Length(freqBins))
                }
            }
        }
        // log(clip(., 1e-7)) * FEAT_SCALE, transpose [100,T] → [T,100]
        var mel = [Float](repeating: 0, count: T * nMels)
        for m in 0..<nMels {
            for t in 0..<T {
                mel[t * nMels + m] = logf(max(melCT[m * T + t], 1e-7)) * featScale
            }
        }
        return (mel, T)
    }

    /// Port of `crossover_merge`: 4th-order Linkwitz-Riley at 12 kHz — the
    /// 24 kHz path supplies the lows, the 48 kHz path the highs. The 24 kHz
    /// path is 2×-upsampled by linear interpolation (librosa uses a
    /// band-limited resampler; the interp rolloff sits at the crossover corner
    /// where the low path is already attenuated). Filtering runs over a
    /// zero-padded power-of-two FFT rather than the Python's exact-length FFT —
    /// a zero-phase magnitude filter, so only the circular-wrap edges differ.
    static func crossoverMerge(_ a48: [Float], _ a24: [Float],
                               crossoverHz: Float = 12000) -> [Float] {
        guard a48.count > 1, a24.count > 1 else { return a48 }
        var up = [Float](repeating: 0, count: a24.count * 2)
        for i in 0..<a24.count - 1 {
            up[2 * i] = a24[i]
            up[2 * i + 1] = 0.5 * (a24[i] + a24[i + 1])
        }
        up[up.count - 2] = a24[a24.count - 1]
        up[up.count - 1] = a24[a24.count - 1]

        let n = min(a48.count, up.count)
        var log2n: vDSP_Length = 1
        while (1 << log2n) < n { log2n += 1 }
        let nfft = 1 << Int(log2n)
        let half = nfft / 2
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return a48 }
        defer { vDSP_destroy_fftsetup(setup) }

        // One buffer, reused by both calls — mirrors the iOS port. The previous
        // shape — `Array(s)` then `append(contentsOf:)` — allocated the slice,
        // then a zero array, then reallocated to grow, churning ~12 MB through
        // three allocations per spectrum; under memory pressure the grow is
        // where malloc returned null on device (swift_abortAllocationFailure,
        // 2026-08-01).
        var padded = [Float](repeating: 0, count: nfft)
        func spectrum(_ s: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
            // Refill: the tail past the slice must be zero for the second call
            // too, so clear before copying rather than trusting what's there.
            for i in 0 ..< nfft { padded[i] = 0 }
            padded.withUnsafeMutableBufferPointer { pb in
                s.withUnsafeBufferPointer { sb in
                    if let src = sb.baseAddress { pb.baseAddress!.update(from: src, count: s.count) }
                }
            }
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pb in
                        pb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                            vDSP_ctoz(cb, 2, &sc, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }

        var (reM, imM) = spectrum(up[0..<n])          // starts as the 24 kHz (low) spectrum
        let (re48, im48) = spectrum(a48[0..<n])
        let sr: Float = 48000
        func gains(_ f: Float) -> (lo: Float, hi: Float) {
            let b = 1 / (1 + powf(f / crossoverHz, 8))   // Butterworth^2 = Linkwitz-Riley
            return (sqrtf(b), sqrtf(max(0, 1 - b)))
        }
        // zrip packing: DC in re[0] (f = 0 → all low path, so reM[0] stands),
        // Nyquist in im[0].
        let gN = gains(sr / 2)
        imM[0] = imM[0] * gN.lo + im48[0] * gN.hi
        for k in 1..<half {
            let g = gains(Float(k) * sr / Float(nfft))
            reM[k] = reM[k] * g.lo + re48[k] * g.hi
            imM[k] = imM[k] * g.lo + im48[k] * g.hi
        }

        var merged = [Float](repeating: 0, count: nfft)
        reM.withUnsafeMutableBufferPointer { rp in
            imM.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
                merged.withUnsafeMutableBufferPointer { mb in
                    mb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                        vDSP_ztoc(&sc, 1, cb, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = 1 / (2 * Float(nfft))                // zrip forward+inverse scales by 2N
        merged.withUnsafeMutableBufferPointer { mb in
            vDSP_vsmul(mb.baseAddress!, 1, &scale, mb.baseAddress!, 1, vDSP_Length(nfft))
        }
        return Array(merged[0..<n])
    }

    /// Linear-interpolation resample — used to bring the engine's 48 kHz
    /// dual-path output to VoiceMixer's native 44.1 kHz (the streamed-chunk
    /// path assumes 44_100 and carries no rate). Linear interp is consistent
    /// with the engine's own 24→48 kHz upsample above; the only content at
    /// risk sits above 22.05 kHz, where the vocoder emits next to nothing.
    static func resampleLinear(_ x: [Float], from src: Int, to dst: Int) -> [Float] {
        guard src != dst, x.count > 1, src > 0, dst > 0 else { return x }
        let n = Int(Double(x.count) * Double(dst) / Double(src))
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let step = Double(src) / Double(dst)
        for i in 0..<n {
            let pos = Double(i) * step
            let j = min(Int(pos), x.count - 1)
            let f = Float(pos - Double(j))
            let a = x[j]
            let b = x[min(j + 1, x.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }
}

struct GaussianRNG {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    private mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func nextUniform() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0) // [0,1)
    }

    mutating func nextGaussian() -> Double {
        if let s = spare { spare = nil; return s }
        var u1 = nextUniform()
        while u1 <= .ulpOfOne { u1 = nextUniform() }
        let u2 = nextUniform()
        let r = (-2.0 * Foundation.log(u1)).squareRoot()
        spare = r * sin(2.0 * .pi * u2)
        return r * cos(2.0 * .pi * u2)
    }
}


