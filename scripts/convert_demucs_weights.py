#!/usr/bin/env python3
"""Convert the htdemucs_ft *vocals* checkpoint to the MLX layout SwiftDemucs loads.

Input : 04573f0d.safetensors from huggingface.co/adefossez/HTDemucs-ft
        (htdemucs_ft.yaml lists models drums,bass,other,vocals -> the 4th, 04573f0d, is vocals)
Output: htdemucs_ft_vocals.safetensors  (see Sources/SwiftDemucs/Weights/WeightKeyMap.swift)

Run (no torch needed):
  uv run --with safetensors --with numpy scripts/convert_demucs_weights.py \
      [--input PATH] [--output-dir DIR] [--dtype float16|float32]
"""
import argparse
import glob
import os
import re
import sys

import numpy as np
from safetensors import safe_open
from safetensors.numpy import save_file

DEFAULT_IN = glob.glob(os.path.expanduser(
    "~/.cache/huggingface/hub/models--adefossez--HTDemucs-ft/snapshots/*/04573f0d.safetensors"))
DEFAULT_OUT = os.path.expanduser(
    "~/Library/Application Support/GloamVoiceStudio/Models/htdemucs-ft-vocals-mlx")

# nn.Sequential indices inside DConv layers -> named keys (DConv.swift)
DCONV_NAMES = {"0": "conv1", "1": "norm1", "3": "conv2", "4": "norm2", "6": "layer_scale"}

CONV1D = re.compile(r"^(tencoder|tdecoder)\.\d+\.(conv|rewrite)\.weight$"
                    r"|^channel_(up|down)sampler(_t)?\.weight$"
                    r"|\.dconv\.layers\.\d+\.\d+\.weight$")


def convert_key(key):
    m = re.match(r"^(.*\.dconv\.layers\.\d+)\.(\d+)\.(.*)$", key)
    if m:
        return f"{m.group(1)}.{DCONV_NAMES[m.group(2)]}.{m.group(3)}"
    m = re.match(r"^crosstransformer\.(layers|layers_t)\.(\d+)\.(.*)$", key)
    if m:
        idx = int(m.group(2))
        kind = "self_layers" if idx % 2 == 0 else "cross_layers"
        suffix = "_t" if m.group(1) == "layers_t" else ""
        return f"crosstransformer.{kind}{suffix}.{idx // 2}.{m.group(3)}"
    return key


def convert_tensor(key, w):
    """key is the ORIGINAL key. Returns channels-last / MLX layout."""
    if not key.endswith(".weight") or w.ndim < 3:
        return w
    if "conv_tr" in key:  # ConvTranspose: [I,O,k...] -> [O,k...,I]
        return np.transpose(w, (1, *range(2, w.ndim), 0))
    # Conv: [O,I,k...] -> [O,k...,I]
    return np.transpose(w, (0, *range(2, w.ndim), 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=DEFAULT_IN[0] if DEFAULT_IN else None)
    ap.add_argument("--output-dir", default=DEFAULT_OUT)
    ap.add_argument("--dtype", default="float16", choices=["float16", "float32"])
    a = ap.parse_args()
    if not a.input or not os.path.exists(a.input):
        sys.exit("input checkpoint not found; pass --input .../04573f0d.safetensors")

    out = {}
    with safe_open(a.input, "np") as f:
        for key in f.keys():
            w = f.get_tensor(key).astype(np.float32)
            if key.endswith("in_proj_weight") or key.endswith("in_proj_bias"):
                base = key.rsplit(".", 1)[0]
                leaf = "weight" if key.endswith("weight") else "bias"
                dim = w.shape[0] // 3
                for i, name in enumerate(("query_proj", "key_proj", "value_proj")):
                    new = convert_key(f"{base}.{name}.{leaf}")
                    out[new] = w[i * dim:(i + 1) * dim]
                continue
            new = convert_key(key)
            assert new not in out, new
            out[new] = convert_tensor(key, w)

    out = {k: np.ascontiguousarray(v.astype(a.dtype)) for k, v in out.items()}
    os.makedirs(a.output_dir, exist_ok=True)
    dest = os.path.join(a.output_dir, "htdemucs_ft_vocals.safetensors")
    save_file(out, dest)
    print(f"wrote {len(out)} tensors -> {dest} ({os.path.getsize(dest) / 1e6:.1f} MB)")
    if not 500 <= len(out) <= 600:
        sys.exit(f"unexpected key count {len(out)}")


if __name__ == "__main__":
    main()
