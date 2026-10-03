import MLX
import MLXNN
import Foundation

/// htdemucs v4 model configuration.
struct HTDemucsConfig {
    let channels: Int = 48
    let growth: Int = 2
    let depth: Int = 4
    let nFFT: Int = 4096
    let hopLength: Int = 1024
    let sampleRate: Double = 44100.0
    let audioChannels: Int = 2  // stereo
    let sources: Int = 4        // drums, bass, other, vocals
    let vocalsIndex: Int = 3    // vocals is source index 3

    // Encoder/decoder
    let kernelSize: Int = 8
    let stride: Int = 4
    let context: Int = 1        // decoder context for rewrite conv
    let contextEnc: Int = 0     // encoder context for rewrite conv
    let dconvCompress: Int = 8
    let dconvDepth: Int = 2

    // Transformer
    let bottomChannels: Int = 512  // channel projector target dims
    let transformerHeads: Int = 8
    let transformerLayers: Int = 5
    let transformerHiddenScale: Float = 4.0

    // Frequency embedding
    let freqEmbScale: Float = 0.2
    let embScale: Float = 10.0

    // Segment length for valid_length (7.8 seconds)
    let segment: Double = 7.8

    /// Number of CaC channels: audioChannels * 2 (real + imaginary)
    var cacChannels: Int { audioChannels * 2 }

    /// Encoder channel progression: [cacChannels, 48, 96, 192, 384]
    var spectralEncoderChannels: [Int] {
        var ch = [cacChannels]
        var c = channels
        for _ in 0..<depth {
            ch.append(c)
            c *= growth
        }
        return ch
    }

    /// Temporal encoder channel progression: [2, 48, 96, 192, 384]
    var temporalEncoderChannels: [Int] {
        var ch = [audioChannels]
        var c = channels
        for _ in 0..<depth {
            ch.append(c)
            c *= growth
        }
        return ch
    }

    /// Spectral decoder channels: [384, 192, 96, 48, sources*cacChannels]
    var spectralDecoderChannels: [Int] {
        var ch = Array(spectralEncoderChannels.reversed())
        ch[ch.count - 1] = sources * cacChannels  // 4 * 4 = 16
        return ch
    }

    /// Temporal decoder channels: [384, 192, 96, 48, sources*audioChannels]
    var temporalDecoderChannels: [Int] {
        var ch = Array(temporalEncoderChannels.reversed())
        ch[ch.count - 1] = sources * audioChannels  // 4 * 2 = 8
        return ch
    }

    /// Bottleneck channels before channel projector
    var encoderBottleneckChannels: Int {
        channels * Int(pow(Double(growth), Double(depth - 1)))  // 48 * 8 = 384
    }

    static let `default` = HTDemucsConfig()
}

/// Scaled embedding with learned weights scaled by a constant.
///
/// Checkpoint key: `freq_emb.embedding.weight` [512, 48].
/// The stored weights are divided by `scale` during training init;
/// at inference they are multiplied back by `scale`.
class ScaledEmbedding: Module {
    @ModuleInfo var embedding: Embedding

    let scale: Float

    init(numEmbeddings: Int, embeddingDim: Int, scale: Float = 10.0) {
        self.scale = scale
        self._embedding.wrappedValue = Embedding(embeddingCount: numEmbeddings, dimensions: embeddingDim)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        embedding(x) * scale
    }
}

/// Hybrid Transformer Demucs v4 — dual-branch U-Net with cross-domain transformer.
///
/// The model processes audio simultaneously as a raw waveform (temporal branch)
/// and as a spectrogram (spectral branch), fusing them through cross-domain
/// attention at the bottleneck.
///
/// Architecture:
/// 1. STFT → CaC → Spectral encoder (4 layers) with skip connections
/// 2. Waveform → Temporal encoder (4 layers) with skip connections
/// 3. Channel upsampler (384→512) on both branches
/// 4. CrossDomainTransformer (5 layers, self-attn + cross-attn)
/// 5. Channel downsampler (512→384) on both branches
/// 6. Spectral decoder (4 layers) → CaC → iSTFT
/// 7. Temporal decoder (4 layers) → waveform
/// 8. Sum spectral + temporal → extract vocals
///
/// Flat layer arrays match checkpoint key paths:
/// - `encoder.N.*` (spectral encoder layers)
/// - `tencoder.N.*` (temporal encoder layers)
/// - `decoder.N.*` (spectral decoder layers, deepest-first)
/// - `tdecoder.N.*` (temporal decoder layers, deepest-first)
///
/// Input: stereo waveform `[batch, 2, samples]`
/// Output: separated vocals `[batch, 2, samples]`
class HTDemucs: Module {

    // Spectral encoder layers (checkpoint: encoder.0.*, encoder.1.*, ...)
    @ModuleInfo(key: "encoder") var encoder: [SpectralEncoderLayer]

    // Temporal encoder layers (checkpoint: tencoder.0.*, ...)
    @ModuleInfo(key: "tencoder") var tencoder: [TemporalEncoderLayer]

    // Spectral decoder layers, deepest-first (checkpoint: decoder.0.*, ...)
    @ModuleInfo(key: "decoder") var decoder: [SpectralDecoderLayer]

    // Temporal decoder layers, deepest-first (checkpoint: tdecoder.0.*, ...)
    @ModuleInfo(key: "tdecoder") var tdecoder: [TemporalDecoderLayer]

    // Channel projectors: encoder bottleneck (384) ↔ transformer (512)
    @ModuleInfo(key: "channel_upsampler") var channelUpsampler: Conv1d
    @ModuleInfo(key: "channel_downsampler") var channelDownsampler: Conv1d
    @ModuleInfo(key: "channel_upsampler_t") var channelUpsamplerT: Conv1d
    @ModuleInfo(key: "channel_downsampler_t") var channelDownsamplerT: Conv1d

    // Cross-domain transformer (checkpoint: crosstransformer.*)
    @ModuleInfo(key: "crosstransformer") var crosstransformer: CrossDomainTransformer

    // Frequency embedding applied after encoder layer 0
    @ModuleInfo(key: "freq_emb") var freqEmb: ScaledEmbedding

    let config: HTDemucsConfig
    let window: MLXArray

    init(config: HTDemucsConfig = .default) {
        self.config = config
        self.window = WindowFunctions.hannWindow(size: config.nFFT)

        let sEncCh = config.spectralEncoderChannels  // [4, 48, 96, 192, 384]
        let tEncCh = config.temporalEncoderChannels   // [2, 48, 96, 192, 384]
        let sDecCh = config.spectralDecoderChannels   // [384, 192, 96, 48, 16]
        let tDecCh = config.temporalDecoderChannels   // [384, 192, 96, 48, 8]

        // Spectral encoder: 4 layers
        self._encoder.wrappedValue = (0..<config.depth).map { i in
            SpectralEncoderLayer(
                inChannels: sEncCh[i],
                outChannels: sEncCh[i + 1],
                kernelSize: config.kernelSize,
                stride: config.stride,
                dconvCompress: config.dconvCompress,
                dconvDepth: config.dconvDepth,
                contextEnc: config.contextEnc
            )
        }

        // Temporal encoder: 4 layers
        self._tencoder.wrappedValue = (0..<config.depth).map { i in
            TemporalEncoderLayer(
                inChannels: tEncCh[i],
                outChannels: tEncCh[i + 1],
                kernelSize: config.kernelSize,
                stride: config.stride,
                dconvCompress: config.dconvCompress,
                dconvDepth: config.dconvDepth
            )
        }

        // Spectral decoder: 4 layers, deepest-first (matching checkpoint order)
        self._decoder.wrappedValue = (0..<config.depth).map { i in
            SpectralDecoderLayer(
                inChannels: sDecCh[i],
                outChannels: sDecCh[i + 1],
                kernelSize: config.kernelSize,
                stride: config.stride,
                context: config.context,
                isLast: i == config.depth - 1,
                dconvCompress: config.dconvCompress,
                dconvDepth: config.dconvDepth
            )
        }

        // Temporal decoder: 4 layers, deepest-first
        self._tdecoder.wrappedValue = (0..<config.depth).map { i in
            TemporalDecoderLayer(
                inChannels: tDecCh[i],
                outChannels: tDecCh[i + 1],
                kernelSize: config.kernelSize,
                stride: config.stride,
                context: config.context,
                isLast: i == config.depth - 1,
                dconvCompress: config.dconvCompress,
                dconvDepth: config.dconvDepth
            )
        }

        // Channel projectors (1×1 Conv1d)
        let encBottom = config.encoderBottleneckChannels  // 384
        let tDim = config.bottomChannels                  // 512
        self._channelUpsampler.wrappedValue = Conv1d(inputChannels: encBottom, outputChannels: tDim, kernelSize: 1)
        self._channelDownsampler.wrappedValue = Conv1d(inputChannels: tDim, outputChannels: encBottom, kernelSize: 1)
        self._channelUpsamplerT.wrappedValue = Conv1d(inputChannels: encBottom, outputChannels: tDim, kernelSize: 1)
        self._channelDownsamplerT.wrappedValue = Conv1d(inputChannels: tDim, outputChannels: encBottom, kernelSize: 1)

        // Cross-domain transformer
        self._crosstransformer.wrappedValue = CrossDomainTransformer(
            dims: tDim,
            numHeads: config.transformerHeads,
            numLayers: config.transformerLayers,
            hiddenScale: config.transformerHiddenScale
        )

        // Frequency embedding: 512 frequency bins (after encoder layer 0) × 48 channels
        let freqBinsAfterLayer0 = config.nFFT / 2 / config.stride  // 2048 / 4 = 512
        self._freqEmb.wrappedValue = ScaledEmbedding(
            numEmbeddings: freqBinsAfterLayer0,
            embeddingDim: config.channels,  // 48
            scale: config.embScale          // 10.0
        )
    }

    /// Separate vocals from a stereo mixture.
    ///
    /// - Parameter mixture: Input waveform of shape `[batch, 2, samples]`.
    /// - Returns: Separated vocals of shape `[batch, 2, samples]`.
    func callAsFunction(_ mixture: MLXArray) -> MLXArray {
        let originalLength = mixture.shape[2]
        let B = mixture.shape[0]

        // Pad to valid length
        let mix = padToValid(mixture)
        let paddedLength = mix.shape[2]

        // === STFT → CaC → Normalize ===
        let z = stft(mix)
        var x = toCaC(z)  // [B, Fr, T, 4] channels-last

        let Fq = x.shape[1]
        let T = x.shape[2]

        // Normalize spectral: mean/std over (Fr, T, C)
        let mean = x.mean(axes: [1, 2, 3], keepDims: true)
        let std = x.variance(axes: [1, 2, 3], keepDims: true).sqrt()
        x = (x - mean) / (1e-5 + std)

        // === Temporal waveform → channels-last → Normalize ===
        var xt = mix.transposed(0, 2, 1)  // [B, samples, 2]
        let meant = xt.mean(axes: [1, 2], keepDims: true)
        let stdt = xt.variance(axes: [1, 2], keepDims: true).sqrt()
        xt = (xt - meant) / (1e-5 + stdt)

        // === Encoding ===
        var savedSpec = [MLXArray]()    // spectral skip connections
        var savedTemp = [MLXArray]()    // temporal skip connections
        var lengthsSpec = [Int]()       // spectral time dimensions (for decoder)
        var lengthsTemp = [Int]()       // temporal time dimensions (for decoder)

        for idx in 0..<config.depth {
            // Save pre-encoding dimensions
            lengthsSpec.append(x.shape[2])  // time dim in [B, Fr, T, C]
            lengthsTemp.append(xt.shape[1]) // time dim in [B, T, C]

            // Temporal encoder
            xt = tencoder[idx](xt)
            savedTemp.append(xt)

            // Spectral encoder (no injection for htdemucs_ft depth=4)
            x = encoder[idx](x)

            // Frequency embedding after layer 0
            if idx == 0 {
                let freqBins = x.shape[1]
                let frs = MLXArray(Array(0..<Int32(freqBins)))
                let emb = freqEmb(frs)  // [freqBins, 48]
                // Reshape for channels-last broadcast: [1, Fr, 1, C]
                let embReshaped = emb.reshaped([1, freqBins, 1, emb.shape[1]])
                x = x + config.freqEmbScale * embReshaped
            }

            savedSpec.append(x)
        }

        // === Channel Upsampler (384 → 512) ===
        // Spectral: [B, Fr, T, C] → [B, Fr*T, C] → Conv1d → [B, Fr*T, 512] → [B, Fr, T, 512]
        let Fr = x.shape[1]
        let T1 = x.shape[2]
        x = x.reshaped([B, Fr * T1, x.shape[3]])
        x = channelUpsampler(x)
        x = x.reshaped([B, Fr, T1, config.bottomChannels])

        // Temporal: [B, T, C] → Conv1d → [B, T, 512]
        xt = channelUpsamplerT(xt)

        // === Cross-Domain Transformer ===
        (x, xt) = crosstransformer(x, xt)

        // === Channel Downsampler (512 → 384) ===
        x = x.reshaped([B, Fr * T1, config.bottomChannels])
        x = channelDownsampler(x)
        x = x.reshaped([B, Fr, T1, config.encoderBottleneckChannels])

        xt = channelDownsamplerT(xt)

        // === Decoding ===
        for idx in 0..<config.depth {
            // Spectral decoder: pop skip from end (deepest first)
            let specSkip = savedSpec[config.depth - 1 - idx]
            _ = lengthsSpec[config.depth - 1 - idx]
            let (specDecoded, _) = decoder[idx].decode(x, skip: specSkip)
            x = specDecoded

            // Temporal decoder: pop skip from end
            let tempSkip = savedTemp[config.depth - 1 - idx]
            let tempLength = lengthsTemp[config.depth - 1 - idx]
            let (tempDecoded, _) = tdecoder[idx].decode(xt, skip: tempSkip, length: tempLength)
            xt = tempDecoded
        }

        // === Spectral Output: reshape for multi-source → denormalize → iSTFT ===
        // x: [B, Fr, T, 16] where 16 = 4 sources × 4 CaC channels
        // Reshape to [B, sources, CaC, Fr, T] for masking
        let S = config.sources
        let CaC = config.cacChannels
        // channels-last [B, Fr, T, S*CaC] → [B, Fr, T, S, CaC] → [B, S, CaC, Fr, T]
        x = x.reshaped([B, Fq, T, S, CaC])
        x = x.transposed(0, 3, 4, 1, 2)  // [B, S, CaC, Fr, T]

        // Denormalize
        x = x * std.transposed(0, 3, 1, 2).expandedDimensions(axis: 1) + mean.transposed(0, 3, 1, 2).expandedDimensions(axis: 1)

        // Extract vocals source and apply CaC → complex → iSTFT
        let vocalsSpec = x[0..., config.vocalsIndex, 0..., 0..., 0...]  // [B, CaC, Fr, T]
        let vocalsComplex = fromCaC(vocalsSpec)  // [B, 2, Fr, T] complex
        let spectralVocals = istft(vocalsComplex, length: paddedLength)  // [B, 2, samples]

        // === Temporal Output: reshape for multi-source → denormalize ===
        // xt: [B, T, 8] where 8 = 4 sources × 2 audio channels
        // Reshape to [B, S, audioChannels, T]
        xt = xt.reshaped([B, xt.shape[1], S, config.audioChannels])
        xt = xt.transposed(0, 2, 3, 1)  // [B, S, 2, T]

        // Denormalize
        xt = xt * stdt.transposed(0, 2, 1).expandedDimensions(axis: 1) + meant.transposed(0, 2, 1).expandedDimensions(axis: 1)

        // Extract vocals source
        let temporalVocals = xt[0..., config.vocalsIndex, 0..., 0...]  // [B, 2, T]

        // === Sum spectral + temporal vocals ===
        let combined = spectralVocals + temporalVocals

        // Trim to original length
        return combined[0..., 0..., ..<originalLength]
    }

    // MARK: - STFT / iSTFT

    /// Compute STFT with proper padding for htdemucs.
    ///
    /// Input: `[B, 2, samples]` → Output: complex `[B, 2, freq_bins, frames]`
    private func stft(_ x: MLXArray) -> MLXArray {
        let hl = config.hopLength
        let nfft = config.nFFT
        let length = x.shape[2]
        let le = Int(ceil(Double(length) / Double(hl)))
        let pad = hl / 2 * 3  // 1536

        // Reflect-pad the signal
        let padded = reflectPad1d(x, left: pad, right: pad + le * hl - length)

        // STFT
        var z = STFT.stft(padded, nFFT: nfft, hopLength: hl, window: window)

        // Remove last frequency bin and trim padding frames
        let freqBins = z.shape[2] - 1
        z = z[0..., 0..., ..<freqBins, 0...]       // [..., :-1, :]
        z = z[0..., 0..., 0..., 2..<(2 + le)]      // [..., 2:2+le]

        return z
    }

    /// Compute iSTFT with proper padding/trimming for htdemucs.
    ///
    /// Input: complex `[B, 2, freq_bins, frames]` → Output: `[B, 2, length]`
    private func istft(_ z: MLXArray, length: Int) -> MLXArray {
        let hl = config.hopLength
        let nfft = config.nFFT

        // Pad back the removed frequency bin
        let freqPad = MLXArray.zeros([z.shape[0], z.shape[1], 1, z.shape[3]], dtype: z.dtype)
        var zPadded = concatenated([z, freqPad], axis: 2)

        // Pad 2 frames on each side (time dimension)
        let timePad = MLXArray.zeros([z.shape[0], z.shape[1], zPadded.shape[2], 2], dtype: z.dtype)
        zPadded = concatenated([timePad, zPadded, timePad], axis: 3)

        let pad = hl / 2 * 3
        let le = hl * Int(ceil(Double(length) / Double(hl))) + 2 * pad

        var x = ISTFT.istft(zPadded, nFFT: nfft, hopLength: hl, window: window, length: le)

        // Trim padding
        x = x[0..., 0..., pad..<(pad + length)]

        return x
    }

    // MARK: - CaC Conversion

    /// Convert complex spectrogram to Complex-as-Channels format.
    ///
    /// Input: complex `[batch, 2, freq_bins, frames]`
    /// Output: real `[batch, freq_bins, frames, 4]` (channels-last CaC)
    private func toCaC(_ z: MLXArray) -> MLXArray {
        let re = z.realPart()
        let im = z.imaginaryPart()

        let lRe = re[0..., 0, 0..., 0...]
        let lIm = im[0..., 0, 0..., 0...]
        let rRe = re[0..., 1, 0..., 0...]
        let rIm = im[0..., 1, 0..., 0...]

        return MLX.stacked([lRe, lIm, rRe, rIm], axis: -1)
    }

    /// Convert CaC back to complex spectrogram.
    ///
    /// Input: real `[batch, CaC, freq_bins, frames]` (channels-first, per source)
    /// Output: complex `[batch, 2, freq_bins, frames]`
    private func fromCaC(_ x: MLXArray) -> MLXArray {
        // x: [B, 4, Fr, T] where 4 = L_Re, L_Im, R_Re, R_Im
        let lRe = x[0..., 0, 0..., 0...]
        let lIm = x[0..., 1, 0..., 0...]
        let rRe = x[0..., 2, 0..., 0...]
        let rIm = x[0..., 3, 0..., 0...]

        let j = MLXArray([Float(0.0), Float(1.0)]).view(dtype: .complex64)

        let lComplex = lRe.asType(.complex64) + lIm.asType(.complex64) * j
        let rComplex = rRe.asType(.complex64) + rIm.asType(.complex64) * j

        return MLX.stacked([lComplex, rComplex], axis: 1)
    }

    // MARK: - Padding

    /// Reflect-pad a 1D signal along the last axis.
    private func reflectPad1d(_ x: MLXArray, left: Int, right: Int) -> MLXArray {
        let length = x.shape[2]

        var padded = x
        var leftRemaining = left
        var rightRemaining = right

        // Pad left: reflect from indices [1..chunk] in reverse order
        while leftRemaining > 0 {
            let chunk = min(leftRemaining, length - 1)
            // Reverse slice along axis 2: indices chunk down to 1
            let reflected = padded[0..., 0..., .stride(from: chunk, to: 0, by: -1)]
            padded = concatenated([reflected, padded], axis: 2)
            leftRemaining -= chunk
        }

        // Pad right: reflect from end
        let newLength = padded.shape[2]
        while rightRemaining > 0 {
            let chunk = min(rightRemaining, newLength - 1)
            // Reverse slice along axis 2: indices (len-2) down to (len-chunk-1)
            let reflected = padded[0..., 0..., .stride(from: newLength - 2, to: newLength - chunk - 2, by: -1)]
            padded = concatenated([padded, reflected], axis: 2)
            rightRemaining -= chunk
        }

        return padded
    }

    /// Pad the input waveform to the training segment length for valid processing.
    private func padToValid(_ x: MLXArray) -> MLXArray {
        let length = x.shape[2]
        let trainingLength = Int(config.segment * config.sampleRate)

        if length >= trainingLength {
            return x
        }

        let padAmount = trainingLength - length
        let rightPad = MLXArray.zeros([x.shape[0], x.shape[1], padAmount], dtype: x.dtype)
        return concatenated([x, rightPad], axis: 2)
    }
}
