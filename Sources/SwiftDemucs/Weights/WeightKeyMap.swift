import Foundation

/// Documents the key mapping from PyTorch htdemucs_ft checkpoint to MLX module tree.
///
/// The Python `scripts/convert_weights.py` handles the actual conversion.
/// This file serves as documentation and validation reference.
///
/// ## Conversion Pipeline (4 steps)
///
/// ### Step 1: Conv Weight Transposition (PyTorch → MLX channels-last)
///
/// Regular convolutions (I/O order preserved):
/// - **Conv1d:** `[O, I, K]` → `[O, K, I]` (axes: 0, 2, 1)
/// - **Conv2d:** `[O, I, kH, kW]` → `[O, kH, kW, I]` (axes: 0, 2, 3, 1)
///
/// Transposed convolutions (I/O swapped in PyTorch):
/// - **ConvTranspose1d:** `[I, O, K]` → `[O, K, I]` (axes: 1, 2, 0)
/// - **ConvTranspose2d:** `[I, O, kH, kW]` → `[O, kH, kW, I]` (axes: 1, 2, 3, 0)
///
/// ### Step 2: Attention Q/K/V Weight Split
///
/// PyTorch `nn.MultiheadAttention` fuses Q, K, V into `in_proj_weight` `[3*dim, dim]`.
/// convert_weights.py splits into separate projections:
/// - `in_proj_weight[0:dim]` → `query_proj.weight` `[dim, dim]`
/// - `in_proj_weight[dim:2*dim]` → `key_proj.weight` `[dim, dim]`
/// - `in_proj_weight[2*dim:]` → `value_proj.weight` `[dim, dim]`
/// - Same split for `in_proj_bias` → `query_proj.bias`, `key_proj.bias`, `value_proj.bias`
///
/// ### Step 3: Transformer Layer Index Remapping
///
/// PyTorch stores self-attention and cross-attention layers in a single
/// `ModuleList`, alternating with `classic_parity=0`:
/// - Even indices (0, 2, 4) → self-attention (MyTransformerEncoderLayer)
/// - Odd indices (1, 3) → cross-attention (CrossTransformerEncoderLayer)
///
/// convert_weights.py separates into typed arrays:
/// ```
/// crosstransformer.layers.0.*   → crosstransformer.self_layers.0.*
/// crosstransformer.layers.1.*   → crosstransformer.cross_layers.0.*
/// crosstransformer.layers.2.*   → crosstransformer.self_layers.1.*
/// crosstransformer.layers.3.*   → crosstransformer.cross_layers.1.*
/// crosstransformer.layers.4.*   → crosstransformer.self_layers.2.*
/// ```
/// Same for `layers_t` → `self_layers_t` / `cross_layers_t`.
///
/// ### Step 4: Float16 Conversion
///
/// All float32 weights converted to float16 for storage efficiency.
///
/// ## Key Path Structure (after conversion)
///
/// ```
/// encoder.N.conv.weight/bias                    (N=0..3, Conv2d [k,1])
/// encoder.N.rewrite.weight/bias                 (Conv2d [1,1] or [3,3])
/// encoder.N.dconv.layers.M.{0,1,3,4,6}.*       (M=0..1, DConv sub-layers)
///
/// tencoder.N.conv.weight/bias                   (N=0..3, Conv1d)
/// tencoder.N.rewrite.weight/bias                (Conv1d kernel=1)
/// tencoder.N.dconv.layers.M.{0,1,3,4,6}.*      (M=0..1)
///
/// decoder.N.conv_tr.weight/bias                 (N=0..3, ConvTranspose2d)
/// decoder.N.rewrite.weight/bias                 (Conv2d [3,3])
/// decoder.N.dconv.layers.M.{0,1,3,4,6}.*       (M=0..1)
///
/// tdecoder.N.conv_tr.weight/bias                (N=0..3, ConvTranspose1d)
/// tdecoder.N.rewrite.weight/bias                (Conv1d kernel=3)
/// tdecoder.N.dconv.layers.M.{0,1,3,4,6}.*      (M=0..1)
///
/// channel_upsampler.weight/bias                 (Conv1d 384→512)
/// channel_downsampler.weight/bias               (Conv1d 512→384)
/// channel_upsampler_t.weight/bias               (Conv1d 384→512)
/// channel_downsampler_t.weight/bias             (Conv1d 512→384)
///
/// freq_emb.embedding.weight                     (Embedding [512, 48])
///
/// crosstransformer.norm_in.weight/bias          (LayerNorm 512)
/// crosstransformer.norm_in_t.weight/bias        (LayerNorm 512)
///
/// crosstransformer.self_layers.N.*              (N=0..2, SelfAttentionTransformerLayer)
///   .self_attn.query_proj.weight/bias
///   .self_attn.key_proj.weight/bias
///   .self_attn.value_proj.weight/bias
///   .self_attn.out_proj.weight/bias
///   .norm1.weight/bias
///   .norm2.weight/bias
///   .linear1.weight/bias
///   .linear2.weight/bias
///   .gamma_1.scale
///   .gamma_2.scale
///   .norm_out.weight/bias
///
/// crosstransformer.cross_layers.N.*             (N=0..1, CrossAttentionTransformerLayer)
///   .cross_attn.query_proj.weight/bias
///   .cross_attn.key_proj.weight/bias
///   .cross_attn.value_proj.weight/bias
///   .cross_attn.out_proj.weight/bias
///   .norm1.weight/bias
///   .norm2.weight/bias
///   .norm3.weight/bias
///   .linear1.weight/bias
///   .linear2.weight/bias
///   .gamma_1.scale
///   .gamma_2.scale
///   .norm_out.weight/bias
///
/// crosstransformer.self_layers_t.N.*            (N=0..2, same as self_layers)
/// crosstransformer.cross_layers_t.N.*           (N=0..1, same as cross_layers)
/// ```
///
/// ## Key Counts
///
/// - Input checkpoint: 533 parameter tensors
/// - After QKV split: +40 new keys, -40 old in_proj keys → net same
/// - After layer remapping: key count preserved, only paths change
/// - Output: ~573 keys (533 + 40 from QKV split = 573, minus 20 in_proj_weight - 20 in_proj_bias = 533 + 40 = 573)
enum WeightKeyMap {

    /// Expected number of parameter tensors after conversion.
    ///
    /// 533 input keys from checkpoint
    /// + 60 new keys from QKV split (20 in_proj → 60 separate Q/K/V, each with weight+bias)
    /// - 40 removed in_proj keys (20 in_proj_weight + 20 in_proj_bias)
    /// = ~553 output keys
    ///
    /// Exact count may vary slightly; validate with `.noUnusedKeys` during loading.
    static let expectedKeyCount = 553

    /// Validate loaded parameter count is in expected range.
    static func validateKeyCount(_ count: Int) -> Bool {
        count >= 500 && count <= 600
    }
}
