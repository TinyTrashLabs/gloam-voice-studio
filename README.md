# Gloam Voice Studio

Native macOS voice cloning studio for Apple Silicon. Fast, private synthesis on-device using MLX with optional OpenAI-compatible API server.

## Overview

Gloam Voice Studio is a SwiftUI macOS app that clones voices using optimized ML models on Apple Silicon (M-series chips). All processing happens locally—no audio leaves your Mac. Several synthesis backends are available:

- **Chatterbox** — Fast, lightweight real-time factor (RTF) ~2–3×
- **Chatterbox-Turbo** — Higher quality, RTF ~1–2×
- **Fish S2-Pro** — Premium quality, research/personal use license
- **Qwen3-TTS** — A multilingual family: clone a voice (`qwen3-0.6b` / `qwen3-1.7b`), invent one from a natural-language description (`qwen3-design`), or direct a preset speaker with natural-language instructions (`qwen3-custom`). See [`docs/gloam-fm-qwen-controls-handoff.md`](docs/gloam-fm-qwen-controls-handoff.md) for the API control surface.

Chatterbox and Chatterbox-Turbo use MIT-licensed weights. Fish S2-Pro weights are under the Fish Audio Research License; the app downloads them from HuggingFace under your own acceptance of the license terms.

## Features

- **Voice Import & Export** — Create, edit, and export voices as `.gvoice` packs (interchange format with the Python sibling project).
- **Reference Audio & Transcription** — Record or drop reference clips; optional transcript hints improve quality.
- **Emotion & Speed Control** — Generate with five emotion variants (flat, neutral, warm, excited, hype); adjust playback speed 0.5× to 2.0×.
- **A/B Variants** — Generate two takes side-by-side; compare waveforms and playback.
- **History** — Browse all generated takes with metadata (backend, voice, emotion, RTF). Play or delete entries. Reuse any entry to repopulate the studio editor.
- **Model Downloads** — Download weights in-app with progress indication. Automatic preflight storage check.
- **Local API Server** — Optional OpenAI-compatible HTTP server (loopback-only, port 8790 by default) for programmatic access.
- **Sandbox** — Minimal entitlements; data lives in Application Support and Caches directories.
- **Speech-to-text, fully on-device** — reference clips auto-transcribe when you
  record or drop them, every editor has a dictate button, and File → Transcribe
  Audio… (⇧⌘T) converts any audio file to text. Apple's built-in recognizer by
  default; downloadable Whisper models (Settings → Speech) for harder audio.
  Audio never leaves the Mac.

### Voice Lab

- **Script sessions** — Multi-line script editor with per-line voice and emotion direction; lines can be reordered at will.
- **Persistent takes** — Each generated take is saved to disk (WAV + JSON session); takes survive app relaunches and are browsable per line.
- **Batch generation** — Generate all lines in a script session serially with a single click; per-line status indicators (queued → generating → done/failed).
- **Stitched export** — Export the full script as one WAV: starred (or newest) take per line, configurable silence gap between lines, optional peak normalization to −0.18 dBFS.
- **Direction overrides** — Per-session temperature and exaggeration knobs that override emotion presets for capable backends (Fish S2-Pro: temperature; Chatterbox: exaggeration).
- **History reuse** — One-click "Reuse" in the history browser repopulates the studio editor (text, voice, emotion, backend) from any past generation.

## Architecture

```
App (SwiftUI)
  ├─ EngineKit (synthesis engine, model loading)
  ├─ StudioKit (voice library, history store, .gvoice I/O, WAV encoding)
  │    └─ mlx-audio-swift + EngineKit/MLXSpeechModel (on-device synthesis)
  │    └─ HuggingFace (model downloading)
  └─ SpeechKit (on-device speech-to-text: Apple speech / WhisperKit)
```

The `AppModel` owns the engine, voices store, history store, and optional API server. UI-test mode swaps in a fake provider for fast XCUITest runs without weights.

## Build & Install

### Requirements

- macOS 14+ (Apple Silicon only)
- Xcode 16+
- `xcodegen` 2.45.4+

### Steps

```bash
# Install xcodegen if not present
brew install xcodegen

# Generate Xcode project from project.yml
xcodegen generate

# Build (Debug)
xcodebuild build -project GloamVoiceStudio.xcodeproj -scheme GloamVoiceStudio \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build-app \
  CODE_SIGN_IDENTITY=- 2>&1 | tail -5

# Or build Release
xcodebuild build -project GloamVoiceStudio.xcodeproj -scheme GloamVoiceStudio \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build-app \
  CODE_SIGN_IDENTITY=- 2>&1 | tail -5

# Run (opens the app)
open build-app/Build/Products/Debug/GloamVoiceStudio.app
# or
open build-app/Build/Products/Release/GloamVoiceStudio.app
```

### Package Tests

The underlying EngineKit and StudioKit packages have unit test suites:

```bash
swift test
```

### UI Tests

```bash
xcodebuild test -project GloamVoiceStudio.xcodeproj -scheme GloamVoiceStudio \
  -destination 'platform=macOS' -derivedDataPath build-app CODE_SIGN_IDENTITY=-
```

## Integration with gloam-voice-engine

The Python sibling project [`gloam-voice-engine`](https://github.com/TinyTrashLabs/gloam-voice-engine) is a backend server and a source of voice data.

**Interchange Format:** Both projects use `.gvoice` packs (ZIP archives containing `meta.json` and `ref.wav`). You can:
- Export a voice from the macOS app and import it into the Python project.
- Export voices from the Python project and import them into the macOS app.

**API Contract:** Both projects offer OpenAI-compatible `/synthesize` endpoints so they can drive each other programmatically.

## Data Storage

All app data is stored in the macOS sandbox container:

- `~/Library/Application Support/Gloam Voice Studio/Voices/` — Voice library (one folder per voice, containing `meta.json` and `ref.wav`).
- `~/Library/Application Support/Gloam Voice Studio/History/` — Generated audio clips and metadata.
- `~/Library/Caches/Models/` — Downloaded ML weights (chatterbox, chatterbox-turbo, fish-s2-pro folders).

No data is uploaded or synced to external services.

## License

Gloam Voice Studio itself is published under the [MIT License](LICENSE).

Model weights are licensed separately:
- **Chatterbox & Chatterbox-Turbo:** MIT
- **Fish S2-Pro:** [Fish Audio Research License](https://huggingface.co/fishaudio/fish-speech-1.5) (personal/research use; commercial use requires a license from business@fish.audio)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for
build instructions and conventions, and note our [Code of
Conduct](CODE_OF_CONDUCT.md). Open issues or pull requests on GitHub.

## Acknowledgments

- Built with [SwiftUI](https://developer.apple.com/swiftui/), [MLX (Apple)](https://github.com/ml-explore/mlx-swift), and [mlx-audio-swift](https://github.com/TinyTrashLabs/mlx-audio-swift).
- Voice synthesis models from [Fish Audio](https://fish.audio), [CoquiTTS](https://github.com/coqui-ai/TTS), and community contributors.
