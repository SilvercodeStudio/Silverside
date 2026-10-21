import SwiftUI
import WebKit

/// One help page, from the Markdown files in the bundle (`Help/NN Title.md`).
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let markdown: String

    static func all() -> [HelpTopic] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        return
            urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let fromName = url.deletingPathExtension().lastPathComponent.drop { $0.isNumber || $0 == " " }
                return HelpTopic(
                    id: url.lastPathComponent, title: MarkdownHTML.title(of: markdown) ?? String(fromName),
                    markdown: markdown)
            }
    }
}

/// The Help window: topics on the left, the page on the right.
struct HelpView: View {
    @State private var topics = HelpTopic.all()
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(topics, selection: $selection) { topic in
                Text(topic.title).tag(topic.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            if let topic = topics.first(where: { $0.id == selection }) ?? topics.first {
                HelpWebView(html: MarkdownHTML.page(MarkdownHTML.render(topic.markdown)))
                    .navigationTitle(topic.title)
            } else {
                Text("No help pages are in the app.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { if selection == nil { selection = topics.first?.id } }
    }
}

/// Shows an HTML page. Links open in the browser.
struct HelpWebView: NSViewRepresentable {
    var html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// A small Markdown to HTML converter for the help pages: headings, paragraphs, bullet and
/// numbered lists, pipe tables, fenced code, and inline code, bold, italics, and links.
nonisolated enum MarkdownHTML {
    /// The first level-one heading.
    static func title(of markdown: String) -> String? {
        for line in markdown.split(separator: "\n") where line.hasPrefix("# ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func render(_ markdown: String) -> String {
        var html = [String]()
        var paragraph = [String]()
        var list: String?
        var table = [String]()
        var inCode = false

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph = []
        }
        func endList() {
            if let list { html.append("</\(list)>") }
            list = nil
        }
        func endTable() {
            guard !table.isEmpty else { return }
            let rows = table.map(cells)
            if rows.count >= 2, rows[1].allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) {
                html.append(
                    "<table><thead><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>")
                for row in rows.dropFirst(2) {
                    html.append("<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>")
                }
                html.append("</tbody></table>")
            } else {
                html.append("<p>\(inline(table.joined(separator: " ")))</p>")
            }
            table = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                endParagraph()
                endList()
                endTable()
                html.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode {
                html.append(escape(raw))
                continue
            }
            if line.hasPrefix("|") {
                endParagraph()
                endList()
                table.append(line)
                continue
            }
            endTable()
            if line.isEmpty {
                endParagraph()
                endList()
                continue
            }
            if let level = heading(line) {
                endParagraph()
                endList()
                html.append("<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                endParagraph()
                if list != "ul" {
                    endList()
                    list = "ul"
                    html.append("<ul>")
                }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>")
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                line[line.index(after: dot)...].hasPrefix(" ")
            {
                endParagraph()
                if list != "ol" {
                    endList()
                    list = "ol"
                    html.append("<ol>")
                }
                html.append("<li>\(inline(String(line[line.index(dot, offsetBy: 2)...])))</li>")
                continue
            }
            paragraph.append(line)
        }
        endParagraph()
        endList()
        endTable()
        return html.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 4, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func cells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Inline code, links, bold, and italics. Code is escaped and left alone.
    static func inline(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let tick = rest.firstIndex(of: "`") {
            out += styled(String(rest[..<tick]))
            let after = rest.index(after: tick)
            guard let close = rest[after...].firstIndex(of: "`") else {
                out += "`"
                rest = rest[after...]
                continue
            }
            out += "<code>\(escape(String(rest[after..<close])))</code>"
            rest = rest[rest.index(after: close)...]
        }
        return out + styled(String(rest))
    }

    private static func styled(_ text: String) -> String {
        var html = escape(text)
        html = replace(html, pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>")
        html = replace(html, pattern: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>")
        html = replace(html, pattern: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, with: "<em>$1</em>")
        return html
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A page in the system font, light or dark with the system.
    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.5 -apple-system, system-ui, sans-serif; color: CanvasText; background: transparent;
               margin: 0; padding: 22px 32px 40px; max-width: 760px; }
        h1 { font-size: 24px; font-weight: 700; margin: 0 0 14px; letter-spacing: -0.01em; }
        h2 { font-size: 17px; font-weight: 600; margin: 26px 0 8px; }
        h3 { font-size: 15px; font-weight: 600; margin: 18px 0 6px; }
        p, li { margin: 0 0 8px; }
        ul, ol { padding-left: 22px; margin: 0 0 10px; }
        code { font: 12.5px ui-monospace, Menlo, monospace; background: color-mix(in srgb, CanvasText 9%, transparent);
               padding: 1px 5px; border-radius: 4px; }
        pre { background: color-mix(in srgb, CanvasText 7%, transparent); padding: 10px 12px; border-radius: 6px;
              overflow-x: auto; }
        pre code { background: none; padding: 0; }
        table { border-collapse: collapse; margin: 6px 0 14px; width: 100%; }
        th, td { text-align: left; vertical-align: top; padding: 6px 10px;
                 border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); }
        th { font-weight: 600; }
        a { color: LinkText; }
        </style></head><body>\(body)</body></html>
        """
    }
}
