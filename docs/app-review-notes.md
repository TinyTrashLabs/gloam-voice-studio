# App Review notes

Paste-ready text for App Store Connect's "Notes" field on this build. Plain
text below the divider — no markdown needed in App Store Connect itself.

---

Gloam Voice Studio is a native, on-device voice cloning and text-to-speech
studio for macOS. All speech synthesis and speech recognition run locally on
the Mac using Apple's Speech framework and MLX-based models — no audio or
generated speech is ever uploaded to us or to any third party. The notes
below cover the parts of the app that touch the network, the filesystem, or
system permissions, so review can verify each one against the running app.

1. Local API + MCP server (network.server entitlement)
The app includes an optional local HTTP server that exposes an
OpenAI-compatible text-to-speech/chat API and an MCP endpoint, so tools like
Claude Code or a companion app on the same Mac can drive the app
programmatically. It is off by default (Settings → API Server). When turned
on, it binds to 127.0.0.1 (loopback) only, so nothing outside the Mac can
reach it. A separate, explicitly-labeled toggle — "Allow other devices on
this network" — is required to bind all interfaces
(0.0.0.0) instead. Turning that second toggle on auto-generates a bearer
token on the Mac and requires it on every route except /health; Settings
displays the token and an on-screen warning while LAN mode is active. This
is a local convenience feature for people running their own agents or a
companion app on their own LAN — it has no relationship to any Gloam-run
backend.

2. Network downloads are model weights only, no executable code
The only things the app fetches from the network are: (a) machine-learning
model weight files from huggingface.co, initiated by the user from
Settings → Models or an in-app download prompt, and (b) audio clips for a
small number of optional catalog voices, fetched from
raw.githubusercontent.com when the user picks one to add to their library.
No executable code, scripts, or binaries are downloaded — weights are data
files consumed by the bundled ML runtime. The pocket-tts backend's runtime
library (sherpa-onnx, Apache-2.0) ships inside the signed app bundle; only
its weight files come from the network.

3. System-audio capture
The "capture from another app" reference-clip source uses Apple's public
Core Audio process-tap API (AudioHardwareCreateProcessTap), gated to
macOS 14.2+ — on earlier macOS this option is not offered. It is entirely
user-initiated (a Record button the user presses) and captures only what
the Mac is currently playing, so the user can use audio they already have
permission to use as a voice reference. macOS itself prompts for the
"Screen & System Audio Recording" permission on first use.

4. Microphone and speech recognition are on-device only
The app requests microphone access to record short reference clips for
voice cloning, and speech-recognition access to transcribe those clips
(and any dictation) using Apple's on-device Speech framework or a
downloaded on-device Whisper model. Recorded and transcribed audio never
leaves the Mac; there is no server-side transcription or analysis.

5. Voice catalog rights
The one voice bundled with the app ("Ava") and every catalog voice offered
in Create Voice → browse the catalog are CC0-licensed. The bundled voice
and two others come from the JL Corpus (tli725, CC0); the remaining
catalog entries come from the NabuCasa voice-datasets project (CC0). Every
entry's exact license and attribution is listed in
App/Resources/catalog.json, and only public-domain (CC0) recordings are
included — no likeness of a real, identifiable public figure is bundled or
offered.

6. Consent before cloning, and provenance on exports
Before a user can clone any voice (record their own, capture from another
app, or import a reference clip), a one-time consent sheet requires them to
confirm they have the right to use that voice — their own, or a speaker who
gave permission — before the "I Understand" button is enabled to proceed.
Every WAV file the app exports (Studio takes, script exports, chat replies)
is tagged in its file metadata with a "Generated with Gloam Voice Studio"
provenance comment.

7. Model weight licenses acknowledged before download
Two of the optional synthesis backends carry restrictive licenses:
Fish S2-Pro (Fish Audio Research License — personal/research use) and
SuperTonic (BigScience Open RAIL-M — use-based restrictions). For both, the
app shows the license text in a sheet and requires the user to explicitly
acknowledge it before the weights are downloaded; declining cancels the
download. All other backends (Chatterbox, Chatterbox-Turbo, Qwen3-TTS,
Kokoro, LuxTTS, pocket-tts) use permissively licensed weights (MIT or
Apache-2.0) with no ack gate. In every case, the weights are downloaded by
the user, on their own Mac, directly from the publisher's HuggingFace
listing — the app does not redistribute or bundle any of these weights.
