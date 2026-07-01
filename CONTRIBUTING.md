# Contributing to Gloam Voice Studio

Thanks for your interest in contributing! This is a native macOS (Apple Silicon)
SwiftUI app with a Swift Package Manager core. Contributions of all sizes are
welcome — bug reports, fixes, docs, and features.

## Getting started

Requirements:

- macOS 14+ (Apple Silicon only)
- Xcode 16+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) 2.45.4+ (`brew install xcodegen`)

Generate the Xcode project and build:

```bash
xcodegen generate
xcodebuild build -project GloamVoiceStudio.xcodeproj -scheme GloamVoiceStudio \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build-app \
  CODE_SIGN_IDENTITY=-
```

Run the package unit tests before opening a PR:

```bash
swift test
```

## Project layout

- `App/` — SwiftUI app (`AppModel` owns the engine, stores, and optional API server).
- `Sources/EngineKit/` — synthesis engine and model loading.
- `Sources/StudioKit/` — voice library, history store, `.gvoice` I/O, WAV encoding, local API server.
- `Sources/SpeechKit/` — on-device speech-to-text (Apple speech / WhisperKit).
- `Tests/` — package unit tests. `UITests/` — XCUITest smoke tests.

## Pull requests

1. Fork and create a topic branch.
2. Keep changes focused; add or update tests where it makes sense.
3. Ensure `swift test` passes.
4. Use clear commit subjects in the existing style: `feat(...)`, `fix(...)`, `docs(...)`.
5. Open a PR describing the change and how you verified it.

## Reporting bugs and requesting features

Use the GitHub issue templates. For bugs, include your macOS version, chip
(e.g. M3), the backend in use, and steps to reproduce.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.
