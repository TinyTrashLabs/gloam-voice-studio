// LuxTokenizer.swift
// EngineKit — LuxTTS text frontend (tokenizer / phonemizer)
//
// Swift port of the LuxTTS (ZipVoice) `EmiliaTokenizer` English pipeline:
//   text
//     -> map_punctuations           (unicode punctuation -> ascii, "..." -> "…")
//     -> language segmentation      (en / zh / pinyin / [tag] runs)
//     -> EnglishTextNormalizer      (abbreviations + number expansion, inflect-style)
//     -> espeak-ng G2P (en-us)      (piper_phonemize.phonemize_espeak semantics)
//     -> vocab lookup               (tokens.txt, 360 entries, OOV silently dropped)
//
// Reference: LuxTTS/zipvoice/tokenizer/tokenizer.py (class EmiliaTokenizer) and
//            LuxTTS/zipvoice/tokenizer/normalizer.py (class EnglishTextNormalizer).
//
// Vocabulary (tokens.txt, bundled as a resource): literal phoneme symbols, one
// Unicode scalar per token — espeak IPA characters incl. stress marks (ˈ ˌ),
// length marks (ː ˑ) and combining diacritics — plus space, ascii punctuation,
// digits, Mandarin pinyin initial/final+tone tokens, and specials:
//   "_" = 0 (pad), "^" = 1, "$" = 2 (BOS/EOS-style markers; EmiliaTokenizer does
//   NOT insert them at inference — no BOS/EOS is appended, no padding is added
//   by the tokenizer itself; padID is exposed for the model's collation code).
//
// ── What is complete vs stubbed ────────────────────────────────────────────────
// COMPLETE (validated against the Python reference implementation):
//   * tokens.txt parsing and exact EmiliaTokenizer ID mapping (OOV dropped,
//     no BOS/EOS, padID = "_" = 0).
//   * EnglishTextNormalizer port (abbreviations, currency, fractions, decimals,
//     percents, ordinals, inflect-style number wording incl. the year rules).
//   * piper_phonemize clause assembly semantics (terminator punctuation tokens,
//     "," ";" ":" followed by a space token, "." "?" "!" ending a sentence with
//     no trailing space, "…" swallowed, NFD decomposition, one token per
//     Unicode scalar, "(en)" language-switch flags stripped).
//   * `EspeakProcessPhonemizer`: out-of-process phonemization via an espeak-ng
//     executable (Homebrew /opt/homebrew/bin/espeak-ng by default, or a binary
//     bundled with the app + ESPEAK_DATA_PATH). Verified 11/12 fixture strings
//     produce token-for-token identical output to piper_phonemize; the one
//     mismatch is voice-data drift between Homebrew espeak-ng 1.52.0 and the
//     rhasspy espeak-ng fork bundled inside piper_phonemize (e.g. "four" =
//     fˈoːɹ in the fork vs fˈɔːɹ in 1.52.0). Both spellings are in-vocab.
// STUBBED / NOT PORTED:
//   * Chinese (zh) and <pinyin> segments: the Python path needs jieba +
//     pypinyin + cn2an. Unsupported here — those segments yield no tokens and
//     are logged, mirroring the Python behavior when tokenize_ZH throws.
//   * Chinese remains the only stub. The espeak licensing/sandbox problem is
//     RESOLVED: the shipping default is `MisakiPhonemizer` (see
//     MisakiPhonemizer.swift) — an in-process, MIT-licensed G2P reusing
//     MLXAudioTTS's misaki port, with its output remapped to the espeak IPA
//     conventions this vocab expects. `EspeakProcessPhonemizer` below is kept
//     for dev-machine parity testing only (`spike lux-phonemes`); it cannot
//     run inside the sandboxed .app and must not ship as the default.
// ──────────────────────────────────────────────────────────────────────────────

import Foundation
import os

// MARK: - Errors

public enum LuxTokenizerError: Error, Sendable {
    case tokensFileNotFound(String)
    case malformedTokensFile(line: String)
    case phonemizerUnavailable(String)
    case phonemizationFailed(String)
}

// MARK: - Phonemizer boundary

/// Boundary for the G2P engine. Implementations must return the *flat* phoneme
/// token stream matching `piper_phonemize.phonemize_espeak(text, "en-us")`
/// flattened across sentences: one element per Unicode scalar (NFD), including
/// stress/length marks, space tokens between words, and terminator punctuation
/// tokens (see `PiperClauseAssembler` for the exact rules).
public protocol PhonemizerProviding: Sendable {
    func phonemize(_ normalizedEnglishText: String) throws -> [String]
}

// MARK: - Clause assembly (piper_phonemize semantics)

/// Reimplements the clause/terminator behavior of piper-phonemize's
/// `phonemize_eSpeak` on top of any "clause text -> IPA string" function:
///   * input is split into clauses on . ? ! , ; : … runs
///   * each clause is phonemized independently (words separated by spaces)
///   * "," ";" ":" append their own token followed by a space token
///   * "." "?" "!" append their own token and end the sentence (no space after)
///   * "…" ends a clause but emits no token (matches observed piper behavior)
///   * output is NFD-decomposed and split into single Unicode scalars
///   * espeak "(en)"-style language-switch flags are stripped
enum PiperClauseAssembler {
    static let terminators: Set<Character> = [".", "?", "!", ",", ";", ":", "…"]

    private static let languageSwitchFlag = try! NSRegularExpression(
        pattern: "\\([a-z]{2,3}(?:-[a-z]+)?\\)")

    static func assemble(
        _ text: String,
        clauseIPA: (String) throws -> String
    ) throws -> [String] {
        var tokens: [String] = []

        // Split into alternating clause-text / terminator-run pieces.
        var pieces: [(text: String, isTerminator: Bool)] = []
        var current = ""
        var currentIsTerminator = false
        for ch in text {
            let isTerm = terminators.contains(ch)
            if !current.isEmpty && isTerm != currentIsTerminator {
                pieces.append((current, currentIsTerminator))
                current = ""
            }
            current.append(ch)
            currentIsTerminator = isTerm
        }
        if !current.isEmpty { pieces.append((current, currentIsTerminator)) }

        var index = 0
        while index < pieces.count {
            let piece = pieces[index]
            if piece.isTerminator {
                // Terminator run with no preceding clause in this iteration
                // (e.g. leading punctuation): skipped, same as espeak.
                index += 1
                continue
            }
            var terminator: Character? = nil
            if index + 1 < pieces.count, pieces[index + 1].isTerminator {
                // First punctuation char of the run decides the terminator,
                // mirroring espeak's single CLAUSE_* code per clause.
                terminator = pieces[index + 1].text.first
                index += 2
            } else {
                index += 1
            }

            let clause = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clause.isEmpty {
                var ipa = try clauseIPA(clause)
                let range = NSRange(ipa.startIndex..., in: ipa)
                ipa = languageSwitchFlag.stringByReplacingMatches(
                    in: ipa, range: range, withTemplate: "")
                let decomposed = ipa.decomposedStringWithCanonicalMapping  // NFD
                tokens.append(contentsOf: decomposed.unicodeScalars.map(String.init))
            }

            switch terminator {
            case ".", "?", "!":
                tokens.append(String(terminator!))  // sentence end: no trailing space
            case ",", ";", ":":
                tokens.append(String(terminator!))
                tokens.append(" ")
            default:
                break  // "…" or none: no token
            }
        }
        return tokens
    }
}

// MARK: - Out-of-process espeak-ng phonemizer

// macOS only. `Process` does not exist on iOS (you cannot spawn a child process
// from a sandboxed iOS app), so building this for iOS fails with
// "cannot find 'Process' in scope" — which broke the aidj iOS app, since its
// App target has a local SwiftPM dependency on EngineKit and this package
// declares .iOS(.v17) support. Guarding rather than deleting: the only caller is
// the macOS-only `spike` dev CLI, and LuxTTS's real phonemizer on both platforms
// is `MisakiPhonemizer` (espeak-ng is GPL-3.0 and undistributable via the App
// Store anyway — see MisakiPhonemizer.swift's header).
#if os(macOS)

/// Runs an `espeak-ng` executable per clause (`espeak-ng -q --ipa -v en-us`).
/// Default lookup order: an explicit URL passed in, then Homebrew paths.
/// For a bundled binary, pass `dataDirectory` pointing at espeak-ng-data and
/// it is exported as ESPEAK_DATA_PATH.
///
/// This is the dev-machine / direct-distribution implementation. See the file
/// header for the vendored-library plan (`EspeakLibraryPhonemizer`).
public struct EspeakProcessPhonemizer: PhonemizerProviding {
    public let executableURL: URL
    public let voice: String
    public let dataDirectory: URL?

    public static let defaultSearchPaths = [
        "/opt/homebrew/bin/espeak-ng",
        "/opt/homebrew/bin/espeak",
        "/usr/local/bin/espeak-ng",
        "/usr/local/bin/espeak",
    ]

    public init(executableURL: URL, voice: String = "en-us", dataDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.voice = voice
        self.dataDirectory = dataDirectory
    }

    /// Finds espeak-ng on well-known paths; throws if none exists.
    public init(voice: String = "en-us") throws {
        guard let path = Self.defaultSearchPaths.first(
            where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw LuxTokenizerError.phonemizerUnavailable(
                "espeak-ng executable not found (looked in \(Self.defaultSearchPaths)). "
                + "Install with `brew install espeak-ng` or bundle a binary and use "
                + "init(executableURL:voice:dataDirectory:).")
        }
        self.init(executableURL: URL(fileURLWithPath: path), voice: voice)
    }

    public func phonemize(_ normalizedEnglishText: String) throws -> [String] {
        try PiperClauseAssembler.assemble(normalizedEnglishText) { clause in
            try runEspeak(clause)
        }
    }

    private func runEspeak(_ clause: String) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-q", "--ipa", "-v", voice, "--", clause]
        if let dataDirectory {
            var env = ProcessInfo.processInfo.environment
            env["ESPEAK_DATA_PATH"] = dataDirectory.path
            process.environment = env
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw LuxTokenizerError.phonemizerUnavailable(
                "failed to launch \(executableURL.path): \(error)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else {
            throw LuxTokenizerError.phonemizationFailed(
                "espeak-ng exited with status \(process.terminationStatus) for clause: \(clause)")
        }
        // espeak prints one line per internal clause; join with a single space
        // (piper inserts a space token between clause chunks inside a sentence).
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

#endif  // os(macOS) — EspeakProcessPhonemizer

// MARK: - English text normalizer (port of EnglishTextNormalizer)

/// Port of `zipvoice.tokenizer.normalizer.EnglishTextNormalizer`, including its
/// inflect-style number wording (`andword`, group-of-2 "year" mode, scale-group
/// commas, hyphenated tens compounds).
public struct LuxEnglishTextNormalizer: Sendable {
    public init() {}

    // (regex, replacement) — matched case-insensitively on word boundaries.
    private static let abbreviations: [(NSRegularExpression, String)] = [
        ("mrs", "misess"), ("mr", "mister"), ("dr", "doctor"), ("st", "saint"),
        ("co", "company"), ("jr", "junior"), ("maj", "major"), ("gen", "general"),
        ("drs", "doctors"), ("rev", "reverend"), ("lt", "lieutenant"),
        ("hon", "honorable"), ("sgt", "sergeant"), ("capt", "captain"),
        ("esq", "esquire"), ("ltd", "limited"), ("col", "colonel"), ("ft", "fort"),
        ("etc", "et cetera"), ("btw", "by the way"),
    ].map { (abbrev, replacement) in
        (try! NSRegularExpression(pattern: "\\b\(abbrev)\\b",
                                  options: [.caseInsensitive]),
         replacement)
    }

    private static let commaNumberRe = try! NSRegularExpression(pattern: "[0-9][0-9,]+[0-9]")
    private static let poundsRe = try! NSRegularExpression(pattern: "£([0-9,]*[0-9]+)")
    private static let dollarsRe = try! NSRegularExpression(pattern: "\\$([0-9.,]*[0-9]+)")
    private static let fractionRe = try! NSRegularExpression(pattern: "([0-9]+)/([0-9]+)")
    private static let decimalRe = try! NSRegularExpression(pattern: "[0-9]+\\.[0-9]+")
    private static let percentRe = try! NSRegularExpression(pattern: "[0-9.,]*[0-9]+%")
    private static let ordinalRe = try! NSRegularExpression(pattern: "[0-9]+(st|nd|rd|th)")
    private static let numberRe = try! NSRegularExpression(pattern: "[0-9]+")

    public func normalize(_ text: String) -> String {
        var t = expandAbbreviations(text)
        t = normalizeNumbers(t)
        return t
    }

    public func expandAbbreviations(_ text: String) -> String {
        var t = text
        for (regex, replacement) in Self.abbreviations {
            t = regex.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: replacement)
        }
        return t
    }

    public func normalizeNumbers(_ text: String) -> String {
        // Order matches the Python reference exactly.
        var t = replacing(Self.commaNumberRe, in: text) { m, _ in
            m.replacingOccurrences(of: ",", with: "")
        }
        t = replacing(Self.poundsRe, in: t) { _, groups in "\(groups[0]) pounds" }
        t = replacing(Self.dollarsRe, in: t) { _, groups in expandDollars(groups[0]) }
        t = replacing(Self.fractionRe, in: t) { _, groups in
            expandFraction(numerator: Int(groups[0]) ?? 0, denominator: Int(groups[1]) ?? 0)
        }
        t = replacing(Self.decimalRe, in: t) { m, _ in
            m.replacingOccurrences(of: ".", with: " point ")
        }
        t = replacing(Self.percentRe, in: t) { m, _ in
            m.replacingOccurrences(of: "%", with: " percent ")
        }
        t = replacing(Self.ordinalRe, in: t) { m, _ in " \(ordinalWords(from: m)) " }
        t = replacing(Self.numberRe, in: t) { m, _ in expandNumber(Int(m) ?? 0) }
        return t
    }

    // MARK: expansion helpers (ports of the _expand_* methods)

    private func expandDollars(_ match: String) -> String {
        let parts = match.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        if parts.count > 2 { return " \(match) dollars " }  // unexpected format
        let dollars = parts.count >= 1 ? (Int(parts[0]) ?? 0) : 0
        let cents = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        if dollars != 0 && cents != 0 {
            let dollarUnit = dollars == 1 ? "dollar" : "dollars"
            let centUnit = cents == 1 ? "cent" : "cents"
            return " \(dollars) \(dollarUnit), \(cents) \(centUnit) "
        } else if dollars != 0 {
            return " \(dollars) \(dollars == 1 ? "dollar" : "dollars") "
        } else if cents != 0 {
            return " \(cents) \(cents == 1 ? "cent" : "cents") "
        }
        return " zero dollars "
    }

    private func expandFraction(numerator: Int, denominator: Int) -> String {
        if numerator == 1 && denominator == 2 { return " one half " }
        if numerator == 1 && denominator == 4 { return " one quarter " }
        if denominator == 2 { return " \(numberToWords(numerator)) halves " }
        if denominator == 4 { return " \(numberToWords(numerator)) quarters " }
        return " \(numberToWords(numerator)) \(ordinalize(numberToWords(denominator))) "
    }

    /// `_expand_ordinal`: inflect's number_to_words("21st") -> "twenty-first".
    private func ordinalWords(from match: String) -> String {
        let digits = String(match.prefix(while: { $0.isNumber }))
        return ordinalize(numberToWords(Int(digits) ?? 0))
    }

    /// `_expand_number`, including the special-cased 1000..<3000 "year" rules.
    private func expandNumber(_ num: Int) -> String {
        if num > 1000 && num < 3000 {
            if num == 2000 { return " two thousand " }
            if num > 2000 && num < 2010 {
                return " two thousand \(numberToWords(num % 100, andWord: "")) "
            }
            if num % 100 == 0 {
                return " \(numberToWords(num / 100, andWord: "")) hundred "
            }
            return " \(numberToWordsGroup2(num)) "
        }
        return " \(numberToWords(num, andWord: "")) "
    }

    // MARK: inflect-style number wording

    private static let units = ["zero", "one", "two", "three", "four", "five", "six",
                                "seven", "eight", "nine", "ten", "eleven", "twelve",
                                "thirteen", "fourteen", "fifteen", "sixteen",
                                "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty",
                               "sixty", "seventy", "eighty", "ninety"]
    private static let scales = ["", " thousand", " million", " billion", " trillion",
                                 " quadrillion", " quintillion"]

    /// inflect.number_to_words(n, andword:). Default andword is "and"
    /// ("one hundred and one"); the reference passes "" for plain numbers.
    /// Scale groups are joined with ", " like inflect
    /// ("twelve thousand, three hundred forty-five").
    func numberToWords(_ n: Int, andWord: String = "and") -> String {
        if n == 0 { return "zero" }
        var n = n
        var negative = false
        if n < 0 { negative = true; n = -n }

        var groups: [Int] = []  // least-significant first
        while n > 0 {
            groups.append(n % 1000)
            n /= 1000
        }
        var parts: [String] = []
        for (i, group) in groups.enumerated().reversed() where group != 0 {
            parts.append(threeDigitWords(group, andWord: andWord) + Self.scales[i])
        }
        let joined = parts.joined(separator: ", ")
        return negative ? "minus " + joined : joined
    }

    private func threeDigitWords(_ n: Int, andWord: String) -> String {
        precondition((1...999).contains(n))
        let hundreds = n / 100
        let rest = n % 100
        var out = ""
        if hundreds > 0 {
            out += Self.units[hundreds] + " hundred"
            if rest > 0 {
                out += andWord.isEmpty ? " " : " \(andWord) "
            }
        }
        if rest > 0 { out += twoDigitWords(rest) }
        return out
    }

    private func twoDigitWords(_ n: Int) -> String {
        precondition((1...99).contains(n))
        if n < 20 { return Self.units[n] }
        let tensWord = Self.tens[n / 10]
        let unit = n % 10
        return unit == 0 ? tensWord : "\(tensWord)-\(Self.units[unit])"  // hyphenated
    }

    /// inflect.number_to_words(n, andword:"", zero:"oh", group:2) with the
    /// reference's `.replace(", ", " ")` applied — e.g. 2019 -> "twenty nineteen",
    /// 2305 -> "twenty-three oh five".
    func numberToWordsGroup2(_ n: Int) -> String {
        var digits = String(n)
        if digits.count % 2 != 0 { digits = "0" + digits }  // only 4-digit reachable
        var words: [String] = []
        var idx = digits.startIndex
        while idx < digits.endIndex {
            let next = digits.index(idx, offsetBy: 2)
            let pair = Int(digits[idx..<next]) ?? 0
            if pair == 0 {
                words.append("oh"); words.append("oh")
            } else if pair < 10 {
                words.append("oh")
                words.append(Self.units[pair])
            } else {
                words.append(twoDigitWords(pair))
            }
            idx = next
        }
        return words.joined(separator: " ")
    }

    /// Cardinal words -> ordinal words ("twenty-one" -> "twenty-first").
    func ordinalize(_ words: String) -> String {
        let irregular = ["one": "first", "two": "second", "three": "third",
                         "five": "fifth", "eight": "eighth", "nine": "ninth",
                         "twelve": "twelfth"]
        // Transform the final hyphen-component of the final word.
        guard let lastWordRange = words.range(of: "[^ ]+$", options: .regularExpression)
        else { return words + "th" }
        var lastWord = String(words[lastWordRange])
        let head = String(words[..<lastWordRange.lowerBound])
        let lastComponentRange = lastWord.range(of: "[^-]+$", options: .regularExpression)!
        let component = String(lastWord[lastComponentRange])
        let ordinalComponent: String
        if let irr = irregular[component] {
            ordinalComponent = irr
        } else if component.hasSuffix("y") {
            ordinalComponent = String(component.dropLast()) + "ieth"
        } else {
            ordinalComponent = component + "th"
        }
        lastWord.replaceSubrange(lastComponentRange, with: ordinalComponent)
        return head + lastWord
    }

    // MARK: regex plumbing

    private func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        with transform: (String, [String]) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd,
                                                 length: match.range.location - lastEnd))
            var groups: [String] = []
            for g in 1..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(ns.substring(with: match.range), groups)
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}

// MARK: - LuxTokenizer (port of EmiliaTokenizer)

public final class LuxTokenizer: @unchecked Sendable {
    public let tokenToID: [String: Int]
    /// ID of "_" (0 in the LuxTTS vocab). The tokenizer never emits it; the
    /// model's batching code uses it for padding, exactly like the reference.
    public let padID: Int
    public let vocabSize: Int

    private let phonemizer: any PhonemizerProviding
    private let normalizer = LuxEnglishTextNormalizer()
    private static let log = Logger(subsystem: "fm.gloam.EngineKit", category: "LuxTokenizer")

    public init(tokensFileURL: URL, phonemizer: any PhonemizerProviding) throws {
        guard let contents = try? String(contentsOf: tokensFileURL, encoding: .utf8) else {
            throw LuxTokenizerError.tokensFileNotFound(tokensFileURL.path)
        }
        var mapping: [String: Int] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            // Format: "{token}\t{id}". The space token is a line " \t3" — do not trim.
            guard let tabIndex = line.lastIndex(of: "\t"),
                  let id = Int(line[line.index(after: tabIndex)...])
            else {
                throw LuxTokenizerError.malformedTokensFile(line: String(line))
            }
            let token = String(line[..<tabIndex])
            precondition(mapping[token] == nil, "duplicate token: \(token)")
            mapping[token] = id
        }
        guard let pad = mapping["_"] else {
            throw LuxTokenizerError.malformedTokensFile(line: "missing pad token \"_\"")
        }
        self.tokenToID = mapping
        self.padID = pad
        self.vocabSize = mapping.count
        self.phonemizer = phonemizer
    }

    #if SWIFT_PACKAGE
    /// Loads the bundled `Resources/tokens.txt`.
    public convenience init(phonemizer: any PhonemizerProviding) throws {
        guard let url = Bundle.module.url(forResource: "tokens", withExtension: "txt") else {
            throw LuxTokenizerError.tokensFileNotFound("Bundle.module tokens.txt")
        }
        try self.init(tokensFileURL: url, phonemizer: phonemizer)
    }
    #endif

    // MARK: public API (mirrors EmiliaTokenizer)

    public func textToTokenIDs(_ text: String) throws -> [Int] {
        tokensToTokenIDs(try textToTokens(text))
    }

    public func textToTokens(_ text: String) throws -> [String] {
        let preprocessed = Self.mapPunctuations(text)
        var phonemes: [String] = []
        for segment in Self.segments(of: preprocessed) {
            switch segment.language {
            case .english:
                let normalized = normalizer.normalize(segment.text)
                phonemes += try phonemizer.phonemize(normalized)
            case .tag:
                phonemes.append(segment.text)  // literal; OOV tags are dropped at ID mapping
            case .chinese, .pinyin:
                // NOT PORTED: requires jieba + pypinyin (see file header).
                Self.log.warning("LuxTokenizer: skipping unsupported \(String(describing: segment.language)) segment: \(segment.text, privacy: .public)")
            case .other:
                // Matches the reference: a segment with no en/zh characters is
                // skipped with a warning (e.g. digits-only input).
                Self.log.warning("LuxTokenizer: skipping segment of unknown language: \(segment.text, privacy: .public)")
            }
        }
        return phonemes
    }

    /// Exact `EmiliaTokenizer.tokens_to_token_ids` for a single sequence:
    /// look up each token; silently drop OOV; no BOS/EOS; no padding.
    public func tokensToTokenIDs(_ tokens: [String]) -> [Int] {
        var ids: [Int] = []
        ids.reserveCapacity(tokens.count)
        for token in tokens {
            if let id = tokenToID[token] {
                ids.append(id)
            }
            // else: OOV skipped, mirroring the reference's debug-log-and-continue.
        }
        return ids
    }

    /// Port of the MLX fork's `_ensure_non_empty_ids` helper: the model cannot
    /// take an empty sequence, so fall back to a single pad token.
    public func ensureNonEmpty(_ ids: [Int]) -> [Int] {
        ids.isEmpty ? [padID] : ids
    }

    // MARK: preprocessing (ports of map_punctuations / get_segment / split_segments)

    static func mapPunctuations(_ text: String) -> String {
        var t = text
        let replacements: [(String, String)] = [
            ("，", ","), ("。", "."), ("！", "!"), ("？", "?"), ("；", ";"),
            ("：", ":"), ("、", ","), ("‘", "'"), ("“", "\""), ("”", "\""),
            ("’", "'"), ("⋯", "…"), ("···", "…"), ("・・・", "…"), ("...", "…"),
        ]
        for (from, to) in replacements {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
    }

    enum SegmentLanguage { case english, chinese, pinyin, tag, other }
    struct Segment { let text: String; let language: SegmentLanguage }

    /// Port of `get_segment` + `split_segments`. Splits text into character
    /// parts (plus `<...>` / `[...]` groups), classifies runs as en/zh/other
    /// (with "other" characters absorbed into the surrounding run), then
    /// extracts pinyin/tag sub-segments.
    static func segments(of text: String) -> [Segment] {
        // Python: re.findall(r"[<[].*?[>\]]|.", text). "." does not match "\n",
        // so newlines are dropped — reproduced here.
        let partPattern = try! NSRegularExpression(pattern: "[<\\[].*?[>\\]]|.")
        let ns = text as NSString
        let parts: [String] = partPattern
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        guard !parts.isEmpty else { return [] }

        enum RunType { case zh, en, other }
        let types: [RunType] = parts.map { part in
            if isChinesePart(part) || isPinyinPart(part) { return .zh }
            if isAlphabetPart(part) { return .en }
            return .other
        }

        var runs: [(text: String, type: RunType)] = []
        var tempSeg = ""
        var tempType = RunType.other
        for i in 0..<parts.count {
            if i == 0 {
                tempSeg = parts[i]
                tempType = types[i]
            } else if tempType == .other {
                tempSeg += parts[i]
                tempType = types[i]
            } else if types[i] == tempType || types[i] == .other {
                tempSeg += parts[i]
            } else {
                runs.append((tempSeg, tempType))
                tempSeg = parts[i]
                tempType = types[i]
            }
        }
        runs.append((tempSeg, tempType))

        // split_segments: extract <pinyin> and [tag] islands.
        let islandPattern = try! NSRegularExpression(pattern: "[<\\[].*?[>\\]]")
        var result: [Segment] = []
        for run in runs {
            let runNS = run.text as NSString
            var last = 0
            var slices: [String] = []
            for m in islandPattern.matches(in: run.text,
                                           range: NSRange(location: 0, length: runNS.length)) {
                if m.range.location > last {
                    slices.append(runNS.substring(
                        with: NSRange(location: last, length: m.range.location - last)))
                }
                slices.append(runNS.substring(with: m.range))
                last = m.range.location + m.range.length
            }
            if last < runNS.length { slices.append(runNS.substring(from: last)) }

            for slice in slices where !slice.isEmpty {
                if isPinyinPart(slice) {
                    result.append(Segment(text: slice, language: .pinyin))
                } else if isTagPart(slice) {
                    result.append(Segment(text: slice, language: .tag))
                } else {
                    let lang: SegmentLanguage = switch run.type {
                    case .zh: .chinese
                    case .en: .english
                    case .other: .other
                    }
                    result.append(Segment(text: slice, language: lang))
                }
            }
        }
        return result
    }

    static func isChinesePart(_ part: String) -> Bool {
        guard part.count == 1, let scalar = part.unicodeScalars.first else { return false }
        return (0x4E00...0x9FA5).contains(scalar.value)
    }

    static func isAlphabetPart(_ part: String) -> Bool {
        guard part.count == 1, let c = part.first else { return false }
        return ("A"..."Z").contains(String(c)) || ("a"..."z").contains(String(c))
    }

    static func isPinyinPart(_ part: String) -> Bool {
        part.hasPrefix("<") && part.hasSuffix(">")
    }

    static func isTagPart(_ part: String) -> Bool {
        part.hasPrefix("[") && part.hasSuffix("]")
    }
}
