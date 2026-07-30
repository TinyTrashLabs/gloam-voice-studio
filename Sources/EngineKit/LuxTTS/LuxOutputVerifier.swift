// LuxOutputVerifier.swift
// EngineKit — trims LuxTTS's occasional garbled lead-in.
//
// The flow-matching sampler is stochastic (a fresh Gaussian draw seeds every
// call): the same text + reference clip can come out clean or with a short
// garbled word bled in from the end of the prompt, depending on the draw.
// Regenerating on a mismatch isn't affordable here — LuxTTS runs as
// unattended background TTS in a radio app, and a full re-synthesis is real
// GPU cost per line. Instead: one on-device ASR pass (zero downloads,
// zero network) gets word-level timestamps for what was actually said:
// since we already know the target text (it's what we asked LuxTTS to
// speak), we can find exactly where in the audio it actually starts and
// trim off anything before that — no regeneration, no guessing a fixed
// frame count.
//
// Deliberately best-effort: if Speech Recognition isn't authorized or ASR
// fails, the audio is returned unmodified rather than blocking synthesis.

import Foundation
import Speech

enum LuxLeadInTrimmer {
    /// Requests Speech Recognition authorization once. Call at a deliberate
    /// moment (backend load), not implicitly inside every synthesize() call,
    /// so the system permission prompt appears predictably.
    static func requestAuthorizationIfNeeded() async {
        if SFSpeechRecognizer.authorizationStatus() != .notDetermined { return }
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Returns `samples` trimmed to start where `expectedText` actually
    /// begins, per on-device ASR word timing — or unmodified if ASR is
    /// unavailable, fails, or finds no leading mismatch to cut.
    static func trimLeadIn(
        samples: [Float], sampleRate: Int, expectedText: String
    ) async -> [Float] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
            recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { return samples }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lux-trim-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: tmp)
        } catch { return samples }

        guard let segments = try? await recognize(url: tmp, recognizer: recognizer) else {
            return samples
        }
        guard let cutTime = leadInCutoff(segments: segments, expectedText: expectedText) else {
            return samples
        }

        // Small pre-roll so the trim doesn't clip the real first phoneme's
        // onset, plus a short fade-in over the cut to avoid a click.
        let preRoll: Float = 0.06
        var cutSample = max(0, Int((cutTime - preRoll) * Float(sampleRate)))
        cutSample = min(cutSample, max(samples.count - 1, 0))
        guard cutSample > 0 else { return samples }

        var trimmed = Array(samples[cutSample...])
        let fadeSamples = min(trimmed.count, Int(0.02 * Float(sampleRate)))
        for i in 0 ..< fadeSamples {
            trimmed[i] *= Float(i) / Float(fadeSamples)
        }
        return trimmed
    }

    /// A plain, Sendable snapshot of the one field of SFTranscriptionSegment
    /// this needs — SFTranscriptionSegment itself isn't Sendable, so it can't
    /// cross the recognitionTask callback's continuation boundary directly.
    private struct WordTiming: Sendable {
        let word: String
        let timestamp: TimeInterval
    }

    private static func recognize(
        url: URL, recognizer: SFSpeechRecognizer
    ) async throws -> [WordTiming] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let lock = NSLock()
            recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                if let error {
                    resumed = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                let timings = result.bestTranscription.segments.map {
                    WordTiming(word: $0.substring, timestamp: $0.timestamp)
                }
                cont.resume(returning: timings)
            }
        }
    }

    /// Finds the timestamp where `expectedText`'s word sequence reliably
    /// begins within the recognized `segments`, by locating the earliest
    /// contiguous run of segments whose words match the target in order. Nil
    /// if the match starts at segment 0 (no leading mismatch to trim) or no
    /// confident match is found at all (don't trim blind).
    private static func leadInCutoff(
        segments: [WordTiming], expectedText: String
    ) -> Float? {
        let target = words(in: expectedText)
        guard !target.isEmpty else { return nil }
        let recognized = segments.map { words(in: $0.word).first ?? "" }

        // Try each candidate start index; keep the earliest one where the
        // target's words appear in order (allowing ASR to drop/mishear a
        // few) for at least 70% of the target — good enough to trust the
        // alignment without demanding a perfect transcript.
        for startIdx in 0 ..< recognized.count {
            var ti = 0
            for i in startIdx ..< recognized.count where ti < target.count {
                if recognized[i] == target[ti] { ti += 1 }
            }
            if Double(ti) >= Double(target.count) * 0.7 {
                return startIdx == 0 ? nil : Float(segments[startIdx].timestamp)
            }
        }
        return nil
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .split(separator: " ")
            .map(String.init)
    }
}
