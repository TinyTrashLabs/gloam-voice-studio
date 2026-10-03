import MLX
import MLXNN

/// Multi-head attention with separate Q, K, V, output projections.
///
/// Replaces PyTorch's `nn.MultiheadAttention` packed `in_proj_weight` with
/// individual projections for MLX weight loading.
///
/// Checkpoint mapping (via convert_weights.py):
/// - `in_proj_weight` [3*dim, dim] → split into `query_proj.weight`, `key_proj.weight`, `value_proj.weight`
/// - `in_proj_bias` [3*dim] → split into `query_proj.bias`, `key_proj.bias`, `value_proj.bias`
/// - `out_proj.weight/bias` → `out_proj.weight/bias` (unchanged)
class Attention: Module {
    @ModuleInfo(key: "query_proj") var queryProj: Linear
    @ModuleInfo(key: "key_proj") var keyProj: Linear
    @ModuleInfo(key: "value_proj") var valueProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    let numHeads: Int
    let scale: Float

    init(dims: Int, numHeads: Int = 8) {
        self.numHeads = numHeads
        self.scale = 1.0 / Float(dims / numHeads).squareRoot()

        self._queryProj.wrappedValue = Linear(dims, dims)
        self._keyProj.wrappedValue = Linear(dims, dims)
        self._valueProj.wrappedValue = Linear(dims, dims)
        self._outProj.wrappedValue = Linear(dims, dims)
    }

    /// Scaled dot-product multi-head attention.
    ///
    /// - Parameters:
    ///   - queries: Query tensor `[B, T_q, D]`.
    ///   - keys: Key tensor `[B, T_k, D]`.
    ///   - values: Value tensor `[B, T_k, D]`.
    /// - Returns: Output `[B, T_q, D]`.
    func callAsFunction(queries: MLXArray, keys: MLXArray, values: MLXArray) -> MLXArray {
        let B = queries.shape[0]
        let Tq = queries.shape[1]
        let Tk = keys.shape[1]
        let headDim = queries.shape[2] / numHeads

        // Project and reshape for multi-head: [B, T, D] → [B, H, T, D/H]
        let q = queryProj(queries).reshaped([B, Tq, numHeads, headDim]).transposed(0, 2, 1, 3)
        let k = keyProj(keys).reshaped([B, Tk, numHeads, headDim]).transposed(0, 2, 1, 3)
        let v = valueProj(values).reshaped([B, Tk, numHeads, headDim]).transposed(0, 2, 1, 3)

        // Scaled dot-product attention
        let scores = (q * scale).matmul(k.transposed(0, 1, 3, 2))  // [B, H, T_q, T_k]
        let weights = softmax(scores, axis: -1)
        let attended = weights.matmul(v)  // [B, H, T_q, D/H]

        // Reshape back: [B, H, T_q, D/H] → [B, T_q, D]
        let output = attended.transposed(0, 2, 1, 3).reshaped([B, Tq, numHeads * headDim])
        return outProj(output)
    }
}

/// GroupNorm(1, C) applied in PyTorch's TBC convention.
///
/// In PyTorch's `MyGroupNorm`: transposes (B, T, C) → (B, C, T), applies
/// GroupNorm(1, C) which normalizes over (C, T) together, then transposes back.
///
/// This custom module replicates that normalization: mean and variance are
/// computed over both time and channels (axes 1 and 2) for each batch element.
class NormOut: Module {
    let weight: MLXArray
    let bias: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float = 1e-5) {
        self.weight = MLXArray.ones([dimensions])
        self.bias = MLXArray.zeros([dimensions])
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, T, C] — normalize over (T, C) together per batch
        let mean = x.mean(axes: [1, 2], keepDims: true)
        let variance = x.variance(axes: [1, 2], keepDims: true)
        let normalized = (x - mean) / (variance + eps).sqrt()
        return weight * normalized + bias
    }
}

/// Self-attention transformer layer (MyTransformerEncoderLayer).
///
/// Used at even indices (classic_parity=0) in the CrossTransformerEncoder.
///
/// Forward (norm_first=True):
/// ```
/// x = x + gamma_1(self_attn(norm1(x)))
/// x = x + gamma_2(FFN(norm2(x)))
/// x = norm_out(x)
/// ```
///
/// Checkpoint keys:
/// ```
/// self_attn.query_proj.weight/bias  (split from in_proj_weight)
/// self_attn.key_proj.weight/bias
/// self_attn.value_proj.weight/bias
/// self_attn.out_proj.weight/bias
/// norm1.weight/bias
/// norm2.weight/bias
/// linear1.weight/bias
/// linear2.weight/bias
/// gamma_1.scale
/// gamma_2.scale
/// norm_out.weight/bias
/// ```
class SelfAttentionTransformerLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Attention
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo(key: "gamma_1") var gamma1: LayerScale
    @ModuleInfo(key: "gamma_2") var gamma2: LayerScale
    @ModuleInfo(key: "norm_out") var normOut: NormOut

    init(dims: Int, numHeads: Int = 8, hiddenScale: Float = 4.0) {
        let hiddenDim = Int(Float(dims) * hiddenScale)

        self._selfAttn.wrappedValue = Attention(dims: dims, numHeads: numHeads)
        self._norm1.wrappedValue = LayerNorm(dimensions: dims)
        self._norm2.wrappedValue = LayerNorm(dimensions: dims)
        self._linear1.wrappedValue = Linear(dims, hiddenDim)
        self._linear2.wrappedValue = Linear(hiddenDim, dims)
        self._gamma1.wrappedValue = LayerScale(dimensions: dims, channelLast: true)
        self._gamma2.wrappedValue = LayerScale(dimensions: dims, channelLast: true)
        self._normOut.wrappedValue = NormOut(dimensions: dims)
    }

    /// Self-attention forward pass.
    ///
    /// - Parameter x: Input `[B, T, C]`.
    /// - Returns: Output `[B, T, C]`.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Self-attention: Q = K = V = norm1(x)
        let normed = norm1(x)
        var out = x + gamma1(selfAttn(queries: normed, keys: normed, values: normed))

        // Feed-forward
        let ffInput = norm2(out)
        let ff = linear2(gelu(linear1(ffInput)))
        out = out + gamma2(ff)

        // Output norm
        out = normOut(out)
        return out
    }
}

/// Cross-attention transformer layer (CrossTransformerEncoderLayer).
///
/// Used at odd indices (classic_parity=0) in the CrossTransformerEncoder.
///
/// Forward (norm_first=True):
/// ```
/// x = q + gamma_1(cross_attn(Q=norm1(q), K=norm2(k), V=norm2(k)))
/// x = x + gamma_2(FFN(norm3(x)))
/// x = norm_out(x)
/// ```
///
/// Checkpoint keys:
/// ```
/// cross_attn.query_proj.weight/bias  (split from in_proj_weight)
/// cross_attn.key_proj.weight/bias
/// cross_attn.value_proj.weight/bias
/// cross_attn.out_proj.weight/bias
/// norm1.weight/bias    (query norm)
/// norm2.weight/bias    (key norm)
/// norm3.weight/bias    (pre-FFN norm)
/// linear1.weight/bias
/// linear2.weight/bias
/// gamma_1.scale
/// gamma_2.scale
/// norm_out.weight/bias
/// ```
class CrossAttentionTransformerLayer: Module {
    @ModuleInfo(key: "cross_attn") var crossAttn: Attention
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo var norm3: LayerNorm
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo(key: "gamma_1") var gamma1: LayerScale
    @ModuleInfo(key: "gamma_2") var gamma2: LayerScale
    @ModuleInfo(key: "norm_out") var normOut: NormOut

    init(dims: Int, numHeads: Int = 8, hiddenScale: Float = 4.0) {
        let hiddenDim = Int(Float(dims) * hiddenScale)

        self._crossAttn.wrappedValue = Attention(dims: dims, numHeads: numHeads)
        self._norm1.wrappedValue = LayerNorm(dimensions: dims)
        self._norm2.wrappedValue = LayerNorm(dimensions: dims)
        self._norm3.wrappedValue = LayerNorm(dimensions: dims)
        self._linear1.wrappedValue = Linear(dims, hiddenDim)
        self._linear2.wrappedValue = Linear(hiddenDim, dims)
        self._gamma1.wrappedValue = LayerScale(dimensions: dims, channelLast: true)
        self._gamma2.wrappedValue = LayerScale(dimensions: dims, channelLast: true)
        self._normOut.wrappedValue = NormOut(dimensions: dims)
    }

    /// Cross-attention forward pass.
    ///
    /// - Parameters:
    ///   - q: Query input `[B, T_q, C]`.
    ///   - k: Key/value input `[B, T_k, C]` (from the other branch).
    /// - Returns: Output `[B, T_q, C]`.
    func callAsFunction(_ q: MLXArray, _ k: MLXArray) -> MLXArray {
        // Cross-attention: Q from norm1(q), K=V from norm2(k)
        let normedQ = norm1(q)
        let normedK = norm2(k)
        var out = q + gamma1(crossAttn(queries: normedQ, keys: normedK, values: normedK))

        // Feed-forward
        let ffInput = norm3(out)
        let ff = linear2(gelu(linear1(ffInput)))
        out = out + gamma2(ff)

        // Output norm
        out = normOut(out)
        return out
    }
}
