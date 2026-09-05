import EngineKit
import Foundation

/// One line of a generated script, before it becomes a composer turn.
public struct ScriptedTurn: Sendable, Equatable {
    /// 1 or 2 — the same two speakers Dia2 has.
    public var speaker: Int
    public var text: String
    public init(speaker: Int, text: String) { self.speaker = speaker; self.text = text }
}

/// What came back from the model, including the parts worth showing the user
/// before they commit to generating audio.
public struct ParsedScript: Sendable, Equatable {
    public var turns: [ScriptedTurn]
    /// Bracketed sounds the model invented that Dia2 does not know. Reported
    /// rather than thrown: the user can fix them in the review sheet, whereas
    /// a throw at Generate would discard the whole script.
    public var unknownTags: [String]
    /// The model's raw reply, kept so nothing is ever lost to a bad parse.
    public var raw: String

    public init(turns: [ScriptedTurn], unknownTags: [String], raw: String) {
        self.turns = turns; self.unknownTags = unknownTags; self.raw = raw
    }
}

public enum ScriptingError: Error, LocalizedError, Equatable {
    case noScriptInReply
    case articleTooShort(words: Int)

    public var errorDescription: String? {
        switch self {
        case .noScriptInReply:
            "The model didn't write anything in the [S1]/[S2] format. Its reply is below — "
                + "try again, or use a stronger chat model."
        case .articleTooShort(let words):
            "There are only \(words) words here — not enough to script from."
        }
    }
}

/// Turns an article into a two-host script.
///
/// Two pure functions and no engine reference, on purpose: the parts most
/// likely to be wrong (the prompt's shape, and surviving whatever a small
/// local model actually emits) are the parts that are directly unit-testable.
public enum PodcastScripter {
    /// The shortest article worth scripting at all.
    public static let minimumArticleWords = 60

    /// How much article text goes into the prompt.
    ///
    /// Every backend advertises a 32k context, and a word is roughly 1.4
    /// tokens for prose, so 8,000 words leaves comfortable room for the
    /// instructions and the reply. Long-read inputs are truncated rather than
    /// refused — the top of a feature carries its own argument.
    public static let maxPromptWords = 8_000

    /// Target length in words, from a target length in minutes.
    ///
    /// A word budget, not "about three minutes": models hit word counts far
    /// more reliably than durations. `DialoguePlanner.wordsPerSecond` is the
    /// same measured constant the pass planner uses, so the picker's estimate
    /// and the plan below it cannot disagree.
    ///
    /// This is NOT `sceneBudgetSeconds`. That is a per-pass drift limit; this
    /// is how long the episode should be. A 10-minute script is many passes.
    public static func wordBudget(targetMinutes: Double) -> Int {
        Int((targetMinutes * 60 * DialoguePlanner.wordsPerSecond).rounded())
    }

    public static func prompt(for article: Article,
                              targetMinutes: Double,
                              hosts: (String, String),
                              tags: Set<String> = []) -> ChatRequest {
        let budget = wordBudget(targetMinutes: targetMinutes)
        let (source, truncated) = trimmed(article.text, to: maxPromptWords)

        var system = """
        You write short two-host podcast scripts. Two people, \(hosts.0) and \(hosts.1), \
        talk through one article for a listener who has not read it.

        Format — this matters, follow it exactly:
        - Every line begins with [S1] or [S2] and nothing else. No names, no bold, no stage \
        directions, no markdown.
        - [S1] is \(hosts.0). [S2] is \(hosts.1).
        - Alternate speakers. Do not put two [S1] lines in a row.
        - Output the script and nothing else — no preamble, no title, no closing remark \
        about the script itself.

        Writing it:
        - About \(budget) words in total. That is the length, not a suggestion.
        - Open by saying what the piece is about; do not open with "welcome back".
        - Cover the actual substance: what happened, why it matters, what is contested.
        - Attribute claims to the article. Invent no facts, no statistics and no quotes.
        - Speak plainly. Contractions, short sentences, no host-voice cliché.
        """
        if !tags.isEmpty {
            // Given only if the engine reports them, so the model is never
            // invited to use a vocabulary this build cannot render.
            let sample = tags.sorted().prefix(8).joined(separator: " ")
            system += "\n- Sounds like \(sample) may be used sparingly, in brackets, "
                + "inline. Use no bracketed sound outside that list."
        }

        var user = "Article"
        if let site = article.siteName { user += " from \(site)" }
        user += "\nTitle: \(article.title)"
        if let byline = article.byline { user += "\nBy: \(byline)" }
        if let url = article.url { user += "\nURL: \(url.absoluteString)" }
        if truncated {
            user += "\n(Only the opening of a long piece is included below.)"
        }
        user += "\n\n\(source)"

        return ChatRequest(
            messages: [ChatTurn(role: .system, content: system),
                       ChatTurn(role: .user, content: user)],
            temperature: 0.7,
            // Generous headroom over the word budget: a reply cut off mid-line
            // costs the whole run, and unused tokens cost nothing.
            maxTokens: max(700, Int(Double(budget) * 2.2)),
            disableThinking: true)
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"\([a-z][a-z ]*\)"#)
    private static let speakerPattern = try! NSRegularExpression(
        // Tolerates what models actually emit around the tag: leading bullets
        // or numbering, markdown bold, missing brackets, and a colon after it.
        pattern: #"^[\s>*\-\d.]*\**\[?\s*S\s*([12])\s*\]?\**\s*[:\-–]?\s*(.*)$"#,
        options: [.caseInsensitive])

    /// Pull the script out of whatever the model said.
    ///
    /// Only tag-matching lines survive, which is what makes a chatty preamble
    /// ("Sure! Here's a script:") harmless instead of corrupting.
    public static func parse(_ reply: String, knownTags: Set<String>) throws -> ParsedScript {
        var turns: [ScriptedTurn] = []
        var unknown: [String] = []

        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = speakerPattern.firstMatch(in: text, range: range),
                  let speakerRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text),
                  let speaker = Int(text[speakerRange])
            else { continue }
            var body = String(text[bodyRange])
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A model that closes with markdown fencing leaves it on the last
            // line rather than on its own.
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            if !knownTags.isEmpty {
                let ns = body as NSString
                for hit in tagPattern.matches(in: body,
                                              range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: hit.range)
                    if !knownTags.contains(tag), !unknown.contains(tag) { unknown.append(tag) }
                }
            }
            turns.append(ScriptedTurn(speaker: speaker, text: body))
        }

        guard !turns.isEmpty else { throw ScriptingError.noScriptInReply }
        return ParsedScript(turns: turns, unknownTags: unknown, raw: reply)
    }

    /// First `limit` words, and whether anything was dropped.
    static func trimmed(_ text: String, to limit: Int) -> (String, Bool) {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return (text, false) }
        return (words.prefix(limit).joined(separator: " "), true)
    }
}
