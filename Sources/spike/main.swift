import Foundation
import MLX
import MLXLMCommon
import MLXAudioCore
import MLXAudioTTS

enum SpikeError: Error, CustomStringConvertible {
    case usage
    var description: String {
        "usage: spike --model <hf-repo> --text <text> --out <file.wav> "
            + "[--ref <ref.wav>] [--ref-text <transcript>] [--temperature <t>]"
    }
}

func run() async throws {
    var args: [String: String] = [:]
    var rest = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = rest.next() {
        guard flag.hasPrefix("--"), let value = rest.next() else { throw SpikeError.usage }
        args[String(flag.dropFirst(2))] = value
    }
    guard let modelRepo = args["model"], let text = args["text"], let out = args["out"]
    else { throw SpikeError.usage }

    let loadStart = Date()
    let model = try await TTS.loadModel(modelRepo: modelRepo)
    let loadWall = Date().timeIntervalSince(loadStart)

    var refAudio: MLXArray?
    if let refPath = args["ref"] {
        (_, refAudio) = try loadAudioArray(
            from: URL(fileURLWithPath: refPath), sampleRate: model.sampleRate)
    }

    var params = model.defaultGenerationParameters
    if let t = args["temperature"].flatMap(Float.init) { params.temperature = t }

    let genStart = Date()
    let audio = try await model.generate(
        text: text, voice: nil, refAudio: refAudio, refText: args["ref-text"],
        language: nil, generationParameters: params)
    let genWall = Date().timeIntervalSince(genStart)

    let samples = audio.asArray(Float.self)
    let audioSeconds = Double(samples.count) / Double(model.sampleRate)
    try AudioUtils.writeWavFile(
        samples: samples, sampleRate: model.sampleRate,
        fileURL: URL(fileURLWithPath: out))
    print(String(
        format: "%@  load %.1fs  audio %.2fs  wall %.2fs  rtf %.2fx",
        out, loadWall, audioSeconds, genWall, audioSeconds / genWall))
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
