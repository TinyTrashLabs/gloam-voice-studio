# The `.gvoice` pack format

**This document is the source of truth for `.gvoice`.** The Swift implementation
(`Sources/StudioKit/GVoice.swift`) and the Python implementation
(`gloam-voice-engine/src/gloam_voice_engine/voices.py`) both conform to it. When
they disagree, this document wins; when this document is wrong, fix it here first.

A `.gvoice` file is a deflate zip holding **one voice identity**, its **source
material**, and **per-engine renditions** derived from that material.

---

## Why the container is not audio-centric

A voice is not always a recording. Of the backends in `BackendID`, three carry no
reference audio at all (`BackendID.controls`, `Sources/EngineKit/Backend.swift`):

| Backend | `voiceClone` | `instruct` | Preset speakers | What a pack must carry |
| --- | --- | --- | --- | --- |
| `qwen3-0.6b` | optional | none | — | `source/` audio + transcript |
| `qwen3-1.7b` | optional | none | — | `source/` audio + transcript |
| `qwen3-design` | **none** | **required** | — | an `instruct` string — the description *is* the voice |
| `qwen3-custom` | **none** | optional | 9 (`qwenPresetSpeakers`) | a `speaker` id + optional `instruct` |
| `chatterbox` | **required** | none | — | `source/` audio |
| `chatterbox-turbo` | **required** | none | — | `source/` audio |
| `fish-s2-pro` | optional | none | — | `source/` audio (stock voice also valid) |
| `kokoro` | **none** | none | `kokoroVoices` | a `speaker` id |
| `supertonic-2` | derived | none | F1–F5 / M1–M5 | `style.json` — `style_ttl` + `style_dp` |
| `supertonic-3` | derived | none | F1–F5 / M1–M5 | `style.json` — `style_ttl` + `style_dp` |

Every asset in a pack is therefore **optional except identity**. A pack may hold
only reference audio, only a Supertonic style, only an instruct string, or all
three.

---

## Layout

```
billie-frost.gvoice          (deflate zip)
├── manifest.json            required
├── source/                  optional — the master; everything else derives from it
│   ├── ref.wav
│   ├── ref-hype.wav
│   └── transcript.txt
└── engines/                 optional — one directory per engine
    ├── supertonic-3/
    │   ├── style.json
    │   └── style-hype.json
    ├── supertonic-2/
    │   └── style.json
    ├── qwen3-design/
    │   └── voice.json       { "instruct": "a warm, gravelly late-night host" }
    ├── qwen3-custom/
    │   └── voice.json       { "speaker": "Dylan", "instruct": "…" }
    ├── kokoro/
    │   └── voice.json       { "speaker": "af_heart" }
    └── elevenlabs/
        └── voice.json       { "voiceId": "…" }
```

`chatterbox`, `chatterbox-turbo`, `fish-s2-pro` and the Qwen Base models need no
`engines/` directory — they consume `source/` audio directly, and the manifest
points them at it.

## `manifest.json`

```json
{
  "gvoice": 1,
  "name": "Billie Frost",
  "slug": "billie-frost",
  "createdAt": "2026-07-24T04:11:00Z",
  "variants": ["base", "hype"],
  "source": {
    "base": { "audio": "source/ref.wav",      "text": "…" },
    "hype": { "audio": "source/ref-hype.wav", "text": "…" }
  },
  "engines": {
    "supertonic-3": { "base": "engines/supertonic-3/style.json",
                      "hype": "engines/supertonic-3/style-hype.json" },
    "chatterbox":   { "base": "source/ref.wav" },
    "qwen3-design": { "base": "engines/qwen3-design/voice.json" }
  },
  "provenance": {
    "source": "latent-inversion",
    "config": { "…": "tool-specific; opaque to readers" }
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `gvoice` | yes | Format version. `1` — the only version. Readers reject anything higher. |
| `name` | yes | Human-readable display name. The only truly required payload. |
| `slug` | no | Derived from `name` when absent (lowercase, non-alphanumeric runs → `-`). |
| `createdAt` | no | RFC 3339 UTC. |
| `variants` | no | Ordered variant keys. `base` is implied and always first. |
| `source` | no | Variant key → `{ audio, text }`. Paths are pack-relative. |
| `engines` | no | Engine id → variant key → pack-relative path. |
| `provenance` | no | Free-form record of how the renditions were produced. Opaque to readers — whatever the producing tool needs to reproduce its own output. |

Engine ids match `BackendID.rawValue` where a backend exists in `EngineKit`.
Engines outside it (`supertonic-2`, `supertonic-3`, `elevenlabs`) use the ids
above and are reserved.

---

## Rules

These three rules are what make one pack serve clients that ship months apart.

1. **Unknown keys are ignored, never fatal.** A reader that does not understand
   an `engines/*` entry must skip it and import everything else. iOS understands
   `supertonic-3` and nothing else; the macOS engine understands `chatterbox` and
   not `supertonic-3`. Both must import the same pack successfully.

2. **Every asset is optional except `name`.** A Supertonic-only pack with no
   `source/` is valid. A `qwen3-design` pack with neither audio nor style JSON is
   valid. Readers surface what they can render and stay silent about the rest.

3. **Variants travel with the pack.** Emotion variants are *inside* one pack, not
   sibling slugs. A reader that resolves `<slug>-<emotion>` from its own library
   must still export those takes into the parent pack's `variants`, or the
   emotional range is silently lost in transit.

## `source/` is the master

Renditions are derived; the reference audio is not. Keeping `source/` in the pack
is what lets a voice be re-baked for an engine that did not exist when the pack
was written — a new Supertonic version, a new backend — instead of re-recorded.
`provenance.config` exists so that re-bake is reproducible rather than
approximate.

**Exporters include `source/` by default.** It is what keeps one voice identity
coherent across clients that run different models — iOS on Supertonic, macOS on
Chatterbox or Qwen, a cloud path on a hosted voice. A pack without it is only a
voice on the one engine it was baked for; a pack with it is the voice itself, and
any client can derive what it needs.

Exporters must still offer `includeSource: false` for packs shared outside the
owner's own machines, since `source/` lets any recipient re-clone the voice into
any engine. It is the exception, not the default.

## Conformance

An implementation conforms when it can:

- import a pack whose `engines` map contains ids it does not recognise;
- import a pack with no `source/`;
- import a pack with no `engines/`;
- round-trip a multi-variant pack without dropping variants;
- export with and without `source/`.
