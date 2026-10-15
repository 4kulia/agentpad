import Foundation
import GRDB
import XCTest
@testable import AgentPadTelegram

@MainActor final class TelegramFolderSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: Double(ChatFixture.now))
    private func session(_ fixture: TelegramFixture) throws -> TelegramChatSession {
        fixture.client.automaticChats = false
        let index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        for scope in ["PrivateChats","GroupChats","ChannelChats"] {
            try FolderFixture.apply(TDLibMessage("updateScopeNotificationSettings",["scope": .typed("notificationSettingsScope" + scope),"notification_settings": .typed("scopeNotificationSettings",["mute_for": .integer(0)])]),index)
        }
        let session = TelegramChatSession(index: index,send: { try fixture.client.send($0) })
        try session.activate(account: ChatFixture.me,user: nil,now: now); session.network = .ready
        return session
    }
    private func reply(_ session: TelegramChatSession, _ request: TDLibMessage, code: Int64? = nil) {
        var response = code.map { TDLibMessage("error",["code": .integer($0),"message": .string($0 == 429 ? "retry after 5" : "test")]) } ?? TDLibMessage("ok")
        response["@extra"] = request["@extra"]; TelegramFixtureSchema.check(response)
        session.receive(response,now: now)
    }
    func testRoundRobinAlwaysLoadsMainArchiveAndVisibleFoldersAndObsoleteRepliesAreIgnored() throws {
        let fixture = try TelegramFixture(), session = try session(fixture), index = session.index
        try FolderFixture.apply(FolderFixture.folders([2,3]),index)
        try index.setListVisible(.main,visible: false); try index.setListVisible(.folder(3),visible: false)
        var loaded: [TelegramListKey] = []
        for _ in 0..<3 {
            session.tick(now: now)
            let request = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
            loaded.append(try XCTUnwrap(TelegramListKey(request["chat_list"]?.object)))
            XCTAssertEqual(session.calls.count,1); TelegramFixtureSchema.check(request)
            reply(session,request,code: 404)
        }
        XCTAssertEqual(loaded,[.main,.folder(2),.archive])
        session.tick(now: now); XCTAssertEqual(index.state,.complete)
        try index.setListVisible(.folder(3),visible: true); session.tick(now: now)
        let stale = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
        try FolderFixture.apply(FolderFixture.folders([2]),index)
        reply(session,stale,code: 500)
        XCTAssertLessThan(session.retryNotBefore,now)
        XCTAssertNil(index.listStates[.folder(3)])
        try FolderFixture.apply(FolderFixture.folders([2,3]),index)
        reply(session,stale,code: 404)
        XCTAssertFalse(try XCTUnwrap(index.listStates[.folder(3)]).complete)
        session.tick(now: now)
        let current = try XCTUnwrap(fixture.client.requests.last { $0.type == "loadChats" })
        reply(session,current,code: 429)
        XCTAssertGreaterThan(session.retryNotBefore,now.addingTimeInterval(5))
    }
    func testAttentionAndListsShareOneBackgroundSlotAndCompletionWaitsForAttention() throws {
        let fixture = try TelegramFixture(), session = try session(fixture)
        try session.index.db.write { db in
            try session.index.enqueueAttentionWork(key: "test",method: "getChat",chat: 1,lane: 0,db: db,now: ChatFixture.now)
        }
        session.tick(now: now)
        XCTAssertEqual(session.calls.count,1)
        XCTAssertEqual(fixture.client.requests.last?.type,"getChat")
        for i in 1...20 { session.tick(now: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(session.calls.count,1)
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "loadChats" })
        for key in try session.index.requiredLists() { try session.index.completeList(key,generation: session.index.listStates[key]!.generation) }
        session.tick(now: now)
        XCTAssertNotEqual(session.index.state,.complete)
    }
    func testMarkReadRequestsAreSequentialContinueAfterFailureAndNeverMutateLocalState() async throws {
        let fixture = try TelegramFixture(), session = try session(fixture)
        try FolderFixture.apply(ChatFixture.chat(1,message: ChatFixture.message(id: 55),unread: 2,mentions: 3),session.index)
        try FolderFixture.apply(TDLibMessage("updateChatIsMarkedAsUnread",["chat_id": .integer(1),"is_marked_as_unread": .bool(true)]),session.index)
        let task = Task { await withCheckedContinuation { session.markAsRead(1,retry: nil,now: now,continuation: $0) } }
        await Task.yield()
        let methods = ["viewMessages","toggleChatIsMarkedAsUnread","readAllChatMentions"]
        for (offset,method) in methods.enumerated() {
            let request = try XCTUnwrap(fixture.client.requests.last)
            XCTAssertEqual(request.type,method); TelegramFixtureSchema.check(request)
            XCTAssertEqual(session.interactiveCount,1)
            if offset == 0 {
                XCTAssertEqual(request["message_ids"],.array([.integer(55)]))
                XCTAssertEqual(request["source"]?.object?.type,"messageSourceChatList")
                XCTAssertEqual(request["force_read"],.bool(true))
            }
            reply(session,request,code: offset == 1 ? 500 : nil)
        }
        let result = await task.value
        XCTAssertEqual(result.failed,[.markedUnread])
        let row = try XCTUnwrap(session.index.get(1,now: ChatFixture.now))
        XCTAssertEqual(row.unreadCount,2); XCTAssertEqual(row.unreadMentionCount,3); XCTAssertTrue(row.markedUnread)
        let retry = Task { await withCheckedContinuation { session.markAsRead(1,retry: result.failed,now: now,continuation: $0) } }
        await Task.yield()
        XCTAssertEqual(fixture.client.requests.last?.type,"toggleChatIsMarkedAsUnread")
        reply(session,try XCTUnwrap(fixture.client.requests.last))
        let retried = await retry.value; XCTAssertTrue(retried.succeeded)
    }
    func testMarkReadSingleStepsUnknownHeadForumAndInteractiveBudget() async throws {
        let fixture = try TelegramFixture(), session = try session(fixture), index = session.index
        try FolderFixture.apply(ChatFixture.chat(1,unread: 2),index)
        let unknown = try index.markReadPlan(chat: 1)
        XCTAssertTrue(unknown.0.isEmpty); XCTAssertTrue(unknown.1)
        try FolderFixture.apply(ChatFixture.chat(2,mentions: 3),index)
        XCTAssertEqual(try index.markReadPlan(chat: 2).0.map(\.0),[.mentions])
        try FolderFixture.apply(ChatFixture.chat(3),index)
        try FolderFixture.apply(TDLibMessage("updateChatIsMarkedAsUnread",["chat_id": .integer(3),"is_marked_as_unread": .bool(true)]),index)
        XCTAssertEqual(try index.markReadPlan(chat: 3).0.map(\.0),[.markedUnread])
        try FolderFixture.apply(ChatFixture.group(4,forum: true),index)
        try FolderFixture.apply(ChatFixture.chat(4,type: "chatTypeSupergroup",unread: 2),index)
        XCTAssertThrowsError(try index.markReadPlan(chat: 4))
        session.otherInteractiveCount = { 6 }
        let task = Task { await withCheckedContinuation { session.markAsRead(3,retry: nil,now: now,continuation: $0) } }
        await Task.yield(); XCTAssertFalse(fixture.client.requests.contains { $0.type == "toggleChatIsMarkedAsUnread" })
        session.otherInteractiveCount = { 0 }; session.tick(now: now)
        let request = try XCTUnwrap(fixture.client.requests.last { $0.type == "toggleChatIsMarkedAsUnread" })
        reply(session,request)
        let result = await task.value; XCTAssertTrue(result.succeeded)
    }
}
