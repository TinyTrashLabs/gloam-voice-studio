import EngineKit
import Foundation
import MLX
import MLXFFT
import StudioKit

// TEMPORARY debug harness — round-trips a synthetic signal through
// LuxISTFT (forward MLXFFT.rfft, trusted, → LuxISTFT reconstruction, under
// test) to isolate whether the ISTFT+overlap-add math itself is correct,
// independent of the acoustic model. Remove once the LuxTTS vocoder output
// is confirmed to actually sound like speech.
if CommandLine.arguments.dropFirst().first == "test-istft" {
    let nFft = 1024
    let hopLength = 256
    let sr = 24000
    let duration: Float = 2.0
    let n = Int(duration * Float(sr))

    var x = [Float](repeating: 0, count: n)
    for i in 0 ..< n {
        let t = Float(i) / Float(sr)
        x[i] = 0.3 * sin(2 * Float.pi * 220 * t) + 0.2 * sin(2 * Float.pi * 880 * t)
            + 0.05 * Float.random(in: -1 ... 1)
    }
    let signal = MLXArray(x)

    // torch.istft / vocos convention (which LuxISTFT's w/w² normalization
    // assumes): the spectrum is the FFT of a WINDOWED frame, not a raw one —
    // apply the same Hann-ish window LuxISTFT uses to each frame before FFT.
    var winArr = [Float](repeating: 0, count: nFft)
    for i in 0 ..< nFft {
        winArr[i] = 0.5 * (1 - cos(2 * Float.pi * Float(i) / Float(nFft)))
    }
    let win = MLXArray(winArr)

    let frameCount = (n - nFft) / hopLength + 1
    var frames: [MLXArray] = []
    for t in 0 ..< frameCount {
        frames.append(signal[(t * hopLength) ..< (t * hopLength + nFft)] * win)
    }
    let framesArr = stacked(frames, axis: 0).expandedDimensions(axis: 0)  // (1, T, nFft)

    let spec = MLXFFT.rfft(framesArr, axis: -1)
    let specReal = spec.realPart()
    let specImag = spec.imaginaryPart()
    eval(specReal, specImag)

    let istftHead = LuxISTFT(nFft: nFft, hopLength: hopLength)
    let reconstructed = istftHead(specReal, specImag)
    eval(reconstructed)

    let recon = reconstructed.squeezed()
    let reconArr = recon.asArray(Float.self)
    print("reconstructed length: \(reconArr.count), original signal length: \(n)")

    // Search over shifts to see if this is just an alignment-convention
    // mismatch (my test's left-aligned framing vs LuxISTFT's assumed
    // center-padded trim) — for each shift, fit the best least-squares SCALE
    // and report the resulting SNR. A real bug (not just alignment) will show
    // low SNR at EVERY shift; a pure alignment/convention issue will show one
    // shift with high SNR and a scale factor close to some fixed constant.
    let compareCore = 4000
    let midStart = n / 2
    var bestShift = 0
    var bestSNR: Float = -1000
    var bestScale: Float = 0
    for shift in -nFft ... nFft {
        var num: Float = 0
        var den: Float = 0
        var count = 0
        for i in 0 ..< compareCore {
            let xi = midStart + i
            let ri = xi + shift
            guard ri >= 0, ri < reconArr.count, xi < n else { continue }
            num += x[xi] * reconArr[ri]
            den += reconArr[ri] * reconArr[ri]
            count += 1
        }
        guard count > compareCore / 2, den > 1e-9 else { continue }
        let scale = num / den
        var sumSqErr: Float = 0
        var sumSqSig: Float = 0
        for i in 0 ..< compareCore {
            let xi = midStart + i
            let ri = xi + shift
            guard ri >= 0, ri < reconArr.count, xi < n else { continue }
            let err = x[xi] - scale * reconArr[ri]
            sumSqErr += err * err
            sumSqSig += x[xi] * x[xi]
        }
        let snr = 10 * log10(sumSqSig / max(sumSqErr, 1e-12))
        if snr > bestSNR {
            bestSNR = snr
            bestShift = shift
            bestScale = scale
        }
    }
    print("best shift: \(bestShift) samples, best-fit scale: \(bestScale), SNR at best shift: \(bestSNR) dB")
    print("(SNR > 30dB at best shift = correct up to alignment/scale convention; low SNR everywhere = real bug)")
    exit(0)
}

func usage() -> Never {
    FileHandle.standardError.write(Data(
        ("usage: spike --backend <qwen3-0.6b|qwen3-1.7b|qwen3-design|qwen3-custom|"
         + "chatterbox|chatterbox-turbo|fish-s2-pro> --text <text> "
         + "--out <file.wav> [--ref <ref.wav>] [--ref-text <transcript>] "
         + "[--emotion <flat|neutral|warm|excited|hype>] [--speed <s>] [--ack-fish-license] "
         + "[--instruct <natural-language direction>] [--speaker <preset>] [--language <lang>]\n"
         + "   or: spike serve-llm <llm-backend-id> [port]   "
         + "(ids: \(LLMBackendID.allCases.map(\.rawValue).joined(separator: "|")))\n"
         + "   or: spike bakeoff [outPath] [--dry]   "
         + "(default out ./bakeoff-results.md; --dry prints the plan, loads nothing)\n"
         + "   or: spike gvoice-build --name <name> --slug <slug> --out <path.gvoice> "
         + "[--ref-wav <path>] [--ref-text <text>|--ref-text-file <path>] [--strip-comment-lines] "
         + "[--engine <id>:<file>=<value>]... [--no-source]\n"
         + "   or: spike lux-compare --ref <ref.wav> --ref-text <transcript> --text <line> "
         + "--onnx-dir <dir> [--mlx-dir <dir>] [--out-dir <dir>] [--speed <s>]\n").utf8))
    exit(2)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Thread-safe last-printed-percent tracker, so the @Sendable progress closure
/// can throttle prints to whole-percent steps without capturing a mutable var.
final class PctTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    /// Returns the percent to print, or nil if unchanged since the last print.
    func step(_ fraction: Double) -> Int? {
        let pct = Int(fraction * 100)
        lock.lock(); defer { lock.unlock() }
        guard pct != last else { return nil }
        last = pct
        return pct
    }
}

// MARK: - chat subcommand
//
// `spike chat <llm-backend-id> <llm-model-dir> <prompt> [--speak <tts-model-dir>]`
// — streams a chat reply from a local model dir, printing deltas as they
// arrive. With --speak it also queues each completed sentence through
// synthesizeInterleaved mid-stream, proving the speak-while-generating path
// (paced TokenIterator decode + TTS in the token gaps) against real weights.
if CommandLine.arguments.dropFirst().first == "chat" {
    let sub = Array(CommandLine.arguments.dropFirst(2))
    guard sub.count >= 3, let backend = LLMBackendID(rawValue: sub[0]) else {
        die("chat needs: <llm-backend-id> <llm-model-dir> <prompt> [--speak <tts-model-dir>]")
    }
    let llmDir = URL(fileURLWithPath: sub[1])
    let prompt = sub[2]
    let ttsPath: String? = {
        guard let flag = sub.firstIndex(of: "--speak"), sub.count > flag + 1 else { return nil }
        return sub[flag + 1]
    }()
    let imageURL: URL? = {
        guard let flag = sub.firstIndex(of: "--image"), sub.count > flag + 1 else { return nil }
        return URL(fileURLWithPath: sub[flag + 1])
    }()

    let parallel = sub.contains("--parallel")
    let languageProvider = MLXLanguageModelProvider(modelDirectoryResolver: { _ in llmDir })
    let provider = MLXModelProvider(modelPathResolver: { _ in ttsPath })
    let engine = GloamEngine(provider: provider, languageProvider: languageProvider)
    // --parallel: a SECOND engine owning only the TTS model, so synthesis runs
    // truly concurrently with the first engine's token decode — an experiment
    // probing whether MLX tolerates overlapping inference from two models
    // (loads still don't overlap: we preload TTS before streaming).
    let ttsEngine = parallel
        ? GloamEngine(provider: MLXModelProvider(modelPathResolver: { _ in ttsPath }))
        : engine

    do {
        let request = ChatRequest(
            messages: [ChatTurn(role: .user, content: prompt)], maxTokens: 200,
            imageURLs: imageURL.map { [$0] })
        if parallel, ttsPath != nil {
            // Load TTS up front so only inference overlaps, never loads.
            _ = try await ttsEngine.synthesize(
                backend: .qwen17B, request: SynthesisRequest(text: "warm up."))
            print("[parallel mode: TTS preloaded on second engine]")
        }
        var pendingSpeech = ""
        var synthTasks: [Task<Void, Never>] = []
        let stream = await engine.chatStream(backend: backend, request: request)
        let start = Date()
        for try await event in stream {
            switch event {
            case .delta(let d):
                print(d, terminator: "")
                if ttsPath != nil {
                    pendingSpeech += d
                    let (complete, remainder) = SentenceSplitter.splitStreaming(pendingSpeech)
                    pendingSpeech = remainder
                    for sentence in complete {
                        synthTasks.append(Task {
                            do {
                                let t0 = Date().timeIntervalSince(start)
                                let r = parallel
                                    ? try await ttsEngine.synthesize(
                                        backend: .qwen17B, request: SynthesisRequest(text: sentence))
                                    : try await engine.synthesizeInterleaved(
                                        backend: .qwen17B, request: SynthesisRequest(text: sentence))
                                let t1 = Date().timeIntervalSince(start)
                                print("\n[speak t=\(String(format: "%.1f–%.1f", t0, t1))s "
                                      + "\(r.samples.count) samples] \(sentence)")
                            } catch {
                                print("\n[speak FAILED] \(error)")
                            }
                        })
                    }
                }
            case .finished(let result):
                print("\n---\nfinished: \(result.usage.completionTokens) tokens, "
                      + "\(String(format: "%.1f", result.tokensPerSecond ?? 0)) tok/s, "
                      + "\(String(format: "%.1f", result.wallSeconds))s wall")
            }
        }
        for task in synthTasks { await task.value }
        exit(0)
    } catch {
        die("chat failed: \(error)")
    }
}

// MARK: - serve-llm subcommand
//
// `spike serve-llm <llm-backend-id> [port]` — downloads the LLM if missing,
// then runs the local OpenAI-compatible server on 127.0.0.1:<port> (default
// 8790) so it can be smoke-tested / driven by the Phase 2 bake-off.
if CommandLine.arguments.dropFirst().first == "serve-llm" {
    let sub = Array(CommandLine.arguments.dropFirst(2))
    guard let backendRaw = sub.first else {
        die("serve-llm needs a backend id "
            + "(\(LLMBackendID.allCases.map(\.rawValue).joined(separator: "|")))")
    }
    guard let backend = LLMBackendID(rawValue: backendRaw) else {
        die("unknown llm backend '\(backendRaw)' "
            + "(\(LLMBackendID.allCases.map(\.rawValue).joined(separator: "|")))")
    }
    let port = sub.count > 1 ? (Int(sub[1]) ?? 8790) : 8790

    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Models")
        .appendingPathComponent(backend.diskFolder)

    do {
        let configPresent = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path)
        let weightsPresent = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "safetensors" }
        if !configPresent || !weightsPresent {
            print("downloading \(backend.repoId) → \(dir.path)")
            let tracker = PctTracker()
            try await downloadHFSnapshot(repo: backend.repoId, to: dir) { p in
                if let pct = tracker.step(p) { print("  \(pct)%") }
            }
            print("download complete")
        } else {
            print("model present: \(dir.path)")
        }

        let provider = MLXLanguageModelProvider(modelDirectoryResolver: { _ in dir })
        let voicesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-voices")
        let deps = APIDependencies(
            engine: GloamEngine(provider: MLXModelProvider(), languageProvider: provider),
            voices: VoiceLibrary(directory: voicesDir),
            defaultBackend: .chatterboxTurbo,
            defaultLLM: backend)
        let server = LocalAPIServer(deps: deps)
        try await server.start(port: port)

        // Confirm the listener is actually accepting connections (catches port-in-use).
        try await Task.sleep(for: .milliseconds(700))
        do {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            req.timeoutInterval = 5
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                die("server did not return 200 from /health on port \(port)")
            }
        } catch {
            die("server failed to start on port \(port) (is it already in use?): \(error)")
        }
        print("serving /v1/chat/completions on http://127.0.0.1:\(port)  (model: \(backend.rawValue))")

        // Keep the process alive — start() spawns the server on a detached task.
        while true { try await Task.sleep(for: .seconds(86_400)) }
    } catch {
        die("\(error)")
    }
}

// MARK: - lux-phonemes subcommand
//
// `spike lux-phonemes "some text"` — dev aid for the MisakiPhonemizer remap
// table: prints the normalized text, the misaki→espeak-remapped token stream,
// and (when a Homebrew espeak-ng is present) the reference espeak token stream
// for a side-by-side diff.
if CommandLine.arguments.dropFirst().first == "lux-phonemes" {
    guard let text = CommandLine.arguments.dropFirst(2).first else {
        die("usage: spike lux-phonemes \"text\"")
    }
    do {
        let normalized = LuxEnglishTextNormalizer().normalize(text)
        print("normalized: \(normalized)")
        let misaki = try await MisakiPhonemizer.prepared()
        let misakiTokens = try misaki.phonemize(normalized)
        print("misaki : \(misakiTokens.joined())")
        if let espeak = try? EspeakProcessPhonemizer(voice: "en-us") {
            let espeakTokens = try espeak.phonemize(normalized)
            print("espeak : \(espeakTokens.joined())")
        }
    } catch {
        die("\(error)")
    }
    exit(0)
}

// MARK: - lux-compare subcommand
//
// `spike lux-compare --ref <ref.wav> --ref-text <transcript> --text <line>
//      --onnx-dir <dir> [--mlx-dir <dir>] [--out-dir <dir>] [--speed <s>]`
//
// Renders ONE line, from ONE reference, through BOTH LuxTTS engines and writes
// a wav per engine. This exists because the two live in different worlds: MLX
// fp32 here, int8 ONNX on iOS (iOS forbids GPU submission while backgrounded,
// so the phone cannot run the MLX path at all). Every quality argument between
// them was previously made from measurements; this makes it a listening test.
//
// Both paths share LuxTokenizer, so phonemes are identical and the engine is
// the only variable.
if CommandLine.arguments.dropFirst().first == "lux-compare" {
    var refPath: String?, refText: String?, text: String?
    var onnxDir: String?, mlxDir: String?, outDir = "."
    var speed: Float = 1.0
    var it = CommandLine.arguments.dropFirst(2).makeIterator()
    while let flag = it.next() {
        switch flag {
        case "--ref": refPath = it.next()
        case "--ref-text": refText = it.next()
        case "--text": text = it.next()
        case "--onnx-dir": onnxDir = it.next()
        case "--mlx-dir": mlxDir = it.next()
        case "--out-dir": outDir = it.next() ?? "."
        case "--speed": speed = Float(it.next() ?? "1") ?? 1
        default: die("lux-compare: unknown flag \(flag)")
        }
    }
    guard let refPath, let refText, let text else {
        die("usage: spike lux-compare --ref <ref.wav> --ref-text <transcript> --text <line> "
            + "--onnx-dir <dir> [--mlx-dir <dir>] [--out-dir <dir>] [--speed <s>]")
    }

    do {
        // One tokenizer for both engines — the comparison is of inference, not G2P.
        let phonemizer = try await MisakiPhonemizer.prepared()
        let tokenizer = try LuxTokenizer(phonemizer: phonemizer)
        let textIDs = try tokenizer.textToTokenIDs(text).map(Int64.init)
        let promptIDs = try tokenizer.textToTokenIDs(refText).map(Int64.init)
        print("tokens: \(promptIDs.count) prompt, \(textIDs.count) text")

        if let onnxDir {
            let started = Date()
            let engine = try LuxEngine(modelDir: URL(fileURLWithPath: onnxDir))
            let samples24k = try LuxOnnx.loadMono24k(URL(fileURLWithPath: refPath))
            let prompt = try LuxOnnx.encodePrompt(samples24k: samples24k, tokens: promptIDs)
            print("onnx prompt: \(prompt.frames) frames, \(prompt.tokens.count) tokens, "
                  + String(format: "%.2f frames/token", Double(prompt.frames) / Double(max(1, prompt.tokens.count))))
            let (audio, rate) = try engine.synthesize(
                textIDs: textIDs, prompt: prompt, numSteps: 4, speed: speed,
                tShift: 0.5, guidance: 3.0, dualPath48k: true)
            let out = URL(fileURLWithPath: outDir).appendingPathComponent("lux_onnx.wav")
            try WAVWriter.write(samples: audio, sampleRate: rate, to: out)
            print(String(format: "onnx : %.2fs audio @ %d Hz in %.2fs -> %@",
                         Double(audio.count) / Double(rate), rate,
                         Date().timeIntervalSince(started), out.path))
        }

        if let mlxDir {
            let started = Date()
            let model = try await LuxSpeechModel.load(from: URL(fileURLWithPath: mlxDir))
            var req = ProviderRequest(text: text)
            req.refAudioPath = refPath
            req.refText = refText
            req.speed = speed
            let audio = try await model.synthesize(req)
            let out = URL(fileURLWithPath: outDir).appendingPathComponent("lux_mlx.wav")
            try WAVWriter.write(samples: audio, sampleRate: 24000, to: out)
            print(String(format: "mlx  : %.2fs audio @ 24000 Hz in %.2fs -> %@",
                         Double(audio.count) / 24000.0,
                         Date().timeIntervalSince(started), out.path))
        }
        if onnxDir == nil && mlxDir == nil { die("lux-compare: pass --onnx-dir and/or --mlx-dir") }
    } catch {
        die("lux-compare: \(error)")
    }
    exit(0)
}

// MARK: - bakeoff subcommand
//
// `spike bakeoff [outPath] [--dry]` — scores the four catalog LLMs on the DJ
// pick-JSON contract grid (4 models × 3 variants × 5 scenarios = 60 cells).
// `--dry` prints the planned matrix + resolved model dirs and exits without
// loading or downloading anything (wiring check). See Bakeoff.swift.
if CommandLine.arguments.dropFirst().first == "bakeoff" {
    let sub = Array(CommandLine.arguments.dropFirst(2))
    let dryRun = sub.contains("--dry")
    let outPath = sub.first(where: { !$0.hasPrefix("--") }) ?? "./bakeoff-results.md"
    let models: [LLMBackendID] = [.qwen3_1_7b, .gemma4_e2b, .gemma4_e4b, .qwen3_8b]
    await Bakeoff.run(models: models, outPath: outPath, dryRun: dryRun)
    exit(0)
}

// MARK: - gvoice-build subcommand
//
// `spike gvoice-build --name <name> --slug <slug> --out <path.gvoice>
//     [--ref-wav <path>] [--ref-text <text> | --ref-text-file <path>] [--strip-comment-lines]
//     [--engine <engineId>:<filename>=<value>]...  [--no-source]`
//
// Builds one reproducible `.gvoice` pack from loose files/values on the
// command line — no interactive prompts, no hardcoded voice data. `--engine`
// may repeat (once per `engines/<id>/<filename>` member); `<value>` is either
// `@<path>` (read that file's raw bytes) or a literal string written as-is
// (UTF-8) — e.g. `--engine kokoro:voice.json=@voice.json` vs.
// `--engine kokoro:voice.json={"speaker":"bf_emma"}`. `--strip-comment-lines`
// drops trailing lines starting with `#` from ref text (some transcript
// exports append `# window:`/`# dur_target:`-style metadata comments).
//
// Follows docs/gvoice-format.md via the same library->export path proven in
// GVoiceTests: build a throwaway VoiceLibrary in a temp dir, `saveAt` the
// voice into it, GVoice.export it, write the Data, remove the temp dir.
if CommandLine.arguments.dropFirst().first == "gvoice-build" {
    let sub = Array(CommandLine.arguments.dropFirst(2))

    func gvoiceBuildUsage() -> Never {
        die("""
            usage: spike gvoice-build --name <name> --slug <slug> --out <path.gvoice>
                     [--ref-wav <path>] [--ref-text <text> | --ref-text-file <path>] [--strip-comment-lines]
                     [--engine <engineId>:<filename>=<value>]...  [--no-source]
                   <value> is @<path> to read a file's raw bytes, or a literal string written as UTF-8.
            """)
    }

    var name: String?
    var slug: String?
    var out: String?
    var refWavPath: String?
    var refText: String?
    var refTextFile: String?
    var stripCommentLines = false
    var includeSource = true
    var engineSpecs: [String] = []

    var it = sub.makeIterator()
    while let flag = it.next() {
        switch flag {
        case "--name": name = it.next()
        case "--slug": slug = it.next()
        case "--out": out = it.next()
        case "--ref-wav": refWavPath = it.next()
        case "--ref-text": refText = it.next()
        case "--ref-text-file": refTextFile = it.next()
        case "--strip-comment-lines": stripCommentLines = true
        case "--no-source": includeSource = false
        case "--engine":
            guard let spec = it.next() else { gvoiceBuildUsage() }
            engineSpecs.append(spec)
        default: gvoiceBuildUsage()
        }
    }

    guard let name, let slug, let out else { gvoiceBuildUsage() }
    guard refText == nil || refTextFile == nil else {
        die("gvoice-build: pass at most one of --ref-text / --ref-text-file")
    }

    func resolveValue(_ raw: String) throws -> Data {
        if raw.hasPrefix("@") {
            return try Data(contentsOf: URL(fileURLWithPath: String(raw.dropFirst())))
        }
        return Data(raw.utf8)
    }

    do {
        var resolvedRefText = ""
        if let refText {
            resolvedRefText = refText
        } else if let refTextFile {
            resolvedRefText = try String(contentsOf: URL(fileURLWithPath: refTextFile), encoding: .utf8)
        }
        if stripCommentLines {
            var lines = resolvedRefText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Trailing blank lines (e.g. a file's final newline) must not stop the
            // strip before it reaches the actual comment lines above them.
            while let last = lines.last {
                let trimmed = last.trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
                lines.removeLast()
            }
            resolvedRefText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let refWav: Data? = try refWavPath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        // "engineId:filename=value", repeatable.
        var engines: [String: [String: Data]] = [:]
        for spec in engineSpecs {
            guard let colonIdx = spec.firstIndex(of: ":"),
                  let eqIdx = spec[colonIdx...].firstIndex(of: "=")
            else { die("gvoice-build: bad --engine spec '\(spec)', want engineId:filename=value") }
            let engineID = String(spec[spec.startIndex..<colonIdx])
            let filename = String(spec[spec.index(after: colonIdx)..<eqIdx])
            let value = String(spec[spec.index(after: eqIdx)...])
            guard !engineID.isEmpty, !filename.isEmpty else {
                die("gvoice-build: bad --engine spec '\(spec)', want engineId:filename=value")
            }
            engines[engineID, default: [:]][filename] = try resolveValue(value)
        }

        guard refWav != nil || !engines.isEmpty else {
            die("gvoice-build: nothing to pack — pass --ref-wav and/or --engine")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gvoice-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lib = VoiceLibrary(directory: tempDir)
        try lib.saveAt(slug: slug, name: name, refWav: refWav, refText: resolvedRefText, engines: engines)
        let packData = try GVoice.export(slug, from: lib, includeSource: includeSource)
        try packData.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(packData.count) bytes)")
        exit(0)
    } catch {
        die("gvoice-build failed: \(error)")
    }
}

var args: [String: String] = [:]
var ackFish = false
var rest = CommandLine.arguments.dropFirst().makeIterator()
while let flag = rest.next() {
    if flag == "--ack-fish-license" { ackFish = true; continue }
    guard flag.hasPrefix("--"), let value = rest.next() else { usage() }
    args[String(flag.dropFirst(2))] = value
}
guard let backendRaw = args["backend"], let backend = BackendID(rawValue: backendRaw),
      let text = args["text"], let out = args["out"]
else { usage() }

Bakeoff.ensureMetallib()
// `--model-dir <path>`: load the backend's weights from a local directory
// (config.json + safetensors) instead of the HF repo — lets a converted-weights
// checkout (e.g. SuperTonic, LuxTTS) be smoke-tested before the repo is published.
let modelDir = args["model-dir"]
let resolver: (@Sendable (BackendID) -> String?)? =
    modelDir.map { dir in { @Sendable _ in dir } }
let engine = GloamEngine(provider: MLXModelProvider(modelPathResolver: resolver))

do {
    if ackFish { await engine.acknowledgeLicense(for: .fishS2Pro) }
    // A license-gated backend (fish, supertonic) can't synthesize un-acked; the
    // CLI is a dev tool, so acking the selected backend here is the ack.
    if backend.spec.needsLicenseAck { await engine.acknowledgeLicense(for: backend) }
    let request = SynthesisRequest(
        text: text,
        refAudioPath: args["ref"],
        refText: args["ref-text"],
        emotion: args["emotion"].flatMap(Emotion.init(rawValue:)) ?? .neutral,
        speed: args["speed"].flatMap(Float.init) ?? 1.0,
        temperatureOverride: args["temperature"].flatMap(Float.init),
        instruct: args["instruct"],
        speaker: args["speaker"],
        language: args["language"],
        topP: args["top-p"].flatMap(Float.init),
        topK: args["top-k"].flatMap(Int.init),
        repetitionPenalty: args["rep"].flatMap(Float.init),
        numStepsOverride: args["num-steps"].flatMap(Int.init),
        guidanceScaleOverride: args["guidance-scale"].flatMap(Float.init),
        tShiftOverride: args["t-shift"].flatMap(Float.init),
        returnSmoothOverride: args["return-smooth"].flatMap { $0 == "false" ? false : true })
    let result = try await engine.synthesize(backend: backend, request: request)
    try WAVWriter.write(samples: result.samples, sampleRate: result.sampleRate,
                        to: URL(fileURLWithPath: out))
    let audioSeconds = Double(result.samples.count) / Double(result.sampleRate)
    print(String(format: "%@  audio %.2fs  wall %.2fs  rtf %.2fx",
                 out, audioSeconds, result.wallSeconds, audioSeconds / result.wallSeconds))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
