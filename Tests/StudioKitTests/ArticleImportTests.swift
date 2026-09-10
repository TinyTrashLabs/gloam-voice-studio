import EngineKit
import XCTest
@testable import StudioKit

/// The scraped/parsed half of article import. Every test here is a pure
/// function over a string, which is the point: this is the code most likely to
/// break silently when somebody else's markup or a model's phrasing changes,
/// so it breaks at build time instead.
final class DuckDuckGoParseTests: XCTestCase {
    /// Trimmed from a real html.duckduckgo.com response: two results, the
    /// redirector-wrapped hrefs, `<b>` highlights inside the title, and the
    /// entity-encoded ampersand that separates the query parameters.
    private let resultsPage = """
    <html><body>
    <div class="result results_links results_links_deep web-result">
      <div class="result__body">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.example.com%2Fnews%2Ffusion&amp;rut=abc">
            <b>Fusion</b> milestone repeated
          </a>
        </h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.example.com%2Fnews%2Ffusion">
          Researchers said the reaction produced more energy than it consumed &mdash; again.
        </a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result">
      <div class="result__body">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fother.example.org%2Fpost">
            What it doesn&#39;t mean
          </a>
        </h2>
      </div>
    </div>
    </body></html>
    """

    func testParsesTitleURLAndSnippet() throws {
        let hits = try DuckDuckGoSearch.parse(html: resultsPage, query: "fusion")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "Fusion milestone repeated")
        XCTAssertEqual(hits[0].url.absoluteString, "https://www.example.com/news/fusion")
        XCTAssertTrue(hits[0].snippet.hasSuffix("than it consumed — again."))
    }

    /// The failure this ordering exists to prevent: result 2 has no snippet, so
    /// zipping the two lists by index would hand it result 1's.
    func testAResultWithoutASnippetDoesNotStealItsNeighboursOne() throws {
        let hits = try DuckDuckGoSearch.parse(html: resultsPage, query: "fusion")
        XCTAssertEqual(hits[1].title, "What it doesn't mean")
        XCTAssertEqual(hits[1].snippet, "")
    }

    func testLimitIsHonoured() throws {
        XCTAssertEqual(try DuckDuckGoSearch.parse(html: resultsPage, query: "x", limit: 1).count, 1)
    }

    /// Throttling is a distinct case, not an empty list: the user can act on
    /// "wait a moment" and cannot act on "no results".
    func testRateLimitPageIsRateLimitedNotEmpty() {
        let page = "<html><body><div id=\"anomaly-modal\">Unfortunately, bots use "
            + "DuckDuckGo too.</div></body></html>"
        XCTAssertThrowsError(try DuckDuckGoSearch.parse(html: page, query: "fusion")) {
            XCTAssertEqual($0 as? WebSearchError, .rateLimited)
        }
    }

    func testNoResultsPageIsToldApartFromChangedMarkup() {
        let empty = "<html><body><div class=\"no-results\">No results.</div></body></html>"
        XCTAssertThrowsError(try DuckDuckGoSearch.parse(html: empty, query: "asdkjhasd")) {
            XCTAssertEqual($0 as? WebSearchError, .noResults("asdkjhasd"))
        }
    }

    /// The one that matters for maintenance. When DuckDuckGo renames its
    /// classes, this is the test that fails, and `.unparseable` is what turns a
    /// user's mystery into a bug report.
    func testChangedMarkupIsUnparseable() {
        let page = "<html><body><a class=\"totally__renamed\" href=\"https://x.example\">Hi</a>"
            + "</body></html>"
        XCTAssertThrowsError(try DuckDuckGoSearch.parse(html: page, query: "fusion")) {
            XCTAssertEqual($0 as? WebSearchError, .unparseable)
        }
    }

    func testDirectHTTPSHrefsSurviveAndOtherSchemesDoNot() {
        XCTAssertEqual(DuckDuckGoSearch.resolvedURL("https://a.example/p")?.absoluteString,
                       "https://a.example/p")
        XCTAssertNil(DuckDuckGoSearch.resolvedURL("javascript:alert(1)"))
        XCTAssertNil(DuckDuckGoSearch.resolvedURL("/y.js?ad=1&x=2"))
    }

    /// `href` must not be matched inside `data-href`, which the page also has.
    func testAttributeReadingRespectsNameBoundaries() {
        XCTAssertEqual(DuckDuckGoSearch.attribute("href", in: #"data-href="no" href="yes""#),
                       "yes")
    }
}

final class HTMLTextTests: XCTestCase {
    func testStripsTagsDecodesEntitiesAndCollapsesWhitespace() {
        XCTAssertEqual(HTMLText.plain("<p>a  <b>b</b>\n  c&amp;d</p>"), "a b c&d")
    }

    func testUnknownEntityIsLeftAloneRatherThanEaten() {
        XCTAssertEqual(HTMLText.decodingEntities("&zzz; &amp;"), "&zzz; &")
    }

    func testNumericEntities() {
        XCTAssertEqual(HTMLText.decodingEntities("caf&#233; &#x2014; ok"), "café — ok")
    }
}

final class PodcastScripterTests: XCTestCase {
    private func article(words: Int = 400) -> Article {
        Article(title: "The Fusion Milestone, Again",
                byline: "A Reporter", siteName: "Example News",
                text: Array(repeating: "energy", count: words).joined(separator: " "),
                url: URL(string: "https://example.com/fusion"))
    }

    // MARK: length

    /// The budget is words, from the SAME constant the pass planner uses, so
    /// the length picker and the pass plan under it cannot disagree.
    func testWordBudgetFollowsThePlannersOwnRate() {
        XCTAssertEqual(PodcastScripter.wordBudget(targetMinutes: 5),
                       Int((5 * 60 * DialoguePlanner.wordsPerSecond).rounded()))
        XCTAssertEqual(PodcastScripter.wordBudget(targetMinutes: 2), 324)
    }

    /// The budget is an episode length; `sceneBudgetSeconds` is a per-pass
    /// drift limit. Conflating them would cap every episode at 45 seconds.
    func testTheLengthTargetIsNotThePassBudget() {
        XCTAssertGreaterThan(Double(PodcastScripter.wordBudget(targetMinutes: 5)),
                             DialoguePlanner.sceneBudgetSeconds * DialoguePlanner.wordsPerSecond)
    }

    // MARK: prompt

    func testPromptCarriesTheBudgetTheTitleAndTheBody() {
        let request = PodcastScripter.prompt(for: article(), targetMinutes: 5,
                                             hosts: ("Ava", "Rex"))
        let system = request.messages[0].content
        let user = request.messages[1].content
        XCTAssertTrue(system.contains("\(PodcastScripter.wordBudget(targetMinutes: 5)) words"))
        XCTAssertTrue(system.contains("[S1] is Ava"))
        XCTAssertTrue(user.contains("The Fusion Milestone, Again"))
        XCTAssertTrue(user.contains("Example News"))
        XCTAssertTrue(user.contains("energy energy"))
        XCTAssertFalse(request.messages[0].content.contains("(chuckles)"))
    }

    /// A model is only told about sounds this build can actually render.
    func testTagsAreOfferedOnlyWhenTheEngineReportsThem() {
        let withTags = PodcastScripter.prompt(for: article(), targetMinutes: 2,
                                              hosts: ("A", "B"), tags: ["(laughs)"])
        XCTAssertTrue(withTags.messages[0].content.contains("(laughs)"))
    }

    /// Long reads are truncated, not refused — and the prompt says so, so the
    /// model does not pretend to summarise what it was not shown.
    func testLongArticlesAreTruncatedAndTheUserTurnSaysSo() {
        let long = article(words: PodcastScripter.maxPromptWords + 500)
        let user = PodcastScripter.prompt(for: long, targetMinutes: 5,
                                          hosts: ("A", "B")).messages[1].content
        XCTAssertTrue(user.contains("Only the opening"))
        XCTAssertLessThan(user.split(whereSeparator: \.isWhitespace).count,
                          PodcastScripter.maxPromptWords + 100)
    }

    // MARK: parse

    /// What a small local model actually emits: a preamble, markdown bold,
    /// bullets, a stray colon, blank lines, and a sign-off.
    func testParseSurvivesRealModelSlop() throws {
        let reply = """
        Sure! Here's a 2-minute script for you:

        **[S1]:** So there's this fusion result everybody is quoting.
        - [S2] Right, and it's the second time, which is the part that matters.

        [s1] Say more?
        [S2] (laughs) Happily.

        Let me know if you'd like it longer!
        """
        let parsed = try PodcastScripter.parse(reply, knownTags: ["(laughs)"])
        XCTAssertEqual(parsed.turns.map(\.speaker), [1, 2, 1, 2])
        XCTAssertEqual(parsed.turns[0].text,
                       "So there's this fusion result everybody is quoting.")
        XCTAssertEqual(parsed.turns[3].text, "(laughs) Happily.")
        XCTAssertTrue(parsed.unknownTags.isEmpty)
    }

    /// A preamble that mentions the format must not become a line of dialogue.
    func testChattyPreambleIsDiscardedNotSpoken() throws {
        let parsed = try PodcastScripter.parse("Here is the script.\n[S1] Hello.",
                                               knownTags: [])
        XCTAssertEqual(parsed.turns.count, 1)
        XCTAssertEqual(parsed.turns[0].text, "Hello.")
    }

    /// An invented sound is reported, not thrown: throwing here would discard
    /// a good script over one word the user can delete.
    func testInventedTagsAreReportedAndTheScriptSurvives() throws {
        let parsed = try PodcastScripter.parse("[S1] (chuckles) Sure.\n[S2] (laughs) Yes.",
                                               knownTags: ["(laughs)"])
        XCTAssertEqual(parsed.unknownTags, ["(chuckles)"])
        XCTAssertEqual(parsed.turns.count, 2)
    }

    func testNoTagsMeansNoTagValidation() throws {
        let parsed = try PodcastScripter.parse("[S1] (whatever) hi", knownTags: [])
        XCTAssertTrue(parsed.unknownTags.isEmpty)
    }

    /// The raw reply is kept so a failed parse loses nothing.
    func testAReplyWithNoScriptThrowsAndSaysWhy() {
        XCTAssertThrowsError(try PodcastScripter.parse("I can't help with that.",
                                                       knownTags: [])) {
            XCTAssertEqual($0 as? ScriptingError, .noScriptInReply)
        }
    }

    func testSpeakerThreeIsNotAScriptLine() throws {
        let parsed = try PodcastScripter.parse("[S1] a\n[S3] b\n[S2] c", knownTags: [])
        XCTAssertEqual(parsed.turns.map(\.speaker), [1, 2])
    }
}

final class ArticleTests: XCTestCase {
    /// A paywall teaser extracts cleanly and reads like a real article. The
    /// word floor is the only thing between that and a confident script built
    /// from three paragraphs of nothing.
    func testShortExtractionsAreFlaggedAsProbablyTruncated() {
        let teaser = Article(title: "Teaser", text: Array(repeating: "word", count: 90).joined(separator: " "))
        XCTAssertTrue(teaser.looksTruncated)
        let full = Article(title: "Full", text: Array(repeating: "word", count: 900).joined(separator: " "))
        XCTAssertFalse(full.looksTruncated)
    }
}
