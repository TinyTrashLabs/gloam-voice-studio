import Foundation
import WebKit

/// Reads an article by rendering the page in an offscreen `WKWebView` and
/// running Mozilla's Readability over the resulting DOM.
///
/// Rendering rather than a plain HTTP GET is the entire reason this class
/// exists. A GET returns an empty shell on any client-rendered site, which is
/// a large share of modern news, and it fails *silently* — you get a valid
/// HTML document with no article in it. The web view pays a second or two to
/// be right instead.
///
/// Everything stays on this machine: WKWebView sandboxes its own content
/// process, Readability is vendored (see Resources/README-Readability.md)
/// rather than fetched, and the only request that leaves is the article's own.
@MainActor
public final class ReadabilityArticleReader: ArticleReading {
    /// How long the page gets to load, and then how long extraction gets.
    /// Separate because they fail for different reasons and the message should
    /// say which.
    public var navigationTimeout: Double = 15
    public var extractionTimeout: Double = 10

    private var webView: WKWebView?
    private var loader: PageLoader?

    public init() {}

    public func read(_ url: URL) async throws -> Article {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ArticleError.unsupportedScheme(url.scheme ?? "(none)")
        }

        let configuration = WKWebViewConfiguration()
        // Nothing here should ever play; a page that starts a video while
        // being read for text is pure surprise.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768),
                             configuration: configuration)
        view.customUserAgent = DuckDuckGoSearch.userAgent
        let pageLoader = PageLoader()
        view.navigationDelegate = pageLoader
        // Held for the duration: a released web view cancels its load, and a
        // released delegate stops the callbacks that end the await.
        webView = view
        loader = pageLoader
        defer { webView = nil; loader = nil }

        try await pageLoader.load(url, in: view, timeout: navigationTimeout)
        let extracted = try await extract(from: view)
        guard !extracted.text.isEmpty else { throw ArticleError.notAnArticle }
        return Article(title: extracted.title.isEmpty ? url.host() ?? "Untitled"
                                                      : extracted.title,
                       byline: extracted.byline.isEmpty ? nil : extracted.byline,
                       siteName: extracted.siteName.isEmpty ? nil : extracted.siteName,
                       text: HTMLText.collapsingWhitespace(extracted.text),
                       url: url)
    }

    // MARK: - Extraction

    private struct Extracted: Sendable {
        var title = ""
        var byline = ""
        var siteName = ""
        var text = ""
    }

    private func extract(from view: WKWebView) async throws -> Extracted {
        let script = try Self.extractionScript()
        let gate = ResumeOnce<Extracted>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
            Task { @MainActor in
                do {
                    let raw = try await view.callAsyncJavaScript(
                        script, arguments: [:], contentWorld: .defaultClient)
                    guard let dictionary = raw as? [String: Any] else {
                        gate.fail(ArticleError.notAnArticle); return
                    }
                    if let jsError = dictionary["error"] as? String {
                        gate.fail(ArticleError.navigationFailed(jsError)); return
                    }
                    gate.finish(Extracted(
                        title: dictionary["title"] as? String ?? "",
                        byline: dictionary["byline"] as? String ?? "",
                        siteName: dictionary["siteName"] as? String ?? "",
                        text: dictionary["text"] as? String ?? ""))
                } catch {
                    gate.fail(ArticleError.navigationFailed(error.localizedDescription))
                }
            }
            Task { @MainActor [extractionTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(extractionTimeout * 1_000_000_000))
                gate.fail(ArticleError.timedOut(stage: "read"))
            }
        }
    }

    /// Readability plus the few lines that call it. Concatenated rather than
    /// injected as a user script so a failure to find the resource is a thrown
    /// Swift error at a known point, not a silent `ReferenceError` later.
    static func extractionScript() throws -> String {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let library = try? String(contentsOf: url, encoding: .utf8)
        else { throw ArticleError.navigationFailed("Readability.js is missing from the bundle") }
        return library + """

        try {
          // Readability mutates the document it is handed, so it gets a copy.
          const parsed = new Readability(document.cloneNode(true)).parse();
          if (!parsed) { return { title: "", byline: "", siteName: "", text: "" }; }
          return {
            title: parsed.title || "",
            byline: parsed.byline || "",
            siteName: parsed.siteName || "",
            text: parsed.textContent || "",
          };
        } catch (e) {
          return { error: String(e) };
        }
        """
    }
}

/// A continuation that can be resumed from more than one place — the work and
/// its timeout — and only ever fires once.
@MainActor
private final class ResumeOnce<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Turns `WKNavigationDelegate`'s callbacks into one awaitable load.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private let gate = ResumeOnce<Bool>()
    private var timeout: Task<Void, Never>?

    func load(_ url: URL, in view: WKWebView, timeout seconds: Double) async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            gate.attach(continuation)
            timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                view.stopLoading()
                gate.fail(ArticleError.timedOut(stage: "load"))
            }
            view.load(URLRequest(url: url, timeoutInterval: seconds))
        }
    }

    private func settle(_ result: Result<Bool, Error>) {
        timeout?.cancel()
        switch result {
        case .success(let value): gate.finish(value)
        case .failure(let error): gate.fail(error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(true))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(.failure(ArticleError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        settle(.failure(ArticleError.navigationFailed(error.localizedDescription)))
    }
}
