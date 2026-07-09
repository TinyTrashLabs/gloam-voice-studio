# App Guide

Gloam Voice Studio has three sections, switched in the sidebar:
**Studio | Create Voice | Chat**. The sidebar's voice library is shared by all
three.

## Voices and the library

A **voice** is a reference clip + transcript (and optionally a chat persona and
acted emotion variants). Voices live in the sidebar:

- **▶** previews the reference clip; **✎** opens the voice in Create Voice's
  edit mode; **⋯** has export (`.gvoice` pack), emotion variants, and delete.
- Voices with acted variants fold their `<voice>-<emotion>` clips under a
  disclosure with a count badge.
- **Renaming is safe**: chats, emotion variants, and selection follow the
  voice automatically.
- Import `.gvoice` packs or browse the free voice catalog from the sidebar
  header buttons.

## Studio

Write a line (or switch to Script mode for multi-line batches), pick a voice
and a model in the toolbar chip, and Generate. Emotion chips, speed, and
model-specific knobs (exaggeration, temperature, direction) appear per
backend. Takes land in the History drawer (⌘Y) for replay, A/B, and export.

**Models** (one TTS resident at a time, managed from the toolbar chip):

- `qwen3-0.6b` / `qwen3-1.7b` — multilingual voice cloning
- `qwen3-design` — invent a voice from a text description (Create Voice only)
- `qwen3-custom` — direct a preset speaker with natural-language instructions
- `chatterbox` / `chatterbox-turbo` — expressive cloning; turbo is the fast one
- `fish-s2-pro` — quality-first cloning (research/non-commercial license;
  acknowledge in Settings)

## Create Voice

One page, two paths, switched at the top:

- **From a description** — the Voice Foundry: describe timbre/age/accent/mood,
  audition `qwen3-design` candidates until one clicks, save it to the library.
- **From a recording** — record, or drop audio files. The **source picker in
  the recorder** chooses **Microphone** or **System Audio** (macOS 14.2+;
  records whatever the Mac is playing — Gloam's own audio is excluded; the OS
  asks for System Audio Recording permission on first use). Multiple clips
  combine into one steadier reference; transcripts auto-fill via on-device
  Whisper and stay editable.

Only clone voices you have the right to use. After saving, the variants panel
offers acted emotion bakes (`<voice>-excited`, …) used by Studio's emotion
chips and the API's `emotion` parameter.

The panel's **Record a take** row is the second way to get emotion variants:
read a fixed guided script in character (each emotion shows its own delivery
note), and the recording is saved as `<voice>-<emotion>`. Recorded takes are
the **only** way to get emotional range on `chatterbox-turbo` — it has no
runtime emotion knob, so the reference clip itself carries the emotion.
Baking stays the recommended path when a `fish-s2-pro` or `chatterbox`
render is good enough.

## Chat

Pick a voice, type (or push-to-talk with the mic button), and the voice
answers out loud — speech starts while the reply is still generating, and the
transcript karaoke-highlights the word being spoken.

**Inspector panels:**

- **MODEL** — local LLM picker (qwen3 / gemma-4 families) with
  download/load/unload/delete, context window (4k–32k), and a **Reasoning**
  control for models that support it (reasoning shows collapsed in the
  transcript and is never spoken).
- **VOICE** — chat's own TTS engine, independent of the Studio backend, with
  **measured speed labels** (`· 1.5× realtime`): above 1× means synthesis
  outruns playback — gapless speech. "Render in parallel with text" (default
  on) runs the voice on a second engine concurrent with token generation;
  turn it off to fall back to strictly serialized rendering.
- **PERSONA** — per-voice system prompt + optional greeting. Stored on the
  voice, travels with `.gvoice` exports.
- **SAMPLING / ADVANCED** — temperature and max tokens up front; topP/topK/
  minP/repetition/presence/frequency behind the disclosure, with reset.

**Conversation niceties:** rename/delete via right-click; retry button on
failed replies; replay any reply from its speaker icon — instant after the
first play, since reply audio is saved automatically; the chevron beside
the speaker icon lists every saved take, lets you regenerate the reply with
a different model (including `fish-s2-pro`, not offered in the live chat
picker since it's too slow for real-time — regenerate has no such
constraint), and export the current take as a WAV; image attachment for
vision models (gemma-4); dictating silences speech so replies can't
transcribe themselves into your draft.

## Settings

- **Models** — download/delete weights, Fish license acknowledgement, and
  **"Keep models loaded under memory pressure"** (default on: models survive
  routine pressure warnings so chat never cold-starts; critical pressure still
  evicts).
- **API Server** — enable the local HTTP server (default port 8790), watch the
  request console. See the [API reference](api.md) and [MCP](mcp.md).
- **Whisper** — dictation/transcription model choice.
