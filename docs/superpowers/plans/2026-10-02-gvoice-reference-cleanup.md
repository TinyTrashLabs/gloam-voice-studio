# `.gvoice` Reference Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a reusable macOS shared library and CLI that reproduce the validated clean-speech and Demucs vocal-isolation recipes and emit pack-ready `.gvoice` reference audio plus reproducible provenance.

**Architecture:** Add `GVoiceProductionKit` as a sibling of portable `GVoiceKit`. It owns typed recipes, AVFoundation/Accelerate audio preparation, an in-process protocol-backed MLX-Swift Demucs adapter, reports, and provenance; `GVoiceKit` stays format-only. The `spike` CLI exposes preparation and accepts the resulting provenance during pack creation.

**Tech Stack:** Swift 6.2, Swift Package Manager, AVFoundation, Accelerate, MLX Swift, SwiftDemucs, XCTest, existing `GVoiceKit`/`EngineKit` loudness and pack APIs.

**Spec:** `docs/gvoice-reference-cleanup-handoff.md`

## Global Constraints

- `GVoiceKit` remains Foundation + ZIPFoundation only and supports macOS 14/iOS 17.
- Demucs receives an untouched 48 kHz stereo PCM24 segment before mono conversion, denoise, normalization, or joining.
- Isolation uses `htdemucs_ft`, two-stem vocals, `other-method none`, PCM24, one shift, and 0.5 overlap.
- Post-isolation denoise defaults to `none`; `strong` is invalid for isolation.
- Final pack audio is mono 24 kHz PCM16 and passes through `ReferenceStandard` once at the pack boundary.
- The library loudness constants, currently −17 LUFS and −1 dBFS, are authoritative.
- No subprocesses, remote downloads, or environment installation occur during preparation.
- Voice-library mutation happens only after complete preparation and verification.

## Review Focus

- Cancellation must stop in-process separation and clean the temporary workspace; Task 3 tests this with a cancellable fake separator.
- Large decoded sources must respect configured sample and duration caps; Task 2 tests the bounds before allocation.
- Multi-segment isolation must call Demucs independently before joining; Task 4 verifies invocation order and inputs.
- Existing non-object provenance must survive rather than being overwritten; Task 1 pins the merge behavior.
- Paths and timestamps are untrusted; Task 1 tests non-finite, reversed, out-of-range, and traversal-adjacent inputs.

---

### Task 1: Recipe, validation, report, and provenance model

**Files:**
- Modify: `Package.swift`
- Create: `Sources/GVoiceProductionKit/ReferenceCleanupModel.swift`
- Create: `Sources/GVoiceProductionKit/ReferenceCleanupProvenance.swift`
- Create: `Tests/GVoiceProductionKitTests/ReferenceCleanupModelTests.swift`
- Create: `Tests/GVoiceProductionKitTests/ReferenceCleanupProvenanceTests.swift`

**Interfaces:**
- Consumes: `GVoiceKit.JSONValue`, `Loudness.referenceLoudnessLUFS`, `Loudness.referencePeakCeilingDbFS`.
- Produces: `ReferenceSegment`, `ReferenceCleanupMode`, `ReferenceDenoise`, `StemSeparationRecipe`, `ReferenceCleanupRecipe`, `ReferenceCleanupMetrics`, `ReferenceVerification`, `ReferenceCleanupReport`, `ReferencePreparationError`, and `ReferenceCleanupProvenance.merging(_:into:)`.

- [ ] **Step 1: Write failing model-default and validation tests**

  Assert the v1 recipe's exact 70/15,000 Hz filters, 50/250 ms fades, 350 ms joins, 24 kHz mono PCM16 output, frozen Demucs arguments, and errors for NaN, infinity, negative, reversed, overlapping, and source-out-of-range segments. Assert isolation rejects `strong` and supplies a separator recipe.

- [ ] **Step 2: Run the focused tests and verify RED**

  Run: `swift test --filter ReferenceCleanupModelTests`

  Expected: compile failure because `GVoiceProductionKit` and its types do not exist.

- [ ] **Step 3: Add the product/targets and minimal model implementation**

  Add a `GVoiceProductionKit` library target depending on `GVoiceKit` and `EngineKit`, plus `GVoiceProductionKitTests`. Implement public `Codable`, `Sendable`, `Equatable` value types and `validated(sourceDuration:)` with typed errors.

- [ ] **Step 4: Run model tests and verify GREEN**

  Run: `swift test --filter ReferenceCleanupModelTests`

  Expected: all model tests pass.

- [ ] **Step 5: Write failing provenance merge tests**

  Assert typed cleanup metadata becomes a `referenceCleanup` object, existing object keys remain unchanged, existing cleanup metadata is replaced, and a previous scalar/array is preserved under `previousProvenance`. Round-trip the result through JSON encoding and decoding.

- [ ] **Step 6: Run provenance tests and verify RED**

  Run: `swift test --filter ReferenceCleanupProvenanceTests`

  Expected: failure because the provenance encoder/merger is missing.

- [ ] **Step 7: Implement provenance encoding and merge**

  Encode typed structures with sorted JSON keys, decode into `JSONValue`, and merge without teaching `GVoiceKit` the schema. Never include local absolute paths or the duplicate transcript.

- [ ] **Step 8: Run the complete new target tests and commit**

  Run: `swift test --filter GVoiceProductionKitTests`

  Commit: `feat: add reference cleanup recipe and provenance`

### Task 2: Native audio I/O and DSP

**Files:**
- Create: `Sources/GVoiceProductionKit/AudioBuffer.swift`
- Create: `Sources/GVoiceProductionKit/NativeAudioProcessor.swift`
- Create: `Tests/GVoiceProductionKitTests/NativeAudioProcessorTests.swift`

**Interfaces:**
- Consumes: local audio URL, validated segments, cleanup recipe, and shared loudness constants.
- Produces: `ReferenceAudioBuffer`, `AudioProperties`, and `NativeAudioProcessing` operations for decode, slice, stereo preparation, filters, denoise, fades, joins, resampling, and PCM WAV encoding.

- [ ] **Step 1: Write failing native audio behavior tests**

  Generate sample buffers in Swift and assert slicing, stereo preservation before separation, mono downmix, 70 Hz high-pass, 15 kHz low-pass, light/strong spectral denoise behavior, bounded fades, 350 ms joins, resampling, PCM16 WAV shape, and pre-allocation duration/sample caps.

- [ ] **Step 2: Run process tests and verify RED**

  Run: `swift test --filter NativeAudioProcessorTests`

  Expected: compile failure because native audio types do not exist.

- [ ] **Step 3: Implement native AVFoundation/Accelerate audio processing**

  Decode with AVAudioFile/AVAudioConverter, keep float planar samples in memory under explicit caps, use Accelerate-backed biquads and FFT noise reduction, apply fades and joins, resample with AVAudioConverter, and encode PCM WAV in Swift. No executable discovery or process launch is permitted.

- [ ] **Step 4: Run process tests and verify GREEN**

  Run: `swift test --filter NativeAudioProcessorTests`

  Expected: all native audio tests pass.

- [ ] **Step 5: Commit**

  Commit: `feat: add native reference audio processing`

### Task 3: Native SwiftDemucs adapter

**Files:**
- Modify: `Package.swift`
- Create: `Sources/GVoiceProductionKit/SwiftDemucsSeparator.swift`
- Create: `Tests/GVoiceProductionKitTests/SwiftDemucsSeparatorTests.swift`

**Interfaces:**
- Consumes: stereo 44.1/48 kHz `ReferenceAudioBuffer`, caller-supplied MLX weights directory, validated separation recipe.
- Produces: `VoiceStemSeparating` and `SwiftDemucsSeparator`, returning the vocal samples in process.

- [ ] **Step 1: Write failing adapter contract tests**

  Assert missing weights fail before inference, non-stereo input is rejected, cancellation is forwarded, the model identifier is reported as `htdemucs_ft`, and the adapter maps an in-memory stereo buffer to the separator without downmixing or prior cleanup.

- [ ] **Step 2: Run adapter tests and verify RED**

  Run: `swift test --filter SwiftDemucsSeparatorTests`

  Expected: compile failure because the adapter does not exist.

- [ ] **Step 3: Pin and wrap native SwiftDemucs**

  Pin `xocialize/demucs-mlx-swift` to an exact reviewed revision. Wrap `VocalSeparator` behind the local protocol, load caller-supplied `htdemucs_ft_vocals.safetensors`, bridge buffers in memory, map progress/cancellation/errors, and record dependency/model versions in provenance.

- [ ] **Step 5: Run adapter tests and verify GREEN**

  Run: `swift test --filter SwiftDemucsSeparatorTests`

  Expected: all native adapter tests pass without weights or live inference.

- [ ] **Step 6: Commit**

  Commit: `feat: add native SwiftDemucs vocal isolation`

### Task 4: Reference preparation orchestration

**Files:**
- Create: `Sources/GVoiceProductionKit/ReferencePreparer.swift`
- Create: `Tests/GVoiceProductionKitTests/ReferencePreparerTests.swift`

**Interfaces:**
- Consumes: `MediaProcessing`, optional `VoiceStemSeparating`, optional `ReferenceTranscribing`, validated request.
- Produces: `ReferencePreparer.prepare(_:progress:) async throws -> PreparedReference`.

- [ ] **Step 1: Write failing standard-mode orchestration tests**

  Assert validation precedes work, standard mode never calls the separator, each segment is cleaned, joins occur once, final format/metrics/transcript/provenance all describe the same returned WAV, and temporary artifacts are removed on success and error.

- [ ] **Step 2: Run focused tests and verify RED**

  Run: `swift test --filter ReferencePreparerTests`

  Expected: compile failure because `ReferencePreparer` is missing.

- [ ] **Step 3: Implement the minimal standard pipeline**

  Use a unique temporary directory, defer cleanup, structured stage progress, final transcript from supplied verified text or the transcriber, SHA-256 hashes, and hard validation gates. Apply `ReferenceStandard` to the final pack WAV before measuring and returning it.

- [ ] **Step 4: Run standard tests and verify GREEN**

  Run: `swift test --filter ReferencePreparerTests`

  Expected: standard-mode tests pass.

- [ ] **Step 5: Write failing isolation and cancellation tests**

  Assert each original segment is independently sliced as untouched stereo float audio, separated, and only then cleaned/joined; no post-denoise is used by default; mono input fails unless explicitly allowed; missing separator fails before DSP work; cancellation removes the workspace.

- [ ] **Step 6: Run tests and verify RED**

  Run: `swift test --filter ReferencePreparerTests`

  Expected: new isolation assertions fail.

- [ ] **Step 7: Implement isolation orchestration and verification gates**

  Add per-segment separation, audio property checks, final PCM/loudness/peak/clipping checks, warnings, and structured report generation.

- [ ] **Step 8: Run target tests and commit**

  Run: `swift test --filter GVoiceProductionKitTests`

  Commit: `feat: orchestrate pack-ready reference cleanup`

### Task 5: CLI integration and pack provenance

**Files:**
- Modify: `Package.swift`
- Create: `Sources/spike/GVoicePrepareCommand.swift`
- Modify: `Sources/spike/main.swift`
- Create: `Tests/GVoiceProductionKitTests/GVoicePrepareArgumentsTests.swift`
- Modify: `Tests/StudioKitTests/GVoiceTests.swift`

**Interfaces:**
- Consumes: `ReferencePreparer`, local source path, repeated `--segment`, cleanup mode/options, optional transcript and source identity.
- Produces: `spike gvoice-prepare` output directory and `gvoice-build --provenance-file` support.

- [ ] **Step 1: Write failing argument/parser tests**

  Cover repeated decimal or `HH:MM:SS` segments, missing values, mutually invalid denoise/mode combinations, local paths with spaces, descriptive source identities that are never fetched, and provenance JSON type validation.

- [ ] **Step 2: Run parser tests and verify RED**

  Run: `swift test --filter GVoicePrepareArgumentsTests`

  Expected: compile failure because the parser is missing.

- [ ] **Step 3: Implement `gvoice-prepare`**

  Write `ref.wav`, `ref.txt`, `cleanup-report.json`, and `provenance.json` atomically into the requested output directory; optionally retain audition artifacts; print structured progress to stderr and JSON result to stdout under `--json`.

- [ ] **Step 4: Add `gvoice-build --provenance-file`**

  Decode the file as `JSONValue`, reject invalid/non-JSON input, and pass it into the existing `VoiceLibrary.save` call. Add a pack round-trip test proving preservation.

- [ ] **Step 5: Run CLI-related tests and verify GREEN**

  Run: `swift test --filter 'GVoicePrepareArgumentsTests|GVoiceTests'`

  Expected: parser and pack round-trip tests pass.

- [ ] **Step 6: Commit**

  Commit: `feat: expose reference cleanup in spike CLI`

### Task 6: Documentation, end-to-end fixture, and verification

**Files:**
- Modify: `docs/gvoice-reference-cleanup-handoff.md`
- Modify: `docs/README.md`
- Create: `Tests/Fixtures/reference-cleanup/README.md`
- Create: small synthetic fixture files only if repository policy permits binary fixtures

**Interfaces:**
- Consumes: completed library and CLI.
- Produces: operator documentation, reproducible smoke command, and verified branch.

- [ ] **Step 1: Update the handoff from proposal to shipped API**

  Replace tentative names with exact public symbols and commands, document native model-weight requirements, explain −17 LUFS ownership, include standard/isolation examples, and retain the behavioral provenance schema.

- [ ] **Step 2: Run a standard-mode end-to-end smoke test**

  Generate a short synthetic stereo WAV in Swift, run `spike gvoice-prepare --mode standard`, inspect `ref.wav` through the native probe, and build/import/re-export a `.gvoice` pack with its provenance.

- [ ] **Step 3: Run isolation integration when Demucs is available**

  Use a synthetic speech-like/noise fixture or a locally supplied licensed clip. If Demucs is unavailable, verify the structured availability error and record the opt-in integration command without claiming the backend ran.

- [ ] **Step 4: Run focused and full verification**

  Run: `swift test --filter GVoiceProductionKitTests`

  Run: `swift test`

  Expected: all non-live tests pass; existing documented live-test skips remain skips.

- [ ] **Step 5: Inspect final diff and commit**

  Run: `git diff --check && git status --short && git diff --stat origin/main...HEAD`

  Commit: `docs: document gvoice reference cleanup workflow`

- [ ] **Step 6: Push and open the requested PR**

  Push `codex/gvoice-reference-cleanup`, create a PR against `main`, summarize architecture and verification, then attach the PR artifact to this task.
