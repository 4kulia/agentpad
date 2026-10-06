import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatInboxTests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private let me = "me_1"
    private var key: ChatOrgKey {
        ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: me, orgId: "org")
    }

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-inbox-\(UUID())")
    }
    override func tearDown() async throws {
        scope.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.write(body) }
    private func read<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.read(body) }

    private func fixture(subdirectory: String? = nil) throws -> (ChatStore, ChatOrgModel) {
        let location = subdirectory.map { directory.appendingPathComponent($0) } ?? directory!
        let store = try ChatStore.open(files: ChatFiles(directory: location), key: key).store
        try write(store) { db in
            try db.execute(sql: "UPDATE meta SET me = ?, rights_in_doubt = 0, rights_session = 's', channels_served = 1", arguments: [me])
            try db.execute(sql: "INSERT INTO members (account_id, handle, name, role) VALUES (?, 'andrew', 'Andrew', 'member'), ('other', 'sasha', 'Sasha', 'member')", arguments: [me])
            for (team, mine) in [("team", true), ("hidden-team", false)] {
                try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES (?, ?, ?)", arguments: [team, team == "team" ? "General" : "Private", mine])
            }
            for (id, team, name) in [("alpha", "team", "Design"), ("beta", "team", "Engineering"), ("hidden", "hidden-team", "Hidden")] {
                try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at) VALUES (?, ?, ?, 0, 1, 1, ?, 'now')", arguments: [id, team, name, me])
                try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [id])
                try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES (?, 1, 0)", arguments: [id])
            }
        }
        let org = ChatOrgModel(me: me) { _, _ in XCTFail("The inbox sends no commands"); return "unexpected" }
        org.key = key; org.session = "s"; org.isFollowed = { _ in true }; org.follow(store)
        return (store, org)
    }

    private func post(_ store: ChatStore, _ id: String, seq: Int, channel: String = "alpha", root: String? = nil,
                      author: String = "other", mentions: [String]? = nil, text: String? = nil,
                      at: String = "2026-10-06T10:00:00Z", deleted: Bool = false) throws {
        let value: [String: Any] = ["message_id": id, "channel_id": channel, "thread_root_id": root as Any? ?? NSNull(),
            "author_account_id": author, "text": text ?? "Message \(id)", "mentions": (mentions ?? [me]).map { ["account_id": $0] },
            "revision": deleted ? 2 : 1, "seq": seq, "created_at": at, "deleted_at": deleted ? at as Any : NSNull()]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
        try write(store) { try ChatMessages.write($0, wire) }
    }
    private func entries(_ store: ChatStore, _ kind: ChatInboxKind = .unread) throws -> [ChatInbox.Entry] {
        try read(store) { try ChatInbox.read($0, kind: kind, account: me, session: "s") }
    }
    private func inbox(_ store: ChatStore, _ org: ChatOrgModel, kind: ChatInboxKind = .unread) -> ChatInboxModel {
        let result = ChatInboxModel(ref: ChatInboxRef(key, kind: kind)); result.follow(store, org: org); return result
    }
    private func refresh(_ store: ChatStore, _ org: ChatOrgModel) throws { org.set(try store.queue.read(ChatOrgView.read)) }
    private func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Observation did not settle", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testUnreadGroupsIncludeRepliesAndMatchSidebarWithoutReadingOnOpen() throws {
        let (store, org) = try fixture()
        try post(store, "self", seq: 1, author: me)
        try post(store, "root", seq: 2)
        try post(store, "reply", seq: 3, root: "root", mentions: [])
        try post(store, "second", seq: 1, channel: "beta")
        try post(store, "hidden", seq: 5, channel: "hidden")
        let model = inbox(store, org)
        XCTAssertEqual(try entries(store).map(\.id), ["root", "reply", "second"], "the SQL projection itself is access-scoped")
        XCTAssertEqual(model.entries(org).map(\.id), ["root", "reply", "second"])
        try refresh(store, org)
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 3)
        XCTAssertEqual(sidebar.teams.flatMap(\.channels).map { $0.unread.count }, [2, 1])
        XCTAssertEqual(try read(store) { try ChatUnread.count($0, channel: "alpha", me: me).count }, 1, "F4 root count retains its meaning")
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 1, "opening a list does not read it")
        var changed = org.view; changed.unreadRepliesByChannel = [:]
        XCTAssertNotEqual(changed, org.view, "reply-only changes invalidate the sidebar")
    }

    func testMentionHistoryUsesExactRecipientsNewestFirstAndF4ReadStatus() throws {
        let (store, org) = try fixture()
        try post(store, "own", seq: 1, author: me)
        try post(store, "read", seq: 2, at: "2026-10-05T10:00:00Z")
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 2) }
        try post(store, "unread", seq: 3)
        try post(store, "fractional", seq: 8, at: "2026-10-06T10:00:00.125Z")
        try post(store, "newest", seq: 1, channel: "beta", at: "2026-10-06T11:00:00Z")
        try post(store, "similar", seq: 4, mentions: ["meX1", "me_1_extra"])
        try post(store, "deleted", seq: 5, deleted: true)
        try post(store, "hidden", seq: 6, channel: "hidden")
        try post(store, "plain-text", seq: 7, mentions: [], text: "@andrew @here @channel")
        try write(store) { db in
            try ChatMessages.insertSending(db, id: "pending", channel: "beta", root: "draft-thread", author: me, text: "@andrew", mentions: [me], at: "now")
        }
        let model = inbox(store, org, kind: .mentions)
        XCTAssertEqual(model.entries(org).map(\.id), ["newest", "fractional", "unread", "read"])
        XCTAssertEqual(model.entries(org).map(\.unread), [true, true, true, false])
        XCTAssertEqual(try read(store) { try ChatUnread.unreadMentions($0) }, 3)
        XCTAssertEqual(try read(store) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notified") }, 0, "history does not depend on live banners")
        XCTAssertEqual(try write(store) { try ChatUnread.owe($0, messageId: "unread", me: me) }, "mention")
        for id in ["unread", "own", "read", "similar", "deleted", "plain-text", "pending"] {
            XCTAssertNil(try write(store) { try ChatUnread.owe($0, messageId: id, me: me) }, id)
        }
    }

    func testThreadAndChannelReadMarksRemainIndependentIncludingLateHistory() throws {
        let (store, _) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 5, root: "root")
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 10) }
        XCTAssertEqual(try entries(store).map(\.id), ["reply"])
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 8, thread: "root") }
        try post(store, "late", seq: 7, root: "root")
        try post(store, "other-thread", seq: 9, root: "another")
        try post(store, "new-root", seq: 11)
        XCTAssertEqual(try entries(store).map(\.id), ["other-thread", "new-root"])
        XCTAssertEqual(try entries(store, .mentions).filter(\.unread).map(\.id), ["new-root", "other-thread"])
    }

    func testMarkAllReadsKnownHeadsAndUnknownThreadsButNotNewPostsOrHiddenChannels() async throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 2, root: "root")
        try post(store, "hidden", seq: 3, channel: "hidden")
        try write(store) { db in
            _ = try ChatUnread.owe(db, messageId: "root", me: me)
            _ = try ChatUnread.owe(db, messageId: "reply", me: me)
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:alpha', 20)")
        }
        let channel = ChatChannelModel(key: key, channel: "alpha")
        channel.follow(store); channel.openThread("root"); channel.beginReading(root: "root")
        XCTAssertEqual(channel.feed.unreadID, "root"); XCTAssertEqual(channel.threadUnreadID, "reply")
        let model = inbox(store, org)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        model.markAllRead(org, service: service)
        try await wait { model.entries(org).isEmpty && channel.feed.unreadID == nil && channel.threadUnreadID == nil }
        XCTAssertNil(model.problem)
        XCTAssertEqual(try read(store) { try ChatUnread.unreadMentions($0) }, 0)
        XCTAssertEqual(try read(store) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notified WHERE read = 0") }, 0)
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "hidden") }, 0)
        try post(store, "late-thread", seq: 19, root: "not-loaded-before")
        try post(store, "new-thread", seq: 21, root: "not-loaded-before")
        try post(store, "new-root", seq: 22)
        XCTAssertEqual(try entries(store).map(\.id), ["new-thread", "new-root"])
        XCTAssertEqual(try entries(store, .mentions).filter(\.unread).count, 2)
    }

    func testAccessAndContextGateReadActionsAndNavigation() throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        let model = inbox(store, org)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() })
        let entry = try XCTUnwrap(model.entries(org).first)
        org.snapshotOwed = { true }
        XCTAssertTrue(model.entries(org).isEmpty)
        model.markAllRead(org, service: service)
        XCTAssertNil(ChatInboxNavigation.open(entry.message, ref: model.ref, org: org, workspace: workspace))
        XCTAssertEqual(try entries(store).map(\.id), ["root"])
        org.snapshotOwed = { false }
        for other in [ChatOrgKey(server: key.server, accountId: "another", orgId: key.orgId),
                      ChatOrgKey(server: key.server, accountId: me, orgId: "another"),
                      ChatOrgKey(server: try ChatServerAddress(parsing: "https://other.example.com"), accountId: me, orgId: key.orgId)] {
            org.key = other
            XCTAssertTrue(model.entries(org).isEmpty)
            XCTAssertEqual(model.ref.state(org), .notConnected)
        }
        org.key = key
        try write(store) { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
        // UI may not yet have received the DB observation: the transaction rechecks rights.
        model.markAllRead(org, service: service)
        XCTAssertTrue(try entries(store).isEmpty)
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 0)
        try write(store) { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 0, rights_session = 'new-session'") }
        XCTAssertTrue(try entries(store).isEmpty)
        try write(store) { try $0.execute(sql: "UPDATE meta SET rights_session = 's'; UPDATE teams SET mine = 0") }
        try refresh(store, org)
        XCTAssertTrue(model.entries(org).isEmpty)
        XCTAssertTrue(try entries(store, .mentions).isEmpty)
        XCTAssertEqual(try write(store) { try ChatInbox.markAllRead($0, account: me, session: "s") }, [])
    }

    func testObservationTracksNewEditsDeletesAndReadStatus() async throws {
        let (store, org) = try fixture()
        let model = inbox(store, org, kind: .mentions)
        try post(store, "root", seq: 1)
        try await wait { model.entries(org).count == 1 }
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 1) }
        try await wait { model.entries(org).first?.unread == false }
        try write(store) { try $0.execute(sql: "UPDATE messages SET mentions = '[]' WHERE message_id = 'root'") }
        try await wait { model.entries(org).isEmpty }
        try post(store, "second", seq: 2)
        try await wait { model.entries(org).count == 1 }
        try post(store, "second", seq: 2, deleted: true)
        try await wait { model.entries(org).isEmpty }
    }

    func testIndividualReadMarkersAndMarkAllSignalStayScoped() throws {
        let (store, org) = try fixture()
        let (other, _) = try fixture(subdirectory: "other-cache")
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 3, root: "root")
        try write(store) { db in
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read, thread_root_id) VALUES ('reply', 'mention', 'alpha', 3, 1, 'root')")
        }
        XCTAssertEqual(try entries(store).map(\.id), ["root"])
        XCTAssertEqual(try entries(store, .mentions).filter(\.unread).map(\.id), ["root"])
        XCTAssertEqual(try read(store) { try ChatUnread.unreadMentions($0) }, 1)
        try post(other, "other-cache-root", seq: 1)
        let otherChannel = ChatChannelModel(key: key, channel: "alpha"); otherChannel.follow(other)
        let model = inbox(store, org)
        model.markAllRead(org, service: ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore()))
        XCTAssertEqual(otherChannel.feed.unreadID, "other-cache-root", "the same address in another cache keeps its visit line")
        XCTAssertEqual(try read(other) { try ChatUnread.readSequence($0, channel: "alpha") }, 0)
    }

    func testSelfMentionFromAnotherMacIsAbsentFromListsBadgeDividerAndNotifications() throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "self", seq: 2, author: me, text: "@andrew привет")
        let unread = inbox(store, org)
        XCTAssertTrue(unread.entries(org).isEmpty)
        XCTAssertEqual(try entries(store, .mentions).map(\.id), ["root"])
        XCTAssertTrue(try entries(store, .mentions).allSatisfy { !$0.unread })
        let channel = ChatChannelModel(key: key, channel: "alpha"); channel.follow(store)
        XCTAssertNil(channel.feed.unreadID)
        XCTAssertEqual(try read(store) { try ChatUnread.unreadMentions($0) }, 0)
        XCTAssertNil(try write(store) { try ChatUnread.owe($0, messageId: "self", me: me) })
    }

    func testPlaceholderAndDeletedRootsKeepF4CountAndMoreIndicator() throws {
        let (store, org) = try fixture()
        try post(store, "deleted", seq: 10, deleted: true)
        try write(store) { db in
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq) VALUES ('unknown', 'alpha', 11)")
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq, thread_root_id) VALUES ('unknown-reply', 'alpha', 12, 'root')")
            try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 10 WHERE channel_id = 'alpha'")
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:beta', 20)")
        }
        org.isFollowed = { _ in false }; try refresh(store, org)
        XCTAssertEqual(try entries(store).map(\.id), ["deleted", "unknown", "unknown-reply"])
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 3); XCTAssertTrue(sidebar.incomplete)
        XCTAssertTrue(sidebar.teams.flatMap(\.channels).first { $0.id == "beta" }!.unread.something)
        XCTAssertTrue(try entries(store, .mentions).isEmpty)
    }

    func testMarkAllFailureRollsBackAndDoesNotDismissDivider() throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        let channel = ChatChannelModel(key: key, channel: "alpha"); channel.follow(store)
        let model = inbox(store, org)
        try write(store) { try $0.execute(sql: "CREATE TRIGGER fail_inbox BEFORE UPDATE OF thread_read_seq ON read_marks BEGIN SELECT RAISE(ABORT, 'test'); END") }
        model.markAllRead(org, service: ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore()))
        XCTAssertNotNil(model.problem)
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 0)
        XCTAssertEqual(channel.feed.unreadID, "root")
        XCTAssertEqual(try entries(store).map(\.id), ["root"])
    }
}

extension ChatInboxTests {
    func testTabsRestoreDuplicateMoveAndReopenWithoutAProcessOrMessagePayload() throws {
        var peers: [WorkspaceStore] = []
        let saved = InMemoryPersistence()
        let a = WorkspaceStore(persistence: saved, engineFactory: { TestEngine() }, peerStores: { peers })
        let b = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, peerStores: { peers })
        peers = [a, b]
        let ref = ChatInboxRef(key, kind: .unread)
        let unread = try XCTUnwrap(a.showInbox(ref))
        XCTAssertTrue(a.showInbox(ref) === unread, "a sidebar click reuses the list tab")
        let mention = try XCTUnwrap(a.showInbox(ChatInboxRef(key, kind: .mentions)))
        XCTAssertFalse(mention === unread)
        var another = ref; another.account = "other"
        XCTAssertFalse(a.showInbox(another) === unread)
        XCTAssertTrue(unread.isChat); XCTAssertEqual(unread.title, "Unread"); XCTAssertEqual(mention.title, "Mentions")
        a.renameTab(unread, to: "not allowed")
        XCTAssertNil(unread.customTitle)
        unread.customTitle = "sensitive message or channel name"
        a.flushPersistence()
        let data = try JSONEncoder().encode(XCTUnwrap(saved.saved))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sensitive"))
        var spawns = 0
        let restored = WorkspaceStore(persistence: InMemoryPersistence(initial: try JSONDecoder().decode(PersistedState.self, from: data)),
                                      engineFactory: { spawns += 1; return TestEngine() })
        let tabs = restored.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }
        let back = try XCTUnwrap(tabs.first { $0.id == unread.id })
        XCTAssertEqual(back.inbox, ref); XCTAssertNil(back.customTitle)
        XCTAssertEqual((back.engine as? ChatInboxTabEngine)?.starts, 0)
        XCTAssertEqual(spawns, tabs.filter { !$0.isChat }.count)
        let copy = try XCTUnwrap(a.duplicateTab(unread, in: a.workspaces[0]))
        XCTAssertEqual(copy.inbox, ref); XCTAssertTrue(copy.engine is ChatInboxTabEngine)
        a.closeTab(copy, in: a.workspaces[0])
        let reopened = try XCTUnwrap(a.reopenLastClosedTab())
        XCTAssertEqual(reopened.inbox, ref); XCTAssertTrue(reopened.engine is ChatInboxTabEngine)
        let destination = try XCTUnwrap(b.workspaces[0].root.firstPane)
        XCTAssertTrue(b.handleTabDrop(droppedId: unread.id, to: destination, at: destination.tabs.count, in: b.workspaces[0]))
        (unread.engine as? ChatInboxTabEngine)?.onClose()
        XCTAssertFalse(destination.tabs.contains { $0 === unread }, "Close binds to the new owner after a move")
        XCTAssertEqual((unread.engine as? ChatInboxTabEngine)?.terminations, 1)
    }

    func testMessageNavigationUsesTheSelectedHostAndRevealsOldRootsAndReplies() throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "reply", seq: 2, root: "root")
        try post(store, "latest", seq: 100)
        try write(store) { try $0.execute(sql: "UPDATE channel_windows SET bottom_seq = 100 WHERE channel_id = 'alpha'") }
        let rows = try entries(store)
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() })
        let otherTab = try XCTUnwrap(workspace.showChannel(ChannelRef(key, channel: "alpha"), newTab: true))
        let selected = try XCTUnwrap(workspace.showChannel(ChannelRef(key, channel: "alpha"), newTab: true))
        // showChannel reuses the first matching tab, so assert the actual returned destination.
        for id in ["reply", "root"] {
            let message = try XCTUnwrap(rows.first { $0.id == id }?.message)
            let tab = try XCTUnwrap(ChatInboxNavigation.open(message, ref: ChatInboxRef(key, kind: .unread), org: org, workspace: workspace))
            XCTAssertTrue(workspace.active?.activeSession === tab)
            let wrong = tab === otherTab ? selected : otherTab
            XCTAssertNil(ChatMessageNavigation.take(key: key, channel: "alpha", from: wrong.engine.view))
            let link = try XCTUnwrap(ChatMessageNavigation.take(key: key, channel: "alpha", from: tab.engine.view))
            let channel = ChatChannelModel(key: key, channel: "alpha"); channel.follow(store); channel.navigate(to: link)
            XCTAssertEqual(channel.revealMessageID, id)
            XCTAssertEqual(channel.threadRoot, message.threadRootId)
            if id == "root" { XCTAssertTrue(channel.feed.messages.contains { $0.id == id }) }
            else { XCTAssertTrue(channel.thread.contains { $0.id == id }) }
        }
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 0)
    }

    func testNativeInboxListsAndEmptyStates() async throws {
        _ = NSApplication.shared
        let (store, org) = try fixture()
        try post(store, "old", seq: 1, text: "@andrew The first draft is ready for review.", at: "2026-10-05T15:30:00Z")
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 1) }
        try post(store, "root", seq: 2, text: "@andrew Can you review the updated chat layout?", at: "2026-10-06T10:00:00Z")
        try post(store, "reply", seq: 3, root: "root", text: "The thread view is ready too. Please check the empty state.", at: "2026-10-06T10:10:00Z")
        try post(store, "second", seq: 1, channel: "beta", text: "@andrew Tests passed. The client build is ready.", at: "2026-10-06T11:00:00Z")
        try refresh(store, org)
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() })
        workspace.sidebarContent = .chat
        let ws = try XCTUnwrap(workspace.active)
        workspace.showInbox(ChatInboxRef(key, kind: .unread))
        workspace.showInbox(ChatInboxRef(key, kind: .mentions))
        let pane = try XCTUnwrap(ws.activePane)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let unread = inbox(store, org)
        let mention = inbox(store, org, kind: .mentions)
        func content(_ kind: ChatInboxKind) -> AnyView {
            AnyView(HStack(spacing: 0) {
                ChatSidebarView(store: workspace, navigation: workspace.chatNavigation, model: org)
                    .frame(width: 248).background(Theme.chromeBackground)
                Divider()
                VStack(spacing: 0) {
                    TabBarView(pane: pane, workspace: ws, store: workspace)
                    ChatInboxView(kind: kind, entries: (kind == .unread ? unread : mention).entries(org),
                                  sidebar: ChatSidebarSnapshot(model: org, active: nil), members: org.members,
                                  markAllRead: { unread.markAllRead(org, service: service) },
                                  openMessage: { ChatInboxNavigation.open($0, ref: ChatInboxRef(self.key, kind: kind), org: org, workspace: workspace) },
                                  openChannel: { workspace.showChannel(ChannelRef(self.key, channel: $0)) }).id(kind)
                }
            }.frame(width: 1100, height: 700))
        }
        let host = NSHostingView(rootView: content(.unread))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1100, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "AgentPad — Chat"; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        // Real AppKit mouse events in the fixed native fixture exercise the
        // SwiftUI buttons; XCTest does not expose SwiftUI's AX tree here.
        func press(_ id: String) throws {
            let point: NSPoint
            switch id {
            case "chat-inbox-unread": point = NSPoint(x: 100, y: 700 - 126)
            case "chat-inbox-mentions": point = NSPoint(x: 100, y: 700 - 160)
            case "chat-inbox-mark-all-read": point = NSPoint(x: 1020, y: 700 - Theme.contentHeaderHeight - 31)
            case "chat-inbox-message-reply": point = NSPoint(x: 500, y: 700 - Theme.contentHeaderHeight - 225)
            default: return XCTFail("Unknown native target: \(id)")
            }
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(up)
            }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let output = ProcessInfo.processInfo.environment["AGENTPAD_INBOX_SCREENSHOT_DIR"]
        for (kind, name) in [(ChatInboxKind.unread, "list"), (.mentions, "mentions"), (.unread, "empty"), (.mentions, "mentions-empty")] {
            if name == "empty" {
                host.rootView = content(.unread); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                try press("chat-inbox-mark-all-read")
                try await wait { unread.entries(org).isEmpty }
                try refresh(store, org)
            } else if name == "mentions-empty" {
                try write(store) { try $0.execute(sql: "DELETE FROM messages") }
                try await wait { mention.entries(org).isEmpty }
                try refresh(store, org)
            }
            try press("chat-inbox-\(kind.rawValue)")
            host.rootView = content(kind); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertGreaterThan(host.fittingSize.width, 1000)
            XCTAssertEqual(workspace.active?.activeSession?.inbox?.kind, kind)
            if let output {
                let path = URL(fileURLWithPath: output).appendingPathComponent("fix-unread-\(name).png")
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
                try capture.run(); capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            }
            if name == "list" {
                try press("chat-inbox-message-reply")
                XCTAssertEqual(workspace.active?.activeSession?.channel, ChannelRef(key, channel: "alpha"))
            }
        }
    }
}
