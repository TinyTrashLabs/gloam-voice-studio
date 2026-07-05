# Phase 0 — Prove OpenAudio S1-mini emotion survives voice cloning (session kickoff)

**Read this cold — it's self-contained.** You are starting Phase 0 of a plan to bring
*genuinely distinct emotional TTS* to Gloam Voice Studio (a free, open-source, on-device
macOS voice app). Do **not** write any Swift yet. Phase 0 is a go/no-go experiment in
**Python**, using the official `fishaudio/fish-speech` inference with the **OpenAudio
S1-mini** model. Its two jobs:

1. **De-risk the whole port:** confirm that S1-mini applies emotion markers like
   `(angry)` / `(whisper)` **while cloning a reference voice** (not just with its stock
   voice). If it doesn't, we stop before sinking effort into a Swift port.
2. **Produce the golden reference** (exact input token IDs) the later Swift port validates
   against.

Full context + the downstream plan: **`../openaudio-s1-mini-port-spec.md`** (read it).

---

## Why we're here (the short version)

Gloam bakes "emotion variants" of a voice by cloning a base clip through a TTS model. We
proved this session that it produces **identical** takes on the current model:

- The app's Fish model, `mlx-community/fish-audio-s2-pro`, is actually **`fish_qwen3_omni`**
  (a Qwen3 model, likely an unofficial port of Fish's cloud-only S2). Measured: `angry`,
  `sad`, `delight` variants came out **same duration + same RMS energy as the neutral base**.
- Root cause: the official fish tokenizer has **no emotion tokens** — `(angry)` is **plain
  text the model was *trained* to interpret**. Our S2/Qwen3 weights don't carry that
  training, so the marker is ignored. (Both intensity knobs are dead too — the cloned
  reference's prosody dominates.)
- The officially-open, emotion-**trained** model is **OpenAudio S1-mini** (`DualARTransformer`,
  LLaMA-style, 0.5B, CC-BY-NC-SA — fine for us: user-downloaded with a license ack, app is
  free/open-source). That's what Phase 0 tests, and what the port targets.

---

## Environment setup

Work in a fresh directory (NOT the gloam repo — this is Python/fish-speech).

```bash
git clone https://github.com/fishaudio/fish-speech
cd fish-speech
# Follow their README exactly for your platform (macOS/CUDA). Typically:
python -m venv .venv && source .venv/bin/activate
pip install -e .            # or per their current install docs
pip install ormsgpack requests numpy
# Download the model (per fish-speech README — huggingface-cli or their script):
huggingface-cli download fishaudio/openaudio-s1-mini --local-dir checkpoints/openaudio-s1-mini
```

Confirm plain (non-emotional) cloning works first, following the fish-speech README's
inference example. Only proceed once you can clone a voice at all.

---

## Run the experiment

Copy this whole `openaudio-phase0/` folder next to your fish-speech checkout. It contains
`reference.wav` (a real Gloam voice clip) + `reference.txt` (its transcript) to clone.

**Option A — HTTP API (scripted).** Start fish-speech's API server (adjust paths/flags to
the current repo):

```bash
python -m tools.api_server \
  --llama-checkpoint-path checkpoints/openaudio-s1-mini \
  --decoder-checkpoint-path checkpoints/openaudio-s1-mini/codec.pth \
  --listen 127.0.0.1:8080
# then, in the phase0 folder:
python run_s1_emotion_test.py
```

`run_s1_emotion_test.py` generates the same line from `reference.wav` with a **fixed seed**,
varying only the leading marker (`base`, `(angry)`, `(whisper)`, `(sad)`, `(excited)`), then
runs the measurement automatically. **Fixed seed is essential** — it means any difference is
the *marker*, not random sampling.

**Option B — manual (WebUI/CLI).** If the API schema fights you, use fish-speech's WebUI or
CLI to generate the same 5 clips by hand (same reference, same text, same seed if exposed,
only the leading marker changes). Save them as `out/base.wav`, `out/angry.wav`, etc., then:

```bash
python measure_audio.py out/base.wav out/angry.wav out/whisper.wav out/sad.wav out/excited.wav
```

---

## Read the result (go/no-go)

`measure_audio.py` prints per-clip acoustics (duration, RMS energy, crest, zero-crossing
rate, spectral centroid) and a pairwise distinctness verdict.

- **GO** — `(angry)` vs `(whisper)` (etc.) differ clearly (energy/brightness/pace). Emotion
  markers work *with cloning*. **Also listen** — ears are the real test. Proceed to the
  golden dump, then start the Swift port (spec Phase 1+).
- **NO-GO** — the clips are ~identical (same failure as the S2 port). Emotion does not
  survive cloning even in official Python. **Stop.** Report back: either markers need the
  model's *stock* voice (no reference), or the feature isn't achievable — a big finding that
  changes the whole plan. Don't start the Swift port on a NO-GO.

---

## Golden reference (only if GO)

The Swift port (spec Phase 2) must reproduce the exact tokenization + model input. Capture it:

1. In fish-speech, find where the prompt is assembled into token IDs (the tokenizer +
   `content_sequence.py` / the inference entrypoint). Add a dump right before the model
   forward: the full input tensor `[num_codebooks+1, seq_len]` — row 0 (token IDs) and the
   reference-audio codebook rows — plus the decoded token strings.
2. Do it for the exact `reference.wav` + `reference.txt` + `"(angry) " + LINE` used above.
3. Save as `golden/angry_input_tokens.json` (token IDs, shapes, the special-token layout).
   Also save the model's `config.json` (dims/codebooks/vocab) and the first few generated
   frames' logits if feasible — the Swift model forward is validated numerically against these.

---

## Files here

| file | purpose |
|---|---|
| `README.md` | this kickoff |
| `../openaudio-s1-mini-port-spec.md` | the full port spec (context + Phases 1–5) |
| `reference.wav` / `reference.txt` | a real Gloam voice clip + transcript to clone |
| `run_s1_emotion_test.py` | scripted harness (fixed-seed, 5 markers) → measurement |
| `measure_audio.py` | the go/no-go instrument (distinctness verdict) |
| `out/`, `golden/` | you create these (generated clips, golden token dump) |

## Crib sheet (don't re-derive)

- S1 marker syntax = **`(parentheses)`** at the **sentence start** (S2 uses `[brackets]`).
- Markers are **literal text**, not special tokens — never add them to the vocab.
- Model = **OpenAudio S1-mini**, `DualARTransformer` (slow semantic backbone + fast codebook
  transformer), RoPE + GQA. Codes → waveform via the DAC codec (`codec.from_indices`).
- **Fix the seed** across the 5 clips so differences are the marker, not sampling.
- Repetition-Aware Sampling (RAS) matters downstream — a runaway once gave us a 34 s clip.
- The gloam app's fork already has an S1 DAC codec + a Fish tokenizer that likely transfer
  to the Swift port later; Phase 0 is pure Python and doesn't touch them.
