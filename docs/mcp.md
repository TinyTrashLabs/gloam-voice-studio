# MCP Server

Gloam mounts a **Model Context Protocol** server at `/mcp` on the local API
server — any MCP-aware agent (Claude Code, Cursor, Windsurf, VS Code MCP
extensions, …) can browse your voice library and speak in your cloned voices.

Enable the API server in **Settings → API Server** first.

## Connect your agent

Streamable HTTP, stateless JSON — point the client at the endpoint:

```json
{
  "mcpServers": {
    "gloam": { "url": "http://127.0.0.1:8790/mcp" }
  }
}
```

For Claude Code: `claude mcp add --transport http gloam http://127.0.0.1:8790/mcp`

## Tools

### `list_voices`

No arguments. Returns the library as JSON: `slug`, display `name`, `id` and
`revision` (see Voice library in [api.md](api.md)), `persona` (the object, or
`null`; `hasPersona` is kept), `hasNotes`, `languages`, `variants` (take keys)
and `hasAvatar`.

### `speak`

| Argument | Type | Notes |
| --- | --- | --- |
| `text` | string, required | What to say |
| `voice` | string | Voice slug from `list_voices`; omitted falls back to the Settings → API server default voice |
| `emotion` | string | `flat` \| `neutral` \| `warm` \| `excited` \| `hype` |
| `instruct` | string | Delivery direction, on backends that take one; wins over the voice's own Direction |
| `language` | string | Language of `text` (`es`, `en-US`, …). A voice with a take in that language speaks from it, and the hint reaches the engine on backends that take one |

Synthesizes with the app's current Studio backend. Returns the WAV inline as
MCP `audio` content (when under 4 MB) plus a text line with the temp-file
path it was written to.

#### Voice resolution on cloning backends

Same contract as `POST /v1/audio/speech` (see [api.md](api.md)): on a cloning
backend this tool never synthesizes without a resolved reference — an
unusable voice is a tool error (`isError: true`), not a take in some invented
voice:

| Case | Result |
| --- | --- |
| `voice` names no library slug | tool error: `voice '<slug>' not found — call list_voices` |
| No `voice` and no Settings default voice | tool error: `<model> requires a 'voice' — call list_voices` |
| Voice exists but its `refText` is empty, on a backend that clones from the transcript too (`qwen3-*` Base, `lux-tts`) | tool error: `voice '<slug>' has an empty reference transcript — <model> cannot clone from it` |

Preset-voicepack backends (`kokoro`, `supertonic`, `qwen3-custom`) are
unaffected by this gate.

### Voice identity tools

These mirror the voice-library routes in [api.md](api.md) and share their rules. File arguments are
paths on this Mac that the app can read (`~` is expanded). Each returns the voice's meta as JSON
(`slug`, `id`, `revision`, …) unless noted.

| Tool | Arguments | Does |
| --- | --- | --- |
| `design_voice` | `name`, `instruct`, `script` (required); `language`, `persona` | `POST /voices/design`: renders `script` on `qwen3-design` from `instruct` and saves it |
| `create_voice` | `name`, `path` (WAV), `transcript` (all required) | Saves a recording as a voice |
| `update_voice` | `voice` (required); `name`, `persona` (object, or `null` to clear), `notes` (`""` clears) | `PATCH /voices/:slug` |
| `set_avatar` | `voice`, `path` (PNG or JPEG) | `PUT /voices/:slug/avatar` |
| `add_language_take` | `voice`, `language`, `path` (WAV), `transcript` | `POST /voices/:slug/variants`; returns the take's meta |
| `delete_voice` | `voice` | Deletes the voice and its takes. Returns `{"ok": true}` |
| `export_voice` | `voice`, `path` | Writes the `.gvoice` (`.gvoice` appended when `path` has no extension) |
| `import_voice` | `path`; `update` (bool) | Imports a `.gvoice`, keeping its `id` and `revision`; `update: true` replaces an older local version |

Failures are tool errors with the same text as the route's `detail`
(`voice 'ghost' not found`, `'path' is not a PNG or JPEG image`, …).

### `unload_models`

| Argument | Type | Notes |
| --- | --- | --- |
| `target` | string | `tts` \| `llm` \| `all` (default `all`) |

Evicts resident models to free memory — same semantics as
`POST /v1/models/unload` (see [api.md](api.md)): an in-flight render or chat
reply finishes first. Returns JSON text `{"unloaded": [<backend ids>],
"memGb": <number>}`; an unknown `target` is a tool error.

## Notes & limits

- Loopback by default, no auth — same trust model as the rest of the local
  API. Settings → API Server → **Allow other devices on this network** opens
  it to the LAN and requires a bearer token: `/mcp` is not exempt, so a LAN
  client must send `Authorization: Bearer <token>` (the token shown in
  Settings) or get `401`.
- Stateless: no SSE stream, no sessions, no server-initiated messages.
  `GET /mcp` returns 405 by design.
- Synthesis shares the app's single-generation gate; a busy engine surfaces
  as a tool error rather than a hang.
