import EngineKit
import Foundation
import StudioKit

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
         + "(default out ./bakeoff-results.md; --dry prints the plan, loads nothing)\n").utf8))
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
            messages: [ChatTurn(role: .user, content: prompt)], maxTokens: 200)
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

let engine = GloamEngine(provider: MLXModelProvider())

do {
    if ackFish { await engine.acknowledgeLicense(for: .fishS2Pro) }
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
        repetitionPenalty: args["rep"].flatMap(Float.init))
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
