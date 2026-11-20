# Lux MLX memory work (2026-11-19) -- session notes

Branch `fix/lux-attention-memory` (worktree of gloam-voice-studio, based on the
iOS app's pin 106b1f2). Local only, not pushed. iOS app branch
`fix/fast-news-memory` builds against this worktree via a TEMP `path:` in
project.yml (see "Before pushing").

## Measured (iPhone 15 Pro, Billie Frost 1062-frame / 188-token ref, 336-char chunk, T = 3078)

| state | MLX peak | lifetime footprint | time |
|---|---|---|---|
| baseline (full attention, 512 MB cache) | 2294 MB | 3054 MB | 7.61 s |
| + blocked attention (7134e58d) | 1710 | 2451 | 6.54 |
| + per-layer eval checkpoints (a0acba84) | 1072 | 1662 | 7.16 |
| + app cache limit 0 (iOS 3561f9e) | 1072 | 1238-1434 | 7.0-7.3 |
| + fp16 weights only (opt-in, d9ddf655, `--lux-half`) | 854 | 1022 | 7.12 |
| + fp16 activations too (1b48d09c) | 568 | 808 | 6.51 |
| + vocoder stage checkpoints (d859aa44), fp32 | 1072 | 1239 (2nd chunk 1432*) | thermal-throttled |
| same, fp16 | 577 | 784 (2nd chunk 929*) | thermal-throttled |

\* second chunk includes playback (+~120 MB) starting after chunk 1.
Times after ~01:00 were taken at thermalState 2 (serious) and are ~35%
slower for unchanged code -- compare times only at the same thermal state.

fp16 error vs fp32 on the same noise (Mac): weights-only 0.8% RMS of the
features, full fp16 2.0%, bf16 4.3%. WAVs of the same 336-char Billie line
(scratchpad fable/): billie-335-fp32.wav, billie-335-fp16-weights-only.wav,
billie-335-fp16-full.wav -- David to listen.

News (CDC repro, 9 min windows, no kill): fp32 lifetime 1552 MB, fp16 1026
MB (before the vocoder checkpoints). The News extra over standalone is the
baseline creeping between chunks (ASR recogniser stays loaded, +~100 MB
measured; rest of episode state unattributed) plus driver transient.

Weights: fp32 554 MB MLX active, fp16 311 MB. Non-MLX on phone: app ~93 MB,
G2P lexicon +84 MB, playback +~120 MB once audio plays, graphics driver
transient up to ~150 MB during the acoustic model (not seen on the Mac).

## Round 2 (2026-11-20): News, CDC story, 6 min each, iPhone 15 Pro

David listened: fp16 weights-only is fine; full fp16 (activations too) has an
audible artifact ~9 s into billie-335-fp16-full.wav -> rejected. 14d1e193 adds
`computeDType`; the app's `--lux-half` is now weights-only (fp16 weights,
fp32 compute); `--lux-half-compute` is the rejected full fp16, experiments only.

New probe (iOS App/MemoryProbe.swift `MemoryWatch`, Debug): samples
phys_footprint split every 2 ms during each chunk -- graphics-tagged ledger
(Metal) vs the rest, MLX active, Metal device allocated -- and logs the max.
It lands within ~10 MB of the kernel's lifetime peak, so the peaks are seen.
Parser: scratchpad tools/peaks.py <log>.

| step | fp16 weights-only | fp32 |
|---|---|---|
| this morning's build (full fp16 was "half") | -- (full fp16: 1142) | 1496 |
| s0 baseline, instrumented | 1226 | 1436 |
| s1 + ASR recogniser dropped before each chunk (`--asr-unload`) | 1164 | -- |
| s2 attention blocks (ef789784), ASR kept | partial: 904 after 5 chunks* | not run* |

\* 08:35 and 09:02 runs stopped when the phone left the foreground/locked
(David took the phone); s2 is incomplete and not comparable to a 6 min run.
At 5 chunks s0 was ~1046 and s2 904; MLX peak at 1237 frames 503 MB.

ASR unload: the recogniser load+decode adds ~130 MB of "other", but dropping
it frees only ~40-80 MB (the rest stays as heap); check time per part 0.25 ->
0.42 s (+0.18 s reload). Peak 1226 -> 1164. Creep is not the recogniser:
with it dropped every chunk "other" still rose 114 -> ~290 (fp32 run: 166 ->
355). malloc in-use/held is now logged before each chunk to split live data
from heap fragmentation -- not yet measured on the phone.

Mac only (bench, 336-char chunk, weights-only unless noted):
- transient vs chunk length after ef789784: 2033 gen frames 286 MB, 1717
  243 MB, 1355 (budget ~2400) 198 MB -> a 2400 budget would save ~90 MB at
  the cost of ~37% less text per chunk (more seams). Not applied.
- MLX cache limit 0/64/128/256 MB: max footprint 618-630 / 665-700 / 730-755
  / 853-860 MB -> keep 0.
- graphics ledger: 60-280 MB above MLX's own peak on the first render of a
  process and stays at ~584 MB after it with MLX at ~250 (ad281e5f bench).
- the vocoder transient is 178 MB (2033 frames), below the acoustic model's.
- time: weights-only 2.1-2.2 s before, 2.3-2.5 s after ef789784 (~+10%),
  fp32 similar; phone times not yet compared at equal thermal state.

What the "~400 MB above every sampled point" is: nothing outside the model.
(a) MLX's own transient inside the acoustic model (MLX peak 864 MB at 2022
frames for weights-only vs 318 active: the [luxmem] lines only sample at stage
boundaries, after it is gone); (b) the graphics ledger lags MLX: freed Metal
buffers stay charged to the process for a while (graphics sits at the recent
high-water mark while MLX active drops 300 MB; Metal's currentAllocatedSize
tracks MLX active, not the ledger), and now and then overshoots MLX's own
peak by 100-200 MB (the 1095 spike: graphics 748 vs MLX 574/577 peak).
Non-graphics during a render is flat: ~120 MB before the ASR recogniser loads,
~250 after, ~310 late in the run.

Creep: graphics between chunks is constant (MLX active + ~31 MB); the creep
is non-graphics memory (other 250 -> 315 MB over 6 min). Not attributed yet.

Mac trace of the acoustic model (fp32, T = 3095): the peak was building the
attention weights -- +482 MB for a 153 MB (H, T, T) tensor, because MLX ran
all row blocks' scores/band/softmax side by side and then concatenated.
ef789784: evaluate each block as built, keep blocks (no concat), evaluate
after each layer stage. Mac transient: fp32 524 -> 290 MB, weights-only
552 -> ~290 MB, same speed; features 0.15% RMS from the old path (rounding:
one layer's block product differs < 7e-7). Recompute-per-use tried: -60 MB,
+45% time, dropped.

## Root causes
1. RelPositionMultiheadAttentionWeights built (H, T, 2T-1) pos scores and a
   pad/reshape shift that copied them twice -> ~7 (H,T,T) fp32 tensors/layer.
2. One lazy graph per ODE step: MLX kept many layers' intermediates alive.
3. 512 MB MLX buffer cache counted in footprint (no speed benefit measured).
4. (vocoder) see below.
5. News: chunks were cut by chars; CDC text expands ~2x under G2P, so a
   325-char chunk was 3750 frames (T = 4812 vs 3200 budget). Fixed app-side
   by LuxPacing.fit (token budget), iOS 8e4e0d0.

- Vocoder: one lazy graph held ~310 MB of intermediates; staged evals ~178 MB.

## Tried and dropped
- Applying attention per row block in the consumers (no concat copy): no
  memory change on the Mac bench (536 vs 520 MB), 6e-8 rounding drift. Reverted.

## Tools
- Mac bench: `TEST_RUNNER_LUXMEM_BENCH=1 TEST_RUNNER_LUXTTS_WEIGHTS_DIR=<ios>/Models/lux-tts-mlx
  [TEST_RUNNER_LUXMEM_CACHE_MB=0] xcodebuild test -scheme gloam-voice-studio-Package
  -destination 'platform=macOS' -derivedDataPath .build-dd
  -only-testing:EngineKitTests/LuxMemoryBenchTests`
- Phone: iOS Debug launch args `--mlx-cache-mb N`, `--lux-half`; `[luxmem]` log lines.
- Empty the News make queue before standalone runs (it resumes on launch).

## Before pushing
- Push this branch (or merge to main) and repin the iOS project.yml
  `gloam-voice-studio:` back to `url:` + `revision: <pushed sha>`; remove
  the TEMP `path: ../gloam-voice-studio-luxmem` line.
- Decide on the [luxmem] NSLog lines (957d6886): drop or demote.

## Paused 2026-11-20 (~09:15)

Nothing running on the phone (app terminated, News make queue emptied) or the
Mac. Both trees clean. Library HEAD 9e09a89c (+ this note); iOS app 6302149,
installed on the phone (attention fix + malloc logging + `--mlx-seed`).

Where I am: ef789784 (attention built a block at a time, kept as blocks,
per-stage evals) is measured on the Mac only; the phone has one partial News
run of it (09:02, 5 chunks, stopped when David took the phone).

All measurements so far (lifetime peak, News CDC story, 6 min unless noted):
| run | build | half weights (`--lux-half`) | fp32 | where |
|---|---|---|---|---|
| verify (morning) | before round 2 | all-fp16: 1142 | 1496 | phone |
| w1 | all-fp16 + MemoryWatch | all-fp16: 984 | -- | phone |
| s0 | weights-only baseline | 1226 | 1436 | phone |
| s1 | s0 + `--asr-unload` | 1164 | -- | phone |
| s2 | + ef789784 | 904 after 5 chunks (partial) | -- | phone |
Mac bench (transient above weights, 336-char chunk, 2033 gen frames):
fp32 524 -> 290 MB; weights-only 552 -> ~290 MB; all-fp16 253 -> 147 MB;
features 0.15% RMS from the old path; ~+10% time. Transient vs length
(weights-only): 2033 frames 286, 1717 243, 1355 198 MB. MLX cache 0/64/128/256:
max footprint 618-630/665-700/730-755/853-860 MB. Vocoder transient 178 MB.
ASR check per part 0.25 s kept vs 0.42 s with unload (phone).

Next, in order (phone):
1. Full 6 min News runs with ef789784: `newsrun.sh s2_fp16w 360 --lux-half`,
   then `newsrun.sh s2_fp32 360` (scratchpad fable/; parse with
   tools/peaks.py). Read malloc in-use/held from "before chunk" for the creep.
2. Billie A/B by ear: `billie.sh billie-after-fp16w --lux-half` on this build;
   then check out 14d1e193 in this worktree, ship-device, `billie.sh
   billie-before-fp16w --lux-half`, return to the branch head, ship again.
   Same seed (7), so the two WAVs differ only by the fix.
3. If half weights is still >1 GB: `--asr-unload` (phone -62 MB) and then
   `--lux-frame-budget 2400` (Mac -90 MB, more seams), one at a time.
4. Then decide what ships: make ASR unload / budget real (not Debug flags),
   drop or demote the probes, and the repin of project.yml (see "Before pushing").
Optional, not started: which fp16 activation causes the ~9 s artifact.
