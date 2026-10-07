# Qwen3-TTS 1.7B on the Neural Engine (`qwen3-1.7b-ane`)

Measured 2026-10-06 on the M5 Mac (32 GB, macOS 26.6), coremltools 9.0. Conversion tooling and raw results:
qwen-onnx-cpu branch `feat/qwen-1-7b-ane` (`tools/cm_build.py`, `gate17.py`, `ab3.py`, `ship17.py`; `out/q17/ab3/report.json`).

## What it is

The 0.6B runtime (QwenANE) with the size read from the model set. Source weights: the MLX 1.7B Base 8-bit that Studio's
MLX engine runs. Talker = four 7-layer Core ML chunks (decode T=1 + prefill T=64 multifunction, shared KV state, a compensated
fp16 residual handed chunk to chunk), per-output-channel int8 weights. Code predictor = one call per frame, 15 unrolled
greedy steps, int8. Vocoder, vocoder head, speech encoder: the 0.6B set's files (same speech tokenizer).

| | 0.6B (shipping) | 1.7B |
|---|---|---|
| talker width / MLP | 1024 / 3072 | 2048 / 6144 |
| talker chunks | 2 x 14 layers | 4 x 7 layers |
| code predictor | 1024-wide, 5 layers | same, plus small_to_mtp_projection (2048 to 1024) applied on the host |
| x-vector | 1024 | 2048 (own speaker encoder, cosine 1.0000 vs MLX) |
| talker weights | fp16 (dequantised MLX 4-bit) | int8 per channel, layer 2 fp16 |
| code predictor weights | fp16 | int8 |
| set on disk | 2.07 GB | 2.8 GB (coreml 2.1, host 0.65, vochead 0.08) |

## Conversion recipe (what mattered)

* fp16 does not overflow at 1.7B. The residual stream peaks near 5.8k (one massive-activation row made by layer 2), far
  inside fp16's 65504; the LayerNorm-trick RMSNorm and TwoSum-compensated residual of the 0.6B graphs are enough. fp16 talker
  g0 logits: relative rms 0.0018 against the fp32 reference.
* fp16 is too slow (talker 107 ms/frame), so int8 per-channel symmetric (`constexpr_blockwise_shift_scale` with one scale per
  row): talker 36 ms/frame. Everything int8 is wrong (g0 agreement 1%): layer 2, the layer that creates the massive-activation
  row, must stay fp16 (+48 MB). With it: g0 1% error budget of the fp32 reference (below).
* Other representations measured on a 7-layer decode chunk: fp16 28.5 ms, int8 per channel 9.3 ms (100% ANE), 256-entry
  per-row palettisation 16.8 ms (100% ANE), int8 per 64-block 14.5 ms with half the ops on the CPU. Per-channel int8 it is.
* The code predictor does not load on the ANE with the projection inside the graph (Core ML error -6), so the host applies it:
  `cp_in_proj_w/b` (fp32) to the talker's hidden state and to codec[g0], in the Swift engine and in the Python tools alike.
  (The first failure was a slice end hard-coded to the talker width; the host projection kept the graph identical to 0.6B's.)
* Chunking: 28 layers in one ANE program do not compile (as at 0.6B); 7-layer chunks, 4 per frame.

## Quality gate (same gates as 0.6B)

Teacher-forced against the fp32 MLX reference (`tools/mlxeng.py`, validated against mlx_audio: logits rel rms 0.0011), 305 frames
over jeff, benson, cruz, same history on both sides:

| build | g0 argmax | g0 logit rel rms | code-predictor sub-codes |
|---|---|---|---|
| 0.6B ANE fp16 (shipping) | 290/291 (99.66%) | 0.002-0.003 | 97.6% |
| 1.7B fp16 talker + fp16 cp (reference build, 143 ms/frame) | 305/305 | 0.002 | 98.2% |
| **1.7B int8 talker + int8 cp (shipped)** | 303/305 (99.3%) | 0.010 | 94.2% |
| 1.7B int8 talker + fp16 cp | 303/305 | 0.010 | 96.8% |

The two g0 misses are near ties (reference top-2 margins 0.84 and 0.06).

## Is it better than before? Same 10 lines (jeff/benson/cruz x short/medium/long + one Spanish line on benson's es reference), same seeds

Whisper large-v3-turbo-q4 word errors (script vs transcript, 375 words; the Spanish line's 3 errors are "12" for "doce" and an
accent, identical in all three), speaker cosine to the reference voice (1.7B speaker encoder as the common yardstick), leading
silence max.

| | 0.6B ANE (shipping) | 1.7B MLX (Studio's) | 1.7B ANE int8 cp | 1.7B ANE fp16 cp |
|---|---|---|---|---|
| word errors | 6 | 7 | 6 | 7 |
| speaker cosine, mean | 0.9904 | 0.9898 | 0.9915 | 0.9920 |
| max leading silence | 0.66 s | 0.50 s | 0.72 s | 0.58 s |
| RTF, Python A/B harness, same session, Mac loaded (load avg 45-100) | 0.88 | 0.98 (python mlx_audio) | 0.85 | 1.06 |
| RTF, Swift engine, quiet Mac (load 8-16), warm voice, release | 0.76-0.79 | not measured in Swift | 0.68-0.74 | not built |

By these measures it is not worse than either: error rates are equal, similarity slightly higher. Speaker cosine and word errors
saturate for all of them, so the real answer is by ear: out/q17/ab3/listen.html (blind, random labels) and key.html.
Per-line numbers: `qwen-onnx-cpu/out/q17/ab3/report.json`.

Speed: the Mac's ANE renders 1.7B (int8/int8) at about the same real-time factor as the 0.6B build, because the 0.6B's fp16 code
predictor is the slow part (35 ms against 19 ms int8). Per frame on the ANE (quiet): talker 36 ms, code predictor 19 ms, vocoder 3 ms,
prefill 0.32 s for a 282-row prompt.

## Studio

`qwen3-1.7b-ane` appears next to `qwen3-0.6b-ane` in the Studio picker, chat voice and the API (same lane, streaming, talk sessions,
warm-up, line splitting, runaway cap, trailing-silence and dead-air rules: the code is shared, QwenANESpeechModel is parameterised
by backend). Install: the model manager downloads `tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE` (about 2.9 GB) into
`<Application Support>/GloamVoiceStudio/Models/qwen3-1.7b-ane`, or point `GLOAM_QWEN_ANE_17B_MODELS` /
the `qwenANE17BModelsPath` default at a set. The repo is not published yet: build the set with qwen-onnx-cpu `tools/ship17.py OUT int8 int8`
and upload `OUT` (`hf upload tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE OUT .`).

Voices: the 1.7B build reads and writes `engines/qwen3-1.7b/` (its own section chosen once at prep time, its own 2048-wide
x-vector; codes are identical to 0.6B's because the speech tokenizer is shared). It is prepared at a voice's first render, not at
import, and travels in exports like the 0.6B folder.

## Tests

`scripts/test-qwen-ane-sizes.sh` runs the QwenANE suite once per installed set. Quick run, 2026-10-06: 0.6B set 89 tests, 21 skipped (slow or
other size), 0 failures; 1.7B set 98 tests, 22 skipped, 0 failures. New: QwenSizeTests (config, kinds, prep cache, host maths against Python
fixtures for the 8-bit text table and the cp projection), QwenANEBackendTests (backend, sets, planner). EngineKit/GVoiceKit/StudioKit suites: 0 failures.

## Not verified

* The Studio app target (xcodebuild) was not built: disk fell under the floor. App/ edits are switch cases, a model-size entry and
  the pre-warm helper; `swift build` of every package target is clean.
* The HF repo `tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE` is unpublished, so the in-app download is untested end to end (the layout code is the 0.6B path).
* Blind listening (David's ear) and MLX 1.7B speed inside Studio itself.
* Eager prep of `engines/qwen3-1.7b/` at voice import and the iOS app (see below).

## iPhone

Not measured. The code predictor and talker are bandwidth-bound on the ANE: the 0.6B build measured 60 ms/frame on this Mac and was projected at
108-180 ms/frame on an A17 Pro (3.4 GB of fp16 weights per frame); the 1.7B int8/int8 build moves roughly 1.4 GB of talker weights plus
0.16 GB x 15 code-predictor passes per frame (about 3.8 GB), so expect the same order, RTF above 1 on a 15 Pro and no streaming. Memory:
the ANE holds about 2.1 GB of compiled weights. iPhone Studio would need the same QwenANE sources (size-config is already in), a
4-chunk set in the tier installer (`scripts/fetch-qwen-ane-ios.sh` fetches the 0.6B set), and an on-device RTF measurement before offering it.
