import Foundation

/// Splits prose into sentence-sized chunks for per-sentence TTS synthesis
/// (play sentence 1 while sentence 2 renders). Chunking only affects audio
/// pacing — the chat transcript always shows the original text — so this
/// favors simple, predictable rules over linguistic perfection.
public enum SentenceSplitter {
    /// Words whose trailing period is not a sentence boundary.
    /// (List broadened from Voicebox's splitter, MIT.)
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "vs", "etc", "eg", "ie", "approx", "dept", "est",
        "ave", "blvd", "inc", "ltd", "corp",
    ]

    /// Dotted abbreviations matched with their INTERNAL dots intact ("p.m",
    /// "e.g"). Kept separate from the plain set: stripping dots first would
    /// turn "p.m" into "pm"/"am" and block genuine sentence ends like "I am."
    private static let dottedAbbreviations: Set<String> = [
        "e.g", "i.e", "a.m", "p.m", "u.s",
    ]

    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if isTerminator(chars[i]) {
                // Absorb the whole punctuation run ("?!", "...").
                while i + 1 < chars.count, isTerminator(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let atBoundary = i + 1 >= chars.count || chars[i + 1].isWhitespace
                if atBoundary, !endsWithAbbreviation(current) {
                    appendTrimmed(current, to: &sentences)
                    current = ""
                }
            }
            i += 1
        }
        appendTrimmed(current, to: &sentences)
        return sentences
    }

    private static func isTerminator(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?"
    }

    private static func appendTrimmed(_ chunk: String, to sentences: inout [String]) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }

    /// True when the chunk ends in "<word>." where word is a known abbreviation
    /// or a single letter (an initial) — i.e. the period isn't a boundary.
    private static func endsWithAbbreviation(_ chunk: String) -> Bool {
        var s = Substring(chunk.trimmingCharacters(in: .whitespaces))
        guard s.hasSuffix(".") else { return false }   // "!"/"?" runs always split
        while let last = s.last, isTerminator(last) { s = s.dropLast() }
        let lastWord: Substring
        if let space = s.lastIndex(where: { $0.isWhitespace }) {
            lastWord = s[s.index(after: space)...]
        } else {
            lastWord = s
        }
        let dotted = lastWord.lowercased()
        let word = dotted.replacingOccurrences(of: ".", with: "")
        return abbreviations.contains(word) || dottedAbbreviations.contains(dotted)
            || word.count == 1
    }

    /// Streaming variant: splits a still-growing buffer into sentences that
    /// are definitely complete plus the trailing remainder, returned verbatim
    /// so callers can append the next delta to it. Unlike `split`, the end of
    /// the buffer is NOT a boundary — "It costs 3." might become "It costs
    /// 3.5" on the next delta — so a sentence only completes once whitespace
    /// follows its terminator run.
    public static func splitStreaming(_ text: String) -> (complete: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var lastBoundary = 0
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if isTerminator(chars[i]) {
                while i + 1 < chars.count, isTerminator(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let atBoundary = i + 1 < chars.count && chars[i + 1].isWhitespace
                if atBoundary, !endsWithAbbreviation(current) {
                    appendTrimmed(current, to: &sentences)
                    current = ""
                    lastBoundary = i + 1
                }
            }
            i += 1
        }
        return (sentences, String(chars[lastBoundary...]))
    }
}
