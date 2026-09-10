import Foundation

/// A readable article: what a reader-view extraction leaves after the nav,
/// the cookie banner, the newsletter box and the related-stories rail.
public struct Article: Sendable, Equatable {
    public var title: String
    public var byline: String?
    public var siteName: String?
    /// Plain text — no markup. This is what goes to the language model.
    public var text: String
    public var url: URL?

    public init(title: String, byline: String? = nil, siteName: String? = nil,
                text: String, url: URL? = nil) {
        self.title = title; self.byline = byline; self.siteName = siteName
        self.text = text; self.url = url
    }

    public var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Below this, an extraction is far more likely to be a paywall teaser or
    /// a summary card than an article. Not an error — a warning, because the
    /// user may genuinely want to script from three paragraphs, and because
    /// silently scripting from a stub is the worst outcome available: the
    /// result looks completely fine.
    public static let shortArticleWordFloor = 250

    public var looksTruncated: Bool { wordCount < Self.shortArticleWordFloor }
}

public enum ArticleError: Error, LocalizedError, Equatable {
    case unsupportedScheme(String)
    case navigationFailed(String)
    case timedOut(stage: String)
    case notAnArticle
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "“\(scheme)” isn't a web address this can open — use http or https."
        case .navigationFailed(let why): "Couldn't load that page: \(why)"
        case .timedOut(let stage):
            "The page took too long to \(stage). Try again, or paste the text instead."
        case .notAnArticle:
            "That page didn't have an article in it — it may be a homepage, a video, or "
                + "behind a login. Paste the text instead and it'll work."
        case .empty: "That page came back empty."
        }
    }
}

public protocol ArticleReading: Sendable {
    func read(_ url: URL) async throws -> Article
}
