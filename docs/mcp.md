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

No arguments. Returns the library as JSON: `slug`, display `name`, and
`hasPersona` (whether a chat persona is set).

### `speak`

| Argument | Type | Notes |
| --- | --- | --- |
| `text` | string, required | What to say |
| `voice` | string | Voice slug from `list_voices`; omitted falls back to the Settings → API server default voice |
| `emotion` | string | `flat` \| `neutral` \| `warm` \| `excited` \| `hype` |

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

## Notes & limits

- Loopback only, no auth — same trust model as the rest of the local API.
- Stateless: no SSE stream, no sessions, no server-initiated messages.
  `GET /mcp` returns 405 by design.
- Synthesis shares the app's single-generation gate; a busy engine surfaces
  as a tool error rather than a hang.
