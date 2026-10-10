import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatUnreadBoundaryTests: XCTestCase {
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let team = "f5000000-0000-4000-8000-000000000004"
    private var directory: URL!
    private var cleanupDirectory: URL!
    private var scope: TeamServiceTestScope!
    private var me: String { CallJSON.anna }
    private var key: ChatOrgKey {
        ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: me,
                   orgId: "f5000000-0000-4000-8000-000000000005")
    }

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("unread-boundary-\(UUID())")
        cleanupDirectory = directory
    }

    override func tearDown() async throws {
        scope.close()
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }

    private func store() throws -> ChatStore {
        let store = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        try write(store) { db in
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES (?, 'Team', 1)", arguments: [team])
            try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at) VALUES (?, ?, 'New', 0, 1, 1, ?, 'now')", arguments: [channel, team, me])
            try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES (?, 1, 0)", arguments: [channel])
            try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [channel])
            try db.execute(sql: "UPDATE meta SET me = ?, rights_in_doubt = 0", arguments: [me])
        }
        return store
    }

    private func wire(_ id: String, seq: Int, root: String? = nil, own: Bool = false, deleted: Bool = false) throws -> ChatMessageWire {
        let value: [String: Any] = ["message_id": id, "channel_id": channel, "thread_root_id": root as Any? ?? NSNull(),
            "author_account_id": own ? me : CallJSON.boris, "text": "Message \(id)",
            "mentions": [["account_id": me]], "revision": deleted ? 2 : 1, "seq": seq, "created_at": "2026-10-06T10:00:00Z",
            "deleted_at": deleted ? "2026-10-06T11:00:00Z" : NSNull()]
        return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func post(_ store: ChatStore, _ id: String, seq: Int, root: String? = nil, own: Bool = false) throws {
        let message = try wire(id, seq: seq, root: root, own: own)
        try write(store) { try ChatMessages.write($0, message) }
    }

    private func model(_ store: ChatStore, root: String? = nil) -> ChatChannelModel {
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        model.beginReading(root: nil)
        if let root { model.openThread(root); model.beginReading(root: root) }
        return model
    }

    private func write(_ store: ChatStore, _ body: (Database) throws -> Void) throws {
        try store.queue.write(body)
    }

    private func read<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T {
        try store.queue.read(body)
    }

    private func count(_ store: ChatStore) throws -> Int {
        try store.queue.read { try ChatUnread.count($0, channel: channel, me: me).count }
    }

    private func mark(_ store: ChatStore, root: String? = nil) throws -> Int {
        try store.queue.read { try ChatUnread.readSequence($0, channel: channel, thread: root) }
    }

    private func mentions(_ store: ChatStore) throws -> Int {
        try store.queue.read { try ChatUnread.unreadMentions($0) }
    }

    private func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Observation did not settle", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testOverlayBlocksChatReadAndClosingRechecksTheCurrentBoundary() async throws {
        final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isVisible: Bool { true }
        }
        let store = try store()
        try post(store, "first", seq: 1)
        let model = model(store)
        let box = WindowBox(), view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = KeyWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; box.view = view
        let token = UUID()
        defer {
            NavigationPresentationGate.setOverlay(token, window: window, presented: false)
            model.endReading(root: nil); window.contentView = nil; window.close()
        }
        NavigationPresentationGate.setOverlay(token, window: window, presented: true)
        model.readIfLooking(root: nil, appActive: true, shown: box.shown, atBottom: true)
        XCTAssertEqual(try mark(store), 0)
        try post(store, "second", seq: 2)
        try await wait { model.feed.messages.count == 2 }
        let observer = NotificationCenter.default.addObserver(forName: NavigationPresentationGate.didChange, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { model.readIfLooking(root: nil, appActive: true, shown: box.shown, atBottom: true) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.canAutomaticallyRead = { false }
        NavigationPresentationGate.setOverlay(token, window: window, presented: false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(try mark(store), 0, "A queued visibility recheck cannot acknowledge an obsolete scope")
        model.canAutomaticallyRead = { true }
        NavigationPresentationGate.recheck(window)
        try await wait { (try? self.mark(store)) == 2 }
        XCTAssertEqual(try count(store), 0)
    }

    func testOwnPostsFromAnotherMacAdvanceReadAndNeverCreateDivider() async throws {
        let store = try store()
        try post(store, "foreign", seq: 1)
        let model = model(store)
        XCTAssertEqual(model.feed.unreadID, "foreign")
        try post(store, "other-mac", seq: 2, own: true)
        try await wait { model.feed.messages.count == 2 }
        XCTAssertNil(model.feed.unreadID)
        XCTAssertEqual(try mark(store), 2)
        XCTAssertEqual(try count(store), 0)
        XCTAssertEqual(try mentions(store), 0)
        try post(store, "other-mac-again", seq: 3, own: true)
        try await wait { model.feed.messages.count == 3 }
        XCTAssertNil(model.feed.unreadID)
        XCTAssertEqual(try mark(store), 3)
    }

    func testLegacyOwnRowsAndUnknownAuthorsCannotStartDivider() throws {
        let store = try store()
        try post(store, "mine", seq: 1, own: true)
        try write(store) { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq) VALUES ('unknown', ?, 2)", arguments: [channel])
        }
        XCTAssertNil(model(store).feed.unreadID)
        try post(store, "foreign", seq: 3)
        XCTAssertEqual(model(store).feed.unreadID, "foreign")
        XCTAssertEqual(try count(store), 1,
                       "an unresolved placeholder is neither unread nor a divider")
    }

    func testPendingSendReadsImmediatelyAndAckAdvancesThroughOwnSequence() async throws {
        let store = try store()
        try post(store, "foreign", seq: 1)
        let model = model(store)
        try write(store) { db in
            try ChatMessages.insertSending(db, id: "pending", channel: channel, root: nil, author: me, text: "sent", mentions: [], at: "now")
        }
        try await wait { model.feed.messages.count == 2 }
        XCTAssertEqual(try mark(store), 1)
        XCTAssertNil(model.feed.unreadID, "a send from another window dismisses the visible boundary")
        try write(store) { db in
            try ChatMessages.apply(db, ChatEvent(stream: "channel:\(channel)", seq: 2, id: "ack", type: "message.post", actor: nil,
                body: .object(["message_id": .string("pending"), "revision": .number(1)]), commandId: nil, at: "now"))
            XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel), 2, "the sequence ACK reads through my pending post")
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 1")
            XCTAssertEqual(try ChatUnread.count(db, channel: channel, me: me).count, 0,
                           "a pending row already knows its author before has_fixed arrives")
        }
        try post(store, "pending", seq: 2, own: true)
        try await wait { model.feed.messages.last?.hasFixed == true }
        XCTAssertEqual(try mark(store), 2)
        XCTAssertNil(model.feed.unreadID)
    }

    func testDismissedPendingPostCannotResurrectVisitBoundary() async throws {
        let store = try store()
        try post(store, "foreign", seq: 1)
        let model = model(store)
        try write(store) { db in
            try ChatMessages.insertSending(db, id: "pending", channel: channel, root: nil, author: me, text: "sent", mentions: [], at: "now")
        }
        try await wait { model.feed.messages.count == 2 && !model.feed.boundaryDismissed }
        XCTAssertNil(model.feed.unreadID)
        try write(store) { try $0.execute(sql: "DELETE FROM messages WHERE message_id = 'pending'") }
        try await wait { model.feed.messages.count == 1 }
        XCTAssertNil(model.feed.unreadID)
    }

    func testEntryBoundaryStaysWhileAutomaticReadingAdvancesAndNeverExpands() async throws {
        let store = try store()
        try post(store, "first", seq: 1)
        let model = model(store)
        XCTAssertEqual(model.feed.unreadID, "first")
        model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try mark(store), 1)
        XCTAssertEqual(model.feed.unreadID, "first")
        try post(store, "live", seq: 2)
        try await wait { model.feed.messages.count == 2 }
        model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try mark(store), 2)
        XCTAssertEqual(model.feed.unreadID, "first")
        XCTAssertEqual(try mentions(store), 0)
        XCTAssertEqual(ChatFeedLayout.rows(model.feed.messages, unreadID: model.feed.unreadID).filter(\.startsUnread).map(\.id), ["first"])
    }

    func testVisibleLiveArrivalsDoNotInventBoundaryInChannelOrThread() async throws {
        for root: String? in [nil, "root"] {
            let store = try storeForConversation(root)
            let model = model(store, root: root)
            try post(store, "live", seq: 2, root: root)
            try await wait { model.conversationMessages(root: root).contains { $0.id == "live" } }
            model.readIfLooking(root: root, appActive: true, shown: true, atBottom: true)
            XCTAssertNil(root == nil ? model.feed.unreadID : model.threadUnreadID)
            XCTAssertEqual(try mark(store, root: root), 2)
            XCTAssertEqual(try mentions(store), 0)
        }
    }

    func testOpeningThreadIncludesUnreadHistoryThatLoadsAfterOpening() async throws {
        let store = try store()
        try post(store, "root", seq: 1, own: true)
        try write(store) { try ChatStore.setCursorValue($0, "channel:\(channel)", 10) }
        let model = model(store, root: "root")
        XCTAssertNil(model.threadUnreadID)
        let replies = try [wire("earlier", seq: 2, root: "root"), wire("later", seq: 9, root: "root")]
        try write(store) { try ChatMessages.applyThread($0, channel: channel, root: "root", epoch: 1,
            page: ChatMessagesPage(messages: replies, next: nil, head: 10)) }
        try await wait { model.thread.count == 3 }
        XCTAssertEqual(model.threadUnreadID, "earlier")
        model.markThreadRead("root")
        XCTAssertNil(model.threadUnreadID)
        XCTAssertEqual(try mark(store, root: "root"), 10)
    }

    func testExplicitReadAcknowledgesUnloadedHistoryWhileAutomaticReadStopsAtPlaceholder() throws {
        for root: String? in [nil, "root"] {
            let store = try storeForConversation(root)
            try write(store) { db in
                try db.execute(sql: "INSERT INTO messages (message_id, channel_id, thread_root_id, seq) VALUES ('placeholder', ?, ?, 2)", arguments: [channel, root])
                try ChatStore.setCursorValue(db, "channel:\(channel)", 5)
            }
            try post(store, "foreign", seq: 3, root: root)
            let model = model(store, root: root)
            model.readIfLooking(root: root, appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try mark(store, root: root), 1)
            model.markConversationRead(root: root)
            XCTAssertEqual(try mark(store, root: root), 5)
            XCTAssertNil(root == nil ? model.feed.unreadID : model.threadUnreadID)
            XCTAssertEqual(try count(store), 0)
            XCTAssertEqual(try mentions(store), 0)
            try post(store, "placeholder", seq: 2, root: root)
            XCTAssertEqual(try mentions(store), 0, "a late body cannot resurrect explicitly acknowledged history")
        }
    }

    func testPlaceholderIsExcludedUntilHydrationAndAutomaticReadingResumes() async throws {
        // A WS placeholder initially looks like a root; its body may reveal a reply or our own post.
        for (root, own) in [(nil as String?, false), ("root", false), (nil, true)] {
            let store = try storeForConversation(root)
            try write(store) { db in
                try ChatMessages.apply(db, ChatEvent(stream: "channel:\(channel)", seq: 2, id: "event", type: "message.post", actor: nil,
                    body: .object(["message_id": .string("placeholder"), "revision": .number(1)]), commandId: nil, at: "now"))
                try db.execute(sql: "UPDATE meta SET channels_served = 1")
            }
            try post(store, "tail", seq: 3)
            let model = model(store, root: root)
            XCTAssertEqual(try count(store), 1, "only the fully known tail belongs in the badge")
            XCTAssertEqual(try read(store) { try ChatInbox.read($0, kind: .unread, account: me, session: nil).map(\.id) }, ["tail"])
            model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try mark(store), 1, "do not mark an unknown message read before its body arrives")
            try post(store, "placeholder", seq: 2, root: root, own: own)
            try await wait {
                model.feed.messages.allSatisfy(\.hasFixed)
                    && (root == nil || model.thread.contains { $0.id == "placeholder" && $0.hasFixed })
            }
            XCTAssertEqual(try count(store), root == nil && !own ? 2 : 1, "hydrated foreign roots count until viewed")
            model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try mark(store), 3, "hydration must release the channel read mark")
            XCTAssertEqual(try count(store), 0)
            if let root {
                XCTAssertEqual(try read(store) { try ChatUnread.unreadRepliesByChannel($0)[channel] }, 1)
                model.readIfLooking(root: root, appActive: true, shown: true, atBottom: true)
                XCTAssertEqual(try mark(store, root: root), 2)
            }
            XCTAssertTrue(try read(store) { try ChatInbox.read($0, kind: .unread, account: me, session: nil).isEmpty })
        }
    }

    func testThreadReadRemovesRootFromBadgeWithoutReadingOtherRoots() throws {
        let store = try store()
        try post(store, "earlier", seq: 1)
        try post(store, "root", seq: 2)
        try post(store, "reply", seq: 3, root: "root")
        try post(store, "later", seq: 4)
        try write(store) { try $0.execute(sql: "UPDATE meta SET channels_served = 1") }
        let model = model(store, root: "root")
        model.readIfLooking(root: "root", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try mark(store), 0, "the channel's other roots have not been viewed")
        XCTAssertEqual(try count(store), 2)
        XCTAssertEqual(try store.queue.read { try ChatInbox.read($0, kind: .unread, account: me, session: nil).map(\.id) }, ["earlier", "later"])
        XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT read FROM notified WHERE object_id = 'root'") }, 1)
        try write(store) { try ChatUnread.markRead($0, channel: channel, upTo: 1) }
        let revisited = self.model(store)
        XCTAssertEqual(revisited.feed.unreadID, "later", "a root already viewed in its thread cannot start the next visit's divider")
        XCTAssertEqual(try count(store), 1)
    }

    func testReadMarkFailureIsLoggedAndNextAutomaticReadRetries() throws {
        for root: String? in [nil, "root"] {
            let store = try storeForConversation(root)
            try post(store, "foreign", seq: 2, root: root)
            try write(store) { db in
                try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, thread_root_id) VALUES ('foreign', 'mention', ?, 2, ?)",
                               arguments: [channel, root])
                // Fail after the mark was written: the entire transaction must roll back.
                try db.execute(sql: "CREATE TRIGGER fail_read BEFORE UPDATE OF read ON notified BEGIN SELECT RAISE(ABORT, 'read mark test failure'); END")
            }
            let model = model(store, root: root)
            var logs: [String] = []
            model.log = { logs.append($0) }
            let before = try mark(store, root: root)
            model.readIfLooking(root: root, appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try mark(store, root: root), before)
            XCTAssertEqual(try mentions(store), 1)
            XCTAssertEqual(logs.count, 1)
            XCTAssertTrue(logs.first?.contains("read mark test failure") == true)
            XCTAssertTrue(logs.first?.contains(channel) == true)
            if let root { XCTAssertTrue(logs.first?.contains(root) == true) }
            XCTAssertEqual(root == nil ? model.feed.unreadID : model.threadUnreadID, "foreign")
            model.markConversationRead(root: root)
            XCTAssertEqual(try mark(store, root: root), before)
            XCTAssertEqual(root == nil ? model.feed.unreadID : model.threadUnreadID, "foreign",
                           "a failed explicit read must not dismiss the visit boundary either")
            XCTAssertEqual(logs.count, 2)
            try write(store) { try $0.execute(sql: "DROP TRIGGER fail_read") }
            model.readIfLooking(root: root, appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try mark(store, root: root), 2)
            XCTAssertEqual(try mentions(store), 0)
            XCTAssertEqual(logs.count, 2, "retry the same mark without another message or an error on success")
        }
    }

    private func storeForConversation(_ root: String?) throws -> ChatStore {
        // Each case uses a fresh, isolated database.
        directory = directory.appendingPathComponent(UUID().uuidString)
        let store = try store()
        try post(store, root ?? "old", seq: 1, own: true)
        return store
    }

    func testHiddenInactiveScrolledAndSearchingViewsCannotReadArrivals() async throws {
        let store = try store()
        let model = model(store)
        try post(store, "live", seq: 1)
        try await wait { model.feed.messages.count == 1 }
        for (active, shown, bottom) in [(false, true, true), (true, false, true), (true, true, false)] {
            model.readIfLooking(root: nil, appActive: active, shown: shown, atBottom: bottom)
            XCTAssertEqual(try mark(store), 0)
        }
        model.setSearching(true)
        model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try mark(store), 0)
        XCTAssertNil(model.feed.unreadID, "no live arrival belongs to the entry range")
        XCTAssertEqual(try mentions(store), 1)
        model.setSearching(false)
        model.endReading(root: nil)
        model.beginReading(root: nil)
        XCTAssertEqual(model.feed.unreadID, "live", "returning starts a new visit at the persisted mark")
        model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        model.endReading(root: nil)
        model.beginReading(root: nil)
        XCTAssertNil(model.feed.unreadID)
    }

    func testNativeTabHidingEndsVisitEvenWhenModelAndViewSurvive() async throws {
        let store = try store()
        try post(store, "first", seq: 1)
        let model = model(store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: window.contentView!.bounds)
        let reader = WindowReader.Reader(frame: parent.bounds)
        var visibility: [Bool] = []
        reader.visibilityChanged = { visible in
            visibility.append(visible)
            if visible { model.beginReading(root: nil) } else { model.endReading(root: nil) }
        }
        parent.addSubview(reader)
        window.contentView?.addSubview(parent)
        try await wait { visibility.last == true }
        model.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(model.feed.unreadID, "first")
        parent.isHidden = true
        try await wait { visibility.last == false }
        XCTAssertNil(model.feed.unreadID)
        parent.isHidden = false
        try await wait { visibility.last == true }
        XCTAssertNil(model.feed.unreadID)
    }

    func testMountedTimelineReadsLiveBottomAndResetsBoundaryOnTabReturn() async throws {
        final class Window: NSWindow {
            override var isKeyWindow: Bool { true }
        }
        let wasActive = ChatNotifications.appActive
        ChatNotifications.appActive = { true }
        defer { ChatNotifications.appActive = wasActive }
        for root: String? in [nil, "root"] {
            let store = try storeForConversation(root)
            try post(store, "entry", seq: 2, root: root)
            let model = model(store, root: root)
            let host = NSHostingView(rootView: AnyView(ChatTimelineView(model: model, root: root, members: [], mentionable: [],
                me: me, archived: false, ownerModel: nil).frame(width: 600, height: 400)))
            let window = Window(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await wait {
                host.layoutSubtreeIfNeeded()
                return (try? self.mark(store, root: root)) == 2
            }
            XCTAssertEqual(root == nil ? model.feed.unreadID : model.threadUnreadID, "entry")
            host.isHidden = true
            try await wait { (root == nil ? model.feed.unreadID : model.threadUnreadID) == nil }
            host.isHidden = false
            // Let the real NSView unhide callback capture the new entry before delivery.
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            try post(store, "live", seq: 3, root: root)
            try await wait {
                host.layoutSubtreeIfNeeded()
                return (try? self.mark(store, root: root)) == 3
            }
            XCTAssertNil(root == nil ? model.feed.unreadID : model.threadUnreadID)
            XCTAssertEqual(try mentions(store), 0)
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
        }
    }

    func testExplicitReadAndEscapeClearChannelBoundary() throws {
        for escape in [false, true] {
            let store = try storeForConversation(nil)
            try post(store, "foreign", seq: 2)
            let model = model(store)
            XCTAssertEqual(model.feed.unreadID, "foreign")
            if escape { XCTAssertTrue(model.dismissTransient()) } else { model.markRead() }
            XCTAssertNil(model.feed.unreadID)
            XCTAssertEqual(try mark(store), 2)
            XCTAssertEqual(try mentions(store), 0)
        }
    }

    func testThreadBoundaryReadEscapeAndReopenDoNotReadSiblingThread() throws {
        let store = try store()
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 2, root: "root")
        try post(store, "sibling", seq: 3, root: "other")
        let model = model(store, root: "root")
        XCTAssertEqual(model.threadUnreadID, "reply")
        model.markRead()
        XCTAssertEqual(try mentions(store), 2, "reading the channel leaves replies unread")
        model.readIfLooking(root: "root", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(model.threadUnreadID, "reply")
        XCTAssertEqual(try mentions(store), 1)
        XCTAssertTrue(model.dismissTransient())
        XCTAssertNil(model.threadRoot)
        XCTAssertNil(model.threadUnreadID)
        model.openThread("root")
        XCTAssertNil(model.threadUnreadID)
        XCTAssertEqual(try mark(store, root: "other"), 0)
        XCTAssertEqual(try mentions(store), 1)
    }

    func testOwnReplyReadsOnlyItsThreadIncludingRepliesDeliveredLaterBelowItsMark() async throws {
        let store = try store()
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 2, root: "root")
        try post(store, "sibling", seq: 3, root: "other")
        let model = model(store, root: "root")
        try post(store, "own-reply", seq: 5, root: "root", own: true)
        try await wait { model.thread.contains { $0.id == "own-reply" } }
        XCTAssertNil(model.threadUnreadID)
        XCTAssertEqual(try mark(store), 0)
        XCTAssertEqual(try mark(store, root: "root"), 5)
        XCTAssertEqual(try mentions(store), 1, "the visible root is read; the sibling thread remains unread")
        XCTAssertEqual(try count(store), 0, "the thread read receipt clears its root without advancing the channel cursor")
        try post(store, "late", seq: 4, root: "root")
        try write(store) { db in
            XCTAssertNil(try ChatUnread.owe(db, messageId: "late", me: me))
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            try db.execute(sql: "DELETE FROM messages WHERE message_id = 'own-reply'")
        }
        let reopened = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        XCTAssertEqual(try mark(reopened, root: "root"), 5, "thread read progress survives cache eviction and reopening")
        XCTAssertNil(self.model(reopened, root: "root").threadUnreadID)
        XCTAssertNil(self.model(reopened).feed.unreadID, "the root's read receipt survives reopening too")
    }

    func testOwnDeliveryThroughSnapshotHistoryAndSingleReadIsMonotonic() throws {
        let store = try store()
        try write(store) { db in
            try ChatMessages.applyWindow(db, channel: channel, head: 10, messages: [wire("own", seq: 8, own: true)], before: nil)
            XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel), 8)
            try ChatMessages.applyHistory(db, channel: channel, page: ChatMessagesPage(messages: [wire("older", seq: 3, own: true)], next: nil, head: 10))
            XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel), 8)
            try ChatMessages.applyOne(db, id: "single", page: ChatMessagesPage(messages: [wire("single", seq: 11, own: true)], next: nil, head: 11))
            XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel), 11)
        }
    }

    func testFirstWindowAndNewGenerationRetainHeadBaselineForThreads() throws {
        let store = try store()
        for initial in [true, false] {
            try write(store) { db in
                if initial { try db.execute(sql: "DELETE FROM read_marks") }
                else {
                    try db.execute(sql: "DELETE FROM notified")
                    try db.execute(sql: "UPDATE read_marks SET last_read_seq = -1")
                }
                try ChatMessages.applyWindow(db, channel: channel, head: 10, messages: [wire("own", seq: 8, own: true)], before: nil)
                XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel), 10)
                XCTAssertEqual(try ChatUnread.readSequence(db, channel: channel, thread: "hidden"), 10)
            }
        }
    }

    func testDeletingNotificationDoesNotReadEarlierThreadReplies() throws {
        let store = try store()
        try post(store, "root", seq: 1)
        try post(store, "unread", seq: 2, root: "root")
        try post(store, "deleted", seq: 10, root: "root")
        try write(store) { db in
            XCTAssertEqual(try ChatUnread.owe(db, messageId: "deleted", me: me), "mention")
            try ChatMessages.write(db, wire("deleted", seq: 10, root: "root", deleted: true))
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'deleted'"), true)
        }
        XCTAssertEqual(try mark(store, root: "root"), 0)
        XCTAssertEqual(try mentions(store), 2)
        XCTAssertEqual(model(store, root: "root").threadUnreadID, "unread")
    }

    func testThreadReadWithdrawsEvictedReplyNotices() throws {
        let store = try store()
        try post(store, "reply", seq: 2, root: "root")
        try write(store) { db in
            XCTAssertEqual(try ChatUnread.owe(db, messageId: "reply", me: me), "mention")
            try db.execute(sql: "DELETE FROM messages WHERE message_id = 'reply'")
            XCTAssertEqual(try ChatUnread.markRead(db, channel: channel, upTo: 5, thread: "root"), ["reply"])
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'reply'"), true)
        }
        XCTAssertEqual(try mark(store, root: "root"), 5)
    }

    func testThreadReadMarksExpireWithAccessAndGeneration() throws {
        for revoked in [true, false] {
            let store = try storeForConversation(nil)
            try store.finishGeneration("g1")
            try write(store) { try ChatUnread.markRead($0, channel: channel, upTo: 100, thread: "root") }
            if revoked {
                try write(store) { db in
                    try db.execute(sql: "DELETE FROM channels")
                    try ChatMessages.dropOrphans(db)
                }
            } else {
                try store.beginGeneration("g2", keeping: [])
            }
            XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM thread_read_marks") }, 0)
        }
    }

    func testUpgradeKeepsViewedThreadProgressButNotDeletedNotifications() throws {
        let queue = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(queue, upTo: "release-15-ux2-draft-options")
        try queue.write { db in
            for (id, seq, deleted) in [("read", 2, false), ("deleted", 10, true)] {
                try db.execute(sql: "INSERT INTO messages (message_id, channel_id, thread_root_id, seq, has_fixed, deleted_at) VALUES (?, ?, 'root', ?, 1, ?)",
                               arguments: [id, channel, seq, deleted ? "now" : nil])
                try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, thread_root_id, seq, read) VALUES (?, 'mention', ?, 'root', ?, 1)",
                               arguments: [id, channel, seq])
            }
        }
        try ChatStoreMigrations.cache.migrate(queue)
        XCTAssertEqual(try queue.read { try ChatUnread.readSequence($0, channel: channel, thread: "root") }, 2)
    }

    func testScrollBadgeExcludesOwnPendingAndRemoteMessages() throws {
        let store = try store()
        let model = model(store)
        var position = ChatScrollPosition()
        try post(store, "old", seq: 1)
        let old = try XCTUnwrap(model.message("old"))
        _ = position.update([old], me: me)
        position.measured(bottom: false, anchor: old.id)
        try post(store, "own", seq: 2, own: true)
        let own = try XCTUnwrap(model.message("own"))
        var pending = own; pending.messageId = "pending"; pending.seq = nil; pending.localState = .sending
        XCTAssertFalse(position.update([old, own, pending], me: me))
        XCTAssertTrue(position.unseen.isEmpty)
    }

    func testBothComposerSendPathsClearBoundaryBeforeAckAndRejectedSendDoesNot() async throws {
        for ux1 in [false, true] {
            let fixture = try await ChatChannelExecutionTests.Fixture(root: directory.appendingPathComponent(UUID().uuidString))
            fixture.service.serverCapabilities[fixture.key.server] = ux1 ? ["chat.channel_ux1"] : []
            fixture.service.isServerKnown = { _, _ in true }
            let store = fixture.store
            try write(store) { db in
                try db.execute(sql: "INSERT OR IGNORE INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [channel])
                try db.execute(sql: "INSERT OR IGNORE INTO channel_windows (channel_id, epoch, bottom_seq) VALUES (?, 1, 0)", arguments: [channel])
            }
            try post(store, "unread", seq: 1)
            let model = self.model(store); model.service = fixture.service
            XCTAssertEqual(model.feed.unreadID, "unread")
            XCTAssertFalse(model.send("", root: nil, members: []))
            XCTAssertEqual(model.feed.unreadID, "unread")
            XCTAssertEqual(try mark(store), 0)
            XCTAssertTrue(model.send("answer", root: nil, members: []), model.problem ?? "")
            XCTAssertNil(model.feed.unreadID)
            XCTAssertEqual(try mark(store), 1)
            XCTAssertEqual(try mentions(store), 0)
            fixture.sender?.hold()
            await fixture.service.disconnect()
        }
    }
}
