// LuxTTS Zipformer2 U-Net encoder stack, ported from the torch reference
// zipvoice/models/modules/zipformer.py (classes Zipformer2EncoderLayer,
// Zipformer2Encoder, DownsampledZipformer2Encoder, TTSZipformer,
// SelfAttention, timestep_embedding).
//
// Inference-only port: Balancer, Whiten, Identity, Dropout2, sequence-level
// dropout, ScheduledFloat schedules, const_attention_rate and
// pos_emb_skip_rate are all identities / disabled at eval time in the torch
// source and are omitted here. ScaledLinear's initial_scale only affects
// weight init, so a plain Linear is exact at inference.
//
// Layout note: the torch stack runs in (seq_len, batch, channels); this port
// keeps that internal layout, transposing only at the TTSZipformer boundary,
// so the shared primitives in LuxLayers.swift are expected to use it too.

import Foundation
import MLX
import MLXNN

/// zipformer.py `timestep_embedding`: sinusoidal embeddings for t of shape
/// (N,) -> (N, dim), or (N, T) -> (T, N, dim).
func luxTimestepEmbedding(_ timesteps: MLXArray, dim: Int, maxPeriod: Float = 10_000) -> MLXArray {
    let half = dim / 2
    let freqValues = (0 ..< half).map { exp(-log(maxPeriod) * Float($0) / Float(half)) }
    let freqs = MLXArray(freqValues)

    var t = timesteps
    if t.ndim == 2 {
        t = t.transposed(1, 0)
    }
    let args = t.asType(.float32).expandedDimensions(axis: -1) * freqs
    var embedding = concatenated([args.cos(), args.sin()], axis: -1)
    if dim % 2 != 0 {
        embedding = concatenated([embedding, zeros(like: embedding[.ellipsis, 0 ..< 1])], axis: -1)
    }
    return embedding
}

/// scaling.py `SwooshRForward`.
func luxSwooshR(_ x: MLXArray) -> MLXArray {
    logAddExp(x - 1.0, 0) - x * 0.08 - 0.313261687
}

/// Equivalent of `x[start:end:step]` along one axis (MLX Swift subscripts have
/// no stride support, so gather explicit indices instead).
private func luxStrided(_ x: MLXArray, axis: Int, by step: Int) -> MLXArray {
    let n = x.dim(axis)
    let indices = MLXArray(Array(Swift.stride(from: 0, to: n, by: step)).map(Int32.init))
    return take(x, indices, axis: axis)
}

/// TTSZipformer's `time_embed` head: torch nn.Sequential(Linear, SwooshR,
/// Linear); ModuleInfo keys "0"/"2" mirror the torch Sequential indices so
/// checkpoint keys line up (`time_embed.0.weight`, `time_embed.2.weight`).
final class TimestepEmbedMLP: Module {
    // Keys "linear1"/"linear2", NOT the torch Sequential indices "0"/"2":
    // mlx-swift's `ModuleParameters.unflattened` always treats a pure-digit
    // path segment as an array index, so a raw "0"/"2" key here collides with
    // that array inference and fails `update(parameters:verify:)`'s structural
    // check against this module's own (dict-keyed) parameter tree. The
    // checkpoint side is remapped to match in LuxSpeechModel.load.
    @ModuleInfo(key: "linear1") var linear1: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear

    init(dim: Int) {
        self._linear1.wrappedValue = Linear(dim, dim * 2)
        self._linear2.wrappedValue = Linear(dim * 2, dim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(luxSwooshR(linear1(x)))
    }
}

/// Zipformer2Encoder's per-stack `time_emb` projection: torch
/// nn.Sequential(SwooshR, Linear); key "1" mirrors `time_emb.1.weight`.
final class EncoderTimeEmbed: Module {
    // Key "linear", not the torch Sequential index "1" — see the comment on
    // TimestepEmbedMLP above; same array-vs-module-dict ambiguity.
    @ModuleInfo(key: "linear") var linear: Linear

    init(timeEmbedDim: Int, embedDim: Int) {
        self._linear.wrappedValue = Linear(timeEmbedDim, embedDim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear(luxSwooshR(x))
    }
}

// `SelfAttention` is defined in LuxLayers.swift (shared primitive).

/// zipformer.py `Zipformer2EncoderLayer` (inference path).
final class Zipformer2EncoderLayer: Module {
    @ModuleInfo(key: "bypass") var bypass: BypassModule
    @ModuleInfo(key: "bypass_mid") var bypassMid: BypassModule
    @ModuleInfo(key: "self_attn_weights") var selfAttnWeights: RelPositionMultiheadAttentionWeights
    @ModuleInfo(key: "self_attn1") var selfAttn1: SelfAttention
    @ModuleInfo(key: "self_attn2") var selfAttn2: SelfAttention
    @ModuleInfo(key: "feed_forward1") var feedForward1: FeedforwardModule
    @ModuleInfo(key: "feed_forward2") var feedForward2: FeedforwardModule
    @ModuleInfo(key: "feed_forward3") var feedForward3: FeedforwardModule
    @ModuleInfo(key: "nonlin_attention") var nonlinAttention: NonlinAttention
    @ModuleInfo(key: "conv_module1") var convModule1: ConvolutionModule?
    @ModuleInfo(key: "conv_module2") var convModule2: ConvolutionModule?
    @ModuleInfo(key: "norm") var norm: BiasNorm

    let useConv: Bool

    init(
        embedDim: Int,
        posDim: Int,
        numHeads: Int,
        queryHeadDim: Int,
        posHeadDim: Int,
        valueHeadDim: Int,
        feedforwardDim: Int,
        cnnModuleKernel: Int,
        useConv: Bool = true
    ) {
        self.useConv = useConv
        self._bypass.wrappedValue = BypassModule(embedDim)
        self._bypassMid.wrappedValue = BypassModule(embedDim)
        self._selfAttnWeights.wrappedValue = RelPositionMultiheadAttentionWeights(
            embedDim: embedDim,
            posDim: posDim,
            numHeads: numHeads,
            queryHeadDim: queryHeadDim,
            posHeadDim: posHeadDim
        )
        self._selfAttn1.wrappedValue = SelfAttention(
            embedDim: embedDim, numHeads: numHeads, valueHeadDim: valueHeadDim)
        self._selfAttn2.wrappedValue = SelfAttention(
            embedDim: embedDim, numHeads: numHeads, valueHeadDim: valueHeadDim)
        self._feedForward1.wrappedValue = FeedforwardModule(
            embedDim: embedDim, feedforwardDim: (feedforwardDim * 3) / 4)
        self._feedForward2.wrappedValue = FeedforwardModule(
            embedDim: embedDim, feedforwardDim: feedforwardDim)
        self._feedForward3.wrappedValue = FeedforwardModule(
            embedDim: embedDim, feedforwardDim: (feedforwardDim * 5) / 4)
        self._nonlinAttention.wrappedValue = NonlinAttention(
            channels: embedDim, hiddenChannels: 3 * embedDim / 4)
        if useConv {
            self._convModule1.wrappedValue = ConvolutionModule(
                channels: embedDim, kernelSize: cnnModuleKernel)
            self._convModule2.wrappedValue = ConvolutionModule(
                channels: embedDim, kernelSize: cnnModuleKernel)
        } else {
            self._convModule1.wrappedValue = nil
            self._convModule2.wrappedValue = nil
        }
        self._norm.wrappedValue = BiasNorm(embedDim)
        super.init()
    }

    /// src: (seq_len, batch, embed_dim); posEmb: (1, 2*seq_len-1, pos_dim);
    /// timeEmb: (batch, embed_dim) or (seq_len, batch, embed_dim).
    func callAsFunction(
        _ src: MLXArray,
        posEmb: MLXArray,
        timeEmb: MLXArray? = nil,
        attnMask: MLXArray? = nil,
        srcKeyPaddingMask: MLXArray? = nil
    ) -> MLXArray {
        let srcOrig = src
        var src = src

        let attnWeights = selfAttnWeights(
            src, posEmb: posEmb, keyPaddingMask: srcKeyPaddingMask, attnMask: attnMask)

        if let timeEmb { src = src + timeEmb }
        src = src + feedForward1(src)

        // Torch uses attn_weights[0:1] (head 0 only) for NonlinAttention.
        let selectedAttnWeights = attnWeights[0 ..< 1]
        src = src + nonlinAttention(src, attnWeights: selectedAttnWeights)

        src = src + selfAttn1(src, attnWeights: attnWeights)

        if useConv, let convModule1 {
            if let timeEmb { src = src + timeEmb }
            src = src + convModule1(src, srcKeyPaddingMask: srcKeyPaddingMask)
        }

        src = src + feedForward2(src)
        src = bypassMid(srcOrig, src)

        src = src + selfAttn2(src, attnWeights: attnWeights)

        if useConv, let convModule2 {
            if let timeEmb { src = src + timeEmb }
            src = src + convModule2(src, srcKeyPaddingMask: srcKeyPaddingMask)
        }

        src = src + feedForward3(src)
        src = norm(src)
        src = bypass(srcOrig, src)
        return src
    }
}

/// Common supertype for the heterogeneous `encoders` list of TTSZipformer
/// (plain Zipformer2Encoder for downsampling factor 1, wrapped otherwise),
/// mirroring torch's nn.ModuleList of mixed classes.
class ZipformerEncoderBlock: Module {
    func callAsFunction(
        _ src: MLXArray,
        timeEmb: MLXArray? = nil,
        attnMask: MLXArray? = nil,
        srcKeyPaddingMask: MLXArray? = nil
    ) -> MLXArray {
        fatalError("ZipformerEncoderBlock is abstract")
    }
}

/// zipformer.py `Zipformer2Encoder`: a stack of N encoder layers sharing one
/// relative positional encoding and one per-stack time-embedding projection.
final class Zipformer2Encoder: ZipformerEncoderBlock {
    @ModuleInfo(key: "encoder_pos") var encoderPos: CompactRelPositionalEncoding
    @ModuleInfo(key: "time_emb") var timeEmb: EncoderTimeEmbed?
    @ModuleInfo(key: "layers") var layers: [Zipformer2EncoderLayer]

    init(
        numLayers: Int,
        embedDim: Int,
        timeEmbedDim: Int,
        posDim: Int,
        makeLayer: () -> Zipformer2EncoderLayer
    ) {
        self._encoderPos.wrappedValue = CompactRelPositionalEncoding(posDim)
        self._timeEmb.wrappedValue =
            timeEmbedDim != -1
            ? EncoderTimeEmbed(timeEmbedDim: timeEmbedDim, embedDim: embedDim) : nil
        self._layers.wrappedValue = (0 ..< numLayers).map { _ in makeLayer() }
        super.init()
    }

    override func callAsFunction(
        _ src: MLXArray,
        timeEmb: MLXArray? = nil,
        attnMask: MLXArray? = nil,
        srcKeyPaddingMask: MLXArray? = nil
    ) -> MLXArray {
        let posEmb = encoderPos(src)

        var projectedTimeEmb: MLXArray? = nil
        if let projection = self.timeEmb {
            guard let timeEmb else {
                fatalError("Zipformer2Encoder configured with time embedding but none given")
            }
            projectedTimeEmb = projection(timeEmb)
        }

        var output = src
        for layer in layers {
            output = layer(
                output,
                posEmb: posEmb,
                timeEmb: projectedTimeEmb,
                attnMask: attnMask,
                srcKeyPaddingMask: srcKeyPaddingMask
            )
        }
        return output
    }
}

/// zipformer.py `DownsampledZipformer2Encoder`: encoder evaluated at a reduced
/// frame rate, upsampled back and combined with the input via a bypass.
final class DownsampledZipformer2Encoder: ZipformerEncoderBlock {
    @ModuleInfo(key: "downsample") var downsample: SimpleDownsample
    @ModuleInfo(key: "encoder") var encoder: Zipformer2Encoder
    @ModuleInfo(key: "upsample") var upsample: SimpleUpsample
    @ModuleInfo(key: "out_combiner") var outCombiner: BypassModule

    let downsampleFactor: Int

    init(encoder: Zipformer2Encoder, dim: Int, downsample: Int) {
        self.downsampleFactor = downsample
        self._downsample.wrappedValue = SimpleDownsample(downsample)
        self._encoder.wrappedValue = encoder
        self._upsample.wrappedValue = SimpleUpsample(downsample)
        self._outCombiner.wrappedValue = BypassModule(dim)
        super.init()
    }

    override func callAsFunction(
        _ src: MLXArray,
        timeEmb: MLXArray? = nil,
        attnMask: MLXArray? = nil,
        srcKeyPaddingMask: MLXArray? = nil
    ) -> MLXArray {
        // TTSZipformer always passes attn_mask=None; the torch [::ds, ::ds]
        // slicing of a non-nil attn_mask is intentionally not ported.
        precondition(attnMask == nil, "attnMask is not supported in the downsampled encoder port")

        let srcOrig = src
        var src = downsample(src)

        var timeEmb = timeEmb
        if let t = timeEmb, t.ndim == 3 {
            timeEmb = luxStrided(t, axis: 0, by: downsampleFactor)
        }
        var mask = srcKeyPaddingMask
        if let m = mask {
            mask = luxStrided(m, axis: -1, by: downsampleFactor)
        }

        src = encoder(src, timeEmb: timeEmb, attnMask: nil, srcKeyPaddingMask: mask)
        src = upsample(src)
        // Drop the frames the ceil-division downsample added.
        src = src[0 ..< srcOrig.dim(0)]
        return outCombiner(srcOrig, src)
    }
}

/// zipformer.py `TTSZipformer`: the 5-stage U-Net Zipformer2 stack used both
/// as the LuxTTS text encoder (downsampling [1]) and as the flow-matching
/// decoder (downsampling [1, 2, 4, 2, 1], with time + guidance embeddings).
final class TTSZipformer: Module {
    @ModuleInfo(key: "in_proj") var inProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear
    @ModuleInfo(key: "encoders") var encoders: [ZipformerEncoderBlock]
    @ModuleInfo(key: "time_embed") var timeEmbed: TimestepEmbedMLP?
    @ModuleInfo(key: "guidance_scale_embed") var guidanceScaleEmbed: Linear?

    let timeEmbedDim: Int
    let guidanceScaleEmbedDim: Int

    init(
        inDim: Int,
        outDim: Int,
        downsamplingFactor: [Int],
        numEncoderLayers: [Int],
        cnnModuleKernel: [Int],
        encoderDim: Int,
        queryHeadDim: Int,
        posHeadDim: Int,
        valueHeadDim: Int,
        numHeads: Int,
        feedforwardDim: Int,
        posDim: Int,
        useTimeEmbed: Bool = true,
        timeEmbedDim: Int = 192,
        useGuidanceScaleEmbed: Bool = false,
        guidanceScaleEmbedDim: Int = 192,
        useConv: Bool = true
    ) {
        let numEncoders = downsamplingFactor.count
        func expanded(_ values: [Int]) -> [Int] {
            if values.count == 1 { return Array(repeating: values[0], count: numEncoders) }
            precondition(values.count == numEncoders)
            return values
        }
        let layerCounts = expanded(numEncoderLayers)
        let kernels = expanded(cnnModuleKernel)

        // U-Net shape check from torch `_assert_downsampling_factor`.
        precondition(downsamplingFactor.first == 1 && downsamplingFactor.last == 1)
        for i in 1 ..< downsamplingFactor.count / 2 + 1 {
            precondition(downsamplingFactor[i] == downsamplingFactor[i - 1] * 2)
        }
        for i in (downsamplingFactor.count / 2 + 1) ..< downsamplingFactor.count {
            precondition(downsamplingFactor[i] * 2 == downsamplingFactor[i - 1])
        }

        self.timeEmbedDim = timeEmbedDim
        self.guidanceScaleEmbedDim = guidanceScaleEmbedDim

        self._inProj.wrappedValue = Linear(inDim, encoderDim)
        self._outProj.wrappedValue = Linear(encoderDim, outDim)

        var blocks: [ZipformerEncoderBlock] = []
        for i in 0 ..< numEncoders {
            let encoder = Zipformer2Encoder(
                numLayers: layerCounts[i],
                embedDim: encoderDim,
                timeEmbedDim: useTimeEmbed ? timeEmbedDim : -1,
                posDim: posDim
            ) {
                Zipformer2EncoderLayer(
                    embedDim: encoderDim,
                    posDim: posDim,
                    numHeads: numHeads,
                    queryHeadDim: queryHeadDim,
                    posHeadDim: posHeadDim,
                    valueHeadDim: valueHeadDim,
                    feedforwardDim: feedforwardDim,
                    cnnModuleKernel: kernels[i],
                    useConv: useConv
                )
            }
            if downsamplingFactor[i] != 1 {
                blocks.append(
                    DownsampledZipformer2Encoder(
                        encoder: encoder, dim: encoderDim, downsample: downsamplingFactor[i]))
            } else {
                blocks.append(encoder)
            }
        }
        self._encoders.wrappedValue = blocks

        self._timeEmbed.wrappedValue = useTimeEmbed ? TimestepEmbedMLP(dim: timeEmbedDim) : nil
        // Torch uses ScaledLinear(bias=False); identical to Linear at inference.
        self._guidanceScaleEmbed.wrappedValue =
            useGuidanceScaleEmbed ? Linear(guidanceScaleEmbedDim, timeEmbedDim, bias: false) : nil

        super.init()
    }

    /// x: (batch, seq_len, in_dim); t: (batch,) or (batch, seq_len);
    /// paddingMask: (batch, seq_len) bool, true = masked;
    /// guidanceScale: same shapes as t. Returns (batch, seq_len, out_dim).
    func callAsFunction(
        _ x: MLXArray,
        t: MLXArray? = nil,
        paddingMask: MLXArray? = nil,
        guidanceScale: MLXArray? = nil
    ) -> MLXArray {
        var x = x.transposed(1, 0, 2)
        x = inProj(x)

        var timeEmb: MLXArray? = nil
        if let t {
            precondition(t.ndim == 1 || t.ndim == 2)
            var emb = luxTimestepEmbedding(t, dim: timeEmbedDim)
            if let guidanceScale, let guidanceScaleEmbed {
                precondition(guidanceScale.ndim == 1 || guidanceScale.ndim == 2)
                emb =
                    emb
                    + guidanceScaleEmbed(
                        luxTimestepEmbedding(guidanceScale, dim: guidanceScaleEmbedDim))
            }
            guard let timeEmbed else {
                fatalError("TTSZipformer received t but was built without time embedding")
            }
            timeEmb = timeEmbed(emb)
        }

        for encoder in encoders {
            x = encoder(x, timeEmb: timeEmb, attnMask: nil, srcKeyPaddingMask: paddingMask)
        }
        x = outProj(x)
        return x.transposed(1, 0, 2)
    }
}
