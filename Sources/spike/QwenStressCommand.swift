import Foundation
import QwenANE
import SpeechKit

/// `spike qwen-ane-stress`: renders the parts of a talk break N times each through `QwenANEEngine`, the
/// way a host app does (same chunking, same render call), and writes one JSON line per render plus its WAV.
/// It measures what a listener would notice on a bad part: the stop reason (`maxTokens` = it never said
/// it was done), frames per character, the longest silent run inside the line, and (with `spike asr-batch`
/// afterwards) whether the words are there at all.
///
///   spike qwen-ane-stress --models DIR --voice DIR --text-file F --out DIR [--n 30] [--language es]
///       [--max-chunk 160] [--parts] (each line of F is one part, no chunking) [--seed-base S]
///       [--no-prefix-cache] [--topk K] [--temp T] [--rep R] [--eos-sampled-only]
///       [--session [--no-carry]]   (parts of a run through one QwenTalkSession, as the radio renders a break)
///
/// Seeds are `seedBase + run` (every part of a run uses it; a session draws all its parts from that one
/// stream) so a run is reproducible; the default base is random, like the app.
func runQwenStress(_ args: [String]) throws {
    var modelsDir: String?, voiceDir: String?, textFile: String?, outDir: String?
    var n = 30, language: String? = nil, maxChunk = 160, linesAreParts = false
    var seedBase: UInt64 = UInt64.random(in: 0...(UInt64.max / 2)), prefixCache = true
    var sampling = QwenSampling()
    var session = false, carry = true
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--models": modelsDir = it.next()
        case "--voice": voiceDir = it.next()
        case "--text-file": textFile = it.next()
        case "--out": outDir = it.next()
        case "--n": n = Int(it.next() ?? "30") ?? 30
        case "--language": language = it.next()
        case "--max-chunk": maxChunk = Int(it.next() ?? "160") ?? 160
        case "--parts": linesAreParts = true
        case "--seed-base": seedBase = UInt64(it.next() ?? "0") ?? 0
        case "--no-prefix-cache": prefixCache = false
        case "--topk": sampling.topK = Int(it.next() ?? "0") ?? 0
        case "--temp": sampling.temperature = Double(it.next() ?? "0.9") ?? 0.9
        case "--rep": sampling.repetition = Float(it.next() ?? "1.05") ?? 1.05
        case "--eos-sampled-only": sampling.eosOnArgmax = false
        case "--session": session = true
        case "--no-carry": carry = false
        default: throw QwenANEError.invalid("unknown argument \(a)")
        }
    }
    guard let modelsDir, let voiceDir, let textFile, let outDir else {
        throw QwenANEError.invalid("--models, --voice, --text-file and --out are required")
    }
    guard #available(macOS 15.0, *) else { throw QwenANEError.invalid("needs macOS 15") }
    let out = URL(fileURLWithPath: outDir)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let raw = try String(contentsOfFile: textFile, encoding: .utf8)
    let parts: [String] = linesAreParts
        ? raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        : radioChunkText(raw, maxLen: maxChunk)
    let engine = try QwenANEEngine(modelsDirectory: URL(fileURLWithPath: modelsDir))
    engine.options.prefixCache = prefixCache
    engine.options.sampling = sampling
    FileHandle.standardError.write("sampling \(sampling)\n".data(using: .utf8)!)
    let voice = try QwenVoiceFiles(directory: URL(fileURLWithPath: voiceDir))
    for (i, p) in parts.enumerated() {
        let cap = try engine.maxFrames(text: p, voice: voice, language: language)
        FileHandle.standardError.write("part \(i): chars=\(p.count) maxFrames=\(cap) \(p)\n".data(using: .utf8)!)
    }
    _ = try engine.warm(voice: voice)
    let log = out.appendingPathComponent("renders.jsonl")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let fh = try FileHandle(forWritingTo: log)
    for run in 0..<n {
        let seed = seedBase &+ UInt64(run)
        let talk = QwenTalkSession(engine: engine, voice: voice, language: language, seed: seed)
        talk.carryContext = carry
        for (pi, part) in parts.enumerated() {
            let t0 = Date()
            var firstAudio: Double? = nil
            let onAudio: ([Float]) -> Void = { _ in if firstAudio == nil { firstAudio = Date().timeIntervalSince(t0) } }
            // A session renders whole parts, as the radio does (no onAudio: that is what lets it redraw a take).
            let r = session
                ? try talk.render(part)
                : try engine.render(text: part, voice: voice, seed: seed, language: language, onAudio: onAudio)
            let wall = Date().timeIntervalSince(t0)      // every take drawn for the part, as the listener waits
            let wavName = String(format: "p%02d-r%03d.wav", pi, run)
            try qwenStressWAV(r.samples, rate: r.sampleRate).write(to: out.appendingPathComponent(wavName))
            let cap = try engine.maxFrames(text: part, voice: voice, language: language)
            let row: [String: Any] = [
                "part": pi, "run": run, "seed": String(seed), "text": part, "chars": part.count,
                "frames": r.frames, "maxFrames": cap, "stop": r.stopReason.rawValue,
                "framesPerChar": Double(r.frames) / Double(max(1, part.count)),
                "audio": r.audioSeconds, "longestPause": r.silenceBefore.longestPause,
                "leading": r.silenceBefore.leading, "trailing": r.silenceBefore.trailing,
                "pausesOver": r.silenceBefore.pausesOverThreshold,
                "total": r.timings.total, "wall": wall, "prefill": r.timings.prefill, "loop": r.timings.loop,
                "ttfa": firstAudio ?? -1, "rtf": r.timings.total / max(0.001, Double(r.frames) * 0.08),
                "prefixRowsReused": r.prefixRowsReused, "wav": wavName,
                "contextFrames": r.contextFrames, "takes": r.takes, "mode": session ? (carry ? "session" : "session-nocarry") : "independent",
            ]
            let d = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            fh.write(d); fh.write("\n".data(using: .utf8)!)
            FileHandle.standardError.write(String(format: "run %d part %d stop=%@ frames=%d/%d pause=%.2f total=%.1fs\n",
                run, pi, r.stopReason.rawValue, r.frames, cap, r.silenceBefore.longestPause, r.timings.total).data(using: .utf8)!)
        }
    }
    try fh.close()
}

/// `spike asr-batch --whisper DIR --dir D [--language es]`: transcribes every `wav` named in
/// `D/renders.jsonl` with WhisperKit and writes `D/asr.jsonl` ({"wav", "text"}). Kept out of the render pass
/// so the transcriber never shares the Neural Engine with a timed render.
func runASRBatch(_ args: [String]) async throws {
    var whisper: String?, dir: String?, language: String? = nil
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--whisper": whisper = it.next()
        case "--dir": dir = it.next()
        case "--language": language = it.next()
        default: throw QwenANEError.invalid("unknown argument \(a)")
        }
    }
    guard let whisper, let dir else { throw QwenANEError.invalid("--whisper and --dir are required") }
    let base = URL(fileURLWithPath: dir)
    let rows = try String(contentsOf: base.appendingPathComponent("renders.jsonl"), encoding: .utf8)
        .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    let outURL = base.appendingPathComponent("asr.jsonl")
    var done = Set<String>()
    if let prev = try? String(contentsOf: outURL, encoding: .utf8) {
        for l in prev.split(separator: "\n") {
            if let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let w = j["wav"] as? String { done.insert(w) }
        }
    } else {
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
    }
    let fh = try FileHandle(forWritingTo: outURL)
    try fh.seekToEnd()
    let asr = WhisperTranscriber(modelFolder: URL(fileURLWithPath: whisper))
    for row in rows {
        guard let wav = row["wav"] as? String, !done.contains(wav) else { continue }
        let t = try await asr.transcribe(audioURL: base.appendingPathComponent(wav), languageHint: language)
        let d = try JSONSerialization.data(withJSONObject: ["wav": wav, "text": t.text], options: [.sortedKeys])
        fh.write(d); fh.write("\n".data(using: .utf8)!)
        done.insert(wav)
    }
    try fh.close()
}

/// gloam-dj apps/ios/App/App/SupertonicOnnx.swift `SupertonicEngine.chunkText`, verbatim, so the harness
/// splits a break into exactly the parts the radio renders.
func radioChunkText(_ text: String, maxLen: Int) -> [String] {
    let paras = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    let abbrev = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Sr.", "Jr.", "Ph.D.",
                  "etc.", "e.g.", "i.e.", "vs.", "Inc.", "Ltd.", "Co.", "Corp.",
                  "St.", "Ave.", "Blvd."]
    var chunks: [String] = []
    for para in paras {
        var sentences: [String] = []
        var current = ""
        let scalars = Array(para)
        var i = 0
        while i < scalars.count {
            current.append(scalars[i])
            let c = scalars[i]
            let atBoundary = (c == "." || c == "!" || c == "?")
                && i + 1 < scalars.count && scalars[i + 1] == " "
            if atBoundary {
                let tail = current.split(separator: " ").last.map(String.init) ?? ""
                let isInitial = tail.count == 2 && tail.hasSuffix(".")
                    && (tail.first?.isUppercase ?? false)
                if !abbrev.contains(tail) && !isInitial {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    i += 1
                }
            }
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { sentences.append(last) }

        var packed = ""
        for s in sentences {
            if packed.isEmpty {
                packed = s
            } else if packed.count + s.count + 1 <= maxLen {
                packed += " " + s
            } else {
                chunks.append(packed)
                packed = s
            }
        }
        if !packed.isEmpty { chunks.append(packed) }
    }
    return chunks.isEmpty ? [text] : chunks
}

/// 16-bit mono WAV.
func qwenStressWAV(_ x: [Float], rate: Int) -> Data {
    var d = Data()
    func u32(_ v: Int) { var l = UInt32(v).littleEndian; d.append(Data(bytes: &l, count: 4)) }
    func u16(_ v: Int) { var l = UInt16(v).littleEndian; d.append(Data(bytes: &l, count: 2)) }
    let bytes = x.count * 2
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    var pcm = [Int16](); pcm.reserveCapacity(x.count)
    for v in x { pcm.append(Int16(max(-1, min(1, v)) * 32767).littleEndian) }
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}
