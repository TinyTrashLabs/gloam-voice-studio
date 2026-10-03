import MLX
import MLXNN

/// Temporal encoder layer (HEncLayer with freq=False).
///
/// Structure: Conv1d → GELU → DConv → Rewrite(Conv1d) → GLU
///
/// Operates in channels-last format: `[batch, time, channels]`.
///
/// The `empty` flag is set for the last temporal encoder layer when the
/// spectral branch has collapsed to a single frequency bin. Empty layers
/// have only a conv (no DConv/rewrite) and inject their output into the
/// spectral encoder instead of producing a skip connection.
class TemporalEncoderLayer: Module {
    @ModuleInfo var conv: Conv1d
    @ModuleInfo var rewrite: Conv1d
    @ModuleInfo var dconv: DConv

    let outChannels: Int
    let stride: Int
    let pad: Int
    let empty: Bool

    init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int = 8,
        stride: Int = 4,
        empty: Bool = false,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        self.outChannels = outChannels
        self.stride = stride
        self.pad = kernelSize / 4
        self.empty = empty

        self._conv.wrappedValue = Conv1d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: kernelSize,
            stride: stride,
            padding: pad
        )

        // Rewrite and DConv are only used when not empty
        self._rewrite.wrappedValue = Conv1d(
            inputChannels: outChannels,
            outputChannels: 2 * outChannels,
            kernelSize: 1
        )

        self._dconv.wrappedValue = DConv(
            channels: outChannels,
            compress: dconvCompress,
            depth: dconvDepth
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Pad input to be divisible by stride
        var input = x
        let length = input.shape[input.ndim - 2]  // time dim in channels-last
        if length % stride != 0 {
            let padAmount = stride - (length % stride)
            input = padded(input, widths: [.init((0, 0)), .init((0, padAmount)), .init((0, 0))])
        }

        var y = conv(input)  // [B, T', C_out]

        if empty { return y }

        // GELU activation
        y = gelu(y)

        // DConv (already in [B, T, C] format — no reshape needed)
        y = dconv(y)

        // Rewrite: conv → GLU
        let z = rewrite(y)
        return glu(z, axis: -1)
    }
}

/// 4-layer temporal (time-domain) encoder branch.
///
/// Processes the raw waveform through progressively deeper Conv1d layers,
/// each producing a skip connection for the U-Net decoder.
///
/// Input: `[batch, samples, 2]` (stereo channels-last)
/// Output: Array of skip connections, one per encoder layer.
class TemporalEncoder: Module {
    @ModuleInfo var layers: [TemporalEncoderLayer]

    init(
        channels: [Int] = [2, 48, 96, 192, 384],
        kernelSize: Int = 8,
        stride: Int = 4,
        dconvCompress: Int = 8,
        dconvDepth: Int = 2
    ) {
        let depth = channels.count - 1
        self._layers.wrappedValue = (0..<depth).map { i in
            TemporalEncoderLayer(
                inChannels: channels[i],
                outChannels: channels[i + 1],
                kernelSize: kernelSize,
                stride: stride,
                dconvCompress: dconvCompress,
                dconvDepth: dconvDepth
            )
        }
    }

    func encode(_ x: MLXArray) -> [MLXArray] {
        var skips = [MLXArray]()
        var out = x
        for layer in layers {
            out = layer(out)
            skips.append(out)
        }
        return skips
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        encode(x).last!
    }
}
