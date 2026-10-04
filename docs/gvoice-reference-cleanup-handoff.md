# `.gvoice` reference cleanup — engineering handoff

Status: implemented on `codex/gvoice-reference-cleanup`  
Audience: `GVoiceKit`, `StudioKit`, CLI, and app maintainers  
Last updated: 2026-10-02

## Outcome

Add a reproducible reference-preparation pipeline to the shared voice tooling so
every `.gvoice` producer can turn selected source passages into a clean,
transcript-matched `source/ref.wav` without reimplementing the Bad Bunny cleanup
by hand.

The pipeline has two modes:

- **standard cleanup** for speech that has steady room noise or hiss but no
  music; and
- **vocal isolation** for otherwise-good speech with faint background music.

The implementation must preserve the package's existing portability boundary:
`GVoiceKit` remains the lightweight, Foundation-only format library used on
macOS and iOS. Native AVFoundation/Accelerate DSP, MLX-Swift Demucs, ASR, and UI
workflow belong in a new optional production layer, not in `GVoiceKit`.

The implementation is native Swift end to end: no Python runtime, ffmpeg,
subprocess, or shell-tool dependency. The first separator is an in-process
MLX-Swift HTDemucs backend. The public API uses protocols so a future Core ML
separator can replace it without changing the recipe, report, or provenance.

## Why this is the recipe

This exact order produced the cleanest accepted results on the Bad Bunny
English reference and was subsequently reused on the Gilbert Gottfried source:

1. select passages with one speaker and no overlapping speech;
2. cut each passage from the untouched stereo source as 48 kHz, 24-bit PCM;
3. when music is present, run the untouched passage through Demucs
   `htdemucs_ft` in two-stem vocal mode;
4. use the vocal stem, with no second denoise pass by default;
5. downmix, band-limit, optionally remove steady noise, level, and fade;
6. join non-contiguous passages only after each has been isolated and cleaned;
7. transcribe the final audio and require the stored reference text to match it;
8. derive the engine-ready mono PCM reference and save it through the existing
   `ReferenceStandard` path;
9. retain a complete recipe and verification report in `provenance`.

Order is part of the contract. In particular, mono conversion, denoising,
normalization, and concatenation before stem separation all reduce separation
quality. A second denoise after Demucs tends to make consonants watery without
removing more music.

## Existing contracts to keep

| Contract | Current owner | Integration consequence |
| --- | --- | --- |
| `.gvoice` model and ZIP layout | `Sources/GVoiceKit/GVoice.swift` | No format version bump is needed. Cleanup metadata fits the existing opaque `provenance` field. |
| Lightweight cross-platform pack library | `GVoiceKit` target in `Package.swift` | Do not add AVFoundation, MLX, WhisperKit, Python, Demucs, or process execution to `GVoiceKit`. |
| Canonical pack loudness | `GVoiceKit/Loudness.swift` | Final pack references target **−17.0 LUFS** and a **−1.0 dBFS** peak ceiling. |
| Final write invariant | `EngineKit/ReferenceStandard.swift` | Every `VoiceLibrary` write trims a cut-off tail and applies the canonical loudness standard. Keep this as the last safety boundary. |
| Voice-library writes | `StudioKit/VoiceLibrary.swift` | Commit the prepared reference, transcript, and provenance together through `save`/`saveAt`; do not partially mutate a voice while preparing it. |
| Master source semantics | `docs/gvoice-format.md` | `source/ref.wav` remains the cross-engine source. Engine-specific derivatives still belong under `engines/<id>/`. |
| Opaque metadata preservation | `GVoiceKit/JSONValue.swift` | Producer-side typed metadata can be encoded into `JSONValue`; readers preserve it without understanding it. |

## Target architecture

Add one optional library product, tentatively named `GVoiceProductionKit`:

```text
GVoiceKit
  .gvoice types, JSONValue, WAV parsing/encoding, loudness standard
        ▲
        │
EngineKit
  ReferenceStandard and engine-facing reference rules
        ▲
        │
GVoiceProductionKit                       macOS first
  orchestration, AVFoundation decoding, filters, reports
  protocol-backed separator and transcriber adapters
        ▲
        ├── SwiftDemucsSeparator           in-process MLX adapter
        ├── Apple/Whisper transcriber      existing SpeechKit capability
        ├── spike gvoice-prepare/build     CLI surface
        └── Studio import UI               later phase
```

The new target may depend on `GVoiceKit`, `EngineKit`, `SpeechKit`, and Apple
media frameworks as required. It must not become a dependency of `GVoiceKit`.
If adding it to `StudioKit` would make an iOS consumer pull in unsupported
symbols, keep it as a sibling product and link it only into the macOS app and
`spike` executable.

### Why the separator is a protocol

Demucs is the validated backend, not the portable API. The shared API describes
the operation and records the concrete implementation used. That gives us:

- deterministic macOS production today;
- a fake separator for unit tests;
- a future Core ML implementation on iOS;
- an explicit unsupported error on platforms with no separator; and
- stable provenance even if the backend changes.

## Proposed public model

Names are suggestions; preserving the separation of request, recipe, result,
and backend is more important than the exact spelling.

```swift
public struct ReferenceSegment: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
}

public enum ReferenceCleanupMode: String, Codable, Sendable {
    case standard
    case isolateVocals
}

public enum ReferenceDenoise: String, Codable, Sendable {
    case none
    case light
    case strong
}

public struct StemSeparationRecipe: Codable, Sendable, Equatable {
    public var backend: String              // "demucs"
    public var backendVersion: String?
    public var model: String                // "htdemucs_ft"
    public var mode: String                 // "two-stems-vocals"
    public var shifts: Int                  // 1
    public var overlap: Double              // 0.5
    public var outputBitDepth: Int           // 24
}

public struct ReferenceCleanupRecipe: Codable, Sendable, Equatable {
    public static let schema = "gvoice.reference-cleanup.v1"

    public var mode: ReferenceCleanupMode
    public var segments: [ReferenceSegment]
    public var highpassHz: Double            // 70
    public var lowpassHz: Double             // 15_000
    public var denoise: ReferenceDenoise
    public var fadeInSeconds: Double         // 0.05
    public var fadeOutSeconds: Double        // up to 0.25
    public var joinSilenceSeconds: Double    // 0.35 default
    public var packSampleRate: Int           // 24_000 default
    public var packChannels: Int             // 1
    public var packPCMBitDepth: Int           // 16
    public var separation: StemSeparationRecipe?
}

public struct ReferencePreparationRequest: Sendable {
    public var sourceURL: URL
    public var sourceIdentity: String?        // user-supplied URL/id; no download
    public var transcript: String?
    public var language: String?
    public var recipe: ReferenceCleanupRecipe
}

public struct ReferenceCleanupMetrics: Codable, Sendable, Equatable {
    public var sourceDurationSeconds: Double
    public var retainedDurationSeconds: Double
    public var sampleRate: Int
    public var channels: Int
    public var loudnessBeforeLUFS: Double?
    public var loudnessAfterLUFS: Double?
    public var truePeakDbFS: Double?
    public var clippedSampleCount: Int
    public var sourceSHA256: String
    public var referenceSHA256: String
}

public struct ReferenceVerification: Codable, Sendable, Equatable {
    public var transcript: String
    public var transcriber: String?
    public var transcriberVersion: String?
    public var speechOnly: Bool
    public var noOverlappingSpeaker: Bool
    public var musicRemoved: Bool?
    public var warnings: [String]
}

public struct PreparedReference: Sendable {
    /// Mono 24 kHz PCM16 WAV ready for VoiceLibrary.save.
    public var wav: Data
    /// Transcript of the actual final waveform, not the source video caption.
    public var transcript: String
    public var metrics: ReferenceCleanupMetrics
    public var verification: ReferenceVerification
    public var provenance: JSONValue
    /// Optional 48 kHz/24-bit editing master retained outside the pack.
    public var productionMasterURL: URL?
}

public protocol VoiceStemSeparating: Sendable {
    func isolateVocals(
        fromStereoWAV input: URL,
        recipe: StemSeparationRecipe,
        outputDirectory: URL
    ) async throws -> URL
}

public protocol ReferenceTranscribing: Sendable {
    func transcribe(wav: URL, language: String?) async throws -> String
}

public struct ReferencePreparer: Sendable {
    public init(
        separator: (any VoiceStemSeparating)?,
        transcriber: (any ReferenceTranscribing)?
    )

    public func prepare(
        _ request: ReferencePreparationRequest
    ) async throws -> PreparedReference
}
```

Do not make a transcript optional in the returned value. It may be supplied by
the caller or generated by ASR, but a cloning reference is not complete until
its exact final transcript is known.

## Canonical recipes

### Standard cleanup

Use only when the selected passage does not contain music or another speaker.

1. Decode/cut the selected source segment.
2. Downmix to mono.
3. High-pass at 70 Hz.
4. Low-pass at 15 kHz.
5. Apply the selected steady-noise preset:

   - `none`: no noise reduction;
   - `light`: native soft noise-floor attenuation with a conservative threshold;
   - `strong`: a lower floor and higher threshold for obvious stationary noise.

6. Add a 50 ms fade-in and a fade-out of `min(250 ms, duration / 2)`.
7. Concatenate separately processed segments with 350 ms silence only at a
   natural quiet boundary.
8. Produce the final pack reference and pass it through `ReferenceStandard`.

`light` should be the standard-mode default. `strong` is only for obvious,
steady room noise; it is not a music remover and should surface a quality
warning.

### Vocal isolation

Use only when the source passage is otherwise strong and faint music remains.

For every selected segment independently:

1. Cut from the original source at the selected timestamps.
2. Keep the untouched stereo float samples. Do not normalize, denoise, downmix,
   or concatenate first.
3. Invoke the in-process MLX-Swift separator with this frozen v1 identity:

   ```text
   model: htdemucs_ft
   two stems: vocals
   shifts: 1
   overlap: 0.5
   ```

4. Take the returned vocal samples and run the standard post-chain with denoise `none`.
5. Use `light` post-denoise only when the isolated stem has a separate,
   stationary hiss. Never use `strong` after separation.
6. Join the processed segments at quiet boundaries.

`SwiftDemucsSeparator` resamples to the model's native 44.1 kHz stereo format
inside the adapter and runs entirely in process.

### Loudness and output formats

The earlier standalone cleanup helper produced a 48 kHz/24-bit editing master
at −16 LUFS and a 192 kbps MP3 preview. Do **not** copy that hard-coded −16 LUFS
into the shared pack engine.

Within this repository, `Loudness.referenceLoudnessLUFS` (currently −17.0) and
`Loudness.referencePeakCeilingDbFS` (currently −1.0) are authoritative. The
implementation should:

- perform filters, fades, and joining in float samples;
- avoid an intermediate loudness pass;
- convert the assembled waveform to mono, 24 kHz, PCM16;
- call `ReferenceStandard.applied(to:)` exactly once at the final pack boundary;
- verify the result is within ±0.5 LU of the library target and does not exceed
  the peak ceiling; and
- optionally write a 48 kHz/24-bit production master and MP3 preview outside
  the `.gvoice` pack for auditioning.

`ReferenceStandard` should remain safe and idempotent so imported and already
prepared clips can still pass through `VoiceLibrary.save` without material
change. Add a test proving a prepared reference is not meaningfully altered by
the automatic save-time pass.

## Processing state machine

```text
validate request
  → create private temporary workspace
  → probe/decode source
  → for each segment
      → cut untouched segment
      → [isolation mode] create stereo 48k/24-bit input
      → [isolation mode] isolate vocal stem
      → mono + filters + optional steady denoise + fades
  → join processed segments
  → derive mono 24k PCM16 WAV
  → apply ReferenceStandard once
  → transcribe final WAV
  → verify audio + transcript + report
  → return PreparedReference
  → caller atomically saves voice and provenance
```

All intermediate output belongs in a unique temporary directory. Cancellation
or failure removes it. A caller may explicitly request retention for debugging,
but debug paths must not be written into portable provenance.

Do not write into the voice library until all stages succeed. The final caller
should make one `VoiceLibrary.save` or `saveAt` call with `wav`, `transcript`,
and `provenance` from the same `PreparedReference`.

## Native Demucs adapter

`SwiftDemucsSeparator` runs HTDemucs in process through MLX Swift. It accepts
caller-managed model weights, never launches another executable, and never
downloads during preparation. Pin the Swift package to an exact reviewed commit
and record the package revision plus weight identity/hash in provenance.

Required behavior:

- validate the weights directory and expected safetensors file before work;
- accept untouched stereo samples before cleanup or normalization;
- preserve per-segment isolation and cancellation semantics;
- expose structured progress from the native model;
- keep model allocation bounded and release caches after completion; and
- return a typed unavailable error on unsupported hardware.

### Producing the weights

The separator loads `<weightsDir>/htdemucs_ft_vocals.safetensors` (float16,
MLX channels-last, fused Q/K/V split, DConv/transformer keys renamed; 573
tensors, about 84 MB). The weights are not committed. Build them from the
PyTorch `htdemucs_ft` bag member that produces vocals (`04573f0d`, the fourth
model in `htdemucs_ft.yaml`):

```sh
huggingface-cli download adefossez/HTDemucs-ft   # or any copy of 04573f0d.safetensors
uv run --with safetensors --with numpy scripts/convert_demucs_weights.py \
    [--input path/to/04573f0d.safetensors] [--output-dir DIR]
```

The default output directory is
`~/Library/Application Support/GloamVoiceStudio/Models/htdemucs-ft-vocals-mlx/`.
No torch is needed. The model keeps all four source heads; `VocalSeparator`
selects vocals. Because `Module.update(verify: .noUnusedKeys)` tolerates missing
keys, verify by running the CLI and comparing against the Python reference
(see below).

Verification on a 32.4 s Spanish clip (`spike gvoice-prepare --mode
isolate-vocals --weights <dir>`): Swift output correlates 0.993 with the Python
`demucs` HTDemucs (CPU, shifts 0, overlap 0.5, same checkpoint) after the same
band-limiting. The model rejects mono input (`stereoSourceRequired`); duplicate
a mono source to stereo when testing.

Standard cleanup remains available without model weights.

## Provenance schema

Store producer metadata in the existing opaque manifest field. This is an
additive use of `.gvoice` v2, so it does not change `GVoice.currentVersion`.

Recommended shape:

```json
{
  "referenceCleanup": {
    "schema": "gvoice.reference-cleanup.v1",
    "source": {
      "identity": "user supplied URL, asset id, or local label",
      "sha256": "…",
      "durationSeconds": 142.3
    },
    "recipe": {
      "mode": "isolateVocals",
      "segments": [
        { "startSeconds": 105.8, "endSeconds": 120.4 },
        { "startSeconds": 131.1, "endSeconds": 145.7 }
      ],
      "highpassHz": 70,
      "lowpassHz": 15000,
      "denoise": "none",
      "fadeInSeconds": 0.05,
      "fadeOutSeconds": 0.25,
      "joinSilenceSeconds": 0.35,
      "packSampleRate": 24000,
      "packChannels": 1,
      "packPCMBitDepth": 16,
      "separation": {
        "backend": "demucs",
        "backendVersion": "…",
        "model": "htdemucs_ft",
        "mode": "two-stems-vocals",
        "shifts": 1,
        "overlap": 0.5,
        "outputBitDepth": 24
      }
    },
    "verification": {
      "transcriber": "…",
      "transcriberVersion": "…",
      "speechOnly": true,
      "noOverlappingSpeaker": true,
      "musicRemoved": true,
      "warnings": []
    },
    "metrics": {
      "retainedDurationSeconds": 29.55,
      "sampleRate": 24000,
      "channels": 1,
      "loudnessAfterLUFS": -17.0,
      "truePeakDbFS": -1.1,
      "clippedSampleCount": 0,
      "referenceSHA256": "…"
    }
  }
}
```

Do not duplicate the full transcript in provenance; it already travels as the
source variant's `text`. Verification metadata describes how that text was
obtained. If existing provenance is present, merge `referenceCleanup` into its
top-level object. If it is a non-object JSON value, preserve it under
`previousProvenance` rather than dropping it.

Create typed `Codable` structs in the production target and one tested encoder
from those structs to `JSONValue`. `GVoiceKit` must continue to treat the result
as opaque.

## Transcript policy

The transcript describes the final waveform after trimming, isolation, fades,
and joining. It is not copied blindly from captions or from the uncut source.

At minimum:

- normalize only whitespace, not words or punctuation that affect pronunciation;
- re-transcribe the final reference when a transcriber is available;
- show supplied and recognized text side by side when they differ;
- require explicit resolution before saving a materially different transcript;
- reject an empty transcript for engines whose `BackendID.needsRefText` is true;
  and
- record the transcriber and version in provenance.

Automatic word-error rate is useful as a warning, not a sufficient acceptance
test. Proper names, expressive delivery, and code switching can fool ASR while
remaining valid cloning material.

The API may accept an explicit `verifiedTranscript` from a trusted caller, but
the report must say that verification was manual rather than implying ASR ran.

## Validation gates

Preparation fails before library mutation when a hard gate fails.

### Hard gates

- source exists and contains a readable audio stream;
- each segment has finite, non-negative times with `end > start`;
- segments fit within the source duration;
- isolation input has two channels, unless the caller explicitly enables a
  lower-quality mono upmix;
- final WAV is mono, 24 kHz, PCM16;
- final duration is non-zero and within tolerance of retained speech plus joins;
- no non-finite samples;
- no clipped PCM samples;
- loudness is within ±0.5 LU of `Loudness.referenceLoudnessLUFS`;
- peak is at or below `Loudness.referencePeakCeilingDbFS` within quantization
  tolerance;
- transcript is non-empty when required; and
- separation mode produced the expected vocal stem.

### Quality warnings requiring audition or explicit acceptance

- `strong` denoise selected;
- mono source upmixed for separation;
- final ASR materially differs from supplied text;
- more than 25% of the final clip is silence;
- a segment is extremely short;
- large boost or heavy limiting was needed;
- post-Demucs denoise was selected; or
- music-removal verification is unknown.

### Human listening acceptance

For isolation mode, the producer must A/B the selected original and final clip
at matched loudness. Reject the result when syllables disappear, consonants
smear, the voice pumps with the former music bed, or musical residue is still
obvious. The library can automate measurements; it cannot fully automate this
judgment in v1.

## CLI surface

Add a preparation command rather than overloading `gvoice-build` with every DSP
option:

```bash
spike gvoice-prepare \
  --input interview.wav \
  --segment 105.8:120.4 \
  --segment 131.1:145.7 \
  --mode isolate-vocals \
  --denoise none \
  --weights /path/to/htdemucs-ft-vocals-mlx \
  --language en \
  --transcript-file ref.txt \
  --source-identity 'https://…' \
  --output prepared/
```

Expected outputs:

```text
prepared/ref.wav                  # mono 24 kHz PCM16, pack-ready
prepared/ref.txt                  # exact final transcript
prepared/cleanup-report.json      # recipe, metrics, verification, tool versions
prepared/provenance.json          # JSONValue-ready fragment
prepared/audition-master.wav      # optional 48 kHz/24-bit
prepared/audition.mp3             # optional preview
```

Then extend `gvoice-build` with a narrow input:

```bash
spike gvoice-build \
  --ref-wav prepared/ref.wav \
  --ref-text prepared/ref.txt \
  --provenance-file prepared/provenance.json \
  ...
```

`gvoice-prepare` should print the report as JSON when `--json` is passed and use
distinct exit codes for invalid input, unavailable backend, processing failure,
and failed verification. It must never download a URL supplied as
`--source-identity`; that field is descriptive provenance only.

## App workflow

The macOS import UI can be layered on the same API after the CLI proves it:

1. choose a local source;
2. mark one or more ranges;
3. select **Clean speech** or **Remove faint music**;
4. choose denoise level, with contextual warnings;
5. run preparation with stage progress and cancellation;
6. show matched-loudness original/final A/B playback;
7. show supplied versus recognized transcript;
8. save only after verification; and
9. attach the report to provenance automatically.

Do not present vocal isolation as capable of removing an overlapping
interviewer. Passage selection is still responsible for choosing single-speaker
audio.

## Errors and progress

Use typed errors rather than parsing process text at call sites:

```swift
public enum ReferencePreparationError: Error, Sendable {
    case invalidSegment(index: Int, reason: String)
    case unreadableSource(String)
    case stereoSourceRequired
    case separationUnavailable(String)
    case separationFailed(exitCode: Int32, diagnostic: String)
    case expectedVocalStemMissing
    case transcriptionFailed(String)
    case verificationFailed([String])
    case cancelled
}
```

Progress should be structured and segment-aware:

```swift
public enum ReferencePreparationStage: Sendable, Equatable {
    case validating
    case decoding(segment: Int, total: Int)
    case separating(segment: Int, total: Int)
    case cleaning(segment: Int, total: Int)
    case assembling
    case standardizing
    case transcribing
    case verifying
}
```

Avoid promises of exact percent completion for Demucs unless the adapter has a
reliable backend signal. A stage plus segment count is honest and useful.

## Security and resource limits

Source audio, WAV headers, transcripts, `.gvoice` manifests, and process output
are untrusted input.

- Reuse existing bounded WAV parsing and `.gvoice` path-validation behavior.
- Put configurable caps on source duration, selected duration, decoded sample
  count, temporary-disk use, and process-log size.
- Resolve every staging path beneath the generated workspace and reject path
  traversal.
- Never launch a subprocess or interpret a shell string.
- Do not fetch remote source URLs in the library.
- Do not run package installation as part of preparation.
- Hash source and result incrementally rather than loading arbitrarily large
  files solely for hashing.
- Remove staging data on success, error, and cancellation unless debug retention
  was explicitly requested.
- Avoid recording local absolute paths, usernames, temporary directories, or
  credentials in provenance.

## Test plan

### Unit tests

- recipe defaults exactly match the frozen v1 presets;
- segment validation rejects NaN, infinity, negative, reversed, overlapping
  where unsupported, and out-of-range timestamps;
- fades use 50 ms in and at most 250 ms out without exceeding half a clip;
- joining inserts the configured silence exactly once between segments;
- 48 kHz stereo separation input is produced without normalization;
- standard mode never calls the separator;
- isolation mode processes every segment separately;
- isolation defaults to no post-denoise and rejects `strong`;
- final reference is mono 24 kHz PCM16;
- final loudness and peak match the shared constants;
- applying `ReferenceStandard` again changes loudness by less than 0.1 LU and
  introduces no additional tail trim;
- report hashes and metrics refer to the returned bytes;
- typed provenance converts to `JSONValue` and round-trips through `.gvoice`
  export/import unchanged;
- existing non-cleanup provenance survives the merge; and
- cancellation terminates the adapter and removes staging files.

### Golden fixtures

Keep small, licensed or synthetic fixtures for:

- clean podcast speech;
- speech plus stationary hiss;
- speech plus faint music;
- speech with an overlapping second speaker;
- two non-contiguous passages joined naturally;
- a very short passage exercising fade bounds; and
- a clipped or malformed WAV.

Golden assertions should cover format, duration, loudness, peak, hashes where
the backend is deterministic, transcript retention, and absence of regressions
such as a missing first or last syllable. Do not commit copyrighted celebrity
source audio as a test fixture.

### Adapter integration tests

Mark real inference tests as opt-in and skip with a clear reason when weights are
unavailable. Unit-test the adapter through an injected native separator closure,
including stereo validation and cancellation.

### Pack acceptance test

Build a pack from `PreparedReference`, export it, import it into a fresh
library, and assert:

- `source/ref.wav` remains mono 24 kHz PCM16;
- source text is exact;
- cleanup provenance is byte-for-byte semantically equivalent;
- the imported voice supports all expected clone backends; and
- a second export preserves provenance.

## Implementation sequence

### Phase 1 — model and provenance

- Add recipe, request, metrics, verification, and report types.
- Add typed-to-`JSONValue` encoding and safe provenance merge.
- Add `--provenance-file` to `gvoice-build`.
- Add round-trip tests.

This phase is independently useful because any native producer can emit the same
provenance before it adopts the complete DSP pipeline.

### Phase 2 — native standard cleanup

- Add decoding, segmentation, mono conversion, high/low-pass filters, fades,
  joins, format conversion, measurement, and validation.
- Reuse `Loudness` and `ReferenceStandard` for the final invariant.
- Ship `gvoice-prepare --mode standard`.

### Phase 3 — separation backend

- Add `VoiceStemSeparating` and `SwiftDemucsSeparator`.
- Freeze the v1 Demucs arguments.
- Add availability reporting, cancellation, bounded memory, and opt-in integration
  tests.
- Ship `--mode isolate-vocals`.

### Phase 4 — transcript verification and app UI

- Adapt an existing `SpeechKit` transcriber.
- Add transcript comparison and report metadata.
- Add the macOS range-selection, progress, and A/B verification workflow.

### Phase 5 — additional backends

- Evaluate a bundled/Core ML separator for iOS only against the frozen golden
  corpus and listening gates.
- Add a new backend identifier/version in provenance; do not silently label a
  different model as Demucs-compatible.

## Definition of done

The feature is complete when:

- the CLI can reproduce both standard and music-isolation workflows from a
  local source and exact timestamp list;
- output is a validated mono 24 kHz PCM16 `ref.wav` at the shared −17 LUFS /
  −1 dBFS standard;
- the final waveform has an exact stored transcript;
- the Bad Bunny-style faint-music case passes matched-loudness listening without
  obvious music, pumping, or watery consonants;
- a multi-segment reference is isolated per segment before joining;
- `VoiceLibrary.save` receives the prepared WAV, transcript, and provenance as
  one completed result;
- `.gvoice` export/import preserves the complete cleanup provenance;
- standard cleanup works with no Demucs weights;
- Demucs failures and cancellation leave no partial library entry; and
- all unit, golden, native-adapter, and pack round-trip tests pass.

## Explicit non-goals for v1

- finding source media on the internet;
- downloading remote media;
- removing an overlapping interviewer or performing speaker diarization;
- automatically deciding which celebrity passages are legally usable;
- training or cloning a voice model;
- real-time microphone cleanup;
- storing the 48 kHz audition master inside every `.gvoice`; and
- claiming objective music removal without a human listening check.

## Reference implementation used during discovery

The validated standalone scripts currently live in the Codex skill:

```text
~/.codex/skills/extracting-clean-voice-clips/
  scripts/clean_voice_clip.py
  scripts/isolate_voice_clip.py
  references/music-separation.md
```

They are a behavioral reference, not a runtime dependency. Port the frozen
recipe and tests into this repository; do not make the app depend on files in a
user's Codex configuration directory.
