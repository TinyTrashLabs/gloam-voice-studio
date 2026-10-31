// ReferenceSections.swift
// EngineKit — the stored sections of the engines that take a short reference
// (docs/gvoice-format.md, "Engine sections"), chosen at prep time.
//
// LuxTTS (30 s) keeps its section through LuxReferenceWindow; Qwen's is made by
// QwenVoicePrep.prepareEngineFolder. This file is Pocket's (audio only, so no
// transcript) and the one call a library makes after a voice is saved,
// imported or its master changes: `prepare`.

import AVFoundation
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
    /// Records which `ref.wav` the codes were encoded from (its SHA-256); codes without a matching key are not trusted.
    public static let audio8CodesKeyName = "ref_codes.json"
    /// Audio8's codec rate: its section is stored at least this fine, so nothing above 12 kHz is lost
    /// (a >= 44.1 kHz master keeps its own rate; only a lower one is resampled up).
    public static let audio8SectionRate = 44_100
    static let audio8CodecHop = 2_048.0
    static let audio8Codebooks = 10
    static let audio8SemanticSize: Int32 = 4_096
    static let audio8ResidualSize: Int32 = 1_024

    /// What Audio8 conditions on for one voice: the stored section's audio and its exact transcript,
    /// and where its cached reference codes live.
    public struct Audio8Section: Sendable, Equatable {
        public let audioURL: URL
        public let text: String
        public let seconds: Double
        public var codesURL: URL { audioURL.deletingLastPathComponent().appendingPathComponent(ReferenceSections.audio8CodesName) }
        var codesKeyURL: URL { audioURL.deletingLastPathComponent().appendingPathComponent(ReferenceSections.audio8CodesKeyName) }
    }

    /// Audio8's section for the voice at `refURL` (`engines/audio8/ref.wav` + `voice.json`): the stored one
    /// when it is current for this master, else one chosen now and stored. A master of at most 20 s is
    /// used whole with its full transcript (stored as a section too, so its codes can be cached beside it
    /// and go stale with it); a longer one is cut once by `ReferenceSection.cut` with the Lux transcript
    /// rule. The section is stored at 44.1 kHz or the master's own higher rate. Nil when the voice has no
    /// transcript (Audio8 cannot clone without the exact words) or the master cannot be read. A render
    /// never cuts a section it does not store.
    public static func audio8Section(forReference refURL: URL, refText: String) async -> Audio8Section? {
        let dir = LuxReferenceWindow.renditionDir(forReference: refURL, engine: audio8Engine)
        let audioURL = dir.appendingPathComponent(LuxReferenceWindow.renditionAudioName)
        if let stored = LuxReferenceWindow.storedRendition(forReference: refURL, engine: audio8Engine),
           FileManager.default.fileExists(atPath: audioURL.path) {
            let seconds = audioSeconds(audioURL) ?? stored.derivedFrom.map { $0.endSeconds - $0.startSeconds } ?? 0
            return Audio8Section(audioURL: audioURL, text: stored.text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds)
        }
        let text = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let nativeRate = (try? AVAudioFile(forReading: refURL).processingFormat.sampleRate).map { Int($0.rounded()) } ?? 0
        let rate = max(audio8SectionRate, nativeRate)
        guard let master = try? LuxOnnx.loadMono(refURL, sampleRate: rate), !master.isEmpty else { return nil }
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
        // `store` also removes the codes of whatever section it replaces.
        guard LuxReferenceWindow.store(window, forReference: refURL, sampleRate: rate, engine: audio8Engine) else { return nil }
        return Audio8Section(audioURL: audioURL, text: window.text, seconds: window.seconds)
    }

    private static func audioSeconds(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Whether `values` (`[10, frames]`, row-major) are plausible codes for `seconds` of audio.
    static func audio8CodesAreValid(_ values: [Int32], shape: [Int], seconds: Double) -> Bool {
        guard shape.count == 2, shape[0] == audio8Codebooks, shape[1] > 0, values.count == shape[0] * shape[1] else { return false }
        let frames = shape[1]
        let expected = Int((seconds * Double(audio8SectionRate) / audio8CodecHop).rounded())
        let ceiling = Int((audio8MaxSeconds * Double(audio8SectionRate) / audio8CodecHop).rounded(.up)) + 2
        guard abs(frames - expected) <= 2, frames <= ceiling else { return false }
        for (i, v) in values.enumerated() {
            let limit = i < frames ? audio8SemanticSize : audio8ResidualSize
            if v < 0 || v >= limit { return false }
        }
        return true
    }

    /// The cached reference codes (`[10, T]`, int32) of `section`, or nil unless they were encoded from THIS
    /// `ref.wav` (the recorded SHA-256 matches its bytes; copying, restoring or importing cannot fake that)
    /// and are plausible (shape, frame count for the section's length, every index inside its codebook).
    public static func audio8CachedCodes(for section: Audio8Section) -> (values: [Int32], frames: Int)? {
        guard let keyData = try? Data(contentsOf: section.codesKeyURL),
              let key = try? JSONDecoder().decode([String: String].self, from: keyData),
              let recorded = key["audioSha256"], recorded == ReferenceSection.sha256Hex(ofFile: section.audioURL),
              let npy = try? NPYInt32.read(section.codesURL),
              audio8CodesAreValid(npy.values, shape: npy.shape, seconds: section.seconds) else { return nil }
        return (npy.values, npy.shape[1])
    }

    /// Writes the codes of `section` next to it, with the hash of the audio they were encoded from.
    public static func audio8StoreCodes(_ values: [Int32], frames: Int, for section: Audio8Section) throws {
        guard audio8CodesAreValid(values, shape: [audio8Codebooks, frames], seconds: section.seconds) else {
            throw EngineError.generationFailed(backend: .audio8, message: "encoded reference codes are implausible")
        }
        guard let hash = ReferenceSection.sha256Hex(ofFile: section.audioURL) else {
            throw EngineError.generationFailed(backend: .audio8, message: "cannot hash the section audio")
        }
        try NPYInt32.write(values, shape: [audio8Codebooks, frames], to: section.codesURL)
        try JSONEncoder().encode(["audioSha256": hash]).write(to: section.codesKeyURL, options: .atomic)
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
