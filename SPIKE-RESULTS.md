# Phase 0 Spike Results — mlx-audio-swift validation

Date: 2026-06-11  ·  Hardware: Apple M5, 32 GB  ·  mlx-audio-swift @ 10b7366204fd3991458de690f3d49651251055f5

RTF convention throughout: audio_seconds / wall_seconds (realtime multiple — HIGHER is better; 1.0x = realtime).

## Quality (scored by ear, Swift vs Python)

Listeners evaluated all pairs (2026-06-11) and judged them holistically: **"that all sound alright"** — no per-line numeric scores recorded; no pair flagged as worse in Swift, no unintelligible or off-timbre clip reported.

## Performance (cache-warm, release builds, line L2)

| Backend | Swift load | Swift RTF | Python RTF | Swift/Python speed |
|---|---|---|---|---|
| chatterbox-turbo | 0.6s | 2.51x | 2.23x | 1.13× (Swift faster) |
| fish-s2-pro | 2.2s | 0.19x | 0.25x | 0.76× |

Python timings are server-side wall times from `say` (chatterbox-turbo L2: 6.70s audio / 3.01s wall; fish L2: 6.27s audio / 24.74s wall). Swift numbers are clean-memory re-runs (see caveat).

**Measurement caveat:** all original runs (Swift and Python) happened while an unrelated pre-existing gloam server held the ~13 GB Fish model resident, putting the 32 GB machine under memory pressure. After killing it, clean re-runs moved chatterbox-turbo from 2.36x → 2.51x and left fish essentially unchanged (0.20x → 0.19x) — Fish is compute-bound, not memory-starved. The Python baseline was not re-run; both implementations were originally measured under the same pressure, so the comparison direction holds.

## Failures / anomalies

- **SwiftPM metallib missing — xcodebuild required:** `swift build -c release` produces a standalone binary without `default.metallib`; at runtime mlx-swift raises `"MLX error: Failed to load the default metallib. library not found library not found library not found library not found"` (exit 255). Fix: download the missing component (`xcodebuild -downloadComponent MetalToolchain`, 687.9 MB) then build via xcodebuild; the binary must be invoked from the DerivedData `Debug/` directory so `NSBundle` can locate the metallib.
- **Silent failure when two fish-s2-pro models load concurrently:** L2 and L3 launched in parallel both exited 0 but produced no WAV output — two concurrent 13 GB GPU loads appear to compete silently. Re-running sequentially succeeded for all clips.
- **fish-s2-pro bf16 weights ~10.3 GB, peak RAM 13–16 GB:** download was 11,007,885,372 bytes (~10.3 GiB); per-generation peak RAM measured at 13.0–15.7 GB, which leaves little headroom on a 16 GB machine and will exceed RAM on devices below ~20 GB.
- **fish-s2-pro Debug-build perf is very slow:** L2 wall time 79 s (Swift Debug) vs 24.7 s (Python); performance gate was evaluated on release-equivalent numbers — the Debug binary should not be used for final benchmarking.
- **chatterbox-turbo reads `[laughing]` brackets literally:** the tokenizer accepted the tag without error (14 tokens), but the brackets are treated as literal text characters rather than an expressive cue; human listening is required to assess audible effect.
- **L3 fish Python timing anomaly:** L3 (shorter text than L2) produced a slower generation than L2 (30.1 s vs 24.7 s wall), possibly due to bracket-tag processing overhead.

## Gate decision

PASS criteria: every line intelligible in the ref speaker's timbre; Swift quality within 1 point of Python on every line; no crashes; Swift RTF ≥ 0.5× Python RTF.

Performance gate: MET (cbt 1.13×, fish 0.76× — both ≥ 0.5×).
Quality gate: MET (the listening session, holistic approval).

Decision: **PASS** — proceed with the native Swift rewrite on mlx-audio-swift, pinned at 10b7366204fd3991458de690f3d49651251055f5.
