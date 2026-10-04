import AVFoundation
import Foundation

/// One thing wrong with a rendered part, in words a person can act on.
public enum RenderProblem: Equatable, Codable, Hashable {
    case silent
    case hiss
    case clipped
    case tooFast(charsPerSecond: Double)
    case tooSlow(charsPerSecond: Double)
    case wordsMissing(match: Double)
    case extraSpeech(coverage: Double)

    public var words: String {
        switch self {
        case .silent: return "came out silent"
        case .hiss: return "came out as noise instead of speech"
        case .clipped: return "is distorted"
        case .tooFast: return "ran short — words may be cut off"
        case .tooSlow: return "ran long — it may say things you didn't write"
        case .wordsMissing: return "skipped words"
        case .extraSpeech: return "said words you didn't write"
        }
    }

    /// Worse is higher. Used to keep the better of two failed attempts.
    public var severity: Int {
        switch self {
        case .silent, .hiss: return 100
        case .extraSpeech, .wordsMissing: return 40
        case .tooSlow, .tooFast: return 30
        case .clipped: return 10
        }
    }
}

/// Is a rendered part fit to play? Signal statistics always; a transcript
/// check when one is available (English script, bundled ASR present).
///
/// Thresholds are the repo's measurements, re-derived from the Task 4
/// corpus -- change the constants, not the shape:
/// - hiss/silence: Qwen's non-speech mode sits at -49...-65 dBFS
///   (LeadingSilenceGate); a quiet voice at -30...-40.
/// - rate: relative to the voice. Both engines copy the pace of the
///   reference they clone from (LuxTTS sizes frames per token from it; Qwen
///   continues it), so a render is judged against its reference's own
///   chars/s, not a fixed band. Jeff's reference reads 17.5 and his renders
///   17-20; Morgan's window reads 11.4 and his clean renders 9.6-17.4, which
///   a fixed 10.5 floor flagged (2026-09-24).
/// - words: RecordingCheck's LCS match; renders are cleaner than takes, so
///   the bar is lower than the take's 0.9 only to absorb ASR error.
public enum RenderCheck {
    public static let speechFloorDb: Float = -45   // = LeadingSilenceGate.defaultFloorDb (pinned by the app's tests)
    public static let minVoicedFraction = 0.35
    public static let maxClippedFraction = 0.001
    /// The band around the expected rate. For a 15 chars/s reference (no
    /// reference known) this is the old fixed 10.5...24.
    public static let minRateFactor = 0.7
    public static let maxRateFactor = 1.6
    /// When there is no reference to measure.
    public static let defaultReferenceRate = 15.0
    /// A reference measured outside this is itself suspect (a transcript that
    /// misses half the clip, a clip that is mostly silence), so it cannot
    /// widen the band past what a real voice needs.
    public static let referenceRateRange = 10.0...22.0
    public static let minWordMatch = 0.8
    public static let minCoverage = 0.7
    /// Under this many words, rate and match are noise: "Yes." can take 0.3 s or 1 s.
    public static let minWordsForTextChecks = 4

    public struct Signal: Equatable {
        public let seconds: Double
        public let speechDb: Float
        public let voicedFraction: Double   // 50 ms blocks above speechFloorDb
        public let clippedFraction: Double
    }

    public static func signal(_ samples: [Float], sampleRate: Int) -> Signal {
        let q = RecordingCheck.measure(samples, sampleRate: sampleRate)
        let block = max(1, sampleRate / 20)
        let floor = pow(10, speechFloorDb / 20)
        var voiced = 0, blocks = 0, i = 0
        while i + block <= samples.count {
            var acc: Float = 0
            for s in samples[i..<(i + block)] { acc += s * s }
            if (acc / Float(block)).squareRoot() > floor { voiced += 1 }
            blocks += 1
            i += block
        }
        return Signal(seconds: q.seconds, speechDb: q.speechDb,
                      voicedFraction: blocks == 0 ? 0 : Double(voiced) / Double(blocks),
                      clippedFraction: q.clippedFraction)
    }

    /// The chars/s a render should read at: the reference's own rate (its
    /// transcript over its length -- the curated window when the voice has
    /// one, since that is what the engine clones from) times the pace the
    /// engine honoured (1 for one that ignores it, e.g. Qwen): 0.7x reads
    /// slower on purpose.
    public static func expectedRate(referenceChars: Int?, referenceSeconds: Double?, pace: Float) -> Double {
        var rate = defaultReferenceRate
        if let chars = referenceChars, let seconds = referenceSeconds, chars > 0, seconds > 0 {
            rate = min(max(Double(chars) / seconds, referenceRateRange.lowerBound), referenceRateRange.upperBound)
        }
        return rate * Double(pace > 0 ? pace : 1)
    }

    /// Header read only; no samples are decoded.
    public static func seconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// `expectedRate` is from `expectedRate(...)`; the default is a 15 chars/s
    /// voice at pace 1.
    public static func problems(text: String, signal: Signal, heard: String?,
                         expectedRate: Double = defaultReferenceRate) -> [RenderProblem] {
        if signal.speechDb < -80 { return [.silent] }
        if signal.speechDb < speechFloorDb || signal.voicedFraction < minVoicedFraction { return [.hiss] }
        var out: [RenderProblem] = []
        if signal.clippedFraction > maxClippedFraction { out.append(.clipped) }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= minWordsForTextChecks, signal.seconds > 0 else { return out }
        let cps = Double(text.count) / signal.seconds
        if cps < expectedRate * minRateFactor { out.append(.tooSlow(charsPerSecond: cps)) }
        if cps > expectedRate * maxRateFactor { out.append(.tooFast(charsPerSecond: cps)) }
        if let heard {
            let match = RecordingCheck.scriptMatch(heard: heard, script: text)
            let coverage = RecordingCheck.transcriptCoverage(heard: heard, script: text)
            if match < minWordMatch { out.append(.wordsMissing(match: match)) }
            if coverage < minCoverage { out.append(.extraSpeech(coverage: coverage)) }
        }
        return out
    }

    public static func severity(_ problems: [RenderProblem]) -> Int {
        problems.reduce(0) { $0 + $1.severity }
    }
}
