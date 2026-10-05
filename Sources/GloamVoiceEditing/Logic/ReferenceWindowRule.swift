import AVFoundation
import Foundation
import GVoiceKit

/// `engines/lux-tts/voice.json`, the way docs/gvoice-format.md spells it:
/// GVoiceKit's `ReferenceWindowRendition`, the very type EngineKit reads
/// (`LuxReferenceWindow.Rendition`). It records the master's SHA-256, so a
/// new master makes a hand-set window stale.
public typealias ReferenceWindowMeta = ReferenceWindowRendition

/// The rules behind the reference-window editor: how a window may sit in
/// the master, the cut "Propose" offers, and the gate on its transcript.
/// Pure. The cut and the sentence ending are GVoiceKit's `ReferenceSection`
/// (the engines' own), so a window made here is one the engine would have
/// made for itself.
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
    public static let minWordsPerSecond = ReferenceSection.minWordsPerSecond
    public static let maxWordsPerSecond = ReferenceSection.maxWordsPerSecond

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

    /// The provenance beside a window, as the format spells it. `master` is
    /// the master file the window was cut from: its SHA-256 is recorded, so a
    /// new master invalidates the window (`LuxReferenceWindow.storedRendition`).
    public static func derivedFrom(bounds: Bounds, sourceSeconds: Double, transcribedOnDevice: Bool,
                                   master: URL? = nil) -> ReferenceWindowMeta.DerivedFrom {
        .init(audio: "source/ref.wav", startSeconds: bounds.start, endSeconds: bounds.end,
              sourceSeconds: sourceSeconds, by: transcribedOnDevice ? "on-device-asr" : "user",
              sourceSha256: master.flatMap(ReferenceSection.sha256Hex(ofFile:)))
    }

    /// Whether a stored window was cut from a different master than `master`
    /// (a window written before the hash was recorded is not stale).
    public static func isStale(_ window: ReferenceWindowMeta, master: URL) -> Bool {
        guard let cutFrom = window.derivedFrom?.sourceSha256 else { return false }
        return cutFrom != ReferenceSection.sha256Hex(ofFile: master)
    }

    /// The energy-based cut (`ReferenceSection.cut`, the engines' own):
    /// first speech to a pause near the tail. The whole clip when it fits.
    public static func cut(samples: [Float], sampleRate: Int, maxSeconds: Double) -> (samples: [Float], start: Int) {
        ReferenceSection.cut(samples: samples, sampleRate: sampleRate, maxSeconds: maxSeconds)
    }

    public struct Proposal: Equatable {
        public var bounds: Bounds
        /// The master's transcript sliced to the window and ended on the same
        /// sentence as the audio: a draft until the window is transcribed.
        public var text: String
    }

    /// What "Propose" offers: `cut` to `proposedSeconds`, then
    /// `ReferenceSection.endAtSentence` so the window ends on a complete
    /// sentence and a pause (a continuing engine carries on a sentence a
    /// reference stops in the middle of). `transcript` is the master's.
    public static func propose(samples: [Float], sampleRate: Int, transcript: String,
                               seconds: Double = proposedSeconds) -> Proposal {
        let total = samples.count
        let cut = cut(samples: samples, sampleRate: sampleRate, maxSeconds: seconds)
        let draft = ReferenceSection.approximateText(transcript, windowStart: cut.start,
                                                     windowCount: cut.samples.count, totalCount: total)
        let ended = ReferenceSection.endAtSentence(samples: cut.samples, text: draft, sampleRate: sampleRate)
        let start = Double(cut.start) / Double(sampleRate)
        let end = start + Double(ended.samples.count) / Double(sampleRate)
        return Proposal(bounds: Bounds(start: start, end: min(end, Double(total) / Double(sampleRate))), text: ended.text)
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
