---
name: run-app
description: Build, launch, and verify the Gloam Voice Studio macOS app (Swift/SwiftUI + SPM, xcodegen). Use when asked to run, start, rebuild, relaunch, or screenshot the app locally, or to confirm a code/dependency change (especially a Chatterbox / mlx-audio-swift bump) is actually present in the running binary rather than a stale build.
---

# Running Gloam Voice Studio (local Debug)

Native macOS app for Apple Silicon. `project.yml` → `GloamVoiceStudio.xcodeproj`
(xcodegen); scheme `GloamVoiceStudio`; Swift Package Manager (EngineKit /
StudioKit / SpeechKit). The Chatterbox TTS engine comes from the vendored fork
`TinyTrashLabs/mlx-audio-swift`, pinned by revision in `Package.swift`.

## Recipe (verified)

Build the Debug app into `build-app/` (the derived-data path the local dev build
already uses), then relaunch. Run from the repo root:

```bash
xcodebuild -project GloamVoiceStudio.xcodeproj \
  -scheme GloamVoiceStudio \
  -configuration Debug \
  -derivedDataPath build-app \
  -skipMacroValidation \
  build

APP=build-app/Build/Products/Debug/GloamVoiceStudio.app
osascript -e 'tell application "GloamVoiceStudio" to quit' 2>/dev/null   # quit stale instance
open "$APP"
```

Confirm it actually launched (not just that the process spawned):

```bash
osascript -e 'tell application "System Events" to get (count of windows of (first process whose name is "GloamVoiceStudio"))'
# expect >= 1
```

The embedded StudioKit HTTP server (Hummingbird) starts on demand, not at
launch, so no listening socket right after `open` is normal.

## Gotcha 1 — `-skipMacroValidation` is REQUIRED

Without it, a non-interactive `xcodebuild` fails early at
`ComputeTargetDependencyGraph` with:

> Macro "MLXHuggingFaceMacros" from package "mlx-swift-lm" must be enabled
> before it can be used

`mlx-swift-lm` 3.x ships its HuggingFace integration as Swift macros, and
Xcode's macro-trust prompt can't be answered from the CLI. The fastlane
`build_pkg` lane passes the same flag — this is the project's established fix,
not a hack.

## Gotcha 2 — the stale-binary trap (why this skill exists)

A running Gloam instance can be **hours older than the source tree** and
silently run pre-fix Chatterbox code — clones that "sound drunk" are usually a
stale binary, not a regression. Fixing the source (repinning the fork) does
NOT change a binary you built before the repin. Before trusting an ear test,
prove the running binary is fresh AND contains the fix:

```bash
BIN=build-app/Build/Products/Debug/GloamVoiceStudio.app/Contents/MacOS/GloamVoiceStudio
stat -f "%Sm %N" "$BIN"                 # build time — must be AFTER the fork commit you expect
ps -p "$(pgrep -x GloamVoiceStudio)" -o lstart=   # process start — must be AFTER the build time

# Debug builds put code in the .debug.dylib sidecar, so nm the whole bundle, not just the exe:
nm build-app/Build/Products/Debug/GloamVoiceStudio.app/Contents/MacOS/GloamVoiceStudio.debug.dylib | grep -i sincResample
# a hit == the round-3 resampler parity fix is compiled in
```

If the process started *before* the binary's mtime, it's running old code in
memory even though the on-disk bundle is fresh — quit and relaunch.

## Release / App Store

Don't use this recipe for shipping. For a Mac App Store build (`.pkg`,
upload to App Store Connect), see the `ship-app-store-build` skill. For a
signed, notarized `.zip` for direct/GitHub distribution, see the
`release-notarized` skill.

## If `project.yml` changed

Regenerate the Xcode project before building: `xcodegen generate`.
