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
    @discardableResult
    public static func prepareQwen(referenceURL refURL: URL, refText: String, modelsDirectory: URL? = nil,
                                   cacheRoot: URL = StoragePaths.appSupport
        .appendingPathComponent("GloamVoiceStudio/Cache/\(QwenANEModelLocation.folderName)", isDirectory: true)) async -> Bool {
        let text = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let models = modelsDirectory ?? (try? QwenANEModelLocation.resolve()),
              let master = try? Data(contentsOf: refURL) else { return false }
        let key = QwenEngineFiles.sha256Hex(Data(refURL.standardizedFileURL.path.utf8)).prefix(16)
        let prepared = try? await QwenVoicePrep.prepareEngineFolder(
            voiceDir: refURL.deletingLastPathComponent(), masterWAV: master, transcript: text,
            modelsDirectory: models, cacheDirectory: cacheRoot.appendingPathComponent(String(key), isDirectory: true),
            transcribe: { await LuxReferenceWindow.transcribeWAV($0) })
        return prepared?.origin == .computed
    }
}
