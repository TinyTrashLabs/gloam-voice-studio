# App Review notes

Paste-ready text for App Store Connect's "Notes" field on this build (limit:
4000 characters; this text is 3589). Plain text below the divider.

---

Gloam Voice Studio is a native, on-device voice cloning and text-to-speech studio for macOS. All speech synthesis and recognition run locally on the Mac using Apple's Speech framework and MLX-based models — no audio or generated speech is ever uploaded to us or any third party. These notes cover everything that touches the network, filesystem, or system permissions.

1. Local API + MCP server (network.server entitlement)
An optional local HTTP server exposes an OpenAI-compatible TTS/chat API and an MCP endpoint so tools on the same Mac (e.g. Claude Code) can drive the app. Off by default (Settings > API Server). When on, it binds to 127.0.0.1 only. A separate, explicitly-labeled toggle — "Allow other devices on this network" — is required to bind 0.0.0.0; enabling it auto-generates a bearer token required on every route except /health, and Settings shows the token plus a warning while LAN mode is active. This is a local convenience for users' own agents on their own LAN — there is no Gloam-run backend.

2. Network downloads are model weights only, no executable code
The app only fetches: (a) ML model weight files from huggingface.co, user-initiated from Settings > Models or an in-app prompt, and (b) audio clips for optional catalog voices from raw.githubusercontent.com when the user adds one. No executable code or scripts are downloaded — weights are data files consumed by the bundled ML runtime. The pocket-tts runtime library (sherpa-onnx, Apache-2.0) ships inside the signed app bundle; only its weights come from the network.

3. System-audio capture
The "capture from another app" reference-clip source uses Apple's public Core Audio process-tap API (AudioHardwareCreateProcessTap), gated to macOS 14.2+ and entirely user-initiated (a Record button). It captures only what the Mac is playing, so users can use audio they already have rights to. macOS prompts for the "Screen & System Audio Recording" permission on first use.

4. Microphone and speech recognition are on-device only
Microphone access records short reference clips for cloning; speech-recognition access transcribes clips and dictation via Apple's on-device Speech framework or a downloaded on-device Whisper model. Nothing recorded or transcribed leaves the Mac.

5. Voice catalog rights
The bundled voice ("Ava") and every catalog voice are CC0-licensed: the bundled voice and two others from the JL Corpus (tli725, CC0), the rest from the NabuCasa voice-datasets project (CC0). Each entry's license and attribution is listed in App/Resources/catalog.json. No likeness of a real, identifiable public figure is bundled or offered.

6. Consent before cloning, and provenance on exports
Before cloning any voice (record, capture, or import), a one-time consent sheet requires the user to confirm they have the right to use that voice before "I Understand" is enabled. Every exported WAV is tagged in its file metadata with a "Generated with Gloam Voice Studio" provenance comment.

7. Model weight licenses acknowledged before download
Two optional backends carry restrictive licenses: Fish S2-Pro (Fish Audio Research License) and SuperTonic (Open RAIL-M). For both, the app shows the license text and requires explicit acknowledgment before download; declining cancels. All other backends (Chatterbox, Chatterbox-Turbo, Qwen3-TTS, Kokoro, LuxTTS, pocket-tts) use MIT/Apache-2.0 weights with no gate. In every case weights are downloaded by the user, on their own Mac, directly from the publisher's HuggingFace listing — the app does not redistribute or bundle any of these weights.
