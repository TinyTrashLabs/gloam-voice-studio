// LuxReferenceWindow.swift
// EngineKit — caps an over-long LuxTTS reference clip, transcript included.
//
// LuxTTS conditions on the prompt as one sequence: prompt mel frames + prompt
// tokens + the text to speak, all attended together through a Zipformer whose
// relative positional encoding is log-compressed and saturating
// (CompactRelPositionalEncoding). Nothing errors when the sequence gets long —
// positions just stop being distinguishable and the sampler falls apart.
//
// Measured on this model (2026-08-01), same 11.5s reference clip repeated to
// hold transcript alignment exactly constant, one fixed 84-token line:
//
//     ref len   prompt tok   result
//     11.5s        188       clean, 1.20s of silence in a 5.2s take
//     23.0s        376       clean, 1.20s
//     34.6s        564       clean, 1.20s
//     46.1s        752       clean, 0.95s
//     57.6s        940       COLLAPSE — 2.55s of silence, speech in two
//                            bursts around a dead middle
//
// A real user voice with a 58.6s reference produced exactly the reported
// symptom: 1.7s of dead air, a burst, a 2s hole, another burst. So the cap is
// real but soft, and 30s (matching LuxOnnx.maxReferenceSeconds) sits well
// inside the healthy zone.
//
// Truncating the AUDIO alone is a known, separate bug — see the long note in
// LuxSpeechModel.encodePrompt: the model is then conditioned on text
// describing more speech than it can hear, and hallucinates the difference.
// So the cut has to move both. The audio is cut on frame energy, and the
// transcript for the surviving window is re-derived by transcribing THAT clip
// on-device. Audio and text then describe the same span, which is the
// invariant that matters — and it holds even when the stored transcript never
// matched the recording in the first place.
//
// ASR text is the right transcript here even though ASR makes mistakes: this
// text conditions pacing and phonetics and is never spoken back, and a slip
// that sounds like the audio is harmless. What is NOT harmless is a transcript
// that under-counts the audio — hence the words-per-second gate below.
//
// A reference is never refused for its length: `pick` always returns a
// window. With no on-device recognizer (or an implausible transcription) the
// transcript falls back to the matching share of the master's own, snapped to
// sentence boundaries — see `approximateText`.

import Foundation
import GVoiceKit
import Speech

public enum LuxReferenceWindow {
    /// Matches LuxOnnx.maxReferenceSeconds so both backends agree on what a
    /// usable reference is.
    public static let maxSeconds: Double = 30.0

    public struct Window: Sendable {
        public let samples: [Float]
        public let text: String
        public let seconds: Double
        /// Where the window sits in the master clip.
        public let startSeconds: Double
        public let sourceSeconds: Double
        /// True when the transcript is a proportional slice of the master's own
        /// (no on-device recognizer, or its words failed the density gate), so
        /// it describes the window less exactly than a transcription would.
        /// It is stored like any other (`by: "transcript-slice"`) and never
        /// recomputed: the stored section is the voice's, whatever made it.
        public var approximate = false
    }

    /// `engines/lux-tts/voice.json` — the metadata beside the materialized
    /// window audio (see docs/gvoice-format.md).
    ///
    /// The window is stored as REAL AUDIO, not as offsets into the master.
    /// Offsets would be smaller, but every implementation would then have to
    /// reproduce the cut — including its edge fade — bit-for-bit to condition
    /// the model on the same thing, and a spec that requires re-deriving a
    /// signal is a spec that drifts. Shipping the audio makes the reference
    /// the pack's, not the reader's. `derivedFrom` keeps the provenance so the
    /// window is still traceable to the master it came out of.
    public struct Rendition: Codable, Equatable, Sendable {
        public struct DerivedFrom: Codable, Equatable, Sendable {
            /// Pack-relative path of the master this was cut from.
            public var audio: String?
            public var startSeconds: Double
            public var endSeconds: Double
            /// Length of the master at derivation time. A master that no
            /// longer matches has been replaced, and this window with it.
            public var sourceSeconds: Double
            /// How the transcript was produced: "on-device-asr", "transcript-slice"
            /// (the master's own transcript cut to the span) or "user".
            public var by: String?
            /// SHA-256 of the master's bytes when the section was cut. A section
            /// whose master no longer hashes to this is stale and is replaced.
            /// Absent on sections written before this field existed (accepted).
            public var sourceSha256: String?
            public init(audio: String? = nil, startSeconds: Double, endSeconds: Double,
                        sourceSeconds: Double, by: String? = nil, sourceSha256: String? = nil) {
                self.audio = audio; self.startSeconds = startSeconds; self.endSeconds = endSeconds
                self.sourceSeconds = sourceSeconds; self.by = by; self.sourceSha256 = sourceSha256
            }
        }
        /// Pack-relative path of the window audio.
        public var audio: String
        /// Transcript of the WINDOW, not of the master.
        public var text: String
        public var derivedFrom: DerivedFrom?
        public init(audio: String, text: String, derivedFrom: DerivedFrom? = nil) {
            self.audio = audio; self.text = text; self.derivedFrom = derivedFrom
        }
    }

    /// Where a voice's section for `engine` lives on disk, mirroring its layout
    /// inside a pack (`engines/<engine>/…` beside `source/`). VoiceLibrary
    /// scans `engines/*`, so a section written here travels into every export
    /// without further plumbing.
    static func renditionDir(forReference refURL: URL, engine: String = "lux-tts") -> URL {
        refURL.deletingLastPathComponent().appendingPathComponent("engines/\(engine)")
    }

    public static let renditionAudioName = "ref.wav"
    public static let renditionMetaName = "voice.json"

    /// The voice's own window, or nil when it has none or the master it was
    /// cut from is no longer the file on disk.
    public static func storedRendition(
        forReference refURL: URL, engine: String = "lux-tts", requiresText: Bool = true
    ) -> Rendition? {
        let metaURL = renditionDir(forReference: refURL, engine: engine)
            .appendingPathComponent(renditionMetaName)
        guard let data = try? Data(contentsOf: metaURL),
            let rendition = try? JSONDecoder().decode(Rendition.self, from: data),
            !requiresText || !rendition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // A section cut from a different master than the one on disk is stale.
        if let cutFrom = rendition.derivedFrom?.sourceSha256,
            cutFrom != ReferenceSection.sha256Hex(ofFile: refURL)
        { return nil }
        return rendition
    }

    /// Loads the window's audio at LuxTTS's mel rate. Throws if the file named
    /// by the rendition isn't there or won't decode, so a broken window falls
    /// back to deriving a fresh one rather than conditioning on nothing.
    ///
    /// Only the filename is taken from the rendition: `audio` is a
    /// PACK-relative path, and on disk the file sits in the voice's own
    /// engines directory.
    public static func loadRenditionAudio(
        _ rendition: Rendition, forReference refURL: URL, engine: String = "lux-tts"
    ) throws -> [Float] {
        let url = renditionDir(forReference: refURL, engine: engine)
            .appendingPathComponent((rendition.audio as NSString).lastPathComponent)
        return try LuxOnnx.loadMono24k(url)
    }

    /// Writes a section as the voice's rendition for `engine`: the audio itself
    /// (levelled to the reference standard, so an export -> import round trip
    /// leaves its bytes alone) plus the transcript that matches it and the span
    /// it covers in the master. Returns false when it could not be written.
    @discardableResult
    public static func store(
        _ window: Window, forReference refURL: URL, sampleRate: Int, engine: String = "lux-tts"
    ) -> Bool {
        let dir = renditionDir(forReference: refURL, engine: engine)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent(renditionAudioName)
        let wav = ReferenceSection.wavData(window.samples, sampleRate: sampleRate)
        guard (try? wav.write(to: audioURL, options: .atomic)) != nil else { return false }
        let rendition = Rendition(
            audio: "engines/\(engine)/\(renditionAudioName)",
            text: window.text,
            derivedFrom: Rendition.DerivedFrom(
                audio: "source/\(refURL.lastPathComponent)",
                startSeconds: window.startSeconds,
                endSeconds: window.startSeconds + window.seconds,
                sourceSeconds: window.sourceSeconds,
                by: window.approximate ? "transcript-slice" : "on-device-asr",
                sourceSha256: ReferenceSection.sha256Hex(ofFile: refURL)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rendition) else { return false }
        return (try? data.write(to: dir.appendingPathComponent(renditionMetaName), options: .atomic)) != nil
    }

    /// Plausible speech rates, in words per second, for the windowed clip.
    /// The transcript's job here is to tell the model how much speech the mel
    /// frames contain — LuxTTS derives the output length from the prompt's
    /// frames-per-token ratio — so a transcript that under-counts the audio
    /// inflates that ratio and the predicted duration runs away with it. A
    /// 30s window transcribed as ten words once drove generation long enough
    /// to trip an MLX FFT assertion and abort the process, which is why this
    /// is a hard gate and not a warning.
    private static let minWordsPerSecond = 1.0
    private static let maxWordsPerSecond = 6.0

    /// Cuts `samples` down to a window of at most `maxSeconds` and returns a
    /// transcript that matches it. Returns nil when the reference already fits
    /// (nothing to do) or when a trustworthy window can't be established — the
    /// caller decides what an unusable reference means.
    ///
    /// `refText` is the caller's stored transcript. It describes the WHOLE
    /// clip, so it cannot describe the window; it is used only as a fallback
    /// sanity reference, never carried through.
    public static func fit(
        samples: [Float], sampleRate: Int, refText: String,
        maxSeconds: Double = LuxReferenceWindow.maxSeconds
    ) async -> Window? {
        let seconds = Double(samples.count) / Double(sampleRate)
        guard seconds > maxSeconds, sampleRate > 0 else { return nil }

        // Cut on energy, not on ASR timings. Recognizing the full clip to find
        // a word boundary sounds tidier, but on-device recognition of a 58s
        // file came back with ten words for the first 30s — long-file results
        // are not dependable enough to cut on.
        let cut = window(samples: samples, sampleRate: sampleRate, maxSeconds: maxSeconds)
        let trimmed = cut.samples
        let startSeconds = Double(cut.start) / Double(sampleRate)
        guard Double(trimmed.count) / Double(sampleRate) >= maxSeconds * 0.5 else { return nil }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
            recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lux-window-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? WAVWriter.write(samples: trimmed, sampleRate: sampleRate, to: tmp)) != nil
        else { return nil }

        // Transcribe only the windowed clip: it is what the mel features will
        // describe, and a ~30s clip is well inside what on-device recognition
        // handles reliably.
        guard let text = try? await recognize(url: tmp, recognizer: recognizer) else { return nil }
        let windowSeconds = Double(trimmed.count) / Double(sampleRate)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let rate = Double(words) / windowSeconds
        guard rate >= minWordsPerSecond, rate <= maxWordsPerSecond else { return nil }

        return Window(
            samples: trimmed, text: text, seconds: windowSeconds,
            startSeconds: startSeconds, sourceSeconds: seconds)
    }

    /// The window for a master that may be any length: nil when it already fits
    /// `maxSeconds`, otherwise the best section the engine can hold. Prefers the
    /// on-device transcription of the cut (`fit`); when that is unavailable it
    /// keeps the same audio cut and slices the master's transcript to match
    /// (`approximateText`), so a long reference never turns into a refusal.
    public static func pick(
        samples: [Float], sampleRate: Int, refText: String,
        maxSeconds: Double = LuxReferenceWindow.maxSeconds
    ) async -> Window? {
        let seconds = Double(samples.count) / Double(max(1, sampleRate))
        guard seconds > maxSeconds, sampleRate > 0 else { return nil }
        if let heard = await fit(
            samples: samples, sampleRate: sampleRate, refText: refText, maxSeconds: maxSeconds)
        {
            return heard
        }
        let cut = window(samples: samples, sampleRate: sampleRate, maxSeconds: maxSeconds)
        let windowSeconds = Double(cut.samples.count) / Double(sampleRate)
        let text = approximateText(
            refText, windowStart: cut.start, windowCount: cut.samples.count,
            totalCount: samples.count)
        var w = Window(
            samples: cut.samples, text: text, seconds: windowSeconds,
            startSeconds: Double(cut.start) / Double(sampleRate), sourceSeconds: seconds)
        w.approximate = true
        return w
    }

    static func approximateText(
        _ text: String, windowStart: Int, windowCount: Int, totalCount: Int
    ) -> String {
        ReferenceSection.approximateText(
            text, windowStart: windowStart, windowCount: windowCount, totalCount: totalCount)
    }

    /// On-device transcription of a WAV, or nil when there is no authorized
    /// on-device recognizer or nothing was heard. The `transcribe` hook for
    /// the shared section preparation (QwenVoicePrep.prepareEngineFolder).
    public static func transcribeWAV(_ wav: Data) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
            recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lux-window-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? wav.write(to: tmp)) != nil else { return nil }
        let text = try? await recognize(url: tmp, recognizer: recognizer)
        return (text?.isEmpty == false) ? text : nil
    }

    /// The energy-based cut: start at the first speech (lead-in silence would
    /// otherwise eat the window), end in a pause near the tail where one is
    /// available so the reference doesn't stop mid-phoneme. Mirrors the web
    /// clone wizard's trimToWindow.
    static func window(
        samples: [Float], sampleRate: Int, maxSeconds: Double
    ) -> (samples: [Float], start: Int) {
        ReferenceSection.cut(samples: samples, sampleRate: sampleRate, maxSeconds: maxSeconds)
    }

    /// Transcribes a whole file, every utterance in it.
    ///
    /// The closure-based `recognitionTask(with:resultHandler:)` reports one
    /// `isFinal` result PER UTTERANCE, not one for the file: resuming on the
    /// first of them returns only the opening phrase. That read a 28.5s clip
    /// as eight words, which then inflated the frames-per-token ratio enough
    /// to blow up the duration prediction. Collect every finished
    /// transcription via the delegate instead, and finish on the task's own
    /// completion callback.
    private static func recognize(
        url: URL, recognizer: SFSpeechRecognizer
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let collector = RecognitionCollector()
        return try await withCheckedThrowingContinuation { cont in
            collector.finish = { result in cont.resume(with: result) }
            let task = recognizer.recognitionTask(with: request, delegate: collector)
            collector.keepAlive = task
        }
    }

    /// Accumulates per-utterance transcriptions and resolves once, on whichever
    /// of success/failure arrives first.
    private final class RecognitionCollector: NSObject, SFSpeechRecognitionTaskDelegate {
        private let lock = NSLock()
        private var pieces: [String] = []
        private var done = false
        var finish: ((Result<String, Error>) -> Void)?
        /// SFSpeechRecognitionTask is not retained by the recognizer; without a
        /// strong reference it can be torn down mid-recognition.
        var keepAlive: SFSpeechRecognitionTask?

        private func resolve(_ result: Result<String, Error>) {
            lock.lock()
            guard !done else { return lock.unlock() }
            done = true
            let finish = self.finish
            lock.unlock()
            keepAlive = nil
            finish?(result)
        }

        func speechRecognitionTask(
            _ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult
        ) {
            lock.lock()
            pieces.append(result.bestTranscription.formattedString)
            lock.unlock()
        }

        func speechRecognitionTask(
            _ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool
        ) {
            if !successfully, let error = task.error {
                resolve(.failure(error))
                return
            }
            lock.lock()
            let text = pieces.joined(separator: " ")
            lock.unlock()
            resolve(.success(text))
        }
    }
}
