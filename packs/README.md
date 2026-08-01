# `.gvoice` packs

The two starter voices, built with `spike gvoice-build` (see
`Sources/spike/main.swift`) per `docs/gvoice-format.md`. Both are ElevenLabs
voices whose rights Tiny Trash Labs holds, shipped with the repo so a fresh
clone has something to speak with.

Built from a debug binary at `.build/arm64-apple-macosx/debug/spike`; adjust
the path if your build config differs (e.g. `.build/release/spike`).

## What `source/` holds

Each pack's `source/ref.wav` is a ~10 s read at **24 kHz mono** — LuxTTS's
native rate, so nothing resamples on the way in — with the exact submitted
text inline in the manifest. Per the format spec `lux-tts` consumes `source/`
directly and needs no `engines/` entry, so this reference *is* the LuxTTS
voice.

Two properties matter and are easy to lose:

- **The transcript must be verbatim.** Audio and words have to describe the
  same span, because the text encoder sizes its output from the reference's
  frames-per-token ratio. A mismatch produces a rushed, clipped read.
- **Short beats long.** The fm_decoder ODE runs over prompt + text frames on
  every one of its steps, and the reference dominates that sequence. These
  replaced 27 s and 19 s masters and cut render cost roughly 2.4×, with no
  loss of likeness.

These reads were generated from the same ElevenLabs voices the `elevenlabs`
rendition names, which is what makes them verbatim by construction.

**Provenance caveat:** `engines/supertonic/style.json` was baked from an
earlier, longer take of the same voice (`supertonic-mlx-spike/refs/`), not
from the `source/ref.wav` now in the pack. Same voice, different read. Rebake
the style from `source/` if you ever need the two to be strictly derived.

## Consumers

`gloam-dj` imports both with `scripts/unpack-gvoice.py`, which writes
`supertonic-voices/<slug>.json` and `luxtts-sources/<slug>.{wav,txt}` into the
iOS bundle. That round-trip is byte-identical to what ships today.

## Building

```sh
SPIKE=.build/arm64-apple-macosx/debug/spike
SRC=../gloam-dj/apps/android/ios/App/App

$SPIKE gvoice-build --name "Billie Frost" --slug billie-frost \
  --out packs/billie-frost.gvoice \
  --ref-wav "$SRC/luxtts-sources/billie-frost.wav" \
  --ref-text-file "$SRC/luxtts-sources/billie-frost.txt" \
  --engine "supertonic:style.json=@$SRC/supertonic-voices/billie-frost.json" \
  --engine 'kokoro:voice.json={"speaker": "bf_emma"}' \
  --engine 'elevenlabs:voice.json={"voiceId": "hHUgSJ0by3cJ5z5U0fRp"}' \
  --engine 'qwen3-design:voice.json={"instruct": "A warm, chatty British woman with a soft working-class accent - conversational and easygoing, like catching up with a mate over a cuppa."}'

$SPIKE gvoice-build --name "Shane Ember" --slug shane \
  --out packs/shane.gvoice \
  --ref-wav "$SRC/luxtts-sources/shane.wav" \
  --ref-text-file "$SRC/luxtts-sources/shane.txt" \
  --engine "supertonic:style.json=@$SRC/supertonic-voices/shane.json" \
  --engine 'kokoro:voice.json={"speaker": "am_michael"}' \
  --engine 'elevenlabs:voice.json={"voiceId": "MuZSq16KJKpvg4F181TX"}' \
  --engine 'qwen3-design:voice.json={"instruct": "A warm, easygoing late-night American radio host - smooth, unhurried delivery, like spinning records at 2am for the night owls."}'
```

## Voices

| | `billie-frost` | `shane` |
| --- | --- | --- |
| name | Billie Frost | Shane Ember |
| read | British, warm, late-night | American, unhurried, late-night |
| `source/ref.wav` | 11.5 s | 9.4 s |
| kokoro speaker | `bf_emma` | `am_michael` |
