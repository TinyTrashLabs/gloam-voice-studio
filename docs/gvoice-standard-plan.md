# Making `.gvoice` the way voice clones are shared — plan

Date: 2026-09-09. Owner: David. Status: agreed direction, steps not started.

## Where we stand

- The format exists and is published: `docs/gvoice-format.md` in this repo
  (MIT, github.com/TinyTrashLabs/gloam-voice-studio), `gvoice` version 1,
  reference implementation `Sources/GVoiceKit` (Swift), producers and
  consumers in the Mac app and the iPhone app.
- Nothing else in the field is a container. Vendor voices (ElevenLabs,
  PlayHT, Resemble, Microsoft CNV, Apple Personal Voice) are account-bound
  and do not export. Open models each have an artefact of their own (Bark
  `.npz`, XTTS latents, RVC `.pth`+`.index`), none of them a clone-from-clip
  package. The zero-shot generation (Fish, F5, CosyVoice, Chatterbox, Dia,
  Qwen3-TTS, LuxTTS) reduced "a voice" to a WAV plus a transcript in a
  folder: no metadata, no consent, no provenance. That habit, and the RVC
  ecosystem's inertia, are the competition.
- Decision (David): the format stays Gloam's and stays open. Revenue comes
  from the apps, the hosted hub, and services around the format, not from
  the spec. No neutral-body handover.

## What "the standard" means here

A `.gvoice` file is what people attach, AirDrop, host and download when they
share a voice; open TTS tools accept it as input; platforms that need
consent and provenance for synthetic voices can check it inside the pack.

## Steps

### 1. Spec: make it consumable by strangers (this repo)

- Split `docs/gvoice-format.md` into a spec that stands alone from the Mac
  app: keep the engine table, but move Mac-app-specific implementation notes
  into GVoiceKit comments. Add a one-page "Read a pack in ten lines" section
  showing the minimum a consumer does: unzip, read `manifest.json`, take
  `source[base].audio` + `.text`.
- Add a JSON Schema for `manifest.json` (`spec/manifest.schema.json`) so any
  language can validate without reading prose.
- Add **consent and licence fields** (the wedge nobody else has; David: "add
  it"). Optional keys, no `gvoice` bump:
  - `consent`: `{ speaker: "self" | "third-party", statement: <text the
    speaker agreed to>, recordedAt: RFC3339, method: "in-app" | "written" |
    "unknown" }` — who the voice belongs to and how permission was captured.
  - `license`: an SPDX-style id or one of `personal`, `noncommercial`,
    `commercial`, `all-rights-reserved`, plus optional `terms` text.
  - `attestation`: optional detached signature over `manifest.json` +
    `source/` hashes (Ed25519, key id), so a hub or an app can verify the
    pack has not been altered since the maker signed it. Defined now,
    enforced by nobody yet.
  Readers that ignore them lose nothing renderable (Rule 1 preserves them
  through re-export).
- Register the media type (`audio/vnd.gloam.gvoice+zip`, IANA vendor tree)
  and document the UTI `fm.gloam.gvoice` and the Windows/Android
  associations in the spec.
- Fill the "Known gaps" list or move each item to an issue.

### 2. Reference reader + validator in Python (new repo `TinyTrashLabs/gvoice`)

- `pip install gvoice`: `gvoice.load(path) -> Pack` (manifest as a dataclass,
  `pack.reference(variant)` → `(wav_path, text)`, `pack.engine_assets(id)`),
  `gvoice.validate(path)` against the JSON Schema plus the rules in the spec
  (Rule 1 preservation is a library concern; the validator checks structure,
  required files, the `gvoice` version rule, path safety, loudness of
  `ref.wav` within tolerance of −17 LUFS).
- CLI: `gvoice validate x.gvoice`, `gvoice info x.gvoice`, `gvoice pack
  --audio ref.wav --text ref.txt --name "…" out.gvoice` (the on-ramp from the
  bare-WAV habit), `gvoice from-rvc` later.
- Tests use the four starter packs from the iOS repo as fixtures. MIT.
- A JavaScript reader (`@tinytrashlabs/gvoice`) follows once the Python one is
  used by a second project; not before.

### 3. Pull requests into the tools people already use (David: "put in the
todo list")

Order by likely acceptance and reach; each PR is "accept a `.gvoice` as the
reference input", using the Python reader or a 30-line inline loader:

1. **Voicebox** (the Mac TTS app David named) — first, as the flagship.
2. **mlx-audio** (Blaizzy) — the Swift and Python ports both; we already
   fork the Swift one.
3. **Fish Speech / OpenAudio**, **F5-TTS**, **Chatterbox**, **Dia** — each
   has a "reference audio + text" input; the PR maps `source[base]` onto it.
4. **Applio / RVC WebUI** — export side: "Save as .gvoice" for a reference
   clip, so the RVC crowd's habit gains a container.
5. **Hugging Face**: a `gvoice` tag and a library integration so packs get
   the "Use in …" button.

Each PR links the spec and the validator; a maintainer who can run
`gvoice validate` on the fixtures merges faster.

### 4. On-ramps and distribution

- Free converters (the CLI above; a web page on gloam.fm that packs a WAV +
  text into `.gvoice` in the browser, no upload).
- A public hub: `gloam.fm/voices` listing packs with consent and licence
  shown, download counts, and "Open in Gloam Voice Studio". Hosting is where
  paid tiers can live (private packs, larger packs, team libraries) without
  touching the open spec.
- Platform associations: the iOS and Mac apps already own the UTI; add the
  Android intent filter when there is an Android app, and Windows file
  association for the desktop.
- The Mac and iPhone apps remain the free reference viewer/editor; the
  editor shows every field the format carries (see the iOS editor work).

### 5. Money, without closing the format

- Apps: the High quality tier, the desktop studio, batch and dialogue
  features.
- Hub: hosting, private/team libraries, verified-creator packs (signed
  attestation), marketplace cut on paid packs where the licence allows.
- Services: hosted rendering from a `.gvoice` for people without the
  hardware; consent-verification API for platforms.
- The spec, the readers and the validator stay MIT; nothing above requires
  a closed format, and an open format is what makes the hub the default
  place to put a pack.

## Order of work

1. Consent/licence/attestation fields + JSON Schema in this repo (a day).
2. Python reader + validator + `pack` CLI (two to three days), fixtures
   from the iOS starter packs.
3. Voicebox PR, then mlx-audio.
4. Spec split and media-type registration alongside.
5. Hub and web converter after the first external merge.

## Not decided

- Whether `consent.statement` should be a fixed text per version (easier to
  reason about legally) or free text.
- Signing key management for `attestation` (per-app key vs per-user key).
