import Foundation

/// Splits a long line into pieces a capped autoregressive model can finish.
///
/// Breeze stops at 750 codec frames — 12.5 frames/s, so 60 s of speech — and
/// a Studio line, API request or chat reply arrives as one text. Past the cap
/// the take simply ends mid-sentence with no error. GloamEngine applies this
/// to any backend declaring `BackendID.maxSecondsPerPass`.
///
/// Pieces are whole sentences packed greedily up to `maxSeconds` of
/// ESTIMATED speech, leaving room under the cap for a slow Direction. A
/// sentence still too long is cut at token boundaries — a CJK character, a
/// Latin word, or a whole `(tag)` / `[tag]`, never half of one.
public enum LongTextChunker {
    /// Rough speaking rates: ~15 Latin characters/s, ~4.5 CJK characters/s.
    public static func estimatedSeconds(_ text: String) -> Double {
        var latin = 0, cjk = 0
        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) {
                cjk += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                latin += 1
            }
        }
        return Double(latin) / 15 + Double(cjk) / 4.5
    }

    public static func chunks(_ text: String, maxSeconds: Double) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard estimatedSeconds(trimmed) > maxSeconds else { return [trimmed] }
        var pieces: [String] = []
        var current = ""
        for sentence in sentences(trimmed) {
            if estimatedSeconds(sentence) > maxSeconds {
                append(current, to: &pieces); current = ""
                for piece in pack(tokens(sentence), maxSeconds: maxSeconds) {
                    append(piece, to: &pieces)
                }
            } else if !current.isEmpty && estimatedSeconds(current + sentence) > maxSeconds {
                append(current, to: &pieces); current = sentence
            } else {
                current += sentence
            }
        }
        append(current, to: &pieces)
        return pieces
    }

    // MARK: - Sentences

    /// Always end a sentence: full-width stops and line breaks.
    private static let hardStops: Set<Character> = ["。", "！", "？", "…", "\n"]
    /// End a sentence only when whitespace (or the end) follows, so "55.2",
    /// "v1.2" and "example.com" stay whole.
    private static let softStops: Set<Character> = [".", "!", "?"]
    /// May trail a stop before the break: `."`, `!)`, `。」`.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "」", "』"]

    /// Sentences with their stop, any closers and trailing whitespace kept
    /// attached, so concatenating them reproduces the input exactly.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard hardStops.contains(c) || softStops.contains(c) else { i += 1; continue }
            var end = i + 1
            while end < chars.count,
                  hardStops.contains(chars[end]) || softStops.contains(chars[end])
                    || closers.contains(chars[end]) {
                end += 1
            }
            let run = chars[i..<end]
            let isHard = run.contains { hardStops.contains($0) }
            let followedBySpace = end == chars.count || chars[end].isWhitespace
            guard isHard || followedBySpace else { i = end; continue }
            while end < chars.count, chars[end].isWhitespace { end += 1 }
            result.append(String(chars[start..<end]))
            start = end
            i = end
        }
        if start < chars.count { result.append(String(chars[start...])) }
        return result
    }

    // MARK: - Over-long sentences

    /// Indivisible units, each carrying its trailing whitespace: a whole
    /// `(tag)`/`[tag]`, a single CJK character, or a run of other characters.
    static func tokens(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            var end = i + 1
            if let close = tagClose(chars[i]), let found = chars[(i + 1)...].prefix(24).firstIndex(of: close) {
                end = found + 1                             // a whole tag
            } else if isCJK(chars[i]) {
                end = i + 1                                 // one CJK character
            } else if !chars[i].isWhitespace {
                while end < chars.count, !chars[end].isWhitespace, !isCJK(chars[end]),
                      tagClose(chars[end]) == nil {
                    end += 1                                // a Latin word
                }
            }
            while end < chars.count, chars[end].isWhitespace { end += 1 }
            result.append(String(chars[i..<end]))
            i = end
        }
        return result
    }

    private static func pack(_ tokens: [String], maxSeconds: Double) -> [String] {
        var out: [String] = []
        var current = ""
        for token in tokens {
            if !current.isEmpty && estimatedSeconds(current + token) > maxSeconds {
                out.append(current); current = ""
            }
            current += token
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func append(_ piece: String, to pieces: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
    }

    private static func tagClose(_ c: Character) -> Character? {
        switch c {
        case "(": ")"
        case "[": "]"
        default: nil
        }
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { isCJKScalar($0) } ?? false
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }
}
