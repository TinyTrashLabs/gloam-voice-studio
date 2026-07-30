// LuxLayers.swift
//
// Shared Zipformer2 building blocks for LuxTTS (ZipVoice), hand-ported from the
// official PyTorch implementation:
//   zipvoice/models/modules/scaling.py
//   zipvoice/models/modules/zipformer.py
// (k2-fsa ZipVoice, Xiaomi Corp., Apache-2.0)
//
// Inference-only port. Training-only machinery (Balancer, Whiten, Dropout2/3,
// ScheduledFloat schedules, limit_param_value, sequence dropout, penalties) is
// omitted or reduced to identity, matching what the torch forward passes compute
// with `.eval()` / requires_grad=False. Each such shortcut is noted at the site.

import Foundation
import MLX
import MLXNN

// MARK: - Activations

/// Ports torch `swoosh_l` / `SwooshLForward` (scaling.py):
/// `log(1 + exp(x - 4)) - 0.08*x - 0.035`.
public func swooshL(_ x: MLXArray) -> MLXArray {
    logAddExp(MLXArray(Float(0)), x - 4.0) - 0.08 * x - 0.035
}

/// Ports torch `swoosh_r` / `SwooshRForward` (scaling.py):
/// `log(1 + exp(x - 1)) - 0.08*x - 0.313261687`.
public func swooshR(_ x: MLXArray) -> MLXArray {
    logAddExp(MLXArray(Float(0)), x - 1.0) - 0.08 * x - 0.313261687
}

/// Ports torch `SwooshL` (scaling.py).
public final class SwooshL: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { swooshL(x) }
}

/// Ports torch `SwooshR` (scaling.py).
public final class SwooshR: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { swooshR(x) }
}

// MARK: - Training-only passthroughs

/// Ports torch `Balancer` (scaling.py). It only shapes gradients in backprop
/// (its forward is the identity), so at inference it is a no-op.
public final class Balancer: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { x }
}

/// Ports torch `Whiten` (scaling.py). Forward returns the input unmodified
/// (it only adds a gradient penalty in backprop), so at inference it is a no-op.
public final class Whiten: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { x }
}

// MARK: - BiasNorm

/// Ports torch `BiasNorm` (scaling.py):
/// `x * (mean((x - bias)^2, dim=channel_dim, keepdim=True) ** -0.5) * exp(log_scale)`.
/// Note: exactly matches torch — no epsilon inside the mean (the broken MLX
/// Python port added 1e-8 there).
public final class BiasNorm: Module, UnaryLayer {
    public let numChannels: Int
    public let channelDim: Int

    @ParameterInfo(key: "log_scale") var logScale: MLXArray
    @ParameterInfo(key: "bias") var bias: MLXArray

    public init(_ numChannels: Int, channelDim: Int = -1, logScale: Float = 1.0) {
        self.numChannels = numChannels
        self.channelDim = channelDim
        super.init()
        // Shape [1], not a bare scalar: the reference checkpoint stores
        // log_scale as a 1-element tensor (`nn.Parameter(torch.zeros(1))`),
        // and MLX's strict parameter-shape verification on load requires
        // matching that exactly. exp(logScale) broadcasts the same either way.
        self._logScale.wrappedValue = MLXArray([logScale])
        self._bias.wrappedValue = MLXArray.zeros([numChannels])
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var dim = channelDim
        if dim < 0 { dim += x.ndim }
        var b = bias
        if dim + 1 < x.ndim {
            for _ in (dim + 1) ..< x.ndim {
                b = expandedDimensions(b, axis: -1)
            }
        }
        let scales = rsqrt(mean(square(x - b), axis: dim, keepDims: true)) * exp(logScale)
        return x * scales
    }
}

// MARK: - ScaledLinear

/// Ports torch `ScaledLinear` (scaling.py). `initial_scale` only rescales the
/// random init; checkpoint weights overwrite it, so at inference this is a
/// plain `Linear`. The parameter is kept for call-site traceability.
public func scaledLinear(
    _ inputDimensions: Int,
    _ outputDimensions: Int,
    bias: Bool = true,
    initialScale: Float = 1.0
) -> Linear {
    Linear(inputDimensions, outputDimensions, bias: bias)
}

// MARK: - ActivationDropoutAndLinear

public enum SwooshActivation: String, Sendable {
    case swooshL = "SwooshL"
    case swooshR = "SwooshR"
}

/// Ports torch `ActivationDropoutAndLinear` (scaling.py):
/// activation → dropout → linear. Dropout skipped (inference-only).
/// `weight`/`bias` live directly on this module, matching the torch checkpoint
/// layout (e.g. `...out_proj.weight`, not `...out_proj.linear.weight`).
public final class ActivationDropoutAndLinear: Module, UnaryLayer {
    public let activation: SwooshActivation

    @ParameterInfo(key: "weight") var weight: MLXArray
    @ParameterInfo(key: "bias") var bias: MLXArray?

    public init(
        _ inputDimensions: Int,
        _ outputDimensions: Int,
        bias: Bool = true,
        activation: SwooshActivation = .swooshL,
        initialScale: Float = 1.0
    ) {
        self.activation = activation
        super.init()
        self._weight.wrappedValue = MLXArray.zeros([outputDimensions, inputDimensions])
        if bias {
            self._bias.wrappedValue = MLXArray.zeros([outputDimensions])
        }
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x =
            switch activation {
            case .swooshL: swooshL(x)
            case .swooshR: swooshR(x)
            }
        x = matmul(x, weight.T)
        if let bias {
            x = x + bias
        }
        return x
    }
}

// MARK: - BypassModule

/// Ports torch `BypassModule` (zipformer.py):
/// `src_orig + (src - src_orig) * bypass_scale`.
/// At inference `_get_bypass_scale` returns the learned scale directly
/// (skip-rate / straight-through randomization is training-only).
public final class BypassModule: Module {
    @ParameterInfo(key: "bypass_scale") var bypassScale: MLXArray

    public init(_ embedDim: Int) {
        super.init()
        self._bypassScale.wrappedValue = MLXArray.full([embedDim], values: MLXArray(Float(0.5)))
    }

    public func callAsFunction(_ srcOrig: MLXArray, _ src: MLXArray) -> MLXArray {
        srcOrig + (src - srcOrig) * bypassScale
    }
}

// MARK: - Downsample / Upsample

/// Ports torch `SimpleDownsample` (zipformer.py): softmax-weighted sum over
/// each group of `downsample` frames, right-padding by repeating the last frame.
/// Input/output layout is (seq_len, batch, channels), as in torch.
public final class SimpleDownsample: Module, UnaryLayer {
    public let downsample: Int

    @ParameterInfo(key: "bias") var bias: MLXArray

    public init(_ downsample: Int) {
        self.downsample = downsample
        super.init()
        self._bias.wrappedValue = MLXArray.zeros([downsample])
    }

    public func callAsFunction(_ src: MLXArray) -> MLXArray {
        var src = src
        let (seqLen, batchSize, inChannels) = (src.dim(0), src.dim(1), src.dim(2))
        let ds = downsample
        let dSeqLen = (seqLen + ds - 1) / ds

        let pad = dSeqLen * ds - seqLen
        if pad > 0 {
            let last = src[(seqLen - 1) ..< seqLen]
            let srcExtra = broadcast(last, to: [pad, batchSize, inChannels])
            src = concatenated([src, srcExtra], axis: 0)
        }

        src = src.reshaped(dSeqLen, ds, batchSize, inChannels)
        let weights = softmax(bias, axis: 0).reshaped(ds, 1, 1)
        return (src * weights).sum(axis: 1)
    }
}

/// Ports torch `SimpleUpsample` (zipformer.py): repeats each frame `upsample`
/// times along the sequence axis. Layout (seq_len, batch, channels).
public final class SimpleUpsample: Module, UnaryLayer {
    public let upsample: Int

    public init(_ upsample: Int) {
        self.upsample = upsample
        super.init()
    }

    public func callAsFunction(_ src: MLXArray) -> MLXArray {
        let (seqLen, batchSize, numChannels) = (src.dim(0), src.dim(1), src.dim(2))
        var s = expandedDimensions(src, axis: 1)
        s = broadcast(s, to: [seqLen, upsample, batchSize, numChannels])
        return s.reshaped(seqLen * upsample, batchSize, numChannels)
    }
}

// MARK: - CompactRelPositionalEncoding

/// Ports torch `CompactRelPositionalEncoding` (zipformer.py).
/// Input (seq_len, batch, *); returns (1, 2*seq_len - 1 + left_context, pos_dim).
/// The torch module caches an oversized `pe` table; here it is recomputed per
/// call (identical values, no cache — the table is cheap). Dropout2 on the
/// output is training-only and omitted.
public final class CompactRelPositionalEncoding: Module {
    public let embedDim: Int
    public let lengthFactor: Float

    public init(_ embedDim: Int, lengthFactor: Float = 1.0) {
        precondition(embedDim % 2 == 0)
        precondition(lengthFactor >= 1.0)
        self.embedDim = embedDim
        self.lengthFactor = lengthFactor
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, leftContextLen: Int = 0) -> MLXArray {
        let seqLen = x.dim(0)
        let T = seqLen + leftContextLen

        // positions [-(T-1) ... T-1], shape (2T-1, 1)
        let positions = expandedDimensions(
            MLXArray.arange(-(T - 1), T, dtype: .float32), axis: 1)
        let freqs = MLXArray.arange(1, embedDim / 2 + 1, dtype: .float32)

        let compressionLength = Float(embedDim).squareRoot()
        let xCompressed =
            compressionLength * sign(positions)
            * (log(abs(positions) + compressionLength) - Foundation.log(compressionLength))
        let lengthScale = lengthFactor * Float(embedDim) / (2.0 * Float.pi)
        let xAtan = atan(xCompressed / lengthScale)

        let cosines = cos(xAtan * freqs)
        let sines = sin(xAtan * freqs)

        // interleave [c0, s0, c1, s1, ...] (torch pe[:, 0::2]/pe[:, 1::2]),
        // then the last column is the constant 1 bias term (torch pe[:, -1] = 1.0)
        var pe = stacked([cosines, sines], axis: -1).reshaped(2 * T - 1, embedDim)
        pe = concatenated(
            [pe[0..., 0 ..< (embedDim - 1)], MLXArray.ones([2 * T - 1, 1])], axis: 1)

        let center = (2 * T - 1) / 2  // == T - 1
        let start = center - T + 1
        let end = center + seqLen
        return expandedDimensions(pe[start ..< end], axis: 0)
    }
}

// MARK: - Relative-position attention weights

/// Ports the `as_strided` relative→absolute conversion inside torch
/// `RelPositionMultiheadAttentionWeights.forward` (zipformer.py), via the
/// standard pad/reshape shift: `out[..., i, j] = rel[..., i, (T-1) + j - i]`.
/// Input (num_heads, batch, seq_len, 2*seq_len - 1); output (num_heads, batch,
/// seq_len, seq_len).
public func relativeToAbsolute(_ posScores: MLXArray, seqLen: Int) -> MLXArray {
    let (numHeads, batchSize, time1) = (posScores.dim(0), posScores.dim(1), posScores.dim(2))
    let widths: [IntOrPair] = [0, 0, 0, [1, 0]]
    var x = padded(posScores, widths: widths)
    x = x.reshaped(numHeads, batchSize, 2 * seqLen, time1)
    x = x[0..., 0..., 1 ..< (2 * seqLen)]
    x = x.reshaped(numHeads, batchSize, time1, 2 * seqLen - 1)
    return x[.ellipsis, 0 ..< seqLen]
}

/// Ports torch `RelPositionMultiheadAttentionWeights` (zipformer.py).
/// Inference-only shortcuts: pos scores are always used (pos_emb_skip_rate is
/// training-only), whiten_keys/balance_keys/copy_* are identity, the score
/// penalty and attention dropout are skipped.
/// Input x: (seq_len, batch, embed_dim); posEmb: (1 or batch, 2*seq_len-1,
/// pos_dim); masks are Bool with true = masked. Returns softmaxed weights of
/// shape (num_heads, batch, seq_len, seq_len).
public final class RelPositionMultiheadAttentionWeights: Module {
    public let embedDim: Int
    public let numHeads: Int
    public let queryHeadDim: Int
    public let posHeadDim: Int

    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "linear_pos") var linearPos: Linear

    public init(
        embedDim: Int,
        posDim: Int,
        numHeads: Int,
        queryHeadDim: Int,
        posHeadDim: Int
    ) {
        self.embedDim = embedDim
        self.numHeads = numHeads
        self.queryHeadDim = queryHeadDim
        self.posHeadDim = posHeadDim
        super.init()
        let keyHeadDim = queryHeadDim
        let inProjDim = (queryHeadDim + keyHeadDim + posHeadDim) * numHeads
        self._inProj.wrappedValue = scaledLinear(
            embedDim, inProjDim, bias: true,
            initialScale: pow(Float(queryHeadDim), -0.25))
        self._linearPos.wrappedValue = scaledLinear(
            posDim, numHeads * posHeadDim, bias: false, initialScale: 0.05)
    }

    public func callAsFunction(
        _ x: MLXArray,
        posEmb: MLXArray,
        keyPaddingMask: MLXArray? = nil,
        attnMask: MLXArray? = nil
    ) -> MLXArray {
        let proj = inProj(x)
        let (seqLen, batchSize) = (proj.dim(0), proj.dim(1))
        let queryDim = queryHeadDim * numHeads

        var q = proj[.ellipsis, 0 ..< queryDim]
        var k = proj[.ellipsis, queryDim ..< (2 * queryDim)]
        var p = proj[.ellipsis, (2 * queryDim) ..< (2 * queryDim + numHeads * posHeadDim)]

        q = q.reshaped(seqLen, batchSize, numHeads, queryHeadDim).transposed(2, 1, 0, 3)
        p = p.reshaped(seqLen, batchSize, numHeads, posHeadDim).transposed(2, 1, 0, 3)
        k = k.reshaped(seqLen, batchSize, numHeads, queryHeadDim).transposed(2, 1, 3, 0)

        var attnScores = matmul(q, k)

        let seqLen2 = 2 * seqLen - 1
        var pos = linearPos(posEmb)
        pos = pos.reshaped(-1, seqLen2, numHeads, posHeadDim).transposed(2, 0, 3, 1)
        // (head, batch, time1, pos_head_dim) x (head, 1 or batch, pos_head_dim,
        // 2*time-1) -> (head, batch, time1, 2*time-1)
        var posScores = matmul(p, pos)
        posScores = relativeToAbsolute(posScores, seqLen: seqLen)
        attnScores = attnScores + posScores

        // torch uses masked_fill(-1000): large enough that exp underflows to 0
        if let attnMask {
            attnScores = which(attnMask, MLXArray(Float(-1000)), attnScores)
        }
        if let keyPaddingMask {
            attnScores = which(
                expandedDimensions(keyPaddingMask, axis: 1),
                MLXArray(Float(-1000)), attnScores)
        }

        return softmax(attnScores, axis: -1)
    }
}

// MARK: - SelfAttention

/// Ports torch `SelfAttention` (zipformer.py): applies precomputed attention
/// weights to projected values. whiten is training-only and omitted.
/// x: (seq_len, batch, embed_dim); attnWeights: (num_heads, batch, seq_len, seq_len).
public final class SelfAttention: Module {
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    public init(embedDim: Int, numHeads: Int, valueHeadDim: Int) {
        super.init()
        self._inProj.wrappedValue = Linear(embedDim, numHeads * valueHeadDim, bias: true)
        self._outProj.wrappedValue = scaledLinear(
            numHeads * valueHeadDim, embedDim, bias: true, initialScale: 0.05)
    }

    public func callAsFunction(_ x: MLXArray, attnWeights: MLXArray) -> MLXArray {
        let (seqLen, batchSize) = (x.dim(0), x.dim(1))
        let numHeads = attnWeights.dim(0)

        var v = inProj(x)
        v = v.reshaped(seqLen, batchSize, numHeads, -1).transposed(2, 1, 0, 3)
        v = matmul(attnWeights, v)
        v = v.transposed(2, 1, 0, 3).reshaped(seqLen, batchSize, -1)
        return outProj(v)
    }
}

// MARK: - FeedforwardModule

/// Ports torch `FeedforwardModule` (zipformer.py). hidden_balancer and
/// out_whiten are training-only and omitted; out_proj carries the SwooshL
/// activation (dropout skipped).
public final class FeedforwardModule: Module, UnaryLayer {
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: ActivationDropoutAndLinear

    public init(embedDim: Int, feedforwardDim: Int) {
        super.init()
        self._inProj.wrappedValue = Linear(embedDim, feedforwardDim)
        self._outProj.wrappedValue = ActivationDropoutAndLinear(
            feedforwardDim, embedDim, bias: true, activation: .swooshL, initialScale: 0.1)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        outProj(inProj(x))
    }
}

// MARK: - NonlinAttention

/// Ports torch `NonlinAttention` (zipformer.py). balancer/whiten1/whiten2/
/// identity1..3 are training-or-diagnostic-only and omitted.
/// x: (seq_len, batch, channels); attnWeights: (num_heads, batch, seq_len,
/// seq_len) — the caller passes only head 0 here, per Zipformer2EncoderLayer.
public final class NonlinAttention: Module {
    public let hiddenChannels: Int

    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    public init(channels: Int, hiddenChannels: Int) {
        self.hiddenChannels = hiddenChannels
        super.init()
        self._inProj.wrappedValue = Linear(channels, hiddenChannels * 3, bias: true)
        self._outProj.wrappedValue = scaledLinear(
            hiddenChannels, channels, bias: true, initialScale: 0.05)
    }

    public func callAsFunction(_ x: MLXArray, attnWeights: MLXArray) -> MLXArray {
        let proj = inProj(x)
        let (seqLen, batchSize) = (proj.dim(0), proj.dim(1))

        // torch order: s, x, y = chunk(3, dim=2)
        let parts = split(proj, parts: 3, axis: 2)
        let s = tanh(parts[0])
        var v = parts[1] * s
        let y = parts[2]

        let numHeads = attnWeights.dim(0)
        v = v.reshaped(seqLen, batchSize, numHeads, -1).transposed(2, 1, 0, 3)
        v = matmul(attnWeights, v)
        v = v.transposed(2, 1, 0, 3).reshaped(seqLen, batchSize, -1)

        v = v * y
        return outProj(v)
    }
}

// MARK: - ConvolutionModule

/// Ports torch `ConvolutionModule` (zipformer.py): pointwise in_proj → GLU-style
/// sigmoid gate → depthwise Conv1d → SwooshR + pointwise out_proj.
/// balancer1/balancer2/whiten are training-only and omitted.
/// x: (seq_len, batch, channels); srcKeyPaddingMask: Bool (batch, seq_len),
/// true = masked.
/// NOTE for weight loading: MLX Conv1d weights are (out, kernel, in/groups);
/// torch stores (out, in/groups, kernel) — transpose axes (0, 2, 1) on load.
public final class ConvolutionModule: Module {
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "depthwise_conv") var depthwiseConv: Conv1d
    @ModuleInfo(key: "out_proj") var outProj: ActivationDropoutAndLinear

    public init(channels: Int, kernelSize: Int) {
        precondition(kernelSize % 2 == 1)
        super.init()
        let bottleneckDim = channels
        self._inProj.wrappedValue = Linear(channels, 2 * bottleneckDim)
        self._depthwiseConv.wrappedValue = Conv1d(
            inputChannels: bottleneckDim,
            outputChannels: bottleneckDim,
            kernelSize: kernelSize,
            padding: kernelSize / 2,
            groups: bottleneckDim,
            bias: true)
        self._outProj.wrappedValue = ActivationDropoutAndLinear(
            bottleneckDim, channels, bias: true, activation: .swooshR, initialScale: 0.05)
    }

    public func callAsFunction(
        _ x: MLXArray,
        srcKeyPaddingMask: MLXArray? = nil
    ) -> MLXArray {
        let proj = inProj(x)  // (time, batch, 2*channels)

        // torch order: x, s = chunk(2, dim=2)
        let parts = split(proj, parts: 2, axis: 2)
        let s = MLX.sigmoid(parts[1])
        var v = parts[0] * s

        // MLX Conv1d is channels-last (NLC), so (time, batch, ch) -> (batch, time, ch)
        v = v.transposed(1, 0, 2)
        if let srcKeyPaddingMask {
            v = which(
                expandedDimensions(srcKeyPaddingMask, axis: -1), MLXArray(Float(0)), v)
        }
        v = depthwiseConv(v)
        v = v.transposed(1, 0, 2)

        return outProj(v)
    }
}
