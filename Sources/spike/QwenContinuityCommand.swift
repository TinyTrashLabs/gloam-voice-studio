import Foundation
import QwenANE

/// `spike qwen-continuity --dir D --models M`: how much a talk break jumps at its part joins, from a
/// `qwen-ane-stress` run (`D/renders.jsonl` + WAVs). For every pair of adjacent parts of one run it measures,
/// across the join (the last 2 s of speech of part A against the first 2 s of part B):
///   dF0     |median pitch A - median pitch B| in semitones
///   dLevel  |speech level A - speech level B| in dB
///   dRate   |ln(chars per second A / chars per second B)| (speech time, leading/trailing silence excluded)
///   spkSim  cosine similarity of the Qwen x-vectors of the two whole parts
/// and writes `D/continuity.jsonl` (one line per join) plus a summary on stdout.
func runQwenContinuity(_ args: [String]) throws {
    var dir: String?, models: String?
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--dir": dir = it.next()
        case "--models": models = it.next()
        default: throw QwenANEError.invalid("unknown argument \(a)")
        }
    }
    guard let dir, let models else { throw QwenANEError.invalid("--dir and --models are required") }
    let base = URL(fileURLWithPath: dir)
    let rows = try String(contentsOf: base.appendingPathComponent("renders.jsonl"), encoding: .utf8)
        .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    var byRun: [Int: [Int: [String: Any]]] = [:]
    for r in rows { if let run = r["run"] as? Int, let p = r["part"] as? Int { byRun[run, default: [:]][p] = r } }
    let modelsURL = URL(fileURLWithPath: models)
    var spkCache: [String: [Float]] = [:]
    func spk(_ wav: String) -> [Float]? {
        if let c = spkCache[wav] { return c }
        guard let d = try? Data(contentsOf: base.appendingPathComponent(wav)),
              let v = try? QwenVoicePrep.prepare(referenceWAV: d, transcript: "x", modelsDirectory: modelsURL) else { return nil }
        spkCache[wav] = v.spkEmbedding
        return v.spkEmbedding
    }
    let out = base.appendingPathComponent("continuity.jsonl")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let fh = try FileHandle(forWritingTo: out)
    var dF0s: [Double] = [], dLevels: [Double] = [], dRates: [Double] = [], sims: [Double] = []
    for run in byRun.keys.sorted() {
        let parts = byRun[run]!
        for p in parts.keys.sorted() where parts[p + 1] != nil {
            let a = parts[p]!, b = parts[p + 1]!
            guard let wa = a["wav"] as? String, let wb = b["wav"] as? String,
                  let xa = readWAV16(base.appendingPathComponent(wa)), let xb = readWAV16(base.appendingPathComponent(wb))
            else { continue }
            let sa = speechSpan(xa), sb = speechSpan(xb)
            guard sa.count > 4800, sb.count > 4800 else { continue }
            let tailA = Array(sa.suffix(48_000)), headB = Array(sb.prefix(48_000))
            let fA = medianPitchSemitones(tailA), fB = medianPitchSemitones(headB)
            let lA = speechLevelDB(tailA), lB = speechLevelDB(headB)
            let cpsA = Double((a["chars"] as? Int) ?? 0) / (Double(sa.count) / 24000)
            let cpsB = Double((b["chars"] as? Int) ?? 0) / (Double(sb.count) / 24000)
            var row: [String: Any] = ["run": run, "join": p, "dLevel": abs(lA - lB), "dRate": abs(log(cpsA / cpsB))]
            dLevels.append(abs(lA - lB)); dRates.append(abs(log(cpsA / cpsB)))
            if let fA, let fB { row["dF0"] = abs(fA - fB); dF0s.append(abs(fA - fB)) }
            if let ea = spk(wa), let eb = spk(wb) { let c = cosine(ea, eb); row["spkSim"] = c; sims.append(c) }
            fh.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); fh.write("\n".data(using: .utf8)!)
        }
    }
    try fh.close()
    func med(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }
    print(String(format: "joins %d | dF0 st mean %.2f med %.2f | dLevel dB mean %.2f med %.2f | dRate mean %.3f med %.3f | spkSim mean %.3f med %.3f",
                 dLevels.count, mean(dF0s), med(dF0s), mean(dLevels), med(dLevels), mean(dRates), med(dRates), mean(sims), med(sims)))
}

/// Mono 16-bit WAV (the harness's own output) as floats.
func readWAV16(_ url: URL) -> [Float]? {
    guard let d = try? Data(contentsOf: url), d.count > 44 else { return nil }
    let n = (d.count - 44) / 2
    return d.withUnsafeBytes { raw in
        let p = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
        return (0..<n).map { Float(Int16(littleEndian: p[$0])) / 32768 }
    }
}

/// The samples from the first to the last 20 ms window within 35 dB of the clip's speech level.
func speechSpan(_ x: [Float]) -> [Float] {
    let w = 480, n = x.count / w
    guard n > 0 else { return [] }
    let db = (0..<n).map { i -> Double in
        var s = 0.0; for j in (i * w)..<((i + 1) * w) { s += Double(x[j] * x[j]) }
        return 10 * log10(s / Double(w) + 1e-12)
    }
    let level = db.sorted()[min(n - 1, Int(Double(n) * 0.95))]
    let thr = max(level - 35, -60)
    guard let a = db.firstIndex(where: { $0 >= thr }), let b = db.lastIndex(where: { $0 >= thr }) else { return [] }
    return Array(x[(a * w)..<min(x.count, (b + 1) * w)])
}

/// Mean dB of the windows within 20 dB of the clip's 95th-percentile window level (the voiced part).
func speechLevelDB(_ x: [Float]) -> Double {
    let w = 480, n = x.count / w
    let db = (0..<n).map { i -> Double in
        var s = 0.0; for j in (i * w)..<((i + 1) * w) { s += Double(x[j] * x[j]) }
        return 10 * log10(s / Double(w) + 1e-12)
    }
    guard !db.isEmpty else { return -120 }
    let level = db.sorted()[min(n - 1, Int(Double(n) * 0.95))]
    let voiced = db.filter { $0 >= level - 20 }
    return voiced.reduce(0, +) / Double(max(1, voiced.count))
}

/// Median F0 of the voiced 40 ms frames, in semitones re 100 Hz (normalised autocorrelation at 8 kHz, 60-400 Hz).
func medianPitchSemitones(_ x24: [Float]) -> Double? {
    var x = [Float](); x.reserveCapacity(x24.count / 3)
    var i = 0
    while i + 2 < x24.count { x.append((x24[i] + x24[i + 1] + x24[i + 2]) / 3); i += 3 }
    let frame = 320, hop = 80, minLag = 20, maxLag = 133
    var f0s: [Double] = []
    var start = 0
    let level = speechLevelDB(x24)
    while start + frame + maxLag < x.count {
        var e0: Float = 0
        for k in 0..<frame { e0 += x[start + k] * x[start + k] }
        let db = 10 * log10(Double(e0) / Double(frame) + 1e-12)
        if db > level - 15 {
            var best: Float = 0, bestLag = 0
            for lag in minLag...maxLag {
                var c: Float = 0, e1: Float = 0
                for k in 0..<frame { c += x[start + k] * x[start + k + lag]; e1 += x[start + k + lag] * x[start + k + lag] }
                let r = c / max(1e-9, (e0 * e1).squareRoot())
                if r > best { best = r; bestLag = lag }
            }
            if best > 0.6, bestLag > 0 { f0s.append(12 * log2(8000 / Double(bestLag) / 100)) }
        }
        start += hop
    }
    guard f0s.count >= 10 else { return nil }
    return f0s.sorted()[f0s.count / 2]
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for i in 0..<min(a.count, b.count) { d += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
    return d / max(1e-12, (na * nb).squareRoot())
}
