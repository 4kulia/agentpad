import AppKit
import AgentPadQuietTestSupport
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeScrollTests: XCTestCase {
    @MainActor private final class Mounted {
        let model: ChatScrollFixture
        let adapter = ChatTimelineAdapter()
        let coordinator = NativeChatTimelineCoordinator()
        let host: ChatQuietHost
        let directory: URL
        var controller: ChatTimelineScrollController { coordinator.scrollController }
        var scroll: NSScrollView { coordinator.scrollView }
        var table: ChatNativeTableView { coordinator.tableView }
        init(root: String?, saved: ChatScrollPosition? = nil) throws {
            XCTAssertTrue(APQuietIsEnabled())
            ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("w04-\(UUID())")
            model = ChatScrollFixture(root: root, directory: directory)
            if let saved { model.positions[root ?? ""] = saved }
            host = ChatQuietHost(view: coordinator.scrollView, dark: false, width: root == nil ? 760 : 420, height: 600)
            ChatScrollAppKitSettings.apply(to: scroll)
            scroll.tile(); apply(); settle()
        }
        func snapshot() -> NativeTimelineSnapshot {
            let result = adapter.snapshot(model: model, root: model.root, members: [], mentionable: [],
                me: model.key.accountId, archived: false, ownerModel: nil,
                style: ChatTimelineAdapter.style(scale: 2, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian),
                    increasedContrast: false, alwaysShowTime: false))
            coordinator.actions = adapter.actions
            return result
        }
        func apply() { _ = coordinator.update(snapshot(), width: scroll.contentSize.width) }
        func settle() {
            for _ in 0..<5 {
                scroll.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        func position(_ id: String, offset: CGFloat = 100.25) throws {
            controller.stopFollowing()
            let frame = try XCTUnwrap(controller.bodyFrame(id))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: frame.minY - offset))
            scroll.reflectScrolledClipView(scroll.contentView); settle()
        }
        func y(_ id: String) throws -> CGFloat {
            try XCTUnwrap(controller.bodyFrame(id)).minY - scroll.contentView.bounds.minY
        }
        func characterY(_ id: String, character: Int) throws -> CGFloat {
            let index = try XCTUnwrap(coordinator.messageIndex(id))
            table.layoutSubtreeIfNeeded()
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChatNativeShellCell)
            cell.layoutSubtreeIfNeeded()
            let manager = try XCTUnwrap(cell.body.layoutManager)
            let container = try XCTUnwrap(cell.body.textContainer)
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndexForCharacter(at: character)
            return cell.body.convert(CGPoint(x: 0, y: manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY), to: scroll).y
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            APQuietSendEvent(event, host.window)
        }
        func generationAtFirstMovement(_ action: () throws -> Void) rethrows -> UInt64? {
            let origin = scroll.contentView.bounds.minY
            var generation: UInt64?
            let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [self] _ in
                MainActor.assumeIsolated {
                    if scroll.contentView.bounds.minY != origin, generation == nil { generation = controller.inputGeneration }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try action()
            return generation
        }
        func preparePage(reveal: String? = nil) throws -> NativeChatTimelineCoordinator.Prepared {
            model.loadOlder()
            model.revealMessageID = reveal
            let request = try XCTUnwrap(coordinator.begin(snapshot(), width: scroll.contentSize.width))
            return try XCTUnwrap(coordinator.prepare(request))
        }
        func close() {
            coordinator.dispose(); host.close()
            try? FileManager.default.removeItem(at: directory)
            XCTAssertNil(APQuietFailure())
        }
    }

    func testTallBodyPreservesReadingCharacterAcrossWidthTextAndPrepend() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            let index = try XCTUnwrap(m.model.feed.messages.firstIndex { $0.id == "fixture-185" })
            let paragraph = "A reading paragraph with enough words to wrap across the changing pane width. "
            m.model.feed.messages[index].text = (0..<50).map { "Paragraph \($0). " + String(repeating: paragraph, count: 3) }.joined(separator: "\n\n")
            m.apply()
            let text = ChatMentionText.attributed(m.model.feed.messages[index].text, addresses: [], fontSize: root == nil ? 14 : 13).string as NSString
            let character = text.range(of: "Paragraph 24.").location
            XCTAssertNotEqual(character, NSNotFound)
            try m.position("fixture-185")
            let glyph = try m.characterY("fixture-185", character: character)
            m.scroll.contentView.scroll(to: CGPoint(x: 0, y: m.scroll.contentView.bounds.minY + glyph + 0.25))
            m.settle()
            let before = try m.characterY("fixture-185", character: character)
            XCTAssertEqual(before, -0.25, accuracy: 0.75)
            let originalWidth = m.scroll.frame.width
            for width in [originalWidth - 80, originalWidth + 30, originalWidth] {
                m.controller.transaction {
                    m.host.window.setContentSize(CGSize(width: width, height: 600))
                    m.scroll.tile(); m.apply()
                }
                m.settle()
                XCTAssertEqual(try m.characterY("fixture-185", character: character), before, accuracy: 0.75,
                    "Preserve the reading glyph, not the tall row's top")
                XCTAssertFalse(m.controller.following)
            }
            let prefix = "A newly hydrated paragraph above the reading position.\n\n"
            m.model.feed.messages[index].text = prefix + m.model.feed.messages[index].text
            m.apply(); m.settle()
            let rendered = ChatMentionText.attributed(m.model.feed.messages[index].text, addresses: [], fontSize: root == nil ? 14 : 13).string as NSString
            let shifted = rendered.range(of: "Paragraph 24.").location
            XCTAssertEqual(try m.characterY("fixture-185", character: shifted), before, accuracy: 0.75)
            m.model.loadOlder(); m.apply(); m.settle()
            XCTAssertEqual(try m.characterY("fixture-185", character: shifted), before, accuracy: 0.75)
        }
    }

    func testDeletedAnchorUsesOldSuccessorThenPredecessorOffsetAndBoundaryClamp() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185", offset: 8.25)
            let successor = try m.y("fixture-186")
            m.model.feed.messages.removeAll { $0.id == "fixture-185" }
            m.apply(); m.settle()
            XCTAssertEqual(try m.y("fixture-186"), successor, accuracy: 0.75)
            try m.position("fixture-350", offset: 8.25)
            let previous = try m.y("fixture-349")
            m.model.feed.messages.removeAll { ($0.seq ?? 0) >= 351 }
            m.apply(); m.settle()
            let desired = try XCTUnwrap(m.controller.bodyFrame("fixture-349")).minY - previous
            let maximum = max(0, m.table.bounds.height - m.scroll.contentView.bounds.height)
            XCTAssertEqual(m.scroll.contentView.bounds.minY, min(maximum, max(0, desired)), accuracy: 0.75)
            XCTAssertEqual(m.controller.lastClamp, min(maximum, max(0, desired)) - desired, accuracy: 0.75)
            m.controller.scrollTo(messageID: "fixture-40", alignment: .center)
            XCTAssertEqual(m.scroll.contentView.bounds.minY, 0, accuracy: 0.75)
            m.controller.followBottom()
            XCTAssertEqual(m.scroll.contentView.bounds.maxY, m.table.bounds.maxY, accuracy: 0.75)
            m.model.feed.messages = []; m.apply(); m.settle()
            XCTAssertEqual(m.scroll.contentView.bounds.minY, 0, accuracy: 0.75)
        }
    }

    func testSavedPositionRetainsKnownHistoryAndNewArrivals() throws {
        for root: String? in [nil, "fixture-root"] {
            var saved = ChatScrollPosition()
            _ = saved.update((40..<357).map { ChatScrollFixture.message($0, root: root) }, me: "fixture-me")
            saved.anchor = "fixture-185"
            saved.unseen = ["fixture-300"]
            let m = try Mounted(root: root, saved: saved); defer { m.close() }
            XCTAssertEqual(m.controller.position.unseen, ["fixture-300", "fixture-357"])
            // Saved positions restore the legacy message wrapper. The paired
            // W09 check observes its grouped body three points below that top.
            let row = try XCTUnwrap(m.coordinator.messageIndex("fixture-185"))
            XCTAssertEqual(m.table.rect(ofRow: row).minY, m.scroll.contentView.bounds.minY, accuracy: 0.75)
            XCTAssertEqual(try m.y("fixture-185"), 3, accuracy: 0.75)
            XCTAssertFalse(m.controller.following)
            m.model.feed.messages.append(ChatScrollFixture.message(360, root: root))
            m.apply(); m.settle()
            XCTAssertEqual(m.controller.position.unseen, ["fixture-300", "fixture-357", "fixture-360"])
            m.controller.jumpToLatest(); m.settle()
            XCTAssertTrue(m.controller.position.unseen.isEmpty)
            XCTAssertTrue(m.controller.following)
        }
    }

    func testAccessibilityScrollerRetainsNativeStylesAndWidthContinuity() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185")
            let before = try m.y("fixture-185")
            for style: NSScroller.Style in [.overlay, .legacy, .overlay] {
                m.scroll.scrollerStyle = style; m.scroll.tile(); m.settle()
                XCTAssertEqual(m.scroll.scrollerStyle, style)
                XCTAssertEqual(m.scroll.verticalScroller?.scrollerStyle, style)
                XCTAssertTrue(m.scroll.verticalScroller is ChatTimelineScroller)
                let index = try XCTUnwrap(m.coordinator.messageIndex("fixture-185"))
                let plan = try XCTUnwrap(m.coordinator.layoutPlan(at: index))
                XCTAssertEqual(plan.width.points, m.scroll.contentSize.width, accuracy: 0.5, "style=\(style.rawValue) clip=\(m.scroll.contentView.bounds.width)")
                XCTAssertEqual(try m.y("fixture-185"), before, accuracy: 0.75)
                XCTAssertFalse(m.controller.following)
            }
        }
    }

    func testAccessibilityValueAndActionsCancelBeforeScrollAndDelayedPage() throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }
        func perform(_ route: String, on scroller: NSScroller) -> Bool? {
            switch route {
            case "value": scroller.setAccessibilityValue(NSNumber(value: 0.43)); return nil
            case "increment": return scroller.accessibilityPerformIncrement()
            default: return scroller.accessibilityPerformDecrement()
            }
        }
        for root: String? in [nil, "fixture-root"] {
            // Some supported AppKit versions return false for increment and
            // decrement even on an ordinary attached NSScroller. Preserve that
            // native result; do not manufacture a new scrolling operation.
            let control = try Mounted(root: root); defer { control.close() }
            control.scroll.verticalScroller = NSScroller()
            control.scroll.tile(); control.apply(); control.settle()
            let stock = try XCTUnwrap(control.scroll.accessibilityVerticalScrollBar() as? NSScroller)
            for route in ["value", "increment", "decrement"] {
                try control.position("fixture-185")
                let stockOrigin = control.scroll.contentView.bounds.minY
                let expectedResult = perform(route, on: stock); control.settle()
                let nativeMoves = control.scroll.contentView.bounds.minY != stockOrigin
                print("W04_AX_STOCK \(root ?? "channel") route=\(route) enhanced=\(String(describing: NSApp.accessibilityAttributeValue(enhancedUI))) result=\(String(describing: expectedResult)) moves=\(nativeMoves) role=\(String(describing: stock.accessibilityRole())) enabled=\(stock.isAccessibilityEnabled())")
                if route == "value" { XCTAssertTrue(nativeMoves, "The control must exercise a real AXValue scroll") }
                for pending in [false, true] {
                    let m = try Mounted(root: root); defer { m.close() }
                    try m.position("fixture-185")
                    if pending {
                        m.model.revealMessageID = "fixture-10"; m.apply()
                    } else { m.controller.reveal(messageID: "fixture-185") }
                    let page = try m.preparePage(reveal: pending ? "fixture-10" : "fixture-60")
                    let exposed = try XCTUnwrap(m.scroll.accessibilityVerticalScrollBar() as? NSScroller)
                    XCTAssertTrue(exposed === m.scroll.verticalScroller, "Exercise the exposed real native scrollbar")
                    let generation = m.controller.inputGeneration
                    let origin = m.scroll.contentView.bounds.minY
                    var generationAtMovement: UInt64?
                    let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                        object: m.scroll.contentView, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            if m.scroll.contentView.bounds.minY != origin, generationAtMovement == nil {
                                generationAtMovement = m.controller.inputGeneration
                            }
                        }
                    }
                    XCTAssertEqual(perform(route, on: exposed), expectedResult)
                    m.settle()
                    NotificationCenter.default.removeObserver(observer)
                    XCTAssertEqual(m.scroll.contentView.bounds.minY != origin, nativeMoves, "Keep the stock native action: \(route)")
                    XCTAssertGreaterThan(m.controller.inputGeneration, generation, "Every actual AX entry cancels pending navigation")
                    if nativeMoves {
                        XCTAssertGreaterThan(try XCTUnwrap(generationAtMovement), generation, "Cancel before the first bounds movement")
                    }
                    let anchor = try XCTUnwrap(m.controller.position.anchor)
                    let before = try m.y(anchor)
                    XCTAssertTrue(m.coordinator.commit(page)); m.settle()
                    XCTAssertEqual(try m.y(anchor), before, accuracy: 0.75, "Delayed page/reveal must not snap back after \(route)")
                    XCTAssertFalse(m.controller.following)
                }
            }
        }
    }

    func testKeyboardAndScrollerCancelPendingNavigationBeforeNativeDispatch() throws {
        let keys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (116, "\u{f72c}", []), (121, "\u{f72d}", []), (115, "\u{f729}", []), (119, "\u{f72b}", []),
            (49, " ", []), (49, " ", [.shift]), (126, "\u{f700}", [.option]), (125, "\u{f701}", [.option]),
            (126, "\u{f700}", [.command]), (125, "\u{f701}", [.command])]
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            for (code, characters, modifiers) in keys {
                for pending in [false, true] {
                    try m.position("fixture-185")
                    m.model.revealMessageID = nil; m.apply()
                    if pending { m.model.revealMessageID = "fixture-10"; m.apply() }
                    else { m.controller.reveal(messageID: "fixture-185") }
                    let page = try m.preparePage(reveal: pending ? "fixture-10" : "fixture-60")
                    XCTAssertTrue(m.host.window.makeFirstResponder(m.table))
                    let generation = m.controller.inputGeneration
                    let origin = m.scroll.contentView.bounds.minY
                    let atMovement = try m.generationAtFirstMovement {
                        try m.key(code, characters, modifiers: modifiers); m.settle()
                    }
                    XCTAssertGreaterThan(m.controller.inputGeneration, generation)
                    if code == 116 || code == 121 {
                        XCTAssertGreaterThan(try XCTUnwrap(atMovement), generation, "Cancel before native paging moves the clip")
                    }
                    if code == 116 { XCTAssertLessThan(m.scroll.contentView.bounds.minY, origin) }
                    if code == 121 { XCTAssertGreaterThan(m.scroll.contentView.bounds.minY, origin) }
                    let id = try XCTUnwrap(m.controller.position.anchor)
                    let before = try m.y(id)
                    XCTAssertTrue(m.coordinator.commit(page)); m.settle()
                    XCTAssertEqual(try m.y(id), before, accuracy: 0.75)
                    // Avoid duplicate IDs on the next prepared fixture page.
                    m.model.feed.messages.removeAll { ($0.seq ?? 0) < 41 }; m.apply()
                }
            }
            try m.position("fixture-185")
            let page = try m.preparePage(reveal: "fixture-60")
            let scroller = try XCTUnwrap(m.scroll.verticalScroller)
            let knob = scroller.rect(for: .knob)
            let start = scroller.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
            let end = CGPoint(x: start.x, y: start.y - 60)
            func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.host.window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let generation = m.controller.inputGeneration
            let origin = m.scroll.contentView.bounds.minY
            let atMovement = try m.generationAtFirstMovement {
                NSApp.postEvent(try event(.leftMouseUp, point: end), atStart: true)
                NSApp.postEvent(try event(.leftMouseDragged, point: end), atStart: true)
                APQuietSendEvent(try event(.leftMouseDown, point: start), m.host.window)
                m.settle()
            }
            XCTAssertGreaterThan(m.controller.inputGeneration, generation)
            XCTAssertGreaterThan(try XCTUnwrap(atMovement), generation, "Cancel before native tracking moves the clip")
            XCTAssertNotEqual(m.scroll.contentView.bounds.minY, origin)
            let id = try XCTUnwrap(m.controller.position.anchor), before = try m.y(id)
            XCTAssertTrue(m.coordinator.commit(page)); m.settle()
            XCTAssertEqual(try m.y(id), before, accuracy: 0.75)
            scroller.setAccessibilityValue(NSNumber(value: 1))
            m.settle()
            XCTAssertTrue(m.controller.atBottom)
            XCTAssertTrue(m.controller.following, "A native scroll back to bottom reattaches after scroller tracking ends")
        }
    }

    func testNavigationTokensReturnFocusAndIndependentPanes() throws {
        let feed = try Mounted(root: nil), thread = try Mounted(root: "fixture-root")
        defer { feed.close(); thread.close() }
        // Place both native scroll views in one window, as in the split pane.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1180, height: 600))
        thread.host.window.contentView = nil
        feed.host.window.contentView = container
        feed.host.window.setContentSize(container.frame.size)
        container.addSubview(feed.scroll); container.addSubview(thread.scroll)
        feed.scroll.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
        thread.scroll.frame = CGRect(x: 760, y: 0, width: 420, height: 600)
        feed.scroll.tile(); thread.scroll.tile(); feed.apply(); thread.apply()
        for m in [feed, thread] { try m.position("fixture-185") }
        let threadY = thread.scroll.contentView.bounds.minY
        let threadInput = thread.controller.inputGeneration
        let page = try thread.preparePage(reveal: "fixture-60")
        XCTAssertTrue(feed.host.window.makeFirstResponder(feed.table))
        try feed.key(125, "\u{f701}")
        XCTAssertEqual(feed.controller.selectedID, "fixture-40")
        XCTAssertEqual(thread.controller.inputGeneration, threadInput)
        XCTAssertEqual(thread.scroll.contentView.bounds.minY, threadY)
        XCTAssertTrue(thread.coordinator.commit(page))
        XCTAssertEqual(thread.controller.selectedID, "fixture-60", "Another pane's input must not cancel this command")
        feed.model.revealMessageID = "fixture-185"; feed.apply()
        XCTAssertEqual(feed.controller.selectedID, "fixture-185")
        let centered = try feed.y("fixture-185")
        feed.controller.userWillScroll()
        feed.scroll.contentView.scroll(to: CGPoint(x: 0, y: feed.scroll.contentView.bounds.minY + 70))
        feed.model.feed.unreadID = "fixture-100"
        feed.apply()
        XCTAssertEqual(try feed.y("fixture-185"), centered - 70, accuracy: 0.75, "Same token is consumed once")
        feed.adapter.builder.request(.reveal("fixture-185")); feed.apply()
        XCTAssertEqual(try feed.y("fixture-185"), centered, accuracy: 0.75, "A new token can reveal the same ID")
        let beforeFocus = feed.scroll.contentView.bounds.minY
        feed.model.focusedMessageID = "fixture-185"; feed.apply()
        XCTAssertEqual(feed.scroll.contentView.bounds.minY, beforeFocus, accuracy: 0.75)
        XCTAssertTrue(feed.host.window.firstResponder === feed.table)
        feed.model.revealMessageID = nil
        var saved = feed.controller.position
        saved.atBottom = false; saved.anchor = "fixture-100"
        feed.model.positions[""] = saved
        feed.model.readingPositionRestored += 1; feed.apply()
        // Actual legacy restoration starts at this message's unread wrapper,
        // not at its body (paired W09 restore coverage checks both frames).
        let unread = try XCTUnwrap(feed.coordinator.rows.firstIndex { $0.id.kind == .unreadBoundary("fixture-100") })
        XCTAssertEqual(feed.table.rect(ofRow: unread).minY, feed.scroll.contentView.bounds.minY, accuracy: 0.75)
        feed.model.revealMessageID = "fixture-185"; feed.apply()
        let jump = try XCTUnwrap(feed.adapter.actions?.jumpToLatest)
        jump(); feed.settle()
        XCTAssertTrue(feed.controller.following); XCTAssertTrue(feed.controller.atBottom)
        XCTAssertNil(feed.model.revealMessageID)
        XCTAssertFalse(APQuietWindowHasOSFocus(feed.host.window))
    }

    func testDelayedPageKeepsNewerExplicitNavigationAndReplacedPaneRejectsCompletion() throws {
        let m = try Mounted(root: nil); defer { m.close() }
        try m.position("fixture-185")
        let page = try m.preparePage(reveal: "fixture-60")
        m.controller.reveal(messageID: "fixture-190")
        let before = try m.y("fixture-190")
        XCTAssertTrue(m.coordinator.commit(page)); m.settle()
        XCTAssertEqual(try m.y("fixture-190"), before, accuracy: 0.75)
        XCTAssertEqual(m.controller.selectedID, "fixture-190")
        let request = try XCTUnwrap(m.coordinator.begin(m.snapshot(), width: m.scroll.contentSize.width))
        let obsolete = try XCTUnwrap(m.coordinator.prepare(request))
        m.model.root = "replacement"; m.model.threadRoot = "replacement"
        m.apply()
        XCTAssertFalse(m.coordinator.commit(obsolete))
        XCTAssertEqual(m.coordinator.snapshot?.conversation.root, "replacement")
        XCTAssertEqual(m.table.numberOfSelectedRows, 0)
    }

    func testNavigationSelectionAccessibilityFollowsConfigurationAndReuse() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            m.model.revealMessageID = "fixture-185"; m.apply(); m.settle()
            let index = try XCTUnwrap(m.coordinator.messageIndex("fixture-185"))
            let cell = try XCTUnwrap(m.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChatNativeShellCell)
            XCTAssertTrue(cell.isAccessibilitySelected(), "A model reveal exposes its selected cell to accessibility")

            m.model.revealMessageID = nil
            let snapshot = m.snapshot()
            let width = ChatTimelineWidth(m.scroll.contentSize.width, scale: snapshot.style.metrics.scale)
            func configure(_ id: String) throws {
                let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == id })
                cell.configure(row: row, epoch: snapshot.presentationEpoch,
                    plan: m.coordinator.layoutEngine.plan(row, snapshot: snapshot, width: width),
                    content: m.coordinator.layoutEngine.content(row, snapshot: snapshot, width: width))
            }
            cell.setNavigationSelected(false)
            cell.setNavigationSelected(true)
            XCTAssertTrue(cell.isAccessibilitySelected())
            try configure("fixture-185")
            XCTAssertFalse(cell.isAccessibilitySelected(), "Reconfiguring the same row clears its previous selection")
            cell.setNavigationSelected(true)
            try configure("fixture-190")
            XCTAssertFalse(cell.isAccessibilitySelected(), "A reused cell cannot expose the previous message's selection")
            cell.setNavigationSelected(true)
            cell.unbind()
            XCTAssertFalse(cell.isAccessibilitySelected(), "An unbound cell clears accessibility selection")
        }
    }

    func testUnloadedRevealWaitsForItsMessageAndReturnCannotOverrideReveal() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185")
            m.model.revealMessageID = "fixture-10"; m.apply()
            XCTAssertNil(m.controller.selectedID)
            let before = try m.y("fixture-185")
            XCTAssertEqual(before, 100.25, accuracy: 0.75)
            m.model.loadOlder(); m.apply(); m.settle()
            XCTAssertEqual(m.controller.selectedID, "fixture-10")
            let target = try XCTUnwrap(m.controller.bodyFrame("fixture-10"))
            XCTAssertEqual(target.midY - m.scroll.contentView.bounds.minY, 300, accuracy: 0.75)
            var saved = m.controller.position; saved.atBottom = false; saved.anchor = "fixture-185"
            m.model.positions[root ?? ""] = saved
            m.model.readingPositionRestored += 1; m.apply()
            XCTAssertEqual(target.midY - m.scroll.contentView.bounds.minY, 300, accuracy: 0.75)
            XCTAssertFalse(m.controller.following)
        }
    }

    func testUnloadedRevealCannotOverrideNewerLoadedEdit() throws {
        try unloadedRevealAfterLoadedEdit(userScrolls: false)
    }

    func testUnloadedRevealCannotOverrideUserScrollAfterNewerLoadedEdit() throws {
        try unloadedRevealAfterLoadedEdit(userScrolls: true)
    }

    private func unloadedRevealAfterLoadedEdit(userScrolls: Bool) throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185")
            m.model.revealMessageID = "fixture-10"; m.apply()
            XCTAssertNil(m.controller.bodyFrame("fixture-10"))
            XCTAssertNil(m.controller.selectedID)

            let edited = try XCTUnwrap(m.model.message("fixture-190"))
            m.model.editing = .init(messageId: edited.id, root: root, text: edited.text, revision: 1, message: edited)
            m.apply(); m.settle()
            let center = try XCTUnwrap(m.controller.bodyFrame(edited.id)).midY - m.scroll.contentView.bounds.minY
            XCTAssertEqual(center, m.scroll.contentView.bounds.height / 2, accuracy: 0.75)

            // Prepare A's arrival before input, just like an in-flight older page.
            let page = try m.preparePage(reveal: "fixture-10")
            if userScrolls {
                let scroller = try XCTUnwrap(m.scroll.accessibilityVerticalScrollBar() as? NSScroller)
                let input = m.controller.inputGeneration
                let origin = m.scroll.contentView.bounds.minY
                scroller.setAccessibilityValue(NSNumber(value: scroller.doubleValue + 0.01)); m.settle()
                XCTAssertGreaterThan(m.controller.inputGeneration, input)
                XCTAssertGreaterThan(m.scroll.contentView.bounds.minY, origin)
            }
            let anchor = userScrolls ? try XCTUnwrap(m.controller.position.anchor) : edited.id
            let before = try m.y(anchor)
            XCTAssertTrue(m.coordinator.commit(page)); m.settle()
            XCTAssertNotNil(m.coordinator.messageIndex("fixture-10"))
            XCTAssertEqual(try m.y(anchor), before, accuracy: 0.75,
                "An older unloaded reveal must not displace the edit or subsequent user scroll")
            XCTAssertNil(m.controller.selectedID, "The canceled reveal must not select its late target")
            XCTAssertFalse(m.controller.following)
        }
    }

    func testUnloadedRevealCannotOverrideNewerDirectNavigation() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185")
            m.model.revealMessageID = "fixture-10"; m.apply()
            XCTAssertNil(m.controller.bodyFrame("fixture-10"))
            m.controller.reveal(messageID: "fixture-190")
            let before = try m.y("fixture-190")
            m.model.loadOlder(); m.apply(); m.settle()
            XCTAssertEqual(try m.y("fixture-190"), before, accuracy: 0.75)
            XCTAssertEqual(m.controller.selectedID, "fixture-190")
        }
    }

    func testUnloadedNavigationCannotOverrideNewerVisibleFocus() throws {
        for root: String? in [nil, "fixture-root"] {
            for kind in [0, 1, 2] {
                let m = try Mounted(root: root); defer { m.close() }
                try m.position("fixture-185")
                var saved = m.controller.position; saved.atBottom = false; saved.anchor = "fixture-10"
                if kind == 0 { m.model.revealMessageID = "fixture-10" }
                else { m.adapter.builder.request(kind == 1 ? .edit("fixture-10") : .restore(.init(saved))) }
                m.apply()
                XCTAssertNil(m.coordinator.messageIndex("fixture-10"))
                XCTAssertTrue(m.controller.visibleIDs.contains("fixture-185"))
                let origin = m.scroll.contentView.bounds.minY
                let navigation = m.controller.navigationGeneration
                m.model.focusedMessageID = "fixture-185"; m.apply(); m.settle()
                XCTAssertEqual(m.controller.selectedID, "fixture-185")
                XCTAssertEqual(m.scroll.contentView.bounds.minY, origin, accuracy: 0.75)
                XCTAssertGreaterThan(m.controller.navigationGeneration, navigation,
                    "Visible focus must fence navigation even without scrolling")
                XCTAssertTrue(m.host.window.firstResponder === m.table)
                let before = try m.y("fixture-185")
                m.model.loadOlder(); m.apply(); m.settle()
                XCTAssertNotNil(m.coordinator.messageIndex("fixture-10"))
                XCTAssertEqual(try m.y("fixture-185"), before, accuracy: 0.75, "Superseded command kind \(kind)")
                XCTAssertEqual(m.controller.selectedID, "fixture-185")
            }
        }
    }

    func testNewerUnloadedNavigationFencesOlderCommandsBeforeTargetsArrive() throws {
        for root: String? in [nil, "fixture-root"] {
            for kind in [0, 1, 2, 3] {
                let m = try Mounted(root: root); defer { m.close() }
                try m.position("fixture-185")
                m.adapter.builder.request(.edit("fixture-10")); m.apply()
                var saved = m.controller.position; saved.atBottom = false; saved.anchor = "fixture-20"
                let commands: [NativeTimelineSnapshot.Command.Kind] = [
                    .reveal("fixture-20"), .edit("fixture-20"), .focusMessage("fixture-20"), .restore(.init(saved))]
                m.adapter.builder.request(commands[kind]); m.apply()
                let before = try m.y("fixture-185")
                m.model.feed.messages.insert(ChatScrollFixture.message(10, root: root), at: 0)
                m.apply(); m.settle()
                XCTAssertNotNil(m.coordinator.messageIndex("fixture-10"))
                XCTAssertEqual(try m.y("fixture-185"), before, accuracy: 0.75,
                    "An older target arriving first must not override newer unloaded command kind \(kind)")
                m.model.feed.messages.insert(ChatScrollFixture.message(20, root: root), at: 1)
                m.apply(); m.settle()
                let frame = try XCTUnwrap(m.controller.bodyFrame("fixture-20"))
                let restoredRow = try XCTUnwrap(m.coordinator.messageIndex("fixture-20"))
                let target = kind == 3 ? m.table.rect(ofRow: restoredRow).minY : frame.midY
                if kind == 2 { XCTAssertTrue(m.controller.visibleIDs.contains("fixture-20")) }
                else {
                    XCTAssertEqual(target - m.scroll.contentView.bounds.minY,
                        kind == 3 ? 0 : m.scroll.contentView.bounds.height / 2, accuracy: 0.75)
                }
                if kind == 0 || kind == 2 { XCTAssertEqual(m.controller.selectedID, "fixture-20") }
                XCTAssertFalse(m.controller.following)
            }
        }
    }

    func testVisibleFocusFencesWaitingRevealWhenItsPageArrivesInTheSameSnapshot() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            try m.position("fixture-185")
            m.model.revealMessageID = "fixture-10"; m.apply()
            XCTAssertNil(m.coordinator.messageIndex("fixture-10"))
            let before = try m.y("fixture-185")
            m.model.loadOlder()
            m.model.focusedMessageID = "fixture-185"
            m.apply(); m.settle()
            XCTAssertNotNil(m.coordinator.messageIndex("fixture-10"))
            XCTAssertEqual(m.controller.selectedID, "fixture-185")
            XCTAssertEqual(try m.y("fixture-185"), before, accuracy: 0.75,
                "The old reveal must be fenced before it can move the visible focus target offscreen")
        }
    }

    func testOtherPanesRevealKeepsRestorationAcrossNarrowWideRemountAndReturn() throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce()
        for isDM in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w04-panes-\(UUID())")
            let model = ChatTimelineW01Model(directory: directory)
            model.isDM = isDM; model.threadRoot = "fixture-40"
            model.feed.messages = (40..<200).map { ChatScrollFixture.message($0, root: nil) }
                + (240..<400).map { ChatScrollFixture.message($0, root: "fixture-40") }
            let style = ChatTimelineAdapter.style(scale: 2, locale: Locale(identifier: "en_US"),
                calendar: Calendar(identifier: .gregorian), increasedContrast: false, alwaysShowTime: false)
            var feed = NativeChatTimelineCoordinator(), feedAdapter = ChatTimelineAdapter()
            let thread = NativeChatTimelineCoordinator(), threadAdapter = ChatTimelineAdapter()
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 1180, height: 600))
            let host = ChatQuietHost(view: container, dark: false, width: 1180, height: 600)
            defer {
                feed.dispose(); thread.dispose(); feedAdapter.invalidate(); threadAdapter.invalidate(); host.close()
                try? FileManager.default.removeItem(at: directory)
            }
            func apply(_ coordinator: NativeChatTimelineCoordinator, _ adapter: ChatTimelineAdapter, root: String?) {
                let snapshot = adapter.snapshot(model: model, root: root, members: [], mentionable: [],
                    me: model.key.accountId, archived: false, ownerModel: nil, style: style)
                coordinator.actions = adapter.actions
                coordinator.update(snapshot, width: coordinator.scrollView.contentSize.width)
            }
            func mount(_ coordinator: NativeChatTimelineCoordinator, x: CGFloat, width: CGFloat) {
                container.addSubview(coordinator.scrollView)
                coordinator.scrollView.frame = CGRect(x: x, y: 0, width: width, height: 600)
                ChatScrollAppKitSettings.apply(to: coordinator.scrollView); coordinator.scrollView.tile()
            }
            func y(_ coordinator: NativeChatTimelineCoordinator, _ id: String) throws -> CGFloat {
                try XCTUnwrap(coordinator.scrollController.bodyFrame(id)).minY - coordinator.scrollView.contentView.bounds.minY
            }
            func rowY(_ coordinator: NativeChatTimelineCoordinator, _ id: String) throws -> CGFloat {
                let index = try XCTUnwrap(coordinator.messageIndex(id))
                return coordinator.tableView.rect(ofRow: index).minY - coordinator.scrollView.contentView.bounds.minY
            }
            mount(feed, x: 0, width: 760); mount(thread, x: 760, width: 420)
            apply(feed, feedAdapter, root: nil); apply(thread, threadAdapter, root: "fixture-40")
            XCTAssertTrue(feed.scrollController.scrollTo(messageID: "fixture-100", alignment: .top))
            let saved = feed.scrollController.position
            XCTAssertEqual(saved.anchor, "fixture-100"); XCTAssertFalse(saved.atBottom)
            model.revealMessageID = "fixture-300"
            apply(feed, feedAdapter, root: nil); apply(thread, threadAdapter, root: "fixture-40")
            XCTAssertEqual(thread.scrollController.selectedID, "fixture-300")
            let threadY = try y(thread, "fixture-300")
            // The narrow layout removes the feed. Widening creates a new adapter
            // and controller from the same model and its saved history position.
            model.positions[""] = saved
            feed.dispose(); feedAdapter.invalidate(); feed.scrollView.removeFromSuperview()
            host.window.setContentSize(CGSize(width: 420, height: 600))
            thread.scrollView.frame.origin.x = 0
            host.window.setContentSize(CGSize(width: 1180, height: 600))
            thread.scrollView.frame.origin.x = 760
            feed = NativeChatTimelineCoordinator(); feedAdapter = ChatTimelineAdapter()
            mount(feed, x: 0, width: 760)
            apply(feed, feedAdapter, root: nil); apply(thread, threadAdapter, root: "fixture-40")
            XCTAssertEqual(try rowY(feed, "fixture-100"), 0, accuracy: 0.75,
                "A thread reveal must not discard the remounted feed's saved history anchor")
            XCTAssertNil(feed.scrollController.selectedID)
            XCTAssertEqual(try y(thread, "fixture-300"), threadY, accuracy: 0.75)
            var returned = saved; returned.anchor = "fixture-120"
            model.positions[""] = returned
            var threadReturn = thread.scrollController.position; threadReturn.anchor = "fixture-280"; threadReturn.atBottom = false
            model.positions["fixture-40"] = threadReturn
            model.readingPositionRestored += 1
            apply(feed, feedAdapter, root: nil); apply(thread, threadAdapter, root: "fixture-40")
            XCTAssertEqual(try rowY(feed, "fixture-120"), 0, accuracy: 0.75,
                "Explicit return also belongs to its pane")
            XCTAssertEqual(try y(thread, "fixture-300"), threadY, accuracy: 0.75,
                "The owning pane's active reveal still takes precedence over return")
            // A saved anchor can also be outside the current loaded window.
            // Foreign reveal/focus/edit commands must leave that restoration waiting.
            returned.anchor = "fixture-20"; model.positions[""] = returned
            model.focusedMessageID = "fixture-300"
            let edited = try XCTUnwrap(model.message("fixture-300"))
            model.editing = .init(messageId: edited.id, root: "fixture-40", text: edited.text, revision: 1, message: edited)
            feed.dispose(); feedAdapter.invalidate(); feed.scrollView.removeFromSuperview()
            feed = NativeChatTimelineCoordinator(); feedAdapter = ChatTimelineAdapter()
            mount(feed, x: 0, width: 760); apply(feed, feedAdapter, root: nil)
            model.feed.messages.insert(contentsOf: (0..<40).map { ChatScrollFixture.message($0, root: nil) }, at: 0)
            apply(feed, feedAdapter, root: nil)
            XCTAssertEqual(try rowY(feed, "fixture-20"), 0, accuracy: 0.75,
                "Other-pane commands must not cancel a restoration waiting for its history page")
            XCTAssertNil(feed.scrollController.selectedID)
            XCTAssertFalse(APQuietWindowHasOSFocus(host.window)); XCTAssertNil(APQuietFailure())
        }
    }

    private final class MomentumWindow: NSWindow {
        var received = false
        override func sendEvent(_ event: NSEvent) {
            if event.type == .scrollWheel { received = true; return }
            super.sendEvent(event)
        }
    }
    private final class Wheel: NSEvent {
        let target: NSWindow
        let momentum: Bool
        let point: CGPoint
        init(_ window: NSWindow, momentum: Bool, point: CGPoint? = nil) {
            target = window; self.momentum = momentum
            self.point = point ?? CGPoint(x: momentum ? -10 : 100, y: 100)
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var type: NSEvent.EventType { .scrollWheel }
        override var window: NSWindow? { target }
        override var locationInWindow: NSPoint { point }
        override var phase: NSEvent.Phase { momentum ? [] : .began }
        override var momentumPhase: NSEvent.Phase { momentum ? .began : [] }
        override var scrollingDeltaY: CGFloat { -8 }
    }
    func testRoutedMomentumOutsidePointerCancelsPendingReveal() throws {
        for root: String? in [nil, "fixture-root"] {
            let m = try Mounted(root: root); defer { m.close() }
            let window = MomentumWindow(contentRect: m.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            m.host.window.contentView = nil; window.contentView = m.scroll
            APQuietSelectWindow(window)
            defer { window.contentView = nil; window.close() }
            try m.position("fixture-185")
            APQuietSendEvent(Wheel(window, momentum: false), window)
            let page = try m.preparePage(reveal: "fixture-60")
            let generation = m.controller.inputGeneration
            APQuietSendEvent(Wheel(window, momentum: true), window)
            XCTAssertTrue(window.received)
            XCTAssertGreaterThan(m.controller.inputGeneration, generation)
            let before = try m.y("fixture-185")
            XCTAssertTrue(m.coordinator.commit(page)); m.settle()
            XCTAssertEqual(try m.y("fixture-185"), before, accuracy: 0.75)
            XCTAssertNil(m.controller.selectedID)
        }
    }

    func testKeyboardInAdjacentPaneKeepsPendingNavigation() throws {
        let feed = try Mounted(root: nil), thread = try Mounted(root: "fixture-root")
        defer { feed.close(); thread.close() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1180, height: 600))
        window.contentView = content
        feed.host.window.contentView = nil; thread.host.window.contentView = nil
        content.addSubview(feed.scroll); content.addSubview(thread.scroll)
        feed.scroll.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
        thread.scroll.frame = CGRect(x: 760, y: 0, width: 420, height: 600)
        feed.scroll.tile(); thread.scroll.tile(); feed.apply(); thread.apply()
        APQuietSelectWindow(window)
        defer { window.contentView = nil; window.close() }
        for m in [feed, thread] { try m.position("fixture-185") }
        let threadPage = try thread.preparePage(reveal: "fixture-60")
        let feedGeneration = feed.controller.inputGeneration, threadGeneration = thread.controller.inputGeneration
        XCTAssertTrue(window.makeFirstResponder(feed.table))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{f72c}", charactersIgnoringModifiers: "\u{f72c}", isARepeat: false, keyCode: 116))
        APQuietSendEvent(event, window)
        feed.settle(); thread.settle()
        XCTAssertGreaterThan(feed.controller.inputGeneration, feedGeneration)
        XCTAssertEqual(thread.controller.inputGeneration, threadGeneration)
        XCTAssertTrue(thread.coordinator.commit(threadPage)); thread.settle()
        XCTAssertEqual(thread.controller.selectedID, "fixture-60")
    }

    func testMomentumOverAdjacentPaneDoesNotCancelItsNavigation() throws {
        let feed = try Mounted(root: nil), thread = try Mounted(root: "fixture-root")
        defer { feed.close(); thread.close() }
        let window = MomentumWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1180, height: 600))
        window.contentView = content
        feed.host.window.contentView = nil; thread.host.window.contentView = nil
        content.addSubview(feed.scroll); content.addSubview(thread.scroll)
        feed.scroll.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
        thread.scroll.frame = CGRect(x: 760, y: 0, width: 420, height: 600)
        feed.scroll.tile(); thread.scroll.tile(); feed.apply(); thread.apply()
        APQuietSelectWindow(window)
        defer { window.contentView = nil; window.close() }
        for m in [feed, thread] { try m.position("fixture-185") }
        APQuietSendEvent(Wheel(window, momentum: false), window)
        let feedPage = try feed.preparePage(reveal: "fixture-60")
        let threadPage = try thread.preparePage(reveal: "fixture-60")
        let feedGeneration = feed.controller.inputGeneration, threadGeneration = thread.controller.inputGeneration
        let before = try feed.y("fixture-185")
        APQuietSendEvent(Wheel(window, momentum: true, point: CGPoint(x: 900, y: 100)), window)
        XCTAssertGreaterThan(feed.controller.inputGeneration, feedGeneration)
        XCTAssertEqual(thread.controller.inputGeneration, threadGeneration)
        XCTAssertTrue(feed.coordinator.commit(feedPage)); XCTAssertTrue(thread.coordinator.commit(threadPage))
        XCTAssertEqual(try feed.y("fixture-185"), before, accuracy: 0.75)
        XCTAssertNil(feed.controller.selectedID)
        XCTAssertEqual(thread.controller.selectedID, "fixture-60")
    }
}
