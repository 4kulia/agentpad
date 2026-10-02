import AppKit
import Foundation

/// Language families for the preview's lightweight highlighter. Not a parser:
/// strings, comments, numbers and a keyword list per family — enough to read
/// code at a glance without a dependency.
enum SyntaxLanguage: String, Equatable, Sendable {
    case swift, cFamily, javaScript, python, ruby, go, rust, shell, json, yaml, toml, sql, html, css, plain

    static let knownTextExtensions: Set<String> = [
        "swift", "c", "h", "m", "mm", "cpp", "cc", "hpp", "cs", "java", "kt", "kts", "scala", "dart",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "pyi", "rb", "go", "rs", "sh", "bash", "zsh", "fish",
        "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "sql", "html", "htm", "xml", "svg",
        "css", "scss", "less", "txt", "log", "csv", "tsv", "env", "gitignore", "dockerignore", "lock",
        "gradle", "properties", "plist", "vue", "svelte", "php", "lua", "r", "pl", "ex", "exs", "erl",
        "md", "markdown", "rst", "tex", "graphql", "proto", "tf", "hcl", "nix", "zig",
    ]

    init(fileName: String) {
        let lower = fileName.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift": self = .swift
        case "c", "h", "m", "mm", "cpp", "cc", "hpp", "cs", "java", "kt", "kts", "scala", "dart", "php", "proto", "zig": self = .cFamily
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "graphql": self = .javaScript
        case "py", "pyi": self = .python
        case "rb": self = .ruby
        case "go": self = .go
        case "rs": self = .rust
        case "sh", "bash", "zsh", "fish", "env": self = .shell
        case "json", "jsonl", "lock": self = .json
        case "yaml", "yml": self = .yaml
        case "toml", "ini", "cfg", "conf", "properties": self = .toml
        case "sql": self = .sql
        case "html", "htm", "xml", "svg", "plist": self = .html
        case "css", "scss", "less": self = .css
        default:
            if ["makefile", "dockerfile", ".zshrc", ".bashrc", ".profile"].contains(lower) { self = .shell }
            else { self = .plain }
        }
    }

    var lineComment: String? {
        switch self {
        case .swift, .cFamily, .javaScript, .go, .rust, .css: return "//"
        case .python, .ruby, .shell, .yaml, .toml: return "#"
        case .sql: return "--"
        case .json, .html, .plain: return nil
        }
    }

    var hasBlockComments: Bool {
        switch self {
        case .swift, .cFamily, .javaScript, .go, .rust, .css, .sql: return true
        default: return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift: return ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch", "for", "in", "while", "import", "protocol", "extension", "static", "private", "public", "internal", "fileprivate", "init", "self", "Self", "nil", "true", "false", "try", "throw", "throws", "async", "await", "default", "break", "continue", "where", "some", "any", "final", "override", "mutating", "inout", "defer", "do", "catch", "typealias", "associatedtype", "actor", "nonisolated", "lazy", "weak", "unowned", "is", "as", "repeat"]
        case .cFamily: return ["int", "char", "void", "float", "double", "long", "short", "unsigned", "signed", "const", "static", "struct", "class", "enum", "union", "typedef", "if", "else", "for", "while", "do", "switch", "case", "default", "return", "break", "continue", "goto", "sizeof", "public", "private", "protected", "new", "delete", "this", "true", "false", "null", "nullptr", "namespace", "using", "template", "typename", "virtual", "override", "final", "import", "package", "extends", "implements", "interface", "fun", "val", "var", "object", "when", "is", "in", "try", "catch", "throw", "throws", "finally", "abstract", "bool", "boolean", "string", "auto", "function", "echo"]
        case .javaScript: return ["function", "const", "let", "var", "if", "else", "return", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "type", "interface", "enum", "implements", "public", "private", "protected", "readonly", "static", "yield", "delete", "void", "keyof", "declare", "namespace", "satisfies"]
        case .python: return ["def", "class", "if", "elif", "else", "return", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "None", "True", "False", "pass", "break", "continue", "global", "nonlocal", "async", "await", "assert", "del", "self", "match", "case"]
        case .ruby: return ["def", "class", "module", "if", "elsif", "else", "unless", "end", "return", "do", "while", "until", "for", "in", "begin", "rescue", "ensure", "raise", "yield", "self", "nil", "true", "false", "and", "or", "not", "require", "attr_accessor", "attr_reader", "private", "public", "then", "case", "when"]
        case .go: return ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "switch", "case", "default", "return", "break", "continue", "go", "defer", "select", "nil", "true", "false", "fallthrough", "goto", "make", "new", "len", "append", "error", "string", "int", "bool"]
        case .rust: return ["fn", "let", "mut", "if", "else", "match", "for", "while", "loop", "in", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "const", "static", "as", "where", "async", "await", "move", "ref", "true", "false", "None", "Some", "Ok", "Err", "unsafe", "dyn", "type", "break", "continue"]
        case .shell: return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "readonly", "set", "unset", "source", "echo", "exit", "true", "false", "shift", "trap"]
        case .sql: return ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "null", "is", "in", "like", "between", "union", "all", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default", "with", "returning"]
        case .json, .yaml, .toml: return ["true", "false", "null", "yes", "no", "on", "off"]
        case .html, .css, .plain: return []
        }
    }

    var keywordsCaseInsensitive: Bool { self == .sql }
}

/// Colors the preview uses. Picked to read on both light and dark chrome.
struct SyntaxPalette {
    var plain: NSColor = .textColor
    var keyword: NSColor = .systemPink
    var string: NSColor = .systemRed
    var comment: NSColor = .secondaryLabelColor
    var number: NSColor = .systemPurple
    var key: NSColor = .systemTeal
}

enum SyntaxHighlighter {
    struct Span: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case keyword, string, comment, number, key }
        let kind: Kind
        let range: NSRange
    }

    /// Highlighting stops here; the rest of a huge file stays plain.
    static let maxHighlightedLength = 400_000

    /// One left-to-right pass over UTF-16. Unterminated strings and comments
    /// end at the line end / text end rather than swallowing the file.
    static func spans(in text: String, language: SyntaxLanguage) -> [Span] {
        guard language != .plain else { return [] }
        let s = text as NSString
        let length = min(s.length, maxHighlightedLength)
        var spans: [Span] = []
        let keywords = language.keywords
        let lineComment = language.lineComment.map { $0 as NSString }
        var i = 0

        func char(_ at: Int) -> unichar { at < length ? s.character(at: at) : 0 }
        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c == 64
        }
        func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        while i < length {
            let c = char(i)
            // Line comment.
            if let lc = lineComment, i + lc.length <= length, s.substring(with: NSRange(location: i, length: lc.length)) == lc as String,
               !(language == .shell && i > 0 && char(i - 1) == 36) {
                let end = s.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: i, length: length - i))
                let stop = end.location == NSNotFound ? length : end.location
                spans.append(Span(kind: .comment, range: NSRange(location: i, length: stop - i)))
                i = stop
                continue
            }
            // Block comment.
            if language.hasBlockComments, c == 47, char(i + 1) == 42 {
                let close = s.range(of: "*/", options: [], range: NSRange(location: i + 2, length: max(0, length - i - 2)))
                let stop = close.location == NSNotFound ? length : close.location + 2
                spans.append(Span(kind: .comment, range: NSRange(location: i, length: stop - i)))
                i = stop
                continue
            }
            if language == .html, c == 60, char(i + 1) == 33, char(i + 2) == 45, char(i + 3) == 45 {
                let close = s.range(of: "-->", options: [], range: NSRange(location: i, length: length - i))
                let stop = close.location == NSNotFound ? length : close.location + 3
                spans.append(Span(kind: .comment, range: NSRange(location: i, length: stop - i)))
                i = stop
                continue
            }
            // Strings: " ' and ` (JS / Go raw / shell).
            if c == 34 || c == 39 || (c == 96 && [.javaScript, .go, .shell].contains(language)) {
                // An apostrophe in prose-y formats isn't a string.
                if c == 39, [.yaml, .toml, .html].contains(language), i > 0, isIdent(char(i - 1)) { i += 1; continue }
                let quote = c
                var j = i + 1
                let multiline = quote == 96
                while j < length {
                    let d = char(j)
                    if d == 92 { j += 2; continue }
                    if d == quote { j += 1; break }
                    if !multiline, d == 10 { break }
                    j += 1
                }
                j = min(j, length)
                // JSON / YAML: a string followed by ':' is a key.
                var k = j
                while k < length, char(k) == 32 { k += 1 }
                let isKey = [.json].contains(language) && char(k) == 58
                spans.append(Span(kind: isKey ? .key : .string, range: NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            // Numbers.
            if isDigit(c), i == 0 || !isIdent(char(i - 1)) {
                var j = i + 1
                while j < length, isIdent(char(j)) || char(j) == 46 { j += 1 }
                spans.append(Span(kind: .number, range: NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            // Identifiers / keywords; YAML & TOML keys at line start.
            if isIdentStart(c) {
                var j = i + 1
                while j < length, isIdent(char(j)) || (char(j) == 45 && [.yaml, .toml, .css].contains(language)) { j += 1 }
                let word = s.substring(with: NSRange(location: i, length: j - i))
                var k = j
                while k < length, char(k) == 32 { k += 1 }
                if [.yaml, .toml].contains(language), char(k) == 58 || char(k) == 61, atLineStart(s, i) {
                    spans.append(Span(kind: .key, range: NSRange(location: i, length: j - i)))
                } else if keywords.contains(language.keywordsCaseInsensitive ? word.lowercased() : word) {
                    spans.append(Span(kind: .keyword, range: NSRange(location: i, length: j - i)))
                }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    private static func atLineStart(_ s: NSString, _ index: Int) -> Bool {
        var k = index - 1
        while k >= 0 {
            let c = s.character(at: k)
            if c == 10 { return true }
            if c != 32 && c != 9 && c != 45 { return false }
            k -= 1
        }
        return true
    }

    static func attributed(_ text: String, spans: [Span], font: NSFont, palette: SyntaxPalette = .init()) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.plain])
        let length = (text as NSString).length
        for span in spans where NSMaxRange(span.range) <= length {
            let color: NSColor
            switch span.kind {
            case .keyword: color = palette.keyword
            case .string: color = palette.string
            case .comment: color = palette.comment
            case .number: color = palette.number
            case .key: color = palette.key
            }
            result.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        return result
    }
}
