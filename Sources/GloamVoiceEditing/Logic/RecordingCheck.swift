import Foundation

/// Whether a clone recording can actually be cloned from -- checked, not
/// assumed.
///
/// The record act used to trust that the person read the script and stored
/// the script as the reference transcript. Ryan (2026-09-09) ad-libbed
/// instead; the transcript disagreed with the audio and Qwen rendered hiss
/// on 6 of 6 tries (Mac probe), while every voice whose recording matched
/// its transcript rendered speech on 6 of 6. The same probe put level and
/// noise second: his clip normalised to −16 dBFS dropped to 1 in 6, and a
/// clean clip with noise added to his signal-to-noise rose to 1 in 6.
///
/// Two pure checks, both tested in the Simulator:
/// - `scriptMatch`: how much of the script was heard, in order (0…1).
/// - `measure`: level, noise floor, clipping, length of the 24 kHz samples,
///   with `Quality.problem` naming the first thing a person can fix.
public enum RecordingCheck {
    /// Below this the take is treated as an ad-lib: what was heard becomes
    /// the transcript, shown for correction (Shane's script read scored 0.97;
    /// Ryan's ad-lib 0.20).
    public static let matchThreshold = 0.9

    // Quality thresholds (dBFS RMS unless noted).
    public static let minSeconds = 3.0
    /// The phone mic records in measurement mode (no AGC), so normal speech at
    /// arm's length lands near −36 dBFS RMS (David's iPhone 15 Pro take,
    /// 2026-09-10: −36.0 over a −66 floor). −25 was set from Mac captures and
    /// Ryan's imported clip (−21/−22) and refused every phone take. Level is
    /// fixed by RecordingCleanup on save; what this floor guards is a take so
    /// faint that levelling it drags the noise up with it.
    public static let minSpeechDb: Float = -45
    public static let minSNRDb: Float = 20       // Ryan 19 (hiss 1/6 even normalised), Shane 30
    public static let maxClippedFraction = 0.001

    public struct Quality: Equatable {
        public let seconds: Double
        public let speechDb: Float       // mean of the louder half of 50 ms blocks
        public let noiseFloorDb: Float   // 5th percentile of the blocks
        public let clippedFraction: Double
        public var snrDb: Float { speechDb - noiseFloorDb }

        public init(seconds: Double, speechDb: Float, noiseFloorDb: Float, clippedFraction: Double) {
            self.seconds = seconds
            self.speechDb = speechDb
            self.noiseFloorDb = noiseFloorDb
            self.clippedFraction = clippedFraction
        }

        /// The first thing wrong, in words the person can act on; nil when
        /// the take is fine.
        public var problem: String? {
            if seconds < RecordingCheck.minSeconds {
                return "That was too short to learn from. Read the whole line, then tap to finish."
            }
            if clippedFraction > RecordingCheck.maxClippedFraction {
                return "That clipped — hold the phone a little further away and try again."
            }
            if speechDb < RecordingCheck.minSpeechDb {
                return "That was too quiet — hold the phone closer and speak up a little."
            }
            if snrDb < RecordingCheck.minSNRDb {
                return "Too much background noise — try somewhere quieter."
            }
            return nil
        }

        /// The same findings for an imported file, where "hold the phone
        /// closer" is no fix: the person can only pick a different clip.
        public var fileProblem: String? {
            if seconds < RecordingCheck.minSeconds {
                return String(format: "That clip is %.1fs of speech — a clone needs at least %.0fs. Pick a longer one.",
                              seconds, RecordingCheck.minSeconds)
            }
            if clippedFraction > RecordingCheck.maxClippedFraction {
                return "That clip is distorted (clipped) — pick a cleaner recording."
            }
            if speechDb < RecordingCheck.minSpeechDb {
                return "That clip is too quiet to learn from — pick one where the voice is closer to the mic."
            }
            if snrDb < RecordingCheck.minSNRDb {
                return "That clip has too much background noise or music — pick one with just the voice."
            }
            return nil
        }
    }

    public static func measure(_ samples: [Float], sampleRate: Int) -> Quality {
        let seconds = Double(samples.count) / Double(sampleRate)
        guard !samples.isEmpty else {
            return Quality(seconds: 0, speechDb: -100, noiseFloorDb: -100, clippedFraction: 0)
        }
        let block = max(1, sampleRate / 20)   // 50 ms
        var levels: [Float] = []
        var i = 0
        while i + block <= samples.count {
            var acc: Float = 0
            for s in samples[i..<(i + block)] { acc += s * s }
            let rms = (acc / Float(block)).squareRoot()
            levels.append(rms > 1e-6 ? 20 * log10(rms) : -120)
            i += block
        }
        if levels.isEmpty { levels = [-120] }
        levels.sort()
        let floor = levels[min(levels.count - 1, levels.count / 20)]
        let upper = levels[(levels.count / 2)...]
        let speech = upper.reduce(0, +) / Float(upper.count)
        let clipped = samples.reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }
        return Quality(seconds: seconds, speechDb: speech, noiseFloorDb: floor,
                       clippedFraction: Double(clipped) / Double(samples.count))
    }

    /// Fraction of the script's words that were heard, in order (longest
    /// common subsequence over lower-cased word tokens). Punctuation and
    /// case are ignored; "you are" vs "you're" costs a word, which is why the
    /// threshold sits at 0.9 rather than 1.
    public static func scriptMatch(heard: String, script: String) -> Double {
        let a = words(script), b = words(heard)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return Double(prev[b.count]) / Double(a.count)
    }

    /// The other direction: how much of what was HEARD is in the script.
    ///
    /// `scriptMatch` divides by the script, so it only asks "was the script
    /// read". Someone who reads the script and then keeps talking still
    /// scores 1.0, and storing the script as the transcript then leaves part
    /// of the reference audio unaccounted for. LuxTTS paces every render by
    /// the reference's frames per token, so that surplus audio both stretches
    /// the render and gives the model reference speech to continue from —
    /// measured on David's iPhone take (2026-09-11): 11.2 chars/s of
    /// transcript against a bundled pack's 17.4, and the same line came back
    /// 13.6 s instead of 9.1 s, with words from the recording in it.
    public static func transcriptCoverage(heard: String, script: String) -> Double {
        let a = words(script), b = words(heard)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            prev = cur
        }
        return Double(prev[b.count]) / Double(b.count)
    }

    /// Below this, the recording says more than the script does, and what was
    /// heard is the honest transcript.
    public static let coverageThreshold = 0.9

    /// Numbers, times and ordinals in words on both sides (`SpokenWords`):
    /// the recogniser writes "4:30" for "four thirty".
    private static func words(_ text: String) -> [String] { SpokenWords.words(text) }
}
