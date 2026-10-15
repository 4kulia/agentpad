import Foundation
import GRDB
import XCTest
@testable import AgentPadTelegram

enum AttentionFixture {
    static let now = ChatFixture.now
    static func settings(mute: Int64 = 0, inherit: Bool = false, disableMention: Bool = false) -> TDLibValue {
        .typed("chatNotificationSettings", ["use_default_mute_for": .bool(inherit), "mute_for": .integer(mute),
            "use_default_disable_mention_notifications": .bool(false), "disable_mention_notifications": .bool(disableMention)])
    }
    static func message(_ id: Int64, chat: Int64 = 1, unreadMention: Bool = false,
                        reply: Int64? = nil, topic: Int64? = nil, outgoing: Bool = false) -> TDLibMessage {
        var raw = TDLibMessage("message", ["id": .integer(id), "chat_id": .integer(chat), "date": .integer(now + id),
            "is_outgoing": .bool(outgoing), "sender_id": .typed("messageSenderUser", ["user_id": .integer(outgoing ? ChatFixture.me : 42)]),
            "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("PRIVATE CONTENT")])]),
            "contains_unread_mention": .bool(unreadMention)])
        if let reply { raw["reply_to"] = .typed("messageReplyToMessage", ["chat_id": .integer(chat), "message_id": .integer(reply)]) }
        if let topic { raw["topic_id"] = .typed("messageTopicForum", ["forum_topic_id": .integer(topic)]) }
        return raw
    }
    static func chat(_ index: TelegramChatIndex, id: Int64 = 1, kind: TelegramChatKind = .person, mute: Int64 = 0) throws {
        try index.apply(TDLibMessage("updateUser", ["user": .typed("user", ["id": .integer(id), "type": .typed(kind == .bot ? "userTypeBot" : "userTypeRegular")])]), now: now)
        if [.channel, .forum, .supergroup].contains(kind) { try index.apply(ChatFixture.group(id, channel: kind == .channel, forum: kind == .forum), now: now) }
        let type = [.channel, .forum, .supergroup].contains(kind) ? "chatTypeSupergroup" : kind == .group ? "chatTypeBasicGroup" : "chatTypePrivate"
        var update = ChatFixture.chat(id, type: type, user: kind == .savedMessages ? ChatFixture.me : id, unread: 20, mentions: 2)
        var raw = update["chat"]!.object!; raw["notification_settings"] = settings(mute: mute)
        raw["last_read_inbox_message_id"] = .integer(0); update["chat"] = .object(raw.fields)
        try index.apply(update, now: now)
        for scope in ["PrivateChats", "GroupChats", "ChannelChats"] {
            try index.apply(TDLibMessage("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScope" + scope),
                "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(0), "disable_mention_notifications": .bool(false)])]), now: now)
        }
    }
    static func unread(_ index: TelegramChatIndex, chat: Int64 = 1) throws -> Int {
        try index.get(chat, now: now)?.attention?.count ?? 0
    }
    static func follow(_ index: TelegramChatIndex, chat: Int64 = 1) throws {
        try index.follow(chat, enabled: true, now: now)
        let work = try index.db.read { db -> TelegramAttentionWork in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM tg_work WHERE key=?", arguments: ["activate:\(chat)"]))
            return .init(key: row["key"], method: row["method"], chat: row["chat"], topic: row["topic"], message: row["message"], cursor: row["cursor"], pageSize: row["pageSize"], version: row["version"])
        }
        let response = TDLibMessage("messages", ["messages": .array([])])
        TelegramFixtureSchema.check(TDLibMessage(work.method, work.fields)); TelegramFixtureSchema.check(response)
        try index.finishAttentionWork(work, response: response, now: now)
    }
}

final class TelegramAttentionTests: XCTestCase {
    func testLegacyMessagesRecoverMentionsAndRecheckLostChatSenders() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .group)
        let mention = AttentionFixture.message(100, unreadMention: true)
        var channelMention = AttentionFixture.message(101, unreadMention: true)
        channelMention["sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(-42)])
        try index!.apply(mention, now: now); try index!.apply(channelMention, now: now)
        try index!.db.write { db in
            try db.execute(sql: """
                UPDATE tg_messages SET sender=0 WHERE senderIsChat=1;
                ALTER TABLE tg_messages DROP COLUMN senderIsChat;
                UPDATE tg_messages SET mentioned=0;
                DELETE FROM tg_reason_messages; DELETE FROM tg_work;
                """)
            try LegacyFolderFixture.makeVersionOne(db)
        }
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.bind(ChatFixture.me, now: now)
        XCTAssertEqual(try restored.get(1, now: now)?.attention?.count, 1)
        XCTAssertEqual(try restored.get(1, now: now)?.attention?.kind, .mention)
        let work = try XCTUnwrap(restored.nextAttentionWork(lane: 0, now: now))
        XCTAssertEqual(work.method, "getMessage"); XCTAssertEqual(work.message, 101)
        try restored.finishAttentionWork(work, response: channelMention, now: now)
        XCTAssertEqual(try restored.db.read { try Int64.fetchOne($0, sql: "SELECT sender FROM tg_messages WHERE id=101") }, -42)
        XCTAssertEqual(try restored.get(1, now: now)?.attention?.count, 1, "Unknown channel settings never use the private scope")
    }

    func testPlainMentionFromPinnedSearchSchemaCreatesAttentionAndNotificationUntilRead() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .group)
        let scan = try XCTUnwrap(index.nextAttentionWork(lane: 0, now: now))
        XCTAssertEqual(scan.method, "searchChatMessages")
        XCTAssertEqual(scan.fields["filter"], .typed("searchMessagesFilterUnreadMention"))
        let mention = AttentionFixture.message(100, unreadMention: true)
        try index.finishAttentionWork(scan, response: .init("foundChatMessages", ["messages": .array([.object(mention.fields)]),
            "next_from_message_id": .integer(0)]), now: now)
        XCTAssertEqual(try index.get(1, now: now)?.attention?.kind, .mention)
        XCTAssertEqual(try index.project(now: now).attention.totalCount, 1)
        try index.apply(NotificationFixture.snapshot([]), now: now)
        let notice = TDLibValue.typed("notification", ["id": .integer(1), "date": .integer(now), "is_silent": .bool(false),
            "type": .typed("notificationTypeNewMessage", ["message": .object(mention.fields)])])
        try index.apply(NotificationFixture.group(added: [notice]), now: now)
        XCTAssertTrue(try XCTUnwrap(index.project(now: now).attention.notifications.items.first).mayDeliver)
        try index.apply(TDLibMessage("updateMessageMentionRead", ["chat_id": .integer(1), "message_id": .integer(100), "unread_mention_count": .integer(0)]), now: now)
        try index.apply(mention, now: now)
        XCTAssertEqual(try index.project(now: now).attention.totalCount, 0)
        XCTAssertTrue(try index.project(now: now).attention.notifications.items.isEmpty)
    }

    func testChatSenderUsesItsExplicitMuteAndChannelScopeNeverPrivateScope() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .group)
        var reply = AttentionFixture.message(100, unreadMention: true, reply: 50)
        reply["sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(-42)])
        try index.apply(reply, now: now)
        XCTAssertNil(try index.get(1, now: now)?.attention, "Unknown sender chat settings fail closed")
        try AttentionFixture.chat(index, id: -42, kind: .channel, mute: 600)
        try index.apply(AttentionFixture.message(50, outgoing: true), now: now)
        XCTAssertNil(try index.get(1, now: now)?.attention)
        try index.apply(TDLibMessage("updateChatNotificationSettings", ["chat_id": .integer(-42), "notification_settings": AttentionFixture.settings(inherit: true)]), now: now)
        try index.apply(TDLibMessage("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScopeChannelChats"),
            "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(600)])]), now: now)
        XCTAssertNil(try index.get(1, now: now)?.attention, "An unmuted private scope cannot unmute a channel sender")
        try index.apply(TDLibMessage("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScopePrivateChats"),
            "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(600)])]), now: now)
        try index.apply(TDLibMessage("updateScopeNotificationSettings", ["scope": .typed("notificationSettingsScopeChannelChats"),
            "notification_settings": .typed("scopeNotificationSettings", ["mute_for": .integer(0)])]), now: now)
        XCTAssertEqual(try index.get(1, now: now)?.attention?.kind, .reply)
        let sender = try index.db.read { try Row.fetchOne($0, sql: "SELECT sender,senderIsChat FROM tg_messages WHERE chat=1 AND id=100") }
        XCTAssertEqual(sender?["sender"] as Int64?, -42); XCTAssertEqual(sender?["senderIsChat"] as Bool?, true)
    }

    func testViewedMessagesOnlyUpdateNewlyViewedReasonsWithoutRebuildingOrSorting() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for chat: Int64 in [1, 2] {
            try AttentionFixture.chat(index, id: chat)
            for id: Int64 in [100, 101] { try index.apply(AttentionFixture.message(id, chat: chat), now: now) }
        }
        _ = try index.project(now: now)
        try index.db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER no_reason_rebuild BEFORE DELETE ON tg_reason_messages BEGIN SELECT RAISE(ABORT,'reason rebuild'); END;
                CREATE TRIGGER no_other_chat_update BEFORE UPDATE ON tg_reason_messages WHEN OLD.chat!=1 BEGIN SELECT RAISE(ABORT,'unrelated chat'); END;
                CREATE TRIGGER no_resort BEFORE DELETE ON tg_list_order BEGIN SELECT RAISE(ABORT,'chat order rebuild'); END;
                """)
        }
        index.dirty = false
        try index.viewedMessages(chat: 1, ids: [100, 999], now: now)
        XCTAssertTrue(index.dirty)
        XCTAssertEqual(try index.project(now: now).attention.totalCount, 4)
        let viewed = try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_reason_messages WHERE viewed=1") }
        XCTAssertEqual(viewed, 1)
        index.dirty = false
        let changes = try index.db.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        for _ in 0..<20 { try index.viewedMessages(chat: 1, ids: [100, 999], now: now) }
        XCTAssertFalse(index.dirty)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }, changes)
        try index.viewedMessages(chat: 1, ids: [100, 101], now: now)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_reason_messages WHERE viewed=1") }, 2)
        _ = try index.project(now: now)
    }

    func testMentionedBotReplyStillVerifiesTheOutgoingTarget() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .bot)
        let scan = try XCTUnwrap(index.nextAttentionWork(lane: 0, now: AttentionFixture.now))
        try index.finishAttentionWork(scan, response: TDLibMessage("messages", ["messages": .array([])]), now: AttentionFixture.now)
        try index.apply(AttentionFixture.message(100, unreadMention: true, reply: 50), now: AttentionFixture.now)
        XCTAssertNil(try index.get(1, now: AttentionFixture.now)?.attention)
        let verification = try XCTUnwrap(index.nextAttentionWork(lane: 0, now: AttentionFixture.now))
        XCTAssertEqual(verification.method, "getMessage"); XCTAssertEqual(verification.message, 50)
        try index.finishAttentionWork(verification, response: AttentionFixture.message(50, outgoing: true), now: AttentionFixture.now)
        XCTAssertEqual(try index.get(1, now: AttentionFixture.now)?.attention?.kind, .botReply)
    }

    func testEquallyDatedAttentionReasonsUseChatIDWithoutReorderingFolders() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for chat: Int64 in [2, 1] {
            try AttentionFixture.chat(index, id: chat)
            try index.apply(AttentionFixture.message(100, chat: chat), now: AttentionFixture.now)
        }
        try index.mode(2, .auto, now: AttentionFixture.now)
        let snapshot = try index.project(now: AttentionFixture.now)
        XCTAssertEqual(snapshot.suggestionRows.map(\.id.chat), [1, 2])
        XCTAssertEqual(snapshot.attentionRows.map(\.id.chat), [1, 2])
    }

    func testHidingDisablesChannelOptInAcrossRestart() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel)
        try index!.mode(1, .auto, now: AttentionFixture.now)
        try AttentionFixture.follow(index!, chat: 1)
        try index!.apply(AttentionFixture.message(100), now: AttentionFixture.now)
        try index!.mode(1, .hidden, now: AttentionFixture.now)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.mode(1, .auto, now: AttentionFixture.now)
        XCTAssertFalse(try XCTUnwrap(restored.get(1, now: AttentionFixture.now)).followEnabled)
        XCTAssertNil(try restored.get(1, now: AttentionFixture.now)?.attention)
    }

    func testChannelOptInAfterRestartWaitsForCurrentHeadAndExcludesOldUnread() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel); try index!.mode(1, .auto)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.follow(1, enabled: true, now: AttentionFixture.now)
        XCTAssertTrue(try restored.get(1, now: AttentionFixture.now)?.followActivating == true)
        XCTAssertTrue(try restored.get(1, now: AttentionFixture.now)?.followEnabled == true)
        let work = try XCTUnwrap(restored.nextAttentionWork(lane: 0, now: AttentionFixture.now))
        XCTAssertEqual(work.method, "getChatHistory")
        var chat = ChatFixture.chat(1, type: "chatTypeSupergroup", message: .object(AttentionFixture.message(200).fields), unread: 20)["chat"]!.object!
        chat["notification_settings"] = AttentionFixture.settings()
        try restored.finishAttentionWork(work, response: .init("messages", ["messages": .array([.object(AttentionFixture.message(200).fields)])]), now: AttentionFixture.now)
        XCTAssertTrue(try restored.get(1, now: AttentionFixture.now)?.followEnabled == true)
        XCTAssertNil(try restored.get(1, now: AttentionFixture.now)?.attention)
        try restored.apply(AttentionFixture.message(201), now: AttentionFixture.now)
        XCTAssertEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.firstMessage, 201)
    }

    func testMutedSenderAndDisableMentionsUseTelegramFallbackRules() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .group, mute: 600)
        try index.apply(AttentionFixture.message(100, unreadMention: true), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1, "An unmuted sender can mention us in a muted group")
        try index.apply(TDLibMessage("updateChatNotificationSettings", ["chat_id": .integer(1), "notification_settings": AttentionFixture.settings(mute: 600, disableMention: true)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0, "Disabling mention overrides uses ordinary chat mute")
        try index.apply(TDLibMessage("updateChatNotificationSettings", ["chat_id": .integer(1), "notification_settings": AttentionFixture.settings(disableMention: true)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1, "disable_mention_notifications is not a blanket suppression")
        try AttentionFixture.chat(index, id: 42, mute: 600)
        try index.apply(TDLibMessage("updateChatNotificationSettings", ["chat_id": .integer(1), "notification_settings": AttentionFixture.settings()]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0, "Mention delivery follows the sender's explicit mute")
    }
    func testDirectReadConfirmationMuteHiddenAndSnooze() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index)
        try index.apply(AttentionFixture.message(100), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1)
        try index.viewedMessages(chat: 1, ids: [100], now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1, "Looking only suppresses banners; TDLib confirms the read")
        try index.snooze(1, undo: false, now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0)
        try index.apply(AttentionFixture.message(101), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1)
        try index.apply(TDLibMessage("updateChatReadOutbox", ["chat_id": .integer(1), "last_read_outbox_message_id": .integer(999)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1)
        try index.apply(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "last_read_inbox_message_id": .integer(101), "unread_count": .integer(0)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0)
        try index.apply(AttentionFixture.message(102), now: AttentionFixture.now)
        try index.apply(TDLibMessage("updateChatNotificationSettings", ["chat_id": .integer(1), "notification_settings": AttentionFixture.settings(mute: 600)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0)
    }

    func testMentionsUseExactFlagsAndTopicSettingsAndBotRepliesAreVerified() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .forum)
        for topic: Int64 in [1, 2] {
            try index.apply(TDLibMessage("updateForumTopic", ["chat_id": .integer(1), "forum_topic_id": .integer(topic), "notification_settings": AttentionFixture.settings()]), now: AttentionFixture.now)
            try index.apply(AttentionFixture.message(100 + topic, unreadMention: true, topic: topic), now: AttentionFixture.now)
        }
        try index.apply(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "last_read_inbox_message_id": .integer(999), "unread_count": .integer(0)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 2)
        try index.apply(TDLibMessage("updateMessageMentionRead", ["chat_id": .integer(1), "message_id": .integer(101)]), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 1)
        index.attentionDestinations = [.init(environment: .test, account: ChatFixture.me, chat: 1, topic: .forum(1)), .init(environment: .test, account: ChatFixture.me, chat: 1, topic: .forum(2))]
        XCTAssertEqual(try index.project(now: AttentionFixture.now).attention.destinations.count, 1)
        try AttentionFixture.chat(index, id: 2, kind: .bot)
        try index.apply(AttentionFixture.message(200, chat: 2), now: AttentionFixture.now)
        try index.apply(AttentionFixture.message(201, chat: 2, unreadMention: true, reply: 150), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index, chat: 2), 0)
        try index.apply(AttentionFixture.message(150, chat: 2, outgoing: true), now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index, chat: 2), 1)
    }

    func testAddressedOverflowSharesOneBudgetAndSurvivesRestart() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for chat: Int64 in 1...30 {
            try AttentionFixture.chat(index!, id: chat)
            try index!.apply(AttentionFixture.message(100 + chat, chat: chat), now: AttentionFixture.now)
        }
        let snapshot = try index!.project(now: AttentionFixture.now)
        XCTAssertEqual(snapshot.lists.first { $0.key == .main }?.capacity, 8); XCTAssertEqual(snapshot.attention.totalCount, 30)
        XCTAssertEqual(snapshot.attentionTotal, 30)
        XCTAssertEqual(try XCTUnwrap(index).listPage(.main, from: 0, revision: snapshot.lists.first { $0.key == .main }!.revision, now: AttentionFixture.now).rows.first?.id.chat, 1)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        XCTAssertEqual(try restored.project(now: AttentionFixture.now).attention.totalCount, 30)
    }

    func testChannelEpisodeAnchorsAndHidingDoNotReplay() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .channel)
        try index.mode(1, .auto); try AttentionFixture.follow(index, chat: 1)
        for id: Int64 in [100, 101] { try index.apply(AttentionFixture.message(id), now: AttentionFixture.now) }
        let before = try XCTUnwrap(index.get(1, now: AttentionFixture.now)?.attention)
        XCTAssertEqual(before.count, 1)
        try index.apply(TDLibMessage("updateDeleteMessages", ["chat_id": .integer(1), "message_ids": .array([.integer(101)]), "is_permanent": .bool(true), "from_cache": .bool(false)]), now: AttentionFixture.now)
        let after = try XCTUnwrap(index.get(1, now: AttentionFixture.now)?.attention)
        XCTAssertEqual(after.identity, before.identity); XCTAssertEqual(after.firstMessage, 100)
        try index.mode(1, .hidden, now: AttentionFixture.now)
        try index.mode(1, .auto)
        XCTAssertNil(try index.get(1, now: AttentionFixture.now)?.attention)
    }

    func testChannelDeletionAndReadKeepIdentityUntilReconciliationProvesEmpty() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel)
        try index!.mode(1, .auto, now: AttentionFixture.now)
        try AttentionFixture.follow(index!, chat: 1)
        for id: Int64 in [100, 101] { try index!.apply(AttentionFixture.message(id), now: AttentionFixture.now) }
        let identity = try XCTUnwrap(index!.get(1, now: AttentionFixture.now)?.attention?.identity)
        try index!.apply(TDLibMessage("updateDeleteMessages", ["chat_id": .integer(1), "message_ids": .array([.integer(101)]), "is_permanent": .bool(true), "from_cache": .bool(false)]), now: AttentionFixture.now)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        XCTAssertEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.identity, identity)
        XCTAssertEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.firstMessage, 100)
        try restored.apply(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "last_read_inbox_message_id": .integer(100), "unread_count": .integer(0)]), now: AttentionFixture.now)
        XCTAssertEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.identity, identity)
        XCTAssertEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.firstMessage, 0, "An incomplete range has no stale navigation anchor")
        let scan = try XCTUnwrap(restored.nextAttentionWork(lane: 0, now: AttentionFixture.now))
        try restored.finishAttentionWork(scan, response: TDLibMessage("messages", ["messages": .array([])]), now: AttentionFixture.now)
        XCTAssertNil(try restored.get(1, now: AttentionFixture.now)?.attention)
        try restored.apply(AttentionFixture.message(102), now: AttentionFixture.now)
        XCTAssertNotEqual(try restored.get(1, now: AttentionFixture.now)?.attention?.identity, identity)
    }
}
