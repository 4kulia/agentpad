import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramForumHarness {
    let h = try! TelegramFeedHarness()
    var chat: TDLibMessage { h.chat(type: .typed("chatTypeSupergroup", ["supergroup_id": .integer(303), "is_channel": .bool(false)])) }
    var peer = TDLibMessage("supergroup", ["id": .integer(303), "is_forum": .bool(true), "status": .typed("chatMemberStatusMember")])
    init() {
        h.session.applyChat(chat, to: h.feed); h.feed.peer = peer; h.feed.fullInfo = TDLibMessage("supergroupFullInfo")
        h.session.capabilities(h.feed); h.feed.needsDetails = false
    }
    func topic(_ id: Int64, order: Int64 = 10, closed: Bool = false, hidden: Bool = false, general: Bool = false, owned: Bool = false) -> TDLibMessage {
        TDLibMessage("forumTopic", ["info": .typed("forumTopicInfo", ["chat_id": .integer(h.id.chat), "forum_topic_id": .integer(id),
            "name": .string(general ? "Renamed lobby" : "Topic \(id)"), "icon": .typed("forumTopicIcon", ["color": .integer(0x123456)]),
            "is_general": .bool(general), "is_closed": .bool(closed), "is_hidden": .bool(hidden), "is_outgoing": .bool(owned),
            "creator_id": .typed("messageSenderUser", ["user_id": .integer(owned ? h.id.account : 999)])]),
            "order": .integer(order), "unread_count": .integer(8), "unread_mention_count": .integer(2),
            "last_read_inbox_message_id": .integer(0), "last_read_outbox_message_id": .integer(0),
            "notification_settings": .typed("chatNotificationSettings", ["use_default_mute_for": .bool(false), "mute_for": .integer(60)])])
    }
    @discardableResult func open(_ id: Int64) -> TelegramFeedSession.Feed {
        let destination = h.id.withTopic(.forum(id))
        _ = h.session.subscribe(destination, pane: UUID())
        let feed = h.session.feeds[destination]!
        h.session.applyChat(chat, to: feed); feed.peer = peer; feed.fullInfo = TDLibMessage("supergroupFullInfo")
        h.session.applyTopic(TelegramForumTopic(topic(id), chatMuted: false)!, to: feed)
        feed.needsDetails = false; feed.loaded = true
        return feed
    }
    func message(_ id: Int64, topic: Int64, outgoing: Bool = false) -> TDLibMessage {
        var message = h.message(id, outgoing: outgoing); message["topic_id"] = .typed("messageTopicForum", ["forum_topic_id": .integer(topic)]); return message
    }
    func refresh(_ id: Int64, closed: Bool = false) throws {
        try h.answer("getChat", chat); try h.answer("getSupergroup", peer)
        try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo")); try h.answer("getForumTopic", topic(id, closed: closed))
    }
}

final class TelegramForumTests: XCTestCase {
    func testFakeTDLibEmitsTopicUpdatesBeforeResponse() throws {
        let f = TelegramForumHarness(), client = f.h.client
        let request = TDLibMessage("getForumTopic", ["chat_id": .integer(f.h.id.chat), "forum_topic_id": .integer(7), "@extra": .string("topic")])
        for expected in [["updateForumTopicInfo", "updateForumTopic", "forumTopic"], ["updateForumTopic", "forumTopic"]] {
            client.reply(request, f.topic(7))
            for type in expected {
                let message = try XCTUnwrap(client.receive(timeout: 0))
                XCTAssertEqual(message.type, type)
                XCTAssertEqual(message["@extra"], type == "forumTopic" ? .string("topic") : nil)
                if type == "updateForumTopic" { XCTAssertNil(message["unread_count"]) }
            }
            XCTAssertNil(try client.receive(timeout: 0))
        }
    }

    func testTopicLoadsHistoryAndSendsAfterOwnUpdatesInForumsAndBots() throws {
        for isBot in [false, true] {
            let f = TelegramForumHarness(), h = f.h, destination = h.id.withTopic(.forum(7))
            _ = h.session.subscribe(destination, pane: UUID())
            let feed = try XCTUnwrap(h.session.feeds[destination])
            var peer = isBot ? h.user(type: "userTypeBot") : f.peer
            if isBot { peer["type"] = .typed("userTypeBot", ["has_topics": .bool(true)]) }
            func answerChat() throws {
                try h.answer("getChat", isBot ? h.chat() : f.chat)
                try h.answer(isBot ? "getUser" : "getSupergroup", peer)
                if !isBot { try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo")) }
            }
            h.session.refresh(feed)
            try answerChat()
            XCTAssertNil(feed.snapshot.topicInfo)
            try h.answer("getForumTopic", f.topic(7), beforeResponse: {
                XCTAssertTrue(feed.invalidTopics.contains(7))
                XCTAssertTrue(feed.validating)
            })
            XCTAssertEqual(feed.snapshot.topicInfo?.id, 7)
            XCTAssertTrue(feed.snapshot.capabilities.canRead); XCTAssertTrue(feed.snapshot.capabilities.canSend)
            XCTAssertFalse(feed.validating); XCTAssertFalse(feed.invalidTopics.contains(7))
            h.session.load(feed, latest: true)
            let history = try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array([.object(f.message(20, topic: 7).fields)])]))
            XCTAssertEqual(history["forum_topic_id"], .integer(7)); XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20])

            let draft = TelegramDraft(text: "After the update")
            XCTAssertTrue(h.session.draft(destination, epoch: h.epoch, value: draft))
            h.session.sendDraft(destination, epoch: h.epoch, draft: draft)
            try answerChat(); try h.answer("getForumTopic", f.topic(7))
            let sends = h.client.requests.filter { $0.type == "sendMessage" }
            XCTAssertEqual(sends.count, 1)
            XCTAssertEqual(sends.first?["topic_id"], .typed("messageTopicForum", ["forum_topic_id": .integer(7)]))
            XCTAssertTrue(feed.snapshot.draft.isEmpty); XCTAssertFalse(feed.invalidTopics.contains(7))
            XCTAssertFalse(h.client.requests.contains { $0.type == "getChatHistory" })
        }
    }

    func testTopicRefreshAcceptsOwnUpdateInSelectedTopicAndList() throws {
        for selected in [false, true] {
            let f = TelegramForumHarness(), h = f.h, feed = selected ? f.open(7) : h.feed
            if !selected { h.session.applyTopic(try XCTUnwrap(h.session.decodeTopic(f.topic(7), feed: feed)), to: feed) }
            h.session.invalidateTopic(chat: h.id.chat, topic: 7)
            h.session.refreshInvalidTopic(feed)
            var topic = f.topic(7); topic["unread_count"] = .integer(0); topic["last_read_inbox_message_id"] = .integer(20)
            try h.answer("getForumTopic", topic)
            let value = try XCTUnwrap(selected ? feed.snapshot.topicInfo : feed.snapshot.topics.first)
            XCTAssertEqual(value.unreadCount, 0); XCTAssertEqual(value.inbox, 20)
            XCTAssertFalse(feed.topicRefreshPending); XCTAssertFalse(feed.invalidTopics.contains(7))
        }
    }

    func testTopicRefreshCannotUndoNewerLiveReadState() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
        h.session.invalidateTopic(chat: h.id.chat, topic: 7)
        h.session.refreshInvalidTopic(feed)
        try h.answer("getForumTopic", f.topic(7), beforeResponse: {
            h.update("updateForumTopic", ["chat_id": .integer(h.id.chat), "forum_topic_id": .integer(7),
                "last_read_inbox_message_id": .integer(20), "last_read_outbox_message_id": .integer(30), "unread_mention_count": .integer(0)])
        })
        XCTAssertEqual(feed.snapshot.inbox, 20); XCTAssertEqual(feed.snapshot.outbox, 30)
        XCTAssertEqual(feed.snapshot.topicInfo?.mentionCount, 0)
        XCTAssertTrue(feed.invalidTopics.contains(7)); XCTAssertFalse(feed.topicRefreshPending)
    }

    func testInitialTopicResponseCannotUndoLiveClosureAndRetryLoadsClosedTopic() throws {
        let f = TelegramForumHarness(), h = f.h, destination = h.id.withTopic(.forum(7))
        _ = h.session.subscribe(destination, pane: UUID())
        let feed = try XCTUnwrap(h.session.feeds[destination])
        h.session.refresh(feed)
        try h.answer("getChat", f.chat); try h.answer("getSupergroup", f.peer)
        try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo"))
        try h.answer("getForumTopic", f.topic(7), beforeResponse: {
            h.update("updateForumTopicInfo", ["info": f.topic(7, closed: true)["info"]!])
        })
        XCTAssertNil(feed.snapshot.topicInfo); XCTAssertFalse(feed.snapshot.capabilities.canSend)
        XCTAssertTrue(feed.invalidTopics.contains(7)); XCTAssertFalse(feed.validating)
        h.session.refresh(feed); try f.refresh(7, closed: true)
        XCTAssertEqual(feed.snapshot.topicInfo?.isClosed, true)
        XCTAssertTrue(feed.snapshot.capabilities.canRead); XCTAssertFalse(feed.snapshot.capabilities.canSend)
        XCTAssertFalse(feed.invalidTopics.contains(7))
    }

    func testClosedTopicOwnershipUsesOutgoingFlagRegardlessOfCreatorType() throws {
        for creator in [TDLibValue.typed("messageSenderChat", ["chat_id": .integer(-303)]),
                        .typed("messageSenderUser", ["user_id": .integer(101)]),
                        .typed("messageSenderUser", ["user_id": .integer(999)])] {
            for owned in [true, false] {
                let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
                var topic = f.topic(7, closed: true, owned: owned), info = try XCTUnwrap(topic["info"]?.object)
                info["creator_id"] = creator; topic["info"] = .object(info.fields)
                h.update("updateForumTopicInfo", ["info": topic["info"]!])
                XCTAssertEqual(feed.snapshot.topicInfo?.isOwned, owned)
                XCTAssertEqual(feed.snapshot.capabilities.canSend, owned)
                XCTAssertTrue(feed.snapshot.capabilities.canRead)
                XCTAssertEqual(feed.snapshot.capabilities.sender, "You")
                let draft = TelegramDraft(text: "My closed topic")
                XCTAssertTrue(h.session.draft(feed.snapshot.destination, epoch: h.epoch, value: draft))
                h.session.sendDraft(feed.snapshot.destination, epoch: h.epoch, draft: draft)
                try h.answer("getChat", f.chat); try h.answer("getSupergroup", f.peer)
                try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo")); try h.answer("getForumTopic", topic)
                XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, owned ? 1 : 0)
                XCTAssertEqual(feed.snapshot.draft.isEmpty, owned)
            }
        }
    }

    func testTopicIdentityDecodesEveryPinnedConstructorAndOldChatRoutes() throws {
        let h = try TelegramFeedHarness()
        XCTAssertNotEqual(h.id.withTopic(.forum(1)), h.id.withTopic(.thread(1)))
        XCTAssertNotEqual(h.id, h.id.withTopic(.forum(1)))
        let old = Data("{\"environment\":\"test\",\"account\":101,\"chat\":202}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(TelegramChatID.self, from: old), h.id)
        for (type, field, expected): (String, String, TelegramMessageTopic) in [
            ("messageTopicForum", "forum_topic_id", .forum(7)), ("messageTopicThread", "message_thread_id", .thread(7)),
            ("messageTopicDirectMessages", "direct_messages_chat_topic_id", .directMessages(7)),
            ("messageTopicSavedMessages", "saved_messages_topic_id", .savedMessages(7))] {
            XCTAssertEqual(TelegramMessageTopic.decode(.typed(type, [field: .integer(7)])), expected)
        }
        XCTAssertEqual(TelegramMessageTopic.decode(.object([:])), .unsupported)
        XCTAssertNil(TelegramMessageTopic.forum(-1).forumID)
    }
    func testTopicsPaginateByTripleDeduplicateSortAndNeverReadList() throws {
        let f = TelegramForumHarness(), h = f.h
        h.session.load(h.feed, latest: true)
        let request = try h.answer("getForumTopics", TDLibMessage("forumTopics", ["topics": .array([
            .object(f.topic(9, order: 20).fields), .object(f.topic(7, closed: true, hidden: true, general: true).fields)]),
            "next_offset_date": .integer(80), "next_offset_message_id": .integer(90), "next_offset_forum_topic_id": .integer(9)]))
        XCTAssertEqual(request["limit"], .integer(50)); XCTAssertNil(request["offset_message_thread_id"])
        XCTAssertEqual(h.feed.snapshot.topics.map(\.id), [9, 7])
        XCTAssertTrue(h.feed.snapshot.topics[1].isGeneral); XCTAssertTrue(h.feed.snapshot.topics[1].isHidden)
        XCTAssertEqual(h.feed.snapshot.topics[0].unreadCount, 8); XCTAssertEqual(h.feed.snapshot.topics[0].mentionCount, 2)
        XCTAssertTrue(h.feed.snapshot.topics[0].muted)
        h.session.load(h.feed, latest: false)
        let next = try h.answer("getForumTopics", TDLibMessage("forumTopics", ["topics": .array([.object(f.topic(9).fields), .object(f.topic(11, order: 30).fields)]),
            "next_offset_date": .integer(80), "next_offset_message_id": .integer(90), "next_offset_forum_topic_id": .integer(9)]))
        XCTAssertEqual(next["offset_date"], .integer(80)); XCTAssertEqual(next["offset_message_id"], .integer(90)); XCTAssertEqual(next["offset_forum_topic_id"], .integer(9))
        XCTAssertEqual(h.feed.snapshot.topics.map(\.id), [11, 7, 9]); XCTAssertFalse(h.feed.snapshot.hasOlder)
        XCTAssertFalse(h.client.requests.contains { ["getChatHistory", "viewMessages", "readAllChatMentions"].contains($0.type) })
    }
    func testHistorySendTypingAndReplyStayInExactTopicAndDraftsSurviveRestart() throws {
        let f = TelegramForumHarness(), h = f.h, a = f.open(7), b = f.open(9)
        XCTAssertNil(f.chat["message_sender_id"])
        XCTAssertEqual(a.snapshot.capabilities.sender, "You")
        XCTAssertTrue(a.snapshot.capabilities.canSend)
        XCTAssertTrue(a.snapshot.capabilities.canSendPhotos)
        XCTAssertTrue(a.snapshot.capabilities.canSendDocuments)
        let first = TelegramDraft(text: "Topic seven"), second = TelegramDraft(text: "Topic nine")
        XCTAssertTrue(h.session.draft(a.snapshot.destination, epoch: h.epoch, value: first))
        XCTAssertTrue(h.session.draft(b.snapshot.destination, epoch: h.epoch, value: second))
        h.session.load(a, latest: true)
        let history = try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array([.object(f.message(20, topic: 7).fields), .object(f.message(30, topic: 9).fields)])]))
        XCTAssertEqual(history["forum_topic_id"], .integer(7)); XCTAssertNil(history["only_local"])
        XCTAssertEqual(a.snapshot.messages.map(\.messageID), [20]); XCTAssertTrue(b.snapshot.messages.isEmpty)
        var allowed = true
        h.session.validateReply(30, feed: a) { allowed = $0 }; try h.answer("getMessage", f.message(30, topic: 9))
        XCTAssertFalse(allowed)
        let pane = a.observers.keys.first!
        h.observe(a.snapshot.destination, .init(pane: pane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [])); try h.answer("openChat")
        h.session.composer(a.snapshot.destination, epoch: h.epoch, pane: pane, typing: true)
        XCTAssertEqual(h.client.requests.last { $0.type == "sendChatAction" }?["topic_id"], .typed("messageTopicForum", ["forum_topic_id": .integer(7)]))
        h.session.sendDraft(a.snapshot.destination, epoch: h.epoch, draft: first); try f.refresh(7)
        let send = try XCTUnwrap(h.client.requests.last { $0.type == "sendMessage" })
        XCTAssertEqual(send["topic_id"], .typed("messageTopicForum", ["forum_topic_id": .integer(7)]))
        XCTAssertEqual(b.snapshot.draft, second); XCTAssertTrue(a.snapshot.draft.isEmpty)
        XCTAssertEqual(h.journal.operations.first?.topic, .forum(7))
        let restarted = try TelegramSendJournal(directory: h.fixture.directory, databaseKey: Data(repeating: 7, count: 32), now: h.now)
        XCTAssertEqual(try restarted.draft(chat: h.id.chat, topic: .forum(9)), second)
        XCTAssertEqual(restarted.operations.first?.topic, .forum(7)); XCTAssertTrue(try restarted.draft(chat: h.id.chat).isEmpty)
    }
    func testClosedTopicIsRecheckedBeforeSendAndCannotFallbackToChat() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(7), draft = TelegramDraft(text: "Keep this")
        h.session.draft(feed.snapshot.destination, epoch: h.epoch, value: draft)
        h.session.sendDraft(feed.snapshot.destination, epoch: h.epoch, draft: draft); try f.refresh(7, closed: true)
        XCTAssertFalse(feed.snapshot.capabilities.canSend); XCTAssertTrue(feed.snapshot.capabilities.canRead)
        XCTAssertEqual(feed.snapshot.draft, draft); XCTAssertFalse(h.client.requests.contains { $0.type == "sendMessage" })
        var info = f.topic(7, closed: true, hidden: true, owned: true)["info"]!.object!
        h.update("updateForumTopicInfo", ["info": .object(info.fields)])
        XCTAssertTrue(feed.snapshot.capabilities.canSend) // topic creator exception
        info["creator_id"] = .typed("messageSenderUser", ["user_id": .integer(999)])
        info["is_outgoing"] = .bool(false)
        h.update("updateForumTopicInfo", ["info": .object(info.fields)])
        feed.peer?["status"] = .typed("chatMemberStatusAdministrator", ["rights": .typed("chatAdministratorRights", ["can_manage_topics": .bool(true)])])
        h.session.capabilities(feed); XCTAssertTrue(feed.snapshot.capabilities.canSend)
        feed.peer?["is_forum"] = .bool(false); h.session.capabilities(feed)
        XCTAssertFalse(feed.snapshot.capabilities.canSend); XCTAssertFalse(feed.snapshot.capabilities.canRead)
        XCTAssertEqual(feed.snapshot.draft, draft)
    }
    func testReadAndLiveUpdatesAreTopicScopedWithOneChatVisibilityRegistration() throws {
        let f = TelegramForumHarness(), h = f.h, a = f.open(7), b = f.open(9)
        let pa = a.observers.keys.first!, pb = b.observers.keys.first!
        for feed in [a, b] {
            h.session.load(feed, latest: true)
            try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array([])]))
        }
        h.update("updateNewMessage", ["message": .object(f.message(20, topic: 7).fields)])
        h.update("updateNewMessage", ["message": .object(f.message(30, topic: 9).fields)])
        h.observe(a.snapshot.destination, .init(pane: pa, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [20, 30])); try h.answer("openChat")
        h.observe(b.snapshot.destination, .init(pane: pb, epoch: h.epoch, active: true, shown: true, ordinaryIDs: []))
        h.observe(a.snapshot.destination, .init(pane: pa, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [20, 30]))
        let read = try h.answer("viewMessages")
        XCTAssertEqual(read["message_ids"], .array([.integer(20)])); XCTAssertEqual(read["source"]?.object?.type, "messageSourceForumTopicHistory")
        h.update("updateChatReadInbox", ["chat_id": .integer(h.id.chat), "last_read_inbox_message_id": .integer(100)])
        XCTAssertEqual(a.snapshot.inbox, 0); XCTAssertEqual(b.snapshot.inbox, 0)
        h.update("updateForumTopic", ["chat_id": .integer(h.id.chat), "forum_topic_id": .integer(7), "last_read_inbox_message_id": .integer(20), "unread_mention_count": .integer(0)])
        XCTAssertEqual(a.snapshot.inbox, 20); XCTAssertEqual(b.snapshot.inbox, 0)
        XCTAssertEqual(a.snapshot.topicInfo?.unreadCount, 8) // no invented update.unread_count
        XCTAssertEqual(b.snapshot.topicInfo?.mentionCount, 2)
        h.session.refreshInvalidTopic(a)
        var topic = f.topic(7); topic["unread_count"] = .integer(0); topic["last_read_inbox_message_id"] = .integer(20)
        try h.answer("getForumTopic", topic)
        XCTAssertEqual(a.snapshot.topicInfo?.unreadCount, 0)
        h.session.release(a.snapshot.destination, pane: pa)
        XCTAssertFalse(h.client.requests.contains { $0.type == "closeChat" })
        h.session.release(b.snapshot.destination, pane: pb)
        XCTAssertEqual(h.client.requests.filter { $0.type == "openChat" }.count, 1)
        XCTAssertEqual(h.client.requests.filter { $0.type == "closeChat" }.count, 1)
    }
    func testTopicWindowIsBoundedWhileCursorContinuesAndOversizedPageShrinks() throws {
        let f = TelegramForumHarness(), h = f.h
        h.session.load(h.feed, latest: true)
        try h.answer("getForumTopics", TDLibMessage("error", ["message": .string("page_too_large")]))
        XCTAssertEqual(h.client.requests.last?["limit"], .integer(25))
        try h.answer("getForumTopics", TDLibMessage("forumTopics", ["topics": .array([])]))
        for page in 0..<12 {
            h.session.load(h.feed, latest: page == 0)
            let values: [TDLibValue] = (1...50).map { offset in
                let id = Int64(page * 50 + offset)
                return .object(f.topic(id, order: 1000 - id).fields)
            }
            try h.answer("getForumTopics", TDLibMessage("forumTopics", ["topics": .array(values), "next_offset_date": .integer(1000 - Int64(page)),
                "next_offset_message_id": .integer(Int64(page + 1)), "next_offset_forum_topic_id": .integer(Int64((page + 1) * 50))]))
            XCTAssertLessThanOrEqual(h.feed.snapshot.topics.count, 500)
        }
        XCTAssertEqual(Set(h.feed.snapshot.topics.map(\.id)), Set((101...600).map(Int64.init)))
        XCTAssertTrue(h.feed.snapshot.topicsWindowed); XCTAssertEqual(h.feed.topicCursor.topic, 600)
    }
    func testLateTopicDetailCannotUndoLiveClosureAndForumCommentsStayReadOnly() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(7), draft = TelegramDraft(text: "Preserve me")
        h.session.draft(feed.snapshot.destination, epoch: h.epoch, value: draft)
        h.session.sendDraft(feed.snapshot.destination, epoch: h.epoch, draft: draft)
        try h.answer("getChat", f.chat); try h.answer("getSupergroup", f.peer); try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo"))
        try h.answer("getForumTopic", f.topic(7), beforeResponse: {
            h.update("updateForumTopicInfo", ["info": f.topic(7, closed: true)["info"]!])
        })
        XCTAssertTrue(feed.snapshot.topicInfo?.isClosed == true); XCTAssertFalse(feed.snapshot.capabilities.canSend)
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendMessage" }); XCTAssertEqual(feed.snapshot.draft, draft)
        var comment = f.message(10, topic: 7)
        comment["forward_info"] = .typed("messageForwardInfo", ["origin": .typed("messageOriginChannel"), "source": .typed("forwardSource")])
        var allowed = true
        h.session.validateReply(10, feed: feed) { allowed = $0 }; try h.answer("getMessage", comment)
        XCTAssertFalse(allowed)
    }
    func testInheritedMuteUsesChatAndScopeUpdatesWithoutReadingMessages() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
        feed.chat?["notification_settings"] = .typed("chatNotificationSettings", ["use_default_mute_for": .bool(true)])
        var raw = f.topic(7); raw["notification_settings"] = .typed("chatNotificationSettings", ["use_default_mute_for": .bool(true)])
        h.session.applyTopic(try XCTUnwrap(h.session.decodeTopic(raw, feed: feed)), to: feed)
        XCTAssertFalse(feed.snapshot.topicInfo!.muteKnown)
        h.session.refreshTopicMute(feed)
        try h.answer("getScopeNotificationSettings", TDLibMessage("scopeNotificationSettings", ["mute_for": .integer(3600)]))
        XCTAssertTrue(feed.snapshot.topicInfo!.muted); XCTAssertTrue(feed.snapshot.topicInfo!.muteKnown)
        h.update("updateChatNotificationSettings", ["chat_id": .integer(h.id.chat), "notification_settings": .typed("chatNotificationSettings", ["use_default_mute_for": .bool(false), "mute_for": .integer(0)])])
        XCTAssertFalse(feed.snapshot.topicInfo!.muted)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
    }

    func testOtherTopicTrafficCannotInvalidateSelectedTopicSendOrDuplicateItsOutcome() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(9), draft = TelegramDraft(text: "Exact topic", replyTo: 20)
        h.session.draft(feed.snapshot.destination, epoch: h.epoch, value: draft)
        h.session.sendDraft(feed.snapshot.destination, epoch: h.epoch, draft: draft)
        try h.answer("getChat", f.chat); try h.answer("getSupergroup", f.peer); try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo"))
        h.update("updateForumTopicInfo", ["info": f.topic(7, closed: true)["info"]!])
        try h.answer("getForumTopic", f.topic(9))
        try h.answer("getMessage", f.message(20, topic: 9)); try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
        var pending = f.message(91, topic: 9, outgoing: true)
        pending["sending_state"] = .typed("messageSendingStatePending")
        pending["reply_to"] = .typed("messageReplyToMessage", ["chat_id": .integer(h.id.chat), "message_id": .integer(20)])
        try h.answer("sendMessage", pending)
        var sent = pending; sent["id"] = .integer(100); sent["sending_state"] = .null
        for _ in 0..<2 { h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(sent.fields)]) }
        XCTAssertEqual(h.journal.operations[0].parts[0].state, .sent)
        XCTAssertEqual(feed.snapshot.messages.last?.delivery, .sent)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 1)
    }

}
