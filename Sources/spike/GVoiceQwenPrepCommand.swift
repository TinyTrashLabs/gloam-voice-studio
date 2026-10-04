import EngineKit
import Foundation
import GVoiceKit
import QwenANE

/// `spike gvoice-qwen-prep <pack.gvoice>... [--models <dir>] [--out <path>] [--check]`
///
/// Adds or refreshes `engines/qwen3-0.6b/` (the Qwen3-TTS prepared voice, docs/gvoice-format.md) in
/// existing packs, in place unless `--out` is given (single pack only). The base variant's
/// `source/ref.wav` is prepared with the Core ML encoders on the CPU (never CPU_AND_NE); a reference
/// over the encoder's 20 s uses the pack's `lux-tts` window when it has one. A pack whose folder is
/// already current is left byte-for-byte alone. `--check` only reports.
///
/// Models: `--models`, else `$QWEN_ANE_MODELS`, else EngineKit's qwen3-0.6b-ane resolution
/// (`GLOAM_QWEN_ANE_MODELS`, the `qwenANEModelsPath` default, Application Support).
func runGVoiceQwenPrep(_ arguments: [String]) throws {
    var packs: [String] = []
    var modelsPath: String?
    var out: String?
    var checkOnly = false
    var it = arguments.makeIterator()
    while let a = it.next() {
        switch a {
        case "--models": modelsPath = it.next()
        case "--out": out = it.next()
        case "--check": checkOnly = true
        default:
            guard !a.hasPrefix("--") else { throw QwenPrepCLIError("unknown flag \(a)") }
            packs.append(a)
        }
    }
    guard !packs.isEmpty else {
        throw QwenPrepCLIError("usage: spike gvoice-qwen-prep <pack.gvoice>... [--models <dir>] [--out <path>] [--check]")
    }
    guard out == nil || packs.count == 1 else { throw QwenPrepCLIError("--out takes exactly one pack") }

    let models: URL
    if let p = modelsPath ?? ProcessInfo.processInfo.environment["QWEN_ANE_MODELS"], !p.isEmpty {
        models = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    } else {
        models = try QwenANEModelLocation.resolve()
    }

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-qwen-prep-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }

    for path in packs {
        let url = URL(fileURLWithPath: path)
        let pack = try Data(contentsOf: url)
        let manifest = try GVoice.manifest(ofPack: pack)
        guard let src = manifest.source?["base"], let audioPath = src.audio,
              let text = src.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let master = GVoice.member(audioPath, ofPack: pack) else {
            print("\(url.lastPathComponent): skipped (no base source audio + transcript)")
            continue
        }
        // Prepare from the master; a master over the encoder's 20 s falls back to the lux-tts window.
        var audio = master, member = audioPath, transcript = text
        let existing = QwenEngineFiles.read(fromPack: pack)
        func trial(_ wav: Data, _ t: String) throws -> QwenVoicePrep.Prepared {
            try QwenVoicePrep.prepared(fromPack: existing, referenceWAV: wav, transcript: t,
                                       cacheDirectory: scratch.appendingPathComponent(UUID().uuidString), modelsDirectory: models)
        }
        let prepared: QwenVoicePrep.Prepared
        do {
            prepared = try trial(audio, transcript)
        } catch QwenVoicePrepError.referenceTooLong(let seconds) {
            guard let vj = GVoice.member("engines/lux-tts/voice.json", ofPack: pack),
                  let j = try? JSONSerialization.jsonObject(with: vj) as? [String: Any],
                  let wp = j["audio"] as? String, let wt = j["text"] as? String,
                  let w = GVoice.member(wp, ofPack: pack) else {
                print("\(url.lastPathComponent): skipped (reference is \(String(format: "%.1f", seconds)) s, over the 20 s encoder limit, and the pack has no lux-tts window)")
                continue
            }
            audio = w; member = wp; transcript = wt
            prepared = try trial(audio, transcript)
        }
        if prepared.origin != .computed, existing != nil {
            print("\(url.lastPathComponent): current (qwen3-0.6b files verified against \(member)), unchanged")
            continue
        }
        if checkOnly { print("\(url.lastPathComponent): needs qwen3-0.6b files (\(existing == nil ? "absent" : "stale"))"); continue }
        let payload = try prepared.enginePayload(audio: member)
        let data = try QwenEngineFiles.write(payload, intoPack: pack)
        let dest = out.map { URL(fileURLWithPath: $0) } ?? url
        try data.write(to: dest, options: .atomic)
        print("\(dest.lastPathComponent): wrote engines/qwen3-0.6b (\(payload.refCodes.count + payload.spkEmbedding.count) bytes of arrays, T=\((try? payload.decodedRefCodes()[0].count) ?? 0), from \(member)); pack \(pack.count) -> \(data.count) bytes")
    }
}

struct QwenPrepCLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
