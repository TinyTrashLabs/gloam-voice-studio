import Foundation

/// Several takes become one master: each peak-normalised (so a quiet phone
/// take does not vanish beside a loud one), joined with a short silence,
/// transcripts joined in order. A port of the desktop's `RefAudioCombiner`
/// (StudioKit, which cannot link on iOS) at the phone's 24 kHz; the desktop
/// works at 44.1 kHz but the rule is the same. Pure; tested in the Simulator.
public enum TakeCombiner {
    public static let gapSeconds = 0.25
    public static let peakTarget: Float = 0.98

    public static func combine(_ clips: [(samples: [Float], transcript: String)], sampleRate: Int)
        -> (samples: [Float], transcript: String)
    {
        var out: [Float] = []
        let gap = [Float](repeating: 0, count: Int(Double(sampleRate) * gapSeconds))
        for (i, clip) in clips.enumerated() {
            if i > 0 { out.append(contentsOf: gap) }
            out.append(contentsOf: normalizePeak(clip.samples))
        }
        let transcript = clips.map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (out, transcript)
    }

    public static func normalizePeak(_ samples: [Float], target: Float = peakTarget) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 1e-6 else { return samples }
        let scale = target / peak
        guard abs(scale - 1) > 1e-3 else { return samples }
        return samples.map { max(-1, min(1, $0 * scale)) }
    }
}

/// What the takes section may and may not do. The hygiene numbers are
/// `RecordingCheck`'s (tuned on real takes, 2026-09-09); this decides which
/// of them stop a Save and which only warn.
public enum TakeRules {
    // No length cap: a master may be any reasonable length, and each engine
    // that listens to less picks its own section of it.

    public enum Verdict: Equatable {
        case good
        case warning(String)
        /// Blocks Save.
        case error(String)
    }

    /// Too short to learn from is the one thing a take cannot be saved with;
    /// every other finding is a warning -- the person may know better (a
    /// deliberately quiet read, a room they cannot change).
    public static func verdict(for quality: RecordingCheck.Quality) -> Verdict {
        if quality.seconds < RecordingCheck.minSeconds {
            return .error(String(format: "Too short (%.1fs) — a take needs at least %.0fs.", quality.seconds, RecordingCheck.minSeconds))
        }
        if let problem = quality.problem { return .warning(problem) }
        return .good
    }

    /// Length of the joined master: the takes plus one gap between each pair.
    public static func combinedSeconds(_ durations: [Double]) -> Double {
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) + Double(durations.count - 1) * TakeCombiner.gapSeconds
    }

    /// Why the master cannot be rebuilt right now, or nil when it can.
    public static func saveBlocker(verdicts: [Verdict], combinedSeconds: Double = 0) -> String? {
        if verdicts.isEmpty { return "No takes to build the master from." }
        for case .error(let why) in verdicts { return why }
        return nil
    }

    /// The basic screen's one line about the takes; nil when there are none.
    /// "2 takes · 0:19", then what Save will do or what stops it.
    public static func countLine(count: Int, combinedSeconds: Double, stale: Bool, blocker: String?) -> String? {
        guard count > 0 else { return nil }
        let s = Int(combinedSeconds.rounded())
        var line = "\(count) take\(count == 1 ? "" : "s") · \(String(format: "%d:%02d", s / 60, s % 60))"
        if let blocker { line += " · \(blocker)" }
        else if stale { line += " · Save rebuilds the master" }
        return line
    }

    /// The section footer's length line.
    public static func lengthLine(combinedSeconds: Double) -> String {
        String(format: "%.0fs of takes.", combinedSeconds)
    }
}
