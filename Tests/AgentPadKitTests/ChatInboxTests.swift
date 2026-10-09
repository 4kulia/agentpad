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

    private func fixture(subdirectory: String? = nil, store suppliedStore: ChatStore? = nil) throws -> (ChatStore, ChatOrgModel) {
        let location = subdirectory.map { directory.appendingPathComponent($0) } ?? directory!
        let store = try suppliedStore ?? ChatStore.open(files: ChatFiles(directory: location), key: key).store
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
        let wire = try wire(id, seq: seq, channel: channel, root: root, author: author, mentions: mentions,
                            text: text, at: at, deleted: deleted)
        try write(store) { try ChatMessages.write($0, wire) }
    }
    private func wire(_ id: String, seq: Int, channel: String = "alpha", root: String? = nil,
                      author: String = "other", mentions: [String]? = nil, text: String? = nil,
                      at: String = "2026-10-06T10:00:00Z", deleted: Bool = false) throws -> ChatMessageWire {
        let value: [String: Any] = ["message_id": id, "channel_id": channel, "thread_root_id": root as Any? ?? NSNull(),
            "author_account_id": author, "text": text ?? "Message \(id)", "mentions": (mentions ?? [me]).map { ["account_id": $0] },
            "revision": deleted ? 2 : 1, "seq": seq, "created_at": at, "deleted_at": deleted ? at as Any : NSNull()]
        return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
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

    func testColdInboxLoadsRootsAndRepliesToTheirReadBoundaries() async throws {
        for kind in ChatInboxKind.allCases {
            let (store, org) = try fixture(subdirectory: kind.rawValue)
            try write(store) { db in
                try db.execute(sql: "UPDATE read_marks SET last_read_seq = 8, thread_read_seq = 3 WHERE channel_id = 'alpha'")
                try db.execute(sql: "INSERT INTO thread_read_marks VALUES ('alpha', 'old-root', 10)")
                try db.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 12)")
                try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 12, history_next = 12 WHERE channel_id = 'alpha'")
                try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq) VALUES ('new', 'alpha', 12)")
            }
            try post(store, "private", seq: 15, channel: "hidden")
            try refresh(store, org)
            XCTAssertEqual(org.unread("alpha")?.count, 0, "a cold placeholder is not a counted message")
            XCTAssertTrue(org.unread("alpha")?.more == true, "the window gap still triggers history loading")
            XCTAssertTrue(try entries(store, kind).allSatisfy { $0.message.loading })
            XCTAssertEqual(try read(store) { try ChatInboxLoading.snapshot($0, ref: ChatInboxRef(key, kind: kind), session: "s").targets.map(\.channel) }, ["alpha"])
            let model = ChatInboxModel(ref: ChatInboxRef(key, kind: kind))
            var requests: [Int?] = []
            model.follow(store, org: org) { target, before in
                XCTAssertEqual(target.channel, "alpha", "do not load read or inaccessible channels")
                requests.append(before)
                if before == nil {
                    return try ChatMessagesPage(messages: [self.wire("new", seq: 12), self.wire("reply", seq: 11, root: "old-root")], next: 11, head: 12)
                }
                if before == 11 {
                    return try ChatMessagesPage(messages: [self.wire("read-root", seq: 8), self.wire("read-reply", seq: 7, root: "old-root")], next: 7, head: 12)
                }
                XCTAssertEqual(before, 7)
                return try ChatMessagesPage(messages: [self.wire("unseen-reply", seq: 4, root: "unseen-thread"),
                    self.wire("wrong-channel", seq: 4, channel: "beta"), self.wire("baseline", seq: 3, root: "unseen-thread", mentions: [])], next: 3, head: 12)
            }
            XCTAssertTrue(model.loading)
            try await wait { !model.loading && model.entries(org).filter { $0.unread && !$0.message.loading }.count == 3 }
            XCTAssertEqual(Set(model.entries(org).filter(\.unread).map(\.id)), ["new", "reply", "unseen-reply"])
            if kind == .mentions {
                XCTAssertEqual(Set(model.entries(org).filter { !$0.unread }.map(\.id)), ["read-root", "read-reply"], "keep the mention history")
            }
            XCTAssertEqual(requests, [nil, 11, 7], "stop at the thread baseline, not the newer channel mark")
            XCTAssertNil(try read(store) { try String.fetchOne($0, sql: "SELECT message_id FROM messages WHERE message_id = 'wrong-channel'") })
            XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 8)
            XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha", thread: "old-root") }, 10)
            XCTAssertEqual(try read(store) { try Int.fetchOne($0, sql: "SELECT history_next FROM channel_windows WHERE channel_id = 'alpha'") }, 12)
            XCTAssertEqual(try read(store) { try Int.fetchOne($0, sql: "SELECT seq FROM cursors WHERE stream = 'channel:alpha'") }, 12)
            model.stop()
        }
    }

    func testOpenInboxLoadsNewHeadsWithoutLoopingOnItsOwnWrites() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 5)") }
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .mentions))
        var calls = 0
        model.follow(store, org: org) { target, _ in
            calls += 1
            return try ChatMessagesPage(messages: [self.wire("m\(target.head)", seq: target.head)], next: nil, head: target.head)
        }
        try await wait { model.entries(org).count == 1 && !model.loading }
        try write(store) { try $0.execute(sql: "UPDATE cursors SET seq = 9 WHERE stream = 'channel:alpha'") }
        try await wait { model.entries(org).count == 2 && !model.loading }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 2)
        model.stop()
    }

    func testNewHeadRefreshStopsAtAlreadyCoveredHistory() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 5)") }
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var requests: [Int?] = []
        model.follow(store, org: org) { target, before in
            requests.append(before)
            return try ChatMessagesPage(messages: [self.wire("m\(target.head)", seq: target.head)],
                                        next: target.head == 9 && before == nil ? 5 : nil, head: target.head)
        }
        try await wait { !model.loading && model.entries(org).count == 1 }
        try write(store) { try $0.execute(sql: "UPDATE cursors SET seq = 9 WHERE stream = 'channel:alpha'") }
        try await wait { !model.loading && model.entries(org).count == 2 }
        XCTAssertEqual(requests, [nil, nil], "refresh only the interval above the covered head")
        XCTAssertFalse(model.limited)
        model.stop()
    }

    func testErrorRetryAndPageLimitResumeFromLastCursor() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 100)") }
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var fail = true, finish = false
        var requests: [Int?] = []
        model.follow(store, org: org) { _, before in
            requests.append(before)
            if fail { throw ChatInboxLoadError.unavailable }
            let seq = (before ?? 101) - 1
            return try ChatMessagesPage(messages: [self.wire("m\(seq)", seq: seq)], next: finish ? nil : seq, head: 100)
        }
        try await wait { model.problem != nil && !model.loading }
        fail = false; model.retry()
        try await wait { model.limited && !model.loading }
        XCTAssertNil(model.problem)
        XCTAssertEqual(requests, [nil, nil, 100, 99, 98, 97])
        finish = true; model.retry()
        try await wait { !model.loading }
        XCTAssertEqual(requests.last!, 96, "continue below the five pages already loaded")
        XCTAssertEqual(model.entries(org).count, 6)
        XCTAssertFalse(model.limited)
        model.stop()
    }

    func testNewHeadsPreserveHistoricalCursorAndAutomaticChannelBudget() async throws {
        for kind in ChatInboxKind.allCases {
            let (store, org) = try fixture(subdirectory: kind.rawValue)
            try write(store) { db in
                try db.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 1000)")
                try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 1000 WHERE channel_id = 'alpha'")
            }
            let model = ChatInboxModel(ref: ChatInboxRef(key, kind: kind))
            var requests: [Int?] = []
            var finish = false
            model.follow(store, org: org) { target, before in
                requests.append(before)
                if requests.count <= ChatInboxLoading.pagesPerChannel {
                    let head = 1000 + requests.count
                    try self.write(store) { try $0.execute(sql: "UPDATE cursors SET seq = ? WHERE stream = 'channel:alpha'", arguments: [head]) }
                    try self.post(store, "live\(head)", seq: head)
                    // Deliver the changed head while the history request is suspended.
                    try await Task.sleep(for: .milliseconds(30))
                }
                let seq = (before ?? 1001) - 1
                return try ChatMessagesPage(messages: [self.wire("m\(seq)", seq: seq)], next: finish ? nil : seq, head: target.head)
            }
            try await wait { !model.loading && model.limited }
            XCTAssertEqual(requests, [nil, 1000, 999, 998, 997], "new events must not renew the five-page allowance")
            try write(store) { try $0.execute(sql: "UPDATE cursors SET seq = 1006 WHERE stream = 'channel:alpha'") }
            try post(store, "live1006", seq: 1006)
            try await wait { model.entries(org).contains { $0.id == "live1006" } && !model.loading }
            XCTAssertEqual(requests.count, 5, "a later head must not restart deferred history")
            XCTAssertTrue(model.limited)
            let retryStart = requests.count
            finish = true; model.retry()
            try await wait { !model.loading }
            let resumed = try XCTUnwrap(requests.dropFirst(retryStart).first)
            XCTAssertEqual(resumed, 996, "explicit continuation starts below the pages already fetched")
            XCTAssertFalse(model.limited)
            model.stop()
        }
    }

    func testReadFollowedChannelIgnoresReactionHeadButKeepsRealGaps() async throws {
        for kind in ChatInboxKind.allCases {
            let (store, org) = try fixture(subdirectory: kind.rawValue)
            try write(store) { db in
                try db.execute(sql: "UPDATE read_marks SET last_read_seq = 1000, thread_read_seq = 100 WHERE channel_id = 'alpha'")
                try db.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 1001)")
                try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 900, history_next = 900 WHERE channel_id = 'alpha'")
            }
            try refresh(store, org)
            XCTAssertEqual(org.unread("alpha"), ChatUnread.Count())
            let model = ChatInboxModel(ref: ChatInboxRef(key, kind: kind))
            var requests = 0
            model.follow(store, org: org) { target, before in
                requests += 1
                return ChatMessagesPage(messages: [], next: (before ?? 1001) - 1, head: target.head)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(requests, 0, "a reaction above the root mark is not an unread message on a followed channel")
            XCTAssertFalse(model.loading)
            XCTAssertFalse(model.limited, "a read inbox must not offer More unread messages / Load more")
            XCTAssertTrue(ChatInboxPresentation(kind: kind, entries: model.entries(org),
                                               sidebar: ChatSidebarSnapshot(model: org, active: nil)).isEmpty)

            try write(store) { try $0.execute(sql: "UPDATE channel_windows SET bottom_seq = 1100 WHERE channel_id = 'alpha'") }
            try await wait { !model.loading && model.limited }
            XCTAssertEqual(requests, 5, "a real history gap still requires hydration on a followed channel")
            model.stop()

            try write(store) { try $0.execute(sql: "UPDATE channel_windows SET bottom_seq = 900 WHERE channel_id = 'alpha'") }
            org.isFollowed = { _ in false }
            requests = 0
            model.follow(store, org: org) { target, _ in
                requests += 1
                return ChatMessagesPage(messages: [], next: nil, head: target.head)
            }
            try await wait { !model.loading }
            XCTAssertEqual(requests, 1, "unfollowed event uncertainty still matches the sidebar's something badge")
            model.stop()
        }
    }

    func testTotalPageBudgetDefersChannelsUntilExplicitRetry() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { db in
            for n in 0..<23 {
                let id = String(format: "c%02d", n)
                try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at) VALUES (?, 'team', ?, 0, 1, 1, 'other', 'now')", arguments: [id, id])
                try db.execute(sql: "INSERT INTO cursors VALUES (?, 1)", arguments: ["channel:\(id)"])
            }
        }
        try refresh(store, org)
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var calls = 0
        model.follow(store, org: org) { target, _ in
            calls += 1
            return try ChatMessagesPage(messages: [self.wire(target.channel, seq: 1, channel: target.channel)], next: nil, head: 1)
        }
        try await wait { !model.loading && model.entries(org).count == 20 }
        XCTAssertEqual(calls, 20)
        XCTAssertTrue(model.limited)
        XCTAssertEqual(model.entries(org).count, 20)
        model.retry()
        try await wait { !model.loading && model.entries(org).count == 23 }
        XCTAssertEqual(calls, 23, "completed channels must not consume the next pass's budget")
        XCTAssertFalse(model.limited)
        model.stop()
    }

    func testNewHeadsShareTheTotalAutomaticPageBudget() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { db in
            for n in 0..<ChatInboxLoading.pagesPerPass {
                let id = String(format: "c%02d", n)
                try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at) VALUES (?, 'team', ?, 0, 1, 1, 'other', 'now')", arguments: [id, id])
                try db.execute(sql: "INSERT INTO cursors VALUES (?, 1)", arguments: ["channel:\(id)"])
            }
        }
        try refresh(store, org)
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var calls = 0
        model.follow(store, org: org) { target, _ in
            calls += 1
            return try ChatMessagesPage(messages: [self.wire("\(target.channel)-\(target.head)", seq: target.head, channel: target.channel)], next: nil, head: target.head)
        }
        try await wait { !model.loading && model.entries(org).count == 20 }
        try write(store) { try $0.execute(sql: "UPDATE cursors SET seq = 2 WHERE stream = 'channel:c00'") }
        try post(store, "live", seq: 2, channel: "c00")
        try await wait { model.entries(org).count > 20 && !model.loading }
        XCTAssertEqual(calls, 20, "a new head cannot renew the shared automatic budget")
        XCTAssertTrue(model.limited)
        model.retry()
        try await wait { !model.loading }
        XCTAssertEqual(calls, 21)
        XCTAssertFalse(model.limited)
        model.stop()
    }

    func testNewHeadDuringLoadingIsFetchedAndReadClearsDeferredWork() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 5)") }
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var held: CheckedContinuation<ChatMessagesPage, Never>?
        var heads: [Int] = []
        model.follow(store, org: org) { target, before in
            heads.append(target.head)
            if heads.count == 1 { return await withCheckedContinuation { held = $0 } }
            let seq = (before ?? 10) - 1
            return try ChatMessagesPage(messages: [self.wire("m\(seq)", seq: seq)], next: seq, head: 9)
        }
        try await wait { held != nil }
        try write(store) { try $0.execute(sql: "UPDATE cursors SET seq = 9 WHERE stream = 'channel:alpha'") }
        held?.resume(returning: try ChatMessagesPage(messages: [wire("m5", seq: 5)], next: nil, head: 5))
        try await wait { !model.loading && model.limited && model.entries(org).count == 5 }
        XCTAssertEqual(heads, [5, 9, 9, 9, 9], "new heads share the original channel budget")
        try write(store) { _ = try ChatInbox.markAllRead($0, account: me, session: "s") }
        try await wait { model.entries(org).isEmpty && !model.limited }
        model.stop()
    }

    func testCancelledTransportAndNonprogressingPagesOfferRetry() async throws {
        let (store, org) = try fixture()
        org.isFollowed = { _ in false }
        try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 5)") }
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
        var cancelled = true, calls = 0
        model.follow(store, org: org) { _, _ in
            calls += 1
            if cancelled { throw CancellationError() }
            return ChatMessagesPage(messages: [], next: 4, head: 5)
        }
        try await wait { !model.loading && model.problem != nil }
        XCTAssertEqual(calls, 1)
        cancelled = false; model.retry()
        try await wait { !model.loading && model.problem != nil }
        XCTAssertEqual(calls, 3, "a nondecreasing before cursor is an error, not an infinite read")
        try write(store) { _ = try ChatInbox.markAllRead($0, account: me, session: "s") }
        try await wait { model.problem == nil }
        model.stop()
    }

    func testLateInboxPagesCannotRestoreRevokedOrReplacedContent() async throws {
        for mutation in ["team", "rights", "session", "epoch", "stop", "context"] {
            let (store, org) = try fixture(subdirectory: mutation)
            org.isFollowed = { _ in false }
            try write(store) { try $0.execute(sql: "INSERT INTO cursors VALUES ('channel:alpha', 5)") }
            let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .unread))
            var held: CheckedContinuation<ChatMessagesPage, Never>?
            var calls = 0
            model.follow(store, org: org) { _, _ in
                calls += 1
                if calls > 1 { return ChatMessagesPage(messages: [], next: nil, head: 5) }
                return await withCheckedContinuation { held = $0 }
            }
            try await wait { held != nil }
            switch mutation {
            case "team": try write(store) { try $0.execute(sql: "UPDATE teams SET mine = 0") }
            case "rights": try write(store) { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
            case "session": try write(store) { try $0.execute(sql: "UPDATE meta SET rights_session = 'replacement'") }
            case "epoch": try write(store) { try $0.execute(sql: "UPDATE channel_windows SET epoch = 2") }
            case "stop": model.stop()
            default: org.key = ChatOrgKey(server: key.server, accountId: me, orgId: "another")
            }
            held?.resume(returning: try ChatMessagesPage(messages: [wire("late", seq: 5)], next: nil, head: 5))
            try await wait { !model.loading }
            XCTAssertEqual(try read(store) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages") }, 0, mutation)
            model.stop()
        }
    }

    func testInboxPageAdmissionRechecksDatabaseAccessBeforeObserversCatchUp() throws {
        let mutations = [
            "account": "UPDATE meta SET me = 'another'",
            "session": "UPDATE meta SET rights_session = 'replacement'",
            "rights": "UPDATE meta SET rights_in_doubt = 1",
            "capability": "UPDATE meta SET channels_served = 0",
            "team": "UPDATE teams SET mine = 0",
            "epoch": "UPDATE channel_windows SET epoch = 2",
            "channel": "DELETE FROM channels WHERE channel_id = 'alpha'"
        ]
        let target = ChatInboxLoading.Key(channel: "alpha", epoch: 1, head: 5, channelRead: 0, threadRead: 0)
        for (name, sql) in mutations {
            let (store, _) = try fixture(subdirectory: name)
            XCTAssertTrue(try read(store) { try ChatInboxLoading.allowed($0, target: target, account: me, session: "s") })
            try write(store) { try $0.execute(sql: sql) }
            XCTAssertFalse(try read(store) { try ChatInboxLoading.allowed($0, target: target, account: me, session: "s") }, name)
        }
    }

    func testExactBadgesAlwaysHaveAnActionableRemainderInBothLists() throws {
        let (store, org) = try fixture()
        var view = org.view
        view.unread["alpha"] = .init(count: 4)
        view.mentionsByChannel["alpha"] = 1
        view.mentionsUnread = 1
        org.set(view)
        for kind in ChatInboxKind.allCases {
            let presentation = ChatInboxPresentation(kind: kind, entries: [], sidebar: ChatSidebarSnapshot(model: org, active: nil))
            XCTAssertFalse(presentation.isEmpty)
            XCTAssertEqual(presentation.groups.map(\.id), ["alpha"])
            XCTAssertEqual(presentation.missing.map(\.count), [kind == .unread ? 4 : 1])
            let missing = try XCTUnwrap(presentation.missing.first)
            XCTAssertTrue(missing.title.contains("#Design — Open channel"))
        }
        try post(store, "loaded", seq: 1)
        let rows = try entries(store)
        let partial = ChatInboxPresentation(kind: .unread, entries: rows, sidebar: ChatSidebarSnapshot(model: org, active: nil))
        XCTAssertEqual(partial.missing.map(\.count), [3])
        let mentions = ChatInboxPresentation(kind: .mentions, entries: rows, sidebar: ChatSidebarSnapshot(model: org, active: nil))
        XCTAssertTrue(mentions.missing.isEmpty)
        var loading = rows[0]; loading.message.stale = 2
        let stale = ChatInboxPresentation(kind: .mentions, entries: [loading], sidebar: ChatSidebarSnapshot(model: org, active: nil))
        XCTAssertTrue(stale.entries.isEmpty)
        XCTAssertEqual(stale.missing.map(\.count), [1], "a placeholder or stale text cannot stand for a loaded message")
        org.snapshotOwed = { true }
        let hidden = ChatInboxPresentation(kind: .unread, entries: rows, sidebar: ChatSidebarSnapshot(model: org, active: nil))
        XCTAssertTrue(hidden.isEmpty)
    }

    func testUnreadGroupsIncludeRepliesWhileSidebarCountsOnlyRootsWithoutReadingOnOpen() throws {
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
        XCTAssertEqual(sidebar.unread.count, 2)
        XCTAssertEqual(sidebar.teams.flatMap(\.channels).map { $0.unread.count }, [1, 1])
        XCTAssertEqual(try read(store) { try ChatUnread.count($0, channel: "alpha", me: me).count }, 1, "F4 root count retains its meaning")
        XCTAssertEqual(try read(store) { try ChatUnread.readSequence($0, channel: "alpha") }, 1, "opening a list does not read it")
        var changed = org.view; changed.unreadRepliesByChannel = [:]
        XCTAssertNotEqual(changed, org.view, "reply-only changes update the inbox's missing-history count")
    }

    func testReadChannelWithFiveUnreadRepliesKeepsInboxAndNewMarkersAtZeroBadge() throws {
        let (store, org) = try fixture()
        try post(store, "root", seq: 1, mentions: [])
        for seq in 2...6 {
            try post(store, "reply-\(seq)", seq: seq, root: "root", mentions: seq == 2 ? [me] : [])
        }
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 6) }
        try refresh(store, org)
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        let channel = try XCTUnwrap(sidebar.teams.flatMap(\.channels).first { $0.id == "alpha" })
        XCTAssertEqual(channel.unread.count, 0)
        XCTAssertNil(channel.unreadLabel)
        XCTAssertFalse(channel.isUnread, "a thread mention must not make the channel bold")
        XCTAssertEqual(sidebar.unread.count, 0)
        XCTAssertNil(ChatSidebarSnapshot.unreadLabel(sidebar.unread))
        XCTAssertEqual(sidebar.mentions, 1, "thread mentions remain in Mentions")
        let replies = try entries(store)
        XCTAssertEqual(replies.map(\.id), (2...6).map { "reply-\($0)" })
        let presentation = ChatInboxPresentation(kind: .unread, entries: replies, sidebar: sidebar)
        XCTAssertFalse(presentation.isEmpty)
        XCTAssertEqual(presentation.entries.map(\.id), replies.map(\.id))
        XCTAssertTrue(presentation.missing.isEmpty)
        XCTAssertEqual(try read(store) { try ChatUnread.unreadRepliesByRoot($0, channel: "alpha").map(\.count) }, [5])
        let loading = try read(store) { try ChatInboxLoading.snapshot($0, ref: ChatInboxRef(key, kind: .unread), session: "s") }
        XCTAssertEqual(loading.targets.map(\.channel), ["alpha"])
        XCTAssertFalse(try XCTUnwrap(loading.targets.first).unfollowedOnly)
    }

    func testReplyOnlyInboxHasNoCountedRemainderForPlaceholders() throws {
        let (store, org) = try fixture()
        try post(store, "reply", seq: 2, root: "old-root", mentions: [])
        try write(store) { db in
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq, thread_root_id) VALUES ('placeholder', 'alpha', 3, 'old-root')")
            try ChatUnread.markRead(db, channel: "alpha", upTo: 3)
        }
        try refresh(store, org)
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 0)
        let presentation = ChatInboxPresentation(kind: .unread, entries: try entries(store), sidebar: sidebar)
        XCTAssertEqual(presentation.entries.map(\.id), ["reply"])
        XCTAssertEqual(presentation.groups.map(\.id), ["alpha"])
        XCTAssertTrue(presentation.missing.isEmpty)
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

    func testPlaceholderAndDeletedRootsLeaveOnlyTheMoreIndicator() throws {
        let (store, org) = try fixture()
        try post(store, "deleted", seq: 10, deleted: true)
        try write(store) { db in
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq) VALUES ('unknown', 'alpha', 11)")
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq, thread_root_id) VALUES ('unknown-reply', 'alpha', 12, 'root')")
            try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 10 WHERE channel_id = 'alpha'")
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:beta', 20)")
        }
        org.isFollowed = { _ in false }; try refresh(store, org)
        XCTAssertTrue(try entries(store).isEmpty)
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 0); XCTAssertTrue(sidebar.incomplete)
        XCTAssertTrue(sidebar.teams.flatMap(\.channels).first { $0.id == "beta" }!.unread.something)
        XCTAssertTrue(try entries(store, .mentions).isEmpty)
    }

    func testDeletedMessagesNeverCountWithOrWithoutNotificationRows() throws {
        let (store, org) = try fixture()
        try post(store, "live-root", seq: 1, mentions: [])
        try post(store, "live-reply", seq: 2, root: "live-root", mentions: [])
        for (offset, root) in [nil, "live-root"].enumerated() {
            try post(store, "deleted-\(offset)", seq: 3 + offset, root: root, deleted: true)
            try post(store, "notified-\(offset)", seq: 5 + offset, root: root, deleted: true)
            try write(store) { db in
                try db.execute(sql: """
                    INSERT INTO notified (object_id, kind, channel_id, seq, read, thread_root_id)
                    VALUES (?, 'mention', 'alpha', ?, 0, ?)
                    """, arguments: ["notified-\(offset)", 5 + offset, root])
            }
        }
        // Revision 2 alone is an edit, not a deletion.
        try write(store) { try $0.execute(sql: "UPDATE messages SET revision = 2 WHERE message_id = 'live-root'") }
        try refresh(store, org)
        XCTAssertEqual(try entries(store).map(\.id), ["live-root", "live-reply"])
        XCTAssertTrue(try entries(store, .mentions).isEmpty)
        let sidebar = ChatSidebarSnapshot(model: org, active: nil)
        XCTAssertEqual(sidebar.unread.count, 1)
        XCTAssertEqual(org.unread("alpha")?.count, 1)
        XCTAssertEqual(try read(store) { try ChatUnread.unreadRepliesByChannel($0) }, ["alpha": 1])
        XCTAssertEqual(try read(store) { try ChatUnread.unreadRepliesByRoot($0, channel: "alpha").map(\.count) }, [1])
        let channel = ChatChannelModel(key: key, channel: "alpha"); channel.follow(store)
        try write(store) { try ChatUnread.markRead($0, channel: "alpha", upTo: 2) }
        channel.beginReading(root: nil)
        XCTAssertNil(channel.feed.unreadID, "a deleted root cannot start an unread divider")
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
    func testNativeInboxBindsWhenContextBecomesReadyWithoutIdentityChange() async throws {
        _ = NSApplication.shared
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        try service.saveSignIn(.init(server: key.server, accountId: me, sessionId: "s", deviceName: "Fixture", orgId: key.orgId), token: "fixture")
        defer { service.stopFeed() }
        let session = service.session(for: key)
        let (store, _) = try fixture(store: XCTUnwrap(session.store))
        try post(store, "existing", seq: 1)
        let current = ChatOrgCurrent()
        let identity = ChatOrgCurrent.identity(service)
        let ref = ChatInboxRef(key, kind: .mentions)
        let model = ChatInboxModel(ref: ref)
        let host = NSHostingView(rootView: ChatInboxTabView(ref: ref, openMessage: { _ in }, openChannel: { _ in }, close: {},
                                                           model: model, current: current, service: service))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); model.stop() }
        window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        try await wait { current.model != nil }
        XCTAssertTrue(model.entries(current.model).isEmpty)
        for _ in 0..<2 {
            session.snapshotOwed = false
            try await wait { model.entries(current.model).map(\.id) == ["existing"] }
            XCTAssertEqual(ChatOrgCurrent.identity(service), identity)
            session.snapshotOwed = true
            try await wait { model.entries(current.model).isEmpty && model.problem == nil }
        }
    }

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
        // Fixed native click coordinates require an isolated attention source:
        // earlier tests can leave local reasons in the app-wide ledger.
        let attention = AttentionSidebarModel(ledger: AttentionLedger())
        func content(_ kind: ChatInboxKind) -> AnyView {
            AnyView(HStack(spacing: 0) {
                ChatSidebarView(store: workspace, navigation: workspace.chatNavigation, model: org, attention: attention)
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
