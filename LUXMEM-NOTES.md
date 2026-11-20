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
| + fp16 acoustic model (opt-in, d9ddf655, `--lux-half`) | 854 | 1022 | 7.12 |

Weights: fp32 554 MB MLX active, fp16 311 MB. Non-MLX on phone: app ~93 MB,
G2P lexicon +84 MB, playback +~120 MB once audio plays, graphics driver
transient up to ~150 MB during the acoustic model (not seen on the Mac).

## Root causes
1. RelPositionMultiheadAttentionWeights built (H, T, 2T-1) pos scores and a
   pad/reshape shift that copied them twice -> ~7 (H,T,T) fp32 tensors/layer.
2. One lazy graph per ODE step: MLX kept many layers' intermediates alive.
3. 512 MB MLX buffer cache counted in footprint (no speed benefit measured).
4. News: chunks were cut by chars; CDC text expands ~2x under G2P, so a
   325-char chunk was 3750 frames (T = 4812 vs 3200 budget). Fixed app-side
   by LuxPacing.fit (token budget), iOS 8e4e0d0.

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
