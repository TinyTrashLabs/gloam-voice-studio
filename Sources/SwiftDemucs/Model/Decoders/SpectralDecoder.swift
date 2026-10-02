import MLX
import MLXNN

/// Spectral decoder layer (HDecLayer with freq=True).
///
/// Structure: (x+skip) → Rewrite(Conv2d) → GLU → DConv → ConvTranspose2d → [GELU if not last]
///
/// For htdemucs_ft, no GroupNorm (norm_starts=4, all indices < 4).
/// The conv_tr kernel is `[kernel, 1]` — transposing only along frequency.
/// The rewrite kernel is `[3, 3]` (context=1).
///
/// Operates in channels-last format: `[batch, freq, time, channels]`.
class SpectralDecoderLayer: Module {
    @ModuleInfo(key: "conv_tr") var convTr: ConvTransposed2d
    @ModuleInfo var rewrite: Conv2d
    @ModuleInfo var dconv: DConv

    let inChannels: Int
    let outChannels: Int
    let stride: Int
    let pad: Int
    let isLast: Bool

    init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        context: Int = 1,
        isLast: Bool = false,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.stride = stride
        self.pad = kernelSize / 4
        self.isLast = isLast

        // ConvTranspose2d with kernel [kernelSize, 1]
        self._convTr.wrappedValue = ConvTransposed2d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: IntOrPair((kernelSize, 1)),
            stride: IntOrPair((stride, 1))
        )

        // Rewrite: context conv [2*context+1, 2*context+1]
        let rewriteKernel = 1 + 2 * context
        self._rewrite.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: 2 * inChannels,
            kernelSize: IntOrPair((rewriteKernel, rewriteKernel)),
            stride: IntOrPair((1, 1)),
            padding: IntOrPair((context, context))
        )

        // DConv operates in 1D
        self._dconv.wrappedValue = DConv(
            channels: inChannels,
            compress: dconvCompress,
            depth: dconvDepth
        )
    }

    /// Decode with skip connection.
    ///
    /// - Parameters:
    ///   - x: Input from previous decoder layer or transformer.
    ///   - skip: Skip connection from corresponding encoder layer.
    /// - Returns: Tuple of (decoded output, pre-convTr features for temporal injection).
    func decode(_ x: MLXArray, skip: MLXArray) -> (MLXArray, MLXArray) {
        // Skip connection
        var y = x + skip

        // Rewrite → GLU
        y = rewrite(y)                // [B, Fr, T, 2*C]
        y = glu(y, axis: -1)          // [B, Fr, T, C]

        // DConv: reshape [B, Fr, T, C] → [B*Fr, T, C] for 1D conv
        let B = y.shape[0]
        let Fr = y.shape[1]
        let T = y.shape[2]
        let C = y.shape[3]
        y = y.reshaped([B * Fr, T, C])
        y = dconv(y)
        y = y.reshaped([B, Fr, T, C])

        let pre = y  // Save pre-transpose features for temporal branch injection

        // ConvTranspose2d
        var z = convTr(y)  // [B, Fr', T, C_out]

        // Trim padding from frequency dimension
        if pad > 0 {
            let freqOut = z.shape[1]
            z = z[0..., pad..<(freqOut - pad), 0..., 0...]
        }

        // GELU for non-final layers
        if !isLast {
            z = gelu(z)
        }

        return (z, pre)
    }
}

/// 4-layer spectral (frequency-domain) decoder branch.
///
/// Mirrors the spectral encoder in reverse with transposed convolutions
/// and U-Net skip connections.
///
/// The decoder array is stored in deepest-first order (matching the checkpoint):
/// - decoder[0] processes the deepest (smallest spatial) features
/// - decoder[3] produces the final output
class SpectralDecoder: Module {
    @ModuleInfo var layers: [SpectralDecoderLayer]

    init(
        channels: [Int] = [384, 192, 96, 48, 16],
        kernelSize: Int = 8,
        stride: Int = 4,
        context: Int = 1,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        let depth = channels.count - 1
        self._layers.wrappedValue = (0..<depth).map { i in
            SpectralDecoderLayer(
                inChannels: channels[i],
                outChannels: channels[i + 1],
                kernelSize: kernelSize,
                stride: stride,
                context: context,
                isLast: i == depth - 1,
                dconvCompress: dconvCompress,
                dconvDepth: dconvDepth
            )
        }
    }

    func decode(_ x: MLXArray, skips: [MLXArray], lengths: [Int]) -> (MLXArray, [MLXArray]) {
        var out = x
        let reversedSkips = Array(skips.reversed())
        var preOutputs = [MLXArray]()
        for (i, layer) in layers.enumerated() {
            let skip = reversedSkips[i]
            let (decoded, pre) = layer.decode(out, skip: skip)
            out = decoded
            preOutputs.append(pre)
        }
        return (out, preOutputs)
    }
}
