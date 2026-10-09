import AppKit
import GRDB
import SwiftUI
import Vision
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatThreadUnreadTests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("thread-unread-\(UUID())")
    }

    override func tearDown() async throws {
        scope.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.write(body) }
    private func read<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.read(body) }

    private func fixture() throws -> (ChatStore, ChatOrgModel) {
        let store = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        try write(store) { db in
            try db.execute(sql: "UPDATE meta SET me = 'me', rights_in_doubt = 0, rights_session = 's', channels_served = 1")
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES ('team', 'Team', 1), ('hidden', 'Hidden', 0)")
            for channel in ["c", "other", "hidden"] {
                try db.execute(sql: """
                    INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at)
                    VALUES (?, ?, ?, 0, 1, 1, 'me', 'now')
                    """, arguments: [channel, channel == "hidden" ? "hidden" : "team", channel])
                try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES (?, 1, 0)", arguments: [channel])
                try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [channel])
            }
        }
        let org = ChatOrgModel(me: "me") { _, _ in XCTFail("No commands expected"); return "unexpected" }
        org.key = key; org.session = "s"; org.isFollowed = { _ in true }; org.follow(store)
        return (store, org)
    }

    private func post(_ store: ChatStore, _ id: String, seq: Int, root: String? = nil,
                      channel: String = "c", author: String = "other", deleted: Bool = false) throws {
        let value: [String: Any] = ["message_id": id, "channel_id": channel, "thread_root_id": root as Any? ?? NSNull(),
            "author_account_id": author, "text": "Message \(id)", "mentions": [], "revision": deleted ? 2 : 1,
            "seq": seq, "created_at": "2026-10-06T10:00:00Z", "deleted_at": deleted ? "2026-10-06T11:00:00Z" : NSNull()]
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
        try write(store) { try ChatMessages.write($0, wire) }
    }

    private func service() -> ChatService { ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore()) }

    private func model(_ store: ChatStore) -> ChatChannelModel {
        let model = ChatChannelModel(key: key, channel: "c")
        model.service = service(); model.follow(store)
        return model
    }

    private func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Observation did not settle", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReadingChannelClearsBadgeButKeepsRepliesUntilThreadViewedInBothWindows() async throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "reply-1", seq: 2, root: "root")
        try post(store, "reply-2", seq: 4, root: "root")
        try post(store, "tail", seq: 5)
        let first = model(store), second = model(store)
        first.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        try await wait { org.unread("c")?.count == 0 && first.feed.unreadReplyCounts["root"] == 2 }
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 0)
        XCTAssertNil(ChatSidebarSnapshot.unreadLabel(sidebar.unread))
        let channel = try XCTUnwrap(sidebar.teams.flatMap(\.channels).first { $0.id == "c" })
        XCTAssertFalse(channel.isUnread)
        XCTAssertNil(channel.unreadLabel)
        XCTAssertEqual(try read(store) { try ChatInbox.read($0, kind: .unread, account: "me", session: "s").map(\.id) }, ["reply-1", "reply-2"])
        XCTAssertEqual(first.feed.unreadReplyCounts, ["root": 2])
        XCTAssertEqual(first.feed.replySummaries["root"]?.label, "2 replies")
        XCTAssertEqual(first.feed.unloadedUnreadReplyCount, 0)
        XCTAssertNil(first.feed.firstUnloadedUnreadThread)
        first.openThread("root")
        first.readIfLooking(root: "root", appActive: false, shown: true, atBottom: true)
        XCTAssertEqual(first.feed.unreadReplyCounts["root"], 2, "Opening alone does not read hidden or inactive content")
        first.readIfLooking(root: "root", appActive: true, shown: true, atBottom: true)
        try await wait { first.feed.unreadReplyCounts.isEmpty && second.feed.unreadReplyCounts.isEmpty && org.unread("c")?.count == 0 }
        try post(store, "late-history", seq: 3, root: "root")
        try post(store, "new-reply", seq: 6, root: "root")
        try await wait { first.feed.unreadReplyCounts["root"] == 1 && second.feed.unreadReplyCounts["root"] == 1 && org.unread("c")?.count == 0 }
        try post(store, "new-root", seq: 7)
        try await wait { org.unread("c")?.count == 1 && first.feed.messages.contains { $0.id == "new-root" } }
        let newPost = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(newPost.unread.count, 1)
        XCTAssertEqual(ChatSidebarSnapshot.unreadLabel(newPost.unread), "1")
        XCTAssertTrue(try XCTUnwrap(newPost.teams.flatMap(\.channels).first { $0.id == "c" }).isUnread)
        first.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        try await wait { org.unread("c")?.count == 0 }
        XCTAssertEqual(try read(store) { try ChatInbox.read($0, kind: .unread, account: "me", session: "s").map(\.id) }, ["new-reply"])
        try write(store) { db in
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read, thread_root_id) VALUES ('new-reply', 'reply', 'c', 6, 1, 'root')")
        }
        try await wait { first.feed.unreadReplyCounts.isEmpty && second.feed.unreadReplyCounts.isEmpty && org.unread("c")?.count == 0 }
    }

    func testRootReplyCountsUseTheInboxesExactReadAndVisibilityRules() throws {
        let (store, _) = try fixture()
        try post(store, "below-baseline", seq: 2, root: "r")
        try post(store, "below-thread-mark", seq: 4, root: "r")
        try post(store, "individually-read", seq: 6, root: "r")
        try post(store, "unread", seq: 7, root: "r")
        try post(store, "sibling", seq: 8, root: "sibling")
        try post(store, "own", seq: 9, root: "third", author: "me")
        try post(store, "deleted", seq: 10, root: "third", deleted: true)
        try post(store, "other-channel", seq: 12, root: "r", channel: "other")
        try post(store, "hidden-team", seq: 13, root: "r", channel: "hidden")
        try write(store) { db in
            try ChatMessages.insertSending(db, id: "pending", channel: "c", root: "r", author: "me", text: "Draft", mentions: [], at: "now")
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 100, thread_read_seq = 3")
            try db.execute(sql: "DELETE FROM thread_read_marks")
            try db.execute(sql: "DELETE FROM notified")
            try db.execute(sql: "INSERT INTO thread_read_marks VALUES ('c', 'r', 5)")
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read, thread_root_id) VALUES ('individually-read', 'reply', 'c', 6, 1, 'r')")
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq, thread_root_id) VALUES ('placeholder', 'c', 11, 'third')")
        }
        try read(store) { db in
            let roots = try ChatUnread.unreadRepliesByRoot(db, channel: "c")
            XCTAssertEqual(roots.map(\.root), ["r", "sibling"])
            XCTAssertEqual(roots.map(\.count), [1, 1])
            XCTAssertEqual(roots.reduce(0) { $0 + $1.count }, try ChatUnread.unreadRepliesByChannel(db)["c"])
            XCTAssertEqual(try ChatUnread.unreadRepliesByRoot(db, channel: "other").map(\.count), [1])
            XCTAssertTrue(try ChatUnread.unreadRepliesByRoot(db, channel: "hidden").isEmpty)
        }
        let model = model(store)
        model.openThread("r")
        model.readIfLooking(root: "r", appActive: true, shown: true, atBottom: true)
        try read(store) { db in
            XCTAssertEqual(try ChatUnread.unreadRepliesByRoot(db, channel: "c").map(\.root), ["sibling"], "Reading one thread preserves its siblings")
        }
    }

    func testHintCoversPageLimitWindowBoundaryAndMissingRootsInReplyOrder() async throws {
        let (store, _) = try fixture()
        try post(store, "old-a", seq: 1)
        try post(store, "old-b", seq: 2)
        try post(store, "reply-b", seq: 5, root: "old-b")
        try post(store, "reply-a", seq: 6, root: "old-a")
        try post(store, "recent", seq: 20)
        try post(store, "reply-recent", seq: 21, root: "recent")
        try post(store, "reply-missing", seq: 22, root: "missing")
        try read(store) { db in
            let limited = try ChatChannelModel.readFeed(db, channel: "c", shown: 1)
            XCTAssertEqual(limited.messages.map(\.id), ["recent"])
            XCTAssertEqual(limited.unreadReplyCounts, ["old-a": 1, "old-b": 1, "recent": 1, "missing": 1])
            XCTAssertEqual(limited.unloadedUnreadReplyCount, 3)
            XCTAssertEqual(limited.firstUnloadedUnreadThread, "old-b", "First unread reply, not oldest root")
            let expanded = try ChatChannelModel.readFeed(db, channel: "c", shown: 3)
            XCTAssertEqual(expanded.unloadedUnreadReplyCount, 1)
            XCTAssertEqual(expanded.firstUnloadedUnreadThread, "missing")
        }
        let model = model(store)
        try write(store) { try $0.execute(sql: "UPDATE channel_windows SET bottom_seq = 20 WHERE channel_id = 'c'") }
        try await wait { model.feed.unloadedUnreadReplyCount == 3 }
        XCTAssertEqual(model.feed.firstUnloadedUnreadThread, "old-b")
        try write(store) { try $0.execute(sql: "UPDATE teams SET mine = 0 WHERE team_id = 'team'") }
        try await wait { model.feed.unreadReplyCounts.isEmpty && model.feed.unloadedUnreadReplyCount == 0 && model.feed.firstUnloadedUnreadThread == nil }
    }

    func testNativeRootBadgesForLocalServerAndStaleServerSummaries() async throws {
        let (store, _) = try fixture()
        try post(store, "root", seq: 1)
        try post(store, "reply-1", seq: 2, root: "root")
        try post(store, "reply-2", seq: 4, root: "root")
        let model = model(store)
        let message = try XCTUnwrap(model.message("root"))
        let host = NSHostingView(rootView: AnyView(ChatMessageRow(model: model, message: message, members: [], mentionable: [],
            me: "me", archived: false, replies: 2).frame(width: 700, height: 180).background(ChatAppearance.surface)))
        let window = makeWindow(host, size: NSSize(width: 700, height: 180))
        defer { window.contentView = nil; window.close() }
        for serverCount: Int? in [nil, 10, 0] {
            if let serverCount {
                model.service.serverCapabilities[key.server] = ["chat.thread_summary"]
                try write(store) { db in
                    try ChatB1.watch(db, channel: "c", ids: ["root"])
                    let metadata = ChatB1.Metadata(messageId: "root", deleted: false, reactions: [], threadSummary:
                        .init(rootId: "root", replyCount: serverCount, lastParticipants: []))
                    try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = 'root'", arguments: [try ChatB1.encode(metadata)])
                }
                try await wait { model.b1?.state.metadata["root"]?.threadSummary?.replyCount == serverCount }
            }
            let words = try await renderedText(host, name: "root-\(serverCount.map(String.init) ?? "local")").map(\.text).joined(separator: " ")
            XCTAssertTrue(words.contains("2 new"), words)
            XCTAssertTrue(words.contains(serverCount == 10 ? "10 replies" : "2 replies"), words)
        }
        model.openThread("root")
        model.readIfLooking(root: "root", appActive: true, shown: true, atBottom: true)
        try await wait { model.feed.unreadReplyCounts.isEmpty }
        model.service.serverCapabilities[key.server] = []
        let words = try await renderedText(host, name: "root-read").map(\.text).joined(separator: " ")
        XCTAssertTrue(words.contains("2 replies"), words)
        XCTAssertFalse(words.contains("new"), words)
    }

    func testNativeChannelHintOpensMissingRootAndReadingRemovesCount() async throws {
        let (store, org) = try fixture()
        try post(store, "recent", seq: 20)
        try post(store, "reply-1", seq: 21, root: "missing")
        try post(store, "reply-2", seq: 22, root: "missing")
        let card = ChatChannelCard(channelId: "c", teamId: "team", name: "general", archived: false, version: 1)
        let conversation = ChatChannelSession()
        conversation.update(.ready(card, team: "Team", offline: true), key: key, store: store, service: service())
        let model = try XCTUnwrap(conversation.model)
        let active = ChatNotifications.appActive
        ChatNotifications.appActive = { true }
        defer { ChatNotifications.appActive = active }
        let host = NSHostingView(rootView: AnyView(ChatChannelView(card: card, team: "Team", offline: true, key: key, conversation: conversation)
            .frame(width: 700, height: 500)))
        let window = makeWindow(host, size: NSSize(width: 700, height: 500))
        defer { window.contentView = nil; window.close() }
        let text = try await renderedText(host, name: "channel-hint")
        let hint = try XCTUnwrap(text.first { $0.text.contains("Unread thread replies: 2") }, text.map(\.text).joined(separator: " "))
        try await wait { host.layoutSubtreeIfNeeded(); return org.unread("c")?.count == 0 && model.feed.unloadedUnreadReplyCount == 2 }
        let point = NSPoint(x: hint.box.midX * host.bounds.width,
                           y: (host.isFlipped ? 1 - hint.box.midY : hint.box.midY) * host.bounds.height)
        try click(window, at: host.convert(point, to: nil))
        try await wait { host.layoutSubtreeIfNeeded(); return model.threadRoot == "missing" && model.feed.unreadReplyCounts.isEmpty && org.unread("c")?.count == 0 }
        XCTAssertNil(model.feed.firstUnloadedUnreadThread)
        model.openThread(nil)
        let read = try await renderedText(host, name: "channel-read").map(\.text).joined(separator: " ")
        XCTAssertFalse(read.contains("Unread thread replies"), read)
    }

    private func makeWindow(_ host: NSView, size: NSSize) -> NSWindow {
        final class Window: NSWindow { override var isKeyWindow: Bool { true } }
        let window = Window(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return window
    }

    /// Assert the actual SwiftUI text, including both production reply-button paths.
    private func renderedText(_ host: NSView, name: String) async throws -> [(text: String, box: CGRect)] {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["AGENTPAD_THREAD_UNREAD_CAPTURE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { result in result.topCandidates(1).first.map { ($0.string, result.boundingBox) } }
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(up) }
    }
}
