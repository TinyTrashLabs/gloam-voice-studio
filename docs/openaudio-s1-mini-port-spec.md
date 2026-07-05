# Port Spec — On-device emotional TTS via OpenAudio S1-mini (for Fable 5)

- **Date:** 2026-07-04
- **Goal:** Make emotion actually work on-device by porting **OpenAudio S1-mini** (the
  open, emotion-*proven* Fish model) into the vendored `TinyTrashLabs/mlx-audio-swift`
  fork, matching `fishaudio/fish-speech`'s official inference — so that literal emotion
  markers in the input text (`(angry)`, `(whisper)`, …) produce genuinely distinct
  emotional speech, including while voice-cloning from a reference clip.
- **Executor:** Fable 5, working in `mlx-audio-swift` (fork) + this app.
- **Distribution:** the S1-mini weights are **downloaded on demand** with a **license
  acknowledgment**, exactly like the current Fish model — **not bundled**. Gloam stays
  free & open-source; App Store distribution is only for reach.

---

## 0. Why the current setup can't produce emotion (established, do not re-litigate)

Proven this session by measuring the actual baked clips:

- `mlx-community/fish-audio-s2-pro` is **`fish_qwen3_omni`** (a Qwen3-based model, likely
  an unofficial/partial port of Fish's **cloud-only** S2). Its emotion markers are **dead**:
  `ogre-angry`, `ogre-delight`, `ogre-sad` came out the **same duration and same RMS energy
  as the neutral base** (`ogre-excited` at 34 s was a separate runaway-generation bug).
- Both live emotion levers are dead here: the intensity knobs (Chatterbox `exaggeration`,
  Fish `temperature`) are overpowered by the cloned reference's prosody (this repo's own
  `VoiceLibrary.swift` comment: *"Cloned reference audio dominates prosody…"*), **and** the
  `[marker]` text is ignored by the S2/Qwen3 port.
- **Root cause of the marker failure:** the official `fish_speech/tokenizer.py` defines **no
  emotion tokens**. Markers like `(angry)` are **literal text the model was trained to
  interpret** — so the fix is *the right emotion-trained weights + the right input format*,
  **not** tokenization. The S2/Qwen3 weights we have don't carry that training.

**Conclusion:** target the officially-open, emotion-trained **OpenAudio S1-mini**
(`DualARTransformer`, LLaMA-style), reimplemented to match fish-speech's inference exactly.

---

## 1. Reference implementation (read these first)

Repo: `github.com/fishaudio/fish-speech` (the OpenAudio S1 codebase). Key files:

| File | What to extract |
|---|---|
| `fish_speech/tokenizer.py` | `FishTokenizer`; control tokens: `<|im_start|>`, `<|im_end|>`, `<|text|>`, `<|voice|>`, `<|interleave|>`, `<|audio_start/end/pad|>`, `<|semantic:{i}|>` (i=0..4095), `<|endoftext|>`, `<|pad|>`, `<|speaker:{x}|>`. Backend = HF `AutoTokenizer` (tiktoken/BPE), `allowed_special="all"`. **No emotion tokens — markers are plain text.** |
| `fish_speech/content_sequence.py` | `ContentSequence` / `encode_for_inference()` — assembles text + reference-audio codes into the `[num_codebooks+1, seq_len]` tensor. Row 0 = token IDs; rows 1..N = codebook codes. |
| `fish_speech/models/text2semantic/llama.py` | `DualARTransformer` (slow backbone + `n_fast_layer` fast/depth transformer), `BaseModelArgs`, `embed()` (vocab emb + Σ masked codebook embs), `forward_generate`, `forward_generate_fast`. RoPE + GQA (`n_local_heads`) + optional QK-norm. |
| `fish_speech/models/text2semantic/inference.py` | `decode_one_token_ar`: slow samples the semantic token (biased to `semantic_begin_id..semantic_end_id`), then the fast transformer autoregressively samples the `num_codebooks` codes for that frame; **Repetition-Aware Sampling (RAS)** with high-temp fallback; stop when semantic token == `im_end_id`. |
| DAC codec (`codec.from_indices`, `encode_audio`) | Encode the reference clip → codes; decode generated codes → mono waveform at the codec sample rate. |

**Config note:** the numbers in `BaseModelArgs` (dim 4096 / 32 layers) are the *large* S1.
**S1-mini is 0.5B** — take exact `dim`, `n_layer`, `n_head`, `head_dim`, `n_local_heads`,
`n_fast_layer`, `num_codebooks`, `codebook_size`, `vocab_size`, `rope_base` from
**S1-mini's own `config.json`**. Same for the codec's `num_codebooks`/sample rate.

---

## 2. Reuse what the fork already has

The fork's current Fish (S2/Qwen3) implementation has scaffolding worth reusing:

- **`FishS1DAC`** (S1 DAC codec) — likely reusable for encode/decode; verify it matches
  S1-mini's codec config.
- **`FishSpeechTokenizer`** — adapt to S1-mini's tokenizer (control tokens above).
- **Reference-audio → codec-code** path — verify/adapt.
- **`FishSpeechPrompt`** — **realign** to fish-speech's `ContentSequence` (see §4); the
  current `<|im_start|>role\n<|modality|>` shape likely differs from what S1 expects.

**New work:** the `DualARTransformer` (slow+fast) architecture (the fork's `FishSpeechModel`
is Qwen3-omni — a different model), the dual-AR generate loop with RAS, and weight mapping.

---

## 3. Model to implement — `DualARTransformer` (S1-mini)

- **Slow transformer:** `n_layer` decoder blocks (RoPE, GQA via `n_local_heads`, optional
  QK-norm, SwiGLU MLP). Input embedding = `embed()`: token embedding (row 0) **plus** the
  sum of per-codebook embeddings (rows 1..N), masked so codebook embeddings only apply to
  audio positions. Produces `token_logits` (over the semantic/text vocab).
- **Fast/depth transformer:** `n_fast_layer` blocks. For each generated frame, conditions on
  the slow hidden state + previously-sampled codebook codes to produce `codebook_logits`
  per codebook, sampled sequentially (codebook 1 → `num_codebooks`).
- **KV-cache** for both stacks (`forward_generate`, `forward_generate_fast`).

Match names/shapes to the HF checkpoint so weight loading is a direct mapping. Validate by
comparing Swift `token_logits`/`codebook_logits` to the Python reference on a **fixed input**
(numerical golden test) before touching the generate loop.

---

## 4. Input sequence (where emotion lives)

Emotion markers are **plain text inside the user text** — put them at the **start of the
sentence** (S1 uses **parentheses**: `(angry) <line>`; NOT S2 brackets). Assemble exactly
like fish-speech:

```
system:  "convert the provided text to speech reference to the following:\n\nText:\n{refText}\n\nSpeech:\n{VQ codes of reference clip}"
user:    <|speaker:0|> TextPart("(angry) " + line)      # marker is literal text
assistant: <empty — model fills with semantic+codebook codes>
```

- Reference clip → `encode_audio()` (DAC) → `VQPart` codes appended after "Speech:\n".
- Build the `[num_codebooks+1, seq_len]` tensor: text tokens on row 0 (codebook rows 0 there),
  VQ codes on rows 1..N at the audio positions.
- **Do NOT** invent emotion special tokens or a marker parser — the model reads the literal
  characters.

---

## 5. Generate loop (`decode_one_token_ar`)

1. Prefill the prompt through the slow transformer (KV-cache).
2. Per frame: slow forward → sample semantic token (logits biased so only
   `semantic_begin_id..semantic_end_id` are valid); then fast transformer autoregressively
   samples `num_codebooks` codes conditioned on prior codebooks.
3. Sampling: `temperature≈0.7–1.0`, `top_p≈0.9`, `top_k≈30`, **RAS** (repetition-aware:
   detect repeats, resample at `RAS_HIGH_TEMP=1.0`/`RAS_HIGH_TOP_P=0.9`). RAS matters — it's
   what prevents the runaway 30s+ generations we already saw.
4. Stop when the semantic token == `im_end_id`.
5. Stack codes → `codec.from_indices(codes)` → mono waveform at codec SR.

---

## 6. App integration (Gloam)

- **New backend id** `openaudio-s1` (or repurpose the Fish slot). Add to `BackendID`,
  `BackendSpec` (`needsLicenseAck: true`, `needsRefAudio: false` — S1 has stock voices too),
  `ControlSurface` (voiceClone `.optional`, emotion = *inline markers* via the existing
  `TagChipsView`, no live-knob emotion → `.none` or a real `.liveKnob` only if a knob exists).
- **Download manager** entry (repo `fishaudio/openaudio-s1-mini` or an MLX-converted mirror);
  **license ack** sheet reusing the Fish-license flow. **Not bundled.**
- **Bake path:** switch `bakeExpressionVariants` to render through `openaudio-s1` with the
  marker in the text (`(angry) <line>`). Drop the dead Fish-S2/Chatterbox emotion paths for
  variants (keep Chatterbox intensity only as a labeled "weak" fallback, or remove).
- **Studio:** `openaudio-s1` becomes the recommended emotional/clone model; its `TagChipsView`
  markers now actually work.
- **API:** the `emotion`→variant resolution already added still applies (variants are clips);
  additionally, a base-voice request with `emotion` could inject the marker for S1 live.

---

## 7. Phased plan (each phase independently verifiable)

- **Phase 0 — Prove the premise (before any Swift).** In official Python `fish-speech` with
  S1-mini: clone a reference clip and generate `(angry) <line>` vs `(whisper) <line>`.
  Confirm they're audibly + measurably distinct (RMS/energy). **Dump the exact input token
  IDs + a few decode steps** — this is the golden reference for the Swift port. If emotion
  does NOT survive cloning even in Python, STOP and reconsider (but the S1 demos say it does).
- **Phase 1 — Weights + tokenizer.** Convert S1-mini safetensors → MLX; port/adapt the
  tokenizer; unit-test that a known string tokenizes to the Python IDs.
- **Phase 2 — Model forward.** Implement `DualARTransformer`; golden-test `token_logits` /
  `codebook_logits` vs Python on the fixed input from Phase 0.
- **Phase 3 — Generate + codec.** Dual-AR loop + RAS + stop; `codec.from_indices` → wav.
  Compare a full generation's codes/energy envelope to Python (allowing sampling variance).
- **Phase 4 — Cloning + emotion.** Reference-clip encode + marker text → verify
  `(angry)` vs `(whisper)` are distinct (energy + ear). This is the acceptance test.
- **Phase 5 — App wiring.** Backend, download, license, bake/studio/API integration; re-pin
  the fork in `Package.swift`; rebuild via the `run-app` skill and verify end-to-end.

---

## 8. Acceptance criteria

1. Golden numerical match: Swift `DualARTransformer` logits ≈ Python on a fixed input.
2. **Emotion is real:** for one cloned voice, `(angry)` and `(whisper)` variants differ
   clearly in energy/prosody (not the identical-RMS result we measured with S2).
3. No runaway generations (RAS working).
4. Weights download on demand behind a license ack; nothing bundled.

## 9. Gotchas

- **S1 syntax = `(parentheses)`**, S2 = `[brackets]`. Use parentheses for S1-mini.
- Markers are **literal text** — never add them to the vocab or write a parser.
- Take all dims/codebook counts from **S1-mini's config.json**, not the large-S1 defaults.
- **RAS is mandatory** for stable length (the 34 s glitch was runaway sampling).
- The current fork Fish (`fish_qwen3_omni`) is a **different architecture** — this is a new
  model class, though the S1 DAC codec + tokenizer scaffolding likely transfer.
- License: S1-mini is CC-BY-NC-SA-4.0 — fine here because it's user-downloaded with an ack
  and the app is free/open-source, mirroring the existing Fish flow.

---

## 10. Sources

- fish-speech (official): https://github.com/fishaudio/fish-speech
- Speech-control internals (DeepWiki): https://deepwiki.com/fishaudio/fish-speech/6.3-speech-control-features
- OpenAudio S1-mini weights: https://huggingface.co/fishaudio/openaudio-s1-mini
- Fish emotion docs: https://docs.fish.audio/developer-guide/core-features/emotions
