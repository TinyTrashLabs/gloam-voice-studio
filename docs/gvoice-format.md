# The `.gvoice` pack format

**This document is the source of truth for `.gvoice`.** The Swift implementation
(`Sources/StudioKit/GVoice.swift`) and the Python implementation
(`gloam-voice-engine/src/gloam_voice_engine/voices.py`) both conform to it. When
they disagree, this document wins; when this document is wrong, fix it here first.

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, and **MAY** in
this document are to be interpreted as in RFC 2119: MUST/MUST NOT are hard
conformance requirements; SHOULD is a strong default an implementation needs a
real reason to deviate from; MAY is a genuine option, not a suggestion either
way is fine to ignore silently.

A `.gvoice` file is a zip holding **one voice identity**, its **source
material**, and **per-engine renditions** derived from that material. The zip
MAY use deflate or store compression; readers MUST accept either.

There is currently exactly one version of this format (`gvoice: 1`) and no
packs in the wild predating it — nothing below describes a migration, only how
the format is meant to evolve once that stops being true.

---

## Why the container is not audio-centric

A voice is not always a recording. Per `BackendID` (`Sources/EngineKit/Backend.swift`),
backends vary in what they need:

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
| `lux-tts` | **required** | none | — | `source/` audio |
| `supertonic` | **none** | none | F1–F5 / M1–M5 (`supertonicVoices`) | `style.json` — `style_ttl` + `style_dp` |

`supertonic` is one backend, not two — there is no separate `supertonic-2`/
`supertonic-3` `BackendID`. If a future SuperTonic generation needs a
genuinely different pack shape, it MUST get its own `BackendID` and engine id
rather than overloading `supertonic`.

A pack's assets are optional *individually*, but a pack MUST carry at least
one — see Rule 2 below for exactly what "at least one" means; this table is
not itself a licence to ship an empty pack.

---

## Layout

```
billie-frost.gvoice          (zip)
├── manifest.json            required
├── source/                  optional — the master; everything else derives from it
│   ├── ref.wav
│   └── ref-hype.wav
└── engines/                 optional — one directory per engine
    ├── supertonic/
    │   ├── style.json
    │   └── style-hype.json
    ├── qwen3-design/
    │   └── voice.json       { "instruct": "a warm, gravelly late-night host" }
    ├── qwen3-custom/
    │   └── voice.json       { "speaker": "Dylan", "instruct": "…" }
    ├── kokoro/
    │   └── voice.json       { "speaker": "af_heart" }
    └── elevenlabs/
        └── voice.json       { "voiceId": "…" }
```

`chatterbox`, `chatterbox-turbo`, `lux-tts`, `fish-s2-pro` and the Qwen Base
models need no `engines/` directory — they consume `source/` audio directly,
so a reader serving them reads `source` and ignores `engines` entirely. A
manifest MAY still list such an engine pointing back into `source/`; readers
MUST tolerate that but writers need not emit it.

Transcript text lives inline in the manifest (`source.<key>.text`), not as a
sibling file — there is no `transcript.txt` member. (An earlier draft of this
doc showed one; it was never implemented and this is the correction.)

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
    "supertonic":   { "base": "engines/supertonic/style.json",
                      "hype": "engines/supertonic/style-hype.json" },
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
| `gvoice` | yes | Format version. Currently `1`. Readers MUST reject a `gvoice` value higher than the newest version they implement (forward incompatibility); they MUST NOT reject a lower one merely for being lower (see Versioning below). A value below `1` is simply malformed. |
| `name` | yes | Human-readable display name. The only truly required payload. |
| `slug` | no | The producing library's own slug for the voice. Informational only — see "What import does NOT preserve" below; a reader MUST NOT rely on it as a stable cross-library identifier. |
| `createdAt` | no | RFC 3339 UTC, from the producing library. Informational only, same caveat as `slug`. |
| `variants` | no | Ordered variant keys. `base` is semantically first regardless of list position — see Rule 4. |
| `source` | no | Variant key → `{ audio, text }`. Paths are pack-relative. |
| `engines` | no | Engine id → variant key → pack-relative path. |
| `provenance` | no | Free-form record of how the renditions were produced. Opaque to readers — whatever the producing tool needs to reproduce its own output. Readers MUST preserve it unchanged through import → re-export even though they don't interpret it; see Rule 1. |

Engine ids SHOULD match `BackendID.rawValue` where a backend exists in
`EngineKit` (`supertonic`, `elevenlabs`, etc. included). A third party
extending the format with an engine `BackendID` doesn't know about MUST
namespace its id (e.g. `x-mycompany-engine` or reverse-DNS) so it can never
collide with a future built-in id — this is what makes Rule 1 safe to rely on
across independently-evolving implementations.

## Versioning

`gvoice` is a **breaking-change counter**, not a build number. A new field, a
new engine id, a new optional manifest key — anything an old reader can
safely ignore per Rule 1 — MUST ship without bumping `gvoice`. Only a change
an old reader would misinterpret if it tried to read it (a field changing
meaning, a required-ness change, restructuring `source`/`engines`) justifies a
bump.

That split is what makes forward compatibility possible at all: readers
reject `gvoice` values *above* what they implement (they don't understand the
breaking change yet) and accept anything at or below it, trusting Rule 1 to
carry them through every additive change in between. Rejecting on `!=` instead
of `>` — treating your own current version as the only valid one — defeats
that: it means a version bump orphans every reader that hasn't shipped yet,
which is the opposite of the point of having a version field.

---

## Rules

These rules are what let one pack serve clients that ship months apart, and
what an implementation MUST do to conform.

1. **Unknown keys, and any member a manifest points at that turns out not to
   exist in the pack, are non-fatal.** A reader that does not understand an
   `engines/*` entry, or an entry whose `manifest.json`-declared engine id it
   has never heard of, MUST skip it and import everything else. A manifest
   entry pointing at a zip member that is missing, corrupt, or oversized MUST
   likewise degrade to "skip that one asset," not abort the whole import — a
   single bad reference in an otherwise-good pack must not sink it. iOS
   understands `supertonic` and nothing else; the macOS engine understands
   `chatterbox` and not `supertonic`. Both MUST import the same pack
   successfully. This also covers `provenance` and any other manifest field a
   given reader doesn't interpret: unknown fields MUST be preserved through
   re-export, not silently dropped.

2. **A pack MUST carry at least one importable asset for `base` beyond its
   name** — reference audio, or at least one engine's rendition. A manifest
   with a `name` and nothing else is syntactically valid JSON but is not an
   importable `.gvoice` pack; readers MUST reject it (with a clear "nothing to
   install" error, not a crash). This is not in tension with "every asset is
   optional" above — that means no *particular* asset is required, not that
   zero assets total is a valid pack. A `qwen3-design` pack whose only asset
   is its `engines/qwen3-design/voice.json` (holding just an `instruct`
   string) satisfies this rule; a pack with no `source/` and no `engines/` at
   all does not.

3. **Import is atomic per pack.** If the `base` variant does not satisfy Rule
   2, the reader MUST install nothing from the pack — no orphaned non-base
   variant directories left behind — regardless of what order `manifest.variants`
   lists keys in. `variants` order is untrusted input; a reader MUST resolve
   `base` first internally no matter where it appears in that list.

4. **Variants travel with the pack.** Emotion/style variants are *inside* one
   pack, not sibling slugs. A reader that resolves `<slug>-<emotion>` from its
   own library MUST still export those takes into the parent pack's
   `variants`, or the emotional range is silently lost in transit. `base` is
   implied even if absent from an explicit `variants` list.

## `source/` is the master

Renditions are derived; the reference audio is not. Keeping `source/` in the pack
is what lets a voice be re-baked for an engine that did not exist when the pack
was written — a new Supertonic version, a new backend — instead of re-recorded.
`provenance.config` exists so that re-bake is reproducible rather than
approximate — which only holds if readers actually preserve it (Rule 1).

**Exporters include `source/` by default.** It is what keeps one voice identity
coherent across clients that run different models — iOS on Supertonic, macOS on
Chatterbox or Qwen, a cloud path on a hosted voice. A pack without it is only a
voice on the one engine it was baked for; a pack with it is the voice itself, and
any client can derive what it needs.

Exporters MUST still offer an option to omit `source/` for packs shared outside
the owner's own machines, since `source/` lets any recipient re-clone the voice
into any engine. Omitting it is the exception, not the default.

## What import does NOT preserve

Import installs a pack into *this* library, which already has its own
slugging and timestamping conventions — it does not adopt the producing
library's identifiers verbatim:

- **`slug`** — the installed voice gets a freshly-derived local slug (from
  `name`), or an existing base's slug for variants (`<baseSlug>-<key>`). The
  manifest's own `slug` is read but not used to name the local copy; treat it
  as informational metadata about where the pack came from, not a stable
  cross-library id.
- **`createdAt`** — the local copy gets the local install time, not the
  manifest's `createdAt`. The original creation time is still visible in the
  manifest inside the pack itself if that provenance matters.
- **Variant membership** (`variantOf`, local-only, not a manifest field) is
  assigned at install time from the *local* base slug a variant was installed
  alongside, so a library's own bookkeeping of "which voices are variants of
  which" never depends on slug-string pattern-matching (an independently
  named voice like "dj-nova" must never be mistaken for a variant of "dj").

`provenance`, by contrast, IS preserved verbatim (Rule 1) — it is opaque
producer metadata, not a local identifier this library owns.

## Known gaps

- **`persona` and the avatar image are app-level metadata, not voice-identity
  data, and are not currently packed.** A `.gvoice` pack carries what's needed
  to *render* the voice; chat persona and avatar stay local to each library.
  If that changes, it's an additive manifest/layout extension under the
  Versioning policy above, not a `gvoice` bump.
- **Cross-implementation zip edge cases are untested.** Duplicate member
  names and directory-entry case sensitivity are handled however each zip
  library's reader happens to handle them (Swift's `ZIPFoundation` vs.
  Python's `zipfile`), and the two have not been cross-checked against each
  other on either point. Don't rely on either behavior until that's verified;
  writers SHOULD simply never emit duplicate member names.

## Conformance

An implementation conforms when it can:

- import a pack whose `engines` map contains ids it does not recognise;
- import a pack with no `source/`;
- import a pack with no `engines/`;
- import a pack where some manifest-referenced member is missing, without
  losing the rest of that variant's installable assets (Rule 1);
- reject a pack whose `base` variant has nothing installable (Rule 2), without
  leaving any other variant partially installed (Rule 3);
- round-trip a multi-variant pack without dropping variants;
- round-trip `provenance` unchanged even though its shape is not understood;
- export with and without `source/`.
