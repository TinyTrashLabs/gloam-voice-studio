import Foundation
import Accelerate

struct HostConfig {
    let ttsBos, ttsEos, ttsPad: Int
    let codecBos, codecEos, codecPad, codecThink, codecNothink, codecThinkBos, codecThinkEos: Int
    let vocab: Int
    let groups: Int
    /// `codec_language_id`: lower-case language name -> codec token id ("spanish" -> 2054).
    let codecLanguageIDs: [String: Int]
    init(path: String) throws {
        guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
            throw QwenANEError.invalid("bad host config")
        }
        func i(_ k: String) -> Int { (j[k] as? Int) ?? 0 }
        ttsBos = i("tts_bos"); ttsEos = i("tts_eos"); ttsPad = i("tts_pad")
        codecBos = i("codec_bos"); codecEos = i("codec_eos"); codecPad = i("codec_pad")
        codecThink = i("codec_think"); codecNothink = i("codec_nothink")
        codecThinkBos = i("codec_think_bos"); codecThinkEos = i("codec_think_eos")
        vocab = i("vocab"); groups = i("num_code_groups")
        var langs: [String: Int] = [:]
        for (k, v) in (j["codec_language_id"] as? [String: Any]) ?? [:] { if let id = v as? Int { langs[k.lowercased()] = id } }
        codecLanguageIDs = langs
    }
}

/// Host-side tables (text embedding + projection, codec embeddings) and the tokenizer.
final class HostTables {
    static let H = 1024
    let cfg: HostConfig
    let tok: QwenTokenizer
    private let teQ, teS, teB, w1, b1, w2, b2, codec, cp: NPY

    init(dir: String) throws {
        cfg = try HostConfig(path: dir + "/config.json")
        tok = try QwenTokenizer(tokenizerJSON: dir + "/tokenizer.json")
        teQ = try NPY(path: dir + "/text_embedding_q.npy")
        teS = try NPY(path: dir + "/text_embedding_scales.npy")
        teB = try NPY(path: dir + "/text_embedding_biases.npy")
        w1 = try NPY(path: dir + "/text_proj_linear_fc1_w.npy")
        b1 = try NPY(path: dir + "/text_proj_linear_fc1_b.npy")
        w2 = try NPY(path: dir + "/text_proj_linear_fc2_w.npy")
        b2 = try NPY(path: dir + "/text_proj_linear_fc2_b.npy")
        codec = try NPY(path: dir + "/talker_codec_embedding.npy")
        cp = try NPY(path: dir + "/cp_codec_embedding.npy")
    }

    /// text_proj: dequant 4-bit rows (group 64, MLX affine) -> fc1 -> silu -> fc2. Returns n x 1024.
    func textProj(_ ids: [Int]) -> [Float] {
        let n = ids.count
        let D = 2048, groupSize = 64, groups = D / groupSize, wordsPerRow = D / 8
        var x = [Float](repeating: 0, count: n * D)
        let q = teQ.u32, s = teS, b = teB
        for (r, id) in ids.enumerated() {
            for g in 0..<groups {
                let sc = s.float(at: id * groups + g), bi = b.float(at: id * groups + g)
                for j in 0..<groupSize {
                    let k = g * groupSize + j
                    let nib = (q[id * wordsPerRow + k / 8] >> UInt32(4 * (k % 8))) & 0xF
                    x[r * D + k] = Float(nib) * sc + bi
                }
            }
        }
        var h = [Float](repeating: 0, count: n * D)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(D), Int32(D), 1, x, Int32(D), w1.f32, Int32(D), 0, &h, Int32(D))
        for r in 0..<n { for o in 0..<D { let v = h[r * D + o] + b1.f32[o]; h[r * D + o] = v / (1 + expf(-v)) } }
        var y = [Float](repeating: 0, count: n * 1024)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), 1024, Int32(D), 1, h, Int32(D), w2.f32, Int32(D), 0, &y, 1024)
        for r in 0..<n { for o in 0..<1024 { y[r * 1024 + o] += b2.f32[o] } }
        return y
    }

    /// Talker codec embedding row (fp32; the table may be stored fp16).
    func codecRow(_ id: Int) -> [Float] {
        var r = [Float](repeating: 0, count: 1024)
        codec.copyFloats(from: id * 1024, count: 1024, to: &r)
        return r
    }
    /// cp table for sub-codebook k (0..14), code c (fp32; the table may be stored fp16).
    func cpRow(_ k: Int, _ c: Int) -> [Float] {
        var r = [Float](repeating: 0, count: 1024)
        cp.copyFloats(from: (k * 2048 + c) * 1024, count: 1024, to: &r)
        return r
    }
}

struct Prompt {
    var embeds: [Float]        // T x 1024
    var T: Int
    var nTextTokens: Int
    var textIds: [Int]
    var refTextIds: [Int]
    var targetIds: [Int]
}

/// Language of a render, as the Qwen3-TTS codec names it (`config.json` `codec_language_id`).
public enum QwenLanguage {
    /// BCP-47 primary subtag -> the codec's language name.
    static let names: [String: String] = [
        "en": "english", "es": "spanish", "zh": "chinese", "de": "german", "it": "italian",
        "pt": "portuguese", "ja": "japanese", "ko": "korean", "fr": "french", "ru": "russian",
    ]

    /// The codec language name for a BCP-47 tag ("es", "es-MX", "en_US") or a codec name ("spanish");
    /// nil for nil, "auto", blank or a language Qwen has no token for. Nil means auto-detect.
    public static func codecName(for language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty, raw != "auto" else { return nil }
        let primary = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        if let n = names[primary] { return n }
        return names.values.contains(raw) ? raw : nil
    }
}

/// Port of qonnx.build_icl_prompt. `language` nil (or "auto", or one Qwen has no token for) is
/// language auto: the prefix is [nothink, think_bos, think_eos], exactly as before the parameter existed.
/// A known language prefixes [think, think_bos, <language id>, think_eos], like the reference.
func buildICLPrompt(host: HostTables, voice: QwenVoiceFiles, text: String, language: String? = nil) -> Prompt {
    let c = host.cfg
    let H = 1024
    let refIds = host.tok.encode("<|im_start|>assistant\n\(voice.refText)<|im_end|>\n")
    let rs = min(3, refIds.count), re = max(rs, refIds.count - 2)
    let refTextIds = Array(refIds[rs..<re])
    let tgtIds = host.tok.encode("<|im_start|>assistant\n\(text)<|im_end|>\n<|im_start|>assistant\n")
    let ts = min(3, tgtIds.count), te = max(ts, tgtIds.count - 5)
    let textIds = Array(tgtIds[ts..<te])
    let tts = host.textProj([c.ttsBos, c.ttsEos, c.ttsPad])
    let ttsBos = Array(tts[0..<H]), ttsEos = Array(tts[H..<2 * H]), ttsPad = Array(tts[2 * H..<3 * H])
    var textEmbed = host.textProj(refTextIds + textIds) + ttsEos          // (n+1) x H
    let nT = textEmbed.count / H
    let padRow = host.codecRow(c.codecPad)
    for r in 0..<nT { for j in 0..<H { textEmbed[r * H + j] += padRow[j] } }
    // codec ICL: [codec_bos ; ref codec sum] + tts_pad
    let Tref = voice.refCodes[0].count
    var codecIcl = [Float](repeating: 0, count: (Tref + 1) * H)
    let bosRow = host.codecRow(c.codecBos)
    for j in 0..<H { codecIcl[j] = bosRow[j] }
    for t in 0..<Tref {
        let r0 = host.codecRow(voice.refCodes[0][t])
        for j in 0..<H { codecIcl[(t + 1) * H + j] = r0[j] }
    }
    for i in 0..<(c.groups - 1) where i + 1 < voice.refCodes.count {
        for t in 0..<Tref {
            let row = host.cpRow(i, voice.refCodes[i + 1][t])
            for j in 0..<H { codecIcl[(t + 1) * H + j] += row[j] }
        }
    }
    for r in 0..<(Tref + 1) { for j in 0..<H { codecIcl[r * H + j] += ttsPad[j] } }
    // prefix: think rows, speaker, pad, bos
    var prefix: [Float] = []
    let langID = QwenLanguage.codecName(for: language).flatMap { host.cfg.codecLanguageIDs[$0] }
    let think = langID.map { [c.codecThink, c.codecThinkBos, $0, c.codecThinkEos] } ?? [c.codecNothink, c.codecThinkBos, c.codecThinkEos]
    for id in think { prefix += host.codecRow(id) }
    prefix += voice.spkEmbedding
    for id in [c.codecPad, c.codecBos] { prefix += host.codecRow(id) }
    let pRows = prefix.count / H                       // 6 (7 with a language)
    let role = host.textProj(Array(tgtIds[0..<3]))     // 3 x H
    let padCount = pRows - 2
    var comb = [Float](repeating: 0, count: (padCount + 1) * H)
    for r in 0..<padCount { for j in 0..<H { comb[r * H + j] = ttsPad[j] + prefix[r * H + j] } }
    for j in 0..<H { comb[padCount * H + j] = ttsBos[j] + prefix[padCount * H + j] }
    let full = role + comb + textEmbed + codecIcl
    return Prompt(embeds: full, T: full.count / H, nTextTokens: host.tok.encode(text).count,
                  textIds: textIds, refTextIds: refTextIds, targetIds: tgtIds)
}
