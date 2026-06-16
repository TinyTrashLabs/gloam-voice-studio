import EngineKit
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data(
        ("usage: spike --backend <qwen3-0.6b|qwen3-1.7b|qwen3-design|qwen3-custom|"
         + "chatterbox|chatterbox-turbo|fish-s2-pro> --text <text> "
         + "--out <file.wav> [--ref <ref.wav>] [--ref-text <transcript>] "
         + "[--emotion <flat|neutral|warm|excited|hype>] [--speed <s>] [--ack-fish-license] "
         + "[--instruct <natural-language direction>] [--speaker <preset>] [--language <lang>]\n").utf8))
    exit(2)
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
