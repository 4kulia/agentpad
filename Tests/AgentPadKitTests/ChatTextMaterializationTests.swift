import AppKit
import AgentPadQuietTestSupport
import QuartzCore
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatTextMaterializationTests: XCTestCase {
    override func setUp() async throws {
        AgentPadFonts.registerOnce()
        XCTAssertNotNil(NSFont(name: "Onest", size: 14))
        XCTAssertNotNil(NSFont(name: "JetBrainsMono-Regular", size: 12))
    }

    private func milliseconds<T>(_ work: () throws -> T) rethrows -> (T, Double) {
        let start = CACurrentMediaTime()
        let value = try work()
        return (value, (CACurrentMediaTime() - start) * 1_000)
    }

    func testProfileNativeTextMaterializationByRowType() throws {
        XCTAssertTrue(APQuietIsEnabled())
        let categories = ["one-line", "formatted-paragraph", "code-block", "structured", "formatted-link", "inline-code"]
        var samples: [[String: Any]] = []
        for (index, category) in categories.enumerated() {
            for iteration in 0..<12 {
                // Different source text forces a cold result even when rows in
                // the scrolling fixture happen to share the same paragraph.
                let source = ChatScrollContinuityTests.Fixture.message(index, root: nil).text
                    + "\n\nMaterialization \(UUID().uuidString)"
                let (_, parse) = milliseconds { MarkdownRenderer.chatDocument(source) }
                let (rendered, markdown) = milliseconds { ChatMarkdownText.attributed(source) }
                let (_, bridge) = milliseconds { NSAttributedString(rendered) }
                let (content, attributed) = milliseconds { ChatMentionText.attributed(source, addresses: []) }
                let (_, repeated) = milliseconds { ChatMentionText.attributed(source, addresses: []) }
                for width: CGFloat in [650, 310] {
                    let view = ChatMentionText.MessageTextView()
                    view.textContainerInset = .zero
                    let container = try XCTUnwrap(view.textContainer)
                    container.lineFragmentPadding = 0
                    container.widthTracksTextView = false
                    container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
                    let (_, storage) = milliseconds { view.textStorage?.setAttributedString(content) }
                    let layout = try XCTUnwrap(view.layoutManager)
                    let (bounds, textKit) = milliseconds {
                        layout.ensureLayout(for: container)
                        return layout.usedRect(for: container)
                    }
                    XCTAssertGreaterThan(bounds.height, 0)
                    samples.append(["category": category, "iteration": iteration, "width": width,
                        "parseMS": parse, "markdownIncludingParseMS": markdown, "bridgeMS": bridge,
                        "nativeAttributedMS": attributed, "repeatedNativeAttributedMS": repeated,
                        "textStorageMS": storage, "textKitLayoutMS": textKit, "height": bounds.height])
                }
            }
        }
        if let output = ProcessInfo.processInfo.environment["AGENTPAD_SCROLL_EVIDENCE"] {
            let url = URL(fileURLWithPath: output).appendingPathComponent("text-materialization.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        for category in categories {
            let rows = samples.filter { $0["category"] as? String == category }
            let keys = ["parseMS", "markdownIncludingParseMS", "bridgeMS", "nativeAttributedMS", "repeatedNativeAttributedMS", "textStorageMS", "textKitLayoutMS"]
            let averages = Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, rows.compactMap { $0[key] as? Double }.reduce(0, +) / Double(rows.count))
            })
            print("CHAT_TEXT_MATERIALIZATION category=\(category) averages=\(averages)")
        }
        XCTAssertNil(APQuietFailure())
    }

    func testRepeatedLongMarkdownMaterializationReusesImmutableContent() {
        XCTAssertTrue(APQuietIsEnabled())
        let source = ChatScrollContinuityTests.Fixture.message(1, root: nil).text + "\n\n" + UUID().uuidString
        // Initialize AppKit's shared font machinery before comparing the same
        // source's first construction with later row materializations.
        _ = ChatMentionText.attributed("Font preparation", addresses: [])
        let (expected, cold) = milliseconds { ChatMentionText.attributed(source, addresses: []) }
        let (_, warmTotal) = milliseconds {
            for _ in 0..<20 {
                let repeated = ChatMentionText.attributed(source, addresses: [])
                XCTAssertTrue(repeated === expected)
                XCTAssertEqual(repeated, expected)
            }
        }
        let warm = warmTotal / 20
        print("CHAT_TEXT_REUSE coldMS=\(cold) repeatedMS=\(warm)")
        XCTAssertFalse(expected is NSMutableAttributedString)
        XCTAssertNil(APQuietFailure())
    }

    func testTextContentFontMentionsAndAppearanceInvalidateReuse() throws {
        XCTAssertTrue(APQuietIsEnabled())
        let source = "**Hello** @anna [link](https://example.com) " + UUID().uuidString
        let original = ChatMentionText.attributed(source, addresses: ["anna"], fontSize: 14)
        let mentioned = (original.string as NSString).range(of: "@anna").location
        let link = (original.string as NSString).range(of: "link").location
        XCTAssertEqual(original.attribute(.toolTip, at: mentioned, effectiveRange: nil) as? String, "@anna")
        XCTAssertEqual(original.attribute(.link, at: link, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertTrue(try XCTUnwrap(original.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        let unmentioned = ChatMentionText.attributed(source, addresses: [], fontSize: 14)
        XCTAssertFalse(unmentioned === original)
        XCTAssertNil(unmentioned.attribute(.toolTip, at: mentioned, effectiveRange: nil))
        let smaller = ChatMentionText.attributed(source, addresses: ["anna"], fontSize: 13)
        XCTAssertFalse(smaller === original)
        XCTAssertEqual(try XCTUnwrap(smaller.attribute(.font, at: mentioned, effectiveRange: nil) as? NSFont).pointSize, 13)
        XCTAssertEqual(try XCTUnwrap(smaller.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).minimumLineHeight, 19.5)
        let edited = ChatMentionText.attributed(source + " edited", addresses: ["anna"], fontSize: 14)
        XCTAssertFalse(edited === original)
        XCTAssertEqual(edited.string, original.string + " edited")

        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)
        let light = ChatMentionText.attributed(source, addresses: ["anna"], fontSize: 14)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let dark = ChatMentionText.attributed(source, addresses: ["anna"], fontSize: 14)
        XCTAssertFalse(light === dark)
        XCTAssertEqual(light.string, dark.string)
        XCTAssertTrue(ChatMentionText.attributed(source, addresses: ["anna"], fontSize: 14) === dark)
        XCTAssertNil(APQuietFailure())
    }
}
