import MLX
import MLXNN

/// Temporal decoder layer (HDecLayer with freq=False).
///
/// Structure: (x+skip) → Rewrite(Conv1d) → GLU → DConv → ConvTranspose1d → [GELU if not last]
///
/// For htdemucs_ft, no GroupNorm (norm_starts=4, all indices < 4).
/// The conv_tr kernel is 8, stride 4.
/// The rewrite kernel is 3 (context=1, so 1+2*1=3).
///
/// Operates in channels-last format: `[batch, time, channels]`.
///
/// The `empty` flag is set for the last temporal decoder layer when the
/// spectral branch has collapsed to a single frequency bin. Empty layers
/// have only conv_tr (no DConv/rewrite) and receive injection from the
/// spectral decoder pre-convTr output instead of a skip connection.
class TemporalDecoderLayer: Module {
    @ModuleInfo(key: "conv_tr") var convTr: ConvTransposed1d
    @ModuleInfo var rewrite: Conv1d
    @ModuleInfo var dconv: DConv

    let inChannels: Int
    let outChannels: Int
    let stride: Int
    let pad: Int
    let isLast: Bool
    let empty: Bool

    init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        context: Int = 1,
        isLast: Bool = false,
        empty: Bool = false,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.stride = stride
        self.pad = kernelSize / 4
        self.isLast = isLast
        self.empty = empty

        // ConvTranspose1d
        self._convTr.wrappedValue = ConvTransposed1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride
        )

        // Rewrite: context conv [2*context+1]
        let rewriteKernel = 1 + 2 * context
        self._rewrite.wrappedValue = Conv1d(
            inputChannels: inChannels,
            outputChannels: 2 * inChannels,
            kernelSize: rewriteKernel,
            stride: 1,
            padding: context
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
    ///   - skip: Skip connection from corresponding encoder layer (nil for empty layers).
    ///   - length: Expected output time dimension (for trimming ConvTranspose output).
    /// - Returns: Tuple of (decoded output, pre-convTr features for spectral injection).
    func decode(_ x: MLXArray, skip: MLXArray?, length: Int) -> (MLXArray, MLXArray) {
        var y: MLXArray

        if empty {
            // Empty layers pass through directly (skip is nil)
            y = x
        } else {
            // Skip connection
            y = x + skip!

            // Rewrite → GLU
            y = rewrite(y)               // [B, T, 2*C]
            y = glu(y, axis: -1)         // [B, T, C]

            // DConv (already in [B, T, C] format)
            y = dconv(y)
        }

        let pre = y  // Save pre-transpose features for spectral branch injection

        // ConvTranspose1d
        var z = convTr(y)  // [B, T', C_out]

        // Trim to expected length
        if pad > 0 {
            z = z[0..., pad..<(pad + length), 0...]
        }

        // GELU for non-final layers
        if !isLast {
            z = gelu(z)
        }

        return (z, pre)
    }
}

/// 4-layer temporal (time-domain) decoder branch.
///
/// Mirrors the temporal encoder in reverse with transposed convolutions
/// and U-Net skip connections.
///
/// The decoder array is stored in deepest-first order (matching the checkpoint):
/// - decoder[0] processes the deepest (smallest temporal) features
/// - decoder[3] produces the final output
class TemporalDecoder: Module {
    @ModuleInfo var layers: [TemporalDecoderLayer]

    init(
        channels: [Int] = [384, 192, 96, 48, 8],
        kernelSize: Int = 8,
        stride: Int = 4,
        context: Int = 1,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        let depth = channels.count - 1
        self._layers.wrappedValue = (0..<depth).map { i in
            TemporalDecoderLayer(
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
        let reversedLengths = Array(lengths.reversed())
        var preOutputs = [MLXArray]()
        for (i, layer) in layers.enumerated() {
            let skip = reversedSkips[i]
            let length = reversedLengths[i]
            let (decoded, pre) = layer.decode(out, skip: skip, length: length)
            out = decoded
            preOutputs.append(pre)
        }
        return (out, preOutputs)
    }
}
