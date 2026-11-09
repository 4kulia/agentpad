import AppKit
import AgentPadQuietTestSupport
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeTextTests: XCTestCase {
    private typealias F = ChatTimelineW01

    override func setUp() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        _ = NSApplication.shared
        AgentPadFonts.registerOnce()
    }

    private func style() -> NativeTimelineSnapshot.Style {
        ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current, increasedContrast: false, alwaysShowTime: false)
    }

    private func cell(_ message: ChatMessage, width: CGFloat, selected: Bool = false,
                      builder: ChatTimelineSnapshotBuilder = ChatTimelineSnapshotBuilder(),
                      into cell: ChatNativeShellCell? = nil) throws -> ChatNativeShellCell {
        let snapshot = builder.build(F.input(messages: [F.content(message)], visuals: [F.visual(selected: selected)],
                                            root: width == 420 ? message.id : nil, style: style()))
        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
        let layout = ChatTimelineLayout(), size = ChatTimelineWidth(width, scale: 2)
        let plan = layout.plan(row, snapshot: snapshot, width: size)
        let result = cell ?? ChatNativeShellCell(kind: .message)
        result.frame = CGRect(x: 0, y: 0, width: width, height: plan.height)
        result.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan, content: layout.content(row, snapshot: snapshot, width: size))
        result.layoutSubtreeIfNeeded()
        return result
    }

    func testOrdinaryLongAndCodeBodiesUseTheExistingRendererAndNativeCopyAtBothWidths() throws {
        let cases = [
            ("ordinary", "A plain message 👩🏽‍💻 e\u{301}.", "A plain message 👩🏽‍💻 e\u{301}."),
            ("long", String(repeating: "**Bold** and *italic* words. ", count: 90), String(repeating: "Bold and italic words. ", count: 89) + "Bold and italic words."),
            ("code", "```swift\nlet value = 2\nprint(value)\n```", "let value = 2\nprint(value)")
        ]
        for width: CGFloat in [760, 420] {
            for (id, source, expected) in cases {
                var message = F.message(id); message.text = source
                let cell = try cell(message, width: width)
                XCTAssertEqual(cell.body.string, expected)
                let legacy = ChatMentionText.attributed(source, addresses: [], fontSize: width == 420 ? 13 : 14)
                let legacyDelegate = ChatMessageText.Coordinator()
                let legacyView = ChatMessageText.makeView(delegate: legacyDelegate)
                legacyView.textStorage?.setAttributedString(legacy)
                legacyView.textContainer?.containerSize = cell.body.textContainer!.containerSize
                legacyView.layoutManager?.ensureLayout(for: legacyView.textContainer!)
                cell.body.layoutManager?.ensureLayout(for: cell.body.textContainer!)
                XCTAssertEqual(cell.body.textStorage, legacyView.textStorage, "The native cell must use every legacy text attribute after TextKit normalization")
                XCTAssertTrue(cell.body.isSelectable); XCTAssertFalse(cell.body.isEditable); XCTAssertFalse(cell.body.canBecomeKeyView)
                XCTAssertTrue(cell.placeholder.isHidden)
                let manager = try XCTUnwrap(cell.body.layoutManager), container = try XCTUnwrap(cell.body.textContainer)
                manager.ensureLayout(for: container)
                XCTAssertEqual(try XCTUnwrap(cell.plan).body.height, ceil(manager.usedRect(for: container).height))
                XCTAssertEqual(cell.body.frame.minX, width == 420 ? 62 : 68)
                XCTAssertEqual(cell.body.frame.width, width == 420 ? 340 : 668)
                cell.body.setSelectedRange(NSRange(location: 0, length: (expected as NSString).length))
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                XCTAssertTrue(cell.body.writeSelection(to: board, types: cell.body.writablePasteboardTypes))
                XCTAssertEqual(board.string(forType: .string), expected)
            }
        }
    }

    func testDeletedAndLoadingStayNonselectableLabelsAtBothWidths() throws {
        for width: CGFloat in [760, 420] {
            for deleted in [false, true] {
                var message = F.message(deleted ? "deleted" : "loading")
                message.text = "Private original body must not reach the cell"
                if deleted { message.deletedAt = "2026-10-08T12:00:00Z" } else { message.hasMutable = false }
                let cell = try cell(message, width: width)
                XCTAssertTrue(cell.body.isHidden); XCTAssertFalse(cell.body.isSelectable)
                XCTAssertEqual(cell.body.string, "")
                XCTAssertFalse(cell.placeholder.isHidden)
                XCTAssertEqual(cell.placeholder.text.string, deleted ? "Message deleted" : "Loading…")
                let font = try XCTUnwrap(cell.placeholder.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.fontDescriptor.symbolicTraits.contains(.italic), deleted)
                XCTAssertEqual(font.pointSize, NSFont.systemFontSize)
            }
        }
    }

    func testFrozenW00BodyTextAndInsetsWithoutRendering() throws {
        guard ProcessInfo.processInfo.environment[ChatTimelineReferencePaths.environmentKey] != nil else {
            throw XCTSkip("Set the configurable W00 reference root to check frozen text geometry")
        }
        let root = try ChatTimelineReferencePaths.configuredRoot()
        let cases = ["plain", "long-markdown", "headings", "code", "lists", "quote-table-rule", "links-mentions",
                     "literal-media-html-nul", "unicode-wrap", "grouped", "time-preference"]
        for width: CGFloat in [760, 420] {
            for name in cases {
                let id = "\(name)-\(Int(width))-light"
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("captures/\(id).json"))) as? [String: Any])
                let messages = try JSONDecoder().decode([ChatMessage].self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(json["fixtureValues"])))
                let expected = try XCTUnwrap((json["nativeTexts"] as? [[String: Any]])?.first)
                let expectedFrame = NSRectFromString(try XCTUnwrap(expected["frame"] as? String))
                let message = try XCTUnwrap(messages.first)
                let snapshot = ChatTimelineSnapshotBuilder().build(F.input(messages: [F.content(message)],
                    root: width == 420 ? message.id : nil, style: style()))
                let source = try XCTUnwrap(snapshot.rows.first { $0.messageID == message.id })
                guard case .message(let payload) = source.payload else { return XCTFail("Missing message") }
                let row = NativeTimelineSnapshot.Row(id: source.id, contentRevision: source.contentRevision, layoutRevision: source.layoutRevision,
                    payload: .message(.init(content: payload.content, startsGroup: name != "grouped", inThread: width == 420)), visual: source.visual)
                let engine = ChatTimelineLayout(), size = ChatTimelineWidth(width, scale: 2)
                let content = engine.content(row, snapshot: snapshot, width: size)
                XCTAssertEqual(content.body.string, expected["text"] as? String, id)
                let body = engine.plan(row, snapshot: snapshot, width: size).body.offsetBy(dx: 0, dy: 24)
                XCTAssertEqual(body.origin, expectedFrame.origin, id)
                XCTAssertEqual(body.width, expectedFrame.width, id)
                // W00 has process-dependent font fallback and SwiftUI rounds
                // native view heights to backing pixels. Height/line-break
                // parity belongs to the paired bitmap gate; the layout plan
                // uses the specification's ceil(TextKit.usedRect.height).
            }
        }
    }

    func testMentionsAndCheckedLinkDelegatePreserveSelectableCanonicalText() throws {
        let source = "@anna @ANNABEL @BORIS `@anna` [web](https://example.com) [mail](mailto:hello@example.com) [refused](javascript:alert(1))"
        let expected = "@anna @ANNABEL @BORIS @anna web mail [refused](javascript:alert(1))"
        for width: CGFloat in [760, 420] {
            let rendered = ChatMessageText.attributed(source, addresses: ["anna", "boris"], fontSize: width == 420 ? 13 : 14)
            XCTAssertEqual(rendered.string, expected)
            var tooltips: [String] = [], links: [String] = []
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
                if let tip = attributes[.toolTip] as? String { tooltips.append(tip) }
                if let link = attributes[.link] as? URL { links.append(link.absoluteString) }
            }
            XCTAssertEqual(tooltips, ["@anna", "@boris", "@anna"])
            XCTAssertEqual(links, ["https://example.com", "mailto:hello@example.com"])
            let delegate = ChatMessageText.Coordinator(), view = ChatMessageText.makeView(delegate: ChatMessageText.Coordinator())
            view.delegate = delegate
            view.textContainer?.containerSize = CGSize(width: width == 420 ? 340 : 668, height: CGFloat.greatestFiniteMagnitude)
            view.textStorage?.setAttributedString(rendered)
            var opened: [String] = []
            delegate.open = { opened.append($0.absoluteString) }
            let urls = ["https://example.com", "mailto:hello@example.com", "javascript:alert(1)", "file:///tmp/fixture", "https://user:pass@example.com"]
            for url in urls { XCTAssertTrue(delegate.textView(view, clickedOnLink: try XCTUnwrap(URL(string: url)), at: 0)) }
            XCTAssertEqual(opened, ["https://example.com", "mailto:hello@example.com"])
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            view.setSelectedRange(NSRange(location: 0, length: 5))
            XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
            XCTAssertEqual(board.string(forType: .string), "@anna")
        }
    }

    func testSelectionSurvivesRepaintAndWidthChangeAndDoesNotTransferToAnotherMessage() throws {
        let builder = ChatTimelineSnapshotBuilder()
        var message = F.message("a"); message.text = "Select this message's own words 👩🏽‍💻."
        let first = try cell(message, width: 760, builder: builder)
        let storage = first.body.textStorage
        first.body.layoutManager?.ensureLayout(for: first.body.textContainer!)
        let normalized = NSAttributedString(attributedString: try XCTUnwrap(storage))
        let range = NSRange(location: 7, length: 4)
        first.body.setSelectedRange(range)
        _ = try cell(message, width: 760, selected: true, builder: builder, into: first)
        XCTAssertTrue(first.body.textStorage === storage); XCTAssertEqual(first.body.selectedRange(), range)
        XCTAssertEqual(first.body.textStorage, normalized, "A selection repaint cannot rewrite TextKit's normalized attributes")
        _ = try cell(message, width: 700, selected: true, builder: builder, into: first)
        XCTAssertTrue(first.body.textStorage === storage); XCTAssertEqual(first.body.selectedRange(), range)
        var other = message; other.messageId = "b"
        _ = try cell(other, width: 700, builder: builder, into: first)
        XCTAssertEqual(first.binding?.id.kind, .message("b"))
        XCTAssertEqual(first.body.selectedRange().length, 0)
        let separate = try cell(message, width: 700)
        separate.body.setSelectedRange(range)
        XCTAssertEqual(first.body.selectedRange().length, 0, "Selection belongs to one message text view")
    }

    func testStructuralRowsKeepMessageIdentitySeparateAndDispatchCurrentPaneActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w03-structure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for root in [nil, "root"] as [String?] {
            let model = ChatTimelineW01Model(directory: directory)
            model.threadRoot = root
            model.feed.hasOlder = true; model.feed.earlierUnread = root == nil; model.threadHasEarlier = true
            model.feed.messages = [F.message("root"), F.message("reply", seq: 2, root: root)]
            model.feed.unreadID = "reply"; model.threadUnreadID = "reply"
            let adapter = ChatTimelineAdapter()
            let snapshot = adapter.snapshot(model: model, root: root, members: F.members, mentionable: [], me: model.key.accountId,
                archived: false, ownerModel: nil, style: style())
            let engine = ChatTimelineLayout(), width = ChatTimelineWidth(root == nil ? 760 : 420, scale: 2)
            let cells = snapshot.rows.map { row in
                let cell = ChatNativeShellCell(kind: ChatNativeShellKind(row.payload))
                cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: engine.plan(row, snapshot: snapshot, width: width),
                               content: engine.content(row, snapshot: snapshot, width: width), actions: adapter.actions)
                cell.layoutSubtreeIfNeeded()
                return cell
            }
            XCTAssertEqual(snapshot.messageIDs, ["root", "reply"])
            let older = try XCTUnwrap(cells.first { $0.binding?.id.kind == .olderControl })
            XCTAssertEqual(older.actionButton.title, root == nil ? "Load earlier messages" : "Earlier replies")
            XCTAssertEqual(older.actionButton.accessibilityRole(), .link)
            XCTAssertTrue(older.actionButton.accessibilityPerformPress())
            let unread = try XCTUnwrap(cells.first { $0.binding?.id.kind == .unreadBoundary("reply") })
            XCTAssertEqual(unread.placeholder.text.string, "New messages")
            XCTAssertEqual(unread.plan?.rules.count, 2)
            XCTAssertEqual(unread.actionButton.title, "Mark as read")
            XCTAssertEqual(unread.actionButton.accessibilityRole(), .button)
            XCTAssertTrue(unread.actionButton.accessibilityPerformPress())
            XCTAssertEqual(model.events, ["older:\(root == nil ? "feed" : "thread")", "read:\(root ?? "feed"):true"])
            XCTAssertEqual(model.readingCalls, [])
            XCTAssertEqual(cells.first?.plan?.height, 16); XCTAssertEqual(cells.last?.plan?.height, 20)
            let day = try XCTUnwrap(cells.first { if case .dayBoundary = $0.binding?.id.kind { true } else { false } })
            XCTAssertEqual(day.plan?.rules.count, 2); XCTAssertGreaterThan(day.plan?.capsule.width ?? 0, 0)
            XCTAssertTrue(cells.filter { $0.binding?.id.kind != .message("root") && $0.binding?.id.kind != .message("reply") }.allSatisfy { !$0.body.isSelectable })
            adapter.invalidate()
            older.actionButton.performClick(nil); unread.actionButton.performClick(nil)
            XCTAssertEqual(model.events.count, 2, "Disposed pane controls cannot act on a replacement conversation")
            await model.service.disconnect()
        }
    }
}
