import Foundation

/// Keyless web search, by scraping DuckDuckGo's no-JavaScript HTML endpoint.
///
/// Keyless is the whole point. Any API key shipped in an app bundle is
/// extractable, which makes it our bill and our rate limit, publicly. This
/// asks nothing of the user and spends nothing of ours.
///
/// The cost is that this is scraping, not an API: it WILL break one day. The
/// design's job is to make that break loud and local, which is why the parse
/// is a pure function over a string (`parse(html:query:)`) with fixture tests,
/// and why `.unparseable` is a distinct case rather than an empty list.
public struct DuckDuckGoSearch: WebSearching {
    /// A desktop user-agent. The endpoint serves a different, much thinner
    /// page to anything that looks like a bot, and the thinner page has none
    /// of the classes below.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func search(_ query: String, limit: Int = 8) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.noResults(query) }
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { throw WebSearchError.transport("bad query") }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            // 202 is DuckDuckGo's own throttle response, not a success.
            if http.statusCode == 429 || http.statusCode == 202 || http.statusCode == 403 {
                throw WebSearchError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else {
                throw WebSearchError.transport("HTTP \(http.statusCode)")
            }
        }
        guard let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw WebSearchError.unparseable }
        return try Self.parse(html: html, query: trimmed, limit: limit)
    }

    // MARK: - The pure part

    /// Turn a results page into hits. Pure, so the fixtures in
    /// `DuckDuckGoSearchTests` catch a markup change at build time rather than
    /// in somebody's hands.
    public static func parse(html: String, query: String, limit: Int = 8) throws -> [SearchHit] {
        if isRateLimitPage(html) { throw WebSearchError.rateLimited }

        let titles = anchors(in: html, class: "result__a")
        let snippets = anchors(in: html, class: "result__snippet")

        guard !titles.isEmpty else {
            // Told apart deliberately: an explicit "no results" banner is a
            // fact about the query, anything else is a fact about our parser.
            if isNoResultsPage(html) { throw WebSearchError.noResults(query) }
            throw WebSearchError.unparseable
        }

        var hits: [SearchHit] = []
        for (offset, anchor) in titles.enumerated() {
            guard let url = resolvedURL(anchor.href) else { continue }
            let end = offset + 1 < titles.count ? titles[offset + 1].start : html.endIndex
            // Snippets are matched by position, not by index: a result without
            // one must not steal the next result's.
            let snippet = snippets.first { $0.start > anchor.start && $0.start < end }
            hits.append(SearchHit(title: HTMLText.plain(anchor.inner),
                                  url: url,
                                  snippet: HTMLText.plain(snippet?.inner ?? "")))
            if hits.count >= limit { break }
        }
        guard !hits.isEmpty else { throw WebSearchError.unparseable }
        return hits
    }

    private static func isRateLimitPage(_ html: String) -> Bool {
        let markers = ["anomaly-modal", "anomaly.js", "unusual traffic",
                       "bots use DuckDuckGo too"]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    private static func isNoResultsPage(_ html: String) -> Bool {
        html.contains("no-results") || html.localizedCaseInsensitiveContains("No results.")
    }

    /// DuckDuckGo wraps most result links in its own redirector,
    /// `//duckduckgo.com/l/?uddg=<percent-encoded target>&rut=…`. The target is
    /// what the article reader needs; the redirector would work but leaves the
    /// user staring at a duckduckgo.com URL for an article they asked for.
    static func resolvedURL(_ href: String) -> URL? {
        var raw = HTMLText.decodingEntities(href)
        if raw.hasPrefix("//") { raw = "https:" + raw }
        guard let url = URL(string: raw) else { return nil }
        if let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "uddg" })?.value,
           let unwrapped = URL(string: target) {
            return unwrapped.scheme.map { $0 == "http" || $0 == "https" } == true ? unwrapped : nil
        }
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: - Anchor scanning

    struct Anchor {
        var href: String
        var inner: String
        var start: String.Index
    }

    /// Every `<a …class="…<name>…"…>inner</a>` in document order.
    ///
    /// Hand-rolled rather than regex because the inner HTML contains `<b>`
    /// highlight tags and DuckDuckGo's attribute order is not fixed; a scanner
    /// that finds the tag, then reads its attributes, does not care about
    /// either.
    static func anchors(in html: String, class name: String) -> [Anchor] {
        var found: [Anchor] = []
        var cursor = html.startIndex
        while let open = html.range(of: "<a", range: cursor..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else {
                break
            }
            let attrs = String(html[open.upperBound..<tagEnd.lowerBound])
            cursor = tagEnd.upperBound
            guard let classes = attribute("class", in: attrs),
                  classes.split(separator: " ").contains(where: { $0 == name }),
                  let href = attribute("href", in: attrs)
            else { continue }
            guard let close = html.range(of: "</a>", range: cursor..<html.endIndex) else { break }
            found.append(Anchor(href: href,
                                inner: String(html[cursor..<close.lowerBound]),
                                start: open.lowerBound))
            cursor = close.upperBound
        }
        return found
    }

    /// `name="value"` out of a tag's attribute text. Single quotes too, since
    /// nothing guarantees which a server emits.
    static func attribute(_ name: String, in attrs: String) -> String? {
        var cursor = attrs.startIndex
        while let key = attrs.range(of: name, range: cursor..<attrs.endIndex) {
            cursor = key.upperBound
            // Must be a whole attribute name: `href` must not match `data-href`.
            let precededByBoundary = key.lowerBound == attrs.startIndex
                || " \t\n\r".contains(attrs[attrs.index(before: key.lowerBound)])
            var after = key.upperBound
            while after < attrs.endIndex, attrs[after] == " " { after = attrs.index(after: after) }
            guard precededByBoundary, after < attrs.endIndex, attrs[after] == "=" else { continue }
            var value = attrs.index(after: after)
            while value < attrs.endIndex, attrs[value] == " " { value = attrs.index(after: value) }
            guard value < attrs.endIndex else { return nil }
            let quote = attrs[value]
            guard quote == "\"" || quote == "'" else { continue }
            let contentStart = attrs.index(after: value)
            guard let end = attrs[contentStart...].firstIndex(of: quote) else { return nil }
            return String(attrs[contentStart..<end])
        }
        return nil
    }
}
