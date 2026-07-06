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
| `voice` | string | Voice slug from `list_voices`; omit for the backend's stock voice |
| `emotion` | string | `flat` \| `neutral` \| `warm` \| `excited` \| `hype` |

Synthesizes with the app's current Studio backend. Returns the WAV inline as
MCP `audio` content (when under 4 MB) plus a text line with the temp-file
path it was written to.

## Notes & limits

- Loopback only, no auth — same trust model as the rest of the local API.
- Stateless: no SSE stream, no sessions, no server-initiated messages.
  `GET /mcp` returns 405 by design.
- Synthesis shares the app's single-generation gate; a busy engine surfaces
  as a tool error rather than a hang.
