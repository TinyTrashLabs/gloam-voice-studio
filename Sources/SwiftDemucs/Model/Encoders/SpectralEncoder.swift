import MLX
import MLXNN

/// Spectral encoder layer (HEncLayer with freq=True).
///
/// Structure: Conv2d → GELU → DConv → Rewrite(Conv2d) → GLU
///
/// For htdemucs_ft, norm_starts=4 with depth=4, so no GroupNorm in encoder layers.
/// The conv kernel is `[kernel, 1]` — convolving only along frequency.
///
/// Operates in channels-last format: `[batch, freq, time, channels]`.
///
/// Checkpoint keys per layer:
/// ```
/// encoder.N.conv.weight/bias
/// encoder.N.rewrite.weight/bias
/// encoder.N.dconv.layers.*
/// ```
class SpectralEncoderLayer: Module {
    @ModuleInfo var conv: Conv2d
    @ModuleInfo var rewrite: Conv2d
    @ModuleInfo var dconv: DConv

    let inChannels: Int
    let outChannels: Int
    let stride: Int
    let pad: Int

    init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2,
        contextEnc: Int = 0
    ) {
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.stride = stride
        self.pad = kernelSize / 4

        // Conv2d with kernel [kernelSize, 1] — frequency-only convolution
        self._conv.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: IntOrPair((kernelSize, 1)),
            stride: IntOrPair((stride, 1)),
            padding: IntOrPair((pad, 0))
        )

        // Rewrite: 1×1 conv (or context conv for encoder with context_enc > 0)
        let rewriteKernel = 1 + 2 * contextEnc
        self._rewrite.wrappedValue = Conv2d(
            inputChannels: outChannels,
            outputChannels: 2 * outChannels,
            kernelSize: IntOrPair((rewriteKernel, rewriteKernel)),
            stride: IntOrPair((1, 1)),
            padding: IntOrPair((contextEnc, contextEnc))
        )

        // DConv operates in 1D on the channel dimension
        self._dconv.wrappedValue = DConv(
            channels: outChannels,
            compress: dconvCompress,
            depth: dconvDepth
        )
    }

    /// Encode with optional injection from temporal branch.
    ///
    /// - Parameters:
    ///   - x: Input `[batch, freq, time, channels]` channels-last.
    ///   - inject: Optional injection from temporal encoder (for last_freq layers).
    /// - Returns: Encoded features `[batch, freq', time, out_channels]`.
    func callAsFunction(_ x: MLXArray, inject: MLXArray? = nil) -> MLXArray {
        var y = conv(x)  // [B, Fr', T, C_out]

        // Inject temporal features if provided
        if let inject = inject {
            // inject is [B, T, C] → expand to [B, 1, T, C] for broadcasting
            if inject.ndim == 3 && y.ndim == 4 {
                y = y + inject.expandedDimensions(axis: 1)
            } else {
                y = y + inject
            }
        }

        // GELU activation (no GroupNorm for htdemucs_ft)
        y = gelu(y)

        // DConv: reshape spectral [B, Fr, T, C] → [B*Fr, T, C] for 1D conv
        let B = y.shape[0]
        let Fr = y.shape[1]
        let T = y.shape[2]
        let C = y.shape[3]
        y = y.reshaped([B * Fr, T, C])
        y = dconv(y)
        y = y.reshaped([B, Fr, T, C])

        // Rewrite: conv → GLU
        let z = rewrite(y)           // [B, Fr, T, 2*C]
        return glu(z, axis: -1)      // [B, Fr, T, C]
    }
}

/// 4-layer spectral (frequency-domain) encoder branch.
///
/// Processes the CaC spectrogram through progressively deeper layers,
/// each producing a skip connection for the U-Net decoder.
///
/// Input: `[batch, freq_bins, frames, 4]` (CaC format)
/// Output: Array of skip connections, one per encoder layer.
class SpectralEncoder: Module {
    @ModuleInfo var layers: [SpectralEncoderLayer]

    init(
        channels: [Int] = [4, 48, 96, 192, 384],
        kernelSize: Int = 8,
        stride: Int = 4,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        let depth = channels.count - 1
        self._layers.wrappedValue = (0..<depth).map { i in
            SpectralEncoderLayer(
                inChannels: channels[i],
                outChannels: channels[i + 1],
                kernelSize: kernelSize,
                stride: stride,
                dconvCompress: dconvCompress,
                dconvDepth: dconvDepth
            )
        }
    }

    func encode(_ x: MLXArray, injects: [MLXArray?] = []) -> [MLXArray] {
        var skips = [MLXArray]()
        var out = x
        for (i, layer) in layers.enumerated() {
            let inject = i < injects.count ? injects[i] : nil
            out = layer(out, inject: inject)
            skips.append(out)
        }
        return skips
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        encode(x).last!
    }
}
