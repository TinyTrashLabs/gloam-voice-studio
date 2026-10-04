---
name: voice-pack-cleaning
description: Make or repair a .gvoice pack's reference (any language) so Qwen renders it reliably — find clean candidate clips, isolate the voice, get exact transcripts, optionally make a fluent read with Fish/Qwen from the voice's OWN language clip, stress-test each candidate on the Neural Engine with word-error scoring, pick by numbers + ear, and write it into the pack in the per-engine layout. Use when a voice sounds wrong, skips/garbles text, stalls into silence, "freaks out", or when adding a language reference to a pack.
---

# Voice pack cleaning

Qwen continues its reference: it copies the reference's **delivery**, not just its timbre. A halting,
noisy, or mismatched reference makes renders stall, drop sentences, or say one word then go silent.
Fix the reference, measure, then ship — never band-aid the renderer (no per-part re-rolls).

Worked example (2026-10-04, Bad Bunny Spanish): the interview clip failed **12/30** renders of a radio
break; a Fish fluent read cloned from his Spanish clip failed **0/20**; Benson's studio Spanish (control)
**1/30**. Write-up: gloam-dj `docs/radio-testflight-18-handoff-2026-10-04.md`.

## Rules

- **Never generate a language from another language's reference** (an English clip speaking Spanish has
  an English accent). Fluent reads are cloned from the voice's own clip in that language.
- Start on a whole word; end on a complete sentence followed by a pause. A reference that stops
  mid-sentence makes Qwen continue it.
- The transcript must match the clip **exactly** — transcribe the final cut, never reuse a source subtitle.
- Qwen ANE section ≤ **256 frames (20.48 s)**; aim 12–18 s.
- The master stays whole; sections live in the pack under `engines/<engine>/` (takes as `-<lang>` files).
  Host apps (radio) never cut or prepare sections.
- Background noise in the clip ends up in every render. If isolation can't make it clean, use a fluent read.

## Steps

Needs: the running Studio app (API `http://127.0.0.1:8790`, MCP `transcribe`), `spike` built from
gloam-voice-studio (`swift build -c release --product spike`; symlink `/opt/homebrew/lib/mlx.metallib`
into `.build/release/` if MLX says "Failed to load the default metallib"), Demucs weights in
`~/Library/Application Support/GloamVoiceStudio/Models/htdemucs-ft-vocals-mlx/`
(`scripts/convert_demucs_weights.py`, PR #86). `qwen-ane-stress` lives on branch
`fix/qwen-degenerate-parts` until merged. Scripts are in this skill's `scripts/`.

1. **Baseline.** Put the break that failed in `break.txt` (the real text from the app's render log,
   `Documents/qwen-renders/*.txt` on the phone). Extract the current reference's Qwen files and run
   `spike qwen-ane-stress --models <qwen3-0.6b-ane> --voice <dir> --text-file break.txt --out base --n 30 --language es`,
   then `scripts/wer.py base`. Also run a known-good control voice (e.g. Benson `scripts/qwen-ane-voices/benson-es`
   in gloam-dj) — if the control fails too, the problem is the engine/text, not the reference.
2. **Candidates.**
   - Real clips: from the source + its subtitles, find 10–20 s runs of continuous speech in the language
     (no interviewer, few fillers), cut with ffmpeg (stereo 44.1 kHz), clean with
     `spike gvoice-prepare --mode isolate-vocals --denoise none --weights <dir> --segment 0:<len> ...`
     (it refuses mono — make it dual-mono stereo first).
   - Fluent reads: a 12–16 s radio-style script in the language; render 4–6 takes with Studio from the
     voice's language take (`/v1/audio/speech` with `voice` + `language`, models `fish-s2-pro` and `qwen3-1.7b`).
   - Convert each to 24 kHz mono 16-bit; transcribe each final clip (`similarity.py` prints it).
3. **Voice match.** `similarity.py --ref es=<real lang clip> --ref en=<other lang clip> cand*.wav` — keep
   takes that clearly match the language clip (≈0.92+) over the other language.
4. **Qwen files.** `qwen-files.py CLIP.wav TRANSCRIPT.txt voice-<name> --language es` (frames must be ≤ 256).
5. **Stress test** each candidate exactly like step 1 (n=20–30; one at a time — the ANE can't share;
   ~10 min each). Bad = >30% words wrong. Ship only a candidate at or below the control's failure rate.
6. **Listen.** Publish a page with each candidate's reference clip + 3 renders of the failing break and
   its score; the user picks (noise and naturalness are ear calls the numbers miss).
7. **Write the pack.** `set-language-reference.py PACK es CLIP TRANSCRIPT voice-<name> OUT.gvoice`
   (bumps revision). Install: delete the voice in the app, then import the pack.
