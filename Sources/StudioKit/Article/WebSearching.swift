import Foundation

/// One web search result, as much as any provider gives us for free.
public struct SearchHit: Sendable, Equatable, Identifiable {
    public var title: String
    public var url: URL
    public var snippet: String
    public var id: URL { url }
    public init(title: String, url: URL, snippet: String) {
        self.title = title; self.url = url; self.snippet = snippet
    }
}

/// Why a search produced nothing usable. The cases are distinguished on
/// purpose: "nothing matched" and "the markup changed under us" are the same
/// empty list to the code and completely different facts to the user.
public enum WebSearchError: Error, LocalizedError, Equatable {
    /// The query genuinely matched nothing.
    case noResults(String)
    /// The provider throttled us. Backing off, or pasting a link, is the fix.
    case rateLimited
    /// A page came back that we could not read at all — for a scraped
    /// provider this means the markup moved, which is a bug on our side.
    case unparseable
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noResults(let query): "No results for “\(query)”."
        case .rateLimited:
            "DuckDuckGo is rate-limiting this Mac. Try again shortly, or paste the link."
        case .unparseable:
            "Couldn't read DuckDuckGo's results — the page format has probably changed."
        case .transport(let why): "Search failed: \(why)"
        }
    }
}

/// A source of web search results.
///
/// A protocol from the first provider, not the second: the keyless scraped
/// backend below is the only one that ships, but a user-supplied Brave or
/// Tavily key is a plausible next step and should cost one new file, not a
/// rewrite of every caller.
public protocol WebSearching: Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
}
