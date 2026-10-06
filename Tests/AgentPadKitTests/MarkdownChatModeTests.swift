import AppKit
import WebKit
import XCTest
@testable import AgentPadKit

/// DESIGN-F7: chat Markdown is untrusted. Nothing runs, nothing loads, links
/// go only to http(s)/mailto, and time and output stay linear.
@MainActor
final class MarkdownChatModeTests: XCTestCase {
    private func chat(_ md: String) -> String { MarkdownRenderer.html(md, mode: .chat) }

    /// The closed set of tags and attributes, checked on any output.
    private func assertSafe(_ html: String, _ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let allowed: [String: Set<String>] = [
            "p": [], "br": [], "h1": [], "h2": [], "h3": [], "h4": [], "h5": [], "h6": [], "strong": [], "em": [], "del": [],
            "code": ["class"], "pre": [], "ul": [], "ol": [], "li": [], "blockquote": [], "table": [], "thead": [], "tbody": [],
            "tr": [], "th": [], "td": [], "hr": [], "a": ["href", "title"],
        ]
        let tag = try! NSRegularExpression(pattern: #"<(/?)([^\s>/]*)([^>]*)>"#)
        let attr = try! NSRegularExpression(pattern: #"\s([^\s=]+)="([^"]*)""#)
        let ns = html as NSString
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            guard let attrs = allowed[name] else { return XCTFail("tag <\(name)> in \(what): \(html.prefix(300))", file: file, line: line) }
            let rest = ns.substring(with: m.range(at: 3))
            let whole = NSRange(location: 0, length: (rest as NSString).length)
            let leftover = attr.stringByReplacingMatches(in: rest, range: whole, withTemplate: "")
            XCTAssertTrue(leftover.trimmingCharacters(in: .whitespaces).isEmpty, "stray markup <\(name)\(rest)> in \(what)", file: file, line: line)
            for a in attr.matches(in: rest, range: whole) {
                let key = (rest as NSString).substring(with: a.range(at: 1)).lowercased()
                XCTAssertTrue(attrs.contains(key), "attribute \(key) on <\(name)> in \(what)", file: file, line: line)
                if key == "href" {
                    let value = (rest as NSString).substring(with: a.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&")
                    let scheme = URL(string: value)?.scheme?.lowercased() ?? ""
                    XCTAssertTrue(["http", "https", "mailto"].contains(scheme), "href \(value) in \(what)", file: file, line: line)
                }
            }
        }
        for bad in ["<img", "<script", "<iframe", "<input", "<style"] {
            XCTAssertFalse(html.lowercased().contains(bad), "\(bad) in \(what)", file: file, line: line)
        }
    }

    private static let hostile: [String] = [
        "![x](https://evil.example/p.png)", "![x](data:image/png;base64,AAAA)", "[a](javascript:alert(1))",
        "[a](JaVaScRiPt:alert(1))", "[a](vbscript:msgbox)", "[a](file:///etc/passwd)", "[a](agentpad-doc://local/x)",
        "[a](agentpad://x)", "[a](../../.ssh/id_rsa)", "[a](#x)", "[a](//evil.example)", "[a](https://ex.com/a b)",
        "[a](https://ex.com/\u{202E}gpj)", "[a](https://ex\u{0}.com)", "[a](https://ex.com/%E2%80%AEgpj)",
        "[a](https://user:pw@ex.com)", "[a](mailto:x@ex.com?body=hi)", "[a](https://ex.com/\t)", #"[a](https:\\evil.example)"#,
        "<script>alert(1)</script>", "<img src=x onerror=alert(1)>", "<iframe src=https://evil.example>",
        #"<a href="javascript:x">y</a>"#, "<style>body{}</style>", "`<b>`", "```html\n<script>x</script>\n```",
        "```\"><script>\nz\n```", "- [ ] box\n- [x] done", "[x](https://a.b/__init__)", "&#x6A;avascript:alert(1)",
        "[a](&#x6A;avascript:alert(1))", #"[**b**](https://ex.com "t")"#, #"https://ex.com/"onmouseover=x"#,
        #"[a](https://ex.com/"onmouseover=x)"#, "*[a](https://ex.com/*x*)*", "x\u{0}0\u{0}y `c\u{0}0\u{0}`",
    ]

    func testHostileInputsRenderInsideTheClosedSet() {
        for input in Self.hostile {
            assertSafe(chat(input), input)
            assertSafe(chat("> " + input), "quoted " + input)
            assertSafe(chat("| a |\n|---|\n| \(input) |"), "cell " + input)
            assertSafe(chat("- " + input), "item " + input)
        }
    }

    func testImagesStayText() {
        XCTAssertEqual(chat("![x](https://evil.example/p.png)"), "<p>![x](https://evil.example/p.png)</p>")
        XCTAssertEqual(chat("![x](data:image/png;base64,AAAA)"), "<p>![x](data:image/png;base64,AAAA)</p>")
    }

    func testRefusedLinksStayTextAsWritten() {
        for target in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "vbscript:x", "file:///etc/passwd", "agentpad-doc://local/x",
                       "agentpad://x", "data:text/html,x", "../../.ssh/id_rsa", "#x", "//evil.example", "https://user:pw@ex.com",
                       "mailto:x@ex.com?body=hi", "https://ex.com/%E2%80%AEgpj", "https://ex.com/\u{202E}gpj", "https://ex.com/\u{200B}"] {
            let html = chat("[a](\(target))")
            XCTAssertFalse(html.contains("href"), target)
            XCTAssertEqual(html, "<p>\(MarkdownRenderer.escape("[a](\(target))"))</p>", target)
        }
        XCTAssertFalse(chat("[a](https://ex.com/a b)").contains("href"), "a space ends the target, the rest is no title")
    }

    func testAllowedLinks() {
        XCTAssertEqual(chat("[a](https://ex.com/a%20b)"), #"<p><a href="https://ex.com/a%20b" title="https://ex.com/a%20b">a</a></p>"#)
        XCTAssertEqual(chat("[m](mailto:x@ex.com)"), #"<p><a href="mailto:x@ex.com" title="mailto:x@ex.com">m</a></p>"#)
        XCTAssertEqual(chat(#"[**b**](https://ex.com "t")"#), #"<p><a href="https://ex.com" title="https://ex.com"><strong>b</strong></a></p>"#)
        XCTAssertEqual(chat("[x](https://a.b/__init__)"), #"<p><a href="https://a.b/__init__" title="https://a.b/__init__">x</a></p>"#)
        XCTAssertEqual(chat("see https://ex.com/path. ok"),
                       #"<p>see <a href="https://ex.com/path" title="https://ex.com/path">https://ex.com/path</a>. ok</p>"#)
        XCTAssertEqual(chat("a/https://ex.com"), "<p>a/https://ex.com</p>", "no autolink glued to a word or path")
    }

    func testRawHTMLAndCodeAreEscaped() {
        XCTAssertEqual(chat("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        XCTAssertEqual(chat("<img src=x onerror=alert(1)>"), "<p>&lt;img src=x onerror=alert(1)&gt;</p>")
        XCTAssertEqual(chat("`<b>` **x**"), "<p><code>&lt;b&gt;</code> <strong>x</strong></p>")
        XCTAssertEqual(chat("```swift\nlet a = \"<x>\"\n```"), #"<pre><code class="language-swift">let a = &quot;&lt;x&gt;&quot;</code></pre>"#)
        XCTAssertEqual(chat("```\"><script>\nz\n```"), "<pre><code>z</code></pre>", "an odd language gets no class")
        XCTAssertEqual(chat("x\u{0}0\u{0}y"), "<p>x\u{FFFD}0\u{FFFD}y</p>")
    }

    func testCodeDelimiterRunsAndLazyQuoteContinuationShareTheChatTree() {
        XCTAssertEqual(chat("``a ` b``"), "<p><code>a ` b</code></p>")
        XCTAssertEqual(chat("````swift\n```\na\n````"), "<pre><code class=\"language-swift\">```\na</code></pre>")
        XCTAssertEqual(chat("    code"), "<pre><code>code</code></pre>")
        XCTAssertEqual(chat("> quoted\ncontinuation\n\noutside"), "<blockquote><p>quoted<br>continuation</p></blockquote>\n<p>outside</p>")
        XCTAssertEqual(MarkdownRenderer.chatDocument("- ```\n  code\n  ```"), [
            .listOpen(ordered: false), .item(checked: nil, []), .code(lang: nil, Array("code".unicodeScalars)), .listClose(ordered: false)])
    }

    func testChatBlocks() {
        XCTAssertEqual(chat("one\ntwo"), "<p>one<br>two</p>", "line breaks matter in chat")
        XCTAssertEqual(chat("*a* _b_ ~~c~~ **d**"), "<p><em>a</em> <em>b</em> <del>c</del> <strong>d</strong></p>")
        XCTAssertEqual(chat("- [ ] a\n- [x] b"), "<ul>\n<li>\u{2610} a\n</li>\n<li>\u{2611} b\n</li></ul>")
        let deep = (0..<20).map { String(repeating: "  ", count: $0) + "- l\($0)" }.joined(separator: "\n")
        XCTAssertEqual(chat(deep).components(separatedBy: "<ul>").count - 1, MarkdownRenderer.maxListDepth)
        let wide = "|" + (0..<70).map { "c\($0)" }.joined(separator: "|") + "|\n|" + String(repeating: "-|", count: 70)
        XCTAssertEqual(chat(wide).components(separatedBy: "<th>").count - 1, MarkdownRenderer.chatMaxColumns)
        XCTAssertTrue(chat(wide).contains("c63|c64"), "the rest stays text in the last cell")
    }

    /// Review F7-3: a NUL in a target is checked as written, not after it is shown as U+FFFD.
    func testNulInATargetIsNoLink() {
        for input in ["[a](https://ex.com/\u{0})", "https://ex.com/\u{0}x", "[a](https://ex\u{0}.com)"] {
            XCTAssertFalse(chat(input).contains("href"), input.debugDescription)
        }
    }

    /// Review F7-2: every link the renderer makes passes the check on click,
    /// by the same length measure.
    func testEveryRenderedLinkOpens() throws {
        let long = "https://ex.com/" + String(repeating: "я", count: 340)
        XCTAssertFalse(chat("[a](\(long))").contains("href"), "too long once encoded, at render as on click")
        XCTAssertFalse(chat(long).contains("href"))
        let fits = "https://ex.com/" + String(repeating: "я", count: 300)
        let inputs = Self.hostile + ["[a](\(fits))", fits, "[a](https://ex.com/a%20b)", "[m](mailto:x@ex.com)",
                                     "https://ex.com/path.", "[a](https://пример.рф/путь?q=1#я)"]
        let href = try NSRegularExpression(pattern: #"href="([^"]*)""#)
        var made = 0
        for input in inputs {
            let html = chat(input)
            for m in href.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
                let value = (html as NSString).substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
                let url = try XCTUnwrap(URL(string: value), value)
                XCTAssertNotNil(MarkdownRenderer.chatLinkTarget(url), "made but refused on click: \(value)")
                made += 1
            }
        }
        XCTAssertGreaterThanOrEqual(made, 6)
    }

    func testChatLinkTargetChecksAgain() throws {
        let cases: [(String, String?)] = [
            ("https://ex.com/a", "https://ex.com/a"), ("HTTPS://EX.COM/a", "HTTPS://EX.COM/a"), ("hTtP://ex.com", "hTtP://ex.com"),
            ("mailto:x@ex.com", "mailto:x@ex.com"), ("file:///etc/passwd", nil), ("agentpad-doc://local/x", nil), ("agentpad://x", nil),
            ("javascript:alert(1)", nil), ("about:blank", nil), ("data:text/html,x", nil), ("https://ex.com/%E2%80%AEgpj", nil),
            ("https://ex.com/%00", nil), ("https://u:p@ex.com", nil), ("https:///path", nil), ("https://ex.com/%FF", nil),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertEqual(MarkdownRenderer.chatLinkTarget(url)?.absoluteString, expected, raw)
        }
    }

    func testChatPagePolicy() {
        let page = MarkdownRenderer.page(body: "x", mode: .chat)
        XCTAssertTrue(page.contains(#"content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'""#))
        XCTAssertFalse(page.contains("img-src"))
    }

    /// 128 KiB of each hostile pattern renders within a second, and the
    /// output stays within its bound.
    func testHostileSizeIsLinear() {
        let cap = MarkdownRenderer.chatMarkdownLimit
        func fill(_ unit: String) -> String { String(repeating: unit, count: cap / unit.utf8.count - 64) }
        let inputs: [(String, String)] = [
            ("code", fill("`a` ")), ("star", fill("*a")), ("double star", fill("**a")), ("under", fill("_a_ ")),
            ("bracket", fill("[")), ("open link", fill("[a](")), ("image", fill("![a](b)")), ("link", fill("[a](https://e.co) ")),
            ("tilde", fill("~~a")), ("quotes", String(repeating: ">", count: 12) + fill("x")),
            ("indent", (0..<2000).map { String(repeating: " ", count: $0 % 60) + "- x" }.joined(separator: "\n")),
            ("table", "|" + String(repeating: "a|", count: 80) + "\n|" + String(repeating: "-|", count: 80) + "\n"
                + String(repeating: "|" + String(repeating: "b|", count: 80) + "\n", count: 700)),
            ("one line", fill("x")), ("autolink", "https://e.co/" + fill("y")), ("amp autolink", "https://a.b/" + fill("&")),
            ("quote chars", fill("\"")), ("mixed", fill("*_~`[]()!<>&\"")), ("lines", fill("a\n")),
        ]
        // Review F7-1: one grapheme of combining marks, in every block and span.
        let marks = String(repeating: "\u{301}\u{323}", count: (cap - 64) / 4)
        let zalgo: [(String, String)] = [
            ("marks", "x" + marks), ("marks heading", "# x" + marks), ("marks item", "- x" + marks), ("marks quote", "> x" + marks),
            ("marks cell", "| a |\n|---|\n| x" + marks + " |"), ("marks fence", "```\nx" + marks + "\n```"),
            ("marks code", "`x" + marks + "`"), ("marks link", "[x" + marks + "](https://e.co)"), ("marks autolink", "https://e.co/x" + marks),
            ("marks fence open", "```x" + marks), ("marks rule", "-" + marks), ("marks lines", fill("x\u{301}\u{323}\n")),
        ]
        for (name, input) in inputs + zalgo {
            XCTAssertLessThanOrEqual(input.utf8.count, cap, name)
            let start = Date()
            let html = chat(input)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, name)
            XCTAssertLessThanOrEqual(html.utf8.count, MarkdownRenderer.chatOutputFactor * input.utf8.count + MarkdownRenderer.chatOutputSlack, name)
            // The checker's regexes are slow on marks themselves; they are text, so drop them first.
            var unmarked = String.UnicodeScalarView()
            unmarked.append(contentsOf: html.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
            assertSafe(String(unmarked), name)
        }
    }

    func testAmpAutolinkFallsBackToPlainText() {
        let input = "https://a.b/" + String(repeating: "&", count: 10_000)
        let html = chat(input)
        XCTAssertFalse(html.contains("href"), "output past the bound is shown without formatting")
        XCTAssertLessThanOrEqual(html.utf8.count, 6 * input.utf8.count + 64)
    }

    func testLongTextIsShownWithoutFormatting() {
        let input = String(repeating: "**a** [x](https://e.co)\n", count: 200 * 1024 / 24)
        let html = chat(input)
        XCTAssertTrue(html.hasPrefix("<p><em>Long text: shown without formatting.</em></p>"))
        XCTAssertFalse(html.contains("<strong>"))
        XCTAssertFalse(html.contains("href"))
    }

    /// The document mode is untouched: the same corpus renders byte for byte
    /// as before F7.
    func testDocumentModeIsUnchanged() {
        XCTAssertEqual(MarkdownRenderer.html(Self.corpus), Self.golden)
        XCTAssertEqual(MarkdownRenderer.html(Self.corpus, mode: .document), Self.golden)
        XCTAssertTrue(MarkdownRenderer.page(body: "B").contains("img-src agentpad-doc: https: data:"))
    }

    // MARK: Web view

    private final class Action: WKNavigationAction {
        let type: WKNavigationType, url: URL?
        init(_ type: WKNavigationType, _ url: String?) { self.type = type; self.url = url.flatMap(URL.init(string:)); super.init() }
        override var navigationType: WKNavigationType { type }
        override var request: URLRequest { URLRequest(url: url ?? URL(string: "about:blank")!) }
    }

    func testDelegateLetsOnlyThePageLoadAndOpensCheckedLinks() {
        let navigation = ChatMarkdownNavigation()
        var opened: [URL] = []
        navigation.open = { opened.append($0) }
        let view = navigation.makeWebView()
        func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
            var policy: WKNavigationActionPolicy?
            navigation.webView(view, decidePolicyFor: action) { policy = $0 }
            return policy ?? .allow
        }
        XCTAssertEqual(decide(Action(.other, "about:blank")), .allow)
        XCTAssertEqual(decide(Action(.linkActivated, "https://ex.com/a")), .cancel)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://ex.com/a"])
        let refused: [(WKNavigationType, String)] = [
            (.linkActivated, "file:///etc/passwd"), (.linkActivated, "agentpad-doc://local/x"), (.linkActivated, "about:blank"),
            (.other, "https://ex.com"), (.other, "file:///etc/passwd"), (.formSubmitted, "https://ex.com"),
            (.backForward, "https://ex.com"), (.reload, "https://ex.com"), (.formResubmitted, "https://ex.com"),
        ]
        for (type, url) in refused {
            XCTAssertEqual(decide(Action(type, url)), .cancel, "\(type.rawValue) \(url)")
        }
        XCTAssertEqual(opened.count, 1, "nothing else opened")
        XCTAssertNil(navigation.webView(view, createWebViewWith: WKWebViewConfiguration(), for: Action(.linkActivated, "https://ex.com"),
                                        windowFeatures: WKWindowFeatures()))
    }

    func testWebViewSettings() {
        let navigation = ChatMarkdownNavigation()
        let view = navigation.makeWebView()
        XCTAssertFalse(view.allowsLinkPreview)
        XCTAssertFalse(view.allowsBackForwardNavigationGestures)
        XCTAssertFalse(view.allowsMagnification)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(view.configuration.urlSchemeHandler(forURLScheme: "agentpad-doc"))
        XCTAssertTrue(view.navigationDelegate === navigation)
        XCTAssertTrue(view.uiDelegate === navigation)
    }

    func testMenuKeepsCopyingOnly() {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                   "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "no id", action: nil, keyEquivalent: ""))
        ChatWebView.trim(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.compactMap(\.identifier?.rawValue),
                       ["WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopy"])
    }

    // MARK: Corpus (document output recorded before F7)

    static let corpus = ##"""
# Title **bold**
## Sub _it_ and *em* ~~del~~

Para with `code <b>` and [link](https://ex.com/a__b__c) and https://auto.example/x. and
second line ![img](https://img.example/p.png "t") ![loc](file:///tmp/a.png) [rel](../x.md)
[js](javascript:alert(1)) [data](data:text/html,x) [f](file:///etc/hosts#top) <script>alert(1)</script>

- one
  - nested [ ] not a box
- [ ] todo
- [x] done
  continued
1. first
2) second

> quote **q**
>> deeper

| a | b |
|---|:-:|
| `x` | **y** |

```swift
let x = "<tag>"
```
~~~"><script>
z
~~~
---
***
"""##

    static let golden = ##"""
<h1>Title <strong>bold</strong></h1>
<h2>Sub <em>it</em> and <em>em</em> <del>del</del></h2>
<p>Para with <code>code &lt;b&gt;</code> and <a href="https://ex.com/a<strong>b</strong>c">link</a> and <a href="https://auto.example/x">https://auto.example/x</a>. and second line <img alt="img" src="https://img.example/p.png"> <img alt="loc" src="agentpad-doc://local/tmp/a.png"> <a href="../x.md">rel</a> <a href="#">js</a>) <a href="#">data</a> <a href="agentpad-doc://local/etc/hosts#top">f</a> &lt;script&gt;alert(1)&lt;/script&gt;</p>
<ul>
<li>one
<ul>
<li>nested [ ] not a box
</li></ul>
</li>
<li><input type="checkbox" disabled> todo
</li>
<li><input type="checkbox" checked disabled> done
<br>continued
</li></ul>
<ol>
<li>first
</li>
<li>second
</li></ol>
<blockquote><p>quote <strong>q</strong></p>
<blockquote><p>deeper</p></blockquote></blockquote>
<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td><code>x</code></td><td><strong>y</strong></td></tr></tbody></table>
<pre><code class="language-swift">let x = &quot;&lt;tag&gt;&quot;</code></pre>
<pre><code class="language-&quot;&gt;&lt;script&gt;">z</code></pre>
<hr>
<hr>
"""##
}
