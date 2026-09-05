import EngineKit
import Foundation
import Observation
import StudioKit

/// Turning a piece of writing into a two-host script the user approves before
/// any audio is made.
///
/// The model does not fetch and does not search — it is a function from text to
/// text. Every network act here is Swift code: `WebSearching` finds candidates,
/// `ArticleReading` renders and extracts one, and only then does the LLM see
/// anything. Keeping that split explicit is what makes each step cancellable,
/// individually testable, and honest about where a failure happened.
@MainActor @Observable
final class ArticleImportModel {
    /// Three first-class ways in. Text is not a fallback: it is the answer for
    /// paywalls, PDFs, newsletters and the user's own drafts, and it is the
    /// only one that cannot fail at the fetch step.
    enum Mode: String, CaseIterable, Identifiable {
        case link, topic, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .link: "Link"
            case .topic: "Topic"
            case .text: "Text"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case searching
        case hits
        case fetching
        case scripting
        case review
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .searching, .fetching, .scripting: true
            default: false
            }
        }
    }

    /// One line in the review sheet. Identity is its own, not its index, so
    /// editing a line above does not re-create every row below it.
    struct ReviewLine: Identifiable, Equatable {
        let id = UUID()
        var speaker: Int
        var text: String
    }

    var mode: Mode = .link
    var link = ""
    var topic = ""
    var pastedText = ""
    /// Episode length. The picker offers 2/5/10; the value is what the word
    /// budget is computed from.
    var targetMinutes: Double = 5

    private(set) var phase: Phase = .idle
    private(set) var hits: [SearchHit] = []
    private(set) var article: Article?
    /// Non-fatal things worth saying before the user commits: a short
    /// extraction, an invented sound tag.
    private(set) var warnings: [String] = []
    /// The model's raw reply, kept so a bad parse loses nothing.
    private(set) var rawReply: String?
    var reviewLines: [ReviewLine] = []

    unowned let app: AppModel
    private let search: any WebSearching
    private let reader: any ArticleReading
    private var work: Task<Void, Never>?

    init(app: AppModel,
         search: any WebSearching = DuckDuckGoSearch(),
         reader: (any ArticleReading)? = nil) {
        self.app = app
        self.search = search
        self.reader = reader ?? ReadabilityArticleReader()
    }

    // MARK: - Readiness

    /// Whether "Script it" has anything to work with. Deliberately not a check
    /// on the LLM: `ensureLLMReady` downloads it, so a missing model is a wait,
    /// not a dead end.
    var canScript: Bool {
        guard !phase.isBusy else { return false }
        switch mode {
        case .link: return !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .topic: return article != nil
        case .text:
            return pastedText.split(whereSeparator: \.isWhitespace).count
                >= PodcastScripter.minimumArticleWords
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        if phase.isBusy { phase = hits.isEmpty ? .idle : .hits }
    }

    func reset() {
        cancel()
        hits = []; article = nil; warnings = []; rawReply = nil; reviewLines = []
        phase = .idle
    }

    // MARK: - Search

    func runSearch() {
        let query = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        work?.cancel()
        phase = .searching
        hits = []; article = nil
        work = Task {
            do {
                let found = try await search.search(query, limit: 8)
                guard !Task.isCancelled else { return }
                hits = found
                phase = .hits
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(app.describeAny(error))
            }
        }
    }

    /// The USER picks the result, never the model. A bad source is invisible
    /// once it is finished audio, which is the same reason the script itself is
    /// reviewed before anything is generated.
    func choose(_ hit: SearchHit) {
        work?.cancel()
        phase = .fetching
        work = Task {
            await fetchThenScript(hit.url)
        }
    }

    // MARK: - Script

    func scriptIt() {
        work?.cancel()
        warnings = []; rawReply = nil
        switch mode {
        case .link:
            let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), url.host() != nil else {
                phase = .failed("That doesn't look like a web address."); return
            }
            phase = .fetching
            work = Task { await fetchThenScript(url) }
        case .topic:
            guard let article else { phase = .failed("Pick a result first."); return }
            phase = .scripting
            work = Task { await script(article) }
        case .text:
            let body = HTMLText.collapsingWhitespace(pastedText)
            let words = body.split(whereSeparator: \.isWhitespace).count
            guard words >= PodcastScripter.minimumArticleWords else {
                phase = .failed(ScriptingError.articleTooShort(words: words).localizedDescription)
                return
            }
            // A pasted body has no title of its own; the first line is the
            // best guess available and the model is told it is a guess.
            let firstLine = body.split(separator: ".").first.map(String.init) ?? "Pasted text"
            let made = Article(title: String(firstLine.prefix(90)), text: body)
            article = made
            phase = .scripting
            work = Task { await script(made) }
        }
    }

    private func fetchThenScript(_ url: URL) async {
        do {
            let read = try await reader.read(url)
            guard !Task.isCancelled else { return }
            article = read
            if read.looksTruncated {
                // A paywall teaser extracts cleanly and reads like an article.
                // Warning rather than failing, because scripting silently from
                // a stub is the worst outcome available: it looks fine.
                warnings.append("Only \(read.wordCount) words came out of that page — it may be "
                    + "a paywall teaser or a summary. Check it reads like the whole piece, or "
                    + "paste the text instead.")
            }
            phase = .scripting
            await script(read)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(app.describeAny(error))
        }
    }

    private func script(_ article: Article) async {
        guard app.hasSufficientRAM(for: app.chatLLM) else {
            phase = .failed("\(app.chatLLM.rawValue) "
                + "\(app.ramRequirementLabel(minRAMBytes: app.chatLLM.minRAMBytes)) and this Mac "
                + "has less. Pick a smaller chat model in Settings.")
            return
        }
        do {
            try await app.ensureLLMReady(app.chatLLM)
            guard !Task.isCancelled else { return }
            let tags = Set((try? await app.engine.nonverbalTags(backend: .dia2)) ?? [])
            let hosts = hostNames()
            let request = PodcastScripter.prompt(for: article, targetMinutes: targetMinutes,
                                                 hosts: hosts, tags: tags)
            let reply = try await app.engine.chat(backend: app.chatLLM, request: request)
            guard !Task.isCancelled else { return }
            rawReply = reply.text
            let parsed = try PodcastScripter.parse(reply.text, knownTags: tags)
            if !parsed.unknownTags.isEmpty {
                warnings.append("The script uses \(parsed.unknownTags.joined(separator: ", "))"
                    + ", which Dia2 doesn't know — it would be read out loud. Edit or remove "
                    + "them below.")
            }
            reviewLines = parsed.turns.map { ReviewLine(speaker: $0.speaker, text: $0.text) }
            // Saved here, not at "Use & Generate". A script costs a whole LLM
            // run; discarding it because the user closed the sheet to think
            // about it would throw away the expensive part of the work.
            save(parsed.turns, from: article)
            phase = .review
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(app.describeAny(error))
        }
    }

    /// Record the script with the article it came from.
    ///
    /// Failing to write history must never fail the script the user is looking
    /// at, so this reports rather than throws.
    private func save(_ turns: [ScriptedTurn], from article: Article) {
        do {
            try app.scriptHistory.record(
                sourceKind: mode.rawValue,
                title: article.title,
                url: article.url?.absoluteString,
                siteName: article.siteName,
                byline: article.byline,
                articleWords: article.wordCount,
                targetMinutes: targetMinutes,
                model: app.chatLLM.rawValue,
                turns: turns.map { .init(speaker: $0.speaker, text: $0.text) })
            app.scriptHistoryVersion += 1
        } catch {
            warnings.append("Couldn't save this script to history: \(app.describeAny(error))")
        }
    }

    /// Reopen a saved script in the review sheet, source and all, so it can be
    /// re-cast and re-rendered without paying for the model run again.
    func reopen(_ entry: ScriptHistoryEntry) {
        cancel()
        warnings = []
        rawReply = nil
        article = Article(title: entry.title, byline: entry.byline, siteName: entry.siteName,
                          text: "", url: entry.url.flatMap(URL.init(string:)))
        targetMinutes = entry.targetMinutes
        reviewLines = entry.turns.map { ReviewLine(speaker: $0.speaker, text: $0.text) }
        phase = .review
    }

    /// The cast's own names when they have been chosen, so the script is
    /// written for the voices that will read it.
    private func hostNames() -> (String, String) {
        let names = app.dialogue.voices.map { slug -> String? in
            slug.flatMap { try? app.voices.meta($0).name }
        }
        return (names[0] ?? "Host A", names[1] ?? "Host B")
    }

    // MARK: - Apply

    /// Replace the composer's turns with the reviewed script.
    ///
    /// Destructive by design and only reachable from the review sheet, which is
    /// where the user sees what they are about to replace them with.
    func applyToComposer() {
        let lines = reviewLines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lines.isEmpty else { return }
        app.dialogue.replaceTurns(with: lines.map {
            DialogueComposer.Turn(speaker: $0.speaker, text: $0.text)
        })
        phase = .idle
    }

    /// Close the review sheet without touching the composer. The script is
    /// discarded on purpose: keeping it would leave a stale "approved" script
    /// hanging around that no longer matches the source.
    func discardReview() {
        reviewLines = []
        phase = .idle
    }

    /// Estimated audio length of what is in the review sheet — the honest
    /// number, measured off the actual words, not the length that was asked
    /// for.
    var reviewSeconds: Double {
        reviewLines.reduce(0) { $0 + DialoguePlanner.estimatedSeconds(of: $1.text) }
    }
}
