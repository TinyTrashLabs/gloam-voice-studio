# Privacy Policy — Gloam Voice Studio

_Last updated: 2026-08-26_

Gloam Voice Studio is a native macOS app. It does not collect, transmit, or sell
any personal data, and it has no analytics, telemetry, or crash-reporting SDKs.

## What stays on your Mac

- **Reference audio, generated takes, and voice packs** are stored in your
  sandboxed `~/Library/Application Support/Gloam Voice Studio/` container.
- **Speech-to-text and speech synthesis** run entirely on-device using Apple's
  Speech framework, WhisperKit, and MLX-based models. Audio never leaves your Mac.
- **Downloaded model weights** are stored in
  `~/Library/Application Support/Gloam Voice Studio/Models/` and are never
  uploaded anywhere.

Nothing above is sent to us or to any third party by the app itself.

## Network access

The app makes outbound network requests only when *you* choose to:

- **Downloading model weights** from HuggingFace (huggingface.co) — including,
  for the pocket-tts backend, a sherpa-onnx export of the weights hosted at a
  HuggingFace mirror — so the app can synthesize speech on-device. Each model
  is distributed by its own publisher under its own license (for example,
  Chatterbox weights are MIT; Fish S2-Pro weights are under the Fish Audio
  Research License and SuperTonic weights are under the BigScience Open
  RAIL-M license, and the app requires you to explicitly acknowledge the
  license before downloading either one). These downloads go directly from
  your Mac to HuggingFace — the app does not proxy, inspect, or retain a copy
  of what you download beyond your local cache. The pocket-tts backend's
  sherpa-onnx runtime library (Apache-2.0) ships inside the app bundle — it
  is not downloaded.
- **Downloading a catalog voice clip** (Create Voice → browse the catalog),
  for the entries that aren't already bundled with the app: audio comes
  directly from raw.githubusercontent.com (the NabuCasa `voice-datasets`
  project, CC0-licensed). The bundled starter voice ships in the app and
  needs no network access.
- **The optional local API + MCP server** (Settings → API Server) is off by
  default. When you turn it on, it binds to `127.0.0.1` (loopback) by
  default, so nothing outside your Mac can reach it. A second, separate
  opt-in — "Allow other devices on this network" — switches
  it to bind all network interfaces (`0.0.0.0`) instead; turning that on
  auto-generates a bearer token on your Mac, and every route except
  `/health` (including the microphone `listen` tool) then requires that
  token in the `Authorization` header. The Settings screen shows the token
  and warns you when LAN mode is active. Nothing sent to or received from
  this server is transmitted anywhere beyond the client that talks to it
  directly (e.g. an agent on your LAN).

## Data collection

We (TinyTrashLabs) do not operate any backend for this app, collect no usage
data, and have no way to see what you generate, import, or type. There is no
account system, so there is nothing to delete.

## Third-party licenses

Model weights downloaded through the app are governed by their own publishers'
licenses, not by Gloam Voice Studio's MIT license. See the in-app license
notice for Fish S2-Pro and SuperTonic, and the [README](README.md#license)
for a summary. Bundled and catalog voice clips are CC0-licensed (JL Corpus
and NabuCasa `voice-datasets`); see `App/Resources/catalog.json` for the
license and attribution of each entry.

## Contact

Questions about this policy or the app: support@gloam.fm. You can also file
an issue at https://github.com/TinyTrashLabs/gloam-voice-studio/issues.
