import AppKit
import AgentPadQuietTestSupport
import ObjectiveC
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeAccessibilityTests: XCTestCase {
    private var fixture: ChatNativeActionFixture?
    override func tearDown() async throws { await fixture?.close(); fixture = nil }
    private func mount() async throws -> ChatNativeActionFixture {
        let f = try await ChatNativeActionFixture(count: 3)
        fixture = f
        try await f.settle()
        return f
    }
    private func key(_ code: UInt16, text: String, in f: ChatNativeActionFixture, flags: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.host.window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        APQuietSendEvent(event, f.host.window)
    }

    func testTextLinkAccessibilityDispatchesOnceAndRejectsDisabledOrUnboundActions() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        let button = ChatNativeTextButton()
        button.frame = CGRect(x: 10, y: 10, width: 180, height: 24)
        button.text = NSAttributedString(string: "Retry")
        view.addSubview(button)
        let host = ChatQuietHost(view: view, dark: false, width: 240, height: 80)
        defer { host.close() }
        try await host.settle()
        var calls = 0
        button.invoke = { calls += 1 }
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .link)
        XCTAssertTrue(button.isAccessibilityEnabled())
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(calls, 1)
        button.performClick(nil)
        XCTAssertEqual(calls, 2, "Mouse/key target-action dispatch remains the same")
        button.isEnabled = false
        XCTAssertFalse(button.isAccessibilityEnabled())
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(calls, 2)
        button.isEnabled = true
        button.invoke = nil
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(calls, 2)
        button.invoke = { [weak button] in
            calls += 1
            button?.invoke = nil
            button?.removeFromSuperview()
        }
        XCTAssertTrue(button.accessibilityPerformPress(), "A synchronous row replacement still handled this press")
        XCTAssertEqual(calls, 3)
        XCTAssertNil(button.superview)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertEqual(calls, 3)
        XCTAssertNil(APQuietFailure())
    }

    func testTimelineKeyLoopAndAccessibilityOrder() async throws {
        // Invisible windows make even a stock NSButton ineligible. Model full
        // keyboard eligibility in this test process, then let AppKit build
        // and traverse its real key loop. This does not alter the owner's
        // settings or claim native key-window traversal (hardware walkthrough).
        XCTAssertTrue(APQuietIsEnabled())
        let selector = #selector(getter: NSView.canBecomeKeyView)
        let keyboardMethod = try XCTUnwrap(class_getInstanceMethod(NSButton.self, selector))
        let keyboardImplementation = method_getImplementation(keyboardMethod)
        let eligible = imp_implementationWithBlock({ (button: NSButton) -> Bool in
            MainActor.assumeIsolated {
                button.window != nil && button.acceptsFirstResponder && button.isEnabled
                    && !button.isHiddenOrHasHiddenAncestor && !button.visibleRect.isEmpty
            }
        } as @convention(block) (NSButton) -> Bool)
        class_replaceMethod(NSButton.self, selector, eligible, method_getTypeEncoding(keyboardMethod))
        defer {
            class_replaceMethod(NSButton.self, selector, keyboardImplementation, method_getTypeEncoding(keyboardMethod))
            imp_removeBlock(eligible)
        }
        let f = try await mount()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let table = f.coordinator.tableView
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual(table.accessibilityLabel(), "Channel messages")
        XCTAssertFalse(table.allowsMultipleSelection)
        XCTAssertTrue(f.host.window.makeFirstResponder(table))
        try key(125, text: "\u{F701}", in: f)
        XCTAssertEqual(f.coordinator.scrollController.selectedID, f.messages.first?.id)
        let cell = try f.row(f.messages[0].id)
        XCTAssertEqual(cell.accessibilityRole(), .group)
        XCTAssertEqual(cell.accessibilityIdentifier(), "chat-message:" + f.messages[0].id)
        let date = try XCTUnwrap(ChatFeedLayout.date(f.messages[0].createdAt))
        XCTAssertEqual(cell.accessibilityLabel(), "Anna, " + date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone()))
        XCTAssertTrue(cell.isAccessibilitySelected())
        XCTAssertFalse(cell.header.isAccessibilityElement(), "Author is already in the row label")
        XCTAssertFalse(cell.timestamp.isAccessibilityElement())
        XCTAssertFalse(cell.mainAvatar.isAccessibilityElement())
        XCTAssertEqual(cell.body.accessibilityRole(), .textArea)
        XCTAssertEqual(cell.body.accessibilityValue() as? String, cell.body.string)
        XCTAssertFalse(cell.body.canBecomeKeyView)
        XCTAssertEqual(cell.rowActions.toolbar.buttons.map(\.title), ["Reply in thread", "Edit message", "Delete message…", "More message actions"])
        for button in cell.rowActions.toolbar.buttons {
            XCTAssertEqual(button.accessibilityRole(), .button)
            XCTAssertEqual(button.accessibilityLabel(), button.title)
            let screen = button.accessibilityFrame()
            let local = button.convert(f.host.window.convertFromScreen(screen), from: nil)
            XCTAssertEqual(local, button.bounds, "AX must expose the actual icon/menu hit target, not the cell bezel")
        }
        let children = try XCTUnwrap(cell.accessibilityChildren() as? [NSView])
        XCTAssertTrue(children.first === cell.body)
        XCTAssertEqual(children.suffix(4).map(ObjectIdentifier.init), cell.rowActions.toolbar.buttons.map(ObjectIdentifier.init))
        XCTAssertTrue(cell.rowActions.toolbar.buttons.allSatisfy { ($0.accessibilityParent() as? NSView) === cell })
        XCTAssertEqual(f.coordinator.editorLayer.accessibilityChildren()?.count, 0)

        let composer = NSTextField(string: "Composer key-view sentinel")
        composer.frame = CGRect(x: 10, y: 0, width: 200, height: 24)
        f.view.addSubview(composer)
        let stock = NSButton(title: "Stock key-view probe", target: nil, action: nil)
        stock.frame = CGRect(x: 230, y: 0, width: 160, height: 24)
        f.view.addSubview(stock)
        XCTAssertTrue(stock.canBecomeKeyView)
        f.host.window.recalculateKeyViewLoop()
        var visited = Set<ObjectIdentifier>(), stops: [NSView] = []
        var next: NSView? = table
        while let view = next, visited.insert(ObjectIdentifier(view)).inserted, stops.count < 100 {
            stops.append(view); next = view.nextValidKeyView
        }
        XCTAssertTrue(stops.contains { $0 === composer })
        XCTAssertEqual(stops.filter { $0 === table }.count, 1)
        XCTAssertFalse(stops.contains { $0 is ChatMessageText.View })
        XCTAssertTrue(cell.rowActions.toolbar.buttons.allSatisfy { button in stops.contains { $0 === button } })
        XCTAssertGreaterThan(table.keyViewCount, 0)
        f.host.window.recalculateKeyViewLoop()
        XCTAssertTrue(f.host.window.makeFirstResponder(table))
        try key(48, text: "\t", in: f)
        XCTAssertTrue(f.host.window.firstResponder === cell.rowActions.toolbar.buttons[0])
        try key(48, text: "\u{19}", in: f, flags: .shift)
        XCTAssertTrue(f.host.window.firstResponder === table)
        XCTAssertTrue(cell.rowActions.toolbar.buttons[0].accessibilityPerformPress())
        XCTAssertEqual(f.model.threadRoot, f.messages[0].id)
        f.coordinator.dispose()
        XCTAssertEqual(table.keyViewCount, 0)
        XCTAssertNil(APQuietFailure())
    }

    func testArrowsClampAndModifiedBodyKeysKeepNativeSelection() async throws {
        let f = try await mount(), table = f.coordinator.tableView
        f.host.window.makeFirstResponder(table)
        try key(126, text: "\u{F700}", in: f)
        XCTAssertEqual(f.coordinator.scrollController.selectedID, f.messages.last?.id)
        for _ in 0..<5 { try key(125, text: "\u{F701}", in: f) }
        XCTAssertEqual(f.coordinator.scrollController.selectedID, f.messages.last?.id)
        for _ in 0..<5 { try key(126, text: "\u{F700}", in: f) }
        XCTAssertEqual(f.coordinator.scrollController.selectedID, f.messages.first?.id)
        let cell = try f.row(f.messages[1].id)
        f.host.window.makeFirstResponder(cell.body)
        cell.body.setSelectedRange(NSRange(location: 1, length: 3))
        try key(124, text: "\u{F703}", in: f, flags: .shift)
        XCTAssertEqual(cell.body.selectedRange(), NSRange(location: 1, length: 4))
        XCTAssertEqual(f.coordinator.scrollController.selectedID, f.messages.first?.id)
        XCTAssertEqual(table.selectedRowIndexes, [])
        let old = cell.binding
        cell.unbind()
        XCTAssertTrue(cell.accessibilityIdentifier().isEmpty)
        XCTAssertTrue(cell.accessibilityLabel()?.isEmpty != false)
        XCTAssertFalse(cell.isAccessibilitySelected())
        XCTAssertEqual(cell.body.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(cell.apply(ifCurrent: try XCTUnwrap(old)) { _ in XCTFail("Reused AX identity") })
    }

    func testAccessibilityReadingOrderMatchesMembershipAttachmentsMarksAndMetadata() async throws {
        let f = try await mount(), id = f.messages[0].id
        let previousTeam = TeamService.sharedForTesting, previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        defer {
            TeamService.sharedForTesting = previousTeam
            ChatOrgCurrent.sharedForTesting = previousOrg
            ChatOrgCurrent.shared.refresh()
        }
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.pins", "chat.attachments", "chat.attachments_context"]
        f.base.service.serverAttachmentLimits[f.base.key.server] = try JSONDecoder().decode(
            ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        f.base.service.isServerKnown = { _, _ in true }
        let file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0,
            name: "Reading order.txt", mime: "text/plain", size: 128, hasPreview: false)
        let fields: [String: Any] = ["message_id": id, "channel_id": f.model.channel,
            "author_account_id": f.base.key.accountId, "text": "@first@anna Please check this file.",
            "revision": 4, "seq": 1, "created_at": ChatTimelineReferenceFixture.date,
            "attachments": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(file))]]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: fields))
        try await f.base.store.queue.write { _ = try ChatMessages.write($0, wire) }
        try f.base.write("UPDATE messages SET edited_at = ?, stale = 1, in_reply_to_message_id = ? WHERE message_id = ?",
            [ChatTimelineReferenceFixture.date, f.messages[1].id, id])
        try f.base.write("DELETE FROM agent_channels")
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        try f.base.write("""
            INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available)
            VALUES (?, ?, 'first', '', 'read', 1, 1)
            """, [CallJSON.agent, f.base.key.accountId])
        let metadata = ChatB1.Metadata(messageId: id, deleted: false, reactions: [],
            pin: .init(pinnedBy: f.base.key.accountId, pinnedAt: ChatTimelineReferenceFixture.date))
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
            [f.model.channel, id, try ChatB1.encode(metadata)])
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        try await f.settle()
        let cell = try f.row(id)
        func ordered(_ confirmation: Bool) throws {
            let exposed = (cell.accessibilityChildren() ?? []).compactMap {
                ($0 as? NSView) ?? ($0 as? NSCell)?.controlView
            }
            let edited = try XCTUnwrap(exposed.first { ($0 as? ChatNativeLabel)?.text.string == "edited" })
            let pin = try XCTUnwrap(exposed.first { ($0 as? ChatNativeLabel)?.text.string == "Pinned" })
            let reply = try XCTUnwrap(exposed.first { ($0 as? NSButton)?.title.hasPrefix("Reply to:") == true })
            let attachment = try XCTUnwrap(exposed.first { $0.isDescendant(of: cell.attachments) })
            var expected: [NSView] = [cell.membership, cell.footnote, attachment, edited]
            if confirmation {
                expected.append(try XCTUnwrap(exposed.first { $0.isDescendant(of: cell.inlineControls.confirmation) }))
            }
            expected += [pin, reply]
            let indexes = try expected.map { view in try XCTUnwrap(exposed.firstIndex { $0 === view }) }
            print("W08_AX_READING_ORDER", exposed.map { ($0.accessibilityLabel() ?? ($0 as? NSButton)?.title ?? "", cell.convert($0.bounds, from: $0).minY) })
            XCTAssertEqual(indexes, indexes.sorted(), "AX traversal follows the same body, membership, stale, file, marks, confirmation, metadata and reply order as the rendered message")
            let top = expected.map { cell.convert($0.bounds, from: $0).minY }
            XCTAssertEqual(top, top.sorted(), "The assertion's expected order is anchored to actual rendered geometry")
        }
        try ordered(false)
        let menu = try XCTUnwrap(cell.rowActions.makeMenu())
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Delete…" }))
        try await f.settle()
        XCTAssertTrue(f.confirmation.isVisible)
        try ordered(true)
        f.confirmation.cancel()
        XCTAssertNil(APQuietFailure())
    }

    func testEditorAccessibilityStaysWithItsMessageAndSurvivesRowReuse() async throws {
        let f = try await ChatNativeActionFixture(count: 40)
        fixture = f
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        let cell = try f.row(f.messages[0].id)
        XCTAssertTrue((session.host.accessibilityParent() as? NSView) === cell)
        XCTAssertTrue((cell.accessibilityChildren() as? [NSView])?.contains { $0 === session.host } == true)
        XCTAssertFalse((cell.accessibilityChildren() as? [NSView])?.contains { $0 === cell.body } == true)
        let controls = try XCTUnwrap(session.host.accessibilityChildren() as? [NSView])
        XCTAssertEqual(controls.prefix(session.host.formatting.count).map(ObjectIdentifier.init), session.host.formatting.map(ObjectIdentifier.init))
        XCTAssertTrue(controls.last === session.host.save)
        XCTAssertEqual(session.editor.accessibilityLabel(), "Edit message")
        XCTAssertEqual(session.editor.accessibilityValue() as? String, session.editor.string)
        session.editor.setAccessibilityFocused(true)
        XCTAssertTrue(f.host.window.firstResponder === session.editor, "AX focus routes to the retained input client")
        XCTAssertFalse(APQuietWindowHasOSFocus(f.host.window), "Quiet focus must not become real desktop focus")
        f.coordinator.scrollController.scrollTo(messageID: f.messages.last!.id, alignment: .top)
        try await f.host.settle()
        XCTAssertNil(session.host.accessibilityOwner)
        XCTAssertTrue((f.coordinator.editorLayer.accessibilityChildren() as? [NSView])?.contains { $0 === session.host } == true)
        _ = try f.row(f.messages[0].id)
        try await f.host.settle()
        XCTAssertNotNil(session.host.accessibilityOwner)
        XCTAssertEqual(f.coordinator.editorLayer.accessibilityChildren()?.count, 0)
        session.cancel(); try await f.settle()
        XCTAssertNil(session.host.accessibilityOwner)
        XCTAssertNil(f.coordinator.editorSession)
    }

    func testQuietAXCapturesResultsOnceAndRejectsHiddenNonkeyAndReusedRows() async throws {
        let f = try await mount()
        var message = f.messages[0]
        message.localState = .sending
        let model = ChatTimelineReferenceModel(f.base, messages: [message])
        func apply() async throws {
            let snapshot = f.adapter.snapshot(model: model, root: nil, members: [], mentionable: [],
                me: model.key.accountId, archived: false, ownerModel: nil,
                style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                    increasedContrast: false, alwaysShowTime: false))
            f.coordinator.actions = f.adapter.actions; f.view.update(snapshot)
            try await f.host.settle()
        }
        func recorded() -> [String] {
            APQuietCapturedAnnouncements().compactMap { $0[NSAccessibility.NotificationUserInfoKey.announcement.rawValue] as? String }
        }
        APQuietCaptureAnnouncements(true)
        defer { APQuietCaptureAnnouncements(false) }
        try await apply()
        XCTAssertEqual(recorded(), [], "Initial appearance is not a delivery transition")
        model.feed.messages[0].localState = nil
        try await apply(); try await apply()
        XCTAssertEqual(recorded(), ["Message sent"])
        model.feed.messages[0].localEdit = .init(kind: "edit", text: "Changed", state: "saving", error: nil)
        try await apply()
        model.feed.messages[0].localEdit = nil
        try await apply()
        XCTAssertEqual(recorded(), ["Message sent", "Message saved"])

        // Source cards intentionally exist only for real channel models.
        let request = UUID().uuidString.lowercased()
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        try f.base.move("running", 1, id: request)
        try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ? WHERE request_id = ?",
            [message.id, f.base.key.accountId, request])
        try await f.settle()
        _ = try f.row(message.id)
        try await f.host.settle()
        let running = try XCTUnwrap(f.model.sourceStatuses.first { $0.id == request })
        try f.base.write("UPDATE requests SET state = 'finished', version = 2 WHERE request_id = ?", [request])
        try await f.settle(); try await f.settle()
        XCTAssertEqual(recorded().count, 3)
        XCTAssertEqual(recorded().last, ChatAccessibility.agent(from: running, to: try XCTUnwrap(f.model.sourceStatuses.first { $0.id == request })))
        XCTAssertTrue(APQuietCapturedAnnouncements().allSatisfy {
            ($0[NSAccessibility.NotificationUserInfoKey.priority.rawValue] as? NSNumber)?.intValue == NSAccessibilityPriorityLevel.medium.rawValue
        })

        f.view.isHidden = true
        model.feed.messages[0].localState = .sending; try await apply()
        model.feed.messages[0].localState = .failed; model.feed.messages[0].localError = "forbidden"; try await apply()
        f.view.isHidden = false; try await apply()
        XCTAssertEqual(recorded().count, 3, "A hidden result is not replayed when shown")
        let other = ChatQuietHost(view: NSView(), dark: false)
        defer { other.close() }
        model.feed.messages[0].localState = .sending; try await apply()
        model.feed.messages[0].localState = nil; try await apply()
        XCTAssertEqual(recorded().count, 3, "A nonkey window cannot announce")
        APQuietSelectWindow(f.host.window)
        model.feed.messages[0].localState = .sending
        try await apply()
        let cell = try f.row(message.id)
        cell.unbind()
        model.feed.messages[0].localState = nil
        try await apply()
        XCTAssertEqual(recorded().count, 3, "A result received between unbind and rebind cannot announce")
        XCTAssertNil(APQuietFailure())
    }
}
