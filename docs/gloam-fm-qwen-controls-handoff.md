# Gloam Voice Studio Local API — Qwen3-TTS Controls

The local Studio API (`http://127.0.0.1:<port>`, loopback only, CORS-allowed for
`https://gloam.fm` and `https://gloam-app.pages.dev`) exposes Qwen3-TTS natural-language controls.
A client composes the spoken text **and** the delivery controls in a single `POST /v1/audio/speech`.

## POST /v1/audio/speech

| field | type | notes |
|---|---|---|
| `input` | string (required) | the text to speak |
| `model` | string | backend id (below); omitted → server default |
| `voice` | string? | voice-library slug to **clone** (Base/Fish) |
| `speaker` | string? | preset speaker name (**qwen3-custom** only) |
| `instruct` | string? | natural-language direction (Qwen) |
| `language` | string? | `auto` or one of the 10 languages |
| `temperature`, `top_p`, `top_k`, `repetition_penalty` | number? | sampling overrides (Qwen) |
| `response_format` | string | only `wav` |

Returns `audio/wav`. Errors are `{"detail": "..."}` with status 400/403/503.

## Model control matrix

| model | clone (`voice`) | `speaker` | `instruct` | `language` | sampling |
|---|---|---|---|---|---|
| `qwen3-0.6b` / `qwen3-1.7b` (Base) | optional | — | **✗** | yes | temp/top_p/top_k/rep |
| `qwen3-design` (VoiceDesign) | ✗ | — | **required** | yes | temp/top_p/top_k/rep |
| `qwen3-custom` (CustomVoice) | ✗ | **required** | optional | yes | temp/top_p/top_k/rep |
| `fish-s2-pro` | optional | — | ✗ | ✗ | temperature |
| `chatterbox-turbo` / `chatterbox` | required | — | ✗ | ✗ | exaggeration (regular only) |

**Base is clone-only.** The 0.6B/1.7B Base models are voice-cloning checkpoints (text + reference audio);
they do **not** take `instruct`. Any `instruct` sent with a Base model is **ignored** by the server (gated
off before the engine). Natural-language direction lives only on `qwen3-design` and `qwen3-custom`.

## Choosing a model

- **Direct a stable, known voice** (keep identity, change delivery) → `qwen3-custom` with `speaker` +
  `instruct`. Best fit for a persona you reuse across lines. Note: only `Ryan` and `Aiden` are English
  presets (both male); the rest are tuned for Chinese/Japanese/Korean.
- **Invent a voice from a description** → `qwen3-design` with `instruct` (no stable identity across calls —
  the description *is* the voice each time).
- **Clone a specific voice** → Base (`qwen3-0.6b` / `qwen3-1.7b`) with `voice`. No `instruct`; for emotional
  variation on a clone, use `fish-s2-pro` or `chatterbox` (Emotion presets), not Qwen Base.

## Writing `instruct`

Sweet spot ~15–40 words (1–3 sentences). Describe timbre, emotion, pace, accent. Examples:
- `"warm, slightly breathy, unhurried late-night radio host"`
- `"say it angrier and faster, clipped consonants, rising intensity toward the end"`
- `"elderly storyteller, gravelly and slow, with a knowing warmth"`

## Examples

Clone (Base):
```json
{"input":"Welcome back to the show.","model":"qwen3-1.7b","voice":"ava"}
```
Direct a preset (CustomVoice):
```json
{"input":"And now, the moment you've waited for.","model":"qwen3-custom",
 "speaker":"Dylan","instruct":"hyped arena announcer, big and punchy","language":"english"}
```
Design from scratch (VoiceDesign):
```json
{"input":"Once upon a time...","model":"qwen3-design",
 "instruct":"elderly storyteller, gravelly, slow and wise"}
```

## Preset speakers (qwen3-custom)

`Vivian, Serena, Uncle_Fu, Dylan, Eric, Ryan, Aiden, Ono_Anna, Sohee`.
An unknown/blank `speaker` on `qwen3-custom` returns **400** `"qwen3-custom requires a preset 'speaker'"`.
A blank `instruct` on `qwen3-design` returns **400** `"qwen3-design requires 'instruct'"`.

## Languages

`auto` (default, model auto-detects), `chinese`, `english`, `japanese`, `korean`, `german`, `french`,
`russian`, `portuguese`, `spanish`, `italian`. Values are lowercased server-side.

## Concurrency & 503

GPU work is serialized and **bounded** (1 running + 3 queued). Over capacity the API returns **503**
`{"detail":"server busy — try again"}`. Clients should retry with backoff (e.g. 250ms → 1s) on 503;
do not fire unbounded parallel requests.

## /health

`GET /health` reports `loadedBackends` — the resident backend id (one Qwen variant or other), so a
client can tell which model is hot before sending controls that only some models honor.
