import AVFoundation
import Foundation
import GVoiceKit

/// The rules behind the reference-window editor: how a window may sit in
/// the master, the energy-based cut "Propose" offers, and the gate on its
/// transcript. Pure; tested in the Simulator.
///
/// The cut is a port of `LuxReferenceWindow.window` (EngineKit keeps it
/// internal) and the gate uses that file's numbers, so a window made here
/// is one the engine would have made for itself -- the point of the format
/// carrying it (docs/gvoice-format.md, "The lux-tts reference window").
/// `engines/lux-tts/voice.json`, the way docs/gvoice-format.md spells it.
/// EngineKit's `LuxReferenceWindow.Rendition` reads the same keys but has
/// no public initialiser, so the phone writes through this mirror.
public struct ReferenceWindowMeta: Codable, Equatable {
    public struct DerivedFrom: Codable, Equatable {
        /// Pack-relative path of the master this was cut from.
        public var audio: String?
        public var startSeconds: Double
        public var endSeconds: Double
        /// Length of the master at derivation time.
        public var sourceSeconds: Double
        /// "on-device-asr" or "user".
        public var by: String?

        public init(audio: String? = nil, startSeconds: Double, endSeconds: Double, sourceSeconds: Double, by: String? = nil) {
            self.audio = audio; self.startSeconds = startSeconds; self.endSeconds = endSeconds
            self.sourceSeconds = sourceSeconds; self.by = by
        }
    }
    public var audio: String
    /// Transcript of the WINDOW, not of the master.
    public var text: String
    public var derivedFrom: DerivedFrom?

    public init(audio: String, text: String, derivedFrom: DerivedFrom? = nil) {
        self.audio = audio; self.text = text; self.derivedFrom = derivedFrom
    }
}

public enum ReferenceWindowRule {
    /// Shorter than this and there is nothing to learn from.
    public static let minSeconds = RecordingCheck.minSeconds
    /// The longest window a person can set by hand (LuxTTS's span). Equal to
    /// EngineKit's `LuxReferenceWindow.maxSeconds`, which this package does
    /// not link: the Studio app's tests pin the two together. Masters are not
    /// limited by it: an engine picks its own section of a longer one.
    public static let maxSeconds = 30.0
    /// Past this the editor offers a window: cost is set by the prompt, and
    /// a window this long is what "Propose" cuts to (the radio app's rule).
    public static let adviseAboveSeconds = 20.0
    public static let proposedSeconds = 15.0

    /// Plausible speech rates, in words per second. Under-counting audio
    /// inflates LuxTTS's frames-per-token ratio and the predicted duration
    /// runs away with it (a 30 s window read as ten words once aborted the
    /// process), which is why this is a gate and not a note.
    public static let minWordsPerSecond = 1.0
    public static let maxWordsPerSecond = 6.0

    public struct Bounds: Equatable {
        public var start: Double
        public var end: Double
        public var seconds: Double { end - start }
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Keep a window inside the master and inside the engine's limits. The
    /// edge that moved wins: dragging start into end pushes end along, and
    /// the other way round.
    public static func clamp(start: Double, end: Double, sourceSeconds: Double, movedStart: Bool) -> Bounds {
        let longest = min(maxSeconds, sourceSeconds)
        let shortest = min(minSeconds, sourceSeconds)
        var s = max(0, min(start, sourceSeconds))
        var e = max(0, min(end, sourceSeconds))
        if movedStart {
            if e - s < shortest { e = min(sourceSeconds, s + shortest); s = e - shortest }
            if e - s > longest { e = s + longest }
        } else {
            if e - s < shortest { s = max(0, e - shortest); e = s + shortest }
            if e - s > longest { s = e - longest }
        }
        return Bounds(start: max(0, s), end: min(sourceSeconds, e))
    }

    public static func wordsPerSecond(_ text: String, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(text.split(whereSeparator: { $0.isWhitespace }).count) / seconds
    }

    /// Nil when the words plausibly cover the audio; else why not.
    public static func transcriptProblem(_ text: String, seconds: Double) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return "The window needs its words." }
        let rate = wordsPerSecond(text, seconds: seconds)
        if rate < minWordsPerSecond {
            return String(format: "%d words for %.0fs is too few — the transcript must cover the audio.", words, seconds)
        }
        if rate > maxWordsPerSecond {
            return String(format: "%d words for %.0fs is too many — more than the audio can hold.", words, seconds)
        }
        return nil
    }

    /// "0:00–0:18".
    public static func rangeLabel(start: Double, end: Double) -> String {
        "\(VoiceTime.string(start))–\(VoiceTime.string(end))"
    }

    /// The provenance beside a window, as the format spells it.
    public static func derivedFrom(bounds: Bounds, sourceSeconds: Double, transcribedOnDevice: Bool)
        -> ReferenceWindowMeta.DerivedFrom
    {
        .init(audio: "source/ref.wav", startSeconds: bounds.start, endSeconds: bounds.end,
              sourceSeconds: sourceSeconds, by: transcribedOnDevice ? "on-device-asr" : "user")
    }

    /// The energy-based cut: start at the first speech (lead-in silence
    /// would otherwise eat the window), end in a pause near the tail where
    /// one is available so the reference does not stop mid-phoneme. Returns
    /// the whole clip when it already fits.
    public static func cut(samples: [Float], sampleRate: Int, maxSeconds: Double) -> (samples: [Float], start: Int) {
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

        // Skip lead-in silence, but only lead-in: an unbounded scan slides
        // the window down the clip whenever a quiet opening sits under a
        // floor set by a loud passage later.
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

    /// The window's samples, with the same short fade the cut applies so a
    /// hand-placed edge does not click.
    public static func slice(_ samples: [Float], sampleRate: Int, bounds: Bounds) -> [Float] {
        let a = max(0, min(samples.count, Int(bounds.start * Double(sampleRate))))
        let b = max(a, min(samples.count, Int(bounds.end * Double(sampleRate))))
        var out = Array(samples[a ..< b])
        let fade = min(out.count / 2, Int(Double(sampleRate) * 0.01))
        for i in 0 ..< fade {
            let ramp = Float(i) / Float(fade)
            out[i] *= ramp
            out[out.count - 1 - i] *= ramp
        }
        return out
    }

    /// Peak envelope of a clip in `bins` columns, 0…1, for a waveform.
    public static func envelope(_ samples: [Float], bins: Int) -> [Float] {
        guard bins > 0, !samples.isEmpty else { return [Float](repeating: 0, count: max(0, bins)) }
        let per = max(1, samples.count / bins)
        var out = [Float](repeating: 0, count: bins)
        var peak: Float = 0
        for b in 0 ..< bins {
            let from = b * per, to = b == bins - 1 ? samples.count : min(samples.count, from + per)
            var m: Float = 0
            if from < to { for i in from ..< to { m = max(m, abs(samples[i])) } }
            out[b] = m
            peak = max(peak, m)
        }
        return peak > 0 ? out.map { $0 / peak } : out
    }
}
