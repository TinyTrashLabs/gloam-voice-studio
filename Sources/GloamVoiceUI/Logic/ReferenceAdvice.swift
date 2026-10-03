import Foundation

/// When a cloned voice renders badly, the recording is the usual cause
/// (memories luxtts-reference-rate, qwen-clone-recording-acceptance): noise
/// the model learns as voice, a transcript that does not cover the audio
/// (heard as slow, mushy speech that says extra words), or too little of it.
/// Stricter than RecordingCheck's accept gate on purpose: that gate decides
/// whether a take can be used at all; this names what would make it better.
public enum ReferenceAdvice {
    public enum Fix: Equatable { case cleanUpNoise, reRecord, fixTranscript }
    public struct Finding: Equatable {
        public let message: String
        public let fix: Fix
        public init(message: String, fix: Fix) { self.message = message; self.fix = fix }
    }

    // The messages, in one place: the clone-time check stores findings as
    // their text (VoiceCheckStore), and `Finding(storedMessage:)` reads
    // them back by these.
    public static let shortPrefix = "Your recording is only "
    public static let shortMessage = shortPrefix + "%.0f seconds. A longer one (10–20 s) gives the voice more to learn from."
    public static let clippedMessage = "Your recording is distorted. Re-record a little further from the phone."
    public static let noiseMessage = "Your recording has background noise, and the voice learns it. Clean it up or re-record somewhere quieter."
    public static let transcriptMessage = "The words saved with your recording don't match how long it is — the voice may add or slur words. Check the transcript."

    public static let adviseBelowSNRDb: Float = 30      // accept gate is 20
    public static let healthyCharsPerSecond = 13.0...20.0   // packs 14.7-17.9
    public static let adviseBelowSeconds = 8.0

    public static func findings(quality q: RecordingCheck.Quality, refText: String) -> [Finding] {
        var out: [Finding] = []
        if q.clippedFraction > RecordingCheck.maxClippedFraction || q.seconds < adviseBelowSeconds {
            out.append(Finding(message: q.seconds < adviseBelowSeconds
                ? String(format: shortMessage, q.seconds)
                : clippedMessage,
                fix: .reRecord))
        }
        if q.snrDb < adviseBelowSNRDb {
            out.append(Finding(message: noiseMessage, fix: .cleanUpNoise))
        }
        if q.seconds > 0, q.seconds >= adviseBelowSeconds {
            let cps = Double(refText.count) / q.seconds
            if !healthyCharsPerSecond.contains(cps) {
                out.append(Finding(message: transcriptMessage, fix: .fixTranscript))
            }
        }
        return out
    }
}

extension ReferenceAdvice.Finding {
    /// A finding read back from its stored message; nil for a message this
    /// build does not write (the caller measures again instead).
    public init?(storedMessage m: String) {
        switch m {
        case ReferenceAdvice.clippedMessage: self.init(message: m, fix: .reRecord)
        case ReferenceAdvice.noiseMessage: self.init(message: m, fix: .cleanUpNoise)
        case ReferenceAdvice.transcriptMessage: self.init(message: m, fix: .fixTranscript)
        case _ where m.hasPrefix(ReferenceAdvice.shortPrefix): self.init(message: m, fix: .reRecord)
        default: return nil
        }
    }
}
