#!/usr/bin/env python3
"""LuxTTS weight conversion: torch checkpoint (model.pt) -> safetensors.

One-time DEV TOOL for the gloam-voice-studio LuxTTS port. Not compiled or
shipped with the app (excluded in Package.swift).

STATUS: written against the reference key-remapping code but NOT YET RUN —
running it requires the 491 MB model.pt download. Give it a test run once
RAM/bandwidth allows:

    uv run --with torch --with safetensors --with numpy \
        Sources/EngineKit/LuxTTS/convert_weights.py \
        --input ~/.cache/huggingface/hub/models--YatharthS--LuxTTS/snapshots/<rev>/model.pt \
        --output luxtts_model.safetensors --manifest luxtts_manifest.json

What it does (mirrors the reference loaders):

1. Load the checkpoint like LuxTTS-mlx/zipvoice/mlx/modeling_utils.py's
   `_load_torch_state_dict`:
     * `torch.load(path, map_location="cpu")`
     * unwrap `checkpoint["model"]` if present
     * strip a `module.` DataParallel prefix if present

2. Fold weight-norm reparametrizations like `_inject_weight_norm` /
   `_compute_weight_norm` in LuxTTS-mlx/zipvoice/mlx/weights.py:
     * `<base>.weight_g` + `<base>.weight_v`                       -> `<base>.weight`
     * `<base>.parametrizations.weight.original0` (+ `original1`)  -> `<base>.weight`
   using  weight = v * (g / (||v||_rows + 1e-12)), where g is reshaped to
   (out, 1, ...) and the norm is over all non-leading axes.
   The raw g/v keys are dropped from the output (unlike the reference, which
   keeps them around and simply fails to assign them). The acoustic model.pt
   is not expected to contain weight-norm keys — this exists so the same
   script also converts vocoder/vocos.bin, which does (upsample layers).

3. Optionally re-lay-out conv weights for MLX (like `_set_param`):
     * Conv1d          torch (out, in, k)  -> mlx (out, k, in)   transpose (0, 2, 1)
     * ConvTranspose1d torch (in, out, k)  -> mlx (out, k, in)   transpose (1, 2, 0)
     * Snake `alpha`   torch (1, C, 1)     -> mlx (1, 1, C)      transpose (0, 2, 1)
   Without the model class available we identify layers by shape + name:
     * any 3-D tensor at a `...weight` key is a Conv1d kernel, EXCEPT keys
       matching --convtranspose-regex (default: upsample layers, vocoder-only)
       which are ConvTranspose1d kernels;
     * any 3-D `...alpha` tensor shaped (1, C, 1) is a Snake alpha.
   In the LuxTTS acoustic model the only 3-D weights are the Zipformer
   ConvolutionModule / downsample conv kernels — plain Conv1d, so the
   heuristic is exact there. Pass `--layout torch` to skip all transposes
   and keep the original torch memory layout.

4. Save as safetensors with VERBATIM torch key names (dot-separated paths,
   e.g. `text_encoder.encoders.0.layers.0.self_attn_weights.in_proj.weight`).
   Top-level modules in model.pt (see zipvoice/models/zipvoice.py):
     * `embed.*`         nn.Embedding(vocab_size=360, 192)
     * `text_encoder.*`  TTSZipformer
     * `fm_decoder.*`    TTSZipformer
   The Swift port should name its module properties to match (the MLX-Swift
   `Module.update(parameters: ModuleParameters.unflattened(...))` path
   consumes exactly these dotted keys). Any renames Task 3 ends up needing
   should be reconciled here in a later integration pass — this script
   deliberately performs no cosmetic renaming.

5. Optionally write a JSON manifest (key -> shape/dtype) for the Swift side.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np


# ---------------------------------------------------------------------------
# Step 1: checkpoint loading (mirrors _load_torch_state_dict)
# ---------------------------------------------------------------------------

def load_torch_state_dict(path: Path):
    import torch

    try:
        checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    except Exception as ex:
        # icefall-style checkpoints can pickle non-tensor training state that
        # weights_only rejects. Only fall back for the trusted, manually
        # downloaded LuxTTS checkpoint; unpickling runs arbitrary code.
        print(f"  weights_only=True failed ({ex!r}); retrying with "
              f"weights_only=False — only OK for a trusted checkpoint",
              file=sys.stderr)
        checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    state_dict = checkpoint["model"] if "model" in checkpoint else checkpoint
    if any(k.startswith("module.") for k in state_dict):
        state_dict = {k[len("module."):]: v for k, v in state_dict.items()}
    return state_dict


def to_numpy(tensor) -> np.ndarray:
    return tensor.detach().cpu().numpy()


# ---------------------------------------------------------------------------
# Step 2: weight-norm folding (mirrors _inject_weight_norm / _compute_weight_norm)
# ---------------------------------------------------------------------------

_WN_SUFFIXES = {
    ".parametrizations.weight.original0": "g",
    ".parametrizations.weight.original1": "v",
    ".weight_g": "g",
    ".weight_v": "v",
}


def compute_weight_norm(weight_g: np.ndarray, weight_v: np.ndarray) -> np.ndarray:
    if weight_g.ndim == 1:
        shape = (weight_g.shape[0],) + (1,) * (weight_v.ndim - 1)
        weight_g = weight_g.reshape(shape)
    norm_axes = tuple(range(1, weight_v.ndim))
    v_norm = np.linalg.norm(weight_v, axis=norm_axes, keepdims=True)
    return weight_v * (weight_g / (v_norm + 1.0e-12))


def fold_weight_norm(arrays: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    groups: dict[str, dict[str, np.ndarray]] = {}
    passthrough: dict[str, np.ndarray] = {}

    for name, arr in arrays.items():
        for suffix, part in _WN_SUFFIXES.items():
            if name.endswith(suffix):
                base = name[: -len(suffix)]
                groups.setdefault(base, {})[part] = arr
                break
        else:
            passthrough[name] = arr

    out = dict(passthrough)
    for base, parts in groups.items():
        if "g" in parts and "v" in parts:
            out[base + ".weight"] = compute_weight_norm(parts["g"], parts["v"])
            print(f"  folded weight-norm: {base}.weight {out[base + '.weight'].shape}")
        else:
            # Incomplete pair: keep raw keys rather than lose data.
            for part, arr in parts.items():
                suffix = ".weight_g" if part == "g" else ".weight_v"
                out[base + suffix] = arr
                print(f"  WARNING: unpaired weight-norm component kept: {base}{suffix}",
                      file=sys.stderr)
    return out


# ---------------------------------------------------------------------------
# Step 3: layout transforms for MLX (mirrors _set_param's transposes)
# ---------------------------------------------------------------------------

def apply_mlx_layout(
    arrays: dict[str, np.ndarray], convtranspose_regex: str
) -> dict[str, np.ndarray]:
    ct_re = re.compile(convtranspose_regex) if convtranspose_regex else None
    out: dict[str, np.ndarray] = {}
    for name, arr in arrays.items():
        if name.endswith(".weight") and arr.ndim == 3:
            if ct_re is not None and ct_re.search(name):
                out[name] = np.transpose(arr, (1, 2, 0))  # ConvTranspose1d
                print(f"  convtranspose (1,2,0): {name} {arr.shape} -> {out[name].shape}")
            else:
                out[name] = np.transpose(arr, (0, 2, 1))  # Conv1d
                print(f"  conv1d (0,2,1): {name} {arr.shape} -> {out[name].shape}")
        elif (name.endswith(".alpha") and arr.ndim == 3
              and arr.shape[0] == 1 and arr.shape[2] == 1):
            out[name] = np.transpose(arr, (0, 2, 1))  # Snake alpha (vocoder)
            print(f"  alpha (0,2,1): {name} {arr.shape} -> {out[name].shape}")
        else:
            out[name] = arr
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", required=True, type=Path,
                        help="torch checkpoint (model.pt, or vocoder/vocos.bin)")
    parser.add_argument("--output", required=True, type=Path,
                        help="output .safetensors path")
    parser.add_argument("--layout", choices=["mlx", "torch"], default="mlx",
                        help="mlx (default): transpose conv kernels to the MLX "
                             "(out, k, in) layout consumed by the Swift port; "
                             "torch: keep original layout")
    parser.add_argument("--convtranspose-regex",
                        default=r"\.upsample_layers\.",
                        help="keys matching this regex (with 3-D .weight) are "
                             "treated as ConvTranspose1d (vocoder-only; the "
                             "acoustic model has none). Must NOT match "
                             "upsampler.resnet_blocks.*.conv1/conv2, which are "
                             "plain (dilated) Conv1d layers inside the "
                             "upsampler module, not transposed convs.")
    parser.add_argument("--dtype", choices=["keep", "float32", "float16"],
                        default="keep", help="optionally cast floating tensors")
    parser.add_argument("--manifest", type=Path, default=None,
                        help="optional JSON manifest of key -> {shape, dtype}")
    args = parser.parse_args()

    print(f"loading {args.input} ...")
    state_dict = load_torch_state_dict(args.input)

    arrays: dict[str, np.ndarray] = {}
    for name, value in state_dict.items():
        if hasattr(value, "detach"):
            arrays[name] = to_numpy(value)
        else:
            print(f"  skipping non-tensor entry: {name} ({type(value).__name__})")
    print(f"  {len(arrays)} tensors")

    print("folding weight-norm reparametrizations ...")
    arrays = fold_weight_norm(arrays)

    if args.layout == "mlx":
        print("applying MLX conv layout ...")
        arrays = apply_mlx_layout(arrays, args.convtranspose_regex)

    if args.dtype != "keep":
        target = np.dtype(args.dtype)
        arrays = {
            k: (v.astype(target) if np.issubdtype(v.dtype, np.floating) else v)
            for k, v in arrays.items()
        }

    print(f"saving {len(arrays)} tensors -> {args.output}")
    import torch
    from safetensors.torch import save_file

    tensors = {k: torch.from_numpy(np.ascontiguousarray(v)) for k, v in arrays.items()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_file(tensors, str(args.output), metadata={
        "source": str(args.input.name),
        "layout": args.layout,
        "converter": "gloam-voice-studio convert_weights.py",
    })

    if args.manifest is not None:
        manifest = {
            k: {"shape": list(v.shape), "dtype": str(v.dtype)}
            for k, v in sorted(arrays.items())
        }
        args.manifest.write_text(json.dumps(manifest, indent=1))
        print(f"wrote manifest -> {args.manifest}")

    total_bytes = sum(v.nbytes for v in arrays.values())
    print(f"done: {total_bytes / 1e6:.1f} MB of tensor data")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
