import CoreML
import Foundation

/// Split streaming vocoder (the "final gated path" of render_fast.py --vocoder ane):
///   head     codes -> hidden, Swift/Accelerate on the CPU, exact streaming (VocoderHead)
///   upF      Core ML fp32, CPU only: hidden window (1,1024,W) -> (1,1536,4W)   [W = 12 first chunk, 20 after]
///   upMall   Core ML fp16, ANE (cpuAndNeuralEngine): (1,1536,4W) -> waveform (1,1,W*1920)
/// A chunk is 12 frames with 8 frames of left context (the upsampler's receptive field), so each
/// chunk is decoded the moment its 12th frame exists and the result is exact. The last chunk is
/// zero-padded on the right (causal, no effect on the kept samples).
///
/// `begin(context:)` primes the head with the voice's reference codes (their audio is dropped), the
/// way upstream's ICL decode does. Without it the vocoder starts cold and the first word comes out
/// wrong: a first word pitched an octave high, heard as a voice crack. The primed state is cached
/// per voice, so only the first line of a voice pays for it.
final class ANEVocoder {
    static let C = 12, L = 8
    private let head: VocoderHead
    private let upF12: MLModel, upF20: MLModel, upMall: MLModel
    private let in12: MLMultiArray, in20: MLMultiArray
    private var hist = [Float](repeating: 0, count: 1024 * ANEVocoder.L)    // (1024 x 8) channel-major
    private var pending: [Int64] = []
    private var first = true
    private var wav: [Float] = []
    private var primed: [[Int64]: (head: VocoderHead.State, hist: [Float])] = [:]   // per voice reference
    /// Wall seconds spent inside the vocoder since `resetStats`.
    private(set) var wall = 0.0

    init(modelsDirectory: URL) throws {
        head = try VocoderHead(dir: modelsDirectory.appendingPathComponent("vochead").path)
        let dir = modelsDirectory.appendingPathComponent("coreml")
        func load(_ n: String, _ units: MLComputeUnits) throws -> MLModel {
            let c = MLModelConfiguration(); c.computeUnits = units
            return try MLModel(contentsOf: dir.appendingPathComponent("\(n).mlmodelc"), configuration: c)
        }
        upF12 = try load("upF_12", .cpuOnly); upF20 = try load("upF_20", .cpuOnly)
        upMall = try load("upMall", .cpuAndNeuralEngine)
        in12 = try MLMultiArray(shape: [1, 1024, 12], dataType: .float32)
        in20 = try MLMultiArray(shape: [1, 1024, 20], dataType: .float32)
        // warm-up: first predictions compile / specialise the graphs (ANE) and are cached by the system
        _ = try predict(window: in12, first: true)
        _ = try predict(window: in20, first: false)
    }

    func resetStats() { wall = 0 }

    /// Starts a line. `context` is the voice's reference codes, frame-major (T x 16).
    func begin(context: [Int64]?) {
        pending = []; pending.reserveCapacity(Self.C * 16)
        wav = []
        if let ctx = context, ctx.count / 16 >= Self.L {
            if primed[ctx] == nil { primed[ctx] = prime(ctx) }
            let p = primed[ctx]!
            head.state = p.head; hist = p.hist; first = false
            return
        }
        head.reset()
        hist = [Float](repeating: 0, count: 1024 * Self.L)
        first = true
    }

    /// Runs the reference codes through the head once (no upsampler: their audio is never kept) and
    /// returns the state a line then starts from: head K/V + conv history, and the upsampler's
    /// 8-frame left context = the reference's last 8 hidden frames. Identical to streaming the
    /// reference ahead of the line and dropping its audio.
    private func prime(_ ctx: [Int64]) -> (head: VocoderHead.State, hist: [Float]) {
        let T = ctx.count / 16, L = Self.L
        head.reset()
        let h = ctx.withUnsafeBufferPointer { head.process(codes: $0.baseAddress!, frames: T) }
        var hs = [Float](repeating: 0, count: 1024 * L)
        for c in 0..<1024 { for j in 0..<L { hs[c * L + j] = h[(T - L + j) * 1024 + c] } }
        return (head.state, hs)
    }

    /// Adds one frame's 16 codes; a chunk is decoded as soon as its 12th frame exists.
    func push(frame: ArraySlice<Int64>) throws {
        pending.append(contentsOf: frame)
        if pending.count == Self.C * 16 { try chunk(); pending.removeAll(keepingCapacity: true) }
    }

    /// Flushes the partial last chunk and returns the whole line (frames * 1920 samples).
    func finish() throws -> [Float] {
        if !pending.isEmpty { try chunk(); pending.removeAll(keepingCapacity: true) }
        let out = wav
        wav = []
        return out
    }

    /// `codes` is frame-major (frames x 16). Returns 24 kHz mono float samples (frames * 1920).
    func decode(codes: [Int64], frames n: Int, context: [Int64]? = nil) throws -> [Float] {
        begin(context: context)
        for f in 0..<n { try push(frame: codes[(f * 16)..<(f * 16 + 16)]) }
        return try finish()
    }

    // MARK: one chunk

    private func chunk() throws {
        let w0 = ProcessInfo.processInfo.systemUptime
        let n = pending.count / 16, C = Self.C, L = Self.L
        let h = pending.withUnsafeBufferPointer { head.process(codes: $0.baseAddress!, frames: n) }    // n x 1024
        let W = first ? C : L + C
        let win = first ? in12 : in20
        let ctx = first ? 0 : L
        // window (1, 1024, W): channel-major, [8 history frames][12 new frames, zero padded]
        let s1 = win.strides[1].intValue, s2 = win.strides[2].intValue
        win.withUnsafeMutableBytes { raw, _ in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            for c in 0..<1024 {
                for j in 0..<ctx { p[c * s1 + j * s2] = hist[c * L + j] }
                for t in 0..<C { p[c * s1 + (ctx + t) * s2] = t < n ? h[t * 1024 + c] : 0 }
            }
        }
        // history = last 8 frames of the window
        win.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for c in 0..<1024 { for j in 0..<L { hist[c * L + j] = p[c * s1 + (W - L + j) * s2] } }
        }
        let out = try predict(window: win, first: first)          // the C*1920 samples of the new frames
        wav.append(contentsOf: out[0..<(n * 1920)])
        first = false
        wall += ProcessInfo.processInfo.systemUptime - w0
    }

    /// The C*1920 waveform samples belonging to the 12 newest frames of the window.
    private func predict(window: MLMultiArray, first: Bool) throws -> [Float] {
        try autoreleasepool {
            let ctx = first ? 0 : Self.L
            let f = first ? upF12 : upF20
            let x = try f.prediction(from: MLDictionaryFeatureProvider(dictionary: ["hidden": window]))
            guard let xv = x.featureValue(for: "x") else { throw QwenANEError.invalid("upF: no output x") }
            let y = try upMall.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": xv]))
            guard let wv = y.featureValue(for: "wav")?.multiArrayValue else { throw QwenANEError.invalid("upMall: no output wav") }
            guard wv.dataType == .float32 else { throw QwenANEError.invalid("upMall wav is not float32") }
            let st = wv.strides.last!.intValue
            var out = [Float](repeating: 0, count: Self.C * 1920)
            wv.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<out.count { out[i] = p[(ctx * 1920 + i) * st] }
            }
            return out
        }
    }
}
