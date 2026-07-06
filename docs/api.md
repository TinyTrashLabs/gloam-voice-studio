# HTTP API Reference

Enable the server in **Settings → API Server**. It binds to
`http://127.0.0.1:8790` (port configurable), loopback only, no authentication.
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
| `voice` | string | Library voice slug. With `emotion`, an acted `<voice>-<emotion>` variant clip is used when it exists |
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
