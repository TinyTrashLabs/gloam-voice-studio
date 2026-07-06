import SwiftUI
import WebKit

/// In-app documentation: the markdown pages from docs/ ship in the bundle and
/// render offline in a WKWebView (Help → Gloam Documentation, or ⌘?).
struct DocsWindow: View {
    enum Page: String, CaseIterable, Identifiable {
        case guide = "App Guide"
        case api = "HTTP API"
        case mcp = "MCP Server"
        var id: String { rawValue }

        var resource: String {
            switch self {
            case .guide: "app-guide"
            case .api: "api"
            case .mcp: "mcp"
            }
        }
    }

    @State private var page: Page = .guide

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Text(page.rawValue).tag(page)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            MarkdownWebView(markdown: Self.load(page))
                .id(page)   // rebuild on page switch, no half-rendered state
        }
        .navigationTitle("Documentation")
        .frame(minWidth: 700, minHeight: 500)
    }

    static func load(_ page: Page) -> String {
        guard let url = Bundle.main.url(forResource: page.resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "# Documentation missing\n\nThe bundled page could not be "
                + "loaded — see https://github.com/TinyTrashLabs/gloam-voice-studio/tree/main/docs"
        }
        return text
    }
}

/// WKWebView wrapper rendering markdown via MarkdownLite (offline, no assets).
private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")   // let the CSS own it
        view.loadHTMLString(MarkdownLite.html(from: markdown), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The subset of markdown our docs use — headers, bold/italic/code, links,
/// bullet lists, tables, fenced code — converted to styled HTML. Not a general
/// markdown engine; it just has to render docs/*.md faithfully.
enum MarkdownLite {
    static func html(from markdown: String) -> String {
        var body: [String] = []
        var inCode = false
        var inList = false
        var tableRows: [String] = []

        func closeList() {
            if inList { body.append("</ul>"); inList = false }
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            body.append("<table>" + tableRows.joined() + "</table>")
            tableRows.removeAll()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                closeList(); flushTable()
                body.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode {
                body.append(escape(rawLine))
                continue
            }
            if line.hasPrefix("|") {
                closeList()
                // Skip |---| separator rows.
                if line.replacingOccurrences(of: "|", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -:")).isEmpty {
                    continue
                }
                let tag = tableRows.isEmpty ? "th" : "td"
                let cells = line.split(separator: "|").map {
                    "<\(tag)>\(inline(String($0).trimmingCharacters(in: .whitespaces)))</\(tag)>"
                }
                tableRows.append("<tr>" + cells.joined() + "</tr>")
                continue
            }
            flushTable()
            if line.hasPrefix("- ") {
                if !inList { body.append("<ul>"); inList = true }
                body.append("<li>\(inline(String(line.dropFirst(2))))</li>")
                continue
            }
            closeList()
            if let level = [3, 2, 1].first(where: { line.hasPrefix(String(repeating: "#", count: $0) + " ") }) {
                body.append("<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
            } else if !line.isEmpty {
                body.append("<p>\(inline(line))</p>")
            }
        }
        closeList(); flushTable()
        if inCode { body.append("</code></pre>") }
        return "<!doctype html><meta charset='utf-8'><style>\(css)</style><body>"
            + body.joined(separator: "\n") + "</body>"
    }

    /// Inline spans: escape first, then code / bold / links (code before bold
    /// so `**` inside backticks survives).
    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = regex(s, #"`([^`]+)`"#, "<code>$1</code>")
        s = regex(s, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        s = regex(s, #"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")
        return s
    }

    private static func regex(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template,
                               options: .regularExpression)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let css = """
    body { font: 13px -apple-system, sans-serif; background: #101418; color: #d8dee6;
           max-width: 720px; margin: 0 auto; padding: 24px 28px 48px; line-height: 1.55; }
    h1 { font-size: 21px; } h2 { font-size: 16px; margin-top: 28px; } h3 { font-size: 14px; }
    h1, h2, h3 { color: #f2f5f8; }
    a { color: #6db3f2; text-decoration: none; } a:hover { text-decoration: underline; }
    code { font: 12px ui-monospace, monospace; background: rgba(255,255,255,.07);
           padding: 1px 4px; border-radius: 4px; }
    pre { background: rgba(255,255,255,.05); border: 1px solid rgba(255,255,255,.08);
          border-radius: 8px; padding: 10px 12px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; margin: 10px 0; }
    th, td { border: 1px solid rgba(255,255,255,.12); padding: 5px 10px; text-align: left; }
    th { background: rgba(255,255,255,.05); }
    ul { padding-left: 22px; }
    """
}
