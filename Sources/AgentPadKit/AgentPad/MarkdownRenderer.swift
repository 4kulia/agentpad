import Foundation

/// Small CommonMark-ish Markdown → HTML for the preview pane: headings,
/// paragraphs, emphasis, inline code, fenced code, lists (nested by indent),
/// task lists, blockquotes, tables, links, images, rules. Everything is
/// HTML-escaped first; raw HTML in the source is shown, not executed.
///
/// `.chat` is for text from other people and agents (DESIGN-F7): no images
/// or other resources, links only to http(s)/mailto after `chatLink`, a
/// closed set of tags, and time and output linear in the input.
enum MarkdownRenderer {
    enum Mode { case document, chat }

    /// Deeper blockquote nesting renders as plain text: each level recurses,
    /// and a hostile file shouldn't get to pick the stack depth.
    static let maxQuoteDepth = 12
    /// Chat: list nesting stops here; deeper items continue the current one.
    static let maxListDepth = 12
    /// Chat: longer text is shown without formatting.
    static let chatMarkdownLimit = 128 * 1024
    /// Chat: output beyond `factor × input + slack` bytes falls back to plain text.
    static let chatOutputFactor = 10, chatOutputSlack = 4096
    static let chatMaxColumns = 64
    static let chatMaxLinkLength = 2048

    static func html(_ markdown: String, mode: Mode = .document, depth: Int = 0) -> String {
        if mode == .chat { return chatHTML(markdown) }
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

    // MARK: Chat blocks

    /// Chat text is parsed as Unicode scalars from end to end: `Character`
    /// comparisons normalize, and a long run of combining marks made the
    /// block parser superlinear (review F7-1). Markers are ASCII anyway.
    private typealias Line = ArraySlice<Unicode.Scalar>

    private static func chatHTML(_ markdown: String) -> String {
        let size = markdown.utf8.count
        let scalars = Array(markdown.unicodeScalars)
        guard size <= chatMarkdownLimit else { return plainChat(scalars, long: true) }
        let out = html(chatBlocks(scalars[...], depth: 0))
        return out.utf8.count > chatOutputFactor * size + chatOutputSlack ? plainChat(scalars, long: false) : out
    }

    /// The chat parse as a tree (F3 shows it natively; `html` is F7's page).
    /// Nil: longer than `chatMarkdownLimit`, shown without formatting.
    static func chatDocument(_ markdown: String) -> [ChatBlock]? {
        guard markdown.utf8.count <= chatMarkdownLimit else { return nil }
        return chatBlocks(Array(markdown.unicodeScalars)[...], depth: 0)
    }

    static func html(_ blocks: [ChatBlock]) -> String { blocks.map(html).joined(separator: "\n") }

    private static func html(_ block: ChatBlock) -> String {
        switch block {
        case .paragraph(let inline): return "<p>\(html(inline))</p>"
        case .heading(let level, let inline): return "<h\(level)>\(html(inline))</h\(level)>"
        case .code(let lang, let text):
            let cls = lang.map { " class=\"language-\($0)\"" } ?? ""
            return "<pre><code\(cls)>\(chatEscape(text[...]))</code></pre>"
        case .rule: return "<hr>"
        case .quote(let inner): return "<blockquote>\(html(inner))</blockquote>"
        case .table(let header, let rows):
            var table = "<table><thead><tr>" + header.map { "<th>\(html($0))</th>" }.joined() + "</tr></thead><tbody>"
            for row in rows { table += "<tr>" + row.map { "<td>\(html($0))</td>" }.joined() + "</tr>" }
            return table + "</tbody></table>"
        case .listOpen(let ordered): return ordered ? "<ol>" : "<ul>"
        case .listClose(let ordered): return ordered ? "</li></ol>" : "</li></ul>"
        case .itemNext: return "</li>"
        case .item(let checked, let inline): return "<li>\(checked.map { $0 ? "\u{2611} " : "\u{2610} " } ?? "")\(html(inline))"
        case .continuation(let inline): return "<br>\(html(inline))"
        }
    }

    static func html(_ inline: [ChatInline]) -> String {
        var out = ""
        for node in inline {
            switch node {
            case .text(let s), .literal(let s): out += chatEscape(s[...])
            case .lineBreak: out += "<br>"
            case .code(let s): out += "<code>\(chatEscape(s[...]))</code>"
            case .link(let url, let children):
                let href = escape(url.absoluteString)
                out += "<a href=\"\(href)\" title=\"\(href)\">\(html(children))</a>"
            case .strong(let c): out += "<strong>\(html(c))</strong>"
            case .em(let c): out += "<em>\(html(c))</em>"
            case .del(let c): out += "<del>\(html(c))</del>"
            }
        }
        return out
    }

    private static func chatLines(_ text: Line) -> [Line] {
        var lines: [Line] = []
        var start = text.startIndex
        for i in text.indices where text[i] == "\n" {
            let end = i > start && text[i - 1] == "\r" ? i - 1 : i
            lines.append(text[start..<end])
            start = i + 1
        }
        lines.append(text[start..<text.endIndex])
        return lines
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { CharacterSet.whitespaces.contains(c) }

    private static func trim(_ line: Line) -> Line {
        var lo = line.startIndex, hi = line.endIndex
        while lo < hi, isSpace(line[lo]) { lo += 1 }
        while hi > lo, isSpace(line[hi - 1]) { hi -= 1 }
        return line[lo..<hi]
    }

    private static func starts(_ line: Line, _ prefix: String) -> Bool {
        var i = line.startIndex
        for p in prefix.unicodeScalars {
            guard i < line.endIndex, line[i] == p else { return false }
            i += 1
        }
        return true
    }

    private static func chatBlocks(_ text: Line, depth: Int, listDepth: Int = 0) -> [ChatBlock] {
        var out: [ChatBlock] = []
        let lines = chatLines(text)
        var i = 0
        var paragraph: [Line] = []

        func joined(_ parts: [Line]) -> [Unicode.Scalar] {
            var all: [Unicode.Scalar] = []
            for (n, part) in parts.enumerated() {
                if n > 0 { all.append("\n") }
                all.append(contentsOf: part)
            }
            return all
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(chatInlineNodes(joined(paragraph))))
            paragraph = []
        }
        func fencedCode(_ opening: Line, indent: Int = 0) -> ChatBlock {
            let marker = opening.first!
            let length = opening.prefix { $0 == marker }.count
            let lang = trim(opening.dropFirst(length))
            var code: [Line] = []
            i += 1
            while i < lines.count {
                let closing = trim(lines[i])
                let count = closing.prefix { $0 == marker }.count
                if count >= length, trim(closing.dropFirst(count)).isEmpty { break }
                let padding = min(indent, lines[i].prefix { $0 == " " }.count)
                code.append(lines[i].dropFirst(padding)); i += 1
            }
            i += 1
            return .code(lang: isChatLanguage(lang) ? String(String.UnicodeScalarView(lang)) : nil, joined(code))
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = trim(line)

            if starts(trimmed, "```") || starts(trimmed, "~~~") {
                flushParagraph()
                out.append(fencedCode(trimmed))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if paragraph.isEmpty, starts(line, "    ") || starts(line, "\t") {
                var code: [Line] = []
                while i < lines.count {
                    let next = lines[i]
                    if starts(next, "    ") { code.append(next.dropFirst(4)) }
                    else if starts(next, "\t") { code.append(next.dropFirst()) }
                    else { break }
                    i += 1
                }
                out.append(.code(lang: nil, joined(code)))
                continue
            }
            if let level = chatHeadingLevel(trimmed) {
                flushParagraph()
                var text = trimmed.dropFirst(level)
                while let c = text.first, c == " " || c == "#" { text = text.dropFirst() }
                while let c = text.last, c == " " || c == "#" { text = text.dropLast() }
                out.append(.heading(level, chatInlineNodes(Array(text))))
                i += 1
                continue
            }
            if isChatRule(trimmed) {
                flushParagraph()
                out.append(.rule)
                i += 1
                continue
            }
            if starts(trimmed, ">"), depth < maxQuoteDepth {
                flushParagraph()
                var quoted: [Line] = []
                var lazyParagraph = false
                while i < lines.count {
                    let next = trim(lines[i])
                    if starts(next, ">") {
                        var q = next.dropFirst()
                        if q.first == " " { q = q.dropFirst() }
                        quoted.append(q)
                        // A list item or nested quote can end in a paragraph
                        // whose next line omits the outer quote marker too.
                        var content = trim(q)
                        while !content.isEmpty {
                            if starts(content, ">") { content = trim(content.dropFirst()) }
                            else if let item = chatListItem(content) { content = trim(item.text) }
                            else { break }
                        }
                        lazyParagraph = !content.isEmpty && !chatInterruptsParagraph(content)
                    } else if lazyParagraph, !next.isEmpty, !chatInterruptsParagraph(next) {
                        quoted.append(lines[i])
                    } else { break }
                    i += 1
                }
                out.append(.quote(chatBlocks(joined(quoted)[...], depth: depth + 1, listDepth: listDepth)))
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isChatTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = chatCells(trimmed)
                var rows: [[Line]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !trim(lines[i]).isEmpty {
                    rows.append(chatCells(lines[i])); i += 1
                }
                out.append(.table(header: header.map { chatInlineNodes(Array($0)) }, rows: rows.map { $0.map { chatInlineNodes(Array($0)) } }))
                continue
            }
            if let first = chatListItem(line) {
                flushParagraph()
                // At the bound, keep unsupported containers as data; they
                // must not turn hidden code or quotes into executable mentions.
                guard listDepth < maxListDepth else {
                    out.append(.code(lang: nil, joined(Array(lines[i...]))))
                    break
                }
                out.append(.listOpen(ordered: first.ordered))
                var firstItem = true
                while i < lines.count, let item = chatListItem(lines[i]),
                      item.indent == first.indent, item.ordered == first.ordered {
                    if !firstItem { out.append(.itemNext) }
                    firstItem = false
                    let contentIndent = item.text.startIndex - lines[i].startIndex
                    var body = item.text
                    var checkbox: Bool?
                    if starts(body, "[ ] ") { checkbox = false; body = body.dropFirst(4) }
                    else if starts(body, "[x] ") || starts(body, "[X] ") { checkbox = true; body = body.dropFirst(4) }
                    var contents = [body]
                    var afterBlank = false
                    i += 1
                    while i < lines.count {
                        let next = lines[i], t = trim(next)
                        if let sibling = chatListItem(next), sibling.indent <= first.indent { break }
                        let padding = next.prefix { $0 == " " }.count
                        if t.isEmpty {
                            contents.append(t); afterBlank = true; i += 1; continue
                        }
                        if padding >= contentIndent {
                            contents.append(next.dropFirst(contentIndent))
                        } else if !afterBlank, !chatInterruptsParagraph(t) {
                            // Lazy paragraph continuation, including a code
                            // span spanning several physical lines.
                            contents.append(t)
                        } else { break }
                        afterBlank = false
                        i += 1
                    }
                    var children = chatBlocks(joined(contents)[...], depth: depth, listDepth: listDepth + 1)
                    if case .paragraph(let inline)? = children.first {
                        out.append(.item(checked: checkbox, inline)); children.removeFirst()
                    } else { out.append(.item(checked: checkbox, [])) }
                    out.append(contentsOf: children)
                }
                out.append(.listClose(ordered: first.ordered))
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return out
    }

    private static func chatHeadingLevel(_ line: Line) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func chatInterruptsParagraph(_ line: Line) -> Bool {
        starts(line, ">") || starts(line, "```") || starts(line, "~~~")
            || chatHeadingLevel(line) != nil || isChatRule(line) || chatListItem(line) != nil
    }

    private static func isChatRule(_ line: Line) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isChatTableSeparator(_ line: Line) -> Bool {
        let t = trim(line)
        guard t.contains("-"), t.contains("|") || t.first == "-" else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Cells past `chatMaxColumns` stay text in the last one.
    private static func chatCells(_ line: Line) -> [Line] {
        var t = trim(line)
        if t.first == "|" { t = t.dropFirst() }
        if t.last == "|" { t = t.dropLast() }
        var cells: [Line] = []
        var start = t.startIndex
        for k in t.indices where t[k] == "|" {
            if cells.count == chatMaxColumns - 1 { break }
            cells.append(trim(t[start..<k])); start = k + 1
        }
        cells.append(trim(t[start..<t.endIndex]))
        return cells
    }

    private static func chatListItem(_ line: Line) -> (ordered: Bool, indent: Int, text: Line)? {
        let indent = line.prefix { $0 == " " }.count + line.prefix { $0 == "\t" }.count * 4
        let t = trim(line)
        for marker in ["- ", "* ", "+ "] where starts(t, marker) {
            return (false, indent, t.dropFirst(2))
        }
        let digits = t.prefix { $0.isASCII && $0.properties.numericType == .decimal }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = t.dropFirst(digits.count)
            if starts(rest, ". ") || starts(rest, ") ") { return (true, indent, rest.dropFirst(2)) }
        }
        return nil
    }

    private static func isChatLanguage(_ lang: Line) -> Bool {
        (1...32).contains(lang.count)
            && lang.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_+#.-".unicodeScalars.contains($0)) }
    }

    /// Escaped for text and attributes; NUL is shown as U+FFFD only here, on
    /// the way out, so a link target is checked as written (review F7-3).
    private static func chatEscape(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\u{0}": out += "\u{FFFD}"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// Chat text too long (or rendering too large) for Markdown: escaped, line by line.
    private static func plainChat(_ text: [Unicode.Scalar], long: Bool) -> String {
        let body = chatLines(text[...]).map { chatEscape($0) }.joined(separator: "<br>\n")
        return (long ? "<p><em>Long text: shown without formatting.</em></p>\n" : "") + "<p>\(body)</p>"
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

    /// Chat inline spans in one pass over the source: code, images (kept as
    /// text), links and autolinks become pieces first, so emphasis only ever
    /// sees text and never an attribute. Every lookup is a precomputed "next
    /// occurrence", which keeps hostile input linear.
    static func chatInline(_ text: String) -> String { html(chatInlineNodes(Array(text.unicodeScalars))) }

    static func chatInlineNodes(_ s: [Unicode.Scalar]) -> [ChatInline] {
        let n = s.count
        func nextTable(_ hit: (Int) -> Bool) -> [Int] {
            var table = [Int](repeating: n, count: n + 1)
            var i = n - 1
            while i >= 0 { table[i] = hit(i) ? i : table[i + 1]; i -= 1 }
            return table
        }
        // Pair whole delimiter runs of equal length in linear time. A shorter
        // run inside code is content, never the end of that code span.
        var tickLengths: [Int: Int] = [:], tickCloses: [Int: Int] = [:], lastTick: [Int: Int] = [:]
        var tick = n - 1
        while tick >= 0 {
            if s[tick] != "`" { tick -= 1; continue }
            let end = tick + 1
            while tick >= 0, s[tick] == "`" { tick -= 1 }
            let start = tick + 1, length = end - start
            tickLengths[start] = length
            tickCloses[start] = lastTick[length]
            lastTick[length] = start
        }
        let nextClose = nextTable { s[$0] == "]" }
        let nextParen = nextTable { s[$0] == ")" }
        func slice(_ range: Range<Int>) -> String {
            var out = String.UnicodeScalarView()
            out.append(contentsOf: s[range])
            return String(out)
        }

        var nodes: [ChatInline] = []
        var plain = 0      // start of the text run not yet emitted
        func flush(_ end: Int) {
            if plain < end { nodes += chatEmphasis(s, plain..<end) }
        }
        var i = 0
        while i < n {
            let c = s[i]
            if c == "`" {
                let length = tickLengths[i] ?? 1
                if let close = tickCloses[i] {
                    flush(i)
                    nodes.append(.code(Array(s[i + length..<close])))
                    i = close + length; plain = i
                    continue
                }
                i += length
                continue
            } else if c == "[" || c == "!" && i + 1 < n && s[i + 1] == "[" {
                let open = c == "!" ? i + 1 : i
                let close = nextClose[open + 1]
                if close < n, close > open + (c == "!" ? 0 : 1), close + 1 < n, s[close + 1] == "(" {
                    let end = nextParen[close + 2]
                    if end < n, end - close - 2 <= chatMaxLinkLength + 256 {
                        flush(i)
                        let target = chatLinkTarget(in: s[close + 2..<end]).map(slice)
                        if c == "[", let target, let url = chatLink(target) {
                            nodes.append(.link(url, chatEmphasis(s, open + 1..<close)))
                        } else {
                            nodes.append(.literal(Array(s[i..<end + 1])))
                        }
                        i = end + 1; plain = i
                        continue
                    }
                }
            } else if c == "h", i == 0 || isAutolinkBoundary(s[i - 1]),
                      let scheme = ["https://", "http://"].first(where: { hasPrefix(s, $0, at: i) }) {
                var end = i + scheme.unicodeScalars.count
                while end < n, !isAutolinkStop(s[end]) { end += 1 }
                var last = end
                while last > i, ".,;:!?)".unicodeScalars.contains(s[last - 1]) { last -= 1 }
                if last > i + scheme.unicodeScalars.count {
                    flush(i)
                    if last - i <= chatMaxLinkLength, let url = chatLink(slice(i..<last)) {
                        nodes.append(.link(url, [.literal(Array(s[i..<last]))]))
                    } else {
                        nodes.append(.literal(Array(s[i..<last])))
                    }
                    i = last; plain = i
                    continue
                }
                i = end
                continue
            }
            i += 1
        }
        flush(n)
        return nodes
    }

    /// A link target is the text up to the first space; anything after it
    /// must be a quoted title, which is dropped.
    private static func chatLinkTarget(in inner: ArraySlice<Unicode.Scalar>) -> Range<Int>? {
        guard let space = inner.firstIndex(of: " ") else { return inner.isEmpty ? nil : inner.indices }
        let title = inner[space...].drop { $0 == " " }
        guard title.count >= 2, title.first == "\"", title.last == "\"", !title.dropFirst().dropLast().contains("\"") else { return nil }
        return inner.startIndex..<space
    }

    private static func isAutolinkBoundary(_ c: Unicode.Scalar) -> Bool {
        !(CharacterSet.alphanumerics.contains(c) || c == "_" || c == "/" || c == "=" || c == "\"")
    }

    private static func isAutolinkStop(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(c) || c == "<" || c == ">" || c == "\"" || c == "`"
    }

    private static func hasPrefix(_ s: [Unicode.Scalar], _ prefix: String, at i: Int) -> Bool {
        var j = i
        for p in prefix.unicodeScalars {
            guard j < s.count, s[j] == p else { return false }
            j += 1
        }
        return true
    }

    /// Bold, italic and strikethrough within one run of text, escaped. A
    /// closer is the next valid one on the same line, as in the document
    /// regexes; a kind doesn't nest in itself, so depth stays at three.
    private static func chatEmphasis(_ s: [Unicode.Scalar], _ range: Range<Int>) -> [ChatInline] {
        let lo = range.lowerBound, hi = range.upperBound
        func word(_ k: Int) -> Bool { k >= lo && k < hi && (CharacterSet.alphanumerics.contains(s[k]) || s[k] == "_") }
        func space(_ k: Int) -> Bool { k < lo || k >= hi || CharacterSet.whitespacesAndNewlines.contains(s[k]) }
        func at(_ k: Int, _ c: Unicode.Scalar) -> Bool { k >= lo && k < hi && s[k] == c }
        func table(_ hit: (Int) -> Bool) -> [Int] {
            var t = [Int](repeating: hi, count: hi - lo + 2)
            var k = hi - 1
            while k >= lo { t[k - lo] = hit(k) ? k : t[k - lo + 1]; k -= 1 }
            return t
        }
        let line = table { s[$0] == "\n" }
        let doubleStar = table { at($0, "*") && at($0 + 1, "*") }
        let doubleUnder = table { at($0, "_") && at($0 + 1, "_") }
        let doubleTilde = table { at($0, "~") && at($0 + 1, "~") }
        let starCloser = table { at($0, "*") && !space($0 - 1) && !at($0 + 1, "*") && $0 > lo }
        let underCloser = table { at($0, "_") && !space($0 - 1) && !word($0 + 1) && $0 > lo }
        func next(_ t: [Int], _ k: Int) -> Int { k > hi ? hi : t[k - lo] }

        enum Kind { case strong, em, del }
        func render(_ from: Int, _ to: Int, _ open: Set<Kind>) -> [ChatInline] {
            var out: [ChatInline] = []
            var run = from
            func flush(_ end: Int) {
                guard run < end else { return }
                var start = run
                for k in run..<end where s[k] == "\n" {
                    if start < k { out.append(.text(Array(s[start..<k]))) }
                    out.append(.lineBreak)
                    start = k + 1
                }
                if start < end { out.append(.text(Array(s[start..<end]))) }
            }
            var k = from
            while k < to {
                let c = s[k]
                let eol = min(next(line, k), to)
                var span: (kind: Kind, width: Int, close: Int)?
                if (c == "*" || c == "_"), at(k + 1, c), !open.contains(.strong) {
                    let close = next(c == "*" ? doubleStar : doubleUnder, k + 3)
                    if close < eol, close + 1 < to { span = (.strong, 2, close) }
                }
                if span == nil, c == "~", at(k + 1, "~"), !open.contains(.del) {
                    let close = next(doubleTilde, k + 3)
                    if close < eol, close + 1 < to { span = (.del, 2, close) }
                }
                if span == nil, !open.contains(.em), !space(k + 1),
                   c == "*" && !word(k - 1) && !at(k - 1, "*") || c == "_" && !word(k - 1) {
                    let close = next(c == "*" ? starCloser : underCloser, k + 2)
                    if close < eol { span = (.em, 1, close) }
                }
                guard let span else { k += 1; continue }
                flush(k)
                let inner = render(k + span.width, span.close, open.union([span.kind]))
                out.append(span.kind == .strong ? .strong(inner) : span.kind == .em ? .em(inner) : .del(inner))
                k = span.close + span.width
                run = k
            }
            flush(to)
            return out
        }
        return render(lo, hi, [])
    }

    /// The one gate for a chat link (DESIGN-F7, 3): no control, format or
    /// space characters before or after percent-decoding, a parsed URL with
    /// http(s) and a host and no credentials, or mailto without fields.
    static func chatLink(_ raw: String) -> URL? {
        func clean(_ text: String, spaces: Bool) -> Bool {
            text.unicodeScalars.allSatisfy { c in
                let category = c.properties.generalCategory
                return category != .control && category != .format && c != "\\"
                    && (spaces || !c.properties.isWhitespace)
            }
        }
        guard raw.utf8.count <= chatMaxLinkLength, clean(raw, spaces: false), let url = URL(string: raw),
              url.absoluteString.utf8.count <= chatMaxLinkLength,
              let decoded = url.absoluteString.removingPercentEncoding, clean(decoded, spaces: true) else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard let host = url.host(percentEncoded: false), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return url
        case "mailto":
            let address = url.absoluteString.dropFirst("mailto:".count)
            return address.isEmpty || address.contains("?") ? nil : url
        default:
            return nil
        }
    }

    /// A link the chat web view was asked to follow, checked again: WebKit
    /// resolves and normalizes `href` on its own.
    static func chatLinkTarget(_ url: URL) -> URL? { chatLink(url.absoluteString) }

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

    static let chatPolicy = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    static func page(body: String, mode: Mode = .document) -> String {
        if mode == .chat { return chatPage(body: body) }
        return """
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

    private static func chatPage(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(chatPolicy)">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; color: CanvasText; background: transparent; overflow-wrap: anywhere; }
        p, ul, ol, pre, blockquote, table { margin: .35em 0; }
        h1, h2, h3, h4, h5, h6 { font-size: 1.15em; margin: .5em 0 .25em; } h4, h5, h6 { font-size: 1em; }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); padding: .1em .35em; border-radius: 4px; }
        pre { background: color-mix(in srgb, CanvasText 6%, transparent); padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { padding: 0 .8em; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); color: color-mix(in srgb, CanvasText 75%, transparent); }
        table { border-collapse: collapse; } th, td { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 3px 8px; }
        a { color: LinkText; } hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 18%, transparent); }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

/// The chat parse (DESIGN-F7, F3): blocks in the order the page shows them —
/// lists as their opening, items and closing, as the HTML has them.
enum ChatBlock: Equatable {
    case paragraph([ChatInline])
    case heading(Int, [ChatInline])
    case code(lang: String?, [Unicode.Scalar])
    case rule
    case quote([ChatBlock])
    case table(header: [[ChatInline]], rows: [[[ChatInline]]])
    case listOpen(ordered: Bool)
    case listClose(ordered: Bool)
    case itemNext
    /// `checked`: a task's box; nil for a plain item.
    case item(checked: Bool?, [ChatInline])
    case continuation([ChatInline])
}

/// Inline pieces; text as written (escaped only by whoever shows it). A
/// link's URL has passed `MarkdownRenderer.chatLink`; nothing else links.
indirect enum ChatInline: Equatable {
    case text([Unicode.Scalar])
    case lineBreak
    case code([Unicode.Scalar])
    /// A refused link or an image, shown as written.
    case literal([Unicode.Scalar])
    case link(URL, [ChatInline])
    case strong([ChatInline])
    case em([ChatInline])
    case del([ChatInline])
}
