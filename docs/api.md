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
| `emotion` | string | `flat` \| `neutral` \| `warm` \| `excited` \| `hype` — drives the model's emotion knob, or selects an acted variant. On `breeze-tts-2` (no variant found) it is phrased into the instruction after `instruct` |
| `exaggeration` | float 0–1 | Chatterbox emotion knob override |
| `speed` | float | Playback-speed multiplier (time-domain; extremes shift pitch) |
| `instruct` | string | Natural-language voice direction — required by `qwen3-design`, optional on `qwen3-custom` and `breeze-tts-2`. On `breeze-tts-2` it is honored *with* `voice` too (directs the cloned voice), and on its own it designs a voice. Omitted with a `voice` that has its own Breeze Direction (`engines/breeze-tts-2/voice.json`), that Direction and its CFG are used; send `"instruct": ""` for none |
| `speaker` | string | Preset speaker — required by `qwen3-custom` |
| `language` | string | Language of `input` (`es`, `es-MX`, `english`, …) on the backends that take one (`qwen3-*`, including `qwen3-0.6b-ane`; nil/`auto` = detect). A cloning request whose `voice` has a take tagged with that language (see `POST /voices/:slug/variants`) renders from that take's reference and transcript, unless `emotion` already picked a take |
| `temperature`, `top_p`, `top_k`, `repetition_penalty` | number | Sampler overrides where the backend supports them |
| `cfg_scale` | number | Classifier-free guidance, clamped to 1–8. `breeze-tts-2`: default 4, 1 = off, and it acts only when there is an `instruct` or `emotion` to follow. `dia2` (single-voice requests): overrides its default guidance. Ignored by other backends |
| `reference_guidance` | number | `breeze-tts-2` identity strength: extra guidance toward the reference voice, clamped to 1–4 (1 = off). Only acts on a cloned take; with an `instruct` it uses upstream's dual guidance (reference and instruction weighted separately). Costs an extra model pass per frame. Ignored by other backends |
| `seed` | int | `breeze-tts-2`: fixed sampling seed. The same seed, text, voice and settings give the same take. Omitted means fresh randomness. Ignored by other backends |
| `response_format` | string | Only `wav` |
| `stream` | bool | `true` returns a streaming WAV — see "Streaming" below |
| `stream_format` | string | `audio` (same as `stream: true`); `sse` is a 400 |
| `first_chunk_frames` | int | `qwen3-0.6b-ane` streaming only: frames (1-12, 80 ms each) in the first chunk; the chunks after it grow back to 12. `4` puts the first audio out about 0.5 s sooner (0.44 s vs 0.93 s measured) but leaves less audio buffered ahead of playback, so it only plays without gaps while the render stays under real time. Same audio up to Neural Engine rounding. Omitted = 12 |
| `fx` | string or object | Character-voice effects. Either a built-in preset name (`"demon"`, `"glitch"`, `"whisper"`) or an inline preset object with the same shape as the bundled JSON. Omitted means unprocessed audio. An unknown name returns 400 rather than silently falling back. |

Backend gating errors are 400s (e.g. `qwen3-design requires 'instruct'`).
Fish, Breeze TTS 2 and SuperTonic each return `403` with their own license
notice until acknowledged in-app.

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
`chatterbox-turbo`, `fish-s2-pro`, `breeze-tts-2`, `lux-tts`, `pocket-tts`) the
endpoint never synthesizes without a resolved reference — an unusable voice is a
logged `400`, not a take in some invented voice. The one exception is a backend
that also designs from `instruct` (`breeze-tts-2`): a non-blank `instruct` with
no `voice` is voice *design* — the caller described the speaker. It is allowed,
and it designs even when a Settings default voice is set (the default is not
cloned in its place); send `voice` as well to direct a clone instead:

| Case | Result |
| --- | --- |
| `voice` names no library slug | `400 voice '<slug>' not found` |
| No `voice` and no Settings default voice | `400 <model> requires a 'voice'` (unless `instruct` is set on `breeze-tts-2`) |
| Voice exists but its `refText` is empty, on a backend that clones from the transcript too (`qwen3-*` Base, `breeze-tts-2`, `lux-tts`) | `400 voice '<slug>' has an empty reference transcript — <model> cannot clone from it` |
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
| `GET /voices` | List voices (`{"voices": [VoiceMeta…]}`). Each row is the stored meta (`name`, `slug`, `refText`, `persona`, `notes`, `language`, `id`, `revision`, …) plus `hasSource`, `engines`, `variants` (take keys), `languages` (own + takes') and `hasAvatar` |
| `POST /voices` | Create: `{"name", "refAudio": <base64 wav>, "refText"?}` |
| `POST /voices/design` | Design and keep: `{"name", "instruct", "script", "language"?, "persona"?}` renders `script` on `qwen3-design` from `instruct` and saves the audio + script as a new voice; returns its meta. `409` for a taken name (before rendering), `400` for a blank field. Takes a slot in the generation queue (`503` when busy) |
| `PATCH /voices/:slug` | Update `name` (re-slugs), `refAudio`, `refText`, `notes` (`""` clears) and `persona` (a full object `{systemPrompt, greeting?, tagline?, catchphrases?, color?, language?}` sets it, `null` clears it, absent leaves it). Returns the new meta |
| `DELETE /voices/:slug` | Delete a voice and its takes |
| `GET /voices/:slug/ref.wav` | The reference clip |
| `GET /voices/:slug/avatar` | The voice's picture, `image/png`, 256x256 (`404` when it has none) |
| `PUT /voices/:slug/avatar` | Raw PNG or JPEG body (up to 16 MB), cropped and resized to the pack's 256x256 PNG; returns the meta. `400` for anything else |
| `DELETE /voices/:slug/avatar` | Remove the picture |
| `POST /voices/:slug/variants` | Add a language take: `{"language": "es", "refAudio": <base64 wav>, "refText"}`. Saved as the take `<slug>-<language>` tagged with its language (the same `source[variant].language` packs carry); an existing take for that language is replaced. Returns the take's meta. `400` for a bad tag, bad base64 or empty `refText` |
| `GET /voices/:slug/export` | `.gvoice` pack (zip), carrying `id` and `revision` |
| `POST /voices/import` | `{"data": <base64 .gvoice>, "update"?: bool}`; returns the meta |

**Identity.** A voice made here gets a UUID `id` and `revision: 1`. `id` never changes; `revision`
goes up by one on every edit of the voice's audio, transcript, name, notes, persona, avatar or
language takes (a patch that changes nothing does not bump it). Export writes both into the pack's
manifest, and import restores them, so a voice keeps its identity across machines. When the library
already holds a voice with the pack's `id`, the import is a copy and the copy gets a new `id`; with
`"update": true` and a pack whose `revision` is higher, the local voice is replaced instead. An
import never overwrites a voice at the same slug (`409`) except through that update path.

## Models

### `POST /v1/models/unload`

Frees memory by evicting resident models. The body is optional:

```bash
curl -s http://127.0.0.1:8790/v1/models/unload \
  -H 'content-type: application/json' \
  -d '{"target": "tts"}'
```

| `target` | Evicts | Waits for |
| --- | --- | --- |
| `tts` | the speech model | an in-flight speech/dialogue render (not an active chat stream) |
| `llm` | the language model | every model request already queued, so an in-flight `/v1/chat/completions` reply (streamed or not) finishes first |
| `all` (default) | both, LLM first | both of the above |

Response: `{"unloaded": ["qwen3-1.7b-text", "qwen3-design"], "memGb": 3.12}`.
`unloaded` lists the backend ids actually evicted (empty when nothing of that
kind was resident); `memGb` is the same figure `/health` reports — the
process's *peak* resident memory, so it does not fall after an unload. An unknown
`target` is `400 {"detail": "target must be one of: tts, llm, all"}`. The next
request that needs a model reloads it on demand. Does not take a slot in the
generation queue, so it never gets `503 server busy`.

## Health

`GET /health` → engine/backend status, resident models, app memory.

## MCP

`POST /mcp` speaks the Model Context Protocol — see [mcp.md](mcp.md).
