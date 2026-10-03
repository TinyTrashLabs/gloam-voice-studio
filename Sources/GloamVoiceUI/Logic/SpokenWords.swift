import Foundation

/// Word tokens for matching what was heard against what was written.
///
/// Recognisers write numbers as digits ("4:30", "platform 9", "21st") while
/// scripts and render text say them in words, so both sides are brought to
/// words before comparing -- otherwise a render that said every word right
/// is flagged "skipped words" (seen at clone time, 2026-09-23: "at four
/// thirty" heard as "at 4:30"). Lower-cased, punctuation dropped except the
/// apostrophe; curly apostrophes are straightened. Pure.
public enum SpokenWords {
    public static func words(_ text: String) -> [String] {
        var s = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        s = replace(#"\b(\d{1,2}):(\d{2})\b"#, in: s) { g in
            guard let h = Int(g[1]), let m = Int(g[2]), m < 60 else { return g[0] }
            let hour = cardinal(h).joined(separator: " ")
            if m == 0 { return hour + " o'clock" }
            if m < 10 { return hour + " oh " + cardinal(m).joined(separator: " ") }
            return hour + " " + cardinal(m).joined(separator: " ")
        }
        s = replace(#"\b(\d{1,3})((?:,\d{3})+)\b"#, in: s) { g in (g[1] + g[2]).replacingOccurrences(of: ",", with: "") }
        s = replace(#"\b(\d+)(st|nd|rd|th)\b"#, in: s) { g in
            guard let n = Int(g[1]), n <= maxNumber else { return g[0] }
            return ordinal(n).joined(separator: " ")
        }
        let tokens = s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        return tokens.flatMap { t -> [String] in
            if t.allSatisfy(\.isASCIIDigit), let n = Int(t), n <= maxNumber { return cardinal(n) }
            return [t]
        }
    }

    public static let maxNumber = 9999

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// 0...9999 in words, as separate tokens ("forty five", no "and").
    public static func cardinal(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : cardinal(n % 100)) }
        return cardinal(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : cardinal(n % 1000))
    }

    public static func ordinal(_ n: Int) -> [String] {
        var w = cardinal(n)
        let last = w.removeLast()
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                         "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        let o = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return w + [o]
    }

    private static func replace(_ pattern: String, in s: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let groups = (0..<m.numberOfRanges).map { i -> String in
                Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
            }
            if let r = Range(m.range, in: out) { out.replaceSubrange(r, with: f(groups)) }
        }
        return out
    }
}

private extension Character {
    public var isASCIIDigit: Bool { isASCII && isNumber }
}
