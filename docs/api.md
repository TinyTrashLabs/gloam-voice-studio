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
| `stream` | bool | `true` returns a streaming WAV — see "Streaming" below |
| `stream_format` | string | `audio` (same as `stream: true`); `sse` is a 400 |
| `first_chunk_frames` | int | `qwen3-0.6b-ane` streaming only: frames (1-12, 80 ms each) in the first chunk; the chunks after it grow back to 12. `4` puts the first audio out about 0.5 s sooner (0.44 s vs 0.93 s measured) but leaves less audio buffered ahead of playback, so it only plays without gaps while the render stays under real time. Same audio up to Neural Engine rounding. Omitted = 12 |
| `fx` | string or object | Character-voice effects. Either a built-in preset name (`"demon"`, `"glitch"`, `"whisper"`) or an inline preset object with the same shape as the bundled JSON. Omitted means unprocessed audio. An unknown name returns 400 rather than silently falling back. |

Backend gating errors are 400s (e.g. `qwen3-design requires 'instruct'`).
Fish returns `403` with the license notice until acknowledged in-app.

#### Streaming (`stream: true`)

`"stream": true` (or `"stream_format": "audio"`; `"sse"` is a 400) returns a **streaming WAV**
instead of one finished file: a 44-byte header with `0xFFFFFFFF` RIFF/data sizes (the
convention players accept for an open-ended stream), then mono PCM16 little-endian at the
backend's sample rate, written as it is rendered. Read the body incrementally and play from the first
bytes; a client that needs a normal WAV should leave `stream` off.

```bash
curl -sN http://127.0.0.1:8790/v1/audio/speech \
  -H 'content-type: application/json' \
  -d '{"input": "You should not have come.", "model": "qwen3-0.6b-ane", "voice": "demon-titan", "stream": true}' \
  -o line.wav        # first audio ~1 s after the request on qwen3-0.6b-ane
```

- Native streaming: `qwen3-0.6b-ane` (one chunk per 0.96 s), and the MLX Qwen Base models
  (`qwen3-0.6b`, `qwen3-0.6b-mobile`, `qwen3-1.7b`; one chunk per 1.0 s). Other backends, and requests
  with `speed` != 1 or `fx` (whole-take effects), render whole and arrive as one piece.
- Errors that are known before the first audio (unknown voice, model not installed, busy) are ordinary
  4xx/5xx statuses. A failure after the headers cut the stream.
- The request takes the same gate slot as a whole-take request and interleaves with a streamed chat
  reply the same way (it runs between the reply's token pulls), so it cannot deadlock against one.
  One exception: `qwen3-0.6b-ane` renders on its own lane (its own engine and gate), so it overlaps
  a GPU request, and a streamed chat reply, instead of queueing behind them. Two requests for the same
  lane (GPU, or Neural Engine) still run one at a time, up to the gate's queue limit.
- The loudness trim of the voice is applied per chunk; leading silence is trimmed on `qwen3-0.6b-ane` only
  (to 0.05 s) and internal pauses are not shortened on a stream.

#### `qwen3-0.6b-ane` (Neural Engine)

Qwen3-TTS 0.6B on the Apple Neural Engine (macOS 15+), no GPU, so it runs beside a GPU-bound LLM.
Clone-only: `voice` is required, and the voice needs a transcript. A voice's `source/` reference up to
20 s is used as is; a longer one needs its `lux-tts` window (`engines/lux-tts`, audio + transcript of
the window) or the request is a 400. The model set is not on Hugging Face yet: put it in
`~/Library/Application Support/GloamVoiceStudio/Models/qwen3-0.6b-ane/` (or point
`GLOAM_QWEN_ANE_MODELS` / the `qwenANEModelsPath` default at it); without it the request is a `503`
that names the expected path. The first request after launch can spend tens of seconds compiling the
Core ML graphs for the ANE (cached by the system afterwards), plus a few seconds preparing the voice
(cached on disk). Studio loads the model and prepares its default (or selected) voice in the background
at launch and when the server starts (turn off with `defaults write <bundle id> prewarmNeuralSpeech -bool NO`),
and `POST /v1/audio/warmup` does the same for the voice a client is about to use. Each voice's prompt
rows (and, for a long reference transcript, the talker's key/value prefix) are kept, four voices at a time.

### `POST /v1/audio/warmup`

Get a model and a voice ready before the first line: `{"model": "qwen3-0.6b-ane", "voice": "demon-titan"}`
(both optional, falling back to the Settings defaults like `/v1/audio/speech`). Returns
`{"model", "voice", "seconds"}` when ready. On `qwen3-0.6b-ane` it loads the Core ML models, prepares the
voice and runs a few frames through every graph, so the next request starts at steady-state speed; on the
MLX Qwen clone models it loads the weights and renders one short word (kernel compile, reference context).
Other backends only load. It queues behind a render on the same lane, never behind the other lane. 400 for
an unknown voice or a clone model with no voice, 503 for a model that is not installed.

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
| `cfg_scale` | number | Classifier-free guidance. 6 is the Dia2 default; lower drifts off the reference, higher gets clipped and shouty |
| `text_temperature`, `text_top_k` | number | Sampler over the text/action state machine — what gets said, and when the speaker changes |
| `audio_temperature`, `audio_top_k` | number | Sampler over the audio codebooks — how it is said |
| `temperature`, `top_k` | number | Legacy aliases for `audio_temperature` / `audio_top_k`; the explicit fields win when both are sent |
| `max_padding` | int | Frames of silence the model may pad a turn with before moving on |
| `keep_prefix_audio` | bool | Return the conditioning clips ahead of the take. For hearing what the model was given while debugging — not for anything you ship |

Errors are 400s: a speaker other than 1 or 2, an empty script, a `(tag)` the
model does not know (it would be read aloud), or a `voices` entry naming no
library slug. A voice that exists but has no recorded reference is **not** an
error — that speaker simply conditions nothing.

Because Dia2 cannot condition speaker 2 alone, a missing first prefix drops the
second as well rather than misassigning it.

One request is one Dia2 pass, and a pass has three ceilings: it stops hard at
~118s of audio, the two speakers' identities merge from ~95s, and the
similarity to the reference starts falling from ~45s. Keep a request under
about 45 seconds of speech and split longer material into separate requests at
a speaker change — each request re-conditions from the reference, so splitting
resets the drift entirely. Studio's Dialogue mode does this planning for you;
over HTTP it is the client's job.

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
