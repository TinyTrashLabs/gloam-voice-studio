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
    /// `scriptYears` is for the HEARD side of a comparison (`years(in:)` of
    /// the script): a spoken year folds into its digits only if the script has
    /// that year. Without it, "chapters 11, 12" (script: "eleven twelve") was
    /// compared with a heard "eleven twelve" folded to 1112 -- a false
    /// "missing" flag; so were "fifteen twenty" and "twenty twenty". nil folds
    /// every year-shaped run, as the script side always does.
    public static func words(_ text: String, scriptYears: Set<Int>? = nil) -> [String] {
        foldAndExpand(tokens(of: text), allowed: scriptYears, found: nil)
    }

    /// The years a script can be heard as: its 4-digit numbers and the years
    /// its own spoken words fold to.
    public static func years(in script: String) -> Set<Int> {
        var years = Set<Int>()
        let toks = tokens(of: script)
        for t in toks where t.count == 4 && t.allSatisfy(\.isASCIIDigit) { if let n = Int(t) { years.insert(n) } }
        _ = foldYears(toks, allowed: nil) { years.insert($0) }
        return years
    }

    private static func foldAndExpand(_ tokens: [String], allowed: Set<Int>?, found: ((Int) -> Void)?) -> [String] {
        foldYears(tokens, allowed: allowed, found: found).flatMap { t -> [String] in
            if t.allSatisfy(\.isASCIIDigit), let n = Int(t), n <= maxNumber { return cardinal(n) }
            return [t]
        }
    }

    private static func tokens(of text: String) -> [String] {
        var s = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        // "4:30pm", "4pm", "4:30 p.m." -> "... pm"; the glued form has no word
        // boundary for the time pattern below.
        s = replace(#"\b([ap])\.\s?m\b\.?"#, in: s) { g in g[1] + "m" }
        s = replace(#"(\d)(am|pm)\b"#, in: s) { g in g[1] + " " + g[2] }
        s = replace(#"\b(\d{1,2}):(\d{2})\b"#, in: s) { g in
            guard let h = Int(g[1]), let m = Int(g[2]), m < 60 else { return g[0] }
            let hour = cardinal(h).joined(separator: " ")
            if m == 0 { return hour + " o'clock" }
            if m < 10 { return hour + " oh " + cardinal(m).joined(separator: " ") }
            return hour + " " + cardinal(m).joined(separator: " ")
        }
        s = replace(#"\b(\d{1,3})((?:,\d{3})+)\b"#, in: s) { g in (g[1] + g[2]).replacingOccurrences(of: ",", with: "") }
        // "3.5" -> "3 point five"; the fraction is read digit by digit.
        s = replace(#"\b(\d+)\.(\d+)\b"#, in: s) { g in
            g[1] + " point " + g[2].compactMap { $0.wholeNumberValue.map { ones[$0] } }.joined(separator: " ")
        }
        s = replace(#"\b(\d+)(st|nd|rd|th)\b"#, in: s) { g in
            guard let n = Int(g[1]), n <= maxNumber else { return g[0] }
            return ordinal(n).joined(separator: " ")
        }
        return s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    public static let maxNumber = 999_999_999

    /// Years read as words ("nineteen ninety nine", "twenty twenty six",
    /// "nineteen oh five", "nineteen hundred") become the same cardinal words
    /// the digits "1999" etc. do. Conservative: a century of 11-19 or "twenty"
    /// must be followed by "hundred", "oh" + a digit, or a complete two-digit
    /// part (tens + optional ones, or ten-nineteen). Anything partial stays as
    /// spoken, so a really skipped number still shows. Runs on the raw word
    /// tokens, before digits expand.
    private static func foldYears(_ tokens: [String], allowed: Set<Int>?, found: ((Int) -> Void)?) -> [String] {
        func value(_ t: String) -> Int? { ones.firstIndex(of: t) }
        func tensValue(_ t: String) -> Int? { tens.firstIndex(of: t).flatMap { $0 >= 2 ? $0 * 10 : nil } }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            let t = tokens[i]
            let c = t == "twenty" ? 20 : value(t)
            guard let c, (11...20).contains(c) else { out.append(t); continue }
            let century = c * 100
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            var part: Int?, used = 0
            if next == "hundred" {
                part = 0; used = 1
            } else if next == "oh", i + 2 < tokens.count, let d = value(tokens[i + 2]), (1...9).contains(d) {
                part = d; used = 2
            } else if let tn = tensValue(next) {
                if i + 2 < tokens.count, let d = value(tokens[i + 2]), (1...9).contains(d) { part = tn + d; used = 2 }
                else { part = tn; used = 1 }
            } else if let v = value(next), (10...19).contains(v) {
                part = v; used = 1
            }
            guard let p = part else { out.append(t); continue }
            if let allowed, !allowed.contains(century + p) { out.append(t); continue }
            found?(century + p)
            out += cardinal(century + p)
            i += used
        }
        return out
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// 0...999,999,999 in words, as separate tokens ("forty five", no "and").
    public static func cardinal(_ n: Int) -> [String] {
        if n >= 1_000_000 { return cardinal(n / 1_000_000) + ["million"] + (n % 1_000_000 == 0 ? [] : cardinal(n % 1_000_000)) }
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
