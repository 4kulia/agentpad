import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramChatSearchTests: XCTestCase {
    private func readySettings(_ index: TelegramChatIndex) throws {
        // These list/search fixtures start after TDLib's settings updates.
        // Attention scan/option scheduling has separate fake-client tests.
        for scope in ["PrivateChats", "GroupChats", "ChannelChats"] {
            try index.apply(TDLibMessage("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScope" + scope),
                "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(0)])]), now: ChatFixture.now)
        }
    }
    private func session(_ fixture: TelegramFixture) throws -> TelegramChatSession {
        fixture.client.automaticChats = false
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try readySettings(index)
        let session = TelegramChatSession(index: index, send: { try fixture.client.send($0) })
        try session.activate(account: ChatFixture.me, user: FakeTDLibClient.user, now: Date(timeIntervalSince1970: Double(ChatFixture.now)))
        session.network = .ready
        return session
    }
    private func reply(_ session: TelegramChatSession, request: TDLibMessage, _ message: TDLibMessage, now: Date) {
        var message = message; message["@extra"] = request["@extra"]
        session.receive(message, now: now)
    }
    func testTraversalNeedsTwoIndependent404sAndNeverStopsAtOldOrEmptyChats() throws {
        let fixture = try TelegramFixture(), now = Date(timeIntervalSince1970: Double(ChatFixture.now))
        let session = try session(fixture)
        session.tick(now: now)
        for page in 0..<6 {
            let request = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
            XCTAssertEqual(request["limit"], .integer(50))
            XCTAssertEqual(session.calls.count, 1)
            // One very old Telegram-pinned chat, then an empty chat, then a
            // qualifying outgoing found much deeper than their position order.
            session.receive(ChatFixture.chat(Int64(page + 1), message: page == 4 ? ChatFixture.message() : .null), now: now)
            reply(session, request: request, TDLibMessage("ok"), now: now)
            session.tick(now: now)
            XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, page + 2)
        }
        let firstEnd = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
        reply(session, request: firstEnd, TDLibMessage("error", ["code": .integer(404)]), now: now)
        session.tick(now: now)
        let secondEnd = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
        XCTAssertNotEqual(firstEnd["chat_list"], secondEnd["chat_list"])
        XCTAssertNotEqual(session.index.state, .complete)
        reply(session, request: secondEnd, TDLibMessage("error", ["code": .integer(404)]), now: now)
        session.tick(now: now); session.publish(now: now)
        XCTAssertEqual(session.snapshot.state, .complete)
        XCTAssertEqual(session.snapshot.foundCount, 6); XCTAssertEqual(session.snapshot.automaticCount, 1)
        XCTAssertFalse(fixture.client.requests.contains { ["getChatHistory", "searchChatMessages", "viewMessages", "sendMessage"].contains($0.type) })
    }
    func testFailedCompletionCheckpointRetriesWithBackoffWithoutReloadingFinishedLists() throws {
        let fixture = try TelegramFixture(), now = Date(timeIntervalSince1970: Double(ChatFixture.now))
        fixture.client.automaticChats = false
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        var diskFull = true, writes: [String] = []
        try readySettings(index)
        let session = TelegramChatSession(index: index, send: { try fixture.client.send($0) }, writeCheckpoint: { key, value in
            writes.append(key)
            if diskFull { throw CocoaError(.fileWriteOutOfSpace) }
            try index.checkpoint(key, value: value)
        })
        try session.activate(account: ChatFixture.me, user: FakeTDLibClient.user, now: now)
        session.network = .ready
        for list in ["chatListMain", "chatListArchive"] {
            session.tick(now: now)
            let request = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
            XCTAssertEqual(request["chat_list"]?.object?.type, list)
            reply(session, request: request, TDLibMessage("error", ["code": .integer(404)]), now: now)
        }
        session.tick(now: now.addingTimeInterval(0.1))
        XCTAssertEqual(session.snapshot.state, .complete, "The 404 completion remains true in memory")
        XCTAssertNotNil(session.snapshot.error)
        XCTAssertEqual(writes.count, 1, "The second completion respects the pending disk backoff")
        let failureRevision = session.snapshot.revision
        // Exponential disk retries cap at 64 seconds; ticks between retries
        // neither hit the disk nor re-publish the same error.
        for (offset, due) in [2.0, 6, 14, 30, 62, 126, 190].enumerated() {
            session.tick(now: now.addingTimeInterval(due - 0.1))
            XCTAssertEqual(writes.count, offset + 1)
            session.tick(now: now.addingTimeInterval(due))
            XCTAssertEqual(writes.count, offset + 2)
            XCTAssertEqual(session.snapshot.revision, failureRevision)
            XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, 2)
        }
        XCTAssertEqual(try index.checkpoint("mainDone"), 0)
        XCTAssertEqual(try index.checkpoint("archiveDone"), 0)
        diskFull = false
        session.tick(now: now.addingTimeInterval(254))
        XCTAssertEqual(try index.checkpoint("mainDone"), 1)
        XCTAssertEqual(try index.checkpoint("archiveDone"), 1)
        XCTAssertNil(session.snapshot.error)
        XCTAssertEqual(session.snapshot.state, .complete)
        let savedWrites = writes.count
        session.tick(now: now.addingTimeInterval(400))
        XCTAssertEqual(writes.count, savedWrites)
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, 2)
    }
    func testSearchDebounceLatestPendingDedupAndNoNetworkForEmptyQuery() async throws {
        let fixture = try TelegramFixture(), now = Date(timeIntervalSince1970: Double(ChatFixture.now))
        let session = try session(fixture)
        session.receive(ChatFixture.chat(1, title: "Ada", message: ChatFixture.message()), now: now)
        session.receive(ChatFixture.chat(2, title: "Ada archive", positions: [ChatFixture.position("Archive")]), now: now)
        try session.index.mode(2, .hidden)
        let empty = session.beginSearch("", now: now)
        var emptyIterator = empty.makeAsyncIterator()
        let initial = await emptyIterator.next()
        XCTAssertEqual(initial?.hits.first?.row.id.chat, 1)
        session.tick(now: now.addingTimeInterval(1))
        XCTAssertEqual(fixture.client.requests.filter { $0.type.hasPrefix("search") }.map(\.type), ["searchChats"])
        let oldRequest = try XCTUnwrap(fixture.client.requests.first { $0.type == "searchChats" })
        _ = session.beginSearch("a", now: now)
        let stream = session.beginSearch("Ada", now: now)
        var iterator = stream.makeAsyncIterator()
        let local = await iterator.next()
        XCTAssertEqual(Set(local?.hits.map(\.row.id.chat) ?? []), Set([1, 2]))
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "searchChats" }.count, 1, "One in flight, only latest pending")
        reply(session, request: oldRequest, TDLibMessage("chats", ["chat_ids": .array([])]), now: now)
        session.tick(now: now)
        let latest = try XCTUnwrap(fixture.client.requests.last { $0.type == "searchChats" })
        XCTAssertEqual(latest["query"], .string("Ada"))
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "searchChatsOnServer" })
        session.tick(now: now.addingTimeInterval(0.16))
        let server = try XCTUnwrap(fixture.client.requests.last { $0.type == "searchChatsOnServer" })
        XCTAssertEqual(server["limit"], .integer(50)); XCTAssertEqual(server["type_filter"], .null)
        reply(session, request: server, TDLibMessage("chats", ["chat_ids": .array([.integer(2), .integer(1), .integer(2)])]), now: now)
        XCTAssertEqual(session.search?.hits.count, 2)
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "createPrivateChat" || $0.type == "addRecentlyFoundChat" })
    }
    func testServerWaitAndResourcePauseKeepLocalResultsAndDoNotDuplicateCalls() async throws {
        let fixture = try TelegramFixture(), now = Date(timeIntervalSince1970: Double(ChatFixture.now))
        let session = try session(fixture)
        session.pause = "Low Power Mode"; session.tick(now: now)
        XCTAssertTrue(fixture.client.requests.isEmpty)
        session.receive(ChatFixture.chat(1, title: "Ada"), now: now)
        let stream = session.beginSearch("Ada", now: now)
        var iterator = stream.makeAsyncIterator()
        let local = await iterator.next()
        XCTAssertEqual(local?.hits.count, 1)
        session.pause = nil; session.tick(now: now)
        let load = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
        for offset in [10.0, 50, 100] { session.tick(now: now.addingTimeInterval(offset)) }
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, 1)
        reply(session, request: load, TDLibMessage("error", ["code": .integer(429), "message": .string("Too Many Requests: retry after 120")]), now: now)
        session.tick(now: now.addingTimeInterval(119))
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, 1)
        XCTAssertGreaterThan(try session.index.checkpoint("retryNotBefore"), ChatFixture.now + 120)
        session.tick(now: now.addingTimeInterval(122))
        XCTAssertEqual(fixture.client.requests.filter { $0.type == "loadChats" }.count, 2)
    }
    func testContactsUseUserIdentityUntilSelectedAndSavedMessagesAlias() async throws {
        let fixture = try TelegramFixture(), now = Date(timeIntervalSince1970: Double(ChatFixture.now))
        let session = try session(fixture)
        let stream = session.beginSearch("Избранное", now: now)
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        let saved = try XCTUnwrap(result?.hits.first)
        XCTAssertEqual(saved.userID, ChatFixture.me); XCTAssertEqual(saved.row.kind, .savedMessages)
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "createPrivateChat" })
        session.receive(TDLibMessage("updateUser", ["user": .object(["id": .integer(7), "first_name": .string("Ada"), "type": .object(["@type": .string("userTypeRegular")])])]), now: now)
        _ = session.beginSearch("@ada", now: now)
        session.tick(now: now.addingTimeInterval(0.2))
        let contacts = try XCTUnwrap(fixture.client.requests.first { $0.type == "searchContacts" })
        reply(session, request: contacts, TDLibMessage("users", ["user_ids": .array([.integer(7)])]), now: now)
        XCTAssertEqual(session.search?.hits.values.first?.userID, 7)
        XCTAssertTrue(fixture.client.requests.contains { $0.type == "searchPublicChat" && $0["username"] == .string("ada") })
        XCTAssertLessThanOrEqual(session.calls.count, 7)
        session.receive(ChatFixture.chat(70, title: "Ada", user: 7), now: now)
        let server = try XCTUnwrap(fixture.client.requests.last { $0.type == "searchChatsOnServer" })
        reply(session, request: server, TDLibMessage("chats", ["chat_ids": .array([.integer(70)])]), now: now)
        XCTAssertEqual(session.search?.hits.count, 1, "The later chat coalesces its contact alias")
        XCTAssertEqual(session.search?.hits.values.first?.row.id.chat, 70)
        XCTAssertNil(session.search?.hits.values.first?.userID)
    }
}
