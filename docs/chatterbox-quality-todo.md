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
