import Foundation
import SwiftUI

/// Chat Markdown as native text (DESIGN-F3): the same parse as F7's page
/// (`MarkdownRenderer.chatDocument`), shown by SwiftUI's `Text`. Nothing
/// loads and nothing runs; the only links are those `chatLink` let through,
/// and the view opens them through `chatLinkTarget` again.
enum ChatMarkdownText {
    static func attributed(_ markdown: String) -> AttributedString {
        guard let blocks = MarkdownRenderer.chatDocument(markdown) else {
            var plain = AttributedString(clean(Array(markdown.unicodeScalars)))
            plain.foregroundColor = .primary
            return plain
        }
        var out = AttributedString()
        append(blocks, to: &out, quote: 0)
        // No trailing break after the last block.
        while out.characters.last == "\n" { out.removeSubrange(out.index(beforeCharacter: out.endIndex)..<out.endIndex) }
        return out
    }

    private static func append(_ blocks: [ChatBlock], to out: inout AttributedString, quote: Int) {
        var lists: [(ordered: Bool, number: Int)] = []
        func line(_ text: AttributedString) {
            var prefix = AttributedString(String(repeating: "▎ ", count: quote))
            prefix.foregroundColor = .secondary
            var body = text
            if quote > 0 { body.foregroundColor = .secondary }
            out += prefix + body + AttributedString("\n")
        }
        for block in blocks {
            switch block {
            case .paragraph(let inline):
                line(self.inline(inline))
            case .heading(_, let inline):
                var text = self.inline(inline)
                text.inlinePresentationIntent = .stronglyEmphasized
                line(text)
            case .code(_, let text):
                var code = AttributedString(clean(text))
                code.inlinePresentationIntent = .code
                code.backgroundColor = Color.secondary.opacity(0.12)
                line(code)
            case .rule:
                line(AttributedString("────────"))
            case .quote(let inner):
                append(inner, to: &out, quote: quote + 1)
            case .table(let header, let rows):
                for (n, row) in ([header] + rows).enumerated() {
                    var text = AttributedString()
                    for (i, cell) in row.enumerated() {
                        if i > 0 { text += AttributedString(" │ ") }
                        text += self.inline(cell)
                    }
                    if n == 0 { text.inlinePresentationIntent = .stronglyEmphasized }
                    line(text)
                }
            case .listOpen(let ordered):
                lists.append((ordered, 0))
            case .listClose:
                _ = lists.popLast()
            case .itemNext:
                break
            case .item(let checked, let inline):
                let indent = String(repeating: "    ", count: max(lists.count - 1, 0))
                var marker = "• "
                if let last = lists.indices.last {
                    lists[last].number += 1
                    if lists[last].ordered { marker = "\(lists[last].number). " }
                }
                if let checked { marker += checked ? "☑ " : "☐ " }
                line(AttributedString(indent + marker) + self.inline(inline))
            case .continuation(let inline):
                line(AttributedString(String(repeating: "    ", count: lists.count)) + self.inline(inline))
            }
        }
    }

    static func inline(_ nodes: [ChatInline]) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            switch node {
            case .text(let s), .literal(let s):
                out += AttributedString(clean(s))
            case .lineBreak:
                out += AttributedString("\n")
            case .code(let s):
                var code = AttributedString(clean(s))
                code.inlinePresentationIntent = .code
                code.backgroundColor = Color.secondary.opacity(0.12)
                out += code
            case .link(let url, let children):
                var text = inline(children)
                text.link = url
                out += text
            case .strong(let c):
                out += styled(inline(c), .stronglyEmphasized)
            case .em(let c):
                out += styled(inline(c), .emphasized)
            case .del(let c):
                out += styled(inline(c), .strikethrough)
            }
        }
        return out
    }

    private static func styled(_ text: AttributedString, _ intent: InlinePresentationIntent) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return text
    }

    /// As written, with NUL shown as U+FFFD (as the page does).
    private static func clean(_ s: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        for c in s { out.append(c == "\u{0}" ? "\u{FFFD}" : c) }
        return String(out)
    }

    /// Opens a link of chat text: checked again, then the system browser
    /// (`ChatMarkdownNavigation`'s rule, for native text).
    static func open(_ url: URL, with open: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> OpenURLAction.Result {
        if let target = MarkdownRenderer.chatLinkTarget(url) { open(target) }
        return .handled
    }
}
