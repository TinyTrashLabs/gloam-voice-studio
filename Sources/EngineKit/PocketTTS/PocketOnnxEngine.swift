// PocketOnnxEngine.swift
//
// Kyutai Pocket TTS driven directly on its ONNX graphs (community export
// KevinAHM/pocket-tts-onnx, MIT), beside the sherpa-onnx path in
// PocketSpeechModel. Both coexist deliberately: this repo is the comparison
// bench, and sherpa's Pocket driver was measured cutting ~700 ms of real
// speech off the FRONT of every utterance (output starts at sample 0 already
// hot, vs the upstream PyTorch model's ~130 ms natural onset ramp). There is
// no knob for that in sherpa's C API, so the fix is to drive the graphs
// ourselves the way upstream does. This port follows kyutai-labs/pocket-tts
// (MIT) `TTSModel.generate_audio` step for step, cross-checked against the
// exporter's own reference runtime (KevinAHM/pocket-tts-onnx
// `pocket_tts_onnx.py`):
//
//   1. voice:  mimi_encoder(ref wav) → [1,F,1024]; prepend the learned
//      bos_before_voice row; run flow_lm_main with an EMPTY sequence so only
//      its KV state absorbs the voice. Outputs are ignored by design.
//   2. text:   sentence-chunk (≤ max_token_per_chunk tokens), SentencePiece-
//      tokenize, text_conditioner → embeddings, another empty-sequence
//      flow_lm_main call.
//   3. loop:   feed one latent per step ([1,1,32], NaN = BOS on step 0),
//      flow_lm_main → (conditioning, eos_logit, states); sample x₀~N(0,√temp),
//      one LSD step through flow_lm_flow (x₁ = x₀ + v); after EOS logit
//      crosses −4.0, run `frames_after_eos` more frames, then stop BEFORE
//      decoding the break-step latent — exactly upstream's loop, which is
//      what preserves the model's own lead-in and tail.
//   4. audio:  mimi_decoder streams latents → 1920 samples per frame, its 56
//      state tensors threaded between calls.
//
// State tensors are created and threaded from bundle.json's manifests — 18
// flow entries, 56 mimi entries with per-tensor dtype/shape/fill — never
// hardcoded. One binding wrinkle: the SwiftPM ONNX Runtime exposes only the
// Objective-C API (no module map for the C headers — see LuxOnnxEngine), and
// that API has no BOOL tensor element type, while mimi_decoder's conv states
// include `first: bool[1]` flags. Bool tensors therefore come out of a tiny
// embedded Cast(int64→bool) graph (86 bytes, generated with onnx.helper; see
// `boolCastModelB64`), and thereafter the decoder's own bool OUTPUTS are fed
// straight back as next-step inputs, so the cast only runs at state init.

import Foundation
#if os(macOS)
import OnnxRuntimeBindings
#endif

/// Namespace for the direct-ONNX Pocket TTS path's shared types.
public enum PocketOnnx {
    public enum Precision: String, Sendable {
        case fp32, int8
    }

    public enum SynthError: Error, LocalizedError {
        case modelsMissing(String)
        case engineInitFailed(String)
        case badBundle(String)
        case emptyText
        case referenceTooLong(Double)
        case promptTooLong(Int)
        case emptyAudio
        public var errorDescription: String? {
            switch self {
            case .modelsMissing(let m):
                return "Pocket ONNX bundle missing: \(m) — run scripts/fetch-pocket-tts-onnx.sh"
            case .engineInitFailed(let m): return "ONNX Runtime failed: \(m)"
            case .badBundle(let m): return "bad Pocket ONNX bundle: \(m)"
            case .emptyText: return "no tokenizable text"
            case .referenceTooLong(let s):
                return String(format: "Reference clip is %.0fs — keep it under %.0fs.",
                              s, PocketOnnx.maxReferenceSeconds)
            case .promptTooLong(let n):
                return "voice + text + generation needs \(n) transformer positions; "
                    + "the exported flow LM cache holds \(PocketOnnx.flowCachePositions)"
            case .emptyAudio: return "engine returned no samples"
            }
        }
    }

    /// Files every bundle needs regardless of precision (the int8 bundle
    /// falls back to fp32 graphs where no quantized file exists, same as the
    /// reference runtime).
    public static let requiredFiles = [
        "bundle.json", "tokenizer.model", "bos_before_voice.npy",
        "text_conditioner.onnx", "flow_lm_main.onnx", "flow_lm_flow.onnx",
        "mimi_encoder.onnx", "mimi_decoder.onnx",
    ]

    /// First required file missing from `dir`; nil when complete.
    public static func missingModelFile(in dir: URL) -> String? {
        for f in requiredFiles
        where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
            return f
        }
        return nil
    }

    /// Upstream truncates audio prompts at 30 s (`get_state_for_audio_prompt`
    /// truncate flag); beyond that the flow cache budget goes to the voice
    /// instead of the text anyway.
    public static let maxReferenceSeconds: Double = 30.0

    /// The exported flow LM KV cache is a static [2,1,1000,16,64]: voice
    /// frames + text tokens + generated frames must fit in 1000 positions.
    public static let flowCachePositions = 1000

    /// Upstream default EOS threshold (default_parameters.py).
    static let eosThreshold: Float = -4.0
    /// english_2026-04's recommended sampling temperature ("Human evals
    /// preferred this model at 0.3" — upstream config). The exporter does not
    /// carry it in bundle.json, so it lives here.
    public static let defaultTemperature: Float = 0.3
    /// Upstream DEFAULT_LSD_DECODE_STEPS.
    static let lsdSteps = 1
    /// TTSModel._TOKENS_PER_SECOND_ESTIMATE / _GEN_SECONDS_PADDING.
    static let tokensPerSecondEstimate = 3.0
    static let genSecondsPadding = 2.0
}

#if os(macOS)

/// Drives the five Pocket TTS graphs through ONNX Runtime's Objective-C API.
/// Same binding idiom as LuxEngine; see that file for why ObjC and not C.
public final class PocketOnnxEngine {
    // MARK: bundle metadata (bundle.json)

    struct StateEntry: Decodable {
        let index: Int
        let inputName: String
        let outputName: String
        let dtype: String
        let shape: [Int]
        let fill: String
        enum CodingKeys: String, CodingKey {
            case index, dtype, shape, fill
            case inputName = "input_name"
            case outputName = "output_name"
        }
    }

    struct BundleMeta: Decodable {
        let sampleRate: Int
        let frameRate: Double
        let samplesPerFrame: Int
        let latentDim: Int
        let conditioningDim: Int
        let maxTokenPerChunk: Int
        let insertBosBeforeVoice: Bool
        let bosBeforeVoiceFile: String?
        let tokenizerFile: String
        let modelRecommendedFramesAfterEos: Int?
        let padWithSpacesForShortInputs: Bool
        let removeSemicolons: Bool
        let flowManifest: [StateEntry]
        let mimiManifest: [StateEntry]
        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case frameRate = "frame_rate"
            case samplesPerFrame = "samples_per_frame"
            case latentDim = "latent_dim"
            case conditioningDim = "conditioning_dim"
            case maxTokenPerChunk = "max_token_per_chunk"
            case insertBosBeforeVoice = "insert_bos_before_voice"
            case bosBeforeVoiceFile = "bos_before_voice_file"
            case tokenizerFile = "tokenizer_file"
            case modelRecommendedFramesAfterEos = "model_recommended_frames_after_eos"
            case padWithSpacesForShortInputs = "pad_with_spaces_for_short_inputs"
            case removeSemicolons = "remove_semicolons"
            case flowManifest = "flow_lm_state_manifest"
            case mimiManifest = "mimi_state_manifest"
        }
    }

    /// A reference voice, encoded once and reusable across lines: the flow
    /// LM's 18 state tensors AFTER absorbing bos_before_voice + the encoded
    /// reference, plus how many cache positions that consumed.
    public struct VoiceState {
        let state: [String: ORTValue]
        let positionsUsed: Int
    }

    private let env: ORTEnv
    private let textConditioner: ORTSession
    private let flowMain: ORTSession
    private let flowFlow: ORTSession
    private let mimiEncoder: ORTSession
    private let mimiDecoder: ORTSession
    private let boolCaster: ORTSession
    private let meta: BundleMeta
    public let tokenizer: PocketTokenizer
    public var sampleRate: Int { meta.sampleRate }
    private let bosBeforeVoice: [Float]
    /// Sherpa-style guard: generation is stateful ORT traffic, not documented
    /// reentrant — serialize direct callers.
    private let lock = NSLock()

    /// Cast(int64→bool), rank-1 dynamic. Generated with Python:
    ///   node  = onnx.helper.make_node("Cast", ["i"], ["o"], to=TensorProto.BOOL)
    ///   model = helper.make_model(make_graph([node], "int64_to_bool",
    ///           [value_info("i", INT64, ["n"])], [value_info("o", BOOL, ["n"])]),
    ///           opset 14, ir_version 8)
    /// Exists because the ObjC ORTValue API cannot create BOOL tensors and
    /// mimi_decoder's state manifest includes bool `first` flags.
    private static let boolCastModelB64 =
        "CAg6TAoXCgFpEgFvIgRDYXN0KgkKAnRvGAmgAQISDWludDY0X3RvX2Jvb2xaEAoBaRILCgkIBxIFCgMSAW5iEAoBbxILCgkICRIFCgMSAW5CBAoAEA4="

    public init(bundleDir: URL, precision: PocketOnnx.Precision = .fp32) throws {
        if let missing = PocketOnnx.missingModelFile(in: bundleDir) {
            throw PocketOnnx.SynthError.modelsMissing(missing)
        }
        let metaURL = bundleDir.appendingPathComponent("bundle.json")
        do {
            meta = try JSONDecoder().decode(BundleMeta.self, from: Data(contentsOf: metaURL))
        } catch {
            throw PocketOnnx.SynthError.badBundle("bundle.json: \(error)")
        }
        guard meta.flowManifest.count == 18, meta.mimiManifest.count == 56 else {
            throw PocketOnnx.SynthError.badBundle(
                "expected 18 flow / 56 mimi state entries, got "
                + "\(meta.flowManifest.count)/\(meta.mimiManifest.count)")
        }

        tokenizer = try PocketTokenizer(
            modelPath: bundleDir.appendingPathComponent(meta.tokenizerFile))

        guard meta.insertBosBeforeVoice, let bosFile = meta.bosBeforeVoiceFile else {
            // english_2026-04 always carries one; a bundle without it would
            // need the (older) no-BOS conditioning flow this port doesn't do.
            throw PocketOnnx.SynthError.badBundle("bundle has no bos_before_voice")
        }
        bosBeforeVoice = try Self.loadNpyFloats(
            bundleDir.appendingPathComponent(bosFile), expectedCount: meta.conditioningDim)

        do {
            let ortEnv = try ORTEnv(loggingLevel: .warning)
            func session(_ file: String) throws -> ORTSession {
                let opts = try ORTSessionOptions()
                try opts.setGraphOptimizationLevel(.all)
                try opts.setIntraOpNumThreads(4)
                return try ORTSession(env: ortEnv,
                                      modelPath: bundleDir.appendingPathComponent(file).path,
                                      sessionOptions: opts)
            }
            /// int8 file when asked for and present, else fp32 — mirrors the
            /// reference runtime's `_model_file` fallback.
            func graphFile(_ stem: String) -> String {
                if precision == .int8 {
                    let q = "\(stem)_int8.onnx"
                    if FileManager.default.fileExists(
                        atPath: bundleDir.appendingPathComponent(q).path) { return q }
                }
                return "\(stem).onnx"
            }
            env = ortEnv
            // mimi_encoder + text_conditioner stay fp32 at every precision,
            // as in the reference runtime: they run once per voice/line, so
            // quantization buys nothing and risks conditioning drift.
            mimiEncoder = try session("mimi_encoder.onnx")
            textConditioner = try session("text_conditioner.onnx")
            flowMain = try session(graphFile("flow_lm_main"))
            flowFlow = try session(graphFile("flow_lm_flow"))
            mimiDecoder = try session(graphFile("mimi_decoder"))

            // The bool-minting Cast graph loads from a temp file (the ObjC
            // API has no from-bytes session init); deleted right after load.
            guard let castBytes = Data(base64Encoded: Self.boolCastModelB64) else {
                throw PocketOnnx.SynthError.engineInitFailed("corrupt embedded cast graph")
            }
            let castURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocket-bool-cast-\(UUID().uuidString).onnx")
            try castBytes.write(to: castURL)
            defer { try? FileManager.default.removeItem(at: castURL) }
            boolCaster = try ORTSession(env: ortEnv, modelPath: castURL.path,
                                        sessionOptions: ORTSessionOptions())
        } catch let e as PocketOnnx.SynthError {
            throw e
        } catch {
            throw PocketOnnx.SynthError.engineInitFailed(error.localizedDescription)
        }
    }

    // MARK: - Voice encoding

    /// Encode a 24 kHz mono reference into a reusable voice state.
    public func makeVoiceState(refSamples24k: [Float]) throws -> VoiceState {
        lock.lock()
        defer { lock.unlock() }
        return try encodeVoice(refSamples24k: refSamples24k)
    }

    private func encodeVoice(refSamples24k: [Float]) throws -> VoiceState {
        guard !refSamples24k.isEmpty else {
            throw PocketOnnx.SynthError.badBundle("empty reference audio")
        }
        let seconds = Double(refSamples24k.count) / Double(meta.sampleRate)
        guard seconds <= PocketOnnx.maxReferenceSeconds else {
            throw PocketOnnx.SynthError.referenceTooLong(seconds)
        }

        let audioT = try floatTensor(refSamples24k, shape: [1, 1, refSamples24k.count])
        let enc = try run(mimiEncoder, ["audio": audioT], outputs: ["latents"])
        let latShape = tensorShape(enc["latents"]!)
        guard latShape.count == 3, latShape[2] == meta.conditioningDim, latShape[1] > 0 else {
            throw PocketOnnx.SynthError.engineInitFailed("mimi_encoder latents shape \(latShape)")
        }
        let latents = tensorFloats(enc["latents"]!)

        // prompt = [bos_before_voice ; encoded reference]  → [1, F+1, 1024]
        var conditioning = bosBeforeVoice
        conditioning.append(contentsOf: latents)
        let frames = latShape[1] + 1
        let condT = try floatTensor(conditioning, shape: [1, frames, meta.conditioningDim])

        // Empty-sequence flow_lm_main pass: only the KV state matters; the
        // conditioning/eos outputs of a prompting call are ignored upstream.
        var state = try initialState(meta.flowManifest)
        try promptFlow(state: &state, sequenceLen: 0, textEmbeddings: condT)
        return VoiceState(state: state, positionsUsed: frames)
    }

    // MARK: - Synthesis

    /// One line, one voice. `seed` pins the flow noise for reproducible takes;
    /// `temperature` nil means the model's recommended 0.3.
    public func synthesize(text: String, voice: VoiceState, seed: UInt64 = 42,
                           temperature: Float? = nil,
                           framesAfterEOS: Int? = nil) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let temp = temperature ?? PocketOnnx.defaultTemperature
        var rng = GaussianRNG(seed: seed)

        let chunks = splitIntoBestSentences(text)
        guard !chunks.isEmpty else { throw PocketOnnx.SynthError.emptyText }

        var out: [Float] = []
        for chunk in chunks {
            let (prepared, eosGuess) = Self.prepareTextPrompt(
                chunk, padShortInputs: meta.padWithSpacesForShortInputs,
                removeSemicolons: meta.removeSemicolons)
            // Upstream: explicit override > model-recommended > guess+2.
            let effectiveFrames = framesAfterEOS
                ?? meta.modelRecommendedFramesAfterEos
                ?? (eosGuess + 2)
            let ids = tokenizer.encode(prepared)
            guard !ids.isEmpty else { continue }

            let latents = try generateLatents(
                voice: voice, tokenIDs: ids, framesAfterEOS: effectiveFrames,
                temperature: temp, rng: &rng)
            if !latents.isEmpty {
                out.append(contentsOf: try decodeLatents(latents))
            }
        }
        guard !out.isEmpty else { throw PocketOnnx.SynthError.emptyAudio }
        return out
    }

    /// The autoregressive loop for one ≤ max_token_per_chunk chunk.
    /// Returns generated latents, one `[latentDim]` row per frame.
    private func generateLatents(voice: VoiceState, tokenIDs: [Int], framesAfterEOS: Int,
                                 temperature: Float, rng: inout GaussianRNG) throws -> [[Float]] {
        let genSeconds = Double(tokenIDs.count) / PocketOnnx.tokensPerSecondEstimate
            + PocketOnnx.genSecondsPadding
        let maxGenLen = Int((genSeconds * meta.frameRate).rounded(.up))
        let needed = voice.positionsUsed + tokenIDs.count + maxGenLen
        guard needed <= PocketOnnx.flowCachePositions else {
            throw PocketOnnx.SynthError.promptTooLong(needed)
        }

        // Each chunk restarts from the voice prompt, exactly like upstream's
        // copy_state=True — so the voice state itself is never consumed.
        var state = try clone(voice.state, manifest: meta.flowManifest)

        let idsT = try int64Tensor(tokenIDs.map(Int64.init), shape: [1, tokenIDs.count])
        let emb = try run(textConditioner, ["token_ids": idsT], outputs: ["embeddings"])
        try promptFlow(state: &state, sequenceLen: 0, textEmbeddings: emb["embeddings"]!)

        let emptyText = try floatTensor([], shape: [1, 0, meta.conditioningDim])
        let sT = try floatTensor([0], shape: [1, 1])   // lsdSteps == 1: s=0 → t=1
        let tT = try floatTensor([1], shape: [1, 1])

        // NaN latent = BOS marker; flow_lm_main swaps in its learned bos_emb.
        var current = try floatTensor([Float](repeating: .nan, count: meta.latentDim),
                                      shape: [1, 1, meta.latentDim])
        var latents: [[Float]] = []
        var eosStep: Int? = nil

        for step in 0 ..< maxGenLen {
            var inputs = state
            inputs["sequence"] = current
            inputs["text_embeddings"] = emptyText
            let outs = try run(flowMain, inputs,
                               outputs: ["conditioning", "eos_logit"]
                                   + meta.flowManifest.map(\.outputName))
            for e in meta.flowManifest { state[e.inputName] = outs[e.outputName]! }

            let eosLogit = tensorFloats(outs["eos_logit"]!).first ?? -Float.infinity
            if eosLogit > PocketOnnx.eosThreshold, eosStep == nil { eosStep = step }
            // Upstream breaks BEFORE queueing this step's latent: the model
            // gets `framesAfterEOS` frames of natural tail, no more.
            if let e = eosStep, step >= e + framesAfterEOS { break }

            var x = [Float](repeating: 0, count: meta.latentDim)
            if temperature > 0 {
                let std = temperature.squareRoot()
                for i in 0 ..< x.count { x[i] = Float(rng.nextGaussian()) * std }
            }
            // LSD decode, upstream lsd_decode with num_steps=1:
            // x₁ = x₀ + v(c, s=0, t=1, x₀).
            let xT = try floatTensor(x, shape: [1, meta.latentDim])
            let flow = try run(flowFlow,
                               ["c": outs["conditioning"]!, "s": sT, "t": tT, "x": xT],
                               outputs: ["flow_dir"])
            let v = tensorFloats(flow["flow_dir"]!)
            guard v.count == x.count else {
                throw PocketOnnx.SynthError.engineInitFailed(
                    "flow_dir returned \(v.count) values for \(x.count)")
            }
            for i in 0 ..< x.count { x[i] += v[i] }

            latents.append(x)
            current = try floatTensor(x, shape: [1, 1, meta.latentDim])
        }
        return latents
    }

    /// Mimi-decode latent frames with the 56 state tensors threaded through.
    /// Chunked like the reference runtime (its streaming property makes
    /// chunked and per-frame decode identical); 1920 samples per frame out.
    private func decodeLatents(_ latents: [[Float]], chunkFrames: Int = 15) throws -> [Float] {
        var state = try initialState(meta.mimiManifest)
        var audio: [Float] = []
        var index = 0
        while index < latents.count {
            let count = min(chunkFrames, latents.count - index)
            let flat = latents[index ..< index + count].flatMap { $0 }
            var inputs = state
            inputs["latent"] = try floatTensor(flat, shape: [1, count, meta.latentDim])
            let outs = try run(mimiDecoder, inputs,
                               outputs: ["audio_frame"] + meta.mimiManifest.map(\.outputName))
            for e in meta.mimiManifest { state[e.inputName] = outs[e.outputName]! }
            audio.append(contentsOf: tensorFloats(outs["audio_frame"]!))
            index += count
        }
        return audio
    }

    /// A conditioning-only flow_lm_main pass (empty sequence): text or voice
    /// enters the KV cache, the conditioning/eos outputs are discarded.
    private func promptFlow(state: inout [String: ORTValue], sequenceLen: Int,
                            textEmbeddings: ORTValue) throws {
        var inputs = state
        inputs["sequence"] = try floatTensor([], shape: [1, sequenceLen, meta.latentDim])
        inputs["text_embeddings"] = textEmbeddings
        let outs = try run(flowMain, inputs, outputs: meta.flowManifest.map(\.outputName))
        for e in meta.flowManifest { state[e.inputName] = outs[e.outputName]! }
    }

    // MARK: - Text preparation (ports of upstream prepare/split)

    /// Port of upstream `prepare_text_prompt`: normalize whitespace, ensure a
    /// leading capital and trailing punctuation, and guess how many frames of
    /// tail the line wants (short lines trail longer).
    static func prepareTextPrompt(_ text: String, padShortInputs: Bool,
                                  removeSemicolons: Bool) -> (text: String, eosGuess: Int) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if removeSemicolons { t = t.replacingOccurrences(of: ";", with: ",") }
        guard !t.isEmpty else { return ("", 1) }
        let words = t.split(separator: " ").count
        let eosGuess = words <= 4 ? 3 : 1
        let first = t.first!
        if first.isLowercase { t = String(first).uppercased() + t.dropFirst() }
        if let last = t.last, last.isLetter || last.isNumber { t += "." }
        if padShortInputs, t.split(separator: " ").count < 5 {
            t = String(repeating: " ", count: 8) + t
        }
        return (t, eosGuess)
    }

    /// Port of upstream `split_into_best_sentences`: cut at sentence enders
    /// (fallback: commas/colons for oversized sentences) and greedily pack
    /// chunks of at most `max_token_per_chunk` tokens.
    func splitIntoBestSentences(_ text: String) -> [String] {
        let (prepared, _) = Self.prepareTextPrompt(
            text, padShortInputs: meta.padWithSpacesForShortInputs,
            removeSemicolons: meta.removeSemicolons)
        guard !prepared.isEmpty else { return [] }
        let tokens = tokenizer.encode(prepared)

        // Upstream drops the first token of ".!...?" — it is the space-ish
        // piece the dummy prefix creates, not a boundary marker.
        let eosTokens = Set(tokenizer.encode(".!...?").dropFirst())
        let boundaries = Self.findBoundaryIndices(tokens, boundaryTokens: eosTokens)
        var segments = segmentsFromBoundaries(tokens, boundaries)

        let fallbackTokens = Set(tokenizer.encode(",;:").dropFirst())
        var refined: [(count: Int, text: String)] = []
        for seg in segments {
            if seg.count <= meta.maxTokenPerChunk { refined.append(seg); continue }
            let subTokens = tokenizer.encode(
                seg.text.trimmingCharacters(in: .whitespaces))
            let subBoundaries = Self.findBoundaryIndices(subTokens, boundaryTokens: fallbackTokens)
            let subSegments = segmentsFromBoundaries(subTokens, subBoundaries)
            if subSegments.count > 1 { refined.append(contentsOf: subSegments) }
            else { refined.append(seg) }
        }
        segments = refined

        var chunks: [String] = []
        var currentChunk = ""
        var currentCount = 0
        for seg in segments {
            if currentChunk.isEmpty {
                currentChunk = seg.text; currentCount = seg.count; continue
            }
            if currentCount + seg.count > meta.maxTokenPerChunk {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespaces))
                currentChunk = seg.text; currentCount = seg.count
            } else {
                currentChunk += " " + seg.text; currentCount += seg.count
            }
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }

    /// Boundary positions: index after each run of boundary tokens, plus both ends.
    static func findBoundaryIndices(_ tokens: [Int], boundaryTokens: Set<Int>) -> [Int] {
        var indices = [0]
        var previousWasBoundary = false
        for (idx, token) in tokens.enumerated() {
            if boundaryTokens.contains(token) {
                previousWasBoundary = true
            } else {
                if previousWasBoundary { indices.append(idx) }
                previousWasBoundary = false
            }
        }
        indices.append(tokens.count)
        return indices
    }

    private func segmentsFromBoundaries(_ tokens: [Int], _ boundaries: [Int])
        -> [(count: Int, text: String)] {
        var segments: [(Int, String)] = []
        for i in 0 ..< boundaries.count - 1 {
            let start = boundaries[i], end = boundaries[i + 1]
            guard end > start else { continue }
            segments.append((end - start, tokenizer.decode(Array(tokens[start ..< end]))))
        }
        return segments
    }

    // MARK: - State plumbing

    /// Build initial state tensors from a bundle manifest. Fills: `nan`
    /// (fresh KV cache), `zeros`, `ones` (bool first-call flags), `empty`
    /// (zero-element tensors whose shape IS the information).
    private func initialState(_ manifest: [StateEntry]) throws -> [String: ORTValue] {
        var state: [String: ORTValue] = [:]
        for e in manifest {
            let count = e.shape.reduce(1, *)
            switch e.dtype {
            case "float32":
                let fill: Float = e.fill == "nan" ? .nan : 0
                state[e.inputName] = try floatTensor(
                    [Float](repeating: fill, count: count), shape: e.shape)
            case "int64":
                state[e.inputName] = try int64Tensor(
                    [Int64](repeating: 0, count: count), shape: e.shape)
            case "bool":
                state[e.inputName] = try boolTensor(
                    ones: e.fill == "ones", count: count, shape: e.shape)
            default:
                throw PocketOnnx.SynthError.badBundle(
                    "state \(e.inputName): unsupported dtype \(e.dtype)")
            }
        }
        return state
    }

    /// Deep-copy a state dict (used to reuse a voice across chunks/lines).
    /// Only float32/int64 appear in the flow manifest, which is the only
    /// state that gets cloned.
    private func clone(_ state: [String: ORTValue],
                       manifest: [StateEntry]) throws -> [String: ORTValue] {
        var copy: [String: ORTValue] = [:]
        for e in manifest {
            guard let v = state[e.inputName], let data = try? v.tensorData() else {
                throw PocketOnnx.SynthError.engineInitFailed("state \(e.inputName) unreadable")
            }
            let shape = tensorShape(v)
            let elementType: ORTTensorElementDataType = e.dtype == "int64" ? .int64 : .float
            copy[e.inputName] = try ORTValue(
                tensorData: NSMutableData(data: data as Data),
                elementType: elementType,
                shape: shape.map { NSNumber(value: $0) })
        }
        return copy
    }

    // MARK: - ORT helpers (same idiom as LuxEngine)

    private func tensor<T>(_ values: [T], shape: [Int],
                           type: ORTTensorElementDataType) throws -> ORTValue {
        // Zero-element tensors still need a non-null backing buffer; ORT only
        // checks the buffer is big ENOUGH for the shape.
        let data: NSMutableData
        if values.isEmpty {
            data = NSMutableData(length: MemoryLayout<T>.stride)!
        } else {
            data = values.withUnsafeBufferPointer {
                NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<T>.stride)
            }
        }
        return try ORTValue(tensorData: data, elementType: type,
                            shape: shape.map { NSNumber(value: $0) })
    }

    private func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        try tensor(values, shape: shape, type: .float)
    }

    private func int64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        try tensor(values, shape: shape, type: .int64)
    }

    /// Mint a bool tensor by running int64 data through the embedded Cast
    /// graph — the only way to a BOOL ORTValue from the ObjC API.
    private func boolTensor(ones: Bool, count: Int, shape: [Int]) throws -> ORTValue {
        guard shape.count == 1 else {
            // The cast graph is rank-1; every bool state in the manifests is
            // shape [1]. A future bundle breaking that should fail loudly.
            throw PocketOnnx.SynthError.badBundle("bool state of rank \(shape.count)")
        }
        let ints = try int64Tensor([Int64](repeating: ones ? 1 : 0, count: count), shape: shape)
        let outs = try run(boolCaster, ["i": ints], outputs: ["o"])
        return outs["o"]!
    }

    private func run(_ session: ORTSession, _ inputs: [String: ORTValue],
                     outputs: [String]) throws -> [String: ORTValue] {
        let out = try session.run(withInputs: inputs, outputNames: Set(outputs), runOptions: nil)
        for name in outputs where out[name] == nil {
            throw PocketOnnx.SynthError.engineInitFailed("run produced no '\(name)' output")
        }
        return out
    }

    private func tensorFloats(_ value: ORTValue) -> [Float] {
        guard let d = try? value.tensorData() else { return [] }
        return (d as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func tensorShape(_ value: ORTValue) -> [Int] {
        guard let info = try? value.typeInfo(),
              let shape = info.tensorTypeAndShapeInfo?.shape else { return [] }
        return shape.map { $0.intValue }
    }

    // MARK: - npy

    /// Read a little-endian float32 .npy (bos_before_voice.npy is
    /// [1,1,1024]); only what numpy.save writes for such an array.
    static func loadNpyFloats(_ url: URL, expectedCount: Int) throws -> [Float] {
        guard let data = try? Data(contentsOf: url) else {
            throw PocketOnnx.SynthError.modelsMissing(url.lastPathComponent)
        }
        guard data.count > 10, data.prefix(6) == Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else {
            throw PocketOnnx.SynthError.badBundle("\(url.lastPathComponent): not .npy")
        }
        let headerLen = Int(data[8]) | Int(data[9]) << 8   // version 1.x
        let header = String(decoding: data[10 ..< 10 + headerLen], as: UTF8.self)
        guard header.contains("'descr': '<f4'"), header.contains("'fortran_order': False") else {
            throw PocketOnnx.SynthError.badBundle(
                "\(url.lastPathComponent): expected C-order <f4, got \(header)")
        }
        let payload = data.dropFirst(10 + headerLen)
        let floats = payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count == expectedCount else {
            throw PocketOnnx.SynthError.badBundle(
                "\(url.lastPathComponent): \(floats.count) floats, expected \(expectedCount)")
        }
        return floats
    }
}

#endif  // os(macOS) — PocketOnnxEngine needs ONNX Runtime
