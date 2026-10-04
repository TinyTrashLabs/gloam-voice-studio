// ReferenceSection.swift
// GVoiceKit — the one place a long reference is cut down for an engine that
// conditions on less (docs/gvoice-format.md, "Engine sections").
//
// A voice's master (source/ref.wav + its full transcript) may be any length.
// An engine with a shorter limit does not pick a slice while it renders: the
// section is chosen ONCE, when the voice is prepared, and stored in the pack
// under that engine's folder (engines/<engine>/ref.wav plus its exact
// transcript and the span it covers). Renders only read what is stored.
//
// This file is the pure part (no frameworks, no engines): the cut, the
// transcript slice, hashes and the WAV bytes of a stored section. The
// engine-specific callers (EngineKit's LuxTTS/Pocket lanes, QwenANE's voice
// prep) all go through it, so macOS Studio and the iOS apps cut identically.

import CryptoKit
import Foundation

public enum ReferenceSection {
    public static let audioName = "ref.wav"

    /// SHA-256 of a file's bytes as 64 lowercase hex digits; nil when unreadable.
    /// Remembered per (path, size, mtime) so a render's staleness check does not
    /// re-hash a multi-megabyte master every line.
    public static func sha256Hex(ofFile url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.standardizedFileURL.path)|\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        hashLock.lock(); defer { hashLock.unlock() }
        if let hit = hashes[key] { return hit }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hex = sha256Hex(data)
        if hashes.count > 64 { hashes.removeAll() }
        hashes[key] = hex
        return hex
    }
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated(unsafe) private static var hashes: [String: String] = [:]
    private static let hashLock = NSLock()

    /// The bytes of a stored section: mono 16-bit PCM WAV, levelled to the
    /// reference standard. Writing the standard's own output means an export ->
    /// import round trip (which applies the standard to every engine wav) leaves
    /// the bytes alone, so the hashes recorded beside it stay true.
    public static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples { pcm += le(Int16(max(-1, min(1, s)) * 32767)) }
        var d = Data("RIFF".utf8); d += le(UInt32(36 + pcm.count)); d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)); d += le(UInt16(1)); d += le(UInt16(1)); d += le(UInt32(sampleRate))
        d += le(UInt32(sampleRate * 2)); d += le(UInt16(2)); d += le(UInt16(16))
        d += Data("data".utf8); d += le(UInt32(pcm.count)); d += pcm
        return ReferenceStandard.applied(to: d)
    }

    /// The share of `text` that sits under a cut of the master, by position in
    /// it, with each edge moved to the nearest sentence end when one is close —
    /// so the slice starts and stops on whole sentences, as the audio cut does
    /// in pauses. Used when no on-device transcription of the cut is available;
    /// a transcription of the cut itself is better. Stored like any other.
    public static func approximateText(_ text: String, windowStart: Int, windowCount: Int, totalCount: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, totalCount > 0 else { return text }
        var from = Int((Double(windowStart) / Double(totalCount) * Double(words.count)).rounded())
        var to = Int((Double(windowStart + windowCount) / Double(totalCount) * Double(words.count)).rounded())
        from = max(0, min(words.count - 1, from))
        to = max(from + 1, min(words.count, to))
        func isStart(_ i: Int) -> Bool {
            i == 0 || i == words.count || (words[i - 1].last.map { ".!?".contains($0) } ?? false)
        }
        let slack = max(2, (to - from) / 6)
        func snap(_ i: Int) -> Int {
            for d in 0 ... slack {
                if i + d <= words.count, isStart(i + d) { return i + d }
                if i - d >= 0, isStart(i - d) { return i - d }
            }
            return i
        }
        let a = snap(from), b = snap(to)
        return (b > a ? words[a ..< b] : words[from ..< to]).joined(separator: " ")
    }

    /// Plausible speech rates (words per second) for a transcript of a cut: a
    /// transcript that under-counts its audio inflates LuxTTS's frames-per-token
    /// ratio and the predicted duration runs away with it.
    public static let minWordsPerSecond = 1.0
    public static let maxWordsPerSecond = 6.0

    /// The text for a cut: `heard` (a transcription of the cut) when it reads at a
    /// plausible rate, else the master's own transcript sliced to the same span.
    /// Returns whether it is the slice.
    public static func text(heard: String?, transcript: String, cutSeconds: Double,
                            start: Int, count: Int, total: Int) -> (text: String, approximate: Bool) {
        if let heard {
            let words = heard.split(whereSeparator: { $0.isWhitespace }).count
            let rate = Double(words) / max(0.1, cutSeconds)
            if rate >= minWordsPerSecond, rate <= maxWordsPerSecond { return (heard, false) }
        }
        return (approximateText(transcript, windowStart: start, windowCount: count, totalCount: total), true)
    }

    /// The energy-based cut: start at the first speech (lead-in silence would
    /// otherwise eat the window), end in a pause near the tail where one is
    /// available so the reference doesn't stop mid-phoneme. Returns the whole
    /// clip when it already fits. Mirrors the web clone wizard's trimToWindow.
    public static func cut(
        samples: [Float], sampleRate: Int, maxSeconds: Double
    ) -> (samples: [Float], start: Int) {
        let maxSamples = Int(maxSeconds * Double(sampleRate))
        guard samples.count > maxSamples, maxSamples > 0 else { return (samples, 0) }

        let frame = max(1, Int(Double(sampleRate) * 0.02))
        let frameCount = (samples.count + frame - 1) / frame
        var energy = [Float](repeating: 0, count: frameCount)
        var loudest: Float = 0
        for f in 0 ..< frameCount {
            let from = f * frame, to = min(from + frame, samples.count)
            var sumSq: Float = 0
            for i in from ..< to { sumSq += samples[i] * samples[i] }
            let e = (sumSq / Float(to - from)).squareRoot()
            energy[f] = e
            loudest = max(loudest, e)
        }
        let floor = max(loudest * 0.08, 0.008)

        // Skip lead-in silence, but only lead-in: search a bounded prefix. An
        // unbounded scan slides the whole window down the clip whenever a quiet
        // opening sits under a floor set by a loud passage later — on a 58s
        // reference that silently selected the LAST 30 seconds, a different
        // part of the recording than the stored transcript describes.
        //
        // Scoring candidate windows by speech DENSITY was tried and reverted
        // (2026-08-01). It measured no benefit — on a real 28.5s clone the
        // opening was already the densest 15s (60.9% speech vs 53-58% later) —
        // and it reproduced the sliding bug, because a quiet opening scores as
        // silence against a floor set by a louder passage. The pausiness it was
        // meant to fix was DRAWL, which density cannot see: that speaker had
        // high density and still read slow. Per-voice pace is the control for
        // that.
        let onsetLimit = min(frameCount, Int(5.0 / 0.02))
        var startFrame = 0
        while startFrame < onsetLimit, energy[startFrame] <= floor { startFrame += 1 }
        if startFrame >= onsetLimit { startFrame = 0 }
        var start = max(0, startFrame * frame - Int(Double(sampleRate) * 0.1))
        start = min(start, samples.count - maxSamples)
        var end = start + maxSamples

        let searchFloorFrame = (end - Int(Double(maxSamples) * 0.25)) / frame
        let minQuietFrames = 10  // 200 ms
        var quietRun = 0
        var f = end / frame - 1
        while f >= max(0, searchFloorFrame) {
            if energy[f] <= floor {
                quietRun += 1
            } else {
                if quietRun >= minQuietFrames {
                    let cut = min(end, (f + 1) * frame + Int(Double(sampleRate) * 0.08))
                    if cut - start >= Int(Double(maxSamples) * 0.6) { end = cut }
                    break
                }
                quietRun = 0
            }
            f -= 1
        }

        var out = Array(samples[start ..< end])
        let fade = min(out.count / 2, Int(Double(sampleRate) * 0.01))
        for i in 0 ..< fade {
            let ramp = Float(i) / Float(fade)
            out[i] *= ramp
            out[out.count - 1 - i] *= ramp
        }
        return (out, start)
    }
}
