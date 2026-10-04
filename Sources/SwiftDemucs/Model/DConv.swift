import MLX
import MLXNN

/// A single depth layer within DConv.
///
/// Structure mirrors PyTorch nn.Sequential indices:
/// - 0: Conv1d (dilated depthwise, channels → hidden)  → conv1
/// - 1: GroupNorm(1, hidden)                            → norm1
/// - 2: GELU (no weights)
/// - 3: Conv1d (pointwise, hidden → 2*channels for GLU) → conv2
/// - 4: GroupNorm(1, 2*channels)                        → norm2
/// - 5: GLU (no weights)
/// - 6: LayerScale                                      → layer_scale
///
/// Uses named keys instead of numeric indices to avoid conflict with
/// MLX-Swift's NestedItem.unflattened() which treats all-numeric keys
/// as array indices. scripts/convert_demucs_weights.py remaps the PyTorch indices
/// (0, 1, 3, 4, 6) to these named keys.
class DConvSubLayer: Module {
    @ModuleInfo(key: "conv1") var conv1: Conv1d
    @ModuleInfo(key: "norm1") var norm1: GroupNorm
    @ModuleInfo(key: "conv2") var conv2: Conv1d
    @ModuleInfo(key: "norm2") var norm2: GroupNorm
    @ModuleInfo(key: "layer_scale") var layerScale: LayerScale

    let channels: Int

    init(channels: Int, hidden: Int, kernelSize: Int = 3, dilation: Int = 1) {
        self.channels = channels
        let padding = dilation * (kernelSize / 2)

        self._conv1.wrappedValue = Conv1d(
            inputChannels: channels,
            outputChannels: hidden,
            kernelSize: kernelSize,
            stride: 1,
            padding: padding,
            dilation: dilation
        )
        self._norm1.wrappedValue = GroupNorm(
            groupCount: 1, dimensions: hidden, pytorchCompatible: true
        )
        self._conv2.wrappedValue = Conv1d(
            inputChannels: hidden,
            outputChannels: 2 * channels,
            kernelSize: 1
        )
        self._norm2.wrappedValue = GroupNorm(
            groupCount: 1, dimensions: 2 * channels, pytorchCompatible: true
        )
        self._layerScale.wrappedValue = LayerScale(dimensions: channels)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, T, C] channels-last
        var h = conv1(x)           // [B, T, hidden]
        h = norm1(h)
        h = gelu(h)                // GELU activation
        h = conv2(h)               // [B, T, 2*C]
        h = norm2(h)
        h = glu(h, axis: -1)       // [B, T, C]
        h = layerScale(h)
        return h
    }
}

/// Depth-wise Convolution residual block.
///
/// Each DConv contains `depth` sub-layers (default 2), each with a dilated
/// Conv1d → GroupNorm → GELU → pointwise Conv1d → GroupNorm → GLU → LayerScale.
/// Sub-layers are applied as residuals: `x = x + sublayer(x)`.
///
/// Operates in channels-last format: `[batch, time, channels]`.
class DConv: Module {
    @ModuleInfo var layers: [DConvSubLayer]

    init(channels: Int, compress: Int = 8, depth: Int = 2, kernelSize: Int = 3) {
        let hidden = channels / compress
        self._layers.wrappedValue = (0..<depth).map { d in
            let dilation = 1 << d  // 2^d: 1, 2, 4, ...
            return DConvSubLayer(
                channels: channels,
                hidden: hidden,
                kernelSize: kernelSize,
                dilation: dilation
            )
        }
    }

    /// Apply DConv residual blocks.
    ///
    /// - Parameter x: Input `[batch, time, channels]` channels-last.
    /// - Returns: Output with same shape.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = x
        for layer in layers {
            out = out + layer(out)
        }
        return out
    }
}
