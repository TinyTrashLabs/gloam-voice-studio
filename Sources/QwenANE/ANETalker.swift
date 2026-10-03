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

    /// Generates frames until EOS, the cap, or `cancelled()`; `onFrame` gets each frame's 16 codes as they exist.
    func generate(prompt: Prompt, sampler: inout Sampler, eos: Int, maxNew: Int?,
                  cancelled: () -> Bool, onFrame: (Int, ArraySlice<Int64>) throws -> Void) throws -> GenResult {
        let H = Self.H, L = Self.LMAX
        let T = prompt.T
        guard T < L - 8 else { throw QwenANEError.invalid("prompt \(T) rows exceeds the ANE talker's \(L) KV slots") }
        let cap = min(maxNew ?? effectiveMaxTokens(prompt.nTextTokens), L - T)
        let t0 = Date()
        try prefill(prompt)
        // decode mask: rows 0..T-2 visible, the rest hidden until written
        let mp = Self.p16(mask), pl = Self.p16(place), kp = Self.p16(keep)
        for j in 0..<L { mp[j] = j < T - 1 ? 0 : -10000; pl[j] = 0; kp[j] = 1 }
        setX(Array(prompt.embeds[((T - 1) * H)..<(T * H)]))
        var hidden = try step(T - 1, nil)
        let prefillWall = Date().timeIntervalSince(t0)

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
            if cancelled() { stop = .cancelled; break }
            var g0 = logits.withUnsafeBufferPointer { sampler.sample($0.baseAddress!, history: hist) }
            let ownG0 = g0
            if let fc = forced { g0 = fc[f][0] }
            var am = 0; var av = logits[0]
            for i in 1..<3072 where logits[i] > av { av = logits[i]; am = i }   // raw argmax (eosGreedyStop)
            if forced == nil && (g0 == eos || am == eos) { stop = .eos; break }
            // code predictor: hidden + codec[g0] -> 15 sub-codes
            let ep = Self.p16(e0), cr = host.codecRow(g0)
            for i in 0..<H { ep[i] = Float16(cr[i]) }
            let co = try cp.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
                "hidden": MLFeatureValue(multiArray: hidden), "e0": MLFeatureValue(multiArray: e0)]))
            guard let ca = co.featureValue(for: "codes")?.multiArrayValue else { throw QwenANEError.invalid("cp codes missing") }
            var cf = [Float](repeating: 0, count: 15)
            Self.read(ca, into: &cf)
            var subs = (0..<15).map { min(2047, max(0, Int(cf[$0].rounded()))) }
            if let fc = forced { forcedPicks.append([ownG0] + subs); subs = Array(fc[f][1...]) }
            // next talker input (fp32 sum, one fp16 rounding)
            // same fp32 summation order as qonnx.Host.code_sum(g0, subs) + tts_pad
            for i in 0..<H { e[i] = cr[i] }
            for k in 0..<15 { let r = host.cpRow(k, subs[k]); for i in 0..<H { e[i] += r[i] } }
            for i in 0..<H { e[i] += ttsPad[i] }
            setX(e)
            hidden = try step(pos, pos - 1)
            codes.append(Int64(g0)); for k in 0..<15 { codes.append(Int64(subs[k])) }
            hist.append(g0)
            pos += 1; frames += 1
            try onFrame(frames, codes[(codes.count - 16)...])
        }
        return GenResult(codes: codes, frames: frames, stop: stop, promptLen: T,
                         prefillWall: prefillWall, loopWall: Date().timeIntervalSince(t1))
    }
}
