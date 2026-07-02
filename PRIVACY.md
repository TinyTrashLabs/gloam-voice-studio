# Privacy Policy — Gloam Voice Studio

_Last updated: 2026-07-01_

Gloam Voice Studio is a native macOS app. It does not collect, transmit, or sell
any personal data, and it has no analytics, telemetry, or crash-reporting SDKs.

## What stays on your Mac

- **Reference audio, generated takes, and voice packs** are stored in your
  sandboxed `~/Library/Application Support/Gloam Voice Studio/` container.
- **Speech-to-text and speech synthesis** run entirely on-device using Apple's
  Speech framework, WhisperKit, and MLX-based models. Audio never leaves your Mac.
- **Downloaded model weights** are cached in `~/Library/Caches/Models/` and are
  never uploaded anywhere.

Nothing above is sent to us or to any third party by the app itself.

## Network access

The app makes outbound network requests only when *you* choose to:

- **Downloading model weights** from HuggingFace (huggingface.co), so the app
  can synthesize speech on-device. Each model is distributed by its own
  publisher under its own license (for example, Chatterbox weights are MIT;
  Fish S2-Pro weights are under the Fish Audio Research License, and the app
  requires you to explicitly acknowledge that license before downloading it).
  These downloads go directly from your Mac to HuggingFace — the app does not
  proxy, inspect, or retain a copy of what you download beyond your local cache.
- **The optional local API server** (Settings → API Server) binds to
  `127.0.0.1` only. It never accepts connections from outside your Mac, and it
  is off by default.

## Data collection

We (TinyTrashLabs) do not operate any backend for this app, collect no usage
data, and have no way to see what you generate, import, or type. There is no
account system, so there is nothing to delete.

## Third-party licenses

Model weights downloaded through the app are governed by their own publishers'
licenses, not by Gloam Voice Studio's MIT license. See the in-app license
notice for Fish S2-Pro, and the [README](README.md#license) for a summary.

## Contact

Questions about this policy or the app can be filed as an issue at
https://github.com/TinyTrashLabs/gloam-voice-studio/issues.
