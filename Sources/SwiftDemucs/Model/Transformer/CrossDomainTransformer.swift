import Foundation
import MLX
import MLXNN

/// Cross-domain transformer encoder for htdemucs (CrossTransformerEncoder).
///
/// Processes spectral and temporal bottleneck features through interleaved
/// self-attention and cross-attention layers with sinusoidal position embeddings.
///
/// Architecture (htdemucs_ft, 5 layers, classic_parity=0):
/// - Layer 0 (even): Self-attention on spectral and temporal independently
/// - Layer 1 (odd):  Cross-attention — spectral queries attend to temporal, and vice versa
/// - Layer 2 (even): Self-attention
/// - Layer 3 (odd):  Cross-attention
/// - Layer 4 (even): Self-attention
///
/// Spectral and temporal branches each have their own layer arrays and input norms.
///
/// The self-attention layers (indices 0, 2, 4) are stored in `self_layers`/`self_layers_t`
/// and cross-attention layers (indices 1, 3) in `cross_layers`/`cross_layers_t`.
/// convert_weights.py remaps `layers.N.*` → `self_layers.M.*` or `cross_layers.M.*`.
///
/// Input: spectral `[B, Fr, T, C]` channels-last, temporal `[B, T, C]` channels-last.
/// Output: same shapes, with cross-domain information fused.
class CrossDomainTransformer: Module {
    @ModuleInfo(key: "norm_in") var normIn: LayerNorm
    @ModuleInfo(key: "norm_in_t") var normInT: LayerNorm

    // Spectral branch: separated by layer type for type-safe weight loading
    @ModuleInfo(key: "self_layers") var selfLayers: [SelfAttentionTransformerLayer]
    @ModuleInfo(key: "cross_layers") var crossLayers: [CrossAttentionTransformerLayer]

    // Temporal branch: same pattern
    @ModuleInfo(key: "self_layers_t") var selfLayersT: [SelfAttentionTransformerLayer]
    @ModuleInfo(key: "cross_layers_t") var crossLayersT: [CrossAttentionTransformerLayer]

    let numLayers: Int
    let dims: Int
    let weightPosEmbed: Float

    init(
        dims: Int = 512,
        numHeads: Int = 8,
        numLayers: Int = 5,
        hiddenScale: Float = 4.0,
        weightPosEmbed: Float = 1.0
    ) {
        self.numLayers = numLayers
        self.dims = dims
        self.weightPosEmbed = weightPosEmbed

        self._normIn.wrappedValue = LayerNorm(dimensions: dims)
        self._normInT.wrappedValue = LayerNorm(dimensions: dims)

        // classic_parity=0: even indices are self-attention, odd are cross-attention
        var selfLayersList = [SelfAttentionTransformerLayer]()
        var crossLayersList = [CrossAttentionTransformerLayer]()
        var selfLayersTList = [SelfAttentionTransformerLayer]()
        var crossLayersTList = [CrossAttentionTransformerLayer]()

        for idx in 0..<numLayers {
            if idx % 2 == 0 {
                selfLayersList.append(SelfAttentionTransformerLayer(
                    dims: dims, numHeads: numHeads, hiddenScale: hiddenScale
                ))
                selfLayersTList.append(SelfAttentionTransformerLayer(
                    dims: dims, numHeads: numHeads, hiddenScale: hiddenScale
                ))
            } else {
                crossLayersList.append(CrossAttentionTransformerLayer(
                    dims: dims, numHeads: numHeads, hiddenScale: hiddenScale
                ))
                crossLayersTList.append(CrossAttentionTransformerLayer(
                    dims: dims, numHeads: numHeads, hiddenScale: hiddenScale
                ))
            }
        }

        self._selfLayers.wrappedValue = selfLayersList
        self._crossLayers.wrappedValue = crossLayersList
        self._selfLayersT.wrappedValue = selfLayersTList
        self._crossLayersT.wrappedValue = crossLayersTList
    }

    /// Process spectral and temporal bottleneck features.
    ///
    /// - Parameters:
    ///   - spectral: Shape `[B, Fr, T, C]` from spectral encoder (channels-last).
    ///   - temporal: Shape `[B, T, C]` from temporal encoder (channels-last).
    /// - Returns: Tuple of (spectral, temporal) with same shapes as input.
    func callAsFunction(_ spectral: MLXArray, _ temporal: MLXArray) -> (MLXArray, MLXArray) {
        let B = spectral.shape[0]
        let Fr = spectral.shape[1]
        let T1 = spectral.shape[2]
        let C = spectral.shape[3]
        let T2 = temporal.shape[1]

        // Flatten spectral: [B, Fr, T, C] → [B, T*Fr, C]
        // PyTorch: rearrange "b c fr t -> b (t fr) c" — time-major order
        // From channels-last [B, Fr, T, C]: transpose to [B, T, Fr, C] then flatten
        var s = spectral.transposed(0, 2, 1, 3)  // [B, T, Fr, C]
        s = s.reshaped([B, T1 * Fr, C])           // [B, T*Fr, C]

        // 2D sinusoidal position embedding for spectral
        let posEmb2D = create2DSinEmbedding(dim: C, height: Fr, width: T1)
        s = normIn(s)
        s = s + weightPosEmbed * posEmb2D

        // 1D sinusoidal position embedding for temporal
        var t = temporal  // [B, T2, C]
        let posEmb = createSinEmbedding(length: T2, dim: C)
        t = normInT(t)
        t = t + weightPosEmbed * posEmb

        // Process through interleaved self-attention and cross-attention layers
        var selfIdx = 0
        var crossIdx = 0
        for idx in 0..<numLayers {
            if idx % 2 == 0 {
                s = selfLayers[selfIdx](s)
                t = selfLayersT[selfIdx](t)
                selfIdx += 1
            } else {
                let oldS = s
                s = crossLayers[crossIdx](s, t)
                t = crossLayersT[crossIdx](t, oldS)
                crossIdx += 1
            }
        }

        // Unflatten spectral: [B, T*Fr, C] → [B, Fr, T, C]
        s = s.reshaped([B, T1, Fr, C])           // [B, T, Fr, C]
        s = s.transposed(0, 2, 1, 3)             // [B, Fr, T, C]

        return (s, t)
    }

    // MARK: - Positional Embeddings

    /// Create 1D sinusoidal positional embedding.
    ///
    /// Matches PyTorch's `create_sin_embedding` with TBC format → BTC.
    /// Output shape: `[1, length, dim]`.
    private func createSinEmbedding(
        length: Int, dim: Int, maxPeriod: Float = 10000.0
    ) -> MLXArray {
        let halfDim = dim / 2
        let positions = MLXArray(Array(stride(from: Float(0), to: Float(length), by: 1)))
            .reshaped([length, 1])
        let dimIndices = MLXArray(Array(stride(from: Float(0), to: Float(halfDim), by: 1)))
            .reshaped([1, halfDim])
        let phase = positions / pow(MLXArray(maxPeriod), dimIndices / Float(halfDim - 1))
        let cosPhase = cos(phase)
        let sinPhase = sin(phase)
        let embedding = concatenated([cosPhase, sinPhase], axis: -1)  // [length, dim]
        return embedding.reshaped([1, length, dim])
    }

    /// Create 2D sinusoidal positional embedding for spectral features.
    ///
    /// Encodes both height (frequency) and width (time) positions.
    /// Matches PyTorch's `create_2d_sin_embedding`.
    /// Output shape: `[1, width*height, dim]` (flattened in time-major order).
    private func create2DSinEmbedding(
        dim: Int, height: Int, width: Int, maxPeriod: Float = 10000.0
    ) -> MLXArray {
        let halfDim = dim / 2

        let dimIndices = MLXArray(
            stride(from: Float(0), to: Float(halfDim), by: 2).map { $0 }
        )
        let logScale: Float = -Foundation.log(maxPeriod) / Float(halfDim)
        let divTerm = exp(dimIndices * MLXArray(logScale))

        let posW = MLXArray(Array(stride(from: Float(0), to: Float(width), by: 1)))
            .reshaped([width, 1])
        let posH = MLXArray(Array(stride(from: Float(0), to: Float(height), by: 1)))
            .reshaped([height, 1])

        // Width (time) embeddings using first half of channels
        let sinW = sin(posW * divTerm)  // [width, quarterDim]
        let cosW = cos(posW * divTerm)

        // Height (freq) embeddings using second half of channels
        let sinH = sin(posH * divTerm)  // [height, quarterDim]
        let cosH = cos(posH * divTerm)

        // Interleave sin/cos: pe[0::2] = sin, pe[1::2] = cos
        let widthEmb = interleave(sinW, cosW)    // [width, halfDim]
        let heightEmb = interleave(sinH, cosH)   // [height, halfDim]

        // Combine: for each (t, fr) position, concat width_emb[t] and height_emb[fr]
        // Time-major order matches PyTorch's rearrange "b c fr t -> b (t fr) c"
        let bShape = [1, width, height, halfDim]
        let wExpanded = broadcast(
            widthEmb.reshaped([1, width, 1, halfDim]), to: bShape
        )
        let hExpanded = broadcast(
            heightEmb.reshaped([1, 1, height, halfDim]), to: bShape
        )
        let combined = concatenated([wExpanded, hExpanded], axis: -1)  // [1, width, height, dim]
        return combined.reshaped([1, width * height, dim])
    }

    /// Interleave two arrays along the last axis: [a0, b0, a1, b1, ...].
    private func interleave(_ a: MLXArray, _ b: MLXArray) -> MLXArray {
        let aExpanded = a.expandedDimensions(axis: -1)  // [N, M, 1]
        let bExpanded = b.expandedDimensions(axis: -1)  // [N, M, 1]
        let stacked = concatenated([aExpanded, bExpanded], axis: -1)  // [N, M, 2]
        return stacked.reshaped([a.shape[0], a.shape[1] * 2])
    }
}
