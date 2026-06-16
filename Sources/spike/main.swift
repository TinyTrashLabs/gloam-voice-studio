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
         + "(ids: \(LLMBackendID.allCases.map(\.rawValue).joined(separator: "|")))\n").utf8))
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
        if !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path) {
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
        print("serving /v1/chat/completions on http://127.0.0.1:\(port)  "
            + "(model: \(backend.rawValue))")

        // Keep the process alive — start() spawns the server on a detached task.
        while true { try await Task.sleep(for: .seconds(86_400)) }
    } catch {
        die("\(error)")
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
