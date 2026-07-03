# Regular Chatterbox quality — status

Status as of 2026-07-02 (evening session): root cause of the remaining
"choppy and awful" quality identified and fixed. All fixes are now durable —
committed to `TinyTrashLabs/mlx-audio-swift` on branch
`fix/chatterbox-regular-quality` (PR #1,
https://github.com/TinyTrashLabs/mlx-audio-swift/pull/1) and
`Package.swift` here is pinned to that commit
(`e7de83ad707733c53a2a0019269f23e1b086ba4f`). Nothing lives only in
scratchpad or DerivedData anymore.

## Root cause of the remaining defect

The `mlx-community_Chatterbox-TTS-fp16` checkpoint conversion **dropped all
56 trained `attn1.to_out.0.bias` vectors** from the S3Gen flow estimator
(4 down-block + 48 mid-block + 4 up-block attention layers). A full
key/shape/value diff against the original `ResembleAI/chatterbox`
`s3gen.safetensors` proved these are the *only* trained weights lost in the
conversion — every shared tensor is bit-exact, weight-norm fusion included.
The Turbo conversion kept its biases, which is why only Regular sounded bad.

The biases are not small (mean |bias| ≈ 0.017 vs mean |weight| ≈ 0.027,
max 0.19) and act in every attention block at every one of 32 ODE steps in
both CFG branches. The previous session's `bias: false` stopgap removed the
random-noise injection but ran the model without 56 trained vectors — and
would also have silently broken Turbo, whose checkpoint ships real biases.

**Fix:** the trained bias values (65 KB) are bundled into mlx-audio-swift as
a package resource (`chatterbox_s3gen_attn_out_biases.safetensors`,
extracted from the original ResembleAI torch checkpoint) and merged at load
time only when the checkpoint doesn't provide the keys. `to_out` is back to
`bias: true`. A future corrected upstream checkpoint wins automatically.

## Additional real bugs found and fixed in the same pass

- **CAMPPlus `TransitLayer` bias** — Swift used `bias: true` where Python
  passes `bias=False`; 3 random-init bias vectors were polluting the speaker
  x-vector (affected Regular *and* Turbo).
- **CAMPPlus `CAMLayer.bn1/bn2`** — batch norms that don't exist in the
  Python reference (near-identity at init, but removed for parity).

Plus the two fixes carried over from the previous session (verified still
present): T3 CFG uncond position-embedding ordering, and `[SPACE]`
tokenization for the Regular EnTokenizer.

## Guardrail against recurrence

`CHATTERBOX_DEBUG_LOAD=1 spike ...` prints every model parameter that
received no checkpoint value (i.e. kept random init) and every checkpoint
key that matched no parameter. Post-fix, the only unloaded entries are
computed buffers (`posEnc.pe`, `stftWindow`, `randNoise`, Turbo-only
`time_embed_mixer`) and the affine=False batchnorm identity pair — all
expected. If a future model/checkpoint change reintroduces a silent gap,
this will show it immediately.

## Verified

- `swift build --product spike` against the pinned revision; generation runs
  clean (`[T3-LLaMA] EOS` fires at sane step counts, loader prints
  "Restored 56 attn out-proj biases").
- Sample outputs for David's ear: `allfix-david.wav`, `allfix-ava.wav`
  (sent 2026-07-02; real voices from the app's Voices dir).

## Resolution

David confirmed the fixed samples sound good (2026-07-02). PR #1 merged to
main (`b85e444`); `Package.swift` and `Package.resolved` here are pinned to
that merge commit. This issue is closed.

Nice-to-have follow-up: report the dropped-bias conversion bug to
mlx-community so the `Chatterbox-TTS-fp16` checkpoint itself gets fixed
(the sidecar merge automatically defers to a corrected checkpoint).

---

# Round 2 (2026-07-02 → 07-03 overnight): "slurred/drunk + hiss" vs PyTorch reference

Blind paired ABX vs the PyTorch reference (`chatterbox-tts` pip, CPU/fp32,
identical params: temp 0.8, cfg 0.5, exaggeration 0.5, min-p 0.05, rep 1.2)
scored **8/8 for the reference** — the Swift port was audibly worse even after
the round-1 bias fix. Stage-isolation transplants (tokens → mel → conditioning
→ vocoder internals, via env-gated debug hooks now in the fork) found SIX bugs:

1. **RNG clobber** — `CausalConditionalCFM.init` called `MLXRandom.seed(0)`,
   making all downstream sampling deterministic per process (first take after
   every model load was always the identical performance). Fix: task-local
   `RandomState(seed: 0)` via `withRandomState` for the legacy rand_noise
   buffer. (Also seeded MLX's RNG at `MLXModelProvider.init` in this repo —
   MLX's global default seed is fixed.)
2. **Missing `model.train(false)`** — Chatterbox was the only model in the
   package not switched to inference mode. BatchNorm therefore normalized with
   per-batch statistics (CAMPPlus' final BN sees ONE pooled value per channel
   → exact-zero speaker x-vector) and Dropout randomly zeroed activations at
   inference. The dominant "drunk" cause together with:
3. **S3TokenizerV2 rotary bug** — freq exponents used `i/dim`; reference uses
   `arange(0, dim, 2)/dim` = `2i/dim`. Same input mel produced 58% different
   speech tokens (verified: reference tokenizer on identical mel now agrees
   99.0%). Corrupted both T3's style prompt and S3Gen's prompt conditioning.
4. **ODE steps** — the pre-round-1 "raise steps to 32" experiment was still in
   place; reverted to the reference's 10 (config.meanflow ? 8 : 10).
5. **s3gen prompt mel double padding** — `s3genMelSpectrogram` reflect-pads
   (nFft−hop)/2 = 720 AND the shared `stft()` center-padded another 960 →
   mel led the reference by exactly 2 frames. Added `center:` param to
   MLXAudioCore `stft` (default true), s3gen mel passes false. Prompt mel now
   corr 1.00000 at shift 0.
6. **The hiss** — HiFT decode's final activation before `conv_post` used
   slope 0.1 (the loop's `lrelu_slope`); Python's `F.leaky_relu(x)` there is
   the DEFAULT 0.01. This alone put +8 dB of broadband HF noise on every
   output ("bad mic" quality). Fix: slope 0.01 → Swift HF floor −21.2 dB,
   byte-for-byte even with the reference; decode corr 0.999986 on identical
   mel+source.

Exonerated after testing: fp16 weights AND fp16 compute (fp32 overlay of the
original ResembleAI s3gen weights, value-matched key remap, changed nothing
audible), kaldi fbank (bit-exact), 128-mel featurizer (corr 0.99999), CAMPPlus
network (cosine 1.0 on identical features — the earlier 0.638 pipeline cosine
is within the x-vector's natural jitter; same-file split halves only reach
0.74), Swift HiFT ISTFT, and T3 sampling (its tokens render cleanly through
the reference vocoder).

David's verdict on the final build: drunk quality gone, hiss gone, "still a
lot better". Formal re-ABX vs the reference not yet run.

## State on disk (continue here)

- All six fixes live in the fork clone
  `/private/tmp/claude-501/-Users-david-projects-gloam-voice-studio/d42aeba9-*/scratchpad/mlx-audio-swift-fork`
  on branch `fix/global-rng-clobber`. Commit `3166a4c` (RNG fix, signed) is
  pushed and open as TinyTrashLabs/mlx-audio-swift **PR #2**; fixes 2–6 plus
  the debug hooks are UNCOMMITTED working-tree changes in that clone.
- This repo's `Package.swift` has a TEMP local-path override pointing at that
  clone (marked with a TEMP comment) and an uncommitted `MLXRandom` product +
  seeding change in `Sources/EngineKit/MLXModelProvider.swift`. Must be
  repinned to the merged revision before committing.
- Python reference env + transplant harness (transplant.py, compare_*.py,
  blind-ABX shuffler with answer keys) in session scratchpad
  `/private/tmp/claude-501/-Users-david-projects-gloam-voice-studio/e25e7b83-*/scratchpad`.
- Listening artifacts in `~/Downloads/chatterbox-transplant/` (`hissfix_*` =
  final state) and `~/Downloads/chatterbox-abx*/`.

## TODO (next session)

1. Optional but recommended: one more blind paired ABX (reference vs fixed
   Swift) to confirm parity formally.
2. Commit fixes 2–6 as signed commits on `fix/global-rng-clobber` (atomic:
   eval-mode / rotary / stft-center / ode-steps / lrelu-slope / debug hooks),
   push, update PR #2 body, merge.
3. Repin this repo's Package.swift to the merge commit, drop the TEMP path
   override, commit EngineKit seeding + this doc via PR (main is protected).
4. Port all fixes to upstream Blaizzy/mlx-audio-swift PR #216 (S3Gen files
   live under `Sources/MLXAudioCodecs/S3Gen` there; same patches apply).
5. Decide whether to replace App Store build 0.1.0(3) (in review, contains
   round-1 fix only — Regular model still has bugs 1–6 there).
6. Known benign deltas left as-is: 3 appended silence tokens (reference
   appends none), 0.95 peak-normalize (port addition), legacy fixed rand_noise
   buffer (current reference uses fresh noise), resampler differences.

---

# Round 3 (2026-07-03): the residual "brighter/edgier" tell — root cause + fix

Formal blind ABX (round 2's leftover TODO #1) run at last: even with all six
round-2 fixes, David scored **8/8 for the PyTorch reference** — a real,
systematic (not jitter) quality gap survived. Full stage isolation via the
env-gated debug hooks localized it precisely, and **two round-2 conclusions were
wrong:**

- **The S3Gen flow ESTIMATOR is correct**, not buggy. (An intermediate "corr
  0.55 estimator divergence" was a measurement artifact — `CHATTERBOX_DUMP_MEL`
  emits the *trimmed gen* mel while the reference solver returns the *full*
  output incl. the prompt region; comparing gen-vs-prompt gave 0.55. Aligned,
  and traced U-Net stage-by-stage, the two estimators agree at **corr 0.9999**.)
- **The x-vector gap was NOT "benign jitter."** It is deterministic, systematic,
  and the dominant cause of the tell.

## Root cause: the 16 kHz resampler's anti-aliasing rolloff

`ChatterboxModel.resampleAudio` (the private polyphase wrapper, *not*
`AudioUtils.resampleAudio`/AVAudioConverter) used a Kaiser window cutting at
Nyquist (rolloff 1.0). torchaudio's `Resample` cuts at rolloff 0.99 (7920 Hz)
with a Hann window, width 6. The difference: Swift's 16 kHz resample of the ref
clip carried **+14 dB excess energy at 7–8 kHz and ~8× above 6 kHz** (0–5 kHz
identical). CAMPPlus is extremely sensitive to this (same-file halves only reach
cos 0.74): the bright audio drove the speaker **x-vector to cos 0.637** (and +8%
norm) vs the reference. That bright speaker embedding conditions the flow
decoder → the generated mel is systematically brighter (hi−lo tilt −3.36 vs the
reference −4.31, ~2× the 4–8 kHz energy) → the edgy tell.

Swap tests attributed the ~0.95 dB tilt gap: **x-vector/resampler ~67%**, encoder
`mu` ~27% (also resampler-fed, via the S3Tokenizer prompt tokens on the same
16 kHz audio), fixed noise ~19%. Exonerated (verified equal to the reference):
T3 tokens, HiFT vocoder + f0/source path (Swift mel → ref HiFT ≡ Swift HiFT,
<0.05 dB), the fbank (corr 1.0), the CAMPPlus network (cos 1.0 on same fbank),
fp16 vs fp32 compute (bit-identical mel).

## Fix (fork branch `fix/global-rng-clobber`, uncommitted working tree)

1. **`MLXAudioCore/AudioUtils.swift`** — new `sincResampleAudio`, a windowed-sinc
   polyphase resampler matching `torchaudio.transforms.Resample` defaults
   exactly (Hann, `lowpass_filter_width=6`, `rolloff=0.99`).
2. **`ChatterboxModel.swift`** — the private `resampleAudio(fromSR:toSR:)`
   wrapper (24 k prompt mel + 16 k x-vector/tokenizer) now delegates to it.
3. **`S3Gen/FlowMatching.swift`** — regular-model CFM now draws fresh
   `MLXRandom.normal(mu.shape)` per call (matches the reference `torch.randn_like`;
   was a frozen seed-0 buffer). Dead `randNoise` buffer removed.
4. Debug hooks added: `CHATTERBOX_DUMP_CFMIN` (estimator inputs),
   `CHATTERBOX_DUMP_UNET` (per-stage U-Net activations).

**Objective validation (utterance A, david-ref):** 16 kHz audio corr 0.996 →
**1.00000**; >6 kHz energy ratio 8.14× → **1.00×**; speaker x-vector cos 0.637 →
**1.0000**; mel tilt −3.36 → **−4.18** (reference −4.31, remainder is fresh-noise
variance). `swift build --product spike` clean.

## TODO (next session)

1. **DONE — blind re-test passed.** New 8-pair ABX (reference vs fully-fixed
   Swift) at `~/Downloads/chatterbox-abx-final2/`: David 2026-07-03 — *"I can't
   tell a difference between any of them."* Parity confirmed by ear (was 8/8 for
   the reference before the fix). Issue resolved.
2. Then land: commit the round-2 + round-3 fixes as signed atomic commits on the
   fork, update PR #2, repin this repo's `Package.swift` to the merge (drop the
   TEMP local-path override), PR into this repo (main protected). NO upstream
   Blaizzy PR until parity is ear-confirmed (David's call: "no PR on half-baked").
3. Decide App Store build 0.1.0(3) (in review, round-1 fix only).
