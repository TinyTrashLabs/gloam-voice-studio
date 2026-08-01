# `.gvoice` packs

The two starter voices, built with `spike gvoice-build` (see
`Sources/spike/main.swift`) per `docs/gvoice-format.md`. Both are ElevenLabs
voices whose rights Tiny Trash Labs holds, shipped with the repo so a fresh
clone has something to speak with.

Built from a debug binary at `.build/arm64-apple-macosx/debug/spike`; adjust
the path if your build config differs (e.g. `.build/release/spike`).

## `billie-frost.gvoice`

- name `Billie Frost`, slug `billie-frost`
- source: `supertonic-mlx-spike/refs/midge.wav` (27.2s, 44.1kHz mono, stored
  as-is — `source/` is the master, readers resample)
- transcript: `supertonic-mlx-spike/mimocro/out_midge/ref_text.txt`, with the
  trailing `# window:` / `# dur_target:` comment lines stripped
- `engines/supertonic/style.json`: byte-identical to the shipped
  `Models/supertonic/voices/midge.json` in gloam-voice-studio-ios (verified
  by SHA-256 — "midge" was the working name for this voice)
- `engines/kokoro/voice.json`: `{"speaker": "bf_emma"}` — she reads British;
  bf_emma is the best-graded British female voicepack
- `engines/qwen3-design/voice.json`: a short instruct description of the
  voice as heard in the transcript (warm, chatty, working-class British,
  conversational)

Built with:

```sh
.build/arm64-apple-macosx/debug/spike gvoice-build \
  --name "Billie Frost" --slug billie-frost \
  --out packs/billie-frost.gvoice \
  --ref-wav /Users/david/projects/gloam.fm/supertonic-mlx-spike/refs/midge.wav \
  --ref-text-file /Users/david/projects/gloam.fm/supertonic-mlx-spike/mimocro/out_midge/ref_text.txt \
  --strip-comment-lines \
  --engine 'supertonic:style.json=@/Users/david/projects/gloam.fm/gloam-voice-studio-ios/Models/supertonic/voices/midge.json' \
  --engine 'kokoro:voice.json={"speaker": "bf_emma"}' \
  --engine 'qwen3-design:voice.json={"instruct": "A warm, chatty British woman with a soft working-class accent - conversational and easygoing, like catching up with a mate over a cuppa."}'
```

## `jeff.gvoice`

- name `Jeff`, slug `jeff`
- source: `supertonic-mlx-spike/refs/jeff.wav` (19.3s, 24kHz mono, stored
  as-is)
- transcript: `supertonic-mlx-spike/refs/jeff.txt`, verbatim
- `engines/supertonic/style.json`: the style actually shipped in the studio
  iOS app (`Models/supertonic/voices/jeff.json`), preferred over the many
  candidate runs under `supertonic-mlx-spike` — verified byte-identical by
  SHA-256
- `engines/kokoro/voice.json`: `{"speaker": "am_michael"}`
- `engines/qwen3-design/voice.json`: a short instruct description (late-night
  American radio host, warm and easy)

Built with:

```sh
.build/arm64-apple-macosx/debug/spike gvoice-build \
  --name "Jeff" --slug jeff \
  --out packs/jeff.gvoice \
  --ref-wav /Users/david/projects/gloam.fm/supertonic-mlx-spike/refs/jeff.wav \
  --ref-text-file /Users/david/projects/gloam.fm/supertonic-mlx-spike/refs/jeff.txt \
  --engine 'supertonic:style.json=@/Users/david/projects/gloam.fm/gloam-voice-studio-ios/Models/supertonic/voices/jeff.json' \
  --engine 'kokoro:voice.json={"speaker": "am_michael"}' \
  --engine 'qwen3-design:voice.json={"instruct": "A warm, easygoing late-night American radio host - smooth, unhurried delivery, like spinning records at 2am for the night owls."}'
```

## Notes

- Neither pack has a `lux-tts` entry under `engines/` — per the spec,
  `lux-tts` consumes `source/` audio directly and needs no `engines/`
  directory; writers need not emit one.
- Both packs include `source/` (the default) so any engine, present or
  future, can re-derive its own rendition from the master recording.
