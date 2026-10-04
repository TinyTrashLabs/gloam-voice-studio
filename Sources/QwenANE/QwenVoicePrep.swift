import CoreML
import CryptoKit
import Foundation
import GVoiceKit

public enum QwenVoicePrepError: Error, Equatable, LocalizedError {
    /// The trimmed reference is longer than the speech encoder's fixed 20 s input; the caller picks a window.
    case referenceTooLong(seconds: Double)
    case referenceTooShort(seconds: Double)
    /// Not mono 24 kHz PCM16/float32 WAV (run it through ReferenceStandard / the cleanup pipeline first).
    case unsupportedWAV(String)
    case modelMissing(String)
    case modelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .referenceTooLong(let s): return "QwenVoicePrep: reference is \(s) s, the encoder takes at most 20 s"
        case .referenceTooShort(let s): return "QwenVoicePrep: reference is \(s) s, too short to clone from"
        case .unsupportedWAV(let m): return "QwenVoicePrep: \(m)"
        case .modelMissing(let m): return "QwenVoicePrep: missing model \(m)"
        case .modelFailed(let m): return "QwenVoicePrep: \(m)"
        }
    }
}

/// Turns a prepared reference (mono 24 kHz WAV, already through `ReferenceStandard`, plus its exact
/// transcript) into a Qwen voice: speech-tokenizer codes (16 x T) and the x-vector speaker embedding.
/// Both encoders are Core ML fp32 on the CPU (`.cpuOnly`): exactness matters and it runs once per
/// voice. Never CPU_AND_NE: that hung the Mac's ANE compiler for 1.5 h. Spec and parity numbers:
/// qwen-onnx-cpu/docs/voice-prep-coreml.md.
///
/// Models (compiled) under `<modelsDirectory>/coreml/`: `QwenSpeechEncoder.mlmodelc`, `QwenSpeakerEncoder.mlmodelc`.
public enum QwenVoicePrep {
    /// Bump when the recipe changes (mel, tail rule, encoders): cached voices are recomputed.
    public static let prepVersion = 1
    public static let melKind = "upstream"
    public static let maxSamples = 480_000          // the speech encoder's fixed 20 s input
    public static let minSamples = 12_000           // 0.5 s
    static let speakerFrames = 2048
    static let sampleRate = 24_000

    // MARK: cache API

    /// Returns the cached voice in `cacheDirectory` when its source sha256, transcript and prep version
    /// match; otherwise prepares it and (re)writes `voice.json`, `ref_codes.npy`, `spk_embed.npy`
    /// (the layout `QwenVoiceFiles(directory:)` reads). A pure function of its inputs: no global state.
    public static func prepared(referenceWAV: Data, transcript: String, cacheDirectory: URL,
                                modelsDirectory: URL) throws -> QwenVoiceFiles {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = sha256Hex(referenceWAV)
        if let hit = cached(directory: cacheDirectory, sha: sha, text: text) { return hit }

        let voice = try prepare(referenceWAV: referenceWAV, transcript: text, modelsDirectory: modelsDirectory)
        try write(voice, sha: sha, to: cacheDirectory)
        return voice
    }

    /// Prepares without touching any cache.
    public static func prepare(referenceWAV: Data, transcript: String, modelsDirectory: URL) throws -> QwenVoiceFiles {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same order as tools/prep_voice.py: trim a cut-off tail, then encode.
        let all = try samples(of: referenceWAV)
        let samples = Array(all[0..<ReferenceTail.end(of: all, sampleRate: sampleRate)])
        let seconds = Double(samples.count) / Double(sampleRate)
        guard samples.count <= maxSamples else { throw QwenVoicePrepError.referenceTooLong(seconds: seconds) }
        guard samples.count >= minSamples else { throw QwenVoicePrepError.referenceTooShort(seconds: seconds) }

        let coreml = modelsDirectory.appendingPathComponent("coreml")
        let speech = try load(coreml.appendingPathComponent("QwenSpeechEncoder.mlmodelc"))
        let speaker = try load(coreml.appendingPathComponent("QwenSpeakerEncoder.mlmodelc"))
        return QwenVoiceFiles(refText: text,
                              refCodes: try codes(speech, samples),
                              spkEmbedding: try embedding(speaker, samples))
    }

    // MARK: encoders

    private static func load(_ url: URL) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw QwenVoicePrepError.modelMissing(url.lastPathComponent) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        do { return try MLModel(contentsOf: url, configuration: cfg) }
        catch { throw QwenVoicePrepError.modelFailed("loading \(url.lastPathComponent): \(error)") }
    }

    /// T = ceil(ceil(ceil(ceil(ceil(n/4)/5)/6)/8)/2)
    static func codeFrames(samples n: Int) -> Int {
        [4, 5, 6, 8, 2].reduce(n) { ($0 + $1 - 1) / $1 }
    }

    private static func codes(_ model: MLModel, _ x: [Float]) throws -> [[Int]] {
        let wav = try MLMultiArray(shape: [1, 1, NSNumber(value: maxSamples)], dataType: .float32)
        let p = wav.dataPointer.bindMemory(to: Float.self, capacity: maxSamples)
        p.initialize(repeating: 0, count: maxSamples)
        x.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: x.count) }
        let n = try MLMultiArray(shape: [1], dataType: .int32)
        n[0] = NSNumber(value: x.count)
        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["wav": wav, "n_samples": n]))
        } catch { throw QwenVoicePrepError.modelFailed("speech encoder: \(error)") }
        guard let c = out.featureValue(for: "codes")?.multiArrayValue, c.shape.count == 3, c.shape[1].intValue == 16 else {
            throw QwenVoicePrepError.modelFailed("speech encoder returned no (1,16,T) codes")
        }
        let T = codeFrames(samples: x.count)
        guard T <= c.shape[2].intValue else { throw QwenVoicePrepError.modelFailed("speech encoder returned too few frames") }
        // Multi-index subscripts: the output may be row-padded, so a flat offset would be wrong.
        return (0..<16).map { g in (0..<T).map { t in c[[0, g, t] as [NSNumber]].intValue } }
    }

    private static func embedding(_ model: MLModel, _ x: [Float]) throws -> [Float] {
        let (mel, frames) = QwenMel.logMel(x)
        guard frames <= speakerFrames else { throw QwenVoicePrepError.referenceTooLong(seconds: Double(x.count) / Double(sampleRate)) }
        let arr = try MLMultiArray(shape: [1, NSNumber(value: speakerFrames), NSNumber(value: QwenMel.nMels)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: speakerFrames * QwenMel.nMels)
        p.initialize(repeating: 0, count: speakerFrames * QwenMel.nMels)
        mel.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: mel.count) }
        let n = try MLMultiArray(shape: [1], dataType: .int32)
        n[0] = NSNumber(value: frames)
        let out: MLFeatureProvider
        do {
            out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": arr, "n_frames": n]))
        } catch { throw QwenVoicePrepError.modelFailed("speaker encoder: \(error)") }
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue, e.count == 1024 else {
            throw QwenVoicePrepError.modelFailed("speaker encoder returned no 1024 embedding")
        }
        return (0..<1024).map { e[$0].floatValue }
    }

    // MARK: WAV

    /// Mono 24 kHz samples in [-1, 1) from PCM16 or float32 WAV bytes.
    static func samples(of wav: Data) throws -> [Float] {
        let wav = Data(wav)   // zero-based indices
        guard let c = RefLoudness.dataChunk(in: wav) else { throw QwenVoicePrepError.unsupportedWAV("not a readable WAV") }
        guard c.channels == 1, c.sampleRate == sampleRate else {
            throw QwenVoicePrepError.unsupportedWAV("need mono 24 kHz, got \(c.channels) ch at \(c.sampleRate) Hz")
        }
        let width = c.format == .pcm16 ? 2 : 4
        let count = c.length / width
        guard count > 0 else { throw QwenVoicePrepError.unsupportedWAV("no audio") }
        return wav.withUnsafeBytes { raw -> [Float] in
            let base = raw.baseAddress!.advanced(by: c.offset)
            if c.format == .pcm16 {
                return (0..<count).map { Float(base.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self).littleEndian) / 32768 }
            }
            return (0..<count).map { Float(bitPattern: base.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) }
        }
    }

    // MARK: cache files

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func cached(directory: URL, sha: String, text: String) -> QwenVoiceFiles? {
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent("voice.json")),
              let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              j["source_sha256"] as? String == sha,
              j["prep_version"] as? Int == prepVersion,
              j["mel"] as? String == melKind,
              (j["ref_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text,
              let v = try? QwenVoiceFiles(directory: directory),
              v.refCodes.count == 16, !(v.refCodes[0].isEmpty), v.spkEmbedding.count == 1024 else { return nil }
        return v
    }

    static func write(_ v: QwenVoiceFiles, sha: String, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // voice.json is the commit marker: remove it first, write it last.
        try? fm.removeItem(at: directory.appendingPathComponent("voice.json"))
        let T = v.refCodes[0].count
        var codes = [Int32](); codes.reserveCapacity(16 * T)
        for g in 0..<16 { codes.append(contentsOf: v.refCodes[g].map { Int32($0) }) }
        try npy(codes, descr: "<i4", shape: "(1, 16, \(T))").write(to: directory.appendingPathComponent("ref_codes.npy"), options: .atomic)
        try npy(v.spkEmbedding, descr: "<f4", shape: "(1024,)").write(to: directory.appendingPathComponent("spk_embed.npy"), options: .atomic)
        let meta: [String: Any] = ["ref_text": v.refText, "source_sha256": sha, "prep_version": prepVersion,
                                   "mel": melKind, "frames": T]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("voice.json"), options: .atomic)
    }

    /// .npy v1.0, little-endian, C order.
    private static func npy<T>(_ values: [T], descr: String, shape: String) -> Data {
        var header = "{'descr': '\(descr)', 'fortran_order': False, 'shape': \(shape), }"
        let total = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - total % 64) % 64) + "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let n = UInt16(header.utf8.count)
        d.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8)])
        d.append(Data(header.utf8))
        values.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
