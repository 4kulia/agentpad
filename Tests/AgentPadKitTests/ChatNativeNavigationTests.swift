import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeNavigationTests: XCTestCase {
    private var fixture: ChatNativeActionFixture?
    private var host: ChatQuietHost?
    private var previousActive: (@MainActor () -> Bool)!

    override func setUp() async throws {
        previousActive = ChatNotifications.appActive; ChatNotifications.appActive = { false }
    }
    override func tearDown() async throws {
        if let view = host?.view as? NSHostingView<AnyView> {
            view.rootView = AnyView(EmptyView()); try await host?.settle()
        }
        host?.close(); host = nil
        await fixture?.close(); fixture = nil
        ChatNotifications.appActive = previousActive
    }
    private func channel(width: CGFloat = 1_100) async throws -> (ChatNativeActionFixture, ChatChannelSession, ChatChannelModel, ChatQuietHost) {
        let f = try await ChatNativeActionFixture(count: 35)
        fixture = f
        f.dispose()
        let root = f.messages[0].id
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET thread_root_id = ? WHERE seq BETWEEN 2 AND 10", arguments: [root])
            try db.execute(sql: "INSERT OR REPLACE INTO thread_cursors (root_id, channel_id, epoch, next, shown_from) VALUES (?, ?, 1, NULL, 2)",
                arguments: [root, ChatTimelineReferenceFixture.channel])
        }
        let card = ChatChannelCard(channelId: ChatTimelineReferenceFixture.channel,
            teamId: "f5000000-0000-4000-8000-000000000004", name: "Native lifecycle", createdBy: f.base.key.accountId,
            archived: false, version: 1)
        let session = ChatChannelSession()
        session.update(.ready(card, team: "Team", offline: true), key: f.base.key, store: f.base.store, service: f.base.service)
        let model = try XCTUnwrap(session.model)
        let view = ChatChannelView(card: card, team: "Team", offline: true, key: f.base.key, conversation: session, service: f.base.service)
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let host = ChatQuietHost(view: hosting, dark: false, width: width, height: 650)
        self.host = host
        try await settle(host)
        return (f, session, model, host)
    }
    private func settle(_ host: ChatQuietHost) async throws {
        for _ in 0..<3 { try await host.settle() }
    }
    private func timelines(_ host: ChatQuietHost) -> [NativeChatTimelineCoordinator] {
        ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self).map(\.coordinator)
    }
    private func pane(_ root: String?, _ host: ChatQuietHost) throws -> NativeChatTimelineCoordinator {
        try XCTUnwrap(timelines(host).first { $0.snapshot?.conversation.root == root })
    }
    private func key(_ host: ChatQuietHost, code: UInt16, text: String, flags: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        APQuietSendEvent(event, host.window)
    }

    func testChannelSearchReturnAndComposerFocusAcrossPaneReplacement() async throws {
        let (f, _, model, host) = try await channel()
        XCTAssertEqual(timelines(host).count, 1)
        let root = f.messages[0].id
        let feed = try pane(nil, host)
        feed.scrollController.scrollTo(messageID: f.messages[20].id, alignment: .top)
        model.openThread(root)
        try await settle(host)
        XCTAssertEqual(timelines(host).count, 2)
        let thread = try pane(root, host)
        thread.scrollController.scrollTo(messageID: f.messages[5].id, alignment: .top)
        try await settle(host)
        let saved = model.positions
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(f.messages[5].id)), root: root))
        model.editing?.text = "Saved thread edit"
        try await settle(host)
        for local in [true, false] {
            model.setSearching(local)
            let target = try XCTUnwrap(model.message(f.messages[25].id))
            if local { model.navigate(to: target) }
            else { model.navigate(to: ChatMessageLink(key: model.key, message: target)) }
            try await settle(host)
            let destination = try pane(nil, host)
            // Preserve the observed legacy precedence when search closes a
            // thread: its root focus currently follows the reveal command.
            XCTAssertEqual(destination.scrollController.selectedID, model.focusedMessageID)
            XCTAssertEqual(model.revealMessageID, target.id)
            XCTAssertFalse(destination.scrollController.following)
            XCTAssertTrue(model.hasNavigationReturn)
            XCTAssertFalse(ChatNotifications.isLooking(model.notificationPlace(root: nil)))
            model.returnFromNavigation()
            try await settle(host)
            XCTAssertEqual(model.threadRoot, root)
            XCTAssertFalse(model.searching)
            XCTAssertFalse(model.hasNavigationReturn)
            XCTAssertEqual(model.editing?.text, "Saved thread edit")
            XCTAssertEqual(try pane(root, host).editorSession?.editor.string, "Saved thread edit")
            XCTAssertEqual(model.positions[""]?.anchor, saved[""]?.anchor)
        }
        model.cancelEditing()
        try await settle(host)
        for area in [ChatFocusArea.feed, .feed, .thread, .thread] {
            model.focusRequest = ChatFocusRequest(area: area)
            try await settle(host)
            XCTAssertTrue(host.window.firstResponder === (try pane(area == .feed ? nil : root, host)).tableView)
        }
        model.focusRequest = ChatFocusRequest(area: .composer)
        try await settle(host)
        let composer = try XCTUnwrap(host.window.firstResponder as? ChatMentionEditor.Editor)
        XCTAssertNotEqual(composer.accessibilityLabel(), "Edit message")
        composer.setMarkedText("入力", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let selected = try pane(root, host).scrollController.selectedID
        try key(host, code: 126, text: "\u{F700}")
        XCTAssertTrue(composer.hasMarkedText())
        XCTAssertEqual(try pane(root, host).scrollController.selectedID, selected)
        composer.unmarkText()

        host.window.setContentSize(NSSize(width: 700, height: 650))
        try await settle(host)
        XCTAssertEqual(timelines(host).count, 1)
        XCTAssertEqual(timelines(host).first?.snapshot?.conversation.root, root)
        model.focusRequest = ChatFocusRequest(area: .feed)
        try await settle(host)
        XCTAssertNil(model.threadRoot)
        XCTAssertEqual(timelines(host).count, 1)
        XCTAssertTrue(host.window.firstResponder === (try pane(nil, host)).tableView)
    }

    func testThreadToSearchRetainsCurrentRootFocusPrecedence() async throws {
        let (f, _, model, host) = try await channel()
        model.openThread(f.messages[0].id)
        try await settle(host)
        let target = try XCTUnwrap(model.message(f.messages[25].id))
        model.navigate(to: target)
        try await settle(host)
        let visible = ChatTimelineReferenceCapture.descendants(host.view, NSTextView.self)
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
            .map(\.string)
        XCTAssertTrue(visible.contains(f.messages[0].text))
        XCTAssertFalse(visible.contains(target.text))
        XCTAssertEqual(model.revealMessageID, target.id)
    }

    func testFeedSearchRevealsExactResultAndReturnsToReading() async throws {
        let (f, _, model, host) = try await channel()
        let feed = try pane(nil, host)
        feed.scrollController.scrollTo(messageID: f.messages[20].id, alignment: .top)
        try await settle(host)
        let saved = model.positions[""]
        for local in [true, false] {
            model.setSearching(local)
            let target = try XCTUnwrap(model.message(f.messages[25].id))
            if local { model.navigate(to: target) }
            else { model.navigate(to: ChatMessageLink(key: model.key, message: target)) }
            try await settle(host)
            XCTAssertEqual(feed.scrollController.selectedID, target.id)
            XCTAssertTrue(feed.scrollController.visibleIDs.contains(target.id))
            model.returnFromNavigation()
            try await settle(host)
            XCTAssertFalse(model.hasNavigationReturn)
            XCTAssertFalse(model.searching)
            XCTAssertEqual(model.positions[""]?.anchor, saved?.anchor)
        }
    }

    func testNewerComposerFocusSupersedesHiddenMessageAndAreaFocus() async throws {
        let (f, _, model, host) = try await channel()
        let root = f.messages[0].id
        model.openThread(root)
        try await settle(host)
        for paneRoot in [nil, root] as [String?] {
            let timeline = try pane(paneRoot, host)
            let container = try XCTUnwrap(timeline.tableView.superview?.superview?.superview)
            for messageFocus in [false, true] {
                model.focusedMessageID = nil
                model.focusRequest = ChatFocusRequest(area: .composer)
                try await settle(host)
                let composer = try XCTUnwrap(host.window.firstResponder as? ChatMentionEditor.Editor)
                XCTAssertNotEqual(composer.accessibilityLabel(), "Edit message")
                container.isHidden = true
                if messageFocus {
                    // The feed root focuses its reply control; a thread message
                    // focuses the table. Both must yield to the later request.
                    model.focusedMessageID = paneRoot == nil ? root : f.messages[3].id
                } else {
                    model.focusRequest = ChatFocusRequest(area: paneRoot == nil ? .feed : .thread)
                }
                try await settle(host)
                model.focusRequest = ChatFocusRequest(area: .composer)
                try await settle(host)
                XCTAssertTrue(host.window.firstResponder === composer)
                container.isHidden = false
                try await settle(host)
                XCTAssertTrue(host.window.firstResponder === composer,
                    "Unhiding must not replay obsolete \(messageFocus ? "message" : "area") focus in \(paneRoot == nil ? "feed" : "thread")")
            }
        }
    }

    func testNativeHiddenFocusAndChannelEscapePriority() async throws {
        let (f, _, model, host) = try await channel(width: 700)
        let root = f.messages[0].id
        model.openThread(root)
        try await settle(host)
        let thread = try pane(root, host)
        let container = try XCTUnwrap(thread.tableView.superview?.superview?.superview)
        container.isHidden = true
        model.focusRequest = ChatFocusRequest(area: .composer)
        try await settle(host)
        let responder = host.window.firstResponder
        model.focusRequest = ChatFocusRequest(area: .thread)
        try await settle(host)
        XCTAssertTrue(host.window.firstResponder === responder)
        container.isHidden = false
        try await settle(host)
        XCTAssertTrue(host.window.firstResponder === thread.tableView)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(f.messages[3].id)), root: root))
        try await settle(host)
        try key(host, code: 53, text: "\u{1b}")
        try await settle(host)
        XCTAssertNil(model.editing)
        XCTAssertEqual(model.threadRoot, root, "Editor Escape does not also close its thread")
        model.setSearching(true)
        model.focusRequest = ChatFocusRequest(area: .thread)
        try await settle(host)
        try key(host, code: 53, text: "\u{1b}")
        try await settle(host)
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.threadRoot, root)
        host.window.makeFirstResponder(thread.tableView)
        try key(host, code: 53, text: "\u{1b}")
        try await settle(host)
        XCTAssertNil(model.threadRoot)
    }

    func testCheckingRetainsChannelModelWhileActualPaneDisposalEndsPresentation() async throws {
        let (f, session, model, host) = try await channel()
        let table = try pane(nil, host)
        table.scrollController.scrollTo(messageID: f.messages[20].id, alignment: .top)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(f.messages[20].id)), root: nil))
        model.editing?.text = "Retained across checking"
        try await settle(host)
        let position = model.positions[""]
        session.update(.checking, key: f.base.key, store: f.base.store, service: f.base.service)
        XCTAssertTrue(session.model === model)
        let hosting = try XCTUnwrap(host.view as? NSHostingView<AnyView>)
        hosting.rootView = AnyView(EmptyView())
        try await settle(host)
        XCTAssertEqual(table.lifecycle.observerCount, 0)
        XCTAssertEqual(table.scrollController.inputMonitorCount, 0)
        XCTAssertNil(table.editorSession)
        XCTAssertEqual(model.editing?.text, "Retained across checking")
        XCTAssertEqual(model.positions[""], position)
    }
}
