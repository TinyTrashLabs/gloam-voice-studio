import CoreML
import Foundation

/// Result of one talker pass.
struct GenResult {
    var codes: [Int64]          // frames x 16, frame-major
    var frames: Int
    var stop: QwenStopReason
    var promptLen: Int
    var prefillWall: Double
    var loopWall: Double
}

/// Talker + code predictor on the Neural Engine, a Swift port of tools/qcoreml.py.
///
/// * talker{0,1}.mlmodelc: 14 layers each, multifunction ("decode" T=1 / "prefill" T=64) sharing one
///   MLState per chunk (k/v buffers (8, LMAX, 128) fp16). A row is written by a one-hot blend
///   (`keep`, `place` inputs) because the ANE has no scatter and slice_update on a state ignores a
///   dynamic begin. Chunk 0 hands its residual to chunk 1 as (x_out, lo_out): a compensated fp16
///   stream (TwoSum), which keeps the g0 logits within ~0.3% of the fp32 reference.
/// * cp_ane.mlmodelc: one call per frame, 15 greedy sub-codes unrolled (argmax on the ANE).
/// Host side per frame (fp32): next talker input = codec[g0] + sum cp[k][code] + tts_pad, the RoPE
/// row and the mask/one-hot rows. CPU cost is ~1 ms per 80 ms frame on the Mac.
#if arch(arm64)
@available(iOS 18.0, macOS 15.0, *)
final class ANETalkerEngine {
    static let H = 1024, LMAX = 1024, P = 64, HD = 128
    private let dec: [MLModel], pre: [MLModel], cp: MLModel
    private let host: HostTables
    private let ttsPad: [Float]
    private var states: [MLState]
    // persistent decode inputs (mutated in place each step)
    private let x, cosA, sinA, mask, place, keep, e0: MLMultiArray
    // prefill inputs
    private let px, pcos, psin, pmask, pplace, pkeep: MLMultiArray
    private var logits = [Float](repeating: 0, count: 3072)
    /// Teacher forcing for parity tests: frames x 16 codes to feed instead of the engine's own (no EOS
    /// stop); the engine's own picks (sampler g0, code-predictor sub-codes) land in `forcedPicks`.
    /// Free-running sampling diverges after the first fp16 near-tie flip, so per-frame agreement is
    /// only meaningful when both sides see the same history.
    var forced: [[Int]]? = nil
    private(set) var forcedPicks: [[Int]] = []

    init(coreMLDirectory dir: URL, host: HostTables) throws {
        self.host = host
        func load(_ name: String, _ fn: String?) throws -> MLModel {
            let c = MLModelConfiguration()
            c.computeUnits = .cpuAndNeuralEngine
            if let fn { c.functionName = fn }
            return try MLModel(contentsOf: dir.appendingPathComponent(name + ".mlmodelc"), configuration: c)
        }
        dec = try (0..<2).map { try load("talker\($0)", "decode") }
        pre = try (0..<2).map { try load("talker\($0)", "prefill") }
        cp = try load("cp_ane", nil)
        ttsPad = host.textProj([host.cfg.ttsPad])
        states = dec.map { $0.makeState() }
        func f16(_ shape: [Int]) throws -> MLMultiArray {
            let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
            memset(a.dataPointer, 0, shape.reduce(1, *) * 2)
            return a
        }
        let H = Self.H, L = Self.LMAX, P = Self.P, HD = Self.HD
        x = try f16([1, H]); cosA = try f16([1, HD]); sinA = try f16([1, HD]); mask = try f16([1, L])
        place = try f16([L, 1]); keep = try f16([L, 1]); e0 = try f16([1, H])
        px = try f16([P, H]); pcos = try f16([P, HD]); psin = try f16([P, HD]); pmask = try f16([P, L])
        pplace = try f16([L, P]); pkeep = try f16([L, 1])
        // zero the KV states once (masked rows are multiplied by 0; they must not hold NaN bit patterns)
        for (c, s) in states.enumerated() { Self.zero(s, layers: (14 * c)..<(14 * c + 14)) }
    }

    private static func zero(_ s: MLState, layers: Range<Int>) {
        for i in layers {
            for kv in ["k", "v"] {
                let name = "\(kv)\(i)"
                s.withMultiArray(for: name) { a in memset(a.dataPointer, 0, a.count * 2) }
            }
        }
    }

    @inline(__always) private static func p16(_ a: MLMultiArray) -> UnsafeMutablePointer<Float16> {
        a.dataPointer.assumingMemoryBound(to: Float16.self)
    }

    private static func rope(_ pos: Int, _ c: UnsafeMutablePointer<Float16>, _ s: UnsafeMutablePointer<Float16>) {
        for i in 0..<(HD / 2) {
            let inv = 1.0 / pow(1e6, Double(2 * i) / Double(HD))
            let a = Double(pos) * inv
            let cv = Float16(cos(a)), sv = Float16(sin(a))          // one rounding, like numpy float64 -> float16
            c[i] = cv; c[i + HD / 2] = cv; s[i] = sv; s[i + HD / 2] = sv
        }
    }

    /// Runs both chunks on the inputs already placed in `inputs` (chunk 1 also gets x_out/lo_out of chunk 0).
    private func runChunks(_ models: [MLModel], _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
        var feed = inputs.mapValues { MLFeatureValue(multiArray: $0) }
        var out: MLFeatureProvider! = nil
        for (c, m) in models.enumerated() {
            out = try m.prediction(from: try MLDictionaryFeatureProvider(dictionary: feed), using: states[c])
            if let xo = out.featureValue(for: "x_out")?.multiArrayValue, let lo = out.featureValue(for: "lo_out")?.multiArrayValue {
                feed["x"] = MLFeatureValue(multiArray: xo); feed["lo"] = MLFeatureValue(multiArray: lo)
            }
        }
        return out
    }

    private func prefill(_ p: Prompt) throws {
        let H = Self.H, L = Self.LMAX, P = Self.P, HD = Self.HD
        let n = p.T - 1                                   // the last row goes through decode
        var s = 0
        while s < n {
            let rows = min(P, n - s)
            let xp = Self.p16(px), mp = Self.p16(pmask), pl = Self.p16(pplace), kp = Self.p16(pkeep)
            memset(px.dataPointer, 0, P * H * 2); memset(pplace.dataPointer, 0, L * P * 2)
            for i in 0..<(L) { kp[i] = 1 }
            p.embeds.withUnsafeBufferPointer { e in
                for i in 0..<(rows * H) { xp[i] = Float16(e[s * H + i]) }
            }
            for t in 0..<P {
                let pos = s + t
                Self.rope(pos, Self.p16(pcos) + t * HD, Self.p16(psin) + t * HD)
                for j in 0..<L { mp[t * L + j] = j <= pos ? 0 : -10000 }
                if pos < L { pl[pos * P + t] = 1; kp[pos] = 0 }
            }
            _ = try runChunks(pre, ["x": px, "cos": pcos, "sin": psin, "mask": pmask, "place": pplace, "keep": pkeep])
            s += P
        }
    }

    /// One decode step of the row in `x` at position `pos`; fills `logits`, returns the hidden array.
    private func step(_ pos: Int, _ prevPos: Int?) throws -> MLMultiArray {
        let mp = Self.p16(mask), pl = Self.p16(place), kp = Self.p16(keep)
        if let q = prevPos { pl[q] = 0; kp[q] = 1 }
        mp[pos] = 0; pl[pos] = 1; kp[pos] = 0
        Self.rope(pos, Self.p16(cosA), Self.p16(sinA))
        let o = try runChunks(dec, ["x": x, "cos": cosA, "sin": sinA, "mask": mask, "place": place, "keep": keep])
        guard let lg = o.featureValue(for: "logits")?.multiArrayValue, let hid = o.featureValue(for: "hidden")?.multiArrayValue
        else { throw QwenANEError.invalid("talker outputs missing") }
        Self.read(lg, into: &logits)
        return hid
    }

    /// fp16 (or fp32) output array -> Float buffer
    private static func read(_ a: MLMultiArray, into out: inout [Float]) {
        let n = min(out.count, a.count)
        if a.dataType == .float16 {
            let p = p16(a); for i in 0..<n { out[i] = Float(p[i]) }
        } else {
            let p = a.dataPointer.assumingMemoryBound(to: Float.self); for i in 0..<n { out[i] = p[i] }
        }
    }

    private func setX(_ v: [Float]) {
        let xp = Self.p16(x)
        for i in 0..<Self.H { xp[i] = Float16(v[i]) }
    }

    /// True when every value is a finite number (no NaN / Inf).
    static func allFinite(_ v: [Float]) -> Bool {
        for x in v where !x.isFinite { return false }
        return true
    }

    /// Zeroes both chunks' KV states. A NaN/Inf written into a cache row would survive into every
    /// later line (masked rows are multiplied by 0, and 0 * NaN is NaN), so a bad line resets them.
    func resetStates() {
        for (c, s) in states.enumerated() { Self.zero(s, layers: (14 * c)..<(14 * c + 14)) }
    }

    /// Test seam: poison the talker logits with NaN right after the step that follows this frame index.
    var injectNaNLogitsAtFrame: Int? = nil
    /// Test seam: poison the code predictor's sub-codes with NaN at this frame index.
    var injectNaNSubCodesAtFrame: Int? = nil

    /// Frames the KV window leaves after `promptRows` prompt rows.
    static func windowFrames(promptRows T: Int) -> Int { max(0, LMAX - T) }

    /// Generates frames until EOS, the cap, or `cancelled()`; `onFrame` gets each frame's 16 codes as they exist.
    /// A non-finite talker or code-predictor output zeroes the KV states and throws `QwenANEError.nonFinite`;
    /// any thrown error leaves the engine ready for the next line.
    func generate(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        do {
            return try generateUnguarded(prompt: prompt, sampler: &sampler, eos: eos, maxNew: maxNew,
                                         cancelled: cancelled, onFrame: onFrame)
        } catch {
            resetStates()
            throw error
        }
    }

    private func generateUnguarded(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        let H = Self.H, L = Self.LMAX
        let T = prompt.T
        guard T < L - 8 else { throw QwenANEError.invalid("prompt \(T) rows exceeds the ANE talker's \(L) KV slots") }
        let requested = maxNew ?? effectiveMaxTokens(prompt.nTextTokens)
        let window = Self.windowFrames(promptRows: T)
        let cap = min(requested, window)
        let t0 = Date()
        try prefill(prompt)
        // decode mask: rows 0..T-2 visible, the rest hidden until written
        let mp = Self.p16(mask), pl = Self.p16(place), kp = Self.p16(keep)
        for j in 0..<L { mp[j] = j < T - 1 ? 0 : -10000; pl[j] = 0; kp[j] = 1 }
        setX(Array(prompt.embeds[((T - 1) * H)..<(T * H)]))
        var hidden = try step(T - 1, nil)
        let prefillWall = Date().timeIntervalSince(t0)
        guard Self.allFinite(logits) else { throw QwenANEError.nonFinite("talker logits after prefill") }

        var pos = T
        var codes: [Int64] = []; codes.reserveCapacity(cap * 16)
        var hist: [Int] = []
        var stop = QwenStopReason.maxTokens
        var frames = 0
        var e = [Float](repeating: 0, count: H)
        let t1 = Date()
        forcedPicks = []
        let capF = forced.map { min(cap, $0.count) } ?? cap
        for f in 0..<capF {
            // one autoreleasepool per frame: Core ML outputs and feature providers are autoreleased
            let done: Bool = try autoreleasepool {
                if cancelled() { stop = .cancelled; return true }
                var g0 = logits.withUnsafeBufferPointer { sampler.sample($0.baseAddress!, history: hist) }
                let ownG0 = g0
                if let fc = forced { g0 = fc[f][0] }
                var am = 0; var av = logits[0]
                for i in 1..<3072 where logits[i] > av { av = logits[i]; am = i }   // raw argmax (eosGreedyStop)
                if forced == nil && (g0 == eos || am == eos) { stop = .eos; return true }
                guard g0 >= 0, g0 < QwenVoiceFiles.codebookSize else { throw QwenANEError.nonFinite("first-codebook code \(g0) outside the vocoder's range") }
                // code predictor: hidden + codec[g0] -> 15 sub-codes
                let ep = Self.p16(e0), cr = host.codecRow(g0)
                for i in 0..<H { ep[i] = Float16(cr[i]) }
                let co = try cp.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                    "hidden": MLFeatureValue(multiArray: hidden), "e0": MLFeatureValue(multiArray: e0)]))
                guard let ca = co.featureValue(for: "codes")?.multiArrayValue else { throw QwenANEError.invalid("cp codes missing") }
                var cf = [Float](repeating: 0, count: 15)
                Self.read(ca, into: &cf)
                if injectNaNSubCodesAtFrame == f { cf[3] = .nan }
                guard Self.allFinite(cf) else { throw QwenANEError.nonFinite("code predictor output at frame \(f)") }
                var subs = (0..<15).map { Int(min(Float(QwenVoiceFiles.codebookSize - 1), max(0, cf[$0])).rounded()) }
                if let fc = forced { forcedPicks.append([ownG0] + subs); subs = Array(fc[f][1...]) }
                guard subs.allSatisfy({ $0 >= 0 && $0 < QwenVoiceFiles.codebookSize }) else { throw QwenANEError.nonFinite("sub-code outside the vocoder's range") }
                // next talker input (fp32 sum, one fp16 rounding)
                // same fp32 summation order as qonnx.Host.code_sum(g0, subs) + tts_pad
                for i in 0..<H { e[i] = cr[i] }
                for k in 0..<15 { let r = host.cpRow(k, subs[k]); for i in 0..<H { e[i] += r[i] } }
                for i in 0..<H { e[i] += ttsPad[i] }
                setX(e)
                hidden = try step(pos, pos - 1)
                if injectNaNLogitsAtFrame == f { logits[5] = .nan }
                guard Self.allFinite(logits) else { throw QwenANEError.nonFinite("talker logits at frame \(f)") }
                codes.append(Int64(g0)); for k in 0..<15 { codes.append(Int64(subs[k])) }
                hist.append(g0)
                pos += 1; frames += 1
                try onFrame(frames, codes[(codes.count - 16)...])
                return false
            }
            if done { break }
        }
        if stop == .maxTokens && forced == nil && cap < requested { stop = .contextFull }   // the KV window, not the token cap, ended it
        return GenResult(codes: codes, frames: frames, stop: stop, promptLen: T,
                         prefillWall: prefillWall, loopWall: Date().timeIntervalSince(t1))
    }
}
#else
/// x86_64 macOS slice: Xcode compiles package targets for Intel even when the app is arm64-only,
/// and Float16 (the ANE models' I/O type) doesn't exist there. There's no Neural Engine on Intel
/// either, so the engine simply refuses to load.
@available(iOS 18.0, macOS 15.0, *)
final class ANETalkerEngine {
    static let LMAX = 1024
    var forced: [[Int]]? = nil
    private(set) var forcedPicks: [[Int]] = []
    var injectNaNLogitsAtFrame: Int? = nil
    var injectNaNSubCodesAtFrame: Int? = nil
    init(coreMLDirectory dir: URL, host: HostTables) throws {
        throw QwenANEError.invalid("the Neural Engine voice needs a Mac with Apple silicon")
    }
    static func allFinite(_ v: [Float]) -> Bool { v.allSatisfy { $0.isFinite } }
    func resetStates() {}
    static func windowFrames(promptRows T: Int) -> Int { max(0, LMAX - T) }
    func generate(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        throw QwenANEError.invalid("the Neural Engine voice needs a Mac with Apple silicon")
    }
}
#endif

