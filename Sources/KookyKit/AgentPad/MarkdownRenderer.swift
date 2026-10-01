import Foundation

/// Small CommonMark-ish Markdown → HTML for the preview pane: headings,
/// paragraphs, emphasis, inline code, fenced code, lists (nested by indent),
/// task lists, blockquotes, tables, links, images, rules. Everything is
/// HTML-escaped first; raw HTML in the source is shown, not executed.
enum MarkdownRenderer {
    /// Deeper blockquote nesting renders as plain text: each level recurses,
    /// and a hostile file shouldn't get to pick the stack depth.
    static let maxQuoteDepth = 12

    static func html(_ markdown: String, depth: Int = 0) -> String {
        var out: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listStack: [(ordered: Bool, indent: Int)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(inline(paragraph.joined(separator: "\n")))</p>")
            paragraph = []
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth {
                out.append(listStack.removeLast().ordered ? "</li></ol>" : "</li></ul>")
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); closeLists()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); closeLists()
                i += 1
                continue
            }
            // Heading.
            if let level = headingLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
                continue
            }
            // Rule.
            if isRule(trimmed) {
                flushParagraph(); closeLists()
                out.append("<hr>")
                i += 1
                continue
            }
            // Blockquote: gather the run and render it recursively.
            if trimmed.hasPrefix(">"), depth < maxQuoteDepth {
                flushParagraph(); closeLists()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quoted.append(String(q)); i += 1
                }
                out.append("<blockquote>\(html(quoted.joined(separator: "\n"), depth: depth + 1))</blockquote>")
                continue
            }
            // Table: header row, then a |---| separator.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph(); closeLists()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                var table = "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows {
                    table += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }
                out.append(table + "</tbody></table>")
                continue
            }
            // List item.
            if let item = listItem(line) {
                flushParagraph()
                if let top = listStack.last, item.indent > top.indent {
                    out.append(item.ordered ? "<ol>" : "<ul>")
                    listStack.append((item.ordered, item.indent))
                } else {
                    while let top = listStack.last, item.indent < top.indent { closeLists(to: listStack.count - 1) }
                    if let top = listStack.last, top.ordered == item.ordered {
                        out.append("</li>")
                    } else {
                        if !listStack.isEmpty { closeLists(to: listStack.count - 1) }
                        out.append(item.ordered ? "<ol>" : "<ul>")
                        listStack.append((item.ordered, item.indent))
                    }
                }
                var body = item.text
                var checkbox = ""
                if body.hasPrefix("[ ] ") { checkbox = "<input type=\"checkbox\" disabled> "; body.removeFirst(4) }
                else if body.lowercased().hasPrefix("[x] ") { checkbox = "<input type=\"checkbox\" checked disabled> "; body.removeFirst(4) }
                out.append("<li>\(checkbox)\(inline(body))")
                i += 1
                continue
            }
            // A line indented under a list item continues it.
            if !listStack.isEmpty, line.hasPrefix("  ") {
                out.append("<br>\(inline(trimmed))")
                i += 1
                continue
            }
            closeLists()
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph(); closeLists()
        return out.joined(separator: "\n")
    }

    // MARK: Blocks

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, indent: Int, text: String)? {
        let indent = line.prefix { $0 == " " }.count + line.prefix { $0 == "\t" }.count * 4
        let t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) {
            return (false, indent, String(t.dropFirst(2)))
        }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, indent, String(rest.dropFirst(2))) }
        }
        return nil
    }

    // MARK: Inline

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline spans. Code spans are cut out first so nothing inside them is
    /// interpreted; then images, links, bold, italic, strikethrough.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var source = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            source += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "`") {
                codes.append(String(rest[afterOpen..<close]))
                source += "\u{0}\(codes.count - 1)\u{0}"
                rest = rest[rest.index(after: close)...]
            } else {
                source += rest[open...]
                rest = ""
            }
        }
        source += rest
        var html = escape(source)
        html = replace(html, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#) { m in
            "<img alt=\"\(m[1])\" src=\"\(safeURL(m[2]))\">"
        }
        html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#) { m in
            "<a href=\"\(safeURL(m[2]))\">\(m[1])</a>"
        }
        html = replace(html, #"(?<![\w"=/])(https?://[^\s<]+[^\s<.,;:!?)])"#) { m in
            "<a href=\"\(m[1])\">\(m[1])</a>"
        }
        html = replace(html, #"\*\*(.+?)\*\*|__(.+?)__"#) { m in "<strong>\(m[1].isEmpty ? m[2] : m[1])</strong>" }
        html = replace(html, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#) { m in
            "<em>\(m[1].isEmpty ? m[2] : m[1])</em>"
        }
        html = replace(html, #"~~(.+?)~~"#) { m in "<del>\(m[1])</del>" }
        html = html.replacingOccurrences(of: "\n", with: " ")
        for (index, code) in codes.enumerated() {
            html = html.replacingOccurrences(of: "\u{0}\(index)\u{0}", with: "<code>\(escape(code))</code>")
        }
        return html
    }

    /// `javascript:` and friends are dropped; relative paths stay relative to
    /// the document (the web view is given read access to its folder).
    private static func safeURL(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:text") || lower.hasPrefix("vbscript:") { return "#" }
        // WebKit refuses file: navigation from our page before any delegate
        // sees it; route absolute local links through our own scheme instead.
        if lower.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
            var components = URLComponents()
            components.scheme = "agentpad-doc"
            components.host = "local"
            components.path = url.path
            components.fragment = url.fragment
            return components.url?.absoluteString ?? "#"
        }
        return raw
    }


    private static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { idx -> String in
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = NSMaxRange(match.range)
        }
        result += ns.substring(from: last)
        return result
    }

    static func page(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src agentpad-doc: https: data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; margin: 18px 24px 40px; max-width: 860px; color: CanvasText; background: transparent; }
        h1, h2 { border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); padding-bottom: .25em; }
        h1 { font-size: 1.7em; } h2 { font-size: 1.35em; } h3 { font-size: 1.12em; }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); padding: .1em .35em; border-radius: 4px; }
        pre { background: color-mix(in srgb, CanvasText 6%, transparent); padding: 10px 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding: 0 1em; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); color: color-mix(in srgb, CanvasText 75%, transparent); }
        table { border-collapse: collapse; } th, td { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 4px 10px; }
        img { max-width: 100%; } a { color: LinkText; } hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 18%, transparent); }
        li > input { margin-right: .4em; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}
