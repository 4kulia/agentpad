import AppKit
import AgentPadQuietTestSupport
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeLifecycleTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []
    private var previousActive: (@MainActor () -> Bool)!

    override func setUp() async throws {
        previousActive = ChatNotifications.appActive
        ChatNotifications.appActive = { false }
    }
    override func tearDown() async throws {
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures = []
        ChatNotifications.appActive = previousActive
    }
    private func fixture(count: Int = 3) async throws -> ChatNativeActionFixture {
        let result = try await ChatNativeActionFixture(count: count)
        fixtures.append(result)
        try await result.base.store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET author_account_id = ?", arguments: [CallJSON.boris])
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
        }
        try await result.settle()
        return result
    }
    private func mark(_ f: ChatNativeActionFixture) throws -> Int {
        try f.base.store.queue.read { try ChatUnread.readSequence($0, channel: f.model.channel, thread: nil) }
    }

    func testNativeVisitRegistersAndDisposesOnlyItsNotificationPlace() async throws {
        let before = ChatNotifications.places.mapValues { Set($0.keys) }
        let f = try await fixture()
        let place = f.model.notificationPlace(root: nil)
        let sibling = UUID()
        ChatNotifications.show(place, view: sibling) { false }
        defer { ChatNotifications.hide(place, view: sibling) }
        ChatNotifications.appActive = { true }
        f.coordinator.scrollController.followBottom()
        try await f.settle()
        XCTAssertTrue(ChatNotifications.isLooking(place))
        XCTAssertEqual(ChatNotifications.places[place]?.count, (before[place]?.count ?? 0) + 2)
        f.view.isHidden = true
        try await f.host.settle()
        XCTAssertFalse(ChatNotifications.isLooking(place))
        f.view.isHidden = false
        try await f.settle()
        XCTAssertTrue(ChatNotifications.isLooking(place))
        f.dispose()
        XCTAssertNotNil(ChatNotifications.places[place]?[sibling])
        ChatNotifications.hide(place, view: sibling)
        XCTAssertEqual(ChatNotifications.places.mapValues { Set($0.keys) }, before)
    }

    func testNativeBottomReadsThroughExistingModelAfterPresentationGateDismisses() async throws {
        let f = try await fixture()
        let overlay = UUID()
        NavigationPresentationGate.setOverlay(overlay, window: f.host.window, presented: true)
        defer { NavigationPresentationGate.setOverlay(overlay, window: f.host.window, presented: false) }
        ChatNotifications.appActive = { true }
        f.coordinator.scrollController.followBottom()
        try await f.settle()
        XCTAssertEqual(try mark(f), 0)
        NavigationPresentationGate.setOverlay(overlay, window: f.host.window, presented: false)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 3)
    }

    func testHiddenPrefetchedOffscreenAndInactiveContentCannotRead() async throws {
        let f = try await fixture(count: 45)
        let scroll = f.coordinator.scrollController
        scroll.scrollTo(messageID: f.messages[0].id, alignment: .top)
        ChatNotifications.appActive = { true }
        let lastIndex = try XCTUnwrap(f.coordinator.messageIndex(f.messages.last!.id))
        _ = f.coordinator.tableView.view(atColumn: 0, row: lastIndex, makeIfNecessary: true)
        try await f.settle()
        XCTAssertFalse(scroll.visibleIDs.contains(f.messages.last!.id))
        XCTAssertFalse(scroll.atBottom)
        XCTAssertEqual(try mark(f), 0, "Prefetching the last row is not reading")

        f.view.isHidden = true
        scroll.followBottom()
        try await f.settle()
        XCTAssertEqual(try mark(f), 0)
        XCTAssertFalse(ChatNotifications.isLooking(f.model.notificationPlace(root: nil)))
        ChatNotifications.appActive = { false }
        f.view.isHidden = false
        try await f.settle()
        XCTAssertEqual(try mark(f), 0)
        f.model.canAutomaticallyRead = { false }
        ChatNotifications.appActive = { true }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 0, "The renderer cannot replace channel access authority")
        f.model.canAutomaticallyRead = { true }
        NavigationPresentationGate.recheck(f.host.window)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 45)
    }

    func testHeaderOnlyIntersectionDoesNotBecomeAVisibleMessage() async throws {
        let f = try await fixture(count: 3)
        let scroll = f.coordinator.scrollView, table = f.coordinator.tableView
        let index = try XCTUnwrap(f.coordinator.messageIndex(f.messages[0].id))
        let row = table.rect(ofRow: index)
        let body = try XCTUnwrap(f.coordinator.scrollController.bodyFrame(f.messages[0].id))
        XCTAssertGreaterThan(body.minY, row.minY + 8)
        f.coordinator.scrollController.stopFollowing()
        f.host.window.setContentSize(NSSize(width: 760, height: 8))
        f.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: row.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await f.host.settle()
        XCTAssertGreaterThan(table.rows(in: scroll.contentView.bounds).length, 0)
        XCTAssertEqual(f.coordinator.scrollController.visibleIDs, [])
        XCTAssertEqual(f.coordinator.scrollController.bodyFrames, [:])
        XCTAssertEqual(try mark(f), 0)

        // At the final inset the viewport is technically at bottom, but no
        // message body is presented. This isolates the visibility read gate
        // from the independent bottom/app-active gates above.
        f.coordinator.scrollController.followBottom()
        try await f.host.settle()
        XCTAssertTrue(f.coordinator.scrollController.atBottom)
        XCTAssertEqual(f.coordinator.scrollController.visibleIDs, [])
        ChatNotifications.appActive = { true }
        NavigationPresentationGate.recheck(f.host.window)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 0, "Bottom padding is not a presented message")
    }

    func testChannelUnknownBodySearchAndNavigationKeepTheirReadPolicies() async throws {
        let f = try await fixture()
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET has_fixed = 0 WHERE seq = 2")
        }
        try await f.settle()
        f.model.setSearching(true)
        ChatNotifications.appActive = { true }
        f.coordinator.scrollController.followBottom()
        try await f.settle()
        XCTAssertEqual(try mark(f), 0)
        XCTAssertFalse(ChatNotifications.isLooking(f.model.notificationPlace(root: nil)))
        f.model.setSearching(false)
        try await f.settle()
        XCTAssertEqual(try mark(f), 1, "Channel automatic reading stops before unknown fixed bodies")
        ChatNotifications.appActive = { false }
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET has_fixed = 1")
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
        }
        try await f.settle()
        f.model.navigate(to: try XCTUnwrap(f.model.message(f.messages[0].id)))
        ChatNotifications.appActive = { true }
        f.coordinator.scrollController.followBottom()
        try await f.settle()
        XCTAssertTrue(f.model.hasNavigationReturn)
        XCTAssertEqual(try mark(f), 0)
        XCTAssertFalse(ChatNotifications.isLooking(f.model.notificationPlace(root: nil)))
        f.coordinator.scrollController.jumpToLatest()
        try await f.settle()
        XCTAssertFalse(f.model.hasNavigationReturn)
        XCTAssertEqual(try mark(f), 3)
    }

    func testAQueuedRecheckCannotReadUnpresentedMessagesOrClobberSearchReturn() async throws {
        let f = try await fixture(count: 40)
        let controller = f.coordinator.scrollController
        controller.scrollTo(messageID: f.messages[10].id, alignment: .top)
        try await f.settle()
        let saved = try XCTUnwrap(f.model.positions[""])
        f.model.navigate(to: try XCTUnwrap(f.model.message(f.messages.last!.id)))
        try await f.settle()
        f.model.returnFromNavigation()
        let restored = try XCTUnwrap(f.model.positions[""])
        XCTAssertEqual(restored.anchor, saved.anchor)
        XCTAssertFalse(f.adapter.actions!.matchesPresented(f.coordinator.snapshot))
        NavigationPresentationGate.recheck(f.host.window)
        // Deliberately drain the queued callback without delivering a new snapshot.
        try await f.host.settle()
        XCTAssertEqual(f.model.positions[""], restored)
        try await f.settle()
        XCTAssertEqual(controller.position.anchor, restored.anchor)
        let restoredRow = try XCTUnwrap(f.coordinator.messageIndex(restored.anchor!))
        XCTAssertEqual(f.coordinator.tableView.rect(ofRow: restoredRow).minY,
            f.coordinator.scrollView.contentView.bounds.minY, accuracy: 0.75)

        controller.followBottom(); try await f.settle()
        ChatNotifications.appActive = { false }
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
            try db.execute(sql: "UPDATE messages SET text = text || ' updated' WHERE seq = 40")
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(f.adapter.actions!.matchesPresented(f.coordinator.snapshot))
        ChatNotifications.appActive = { true }
        NavigationPresentationGate.recheck(f.host.window)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 0)
        try await f.settle()
        XCTAssertEqual(try mark(f), 40)
        ChatNotifications.appActive = { false }
        let extra = UUID().uuidString.lowercased()
        try await f.base.store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
            try db.execute(sql: """
                INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                SELECT ?, channel_id, author_account_id, 41, created_at, 1, 1, 'New unpresented message', '[]', 1 FROM messages WHERE seq = 40
                """, arguments: [extra])
        }
        try await Task.sleep(for: .milliseconds(80))
        ChatNotifications.appActive = { true }
        NavigationPresentationGate.recheck(f.host.window)
        try await f.host.settle()
        XCTAssertEqual(try mark(f), 0, "A newly arrived model row must be presented before it can be read")
        try await f.settle()
        XCTAssertEqual(try mark(f), 41)
    }

    func testNotificationSuppressionSurvivesUnpresentedLiveAndHydratedMentionsWithoutReading() async throws {
        let f = try await fixture()
        let keptVisible = ChatNotifications.visible, keptPost = ChatNotifications.post
        let keptEmit = ChatNotifications.emit, keptBadge = ChatNotifications.badgeChanged
        defer {
            ChatNotifications.visible = keptVisible; ChatNotifications.post = keptPost
            ChatNotifications.emit = keptEmit; ChatNotifications.badgeChanged = keptBadge
        }
        var posted: [String] = [], emitted: [Bool] = []
        ChatNotifications.visible = { _, _, _ in true }
        ChatNotifications.post = { id, _ in posted.append(id) }
        ChatNotifications.emit = { emitted.append($0.isRead) }
        ChatNotifications.badgeChanged = {}
        let mentions = String(decoding: try JSONEncoder().encode([f.base.key.accountId]), as: UTF8.self)
        for hydrated in [false, true] {
            ChatNotifications.appActive = { false }
            let id = UUID().uuidString.lowercased(), sequence = hydrated ? 5 : 4
            try await f.base.store.queue.write { db in
                try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
                try db.execute(sql: """
                    INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                    SELECT ?, channel_id, author_account_id, ?, created_at, 1, ?, 'An unread mention', ?, 1 FROM messages WHERE seq = 3
                    """, arguments: [id, sequence, !hydrated, mentions])
            }
            if hydrated {
                try await f.settle()
                try await f.base.store.queue.write { db in
                    try db.execute(sql: "UPDATE messages SET has_mutable = 1, text = 'A hydrated mention' WHERE message_id = ?", arguments: [id])
                }
            }
            // Observe the model but deliberately withhold the next native snapshot.
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNotNil(f.model.message(id))
            XCTAssertFalse(f.adapter.actions!.matchesPresented(f.coordinator.snapshot))
            XCTAssertTrue(f.coordinator.scrollController.atBottom)
            ChatNotifications.appActive = { true }
            XCTAssertTrue(ChatNotifications.isLooking(f.model.notificationPlace(root: nil)))
            posted = []; emitted = []
            ChatNotifications.live(f.base.service, f.base.key, store: f.base.store, channel: f.model.channel, messageId: id)
            XCTAssertEqual(posted, [], "An active visible bottom pane suppresses notices before its snapshot commits")
            XCTAssertEqual(emitted, [true])
            NavigationPresentationGate.recheck(f.host.window)
            try await f.host.settle()
            XCTAssertEqual(try mark(f), 0, "Notification suppression must not bypass the durable-read presentation fence")
            try await f.settle()
            XCTAssertEqual(try mark(f), sequence)
        }
    }

    func testDetachReattachAndDisposalReleaseObserversAndPendingWork() async throws {
        let before = ChatNotifications.places.mapValues { Set($0.keys) }
        let f = try await fixture()
        let c = f.coordinator, lifecycle = c.lifecycle, scroll = c.scrollController
        try await f.settle()
        let counts = (lifecycle.observerCount, scroll.observerCount, scroll.inputMonitorCount)
        XCTAssertEqual(counts.0, 9)
        XCTAssertEqual(counts.1, 4)
        XCTAssertEqual(counts.2, 1)
        for _ in 0..<3 {
            lifecycle.schedule()
            f.host.window.contentView = nil
            XCTAssertEqual(lifecycle.observerCount, 0)
            XCTAssertEqual(scroll.observerCount, 0)
            XCTAssertEqual(scroll.inputMonitorCount, 0)
            XCTAssertEqual(lifecycle.pendingWorkCount, 0)
            XCTAssertEqual(scroll.pendingPublicationCount, 0)
            XCTAssertEqual(ChatNotifications.places.mapValues { Set($0.keys) }, before)
            f.host.window.contentView = f.view
            try await f.settle()
            XCTAssertEqual(lifecycle.observerCount, counts.0)
            XCTAssertEqual(scroll.observerCount, counts.1)
            XCTAssertEqual(scroll.inputMonitorCount, counts.2)
        }
        lifecycle.schedule()
        c.dispose()
        c.dispose()
        try await f.host.settle()
        XCTAssertEqual(lifecycle.observerCount + scroll.observerCount + scroll.inputMonitorCount
            + lifecycle.pendingWorkCount + scroll.pendingPublicationCount, 0)
        XCTAssertEqual(ChatNotifications.places.mapValues { Set($0.keys) }, before)
        XCTAssertNil(c.editorSession)
        XCTAssertNil(c.tableView.dataSource)
        XCTAssertNil(c.tableView.delegate)
    }

    func testTwoWindowsAndInvalidatedActionsDoNotSuppressForAnotherVisit() async throws {
        let first = try await fixture(), second = try await fixture()
        let place = first.model.notificationPlace(root: nil)
        ChatNotifications.appActive = { true }
        APQuietSelectWindow(first.host.window)
        first.coordinator.scrollController.followBottom()
        second.coordinator.scrollController.followBottom()
        try await first.settle(); try await second.settle()
        XCTAssertTrue(ChatNotifications.isLooking(place))
        first.dispose()
        XCTAssertFalse(ChatNotifications.isLooking(place), "Remaining non-key window must not suppress")
        APQuietSelectWindow(second.host.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second.host.window)
        try await second.host.settle()
        XCTAssertTrue(ChatNotifications.isLooking(place))
        let oldActions = try XCTUnwrap(second.adapter.actions)
        second.adapter.invalidate()
        XCTAssertNil(oldActions.notificationPlace, "A retained callback cannot keep an invalid visit alive")
        XCTAssertFalse(ChatNotifications.isLooking(place), "Invalid scopes stop suppressing synchronously")
        second.coordinator.lifecycle.schedule()
        try await second.host.settle()
        XCTAssertNil(ChatNotifications.places[place])
    }
}
