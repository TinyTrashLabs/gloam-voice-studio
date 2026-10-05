import Foundation

/// The cleanup every reference recording gets on its way into the voice
/// store: silence trimmed off both ends and the speech levelled to a fixed
/// loudness. Both cloners read the reference as-is, so a quiet or padded
/// take used to stay quiet and padded forever.
///
/// Why level: the 2026-09-09 probe rendered Ryan's quiet take (−22 dBFS)
/// through Qwen 6 times with its true transcript -- 3 came out as hiss;
/// the same take normalised to −16 dBFS -- 1 did. Why trim: the reference
/// codes prime the talker's first frames, and a long silent tail primes
/// silence. Pure; tested in the Simulator.
public enum RecordingCleanup {
    /// Speech RMS after levelling (mean of the louder half of 50 ms blocks).
    public static let targetSpeechDb: Float = -18
    /// Never push a peak past this; a take whose peaks would exceed it is
    /// levelled to the peak instead.
    public static let peakCeiling: Float = 0.95
    /// Blocks under this are silence for trimming.
    public static let trimFloorDb: Float = -45
    /// Kept on each side of the speech so the first word is not clipped off.
    public static let padSeconds = 0.15

    public static func clean(_ samples: [Float], sampleRate: Int) -> [Float] {
        level(trim(samples, sampleRate: sampleRate), sampleRate: sampleRate)
    }

    /// Cut leading and trailing silence, keeping `padSeconds` around the speech.
    public static func trim(_ samples: [Float], sampleRate: Int) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let block = max(1, sampleRate / 20)
        let floor = pow(10, trimFloorDb / 20)
        var first: Int? = nil, last: Int? = nil
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + block)
            var acc: Float = 0
            for s in samples[i..<end] { acc += s * s }
            if (acc / Float(end - i)).squareRoot() > floor {
                if first == nil { first = i }
                last = end
            }
            i = end
        }
        guard let first, let last else { return samples }   // all silence: leave it to the quality check
        let pad = Int(padSeconds * Double(sampleRate))
        return Array(samples[max(0, first - pad)..<min(samples.count, last + pad)])
    }

    /// Scale so the speech sits at `targetSpeechDb`, unless that would push a
    /// peak past `peakCeiling`, in which case the peak wins.
    public static func level(_ samples: [Float], sampleRate: Int) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let speech = RecordingCheck.measure(samples, sampleRate: sampleRate).speechDb
        guard speech > -100 else { return samples }
        var gain = pow(10, (targetSpeechDb - speech) / 20)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        if peak * gain > peakCeiling { gain = peakCeiling / peak }
        if abs(gain - 1) < 0.01 { return samples }
        return samples.map { $0 * gain }
    }
}
