// ReferenceSections.swift
// EngineKit — the stored sections of the engines that take a short reference
// (docs/gvoice-format.md, "Engine sections"), chosen at prep time.
//
// LuxTTS (30 s) keeps its section through LuxReferenceWindow; Qwen's is made by
// QwenVoicePrep.prepareEngineFolder. This file is Pocket's (audio only, so no
// transcript) and the one call a library makes after a voice is saved,
// imported or its master changes: `prepare`.

import Foundation
import GVoiceKit
import QwenANE
import SpeechKit

public enum ReferenceSections {
    public static let pocketEngine = "pocket-tts"
    /// What sherpa-onnx encodes of a Pocket reference (PocketTTS.maxReferenceSeconds).
    public static let pocketMaxSeconds = 10.0

    /// Pocket's reference for the voice at `refURL`: its stored section
    /// (`engines/pocket-tts/ref.wav`) when it has one for this master, the master
    /// itself when it fits, else a section chosen now and stored. A render reads;
    /// it never cuts a section it does not store.
    public static func pocketSamples(forReference refURL: URL) throws -> [Float] {
        if let stored = LuxReferenceWindow.storedRendition(
            forReference: refURL, engine: pocketEngine, requiresText: false),
            let audio = try? LuxReferenceWindow.loadRenditionAudio(stored, forReference: refURL, engine: pocketEngine)
        { return audio }
        let master = try LuxOnnx.loadMono24k(refURL)
        let seconds = Double(master.count) / Double(LuxOnnx.sampleRate)
        guard seconds > pocketMaxSeconds else { return master }
        let cut = ReferenceSection.cut(samples: master, sampleRate: LuxOnnx.sampleRate, maxSeconds: pocketMaxSeconds)
        let start = Double(cut.start) / Double(LuxOnnx.sampleRate)
        let window = LuxReferenceWindow.Window(
            samples: cut.samples, text: "", seconds: Double(cut.samples.count) / Double(LuxOnnx.sampleRate),
            startSeconds: start, sourceSeconds: seconds)
        LuxReferenceWindow.store(window, forReference: refURL, sampleRate: LuxOnnx.sampleRate, engine: pocketEngine)
        return cut.samples
    }

    /// Chooses and stores, once, every section the voice at `refURL` needs for the engines whose lengths
    /// its master exceeds (Lux 30 s with its transcript, Pocket 10 s). Call after a voice is saved,
    /// imported or its master replaced; sections already stored for this master are kept as they are.
    /// Qwen's section is made by `QwenVoicePrep.prepareEngineFolder` (it needs the model files to know
    /// the encoder's length). Returns the engines whose section was written now.
    @discardableResult
    public static func prepare(referenceURL refURL: URL, refText: String) async -> [String] {
        var written: [String] = []
        let lux = LuxReferenceWindow.storedRendition(forReference: refURL)
        if lux == nil, let samples = try? LuxOnnx.loadMono24k(refURL),
           let window = await LuxReferenceWindow.pick(samples: samples, sampleRate: LuxOnnx.sampleRate, refText: refText),
           LuxReferenceWindow.store(window, forReference: refURL, sampleRate: LuxOnnx.sampleRate) {
            written.append("lux-tts")
        }
        let had = LuxReferenceWindow.storedRendition(forReference: refURL, engine: pocketEngine, requiresText: false) != nil
        if !had, (try? pocketSamples(forReference: refURL)) != nil,
           LuxReferenceWindow.storedRendition(forReference: refURL, engine: pocketEngine, requiresText: false) != nil {
            written.append(pocketEngine)
        }
        return written
    }

    /// Prepares and stores the Qwen section (`engines/qwen3-0.6b/`, <= 256 frames, cut at a sentence end,
    /// its exact transcript) of the voice or take whose master is `refURL`, through the same
    /// `QwenVoicePrep.prepareEngineFolder` the base voice uses. A folder already complete for this master
    /// is read, not recomputed. Returns true when it was computed now; false when it was current, the
    /// models are not installed, or the voice has no transcript.
    ///
    /// `language` (BCP-47, the take's) is what the section's words are checked in; nil lets Whisper detect it.
    @discardableResult
    public static func prepareQwen(referenceURL refURL: URL, refText: String, language: String? = nil, modelsDirectory: URL? = nil,
                                   cacheRoot: URL = StoragePaths.appSupport
        .appendingPathComponent("GloamVoiceStudio/Cache/\(QwenANEModelLocation.folderName)", isDirectory: true)) async -> Bool {
        let text = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let models = modelsDirectory ?? (try? QwenANEModelLocation.resolve()),
              let master = try? Data(contentsOf: refURL) else { return false }
        let key = QwenEngineFiles.sha256Hex(Data(refURL.standardizedFileURL.path.utf8)).prefix(16)
        let prepared = try? await QwenVoicePrep.prepareEngineFolder(
            voiceDir: refURL.deletingLastPathComponent(), masterWAV: master, transcript: text,
            modelsDirectory: models, cacheDirectory: cacheRoot.appendingPathComponent(String(key), isDirectory: true),
            transcribe: sectionTranscriber(language: language))
        return prepared?.origin == .computed
    }

    /// The recogniser that checks a section's words against its transcript (`QwenVoicePrep`): Whisper when a
    /// model is installed (no permission needed, every language Qwen speaks, and it is told the take's
    /// language), else Apple's on-device recogniser for that language. The Apple path alone was en-US only and
    /// needs speech permission; without it a Spanish section's end was never checked, and Bad Bunny's stored
    /// section ended three words after its transcript.
    public static func sectionTranscriber(language: String?) -> @Sendable (Data) async -> String? {
        let hint = language.flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } }
        if let folder = installedWhisperFolder() {
            let whisper = WhisperTranscriber(modelFolder: folder)
            return { wav in
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-section-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard (try? wav.write(to: tmp)) != nil,
                      let t = try? await whisper.transcribe(audioURL: tmp, languageHint: hint) else { return nil }
                let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        return { await LuxReferenceWindow.transcribeWAV($0, language: language) }
    }

    /// The language a take key names ("es", "es-MX"), or nil for "base" and emotion takes.
    public static func language(ofTakeKey key: String) -> String? {
        key != "base" && QwenLanguage.codecName(for: key) != nil ? key : nil
    }

    /// A downloaded Whisper model (Studio's Settings > Speech), best first; nil when none is installed.
    static func installedWhisperFolder() -> URL? {
        let root = StoragePaths.models.appendingPathComponent("whisper", isDirectory: true)
        let variants = [WhisperModelCatalog.defaultVariant] + WhisperModelCatalog.models.map(\.variant)
        for v in variants {
            let dir = root.appendingPathComponent(v, isDirectory: true)
            if ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy({
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }) { return dir }
        }
        return nil
    }
}
