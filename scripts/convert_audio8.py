#!/usr/bin/env python3
"""Repack Edge0/Audio8-TTS-Realistic-0.6b into the Fish DualAR MLX layout that
TinyTrashLabs/mlx-audio-swift (FishSpeechModel, model_type fish_qwen3_omni) loads.

Input : a snapshot of huggingface.co/Edge0/Audio8-TTS-Realistic-0.6b
        (pinned revision 1e857568bfd4f02931aca3988ee773a44d2d26d3)
Output: config.json, model.safetensors, codec.safetensors, tokenizer files,
        LICENSE, NOTICE and a README.md model card (see docs/audio8-weights.md)

Run (needs torch + safetensors; use a venv outside the repo):
  python -I scripts/convert_audio8.py <audio8 snapshot dir> <out dir>
"""
import json
import shutil
import sys
from pathlib import Path

import torch
from safetensors import safe_open
from safetensors.torch import save_file

src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
SOURCE_REVISION = "1e857568bfd4f02931aca3988ee773a44d2d26d3"
a8 = json.loads((src / "config.json").read_text())

# Slow + fast AR: flat keys -> "model.*" (FishSpeechModel.sanitize keeps that prefix as-is).
model = {}
with safe_open(src / "model.safetensors", "pt") as f:
    for k in f.keys():
        model["model." + k] = f.get_tensor(k).contiguous()
save_file(model, out / "model.safetensors", metadata={"format": "mlx"})

# Codec: raw PyTorch state dict; FishS1DAC.sanitize maps weight-norm parametrizations itself.
codec = torch.load(src / "codec.pth", map_location="cpu", weights_only=True)
save_file({k: v.float().contiguous() for k, v in codec.items()}, out / "codec.safetensors")

def block(prefix: str, fast: bool) -> dict:
    g = (lambda k: a8["fast_" + k]) if fast else (lambda k: a8[k])
    return {
        "attention_o_bias": g("attention_o_bias"),
        "attention_qk_norm": g("attention_qk_norm"),
        "attention_qkv_bias": g("attention_qkv_bias"),
        "dim": g("dim"),
        "head_dim": g("head_dim"),
        "intermediate_size": g("intermediate_size"),
        "n_head": g("n_head"),
        "n_local_heads": g("n_local_heads"),
        "norm_eps": a8["norm_eps"],
        "rope_base": a8["rope_base"],
        "dropout": 0.0,
        "initializer_range": a8["initializer_range"],
        "use_gradient_checkpointing": False,
    }

text = block("", False) | {
    "model_type": "fish_qwen3",
    "n_layer": a8["n_layer"],
    "vocab_size": a8["vocab_size"],
    "max_seq_len": a8["max_seq_len"],
    "tie_word_embeddings": True,
}
audio = block("fast_", True) | {
    "model_type": "fish_qwen3_audio_decoder",
    "n_layer": a8["n_fast_layer"],
    "vocab_size": a8["codebook_size"],
    "num_codebooks": a8["num_codebooks"],
    "max_seq_len": a8["num_codebooks"] + 1,
    "text_dim": a8["dim"],
    "tie_word_embeddings": False,
}

# FishS1DACBuildConfig decodes with synthesized Codable: every non-optional key must be present
# or it silently falls back to Fish defaults (which have 4 decoder transformer layers).
codec_cfg = {
    "encoder_dim": 64, "encoder_rates": [2, 4, 8, 8], "latent_dim": 1024,
    "decoder_dim": 1536, "decoder_rates": [8, 8, 4, 2],
    "n_codebooks": 9, "codebook_size": 1024, "codebook_dim": 8, "semantic_codebook_size": 4096,
    "quantizer_dropout": 0.5, "downsample_factor": [2, 2], "sample_rate": a8["codec_sample_rate"],
    "causal": True, "encoder_transformer_layers": [0, 0, 0, 4], "decoder_transformer_layers": [0, 0, 0, 0],
    "quantizer_transformer_block_size": 4096, "quantizer_transformer_layers": 8,
    "quantizer_transformer_heads": 16, "quantizer_transformer_dim": 1024,
    "quantizer_transformer_intermediate_size": 3072, "quantizer_transformer_head_dim": 64,
    "quantizer_window_size": 128, "transformer_block_size": 16384, "transformer_head_dim": 64,
    "transformer_norm_eps": 1e-5, "transformer_rope_base": 10000.0,
    "quantizer_post_transformer_layers": a8["codec_post_n_layer"],
    "quantizer_post_transformer_heads": a8["codec_post_n_head"],
    "quantizer_post_transformer_local_heads": a8["codec_post_n_local_heads"],
    "quantizer_post_transformer_intermediate_size": a8["codec_post_intermediate_size"],
}

cfg = {
    "model_type": "fish_qwen3_omni",
    "dtype": "bfloat16",
    "eos_token_id": a8["eos_token_id"],
    "pad_token_id": a8["pad_token_id"],
    "semantic_start_token_id": a8["semantic_begin_id"],
    "semantic_end_token_id": a8["semantic_end_id"],
    "sample_rate": a8["codec_sample_rate"],
    "scale_codebook_embeddings": a8["scale_codebook_embeddings"],
    # Audio8-specific knobs read by the Fish loader (measured in Task 4 of the engine plan).
    "max_frames_per_text_token": 12.0,
    "reference_budget_scale": 1.95,
    "text_config": text,
    "audio_decoder_config": audio,
} | codec_cfg
(out / "config.json").write_text(json.dumps(cfg, indent=2))

for name in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "LICENSE", "NOTICE"):
    if (src / name).exists():
        shutil.copy(src / name, out / name)
README = f"""---
license: apache-2.0
base_model: Edge0/Audio8-TTS-Realistic-0.6b
library_name: mlx
pipeline_tag: text-to-speech
tags: [tts, mlx, voice-cloning, audio8]
---

# Audio8-TTS-0.6B-MLX

A repack of [Edge0/Audio8-TTS-Realistic-0.6b](https://huggingface.co/Edge0/Audio8-TTS-Realistic-0.6b)
(source revision `{SOURCE_REVISION}`) by Edge0, licensed under Apache 2.0. All credit for the model goes to Edge0.

This repo only rearranges the weights so the Fish DualAR loader in
[TinyTrashLabs/mlx-audio-swift](https://github.com/TinyTrashLabs/mlx-audio-swift) (PR #20) can load them:
the slow and fast transformer tensors are stored under `model.*` in `model.safetensors`, the codec is
converted from `codec.pth` to `codec.safetensors`, and `config.json` is written in the `fish_qwen3_omni` layout.
No weights are re-trained or quantised; the codec tensors are stored as fp32.

## Audio8-specific config keys

- `max_frames_per_text_token`: 12.0
- `reference_budget_scale`: 1.95

Everything else in `config.json` is the Fish layout with `scale_codebook_embeddings: false`.

## Licence

Apache 2.0. See `LICENSE` and `NOTICE` (copied from the source repo).
"""
(out / "README.md").write_text(README)
print("wrote", out, len(model), "model tensors,", len(codec), "codec tensors")
