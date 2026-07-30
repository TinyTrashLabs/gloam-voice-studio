// LuxVocoder.swift
//
// Vocos-style dual-path vocoder for LuxTTS (24 kHz backbone + 48 kHz upsampler
// head, merged with an FFT crossover), hand-ported from:
//   - linacodec `src/linacodec/vocoder/{vocos,upsampler_block,linkwitz}.py`
//     (ysharma3501/LinaCodec — the torch ground truth LuxTTS actually runs)
//   - official vocos `vocos/{models,heads}.py` (VocosBackbone, ISTFTHead)
//   - LuxTTS-mlx `zipvoice/mlx/vocoder.py` (MLX structural reference)
//   - luxtts-onnx `src/luxtts_onnx/exporter.py` RealISTFT (independent
//     cross-check for the DFT-basis ISTFT)
//
// Inference-only port, channels-last (B, L, C) throughout as MLX convention.
// Config (YatharthS/LuxTTS vocoder/config.yaml): backbone 100→512,
// intermediate 1536, 8 ConvNeXt layers; both ISTFT heads n_fft=1024,
// hop=256, padding=center; upsampler in=512, factors [2, 1], kernels [8, 8].
//
// Weight loading: torch `vocos.bin` layouts differ from MLX (Conv1d
// (O, I, K) → (O, K, I); ConvTranspose1d (I, O, K) → (O, K, I); Snake alpha
// (1, C, 1) → (1, 1, C)). Use `LuxVocoder.sanitize(torchWeights:)` /
// `loadTorchWeights(_:)` to convert a flat torch-key dictionary.

import Foundation
import MLX
import MLXNN

// MARK: - Snake1d

/// Ports linacodec `Snake1d` (upsampler_block.py):
/// `x + (alpha + 1e-9)^-1 * sin(alpha * x)^2`, alpha stored channels-last.
public final class LuxSnake1d: Module, UnaryLayer {
    @ParameterInfo(key: "alpha") var alpha: MLXArray

    public init(channels: Int) {
        super.init()
        self._alpha.wrappedValue = MLXArray.ones([1, 1, channels])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        x + (1.0 / (alpha + 1e-9)) * square(sin(alpha * x))
    }
}

// MARK: - ConvNeXt block

/// Ports vocos `ConvNeXtBlock` (models.py): depthwise Conv1d(k7) → LayerNorm →
/// pointwise MLP with GELU → layer scale (gamma) → residual.
/// AdaLayerNorm branch omitted (LuxTTS config has no adanorm embeddings).
public final class LuxConvNeXtBlock: Module, UnaryLayer {
    @ModuleInfo(key: "dwconv") var dwConv: Conv1d
    @ModuleInfo(key: "norm") var norm: LayerNorm
    @ModuleInfo(key: "pwconv1") var pwConv1: Linear
    @ModuleInfo(key: "pwconv2") var pwConv2: Linear
    @ParameterInfo(key: "gamma") var gamma: MLXArray

    public init(dim: Int, intermediateDim: Int, layerScaleInitValue: Float) {
        super.init()
        self._dwConv.wrappedValue = Conv1d(
            inputChannels: dim, outputChannels: dim, kernelSize: 7, padding: 3,
            groups: dim, bias: true)
        self._norm.wrappedValue = LayerNorm(dimensions: dim, eps: 1e-6)
        self._pwConv1.wrappedValue = Linear(dim, intermediateDim)
        self._pwConv2.wrappedValue = Linear(intermediateDim, dim)
        self._gamma.wrappedValue = layerScaleInitValue * MLXArray.ones([dim])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var h = dwConv(x)
        h = norm(h)
        h = pwConv1(h)
        // torch nn.GELU() default is the exact (erf) form; MLXNN `gelu` matches.
        h = gelu(h)
        h = pwConv2(h)
        return residual + gamma * h
    }
}

// MARK: - Backbone

/// Ports vocos `VocosBackbone` (models.py): embed Conv1d(k7) → LayerNorm →
/// N ConvNeXt blocks → final LayerNorm. Input (B, T, inputChannels) mel-ish
/// features, output (B, T, dim).
public final class LuxVocosBackbone: Module, UnaryLayer {
    @ModuleInfo(key: "embed") var embed: Conv1d
    @ModuleInfo(key: "norm") var norm: LayerNorm
    @ModuleInfo(key: "convnext") var convNeXt: [LuxConvNeXtBlock]
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    public init(inputChannels: Int, dim: Int, intermediateDim: Int, numLayers: Int) {
        super.init()
        self._embed.wrappedValue = Conv1d(
            inputChannels: inputChannels, outputChannels: dim, kernelSize: 7, padding: 3)
        self._norm.wrappedValue = LayerNorm(dimensions: dim, eps: 1e-6)
        // layer_scale_init_value defaults to 1/num_layers in vocos; checkpoint
        // values overwrite it, kept for init parity.
        self._convNeXt.wrappedValue = (0 ..< numLayers).map { _ in
            LuxConvNeXtBlock(
                dim: dim, intermediateDim: intermediateDim,
                layerScaleInitValue: 1.0 / Float(numLayers))
        }
        self._finalLayerNorm.wrappedValue = LayerNorm(dimensions: dim, eps: 1e-6)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = embed(x)
        h = norm(h)
        for block in convNeXt {
            h = block(h)
        }
        return finalLayerNorm(h)
    }
}

// MARK: - ISTFT

/// Inverse STFT via a real-valued DFT basis matmul + overlap-add, following
/// luxtts-onnx `RealISTFT` (exporter.py) — exact irfft for even n_fft, no
/// complex-tensor construction needed.
///
/// Numerically-sensitive choices (all matching `torch.istft(..., center=True)`,
/// which is what the official vocos `ISTFTHead` runs for the config's
/// `padding: center`):
///   - Window is the PERIODIC Hann (`torch.hann_window`: denominator N, not
///     N-1). vocos-mlx uses the symmetric one — that is a deviation from the
///     torch model this checkpoint was trained with.
///   - Overlap-add is normalized by the summed SQUARED window envelope
///     (+1e-11), as in torch.istft / luxtts-onnx. vocos-mlx divides by the
///     plain window sum, which introduces a ~0.75x gain error.
///   - `n_fft/2` samples are trimmed from BOTH ends (center padding). This is
///     also what keeps the 24k and 48k paths sample-aligned for the crossover
///     merge (with luxtts-onnx's "same"-style `(win-hop)/2` trim the two paths
///     end up 128 samples apart at 48 kHz). vocos-mlx does not trim at all.
public final class LuxISTFT {
    public let nFft: Int
    public let hopLength: Int
    private let phases: Int  // nFft / hopLength

    private let cosBasis: MLXArray  // (nBins, nFft)
    private let sinBasis: MLXArray  // (nBins, nFft)
    private let window: MLXArray  // (nFft,)

    public init(nFft: Int, hopLength: Int) {
        precondition(nFft % 2 == 0, "real DFT basis assumes even n_fft (Nyquist bin not doubled)")
        precondition(
            nFft % hopLength == 0,
            "overlapAdd's polyphase decomposition requires hopLength to divide nFft evenly")
        self.nFft = nFft
        self.hopLength = hopLength
        self.phases = nFft / hopLength

        let nBins = nFft / 2 + 1
        let n = MLXArray.arange(nFft, dtype: .float32)
        let k = MLXArray.arange(nBins, dtype: .float32)
        let angles =
            expandedDimensions(k, axis: 1) * expandedDimensions(n, axis: 0)
            * (2.0 * Float.pi / Float(nFft))
        // irfft as matmul: scale interior bins by 2 (conjugate symmetry), all by
        // 1/n_fft; DC and Nyquist appear once.
        var scale = [Float](repeating: 2.0 / Float(nFft), count: nBins)
        scale[0] = 1.0 / Float(nFft)
        scale[nBins - 1] = 1.0 / Float(nFft)
        let scaleCol = expandedDimensions(MLXArray(scale), axis: 1)
        self.cosBasis = cos(angles) * scaleCol
        self.sinBasis = sin(angles) * scaleCol

        self.window = 0.5 * (1.0 - cos(n * (2.0 * Float.pi / Float(nFft))))
    }

    /// Overlap-add `frames` (B, T, nFft), each frame hopLength samples after
    /// the previous, into (B, (T + phases - 1) * hopLength).
    ///
    /// Mathematically identical to a transposed conv with an identity kernel
    /// (the textbook OLA-as-fold trick), but implemented directly: MLX's
    /// dense conv path has no fast kernel for a (C_out=nFft, C_in=nFft)
    /// identity weight, and materializes an intermediate on the order of
    /// T * nFft * nFft * hopLength elements — 522 BILLION for this model's
    /// shapes (T≈1944, nFft=1024, hop=256), a 2 TB allocation that crashes
    /// immediately. Since hopLength evenly divides nFft here (phases=4),
    /// each frame splits into `phases` non-overlapping hop-sized chunks;
    /// summing those `phases` chunks at their (fixed, small) sample offsets
    /// reproduces OLA in O(T * nFft) — no giant intermediate, no conv at all.
    private func overlapAdd(_ frames: MLXArray) -> MLXArray {
        let batch = frames.dim(0)
        let frameCount = frames.dim(1)
        let outLen = (frameCount + phases - 1) * hopLength
        var acc = MLXArray.zeros([batch, outLen])
        for r in 0 ..< phases {
            // Samples [r*hop, (r+1)*hop) of every frame, flattened across
            // frames — this is exactly the r-th hop-sized polyphase band.
            let band = frames[.ellipsis, (r * hopLength) ..< ((r + 1) * hopLength)]
            let flatBand = band.reshaped([batch, frameCount * hopLength])
            let leftPad = r * hopLength
            let rightPad = outLen - leftPad - frameCount * hopLength
            acc = acc + padded(flatBand, widths: [IntOrPair([0, 0]), IntOrPair([leftPad, rightPad])])
        }
        return acc
    }

    /// specReal/specImag: (B, T, nBins) → audio (B, (T-1)*hop).
    public func callAsFunction(_ specReal: MLXArray, _ specImag: MLXArray) -> MLXArray {
        let frameCount = specReal.dim(1)
        // ifft = cos_basis @ real - sin_basis @ imag (luxtts-onnx RealISTFT)
        var frames = matmul(specReal, cosBasis) - matmul(specImag, sinBasis)  // (B, T, nFft)
        frames = frames * window

        let y = overlapAdd(frames)  // (B, L)

        let windowSq = broadcast(square(window), to: [1, frameCount, nFft])
        let envelope = overlapAdd(windowSq)  // (1, L)

        let normalized = y / (envelope + 1e-11)  // (B, L)
        let pad = nFft / 2
        let total = normalized.dim(-1)
        return normalized[0..., pad ..< (total - pad)]
    }
}

// MARK: - ISTFT head

/// Ports vocos `ISTFTHead` (heads.py): Linear(dim → n_fft + 2) predicting
/// log-magnitude and phase halves, then ISTFT. Input (B, T, dim), output (B, samples).
public final class LuxISTFTHead: Module {
    @ModuleInfo(key: "out") var out: Linear

    // Not a Module property type, so its basis/window arrays stay out of
    // `parameters()` (they are deterministic constants, not checkpoint keys).
    let istft: LuxISTFT

    public init(dim: Int, nFft: Int, hopLength: Int) {
        self.istft = LuxISTFT(nFft: nFft, hopLength: hopLength)
        super.init()
        self._out.wrappedValue = Linear(dim, nFft + 2)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let nBins = istft.nFft / 2 + 1
        let h = out(x)  // (B, T, nFft + 2)
        // torch: chunk(2, dim=1) after transpose — first half magnitudes, second phases.
        var mag = exp(h[.ellipsis, 0 ..< nBins])
        // Safety clip from vocos: upper bound only, at 1e2.
        mag = clip(mag, max: 1e2)
        let p = h[.ellipsis, nBins...]
        let specReal = mag * cos(p)
        let specImag = mag * sin(p)
        return istft(specReal, specImag)
    }
}

// MARK: - Resnet block

/// Ports linacodec `ResnetBlock` (upsampler_block.py):
/// norm1 → snake1 → conv1 → norm2 → snake2 → conv2, residual add.
/// The time-embedding branch is omitted (UpSamplerBlock builds these with
/// `temb_channels=0`, so the checkpoint has no `temb_proj` keys).
public final class LuxResnetBlock: Module {
    public let inChannels: Int
    public let outChannels: Int

    @ModuleInfo(key: "snake1") var snake1: LuxSnake1d
    @ModuleInfo(key: "norm1") var norm1: GroupNorm
    @ModuleInfo(key: "conv1") var conv1: Conv1d
    @ModuleInfo(key: "norm2") var norm2: GroupNorm
    @ModuleInfo(key: "conv2") var conv2: Conv1d
    @ModuleInfo(key: "snake2") var snake2: LuxSnake1d
    @ModuleInfo(key: "nin_shortcut") var ninShortcut: Conv1d?

    public init(inChannels: Int, outChannels: Int? = nil) {
        self.inChannels = inChannels
        self.outChannels = outChannels ?? inChannels
        super.init()
        self._snake1.wrappedValue = LuxSnake1d(channels: inChannels)
        self._norm1.wrappedValue = GroupNorm(
            groupCount: 32, dimensions: inChannels, eps: 1e-6, pytorchCompatible: true)
        self._conv1.wrappedValue = Conv1d(
            inputChannels: inChannels, outputChannels: self.outChannels,
            kernelSize: 3, padding: 1)
        self._norm2.wrappedValue = GroupNorm(
            groupCount: 32, dimensions: self.outChannels, eps: 1e-6, pytorchCompatible: true)
        self._conv2.wrappedValue = Conv1d(
            inputChannels: self.outChannels, outputChannels: self.outChannels,
            kernelSize: 3, padding: 1)
        self._snake2.wrappedValue = LuxSnake1d(channels: self.outChannels)
        self._ninShortcut.wrappedValue =
            inChannels != self.outChannels
            ? Conv1d(
                inputChannels: inChannels, outputChannels: self.outChannels,
                kernelSize: 1, padding: 0)
            : nil
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = norm1(x)
        h = snake1(h)
        h = conv1(h)
        h = norm2(h)
        h = snake2(h)
        h = conv2(h)
        var shortcut = x
        if let ninShortcut {
            shortcut = ninShortcut(shortcut)
        }
        return shortcut + h
    }
}

// MARK: - Upsampler

/// Ports linacodec `UpSamplerBlock` (upsampler_block.py): per stage a
/// ConvTranspose1d (halving channels) + ResnetBlock, then Linear back to
/// `inChannels` and a final Snake. LuxTTS config: in=512, factors [2, 1],
/// kernels [8, 8] → doubles the frame rate for the 48 kHz head.
/// The torch checkpoint is saved AFTER `remove_parametrizations`, so the
/// transposed convs carry plain `weight`/`bias` (no weight-norm keys);
/// `sanitize` still reconstructs weight-norm keys defensively if present.
public final class LuxUpSamplerBlock: Module, UnaryLayer {
    @ModuleInfo(key: "upsample_layers") var upsampleLayers: [ConvTransposed1d]
    @ModuleInfo(key: "resnet_blocks") var resnetBlocks: [LuxResnetBlock]
    @ModuleInfo(key: "out_proj") var outProj: Linear
    @ModuleInfo(key: "final_snake") var finalSnake: LuxSnake1d

    public init(inChannels: Int, upsampleFactors: [Int], kernelSizes: [Int]? = nil) {
        let kernels = kernelSizes ?? Array(repeating: 8, count: upsampleFactors.count)
        precondition(kernels.count == upsampleFactors.count)
        super.init()
        var layers: [ConvTransposed1d] = []
        var blocks: [LuxResnetBlock] = []
        for (i, (k, u)) in zip(kernels, upsampleFactors).enumerated() {
            let cIn = inChannels / (1 << i)
            let cOut = inChannels / (1 << (i + 1))
            layers.append(
                ConvTransposed1d(
                    inputChannels: cIn, outputChannels: cOut, kernelSize: k,
                    stride: u, padding: (k - u) / 2))
            blocks.append(LuxResnetBlock(inChannels: cOut, outChannels: cOut))
        }
        self._upsampleLayers.wrappedValue = layers
        self._resnetBlocks.wrappedValue = blocks
        self._outProj.wrappedValue = Linear(
            inChannels / (1 << upsampleFactors.count), inChannels, bias: true)
        self._finalSnake.wrappedValue = LuxSnake1d(channels: inChannels)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for (up, block) in zip(upsampleLayers, resnetBlocks) {
            h = block(up(h))
        }
        h = outProj(h)
        return finalSnake(h)
    }
}

// MARK: - FFT helpers

/// Smallest power of 2 >= n. MLX's FFT falls back to a Bluestein algorithm
/// for non-power-of-2 sizes — including 5-smooth (factors only 2, 3, 5)
/// composites, empirically confirmed by this crashing even after padding to
/// a 5-smooth length — and that Bluestein path has a real crash (an internal
/// assertion failure, observed as SIGABRT in mlx::core::fft_op/four_step_fft)
/// for certain — apparently prime-heavy — sub-factor sizes. Audio lengths
/// here vary per voice/text (no fixed prompt truncation), so any length can
/// occur; every MLXFFT.rfft/irfft call in this file zero-pads up to a power
/// of 2 first (the one size class every FFT implementation's fast path is
/// guaranteed to support) and trims back down after.
private func nextFFTFriendlySize(_ n: Int) -> Int {
    guard n > 1 else { return max(n, 1) }
    var candidate = 1
    while candidate < n { candidate <<= 1 }
    return candidate
}

/// Zero-pads only the last axis of `x` up to `target` samples (no-op if
/// already that length).
private func padLastAxis(_ x: MLXArray, to target: Int) -> MLXArray {
    let n = x.dim(-1)
    guard target != n else { return x }
    var widths = Array(repeating: IntOrPair([0, 0]), count: x.ndim)
    widths[widths.count - 1] = IntOrPair([0, target - n])
    return padded(x, widths: widths)
}

/// Ports LuxTTS-mlx `_fft_resample_np` (vocoder.py): zero-pad/truncate the
/// rfft spectrum, irfft at the new length, rescale by newN/n.
///
/// NOTE (numerically-sensitive): the torch ground truth resamples with
/// `torchaudio.functional.resample` (windowed-sinc, slight rolloff near the
/// source Nyquist). This FFT method — from the primary MLX reference — is
/// zero-phase and flat to Nyquist instead. The difference concentrates right
/// where the crossover sits; listen for artifacts around 11–12 kHz in
/// validation.
func luxFFTResample(_ audio: MLXArray, from srcRate: Int, to dstRate: Int) -> MLXArray {
    guard srcRate != dstRate else { return audio }
    let n = audio.dim(-1)
    let newN = Int((Double(n) * Double(dstRate) / Double(srcRate)).rounded())
    guard newN > 1, newN != n else { return audio }

    let paddedN = nextFFTFriendlySize(n)
    let paddedAudio = padLastAxis(audio, to: paddedN)
    let paddedNewN = Int((Double(paddedN) * Double(dstRate) / Double(srcRate)).rounded())

    let spec = MLXFFT.rfft(paddedAudio, axis: -1)
    // MLX irfft pads/truncates the spectrum internally, matching the
    // reference's explicit pad/slice; trim back to the true (unpadded) target.
    let resampled = MLXFFT.irfft(spec, n: paddedNewN, axis: -1)
    return resampled[.ellipsis, 0 ..< newN] * (Float(newN) / Float(n))
}

/// Ports linacodec `crossover_merge_linkwitz_riley` (linkwitz.py), identically
/// reproduced by LuxTTS-mlx `_crossover_merge_linkwitz_riley_np`: despite the
/// name this is a zero-phase FFT brick-wall with a cubic-Hermite smoothstep
/// over `transitionBins` bins — NOT a true LR4 response (luxtts-onnx uses a
/// real Butterworth-squared curve instead; we match the torch ground truth).
/// `highPath` (48k head) supplies bins above the cutoff, `lowPath` (resampled
/// 24k head) below.
func luxCrossoverMergeLinkwitzRiley(
    highPath: MLXArray,
    lowPath: MLXArray,
    sampleRate: Int = 48000,
    cutoff: Float,
    transitionBins: Int = 8
) -> MLXArray {
    let n = highPath.dim(-1)
    let paddedN = nextFFTFriendlySize(n)
    let specHigh = MLXFFT.rfft(padLastAxis(highPath, to: paddedN), axis: -1)
    let specLow = MLXFFT.rfft(padLastAxis(lowPath, to: paddedN), axis: -1)

    let nBins = specHigh.dim(-1)
    // Reference maps cutoff with n_bins (not n_bins - 1) and truncates —
    // one-bin-scale bias kept intentionally for parity.
    let cutoffBin = Int((cutoff / (Float(sampleRate) / 2.0)) * Float(nBins))
    let half = transitionBins / 2
    let start = max(0, cutoffBin - half)
    let end = min(nBins, cutoffBin + half)
    let width = end - start

    var mask = [Float](repeating: 1.0, count: nBins)
    if width > 0 {
        for i in 0 ..< start { mask[i] = 0 }
        for j in 0 ..< width {
            // np.linspace(0, 1, width) then smoothstep t^2 (3 - 2t); linspace
            // with a single point yields 0.
            let t = width == 1 ? Float(0) : Float(j) / Float(width - 1)
            mask[start + j] = t * t * (3.0 - 2.0 * t)
        }
    }

    let maskArray = MLXArray(mask)  // broadcasts over leading axes
    let merged = specHigh * maskArray + specLow * (1.0 - maskArray)
    let result = MLXFFT.irfft(merged, n: paddedN, axis: -1)
    return paddedN == n ? result : result[.ellipsis, 0 ..< n]
}

// MARK: - Vocoder

/// Configuration mirroring `vocoder/config.yaml` of YatharthS/LuxTTS.
public struct LuxVocoderConfig: Sendable {
    public var inputChannels: Int
    public var dim: Int
    public var intermediateDim: Int
    public var numLayers: Int
    public var nFft: Int
    public var hopLength: Int
    public var sampleRate: Int
    public var upsampleFactors: [Int]
    public var kernelSizes: [Int]

    public init(
        inputChannels: Int = 100,
        dim: Int = 512,
        intermediateDim: Int = 1536,
        numLayers: Int = 8,
        nFft: Int = 1024,
        hopLength: Int = 256,
        sampleRate: Int = 24000,
        upsampleFactors: [Int] = [2, 1],
        kernelSizes: [Int] = [8, 8]
    ) {
        self.inputChannels = inputChannels
        self.dim = dim
        self.intermediateDim = intermediateDim
        self.numLayers = numLayers
        self.nFft = nFft
        self.hopLength = hopLength
        self.sampleRate = sampleRate
        self.upsampleFactors = upsampleFactors
        self.kernelSizes = kernelSizes
    }
}

/// Ports linacodec `Vocos` (vocos.py) as used by LuxTTS: dual-path decode —
/// a 24 kHz ISTFT head (upsampled to 48 kHz, the "smooth" path) and a native
/// 48 kHz head over upsampled features, crossover-merged for the sharp path.
/// Both output modes are 48 kHz.
public final class LuxVocoder: Module {
    /// Both decode paths emit audio at this rate.
    public static let outputSampleRate = 48000

    @ModuleInfo(key: "backbone") var backbone: LuxVocosBackbone
    @ModuleInfo(key: "head") var head: LuxISTFTHead
    @ModuleInfo(key: "upsampler") var upsampler: LuxUpSamplerBlock
    @ModuleInfo(key: "head_48k") var head48k: LuxISTFTHead

    public let sampleRate: Int

    /// Crossover cutoff in Hz (`vocos.freq_range` upstream). The linacodec
    /// class default is 4000, but the LuxTTS pipeline (luxvoice.py) sets 12000
    /// right after loading — 12000 is what the released model runs with.
    public var crossoverCutoff: Float = 12000

    public init(_ config: LuxVocoderConfig = LuxVocoderConfig()) {
        self.sampleRate = config.sampleRate
        super.init()
        self._backbone.wrappedValue = LuxVocosBackbone(
            inputChannels: config.inputChannels, dim: config.dim,
            intermediateDim: config.intermediateDim, numLayers: config.numLayers)
        self._head.wrappedValue = LuxISTFTHead(
            dim: config.dim, nFft: config.nFft, hopLength: config.hopLength)
        self._upsampler.wrappedValue = LuxUpSamplerBlock(
            inChannels: config.dim, upsampleFactors: config.upsampleFactors,
            kernelSizes: config.kernelSizes)
        self._head48k.wrappedValue = LuxISTFTHead(
            dim: config.dim, nFft: config.nFft, hopLength: config.hopLength)
    }

    /// Decode acoustic features (B, T, inputChannels) to 48 kHz audio (B, samples).
    ///
    /// - Parameter returnSmooth: maps to upstream `return_smooth`.
    ///   `true` → upstream `return_48k = False`: the 24 kHz head alone,
    ///   FFT-resampled to 48 kHz ("smoother/clearer" default of the public
    ///   LuxTTS API). `false` → the sharper dual-path output: 48 kHz head above
    ///   `crossoverCutoff`, resampled 24 kHz head below, crossover-merged.
    public func decode(_ features: MLXArray, returnSmooth: Bool = false) -> MLXArray {
        let feats = backbone(features)  // (B, T, dim)

        // The ±1 clips follow the MLX reference; the torch ground truth does
        // not clip anywhere in decode. They only bite if a path overshoots
        // full scale — remove if parity checks show audible differences.
        var audio24 = head(feats)  // (B, L24) @ 24 kHz
        audio24 = clip(audio24, min: -1.0, max: 1.0)
        var audio24Up = luxFFTResample(audio24, from: sampleRate, to: sampleRate * 2)

        if returnSmooth {
            return audio24Up
        }

        let upsampled = upsampler(feats)  // (B, ~2T, dim)
        var audio48 = head48k(upsampled)  // (B, L48) @ 48 kHz
        audio48 = clip(audio48, min: -1.0, max: 1.0)

        let minLen = min(audio48.dim(-1), audio24Up.dim(-1))
        audio48 = audio48[.ellipsis, 0 ..< minLen]
        audio24Up = audio24Up[.ellipsis, 0 ..< minLen]

        let merged = luxCrossoverMergeLinkwitzRiley(
            highPath: audio48,
            lowPath: audio24Up,
            sampleRate: sampleRate * 2,
            cutoff: crossoverCutoff)
        return clip(merged, min: -1.0, max: 1.0)
    }

    // MARK: Weight loading

    /// Convert a flat torch-keyed state dict (from `vocoder/vocos.bin`) into
    /// this module's key space and MLX tensor layouts.
    public static func sanitize(torchWeights: [String: MLXArray]) -> [String: MLXArray] {
        var flat: [String: MLXArray] = [:]
        for (rawKey, value) in torchWeights {
            let key = rawKey.hasPrefix("module.") ? String(rawKey.dropFirst("module.".count)) : rawKey
            // Feature extractor buffers (mel filterbank, STFT window) and the
            // heads' ISTFT window buffers are recomputed here, not loaded.
            if key.hasPrefix("feature_extractor.") || key.contains(".istft.") { continue }
            flat[key] = value
        }

        // Defensive weight-norm reconstruction (w = g * v / ||v||, norm over
        // all dims but 0, per torch weight_norm dim=0). The released vocos.bin
        // is saved post-remove_parametrizations, so this normally never fires.
        var merged: [String: MLXArray] = [:]
        for (key, value) in flat {
            if key.hasSuffix("parametrizations.weight.original0") || key.hasSuffix(".weight_g") {
                continue  // handled with its partner below
            }
            if key.hasSuffix("parametrizations.weight.original1") || key.hasSuffix(".weight_v") {
                let (gKey, base): (String, String)
                if key.hasSuffix("parametrizations.weight.original1") {
                    gKey = key.replacingOccurrences(of: ".original1", with: ".original0")
                    base = key.replacingOccurrences(
                        of: ".parametrizations.weight.original1", with: ".weight")
                } else {
                    gKey = key.replacingOccurrences(of: ".weight_v", with: ".weight_g")
                    base = key.replacingOccurrences(of: ".weight_v", with: ".weight")
                }
                guard let g = flat[gKey] else { continue }
                let norm = sqrt(sum(square(value), axes: [1, 2], keepDims: true))
                merged[base] = g * value / norm
                continue
            }
            merged[key] = value
        }

        var result: [String: MLXArray] = [:]
        for (key, value) in merged {
            var v = value
            if key.hasSuffix(".weight"), v.ndim == 3 {
                if key.contains("upsample_layers") {
                    // torch ConvTranspose1d (in, out, K) → MLX (out, K, in)
                    v = v.transposed(1, 2, 0)
                } else {
                    // torch Conv1d (out, in/groups, K) → MLX (out, K, in/groups)
                    v = v.transposed(0, 2, 1)
                }
            } else if key.hasSuffix(".alpha"), v.ndim == 3 {
                // torch Snake alpha (1, C, 1) → channels-last (1, 1, C)
                v = v.transposed(0, 2, 1)
            }
            result[key] = v
        }
        return result
    }

    /// Sanitize and apply a torch state dict; throws if any parameter is
    /// missing or shaped wrong.
    public func loadTorchWeights(_ torchWeights: [String: MLXArray]) throws {
        let weights = Self.sanitize(torchWeights: torchWeights)
        try update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        // MLX.eval materializes the lazy weight arrays up front (it does not
        // execute code — no relation to code-eval).
        eval(self)
    }
}
