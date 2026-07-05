# Phase 0 — RESULTS (2026-07-04)

Ran the go/no-go in official `fish-speech` **v2.0.0** reference inference on macOS (Apple
Silicon, 32GB, MPS/bf16). Same Ogre reference clip, same line, **fixed seed 1234**, only the
leading `(emotion)` marker changes. Measured with `measure_audio.py` (distinctness verdict).
Every result was independently re-measured; determinism controls passed (base regenerates
bit-identical).

## Verdicts

| Model | Size / arch | Emotion **while cloning** | Emotion on **stock** voice |
|---|---|---|---|
| **OpenAudio S1-mini** | 0.5B `dual_ar` (DualARTransformer) | ❌ **NO-GO** (3–4/10 distinct) | ✅ **GO** (10/10) |
| **S2-Pro** | 4B `fish_qwen3_omni` (→ DualAR loader) | ✅ **GO** (9/10 distinct) | (not run) |

## The three findings that matter

1. **The premise is alive.** Emotion markers genuinely work in Fish's open weights — in *both*
   architectures. `(angry)`/`(whisper)`/… are literal text (parentheses, sentence-start),
   consumed as control (STT confirms they're never spoken). The app's "dead emotion" is a
   weights/driver problem, not "Fish can't emote."

2. **S2-Pro emotes *while cloning* (9/10).** whisper = quietest + breathiest (crest 9.22) +
   brightest; excited = fastest (highest ZCR); sad = darkest centroid. Only base-vs-angry was
   below threshold. It clones the reference AND applies emotion — out of the box.

3. **S1-mini emotes hard, but only on its *stock* voice.** Stock: 10/10 distinct, huge swings
   (RMS 25–81%), whisper textbook-correct (quieter/breathier/darker than base). Cloning the
   Ogre flattens all of it (≤20% swings). **The cloned reference's prosody overrides the
   markers.** Direction on stock is mostly sensible (whisper best; angry reads dark/seething
   not loud; excited weakest) — needs an ears check for per-label correctness.

## The practical kicker

S2-Pro is the **same architecture already shipping in the app** (`mlx-community/fish-audio-
s2-pro-bf16` = a 4B `fish_qwen3_omni`, already on-device, already clones). Reference S2-Pro
emotes; the app's copy is emotion-dead. So the gap is almost certainly **how the app drives
it** (marker syntax/placement, prompt wrapping) or a lossy MLX conversion — **not** a missing
model. Potentially a much cheaper fix than any port. (Also dissolves the "4B can't run on-
device" worry — the app already runs it on 32GB.)

## Model measurements (RMS / centroid), for reference

S2-Pro cloning:  base 3464/2621 · angry 3203/2693 · whisper **2306**/3037 · sad 4622/2309 · excited 3964/2590
S1-mini cloning: base 4785/2510 · angry 5762/2272 · whisper 5118/2472 · sad 5190/2549 · excited 4793/2523  (cramped)
S1-mini stock:   base **6191**/2943 · angry 2632/1947 · whisper 4282/1756 · sad 3537/2200 · excited 3374/1900  (wide)

## Reproduce (from `openaudio-phase0-work/fish-speech`)

- S2-Pro CLI (built-in `--seed`): `text2semantic/inference.py --text "(angry) <line>"
  --prompt-text "<ref transcript>" --prompt-tokens <ref codes.npy> --checkpoint-path
  checkpoints/s2-pro --device mps --seed 1234 --temperature 0.8 --top-p 0.8`, then decode
  codes via `models/dac/inference.py ... --checkpoint-path checkpoints/s2-pro/codec.pth`.
- S1-mini needed a tokenizer patch (checkpoint ships tiktoken; v2.0.0 loader expects HF) +
  the S1 reference-free / reference prompt form — driver scripts in the work scratchpad.

## Artifacts (in `openaudio-phase0-work/`)

- `out-s2pro/{base,angry,whisper,sad,excited}.wav` — S2-Pro cloning (GO)
- `out-s1mini/{...}.wav` + `golden_angry_tokens.json` — S1-mini cloning (NO-GO) + golden dump
- `out-s1mini-stock/{...}.wav` — S1-mini stock (GO)

## Follow-up: emotion transfers through cloning (emotional-reference architecture — GO)

Cloning a Fish-minted **whispered** Ogre reference, with **no marker**, on a new line →
**−27% RMS, +23% centroid, +25% ZCR** vs cloning the neutral reference (determinism: bit-
identical repeat). So the flip side of "cloning suppresses added markers" holds: an *emotional
reference* carries its emotion into new text. **Any clone model (qwen/chatterbox) can inherit
emotion by cloning Fish-minted emotional reference clips** — validating the bake-variant path
(once the text≠refText bug is fixed). Caveat: crest didn't move, n=1, ears check advised.
Clips: `out-transfer/{neutral_ref,whisper_ref}.wav`.

## Next-step options

- **A. Cheap win:** diagnose why the app's existing S2-Pro is emotion-dead vs. reference
  (marker syntax/prompt format / MLX conversion). If a driver bug → emotion ships, no port.
- **B. Two-tier:** S1-mini for fast stock/preset emotional voices everywhere; S2-Pro for
  emotional voice-cloning. One shared DualAR port covers both.
- **C. Fix S1-mini cloning:** engineer lighter/prosody-neutral reference conditioning so
  S1-mini emotion survives cloning (unproven R&D).

Recommendation: **A first** — highest leverage, lowest cost; the app may already contain a
working emotion model that's just driven wrong.
