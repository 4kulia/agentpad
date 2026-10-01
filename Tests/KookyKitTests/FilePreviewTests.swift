import XCTest
@testable import KookyKit

/// AgentPad: the file preview's pure parts — content detection, the
/// highlighter's tokenizer, and the Markdown renderer. The views themselves
/// (NSTextView, Quick Look, WKWebView) stay manual.
@MainActor
final class FilePreviewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Detection

    func testDetectsTextMarkdownBinaryAndFolders() throws {
        let swift = try file("a.swift", Data("let x = 1".utf8))
        guard case .text(let text, let lang, false, let spans) = FilePreviewModel.load(swift) else { return XCTFail() }
        XCTAssertEqual(text, "let x = 1")
        XCTAssertEqual(lang, .swift)
        XCTAssertEqual(spans.map(\.kind), [.keyword, .number], "highlighted while loading")

        guard case .markdown(let md, let html) = FilePreviewModel.load(try file("README.md", Data("# Hi".utf8))) else { return XCTFail() }
        XCTAssertEqual(md, "# Hi")
        XCTAssertTrue(html.contains("<h1>Hi</h1>"))
        // No extension, but plain UTF-8: sniffed as text.
        guard case .text = FilePreviewModel.load(try file("Makefile", Data("all:\n\techo hi".utf8))) else { return XCTFail() }
        // NUL bytes: binary, handed to Quick Look.
        XCTAssertEqual(FilePreviewModel.load(try file("blob", Data([0x00, 0x01, 0x02]))), .quickLook)
        XCTAssertEqual(FilePreviewModel.load(try file("pic.png", Data([0x89, 0x50]))), .quickLook)
        XCTAssertEqual(FilePreviewModel.load(try file("bad", Data([0x41, 0xC3, 0x28]))), .quickLook, "invalid UTF-8")
        XCTAssertEqual(FilePreviewModel.load(dir), .directory)
        guard case .unreadable = FilePreviewModel.load(dir.appendingPathComponent("missing.txt")) else { return XCTFail() }
    }

    func testLargeTextIsTruncatedAndLargeMarkdownFallsBackToText() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: FilePreviewModel.textByteLimit + 10)
        guard case .text(let text, _, true, _) = FilePreviewModel.load(try file("big.log", big)) else { return XCTFail() }
        XCTAssertEqual(text.utf8.count, FilePreviewModel.textByteLimit)
        guard case .text(_, _, true, _) = FilePreviewModel.load(try file("big.md", big)) else { return XCTFail() }
    }

    func testLanguageFromFileName() {
        XCTAssertEqual(SyntaxLanguage(fileName: "x.tsx"), .javaScript)
        XCTAssertEqual(SyntaxLanguage(fileName: "Dockerfile"), .shell)
        XCTAssertEqual(SyntaxLanguage(fileName: "q.SQL"), .sql)
        XCTAssertEqual(SyntaxLanguage(fileName: "notes.txt"), .plain)
    }

    // MARK: Highlighter

    private func kinds(_ code: String, _ lang: SyntaxLanguage) -> [(SyntaxHighlighter.Span.Kind, String)] {
        let ns = code as NSString
        return SyntaxHighlighter.spans(in: code, language: lang).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    func testSwiftTokens() {
        let spans = kinds("let s = \"a // b\" // note\nreturn 42", .swift)
        XCTAssertEqual(spans.map(\.0), [.keyword, .string, .comment, .keyword, .number])
        XCTAssertEqual(spans.map(\.1), ["let", "\"a // b\"", "// note", "return", "42"])
    }

    func testBlockCommentsEscapesAndUnterminatedStrings() {
        let spans = kinds("/* a\nb */ x = \"q\\\"t\"\ny = \"open\nz", .javaScript)
        XCTAssertEqual(spans.map(\.0), [.comment, .string, .string])
        XCTAssertEqual(spans[1].1, "\"q\\\"t\"")
        XCTAssertEqual(spans[2].1, "\"open", "an unterminated string stops at the line end")
    }

    func testPythonAndShellComments() {
        XCTAssertEqual(kinds("def f(): # hi", .python).map(\.0), [.keyword, .comment])
        // `$#` in shell is a variable, not a comment.
        XCTAssertEqual(kinds("echo $# # count", .shell).map(\.1), ["echo", "# count"])
    }

    func testJSONKeysAndYAMLKeys() {
        XCTAssertEqual(kinds("{\"name\": \"x\", \"n\": 1}", .json).map(\.0), [.key, .string, .key, .number])
        XCTAssertEqual(kinds("name: app\nlist:\n  - item", .yaml).map(\.1), ["name", "list"])
    }

    func testIdentifiersWithDigitsAreNotNumbers() {
        XCTAssertEqual(kinds("var x1 = utf8", .swift).map(\.1), ["var"])
    }

    // MARK: Markdown

    func testMarkdownBlocks() {
        let html = MarkdownRenderer.html("""
        # Title
        Some *em* and **bold** and `x<y`.

        - one
        - [x] done
          - nested
        1. first

        > quote

        ```swift
        let a = "<b>"
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        """)
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<em>em</em>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>x&lt;y</code>"))
        XCTAssertTrue(html.contains("<ul>\n<li>one"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" checked disabled> done"))
        XCTAssertTrue(html.contains("<li><input type=\"checkbox\" checked disabled> done\n<ul>\n<li>nested"), "nested list inside its parent item")
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>quote</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot;</code></pre>"))
        XCTAssertTrue(html.contains("<th>a</th>"))
        XCTAssertTrue(html.contains("<td>2</td>"))
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testMarkdownInlineSafety() {
        XCTAssertEqual(MarkdownRenderer.inline("<script>alert(1)</script>"), "&lt;script&gt;alert(1)&lt;/script&gt;")
        XCTAssertFalse(MarkdownRenderer.inline("[x](javascript:alert(1))").contains("javascript:"))
        XCTAssertEqual(MarkdownRenderer.inline("[docs](./a.md)"), "<a href=\"./a.md\">docs</a>")
        XCTAssertEqual(MarkdownRenderer.inline("![logo](img/l.png)"), "<img alt=\"logo\" src=\"img/l.png\">")
        XCTAssertEqual(MarkdownRenderer.inline("see https://example.com."), "see <a href=\"https://example.com\">https://example.com</a>.")
        // Nothing inside a code span is interpreted.
        XCTAssertEqual(MarkdownRenderer.inline("`**not bold**`"), "<code>**not bold**</code>")
        XCTAssertEqual(MarkdownRenderer.inline("snake_case_name"), "snake_case_name")
    }

    func testDeepBlockquotesStopRecursing() {
        let hostile = String(repeating: ">", count: 5_000) + " boom"
        let html = MarkdownRenderer.html(hostile)
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count - 1, MarkdownRenderer.maxQuoteDepth)
    }

    // MARK: Local resources for rendered Markdown

    func testImagesLoadOnlyFromInsideTheProject() throws {
        let project = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("img"), withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("img/a.png")
        try Data([1, 2, 3]).write(to: inside)
        let outside = dir.appendingPathComponent("secret.png")
        try Data([9]).write(to: outside)
        let text = project.appendingPathComponent("notes.txt")
        try Data("t".utf8).write(to: text)
        let escape = project.appendingPathComponent("img/escape.png")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        XCTAssertEqual(LocalResourceHandler.resource(at: inside.path, root: project), Data([1, 2, 3]))
        XCTAssertNil(LocalResourceHandler.resource(at: outside.path, root: project), "outside the project")
        XCTAssertNil(LocalResourceHandler.resource(at: project.path + "/img/../../secret.png", root: project), "dot-dot escape")
        XCTAssertNil(LocalResourceHandler.resource(at: escape.path, root: project), "symlink escape")
        XCTAssertNil(LocalResourceHandler.resource(at: text.path, root: project), "not an image")
    }

    func testCSPAllowsOnlyOurSchemeForLocalImages() {
        let page = MarkdownRenderer.page(body: "")
        XCTAssertTrue(page.contains("img-src agentpad-doc: https: data:"))
        XCTAssertFalse(page.contains("file:"))
    }

    func testFileLinksAreRoutedThroughOurScheme() {
        XCTAssertEqual(
            MarkdownRenderer.inline("[doc](file:///tmp/other.md#part)"),
            "<a href=\"agentpad-doc://local/tmp/other.md#part\">doc</a>"
        )
    }
}
