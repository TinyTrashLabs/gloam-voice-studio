import MLX
import MLXNN

/// Learned scalar multiplier for residual connections.
///
/// Initialized to a small value (default 1e-4) to stabilize training.
/// Used in DConv sub-layers and transformer layers.
class LayerScale: Module, UnaryLayer {
    let scale: MLXArray
    let channelLast: Bool

    init(dimensions: Int, initValue: Float = 1e-4, channelLast: Bool = false) {
        self.channelLast = channelLast
        self.scale = MLXArray(Array(repeating: initValue, count: dimensions))
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // In channels-last format, scale [C] broadcasts with [..., C] naturally
        x * scale
    }
}
