import SwiftUI
import WebKit

/// One help page, from the Markdown files in the bundle (`Help/NN Title.md`).
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let markdown: String

    /// The name that `help:` links use: the title as an anchor, as "ripping-a-disc".
    var slug: String { MarkdownHTML.slug(title) }

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

/// The Help window: topics on the left, the page on the right, with Back and Forward.
struct HelpView: View {
    @State private var topics = HelpTopic.all()
    @State private var selection: String?
    @State private var browser: HelpBrowser?

    var body: some View {
        NavigationSplitView {
            // A page chosen in the list opens at its top, as a new step in the history.
            List(
                topics,
                selection: Binding(
                    get: { selection },
                    set: { id in
                        guard let id, id != selection, let topic = topics.first(where: { $0.id == id }) else { return }
                        selection = id
                        browser?.open(topic.slug)
                    })
            ) { topic in
                Text(topic.title).tag(topic.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            if let browser {
                HelpBrowserView(browser: browser)
                    .navigationTitle(topics.first { $0.id == selection }?.title ?? "Silverside Help")
                    .toolbar {
                        ToolbarItemGroup(placement: .navigation) {
                            Button(action: browser.goBack) { Label("Back", systemImage: "chevron.backward") }
                                .disabled(!browser.canGoBack)
                                .help("Show the place you were before (⌘[)")
                            Button(action: browser.goForward) { Label("Forward", systemImage: "chevron.forward") }
                                .disabled(!browser.canGoForward)
                                .help("Show the place you went back from (⌘])")
                        }
                    }
            } else if topics.isEmpty {
                Text("No help pages are in the app.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            guard browser == nil, let first = topics.first else { return }
            let browser = HelpBrowser(topics: topics)
            // The page on show names the selection in the list, also after Back and links.
            browser.onPage = { slug in selection = topics.first { $0.slug == slug }?.id }
            self.browser = browser
            var slug = first.slug
            var section: String?
            #if DEBUG
                // `-helpTopic ripping-a-disc` (and `-helpSection hdcd`) opens that page, for screenshots.
                if let topic = UserDefaults.standard.string(forKey: "helpTopic") {
                    slug = topic
                    section = UserDefaults.standard.string(forKey: "helpSection")
                }
            #endif
            browser.open(slug, section: section)
        }
    }
}

/// The help pages in a web view, served from the bundle's Markdown under
/// `silverside-help://<page>`, so that WebKit keeps the history: a page, and a section of it
/// (`#hdcd`), is one step back, with the place it was scrolled to. `help:` links in the
/// Markdown (`help:verification#repair`) open another page; other links open in the browser.
/// Back and Forward: the toolbar, ⌘[ and ⌘] (and ⌘← and ⌘→), a mouse's back and forward
/// buttons, and a swipe on the trackpad.
@Observable
final class HelpBrowser: NSObject, WKNavigationDelegate {
    static let scheme = "silverside-help"

    @ObservationIgnored let webView: WKWebView
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Called with the page's name when a page shows.
    @ObservationIgnored var onPage: ((String) -> Void)?
    @ObservationIgnored private var observations = [NSKeyValueObservation]()
    /// Set once in init and read only in deinit, both on the main thread.
    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    init(topics: [HelpTopic]) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(HelpPages(topics: topics), forURLScheme: Self.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = webView.window, event.window === window else { return event }
            return handle(event) ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func open(_ slug: String, section: String? = nil) {
        guard let url = URL(string: "\(Self.scheme)://\(slug)" + (section.map { "#\($0)" } ?? "")) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// The mouse's back and forward buttons (buttons 4 and 5, numbered 3 and 4 from 0), and the
    /// keys, which the main window's Back and Forward in the View menu would take otherwise.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .otherMouseDown {
            switch event.buttonNumber {
            case 3: goBack()
            case 4: goForward()
            default: return false
            }
            return true
        }
        guard
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
                == .command
        else { return false }
        switch event.charactersIgnoringModifiers {
        case "[": goBack()
        case "]": goForward()
        default:
            switch event.keyCode {
            case 123: goBack()
            case 124: goForward()
            default: return false
            }
        }
        return true
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        switch url.scheme {
        case Self.scheme, "about":
            decisionHandler(.allow)
        case "help":
            // help:verification#repair. Such a URL has no path, so `URL.fragment` is nil: split the text.
            decisionHandler(.cancel)
            let parts = url.absoluteString.dropFirst("help:".count).split(separator: "#", maxSplits: 1)
            if let page = parts.first { open(String(page), section: parts.count > 1 ? String(parts[1]) : nil) }
        default:
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let slug = webView.url?.host() { onPage?(slug) }
    }
}

/// Serves `silverside-help://<page>` from the help pages' Markdown, as HTML.
private final class HelpPages: NSObject, WKURLSchemeHandler {
    let topics: [HelpTopic]

    init(topics: [HelpTopic]) { self.topics = topics }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let topic = topics.first(where: { $0.slug == url.host() }) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = Data(MarkdownHTML.page(MarkdownHTML.render(topic.markdown)).utf8)
        task.didReceive(
            URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

private struct HelpBrowserView: NSViewRepresentable {
    let browser: HelpBrowser

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Shows an HTML page, such as a rip's report. Links open in the browser.
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
/// Each heading gets an anchor (`slug`), so `[HDCD](#hdcd)` links to a section, and a line
/// `<!-- toc -->` becomes a list of the page's sections (its `##` headings).
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
        let anchors = headings(markdown)
        var headingIndex = 0

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
            // A details block in the rip report passes through as HTML.
            if line.hasPrefix("<details") || line.hasPrefix("</details") {
                endParagraph()
                endList()
                endTable()
                html.append(line)
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
                let id = headingIndex < anchors.count ? anchors[headingIndex].id : slug(line)
                headingIndex += 1
                html.append("<h\(level) id=\"\(id)\">\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
                continue
            }
            if line == "<!-- toc -->" {
                endParagraph()
                endList()
                let items = anchors.filter { $0.level == 2 }.map {
                    "<li><a href=\"#\($0.id)\">\(inline($0.text))</a></li>"
                }
                if !items.isEmpty { html.append("<nav class=\"toc\"><ul>" + items.joined() + "</ul></nav>") }
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

    /// Every heading outside code, with its anchor; a second heading of the same name gets "-2".
    private static func headings(_ markdown: String) -> [(level: Int, text: String, id: String)] {
        var result = [(level: Int, text: String, id: String)]()
        var used = [String: Int]()
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle() }
            guard !inCode, let level = heading(line) else { continue }
            let base = slug(line)
            let count = (used[base] ?? 0) + 1
            used[base] = count
            result.append((level, String(line.dropFirst(level + 1)), count == 1 ? base : "\(base)-\(count)"))
        }
        return result
    }

    /// A heading or title as an anchor, as GitHub makes them: lowercase letters, digits, and
    /// hyphens, with spaces as hyphens ("## Pre-emphasis and other flags" is
    /// "pre-emphasis-and-other-flags").
    static func slug(_ text: String) -> String {
        let words = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        return String(
            words.compactMap { character -> Character? in
                if character == " " { return "-" }
                return character.isLetter || character.isNumber || character == "-" ? character : nil
            })
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
    static func page(_ body: String, compact: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { font: \(compact ? "12.5px/1.45" : "14px/1.5") -apple-system, system-ui, sans-serif; color: CanvasText;
               background: transparent; margin: 0; padding: \(compact ? "12px 16px 24px" : "22px 32px 40px");
               max-width: 760px; }
        details { margin: 2px 0 8px; } summary { cursor: pointer; color: color-mix(in srgb, CanvasText 60%, transparent); }
        \(compact ? "table { display: block; overflow-x: auto; width: max-content; max-width: 100%; } th, td { white-space: nowrap; }" : "")
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
        nav.toc { margin: 0 0 18px; padding: 10px 14px; border-radius: 8px;
                  background: color-mix(in srgb, CanvasText 5%, transparent); }
        nav.toc ul { list-style: none; padding: 0; margin: 0; columns: 2; column-gap: 28px; }
        nav.toc li { margin: 0; padding: 0 0 4px; break-inside: avoid; }
        nav.toc a { text-decoration: none; }
        nav.toc a:hover { text-decoration: underline; }
        </style></head><body>\(body)</body></html>
        """
    }
}
