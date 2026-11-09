import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

/// Native controls dispatch into the real offline service and durable queue.
/// Transport and server outcomes are fixtures; model actions are not replaced.
@MainActor final class ChatNativeServiceActionTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures.removeAll()
    }

    private func fixture() async throws -> ChatNativeActionFixture {
        let value = try await ChatNativeActionFixture()
        fixtures.append(value)
        try await value.settle()
        return value
    }

    private func button(_ title: String, row: ChatNativeShellCell) throws -> ChatNativeTextButton {
        try XCTUnwrap(row.inlineControls.subviews.compactMap { $0 as? ChatNativeTextButton }.first { $0.title == title })
    }

    private func failPost(_ f: ChatNativeActionFixture, id: String) throws {
        try f.base.write("UPDATE messages SET local_state = 'failed', local_error = 'forbidden' WHERE message_id = ?", [id])
        try f.base.write("UPDATE outbox SET state = 'failed', error = 'forbidden' WHERE type = 'message.post'")
    }

    private func failEdit(_ f: ChatNativeActionFixture, text: String) throws {
        try f.base.service.change(f.base.key, messageId: f.messages[0].id, text: text, expectedRevision: 3)
        try f.base.write("UPDATE local_edits SET state = 'failed', error = 'revision_conflict'")
        try f.base.write("UPDATE outbox SET state = 'failed', error = 'revision_conflict' WHERE type = 'message.edit'")
    }

    func testNativeFailedPostRetryRechecksArchiveAndDiscardRechecksDelivery() async throws {
        let f = try await fixture()
        let text = "Retain this exact failed post"
        let id = try f.base.service.post(f.base.key, channel: f.model.channel, root: nil, text: text, mentions: [])
        try failPost(f, id: id)
        try await f.settle()
        let row = try f.row(id)
        let retry = try button("Retry", row: row), discard = try button("Delete", row: row)
        XCTAssertTrue(retry.isEnabled)
        try f.base.write("UPDATE channels SET archived = 1")
        // Keep the enabled native control from before the permission change.
        try await Task.sleep(for: .milliseconds(80))
        retry.performClick(nil)
        XCTAssertEqual(try f.commands().map(\.type), ["message.post"])
        XCTAssertEqual(f.model.message(id)?.localState, .failed)
        try f.base.write("UPDATE channels SET archived = 0")
        try await Task.sleep(for: .milliseconds(80))
        retry.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        let commands = try f.commands()
        XCTAssertEqual(commands.map(\.type), ["message.post", "message.post"])
        let repeated = try XCTUnwrap(commands.last)
        XCTAssertEqual(ChatService.args(repeated), ["message_id": .string(id), "channel_id": .string(f.model.channel),
            "text": .string(text), "mentions": .array([])])
        XCTAssertNotEqual(commands.first?.commandId, repeated.commandId)
        XCTAssertEqual(f.model.message(id)?.localState, .sending)
        // Dispatch before repaint removes the old failed-row control.
        discard.performClick(nil)
        try await f.settle()
        XCTAssertNotNil(f.model.message(id), "A retained failed-row Delete cannot delete a post that is now sending")
        try failPost(f, id: id)
        try await f.settle()
        try button("Delete", row: f.row(id)).performClick(nil)
        try await f.settle()
        XCTAssertNil(f.model.message(id))
        XCTAssertEqual(try f.commands().map(\.type), ["message.post", "message.post"])
    }

    func testNativeConflictRecoverySavesFailedTextWithCurrentRevision() async throws {
        let f = try await fixture()
        let text = "My unsaved change after conflict"
        try failEdit(f, text: text)
        try f.base.write("UPDATE messages SET text = 'Changed elsewhere', revision = 7 WHERE message_id = ?", [f.messages[0].id])
        try await f.settle()
        try button("Edit again", row: f.row(f.messages[0].id)).performClick(nil)
        try await f.settle()
        let editor = try XCTUnwrap(f.coordinator.editorSession)
        XCTAssertEqual(editor.editor.string, text)
        XCTAssertEqual(f.model.editing?.revision, 7)
        editor.host.save.performClick(nil)
        try await f.settle()
        let commands = try f.commands()
        XCTAssertEqual(commands.map(\.type), ["message.edit", "message.edit"])
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.last)), ["message_id": .string(f.messages[0].id),
            "expected_revision": .number(7), "text": .string(text), "mentions": .array([])])
        XCTAssertNil(f.model.editing)
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertEqual(f.model.message(f.messages[0].id)?.localEdit?.state, "saving")
    }

    func testNativeArchivedConflictCanBeRecoveredReadOnlyCancelledAndDiscarded() async throws {
        let f = try await fixture()
        try failEdit(f, text: "Keep my failed text readable")
        try f.base.write("UPDATE channels SET archived = 1")
        try await f.settle()
        try button("Edit again", row: f.row(f.messages[0].id)).performClick(nil)
        try await f.settle()
        let editor = try XCTUnwrap(f.coordinator.editorSession)
        XCTAssertEqual(editor.editor.string, "Keep my failed text readable")
        XCTAssertFalse(editor.host.save.isEnabled)
        editor.host.save.performClick(nil)
        XCTAssertEqual(try f.commands().count, 1)
        editor.host.cancel.performClick(nil)
        try await f.settle()
        XCTAssertNil(f.coordinator.editorSession)
        try button("Discard", row: f.row(f.messages[0].id)).performClick(nil)
        try await f.settle()
        XCTAssertNil(f.model.message(f.messages[0].id)?.localEdit)
        XCTAssertEqual(try f.commands().map(\.type), ["message.edit"])
    }

    func testNativePinMenuAndReactionPickerDispatchRealCommandsWithCurrentGuards() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }
        let f = try await fixture()
        try await f.connectSocket()
        let id = f.messages[0].id
        let metadata = ChatB1.Metadata(messageId: id, deleted: false, reactions: [], pin: nil)
        try f.base.write("INSERT OR REPLACE INTO b1_metadata (channel_id, message_id, data, dirty) VALUES (?, ?, ?, 0)",
                         [f.model.channel, id, try ChatB1.encode(metadata)])
        try await f.settle()
        let b1 = try XCTUnwrap(f.model.b1)
        XCTAssertTrue(b1.canChange)
        let row = try f.row(id)
        let menu = try XCTUnwrap(row.rowActions.makeMenu())
        let pin = try XCTUnwrap(menu.items.firstIndex { $0.title == "Pin message" })
        XCTAssertTrue(menu.items[pin].isEnabled)
        // A menu made before rights became uncertain must not enqueue a change.
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        menu.performActionForItem(at: pin)
        XCTAssertTrue(try f.base.commands().isEmpty)
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = false
        menu.performActionForItem(at: pin)
        try await f.settle()
        var commands = try f.base.commands().filter { ChatB1.commands.contains($0.type) }
        XCTAssertEqual(commands.map(\.type), ["message.pin.set"])
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first)), ["channel_id": .string(f.model.channel),
            "message_id": .string(id), "present": .bool(true)])
        menu.performActionForItem(at: pin)
        XCTAssertEqual(try f.base.commands().filter { ChatB1.commands.contains($0.type) }.count, 1)
        let fresh = try XCTUnwrap(row.rowActions.makeMenu())
        XCTAssertFalse(try XCTUnwrap(fresh.items.first { $0.title == "Pin message" }).isEnabled)

        row.rowActions.hover(true)
        try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Add reaction" }).performClick(nil)
        try await f.host.settle()
        XCTAssertTrue(row.rowActions.popup.popover.isShown)
        XCTAssertTrue(NavigationPresentationGate.obscures(f.host.window))
        let popupWindow = try XCTUnwrap(row.rowActions.popup.popover.contentViewController?.view.window)
        popupWindow.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(pressPicker("👍", window: popupWindow), "Press the actual SwiftUI picker button through its native accessibility action")
        try await f.settle()
        commands = try f.base.commands().filter { ChatB1.commands.contains($0.type) }
        XCTAssertEqual(commands.map(\.type), ["message.pin.set", "message.reaction.set"])
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.last)), ["channel_id": .string(f.model.channel),
            "message_id": .string(id), "present": .bool(true), "emoji": .string("👍")])
        let other = NSTextField(string: "Another control")
        other.frame = CGRect(x: 2, y: 2, width: 160, height: 22)
        f.view.addSubview(other)
        XCTAssertTrue(f.host.window.makeFirstResponder(other))
        let responder = f.host.window.firstResponder
        f.base.service.serverCapabilities[f.base.key.server] = []
        try await f.settle()
        XCTAssertNil(f.adapter.actions?.reactionPicker(messageID: id), "The current domain capability must reject the popup")
        XCTAssertFalse(row.rowActions.popup.popover.isShown)
        XCTAssertFalse(NavigationPresentationGate.obscures(f.host.window))
        XCTAssertTrue(f.host.window.firstResponder === responder)
        XCTAssertEqual(try f.base.commands().filter { ChatB1.commands.contains($0.type) }.count, 2)
    }

    private func pressPicker(_ title: String, window: NSWindow) -> Bool {
        let nodes = ChatTimelineReferenceCapture.accessibilityNodes(window)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        // SwiftUI also exposes the button's Text child with the same label.
        // Select an actionable node rather than stopping at that text child.
        let button = nodes.first { node in
            node.responds(to: selector) && ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) as? String == title
            }
        }
        if let button {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            if unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector) { return true }
        }
        let diagnostic = nodes.prefix(80).map { node in
            let values = ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"].map {
                String(describing: ChatTimelineReferenceCapture.accessibilityAttribute(node, $0) ?? "nil").prefix(100)
            }
            return "\(type(of: node)) press=\(node.responds(to: selector)) \(values)"
        }.joined(separator: "\n")
        print("W05 picker AX diagnostic (first 80 nodes):\n\(diagnostic)")
        return false
    }
}

extension ChatNativeActionFixture {
    /// A real ChatSocket state machine, fed only by FakeSocketTransport. The
    /// feed lifecycle is detached before hello so no snapshot or sender starts.
    func connectSocket() async throws {
        let f = self
        let transport = FakeSocketTransport()
        f.base.service.makeSocketTransport = { transport }
        ChatStubProtocol.reset { request, _ in
            guard request.url?.path == "/v1/server" else { return .failure(URLError(.unsupportedURL)) }
            return .success(.init(status: 200, body: Data(#"{"name":"fixture","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels","chat.reactions","chat.pins"]}"#.utf8)))
        }
        f.base.service.followsFeed = true
        try await f.base.service.start(mode: .server)
        let socket = try XCTUnwrap(f.base.service.socket)
        socket.lifecycle = nil
        let deadline = ContinuousClock.now + .seconds(3)
        while transport.request == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try XCTUnwrap(transport.request)
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        while socket.state != .connected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(socket.state, .connected)
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = false
        f.base.service.orgSessions[f.base.key]?.outbox?.hold()
    }
}
