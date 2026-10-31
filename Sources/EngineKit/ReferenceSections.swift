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

    public static let audio8Engine = "audio8"
    /// Audio8 conditions on at most this much reference: its 2,048-position context is shared by the
    /// reference codes (about 21.5 frames/s), both transcripts and the output.
    public static let audio8MaxSeconds = 20.0
    public static let audio8CodesName = "ref_codes.npy"

    /// What Audio8 conditions on for one voice: the stored section's audio and its exact transcript,
    /// and where its cached reference codes live.
    public struct Audio8Section: Sendable, Equatable {
        public let audioURL: URL
        public let text: String
        public let seconds: Double
        public var codesURL: URL { audioURL.deletingLastPathComponent().appendingPathComponent(ReferenceSections.audio8CodesName) }
    }

    /// Audio8's section for the voice at `refURL` (`engines/audio8/ref.wav` + `voice.json`): the stored one
    /// when it is current for this master, else one chosen now and stored. A master of at most 20 s is
    /// used whole with its full transcript (stored as a section too, so its codes can be cached beside it
    /// and go stale with it); a longer one is cut once by `ReferenceSection.cut` with the Lux transcript
    /// rule. Nil when the voice has no transcript (Audio8 cannot clone without the exact words) or the
    /// master cannot be read. A render never cuts a section it does not store.
    public static func audio8Section(forReference refURL: URL, refText: String) async -> Audio8Section? {
        let dir = LuxReferenceWindow.renditionDir(forReference: refURL, engine: audio8Engine)
        let audioURL = dir.appendingPathComponent(LuxReferenceWindow.renditionAudioName)
        if let stored = LuxReferenceWindow.storedRendition(forReference: refURL, engine: audio8Engine),
           FileManager.default.fileExists(atPath: audioURL.path) {
            let seconds = stored.derivedFrom.map { $0.endSeconds - $0.startSeconds } ?? 0
            return Audio8Section(audioURL: audioURL, text: stored.text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds)
        }
        let text = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let master = try? LuxOnnx.loadMono24k(refURL), !master.isEmpty else { return nil }
        let rate = LuxOnnx.sampleRate
        let seconds = Double(master.count) / Double(rate)
        let window: LuxReferenceWindow.Window
        if seconds > audio8MaxSeconds {
            guard let picked = await LuxReferenceWindow.pick(
                samples: master, sampleRate: rate, refText: text, maxSeconds: audio8MaxSeconds) else { return nil }
            window = picked
        } else {
            var whole = LuxReferenceWindow.Window(
                samples: master, text: text, seconds: seconds, startSeconds: 0, sourceSeconds: seconds)
            whole.approximate = true   // the master's own transcript, "transcript-slice"
            window = whole
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(audio8CodesName))   // codes of a replaced section
        guard LuxReferenceWindow.store(window, forReference: refURL, sampleRate: rate, engine: audio8Engine) else { return nil }
        return Audio8Section(audioURL: audioURL, text: window.text, seconds: window.seconds)
    }

    /// The cached reference codes (`[10, T]`, int32) of `section`, or nil when absent, unreadable, the wrong
    /// shape, or older than the section's audio (the section was replaced).
    public static func audio8CachedCodes(for section: Audio8Section) -> (values: [Int32], frames: Int)? {
        let fm = FileManager.default
        func modified(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        guard let codesDate = modified(section.codesURL), let audioDate = modified(section.audioURL),
              codesDate.addingTimeInterval(10) >= audioDate,   // an import rewrites both files within moments
              let npy = try? NPYInt32.read(section.codesURL),
              npy.shape.count == 2, npy.shape[0] == 10, npy.shape[1] > 0 else { return nil }
        return (npy.values, npy.shape[1])
    }

    /// Writes the codes of `section` next to it.
    public static func audio8StoreCodes(_ values: [Int32], frames: Int, for section: Audio8Section) throws {
        try NPYInt32.write(values, shape: [10, frames], to: section.codesURL)
    }

    /// Chooses and stores, once, every section the voice at `refURL` needs for the engines whose lengths
    /// its master exceeds (Lux 30 s with its transcript, Pocket 10 s, Audio8 20 s with its transcript). Call after a voice is saved,
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
        if LuxReferenceWindow.storedRendition(forReference: refURL, engine: audio8Engine) == nil,
           await audio8Section(forReference: refURL, refText: refText) != nil {
            written.append(audio8Engine)
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
            language: language, transcribe: sectionTranscriber(language: language))
        return prepared?.origin == .computed
    }

    /// The recogniser that checks a section's words against its transcript (`QwenVoicePrep`): Whisper when a
    /// model is installed (no permission needed, every language Qwen speaks, and it is told the take's
    /// language), else Apple's on-device recogniser for that language. The Apple path alone was en-US only and
    /// needs speech permission; without it a Spanish section's end was never checked, and Bad Bunny's stored
    /// section ended three words after its transcript.
    public static func sectionTranscriber(language: String?) -> @Sendable (Data) async -> String? {
        let hint = language.flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } }
            .flatMap { $0.count == 2 ? $0 : nil }  // "auto"/"spanish" are not Whisper codes: nil detects
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
