// LuxSpeechModel.swift
// EngineKit — wires the ported LuxTTS graph (LuxModel/LuxZipformer/LuxVocoder/
// LuxTokenizer) into the app's SpeechModel/ModelProviding contract, mirroring
// MLXSpeechModel's shape for the other backends.

import Foundation
import MLX
import MLXAudioCore
import MLXFFT
import MLXNN
import MLXRandom

// NOTE: `eval(_:)` calls throughout this file are MLX's lazy-graph-materialization
// function (mlx-swift's `MLX.eval`, forces queued GPU ops to actually run) —
// unrelated to arbitrary-code-execution `eval`. Same usage as every other file
// in this port and the rest of EngineKit (e.g. MLXSpeechModel.swift).

// MARK: - Prompt mel-feature extraction

/// Converts a raw reference clip into the 100-dim log-mel features LuxTTS's
/// prompt path and `ZipVoiceDistill.sample(promptFeatures:)` expect.
///
/// Config verbatim from YatharthS/LuxTTS's vocoder/config.yaml
/// feature_extractor block: sample_rate 24000, n_fft 1024, hop_length 256,
/// n_mels 100, padding "center". CRITICAL: norm must be nil (NOT the
/// MLXAudioCore default "slaney") — ningyos/luxtts-onnx independently found
/// that librosa's default norm='slaney' silently produces a ~33x magnitude
/// error against this checkpoint's expected (norm=None, htk=True) features.
enum LuxMelFeatures {
    static let sampleRate = 24_000
    static let nFft = 1024
    static let hopLength = 256
    static let nMels = 100

    /// LuxTTS's `feat_scale` (zipvoice/modeling_utils.py `process_audio`):
    /// the acoustic model is trained/conditioned on log-mel features scaled by
    /// 0.1, and its output must be divided by 0.1 again before the vocoder
    /// (`generate`: `pred_features.permute(0, 2, 1) / 0.1`). Omitting this was
    /// the root cause of the static/noise output: the speech condition was 10x
    /// too large and the ODE's x1 target 10x smaller than what the vocoder and
    /// prompt-reconstruction comparison expected.
    static let featScale: Float = 0.1

    /// audio: 1D float samples at `sampleRate`. Returns (numFrames, nMels).
    ///
    /// Verified against the actual reference (LuxTTS/zipvoice/utils/feature.py
    /// `VocosFbank`): `torchaudio.transforms.MelSpectrogram(..., center=True,
    /// power=1)` — power=1 means the MAGNITUDE spectrogram (|STFT|^1) feeds the
    /// mel filterbank, NOT the power/energy spectrogram (|STFT|^2) — followed by
    /// `mel.clamp(min=1e-7).log()`.
    static func extract(_ audio: MLXArray) -> MLXArray {
        let window = hanningWindow(size: nFft)
        let freqs = stft(audio: audio, window: window, nFft: nFft, hopLength: hopLength, center: true)
        let magnitude = MLX.abs(freqs)
        let filters = melFilters(
            sampleRate: sampleRate, nFft: nFft, nMels: nMels,
            norm: nil, melScale: .htk)
        let mel = matmul(magnitude, filters)
        return MLX.log(MLX.maximum(mel, MLXArray(1e-7)))
    }

    /// RMS of the raw waveform (matches LuxTTS's `rms`/`target_rms` prompt
    /// loudness knob semantics — see zipvoice/modeling_utils.py `_rms_norm_np`).
    static func rms(_ audio: MLXArray) -> Float {
        sqrt(MLX.mean(audio.square()).item(Float.self) + 1e-12)
    }

    /// Scales `audio` in place to `targetRMS`, clamped to [rmsMin, rmsMax] the
    /// same way LuxTTS's `_normalize_prompt_rms_np` does.
    static func normalized(
        _ audio: MLXArray, targetRMS: Float, rmsMin: Float = 0.006, rmsMax: Float = 0.03
    ) -> (audio: MLXArray, rms: Float) {
        let safeTarget = min(max(targetRMS, rmsMin), rmsMax)
        let currentRMS = rms(audio)
        guard currentRMS > 1e-8 else { return (audio, currentRMS) }
        var scaled = audio * (safeTarget / currentRMS)
        let scaledRMS = rms(scaled)
        if scaledRMS > rmsMax {
            scaled = scaled * (rmsMax / scaledRMS)
        }
        return (scaled, currentRMS)
    }

    /// Trims leading/trailing near-silence from the raw prompt waveform and
    /// applies a short fade-in/out. Neither is in the official torch
    /// reference (which just takes the first N seconds of the raw file
    /// as-is) — this mirrors LuxTTS-mlx's `process_audio_mlx` pre-processing
    /// (`_trim_silence_edges_np`/`_apply_fade_np`, defaults: -42dB threshold,
    /// 35ms silence kept, 12ms fade), a documented, working mitigation for a
    /// real artifact: an abrupt/mid-phoneme prompt edge biases the model into
    /// a garbled onset for the first ~1s of GENERATED speech, not just the
    /// prompt echo itself.
    static func trimAndFade(
        _ audio: MLXArray, sampleRate: Int,
        thresholdDB: Float = -42, keepSilenceMs: Float = 35, fadeMs: Float = 12
    ) -> MLXArray {
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty, let peak = samples.map({ abs($0) }).max(), peak > 1e-8 else {
            return audio
        }
        let threshold = peak * pow(10, thresholdDB / 20)
        guard let firstActive = samples.firstIndex(where: { abs($0) > threshold }),
            let lastActive = samples.lastIndex(where: { abs($0) > threshold })
        else { return audio }

        let keep = max(0, Int(Float(sampleRate) * max(keepSilenceMs, 0) / 1000))
        let start = max(0, firstActive - keep)
        let end = min(samples.count, lastActive + keep + 1)
        guard end - start > 8 else { return audio }
        var trimmed = Array(samples[start ..< end])

        let fadeSamples = max(0, Int(Float(sampleRate) * max(fadeMs, 0) / 1000))
        if fadeSamples > 1, trimmed.count > fadeSamples * 2 {
            for i in 0 ..< fadeSamples {
                let ramp = Float(i) / Float(fadeSamples)
                trimmed[i] *= ramp
                trimmed[trimmed.count - 1 - i] *= ramp
            }
        }
        return MLXArray(trimmed)
    }
}

// MARK: - LuxSpeechModel

public final class LuxSpeechModel: SpeechModel, @unchecked Sendable {
    private let model: ZipVoiceDistill
    private let vocoder: LuxVocoder
    private let tokenizer: LuxTokenizer

    /// Same reference-clip-reuse idea as MLXSpeechModel.CachedRef, but caches
    /// the encoded PROMPT (tokens + mel features + rms), not raw audio — the
    /// mel extraction + phonemization are the expensive/GPU part here.
    private struct CachedPrompt {
        let path: String
        let mtime: Date
        let refText: String
        let tokens: [Int]
        let features: MLXArray
        let rms: Float
    }
    private var promptCache: [CachedPrompt] = []
    private let promptCacheLock = NSLock()

    public init(model: ZipVoiceDistill, vocoder: LuxVocoder, tokenizer: LuxTokenizer) {
        self.model = model
        self.vocoder = vocoder
        self.tokenizer = tokenizer
    }

    public var sampleRate: Int { LuxVocoder.outputSampleRate }

    private func encodePrompt(path: String, refText: String?) throws -> CachedPrompt {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date) ?? .distantPast

        promptCacheLock.lock()
        if let index = promptCache.firstIndex(where: {
            $0.path == path && $0.mtime == mtime && $0.refText == (refText ?? "")
        }) {
            let hit = promptCache.remove(at: index)
            promptCache.insert(hit, at: 0)
            promptCacheLock.unlock()
            return hit
        }
        promptCacheLock.unlock()

        guard let refText, !refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // LuxTTS's own tokenizer has no ASR fallback in this port (see
            // LuxTokenizer.swift header) — the reference transcript is required.
            throw EngineError.refAudioRequired(.luxTTS)
        }

        var (_, rawAudio) = try loadAudioArray(
            from: URL(fileURLWithPath: path), sampleRate: LuxMelFeatures.sampleRate)
        // NOTE: LuxTTS's own encode_prompt(duration=5) truncates the reference
        // clip to a few seconds — but that convention assumes the caller's
        // refText is ALREADY just a transcript of those first few seconds
        // (their own examples always pass a short clip with a matching short
        // transcript). This app's Voice Library instead stores one FULL
        // transcript matching a FULL (often 10-80s) clip; blindly truncating
        // only the audio here left the model conditioned on text describing
        // far more speech than it could actually hear in the cropped audio —
        // a real bug (found via the app producing hallucinated/echoed prompt
        // content for voices whose clips are much longer than their
        // proportional 5s-worth of transcript, e.g. ogre-excited: 131 chars
        // of text but a 34s clip). Without word-level alignment to crop the
        // text to match, the correct move is to NOT truncate — audio and
        // refText must describe the same span. This does mean longer clips
        // cost more compute per synthesis; that's a real tradeoff, not a bug.
        rawAudio = LuxMelFeatures.trimAndFade(rawAudio, sampleRate: LuxMelFeatures.sampleRate)
        rawAudio = rawAudio - MLX.mean(rawAudio)  // remove DC bias, matching LuxTTS-mlx
        let (normalizedAudio, measuredRMS) = LuxMelFeatures.normalized(rawAudio, targetRMS: 0.05)
        // feat_scale: the model consumes 0.1-scaled features (see featScale).
        let features = LuxMelFeatures.extract(normalizedAudio) * LuxMelFeatures.featScale
        eval(features)

        let tokens = try tokenizer.textToTokenIDs(refText)
        let entry = CachedPrompt(
            path: path, mtime: mtime, refText: refText,
            tokens: tokens, features: features, rms: measuredRMS)

        promptCacheLock.lock()
        promptCache.insert(entry, at: 0)
        if promptCache.count > 4 { promptCache.removeLast() }
        promptCacheLock.unlock()
        return entry
    }

    public func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        do {
            guard let refPath = request.refAudioPath else {
                throw EngineError.refAudioRequired(.luxTTS)
            }
            let prompt = try encodePrompt(path: refPath, refText: request.refText)
            let textTokens = try tokenizer.textToTokenIDs(request.text)
            let promptTokens = try tokenizer.textToTokenIDs(prompt.refText)

            let promptFeatures = prompt.features.expandedDimensions(axis: 0)  // (1, T, 100)

            let output = model.sample(
                tokens: [textTokens],
                promptTokens: [promptTokens],
                promptFeatures: promptFeatures,
                promptFeaturesLens: [prompt.features.dim(0)],
                duration: .predict,
                numSteps: request.numSteps ?? 4,
                guidanceScale: request.guidanceScale ?? 3.0,
                tShift: request.tShift ?? 0.5,
                speed: request.speed ?? 1.0,
                durationPadFrames: 16
            )
            eval(output.features)

            if ProcessInfo.processInfo.environment["LUXTTS_DUMP_DEBUG"] != nil {
                func dump(_ arr: MLXArray, _ path: String) {
                    let flat = arr.reshaped([-1]).asArray(Float.self)
                    var data = Data()
                    for v in flat { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
                    try? data.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data(
                        "DEBUG dumped \(path) shape=\(arr.shape) count=\(flat.count)\n".utf8))
                }
                dump(prompt.features, "/tmp/lux_prompt_features.f32")
                dump(output.features, "/tmp/lux_output_features.f32")
            }

            // Undo feat_scale before the vocoder, mirroring the reference
            // `pred_features / 0.1` in modeling_utils.generate.
            let wav = vocoder.decode(
                output.features / LuxMelFeatures.featScale,
                returnSmooth: request.returnSmooth ?? true)
            var samplesArray = wav.squeezed()

            // Match the prompt's loudness the way LuxTTS's own generate_mlx does:
            // scale down only if the prompt was quieter than the target used to
            // encode it (never amplify above the encoded target).
            let targetRMS: Float = 0.05
            if prompt.rms < targetRMS, prompt.rms > 1e-8 {
                samplesArray = samplesArray * (prompt.rms / targetRMS)
            }
            samplesArray = MLX.clip(samplesArray, min: -1.0, max: 1.0)
            eval(samplesArray)

            var samples = samplesArray.asArray(Float.self)
            Memory.clearCache()
            samples = await LuxLeadInTrimmer.trimLeadIn(
                samples: samples, sampleRate: sampleRate, expectedText: request.text)
            return samples
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.generationFailed(backend: .luxTTS, message: "\(error)")
        }
    }
}

// MARK: - Loading

public enum LuxModelLoadError: Error, Sendable {
    case weightsNotFound(String)
    case missingTokensFile
    case phonemizerUnavailable(String)
}

extension LuxSpeechModel {
    /// Loads a LuxTTS model from a local directory containing the converted
    /// safetensors produced by `LuxTTS/convert_weights.py` — NOT the raw
    /// `model.pt`/ONNX files `YatharthS/LuxTTS` ships (see the note on
    /// `BackendSpec.spec` for `.luxTTS` in Backend.swift). Expected files:
    ///   - `lux_model.safetensors`  (ZipVoiceDistill: fm_decoder + text_encoder + embed)
    ///   - `lux_vocoder.safetensors` (LuxVocoder, MLX conv layout)
    /// `convert_weights.py --layout mlx` produces both when pointed at
    /// `model.pt` and `vocoder/vocos.bin` respectively.
    ///
    /// Async because the default phonemizer (`MisakiPhonemizer`, the
    /// license-clean in-process G2P — see MisakiPhonemizer.swift) resolves its
    /// dictionaries + BART fallback checkpoint from cache or HuggingFace on
    /// first use.
    public static func load(from directory: URL) async throws -> LuxSpeechModel {
        // Fire-and-forget: surfaces the Speech Recognition permission prompt
        // once, predictably, when the backend loads — not blocking on it (the
        // lead-in trim is best-effort and works fine without it), and not
        // buried inside every synthesize() call.
        Task { await LuxLeadInTrimmer.requestAuthorizationIfNeeded() }

        let modelWeightsURL = directory.appendingPathComponent("lux_model.safetensors")
        let vocoderWeightsURL = directory.appendingPathComponent("lux_vocoder.safetensors")
        guard FileManager.default.fileExists(atPath: modelWeightsURL.path) else {
            throw LuxModelLoadError.weightsNotFound(modelWeightsURL.path)
        }
        guard FileManager.default.fileExists(atPath: vocoderWeightsURL.path) else {
            throw LuxModelLoadError.weightsNotFound(vocoderWeightsURL.path)
        }

        let config = LuxTTSConfig()
        let model = ZipVoiceDistill(config: config)
        var modelWeights = try loadArrays(url: modelWeightsURL)
        // Rename the torch Sequential-index keys ("time_embed.0"/".2",
        // "time_emb.1") to the disambiguated names TimestepEmbedMLP/
        // EncoderTimeEmbed actually declare (see their @ModuleInfo comments) —
        // ModuleParameters.unflattened treats bare-digit path segments as
        // array indices, which collides with these modules' dict-shaped
        // parameter trees otherwise.
        for key in Array(modelWeights.keys) {
            var renamed = key
            renamed = renamed.replacingOccurrences(of: ".time_embed.0.", with: ".time_embed.linear1.")
            renamed = renamed.replacingOccurrences(of: ".time_embed.2.", with: ".time_embed.linear2.")
            renamed = renamed.replacingOccurrences(of: ".time_emb.1.", with: ".time_emb.linear.")
            if renamed != key {
                modelWeights[renamed] = modelWeights.removeValue(forKey: key)
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(modelWeights), verify: [.all])
        eval(model)

        let vocoder = LuxVocoder()
        let vocoderWeights = try loadArrays(url: vocoderWeightsURL)
        try vocoder.loadTorchWeights(vocoderWeights)
        eval(vocoder)

        // In-process, MIT-licensed G2P (misaki port from mlx-audio-swift) —
        // works inside the App Store sandbox, unlike the previous
        // EspeakProcessPhonemizer which shelled out to a GPL espeak-ng binary
        // (kept in LuxTokenizer.swift for dev-CLI parity testing only).
        let phonemizer: any PhonemizerProviding
        do {
            phonemizer = try await MisakiPhonemizer.prepared()
        } catch {
            throw LuxModelLoadError.phonemizerUnavailable("\(error)")
        }
        let tokenizer = try LuxTokenizer(phonemizer: phonemizer)

        return LuxSpeechModel(model: model, vocoder: vocoder, tokenizer: tokenizer)
    }
}
