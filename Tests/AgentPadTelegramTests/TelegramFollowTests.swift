import Foundation
import GRDB
import XCTest
@testable import AgentPadTelegram

enum FollowFixture {
    static let now = ChatFixture.now
    static func apply(_ value: TDLibMessage, _ index: TelegramChatIndex) throws { try FolderFixture.apply(value, index) }
    static func chat(_ index: TelegramChatIndex, id: Int64 = 1, kind: TelegramChatKind = .group, head: Int64 = 100) throws {
        try apply(.init("updateUser", ["user": .typed("user", ["id": .integer(id), "type": .typed("userTypeRegular")])]), index)
        if [.forum,.supergroup,.channel].contains(kind) { try apply(ChatFixture.group(id, channel: kind == .channel, forum: kind == .forum), index) }
        let type = [.forum,.supergroup,.channel].contains(kind) ? "chatTypeSupergroup" : kind == .group ? "chatTypeBasicGroup" : "chatTypePrivate"
        var value = ChatFixture.chat(id, type: type, message: .object(AttentionFixture.message(head, chat: id, outgoing: true).fields), unread: 20, mentions: 1)
        var raw = value["chat"]!.object!; raw["notification_settings"] = AttentionFixture.settings(); value["chat"] = .object(raw.fields)
        try apply(value, index)
        for scope in ["PrivateChats","GroupChats","ChannelChats"] {
            try apply(.init("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScope" + scope), "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(0)])]), index)
        }
    }
    static func topic(_ index: TelegramChatIndex, _ id: Int64, inbox: Int64 = 0, mute: Int64 = 0) throws {
        try apply(.init("updateForumTopic", ["chat_id": .integer(1), "forum_topic_id": .integer(id), "last_read_inbox_message_id": .integer(inbox), "notification_settings": AttentionFixture.settings(mute: mute)]), index)
    }
    static func work(_ index: TelegramChatIndex, _ key: String) throws -> TelegramAttentionWork {
        let result = try index.db.read { db -> TelegramAttentionWork in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM tg_work WHERE key=?", arguments: [key]))
            return .init(key: row["key"], method: row["method"], chat: row["chat"], topic: row["topic"], message: row["message"], cursor: row["cursor"], pageSize: row["pageSize"], version: row["version"])
        }
        TelegramFixtureSchema.check(TDLibMessage(result.method, result.fields)); return result
    }
    static func finish(_ index: TelegramChatIndex, _ work: TelegramAttentionWork, _ messages: [TDLibMessage], next: Int64 = 0) throws {
        var fields: [String:TDLibValue] = ["messages": .array(messages.map { .object($0.fields) })]
        if work.method == "searchChatMessages" { fields["next_from_message_id"] = .integer(next) }
        let value = TDLibMessage(work.method == "searchChatMessages" ? "foundChatMessages" : "messages", fields)
        TelegramFixtureSchema.check(value); try index.finishAttentionWork(work, response: value, now: now)
    }
    static func new(_ index: TelegramChatIndex, _ message: TDLibMessage) throws { try apply(.init("updateNewMessage", ["message": .object(message.fields)]), index) }
}

final class TelegramFollowTests: XCTestCase {
    func testHeldAttentionPromotionDemotionNewChatsAndEmptyWindowKeepFrozenFrontier() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for chat: Int64 in 1...120 {
            try FollowFixture.chat(index, id: chat); try AttentionFixture.follow(index, chat: chat)
            var message = AttentionFixture.message(150, chat: chat); message["date"] = .integer(1000 - chat)
            try FollowFixture.new(index, message)
        }
        var mention = AttentionFixture.message(50, chat: 11, unreadMention: true); mention["date"] = .integer(2000)
        try FollowFixture.new(index, mention)
        let before = try index.project(now: FollowFixture.now), owner = UUID()
        let second = try index.attentionPage(start: 50, revision: before.attentionRevision, now: FollowFixture.now)
        index.attentionHolds.insert(owner)
        var promotion = AttentionFixture.message(50, chat: 61, unreadMention: true); promotion["date"] = .integer(3000)
        try FollowFixture.new(index, promotion)
        try FollowFixture.apply(.init("updateMessageMentionRead", ["chat_id": .integer(11),"message_id": .integer(50),"unread_mention_count": .integer(0)]), index)
        try FollowFixture.chat(index, id: 121); try AttentionFixture.follow(index, chat: 121)
        try FollowFixture.new(index, AttentionFixture.message(151, chat: 121))
        let held = try index.project(now: FollowFixture.now)
        XCTAssertEqual(held.attentionRevision,before.attentionRevision); XCTAssertEqual(held.attentionRows.map(\.id),before.attentionRows.map(\.id))
        XCTAssertEqual(held.attentionTotal,121); XCTAssertEqual(held.attentionNewCount,1)
        let page = try index.attentionPage(start: 50, revision: before.attentionRevision, now: FollowFixture.now)
        XCTAssertEqual(page.rows.map(\.id),second.rows.map(\.id)); XCTAssertEqual(page.attentionFrontier,second.attentionFrontier)
        XCTAssertEqual(page.rows.first { $0.id.chat == 61 }?.attentionOrderKey?.tier,4)
        XCTAssertEqual(page.rows.first { $0.id.chat == 61 }?.attention?.kind,.mention)
        for row in before.attentionRows { try index.mode(row.id.chat,.hidden,now: FollowFixture.now) }
        let empty = try index.project(now: FollowFixture.now)
        XCTAssertTrue(empty.attentionRows.isEmpty); XCTAssertEqual(empty.attentionNext,50); XCTAssertEqual(empty.attentionFrontier,before.attentionFrontier)
        XCTAssertEqual(empty.attentionWindowCounts,[0:0,50:50,100:20])
        index.attentionHolds.remove(owner)
        XCTAssertEqual(try index.project(now: FollowFixture.now).attentionRows.first?.id.chat,61)
        XCTAssertTrue(try index.attentionPage(start: 50,revision: before.attentionRevision,now: FollowFixture.now).rows.isEmpty)
    }

    func testEmptySearchPreservesSuggestionsWithMainHiddenAndArchiveFindable() async throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index, id: 1, kind: .person)
        try FollowFixture.chat(index, id: 2, kind: .person)
        try FollowFixture.new(index, AttentionFixture.message(150, chat: 2))
        try FolderFixture.position(1,.main,9999,index)
        try index.setListVisible(.main,visible: false)
        try FollowFixture.chat(index, id: 3, kind: .person)
        try FolderFixture.position(3,.archive,9999,index); try index.mode(3,.hidden,now: FollowFixture.now)
        let session = TelegramChatSession(index: index, send: { request in
            TelegramFixtureSchema.check(request)
            XCTAssertEqual(request.type,"searchChats", "Empty suggestions may query TDLib's offline directory only")
        })
        try session.activate(account: ChatFixture.me,user: nil,now: Date(timeIntervalSince1970: Double(FollowFixture.now)))
        let snapshot = try index.project(now: FollowFixture.now)
        XCTAssertEqual(snapshot.suggestionRows.map(\.id.chat),[2,1])
        var iterator = session.beginSearch("",now: Date(timeIntervalSince1970: Double(FollowFixture.now))).makeAsyncIterator()
        let search = await iterator.next(); XCTAssertEqual(search?.hits.map(\.row.id.chat),[2,1])
        let hidden = try XCTUnwrap(index.localMatches("Chat 3",now: FollowFixture.now).first)
        XCTAssertTrue(hidden.hidden); XCTAssertTrue(hidden.inArchive)
    }

    func testOnlineActivationBoundaryRetriesAndRejectsObsoleteRepliesForAllFollowKinds() throws {
        for kind: TelegramChatKind in [.group,.supergroup,.forum,.channel] {
            let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
            try FollowFixture.chat(index, kind: kind)
            if kind == .forum { try FollowFixture.topic(index, 1) }
            try index.follow(1, enabled: true, now: FollowFixture.now)
            let work = try FollowFixture.work(index, "activate:1")
            XCTAssertEqual(work.method, "getChatHistory"); XCTAssertEqual(work.fields["only_local"], .bool(false))
            XCTAssertEqual(work.fields["from_message_id"], .integer(0)); XCTAssertEqual(work.pageSize, 1)
            XCTAssertTrue(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followActivating)
            try FollowFixture.new(index, AttentionFixture.message(130, topic: kind == .forum ? 1 : nil))
            XCTAssertNil(try index.get(1, now: FollowFixture.now)?.attention)
            let error = TDLibMessage("error", ["code": .integer(500), "message": .string("offline")]); TelegramFixtureSchema.check(error)
            try index.finishAttentionWork(work, response: error, now: FollowFixture.now)
            XCTAssertTrue(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followActivating)
            XCTAssertGreaterThan(try index.db.read { try Int64.fetchOne($0, sql: "SELECT retry FROM tg_work WHERE key='activate:1'") } ?? 0, FollowFixture.now)
            try FollowFixture.finish(index, work, [AttentionFixture.message(999, chat: 2)])
            XCTAssertTrue(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followActivating)
            try FollowFixture.finish(index, work, [AttentionFixture.message(120)])
            XCTAssertFalse(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followActivating)
            XCTAssertEqual(try index.db.read { try Int64.fetchOne($0, sql: "SELECT activation FROM tg_state WHERE chat=1") }, 130)
            for id: Int64 in [129,130,131] { try FollowFixture.new(index, AttentionFixture.message(id, topic: kind == .forum ? 1 : nil)) }
            XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.firstMessage, 131)
            XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.kind, kind == .channel ? .channelPost : .groupMessage)
            try index.follow(1, enabled: false, now: FollowFixture.now)
            try FollowFixture.finish(index, work, [AttentionFixture.message(999)])
            XCTAssertFalse(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followEnabled)
            XCTAssertNil(try index.get(1, now: FollowFixture.now)?.attention)
        }
    }

    func testMentionsAndOrdinaryHistoryAreIndependentAndReconcileOnlyTheirOwnRows() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index, head: 200); try AttentionFixture.follow(index)
        try FollowFixture.apply(.init("updateChatReadInbox", ["chat_id": .integer(1),"last_read_inbox_message_id": .integer(210),"unread_count": .integer(5)]), index)
        let oldMention = AttentionFixture.message(50, unreadMention: true)
        let mention = try FollowFixture.work(index, "scan:1"), history = try FollowFixture.work(index, "history:1")
        XCTAssertEqual(mention.method, "searchChatMessages"); XCTAssertEqual(history.method, "getChatHistory")
        try FollowFixture.finish(index, mention, [oldMention])
        try FollowFixture.new(index, AttentionFixture.message(220)); try FollowFixture.new(index, AttentionFixture.message(230, unreadMention: true))
        try FollowFixture.new(index, AttentionFixture.message(240, unreadMention: true))
        // Capture a head including 220, then prove that ordinary row gone.
        try FollowFixture.apply(.init("updateChatLastMessage", ["chat_id": .integer(1),"last_message": .object(AttentionFixture.message(250, outgoing: true).fields),"positions": .array([])]), index)
        let revised = try FollowFixture.work(index, "history:1")
        try FollowFixture.finish(index, revised, [AttentionFixture.message(230, unreadMention: true),AttentionFixture.message(210)])
        let summary = try XCTUnwrap(index.get(1, now: FollowFixture.now)?.attention)
        XCTAssertEqual(summary.kind, .mention); XCTAssertEqual(summary.count, 3); XCTAssertEqual(summary.firstMessage, 50)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_messages WHERE chat=1 AND id=230") }, 1)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_messages WHERE chat=1 AND id=220") }, 0)
        try index.follow(1, enabled: false, now: FollowFixture.now)
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 3)
        XCTAssertEqual(try FollowFixture.work(index, "scan:1").method, "searchChatMessages")
    }

    func testOrdinaryMuteUsesTopicChatScopeWhileMentionsUseSenderAndUnknownFailsClosed() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index, kind: .forum); try FollowFixture.topic(index, 1); try AttentionFixture.follow(index)
        try FollowFixture.apply(.init("updateChatNotificationSettings", ["chat_id": .integer(1),"notification_settings": AttentionFixture.settings(mute: 600)]), index)
        // The topic inherits the muted chat; sender/private scope is unmuted.
        try FollowFixture.apply(.init("updateForumTopic", ["chat_id": .integer(1),"forum_topic_id": .integer(1),"notification_settings": AttentionFixture.settings(inherit: true)]), index)
        try FollowFixture.new(index, AttentionFixture.message(101, topic: 1))
        XCTAssertNil(try index.get(1, now: FollowFixture.now)?.attention)
        try FollowFixture.new(index, AttentionFixture.message(102, unreadMention: true, topic: 1))
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.kind, .mention)
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 1)
        try FollowFixture.topic(index, 1)
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 2)
        try index.db.write { try $0.execute(sql: "DELETE FROM tg_scopes; UPDATE tg_settings SET muteUntil=NULL") }
        try index.refreshAttention(now: FollowFixture.now)
        XCTAssertNil(try index.get(1, now: FollowFixture.now)?.attention)
    }

    func testStrongestClassOwnsAnchorTopicTimeAndCountAcrossForumTopicsWithoutEviction() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index, kind: .forum); try FollowFixture.topic(index, 1); try FollowFixture.topic(index, 2)
        try AttentionFixture.follow(index)
        try FollowFixture.new(index, AttentionFixture.message(150, unreadMention: true, topic: 1))
        for id: Int64 in 200..<1400 { try FollowFixture.new(index, AttentionFixture.message(id, topic: id < 800 ? 1 : 2)) }
        let summary = try XCTUnwrap(index.get(1, now: FollowFixture.now)?.attention)
        XCTAssertEqual(summary.kind, .mention); XCTAssertEqual(summary.firstMessage, 150)
        XCTAssertEqual(summary.destination.topic, .forum(1)); XCTAssertEqual(summary.lastDate, FollowFixture.now + 150)
        XCTAssertEqual(summary.classCount, 1); XCTAssertEqual(summary.count, 1201)
        try FollowFixture.topic(index, 2, inbox: 2000)
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 601)
        try FollowFixture.new(index, AttentionFixture.message(1401, topic: 2))
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 601)
        try FollowFixture.apply(.init("updateMessageMentionRead", ["chat_id": .integer(1),"message_id": .integer(150),"unread_mention_count": .integer(0)]), index)
        let demoted = try XCTUnwrap(index.get(1, now: FollowFixture.now)?.attention)
        XCTAssertEqual(demoted.kind, .groupMessage); XCTAssertEqual(demoted.firstMessage, 150)
        XCTAssertEqual(demoted.lastDate, FollowFixture.now + 799)
    }

    func testRestartHistoryResumesAfterTenPagesAndKeepsMigratedBoundary() throws {
        let fixture = try TelegramFixture()
        var first: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(first!, head: 1500); try AttentionFixture.follow(first!)
        try first!.db.write { try $0.execute(sql: "UPDATE tg_state SET activation=100; DELETE FROM tg_work") }
        first = nil
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try index.prepareAttentionScan(now: FollowFixture.now)
        XCTAssertEqual(try index.db.read { try Int64.fetchOne($0, sql: "SELECT activation FROM tg_state WHERE chat=1") }, 100)
        try FollowFixture.finish(index, FollowFixture.work(index, "scan:1"), [])
        try index.db.write { db in try index.enqueueAttentionWork(key: "later", method: "getChat", chat: 2, lane: 1, db: db, now: FollowFixture.now) }
        for page in 0..<10 {
            let work = try FollowFixture.work(index, "history:1")
            let top = Int64(1500 - page * 50)
            try FollowFixture.finish(index, work, (0..<50).map { AttentionFixture.message(top - Int64($0)) })
        }
        XCTAssertEqual(try index.nextAttentionWork(lane: 1, now: FollowFixture.now)?.key, "later")
        let work = try FollowFixture.work(index, "history:1"); XCTAssertEqual(work.cursor, 1001)
        XCTAssertTrue(try XCTUnwrap(index.get(1, now: FollowFixture.now)?.attention).incomplete)
        try FollowFixture.finish(index, work, [AttentionFixture.message(1000),AttentionFixture.message(100)])
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 501)
        XCTAssertFalse(try XCTUnwrap(index.get(1, now: FollowFixture.now)?.attention).incomplete)
    }

    func testPerChatReductionAndCoalescedSenderMuteAndCrossChatReplyResolution() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index); try FollowFixture.chat(index, id: 2); try FollowFixture.chat(index, id: 42, kind: .person)
        try FollowFixture.new(index, AttentionFixture.message(150, unreadMention: true))
        try FollowFixture.new(index, AttentionFixture.message(151, chat: 2, unreadMention: true))
        _ = try index.project(now: FollowFixture.now)
        try index.db.write { try $0.execute(sql: "CREATE TABLE reduction_audit(chat INTEGER); CREATE TRIGGER record_reduction BEFORE DELETE ON tg_reason_messages BEGIN INSERT INTO reduction_audit VALUES (OLD.chat); END;") }
        try FollowFixture.new(index, AttentionFixture.message(152, unreadMention: true))
        XCTAssertEqual(try index.db.read { try Set(Int64.fetchAll($0, sql: "SELECT chat FROM reduction_audit")) }, [1])
        try index.db.write { try $0.execute(sql: "DELETE FROM reduction_audit") }
        for _ in 0..<5 { try FollowFixture.apply(.init("updateChatNotificationSettings", ["chat_id": .integer(42),"notification_settings": AttentionFixture.settings(mute: 600)]), index) }
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM reduction_audit") }, 0)
        XCTAssertEqual(try index.project(now: FollowFixture.now).attentionTotal, 0)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM reduction_audit") }, 3)
        try FollowFixture.apply(.init("updateChatNotificationSettings", ["chat_id": .integer(42),"notification_settings": AttentionFixture.settings()]), index)
        var reply = AttentionFixture.message(153, chat: 2, unreadMention: true, reply: 99)
        reply["reply_to"] = .typed("messageReplyToMessage", ["chat_id": .integer(1),"message_id": .integer(99)])
        try FollowFixture.new(index, reply); _ = try index.project(now: FollowFixture.now)
        try FollowFixture.new(index, AttentionFixture.message(99, outgoing: true))
        XCTAssertEqual(try index.project(now: FollowFixture.now).attentionRows.first { $0.id.chat == 2 }?.attention?.kind, .reply)
    }

    func testGroupEpisodeBannersAndHiddenFollowClosure() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index); try AttentionFixture.follow(index)
        try FollowFixture.apply(NotificationFixture.snapshot([]), index)
        for id: Int64 in [101,102] {
            let notification = TDLibValue.typed("notification", ["id": .integer(id),"date": .integer(FollowFixture.now),"is_silent": .bool(false),"type": .typed("notificationTypeNewMessage", ["message": .object(AttentionFixture.message(id).fields)])])
            try FollowFixture.apply(NotificationFixture.group(added: [notification]), index)
            let items = try index.project(now: FollowFixture.now).attention.notifications.items
            XCTAssertEqual(items.count,1)
            XCTAssertEqual(items.filter(\.mayDeliver).count,id == 101 ? 1 : 0)
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.kind, .groupMessage); XCTAssertEqual(item.mayDeliver, id == 101)
            if id == 101 { try index.consumeNotification(item.id, now: FollowFixture.now) }
        }
        try index.mode(1, .hidden, now: FollowFixture.now); try index.mode(1, .auto, now: FollowFixture.now)
        XCTAssertFalse(try XCTUnwrap(index.get(1, now: FollowFixture.now)).followEnabled)
        XCTAssertNil(try index.get(1, now: FollowFixture.now)?.attention)
    }

    func testMeasureFullReductionOfOneHundredThousandUnreadRows() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try FollowFixture.chat(index); try AttentionFixture.follow(index)
        try index.db.write { db in
            try db.execute(sql: "WITH RECURSIVE n(id) AS (SELECT 101 UNION ALL SELECT id+1 FROM n WHERE id<100100) INSERT INTO tg_messages(chat,id,topic,date,sender,mentioned,unreadMention,replyChat,replyID,replyToMe) SELECT 1,id,'',id,42,0,0,0,0,0 FROM n")
        }
        let start = Date(); try index.refreshAttention(now: FollowFixture.now)
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print("Part B 100000-row full attention reduction: \(milliseconds) ms (debug)")
        XCTAssertEqual(try index.get(1, now: FollowFixture.now)?.attention?.count, 100000)
    }
}
