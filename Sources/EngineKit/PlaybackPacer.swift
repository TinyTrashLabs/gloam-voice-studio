import Foundation

/// When a streamed render may start (or resume) playing.
///
/// A render that arrives slower than it plays drains the player's queue, and playing every late chunk the
/// moment it lands turns a 10 % shortfall into a stutter of small gaps. `adaptive` measures the render rate
/// from the chunks so far and holds playback until the queued audio covers the shortfall projected over the
/// rest of the read, so it plays through; a render well ahead of real time never waits. After a drain it
/// holds again, with a minimum lead that doubles each time (1 s, 2 s, 4 s …, capped), so a wrong projection
/// costs one or two re-buffers, never a pause per chunk.
///
/// Pure and model-free (Foundation only): it is fed chunk arrivals with wall times and asked a yes/no, so the
/// rule is testable without an audio session. Wall times are seconds on any monotonic clock; the first chunk
/// carries the model load and prefill, so the rate is taken between arrivals, never from zero. Arrivals that
/// span several renders (a chat reply's sentences, each with its own prefill) go to ONE pacer, so the gaps
/// between renders count against the measured rate.
///
/// Ported from gloam-voice-studio-ios `App/StreamPacer.swift` (perf/compose-overhead); `Tuning.phone` is
/// that app's rule exactly, so the iPhone can adopt this type in its place.
public struct PlaybackPacer: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case immediate, adaptive }

    public struct Tuning: Equatable, Sendable {
        /// Over-estimate the shortfall a little: a render that dipped tends to stay down.
        public var margin: Double
        /// Arrivals the recent rate is measured over, so a slowdown is seen quickly.
        public var rateWindow: Int
        /// A render measured below this (audio seconds per wall second) is marginal: it keeps
        /// `floorFraction` of the remaining read queued before starting, capped at `floorCap`.
        public var marginalRate: Double
        public var floorFraction: Double
        public var floorCap: Double
        /// After a drain, never wait longer than this before resuming.
        public var drainCap: Double
        /// What a marginal render sustains later (a phone that throttles once warm); nil plans on the
        /// measured rate.
        public var warmRate: Double?
        /// Planned rate when the device is already `.serious`/`.critical` at the start; nil ignores heat.
        public var hotRate: Double?
        /// Add one chunk to the lead when the render is not ahead of real time. Audio arrives in chunks,
        /// not continuously: just before the LAST chunk lands the queue is a whole chunk lower than the
        /// continuous projection says, so a short read (a chat sentence, where the margin is small) planned
        /// without it drains right before its end.
        public var chunkQuantum: Bool

        public init(margin: Double, rateWindow: Int, marginalRate: Double, floorFraction: Double,
                    floorCap: Double, drainCap: Double, warmRate: Double?, hotRate: Double?,
                    chunkQuantum: Bool = false) {
            self.margin = margin; self.rateWindow = rateWindow; self.marginalRate = marginalRate
            self.floorFraction = floorFraction; self.floorCap = floorCap; self.drainCap = drainCap
            self.warmRate = warmRate; self.hotRate = hotRate; self.chunkQuantum = chunkQuantum
        }

        /// The iPhone app's rule (2026-10-04): the 15 Pro renders Qwen at 1.2–1.3x cool and settles to
        /// ~0.7x warm, ~0.6x when the read starts hot.
        public static let phone = Tuning(margin: 1.15, rateWindow: 4, marginalRate: 1.25, floorFraction: 0.2,
                                         floorCap: 10, drainCap: 10, warmRate: 0.7, hotRate: 0.6)
        /// A Mac rendering qwen3-0.6b-ane on the Neural Engine: 0.85–1.10x measured per sentence
        /// (2026-10-05), with no thermal slide over a chat reply. Plan on the measured rate; keep a short
        /// floor near real time, where one slow sentence would otherwise drain the queue.
        public static let mac = Tuning(margin: 1.15, rateWindow: 4, marginalRate: 1.2, floorFraction: 0.1,
                                       floorCap: 2, drainCap: 6, warmRate: nil, hotRate: nil,
                                       chunkQuantum: true)
    }

    /// Speech rate of the measured Qwen reads, characters per second (iPhone 2026-09-09: 17–20 on long
    /// reads; Mac chat sentences 2026-10-05: 16–21). Prefer the read's own measured rate once known.
    public static let charactersPerSecond = 17.0

    public let mode: Mode
    public let tuning: Tuning
    /// Audio seconds the whole read is expected to produce. Mutable: a chat reply's text grows while the
    /// language model is still writing it.
    public var expectedSeconds: Double
    /// `ProcessInfo.thermalState` when the stream started -- passed in, so the rule stays pure.
    public let thermalState: ProcessInfo.ThermalState

    public var startedHot: Bool { thermalState == .serious || thermalState == .critical }

    private var cumulative: [Arrival] = []
    /// Raised on every drain: 1 s, 2 s, 4 s … so pauses get rarer, not more frequent.
    public private(set) var minimumLead: Double = 0
    public private(set) var drains = 0

    private struct Arrival: Equatable, Sendable { var audio: Double; var at: Double }

    /// Arrivals closer together than this are one arrival (a lead-in gap handed over with its chunk).
    static let sameArrival = 0.005

    public init(mode: Mode = .adaptive, tuning: Tuning, expectedSeconds: Double,
                thermalState: ProcessInfo.ThermalState = .nominal) {
        self.mode = mode
        self.tuning = tuning
        self.expectedSeconds = expectedSeconds
        self.thermalState = thermalState
    }

    public static func estimateSeconds(characters: Int, charactersPerSecond: Double = charactersPerSecond) -> Double {
        Double(characters) / max(1, charactersPerSecond)
    }

    /// Total audio seconds received so far.
    public var receivedSeconds: Double { cumulative.last?.audio ?? 0 }

    public mutating func chunkArrived(seconds: Double, at t: Double) {
        let total = receivedSeconds + seconds
        if let last = cumulative.last, t - last.at < Self.sameArrival {
            cumulative[cumulative.count - 1].audio = total
        } else {
            cumulative.append(Arrival(audio: total, at: t))
        }
    }

    /// The queue ran dry mid-render: hold again, with a higher floor.
    public mutating func drained() {
        drains += 1
        minimumLead = max(1, minimumLead * 2)
    }

    /// Audio seconds per wall second; nil until two arrivals. The slower of the recent window and the whole
    /// stream since its first chunk: the window sees a slowdown quickly, the whole-stream rate counts the
    /// gaps a window inside one render misses (the next render's prefill).
    public var renderRate: Double? {
        guard cumulative.count >= 2 else { return nil }
        let window = cumulative.suffix(max(2, tuning.rateWindow))
        guard let first = window.first, let last = window.last, last.at > first.at else { return nil }
        let recent = (last.audio - first.audio) / (last.at - first.at)
        guard let start = cumulative.first, last.at > start.at else { return recent }
        let overall = (last.audio - start.audio) / (last.at - start.at)
        return min(recent, overall)
    }

    /// Mean audio per arrival over the rate window (the render's chunk size).
    private var typicalChunk: Double {
        let window = cumulative.suffix(max(2, tuning.rateWindow))
        guard let first = window.first, let last = window.last, window.count >= 2 else { return 0 }
        return (last.audio - first.audio) / Double(window.count - 1)
    }

    /// Seconds that must be queued ahead of the playhead before playing. Nil while the rate is unknown
    /// (adaptive holds).
    public var requiredLead: Double? {
        switch mode {
        case .immediate:
            return minimumLead
        case .adaptive:
            guard let rate = renderRate else { return nil }
            let remaining = max(0, expectedSeconds - receivedSeconds)
            let marginal = rate < tuning.marginalRate
            let floor = marginal ? min(tuning.floorCap, remaining * tuning.floorFraction) : 0
            var sustained = rate
            if marginal, let warm = tuning.warmRate { sustained = min(sustained, warm) }
            if startedHot, let hot = tuning.hotRate { sustained = min(sustained, hot) }
            // Playback eats 1 s/s, the render supplies `sustained` s/s: the gap over the remaining render
            // must already be in the queue.
            var shortfall = sustained < 1 ? remaining * (1 / max(sustained, 0.05) - 1) * tuning.margin : 0
            if tuning.chunkQuantum, sustained <= 1, remaining > 0 { shortfall += min(remaining, typicalChunk) }
            let lead = max(minimumLead, floor, shortfall)
            return minimumLead > 0 ? min(lead, tuning.drainCap) : lead
        }
    }

    public func mayPlay(queued: Double, renderFinished: Bool) -> Bool {
        if renderFinished { return true }
        guard let lead = requiredLead else { return false }
        return queued >= lead
    }
}
