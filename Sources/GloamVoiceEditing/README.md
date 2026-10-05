# GloamVoiceEditing

The shared voice-editing API. Every app that edits a Gloam voice -- the iPhone
Studio, the Mac Studio, the radio -- uses it.

**Apps own their screens; behaviour lives here.** No SwiftUI, no UIKit/AppKit
views: nothing in this target imports a UI framework.
Foundation, Combine, AVFoundation, Accelerate, NaturalLanguage and GVoiceKit
only -- no EngineKit, so it links on iOS without MLX. `GloamVoiceUI` is a set of
reference SwiftUI screens built on it (and re-exports it); an app may use those
or draw its own over the same calls.

## The store: `VoiceLibraryStore`

What the editor reads and writes. The host implements it over its own library
(`StudioKit.StudioVoiceEditorStore` does for the Mac's `VoiceLibrary`).

- Required: `voices`, `referenceText(of:)`, `masterURL(of:)`, `referenceURL(of:)`,
  `update(_:_:)`, `languages(of:)`, `updateTranscript(of:_:)`.
- Everything else has a default that does nothing or throws
  `VoiceEditorUnsupported`: delete, pace/gain, cleanup, avatar, takes, the
  reference window, emotion versions, languages, pack export.
- `features: VoiceLibraryFeatures` says which of those the store backs; a
  screen draws only those. `.all` is Studio's set; `.persona` and `.languages`
  are opt-in.
- Language references are first-class references (`languageReferences(of:)`,
  `addLanguageReference`, `removeLanguageReference`), never emotion versions.
- Helpers on every store: `referenceText(for:)`, `outputGain(for:)`.
- `VoiceStoreError` is what a store throws for its own refusals; `userMessage(for:)`
  turns any import/save error into one sentence.

## What the host does: `VoiceEditorCapabilities`

Engine and platform work the library cannot do, each optional (absent hides
the feature): `transcribe` (ASR), `voiceCheck` (`VoiceCheckCapability`: prepare,
candidates, a `TestRenderer`, a `PartChecker`, engine name), `canRecord`,
`consent` (`ConsentGate`: `isRequired` + `accept` -- headless; how the question
is asked is the app's screen), `deviceNoun`.

## Models and rules

- `TakesModel` (takes of one voice, hygiene verdicts, Save blocker),
  `CloneRecorder` (mic + dB meter), `VoicePlayer`, `VoicePackExport`.
- `RecordingCheck` (level judged on the voiced blocks, noise, clipping, script
  match), `RenderCheck` (+ `NoiseBed` floor), `VoiceQualifier` (+ `NoiseCleanup`
  and a host `SpeechDenoiser`), `ReferenceAdvice`, `ReferenceWindowRule` (the
  engines' own `ReferenceSection.cut` / `endAtSentence`; windows record the
  master's hash), `TakeRules`/`TakeCombiner`, `EmotionVersions`, `ClipImport`,
  `SpokenWords`, `ScriptLanguage`, `Renditions`.

## Rules

- Long references are fine: nothing here warns on or caps a master's length.
  Only unusable input is refused (silent, too short, a file over 200 MB).
- Sections live in the pack. An app never picks, cuts or prepares an engine's
  section itself; the library does (`QwenVoicePrep.prepareEngineFolder`,
  `ReferenceSections.prepare`).
