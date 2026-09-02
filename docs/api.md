# HTTP API Reference

Enable the server in **Settings → API Server**. It binds to
`http://127.0.0.1:8790` (port configurable), loopback by default, no
authentication. **Allow other devices on this network** in the same settings
pane rebinds to `0.0.0.0` so other machines can reach the API and MCP, and
requires a bearer token: every route except `/health` needs an
`Authorization: Bearer <token>` header carrying the token shown in Settings
(generated once, the first time LAN mode is turned on), or the request gets
`401 {"error": "unauthorized"}`. Loopback-only mode stays unauthenticated.
Errors are FastAPI-shaped: `{"detail": "<message>"}` with an appropriate
status. One generation runs at a time; excess requests queue (up to 3) and
then get `503 server busy`.

## Speech

### `POST /v1/audio/speech`

OpenAI-compatible, with extra fields for voices and expressiveness. Returns
`audio/wav`.

```bash
curl -s http://127.0.0.1:8790/v1/audio/speech \
  -H 'content-type: application/json' \
  -d '{"input": "Hello from Gloam.", "voice": "midge", "emotion": "excited"}' \
  -o hello.wav
```

| Field | Type | Notes |
| --- | --- | --- |
| `input` | string, required | Text to speak |
| `model` | string | Backend id (`qwen3-1.7b`, `chatterbox-turbo`, `fish-s2-pro`, …); defaults to the app's Studio backend |
| `voice` | string | Library voice slug. With `emotion`, an acted `<voice>-<emotion>` variant clip is used when it exists. Required on cloning backends — see below |
| `emotion` | string | `flat` \| `neutral` \| `warm` \| `excited` \| `hype` — drives the model's emotion knob, or selects an acted variant |
| `exaggeration` | float 0–1 | Chatterbox emotion knob override |
| `speed` | float | Playback-speed multiplier (time-domain; extremes shift pitch) |
| `instruct` | string | Natural-language voice direction — required by `qwen3-design`, optional on `qwen3-custom` |
| `speaker` | string | Preset speaker — required by `qwen3-custom` |
| `language` | string | Qwen language hint |
| `temperature`, `top_p`, `top_k`, `repetition_penalty` | number | Sampler overrides where the backend supports them |
| `response_format` | string | Only `wav` |

Backend gating errors are 400s (e.g. `qwen3-design requires 'instruct'`).
Fish returns `403` with the license notice until acknowledged in-app.

### `POST /v1/audio/dialogue`

Two voices in one pass, on the `dia2` backend. Returns `audio/wav`. This is how
an off-machine client (Gloam Radio's two-host segments) drives a conversation
rather than stitching two single-voice takes together.

```bash
curl -s http://127.0.0.1:8790/v1/audio/dialogue \
  -H 'content-type: application/json' \
  -d '{"turns": [{"speaker": 1, "text": "Evening. (laughs)"},
                 {"speaker": 2, "text": "Evening yourself."}],
       "voices": ["midge", "wizard"]}' \
  -o exchange.wav
```

| Field | Type | Notes |
| --- | --- | --- |
| `turns` | array, required | `{"speaker": 1\|2, "text": "…"}` in order. Dia2 speaks exactly two speakers |
| `voices` | array of string\|null | Voice slug per speaker index. Omit, or send `null`, to generate unconditioned — the voice then varies between requests |
| `stream` | bool | Stream the WAV as it generates (open-ended header, then PCM frames) instead of buffering the whole take |
| `temperature`, `top_k`, `cfg_scale` | number | Sampler overrides |

Errors are 400s: a speaker other than 1 or 2, an empty script, a `(tag)` the
model does not know (it would be read aloud), or a `voices` entry naming no
library slug. A voice that exists but has no recorded reference is **not** an
error — that speaker simply conditions nothing.

Because Dia2 cannot condition speaker 2 alone, a missing first prefix drops the
second as well rather than misassigning it.

### `GET /v1/audio/dialogue/tags`

The nonverbal tags the loaded Dia2 model actually knows, e.g.
`{"tags": ["(laughs)", "(sighs)", …]}`. Offer these as chips: free text in
brackets is spoken aloud, not performed. Loads the model if it is not resident.

### Voice resolution on cloning backends

On a cloning backend (`qwen3-0.6b`, `qwen3-1.7b`, `chatterbox`,
`chatterbox-turbo`, `fish-s2-pro`, `lux-tts`, `pocket-tts`) the endpoint never
synthesizes without a resolved reference — an unusable voice is a logged `400`,
not a take in some invented voice:

| Case | Result |
| --- | --- |
| `voice` names no library slug | `400 voice '<slug>' not found` |
| No `voice` and no Settings default voice | `400 <model> requires a 'voice'` |
| Voice exists but its `refText` is empty, on a backend that clones from the transcript too (`qwen3-*` Base, `lux-tts`) | `400 voice '<slug>' has an empty reference transcript — <model> cannot clone from it` |
| `emotion` given but no `<voice>-<emotion>` clip exists | Falls back to the base voice (unchanged) |

Preset-voicepack backends (`kokoro`, `supertonic`, `qwen3-custom`) are
unaffected: their `voice`/`speaker` field is a voicepack name, not a library
slug, and an unknown one still falls back to the backend's default preset.

## Chat

### `POST /v1/chat/completions`

OpenAI-shaped, single-shot (no streaming). Uses the on-device LLM configured
in the chat panel; `503` when none is configured.

```bash
curl -s http://127.0.0.1:8790/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"messages": [{"role": "user", "content": "Say hi in one sentence."}]}'
```

`model` selects an LLM backend id (`qwen3-1.7b-text`, `gemma4-e2b`, …).
Response carries `choices[0].message.content` plus prompt/completion token
usage.

## Voice library

| Route | Description |
| --- | --- |
| `GET /voices` | List voices (`{"voices": [VoiceMeta…]}`) |
| `POST /voices` | Create: `{"name", "refAudio": <base64 wav>, "refText"?}` |
| `PATCH /voices/:slug` | Update name/reference/transcript (rename re-slugs) |
| `DELETE /voices/:slug` | Delete a voice |
| `GET /voices/:slug/ref.wav` | The reference clip |
| `GET /voices/:slug/export` | `.gvoice` pack (zip) |
| `POST /voices/import` | `{"data": <base64 .gvoice>}` |

## Health

`GET /health` → engine/backend status, resident models, app memory.

## MCP

`POST /mcp` speaks the Model Context Protocol — see [mcp.md](mcp.md).
