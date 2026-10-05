import Foundation

/// The rules one read (a talk break, a long line) follows on every Qwen backend: the Neural Engine
/// (`QwenTalkSession`) and the iPhone's MLX path (gloam-voice-studio-ios `QwenMLXEngine`). Pure and
/// model-free, so a host on either backend applies the same split, the same derail test and the same
/// carry decision.
public enum QwenReadRules {
    /// Extra takes drawn for a part whose take derailed. Not when streaming: its chunks are already out.
    public static let maxRedraws = 2
    /// A silent run longer than this between two stretches of speech makes a take derailed.
    public static let maxPauseSeconds = 2.0
    /// The part size a break is split into: ~10 s of speech, the size the radio and the iPhone render.
    public static let defaultMaxPartChars = 160

    /// A take that derailed: it ran to the frame cap without ending, or it holds a silent run of more than
    /// `maxPauseSeconds` between two stretches of speech. Measured on Bad Bunny and Benson Spanish parts
    /// (360 renders, Whisper large-v3 turbo as the judge): it catches 34 of the 53 unintelligible takes and
    /// fires on 3 of the 307 intelligible ones (1 %), whose redraw only costs time.
    public static func derailed(hitFrameCap: Bool, longestPause: Double) -> Bool {
        hitFrameCap || longestPause > maxPauseSeconds
    }

    /// Orders takes when none is clean: one that ended beats one that hit the cap, then the shorter dead air.
    public static func badness(hitFrameCap: Bool, longestPause: Double) -> Double {
        (hitFrameCap ? 100 : 0) + longestPause
    }

    /// Whether the next part may continue this take. Only a finished take with frames that did not derail
    /// AND was not flagged by any check that ran before the next part starts: carrying a bad part spreads
    /// it (a bad reference's undetected bad part 1 made part 2 bad 8/30 times carried vs 1/30 not).
    public static func carries(frames: Int, derailed: Bool, flagged: Bool = false) -> Bool {
        frames > 0 && !derailed && !flagged
    }

    /// Frames of a take worth carrying (24 kHz audio, 1920 samples a frame): true trailing silence past
    /// 1.5 s is cut, as the Neural Engine path cuts its renders, so the next part does not continue a
    /// long silence. `floorDb` is what counts as silent (-35 dBFS, or the reference's noise-bed floor).
    public static func keptFrames(samples24k: [Float], frames: Int, floorDb: Float = -35) -> Int {
        let total = min(frames, samples24k.count / samplesPerFrame)
        guard total > 0 else { return 0 }
        return trailingSilenceCut(samples24k, frames: total, floorDb: floorDb)
    }

    /// A fresh seed for a read nobody asked to reproduce (Regenerate must give a new take).
    public static func randomSeed() -> UInt64 { UInt64.random(in: 0...UInt64.max) }

    /// The read split into parts of at most `maxPartChars` characters: whole sentences grouped while they
    /// fit, a longer sentence split at its clauses, then at words. Text that fits is one part, unchanged.
    public static func split(_ text: String, maxPartChars: Int = defaultMaxPartChars) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(20, maxPartChars)
        if trimmed.count <= limit { return [trimmed] }
        var parts: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { parts.append(current); current = "" } }
        func add(_ piece: String) {
            if current.isEmpty { current = piece }
            else if current.count + 1 + piece.count <= limit { current += " " + piece }
            else { flush(); current = piece }
        }
        for sentence in pieces(trimmed, endingAt: sentenceEnds) {
            if sentence.count <= limit { add(sentence); continue }
            for clause in pieces(sentence, endingAt: clauseEnds) {
                if clause.count <= limit { add(clause); continue }
                for word in clause.split(whereSeparator: \.isWhitespace) { add(String(word)) }
            }
        }
        flush()
        return parts
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clauseEnds: Set<Character> = [",", ";", ":", "—", "–", "，", "；"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// `text` cut after each run of `ends` (plus closing quotes/brackets) that is followed by whitespace.
    static func pieces(_ text: String, endingAt ends: Set<Character>) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            cur.append(chars[i])
            if ends.contains(chars[i]) {
                var j = i + 1
                while j < chars.count, ends.contains(chars[j]) || closers.contains(chars[j]) { cur.append(chars[j]); j += 1 }
                i = j
                if i >= chars.count || chars[i].isWhitespace {
                    let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    cur = ""
                }
                continue
            }
            i += 1
        }
        let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return out
    }
}

/// What the next part of a read continues: the last part that `QwenReadRules.carries`, or nothing (the
/// next part starts from the reference). Generic over what a backend keeps (the Neural Engine keeps
/// transcript ids and Int64 codes, MLX an `MLXArray`).
public struct QwenCarry<Context> {
    public private(set) var previous: Context?
    /// Off renders every part from the reference alone (still from the read's one sampler stream).
    public var enabled: Bool

    public init(enabled: Bool = true) { self.enabled = enabled }

    /// What the next part is conditioned on.
    public var context: Context? { enabled ? previous : nil }

    /// A part ended. `take` is what it would hand on, nil when it must not be carried (derailed, flagged,
    /// empty): the next part then starts from the reference. A cancelled part changes nothing.
    public mutating func partEnded(cancelled: Bool, take: Context?) {
        guard !cancelled else { return }
        previous = take
    }
}

/// One part of a rendered break, for logs.
public struct QwenBreakPart: Sendable, Equatable {
    public var index: Int
    public var text: String
    public var frames: Int
    /// Takes drawn (more than 1 when a take derailed and was redrawn).
    public var takes: Int
    public var stopReason: QwenStopReason
    /// Frames of the previous part this one continued (0: the reference alone).
    public var contextFrames: Int
    public var longestPause: Double
    public var derailed: Bool
    public var audioSeconds: Double
    public var renderSeconds: Double

    public var logLine: String {
        String(format: "part %d: %d frames, %.2f s audio in %.2f s, stop %@, takes %d, context %d frames, longest pause %.2f s%@ -- %@",
               index + 1, frames, audioSeconds, renderSeconds, stopReason.rawValue, takes, contextFrames, longestPause,
               derailed ? " (derailed)" : "", String(text.prefix(48)))
    }
}

/// A rendered break: the joined audio (empty when streamed through `onAudio`) and one report per part.
public struct QwenBreak: Sendable {
    public var seed: UInt64
    public var sampleRate: Int
    public var samples: [Float]
    public var parts: [QwenBreakPart]
}

@available(iOS 18.0, macOS 15.0, *)
extension QwenTalkSession {
    /// Splits `text` (`QwenReadRules.split`) and renders it as one break. See `renderBreak(parts:…)`.
    public func renderBreak(_ text: String, maxPartChars: Int = QwenReadRules.defaultMaxPartChars,
                            gapSeconds: Double = 0.15, firstChunkFrames: [Int]? = nil,
                            cancelled: () -> Bool = { false }, pace: () -> Void = {},
                            onAudio: (([Float]) -> Void)? = nil,
                            onPart: ((QwenBreakPart) -> Void)? = nil) throws -> QwenBreak {
        try renderBreak(parts: QwenReadRules.split(text, maxPartChars: maxPartChars), gapSeconds: gapSeconds,
                        firstChunkFrames: firstChunkFrames, cancelled: cancelled, pace: pace,
                        onAudio: onAudio, onPart: onPart)
    }

    /// Renders `parts` in order through this session (one sampler stream, each part continuing the one
    /// before it, a derailed take redrawn unless streaming) with `gapSeconds` of silence between parts.
    /// With `onAudio` the audio (gaps included) goes there as it is made and `QwenBreak.samples` is empty;
    /// `firstChunkFrames` is the first part's vocoder chunk schedule. Stops between parts once `cancelled`.
    public func renderBreak(parts: [String], gapSeconds: Double = 0.15, firstChunkFrames: [Int]? = nil,
                            cancelled: () -> Bool = { false }, pace: () -> Void = {},
                            onAudio: (([Float]) -> Void)? = nil,
                            onPart: ((QwenBreakPart) -> Void)? = nil) throws -> QwenBreak {
        let sr = sampleRate
        let gap = [Float](repeating: 0, count: Int((gapSeconds * Double(sr)).rounded()))
        var out = QwenBreak(seed: seed, sampleRate: sr, samples: [], parts: [])
        for (i, part) in parts.enumerated() {
            if cancelled() { break }
            if i > 0 { if let onAudio { onAudio(gap) } else { out.samples += gap } }
            let t0 = Date()
            let r = try render(part, chunkFrames: i == 0 ? firstChunkFrames : nil, cancelled: cancelled,
                               pace: pace, onAudio: onAudio)
            if onAudio == nil { out.samples += r.samples }
            let report = QwenBreakPart(index: i, text: part, frames: r.frames, takes: r.takes, stopReason: r.stopReason,
                                       contextFrames: r.contextFrames, longestPause: r.silenceBefore.longestPause,
                                       derailed: Self.derailed(r), audioSeconds: r.audioSeconds,
                                       renderSeconds: Date().timeIntervalSince(t0))
            out.parts.append(report)
            onPart?(report)
            if r.stopReason == .cancelled { break }
        }
        return out
    }
}
