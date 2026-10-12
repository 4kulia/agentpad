import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramFeedWindowTests: XCTestCase {
    private func chat(_ h: TelegramFeedHarness, last: Int64) {
        var chat = h.chat()
        chat["last_message"] = .object(h.message(last).fields)
        TelegramFixtureSchema.check(chat)
        h.session.applyChat(chat, to: h.feed)
    }
    private func page(_ h: TelegramFeedHarness, _ ids: [Int64]) -> TDLibMessage {
        TDLibMessage("messages", ["messages": .array(ids.reversed().map { .object(h.message($0).fields) })])
    }
    private func page(_ f: TelegramForumHarness, _ ids: [Int64]) -> TDLibMessage {
        TDLibMessage("messages", ["messages": .array(ids.reversed().map { .object(f.message($0, topic: 7).fields) })])
    }
    private func lastMessage(_ h: TelegramFeedHarness, _ id: Int64) {
        h.update("updateChatLastMessage", ["chat_id": .integer(h.id.chat),
            "last_message": .object(h.message(id).fields), "positions": .array([])])
    }

    func testAroundPageAtLatestAppendsIncomingMessagesInEitherUpdateOrder() throws {
        for channel in [false, true] {
            for lastFirst in [false, true] {
                let h = try TelegramFeedHarness()
                chat(h, last: 30)
                if channel { h.channel(); lastMessage(h, 30) }
                h.session.loadAround(h.feed, message: 20)
                let request = try h.answer("getChatHistory", page(h, [20, 30]))
                XCTAssertEqual(request["from_message_id"], .integer(20))
                XCTAssertEqual(request["offset"], .integer(-25))
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                if lastFirst { lastMessage(h, 40) }
                h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30, 40])
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                if !lastFirst { lastMessage(h, 40) }
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30, 40])
                XCTAssertFalse(h.feed.snapshot.hasNewer, "The channel's sponsored footer also requires the latest window")
            }
        }
    }

    func testAroundOlderPageKeepsGapUntilLatestHistoryLoads() throws {
        let h = try TelegramFeedHarness()
        chat(h, last: 100)
        h.session.loadAround(h.feed, message: 20)
        try h.answer("getChatHistory", page(h, [20, 30]))
        XCTAssertTrue(h.feed.snapshot.hasNewer, "A short page does not prove the end of history")
        h.update("updateNewMessage", ["message": .object(h.message(110).fields)])
        lastMessage(h, 110)
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
        XCTAssertTrue(h.feed.snapshot.hasNewer)
        h.session.load(h.feed, latest: true)
        try h.answer("getChatHistory", page(h, [100, 110]))
        XCTAssertFalse(h.feed.snapshot.hasNewer)
        h.update("updateNewMessage", ["message": .object(h.message(120).fields)])
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [100, 110, 120])
        XCTAssertFalse(h.feed.snapshot.hasNewer)
    }

    func testIncomingMessageDuringHistoryRequestKeepsNewerBoundary() throws {
        for latest in [false, true] {
            let h = try TelegramFeedHarness()
            chat(h, last: 30)
            if latest { h.session.load(h.feed, latest: true) }
            else { h.session.loadAround(h.feed, message: 20) }
            h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
            try h.answer("getChatHistory", page(h, [20, 30]))
            XCTAssertTrue(h.feed.snapshot.hasNewer, "The returned page does not include the newer live update")
        }
    }

    func testLatestReloadUsesPageAndMessagesObservedDuringRequest() throws {
        for observed: Int64 in [20, 40, 100, 110] {
            for fromLastMessage in [false, true] {
                let h = try TelegramFeedHarness()
                chat(h, last: 100)
                h.session.loadAround(h.feed, message: 20)
                try h.answer("getChatHistory", page(h, [20, 30]))
                h.session.load(h.feed, latest: true)
                if fromLastMessage { lastMessage(h, observed) }
                else { h.update("updateNewMessage", ["message": .object(h.message(observed).fields)]) }
                try h.answer("getChatHistory", page(h, [20, 30]))
                XCTAssertEqual(h.feed.newestKnown, max(30, observed))
                XCTAssertEqual(h.feed.snapshot.hasNewer, observed > 30)
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])

                h.session.load(h.feed, latest: true)
                try h.answer("getChatHistory", page(h, [20, 30]))
                XCTAssertEqual(h.feed.newestKnown, 30, "Only observations during this request survive the authoritative page")
                XCTAssertFalse(h.feed.snapshot.hasNewer)
            }
        }
    }

    func testStaleLastMessageCannotLowerKnownNewestBeforeLatestReload() throws {
        for fromChat in [false, true] {
            let h = try TelegramFeedHarness()
            chat(h, last: 100)
            h.session.loadAround(h.feed, message: 20)
            try h.answer("getChatHistory", page(h, [20, 30]))
            if fromChat { chat(h, last: 30) } else { lastMessage(h, 30) }
            XCTAssertTrue(h.feed.snapshot.hasNewer)
            h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
            XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
            h.session.load(h.feed, latest: true)
            try h.answer("getChatHistory", page(h, [40, 60, 80]))
            XCTAssertEqual(h.feed.newestKnown, 80, "A latest page replaces observations from before the request")
            h.update("updateNewMessage", ["message": .object(h.message(90).fields)])
            XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [40, 60, 80, 90])
            XCTAssertFalse(h.feed.snapshot.hasNewer)
        }
    }

    func testMissingLastMessageAfterDeletionKeepsOlderWindowGap() throws {
        for channel in [false, true] {
            let h = try TelegramFeedHarness()
            if channel { h.channel() }
            lastMessage(h, 100)
            h.session.loadAround(h.feed, message: 20)
            try h.answer("getChatHistory", page(h, [20, 30]))
            XCTAssertTrue(h.feed.snapshot.hasNewer)
            h.update("updateDeleteMessages", ["chat_id": .integer(h.id.chat), "message_ids": .array([.integer(100)]),
                "is_permanent": .bool(true), "from_cache": .bool(false)])
            h.update("updateChatLastMessage", ["chat_id": .integer(h.id.chat), "positions": .array([])])
            XCTAssertTrue(h.feed.snapshot.hasNewer, "Keep Jump to latest and withhold the channel's sponsored footer")
            lastMessage(h, 90)
            h.update("updateNewMessage", ["message": .object(h.message(110).fields)])
            XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
            XCTAssertTrue(h.feed.snapshot.hasNewer)
            h.session.load(h.feed, latest: true)
            try h.answer("getChatHistory", page(h, [20, 30, 50, 70, 90, 110]))
            XCTAssertFalse(h.feed.snapshot.hasNewer)
            h.update("updateNewMessage", ["message": .object(h.message(120).fields)])
            XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30, 50, 70, 90, 110, 120])
        }
    }

    func testMissingLastMessageDoesNotInvalidateLoadedNewest() throws {
        for latest in [false, true] {
            for missingBeforeRequest in [false, true] {
                let h = try TelegramFeedHarness()
                chat(h, last: 30)
                if missingBeforeRequest {
                    h.update("updateChatLastMessage", ["chat_id": .integer(h.id.chat), "positions": .array([])])
                }
                if latest { h.session.load(h.feed, latest: true) }
                else { h.session.loadAround(h.feed, message: 20) }
                h.update("updateChatLastMessage", ["chat_id": .integer(h.id.chat), "positions": .array([])])
                try h.answer("getChatHistory", page(h, [20, 30]))
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                h.session.applyChat(h.chat(), to: h.feed)
                XCTAssertFalse(h.feed.snapshot.hasNewer, "Missing data cannot change the maximum already observed")
                h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30, 40])
            }
        }
    }

    func testDeletingLoadedNewestResumesLiveAppendsAfterOneLatestReload() throws {
        for channel in [false, true] {
            for remaining: [Int64] in [[20], []] {
                let h = try TelegramFeedHarness()
                if channel { h.channel() }
                lastMessage(h, 30)
                h.session.load(h.feed, latest: true)
                try h.answer("getChatHistory", page(h, [20, 30]))
                h.update("updateDeleteMessages", ["chat_id": .integer(h.id.chat), "message_ids": .array((remaining.isEmpty ? [20, 30] : [30]).map(TDLibValue.integer)),
                    "is_permanent": .bool(true), "from_cache": .bool(false)])
                XCTAssertTrue(h.feed.snapshot.hasNewer, "Deleting the newest row also withholds the sponsored footer")
                if let last = remaining.last { lastMessage(h, last) }
                h.session.load(h.feed, latest: true)
                try h.answer("getChatHistory", page(h, remaining))
                XCTAssertEqual(h.feed.newestKnown, remaining.last ?? 0)
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), remaining + [40])
                XCTAssertFalse(h.feed.snapshot.hasNewer)
            }
        }
    }

    func testScheduledMessagesDoNotAffectHistoryOrNewestBoundary() throws {
        let states: [TDLibValue] = [
            .typed("messageSchedulingStateSendAtDate", ["send_date": .integer(2_000_000_000), "repeat_period": .integer(0)]),
            .typed("messageSchedulingStateSendWhenOnline"),
            .typed("messageSchedulingStateSendWhenVideoProcessed", ["send_date": .integer(2_000_000_000)])
        ]
        for state in states {
            for gap in [false, true] {
                let h = try TelegramFeedHarness()
                if gap { chat(h, last: 100) }
                h.session.loadAround(h.feed, message: 20)
                try h.answer("getChatHistory", page(h, [20, 30]))
                let newest = h.feed.newestKnown
                // Scheduled IDs occupy a separate, much larger range in the pinned TDLib.
                let scheduledID: Int64 = 4_000_000_000_004
                var scheduled = h.message(scheduledID, outgoing: true)
                scheduled["scheduling_state"] = state
                h.update("updateNewMessage", ["message": .object(scheduled.fields)])
                XCTAssertEqual(h.feed.newestKnown, newest)
                XCTAssertEqual(h.feed.snapshot.hasNewer, gap)
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
                h.session.merge(scheduled, into: h.feed)
                h.update("updateMessageSendSucceeded", ["old_message_id": .integer(scheduledID - 8), "message": .object(scheduled.fields)])
                XCTAssertEqual(h.feed.newestKnown, newest)
                XCTAssertEqual(h.feed.snapshot.hasNewer, gap)
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])

                h.session.load(h.feed, latest: true)
                h.update("updateNewMessage", ["message": .object(scheduled.fields)])
                try h.answer("getChatHistory", page(h, [20, 30]))
                XCTAssertEqual(h.feed.newestKnown, 30)
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                h.update("updateDeleteMessages", ["chat_id": .integer(h.id.chat), "message_ids": .array([.integer(scheduledID)]),
                    "is_permanent": .bool(true), "from_cache": .bool(false)])
                // is_from_offline describes an already-sent message, not a scheduled one.
                var sent = h.message(40, outgoing: true)
                sent["scheduling_state"] = .null
                sent["is_from_offline"] = .bool(true)
                h.update("updateMessageSendSucceeded", ["old_message_id": .integer(scheduledID), "message": .object(sent.fields)])
                sent = h.message(50)
                sent["is_from_offline"] = .bool(true)
                h.update("updateNewMessage", ["message": .object(sent.fields)])
                XCTAssertEqual(h.feed.newestKnown, 50)
                XCTAssertFalse(h.feed.snapshot.hasNewer)
                XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30, 40, 50])
            }
        }
    }

    func testSendResponseAndSuccessDoNotAppendAcrossOlderWindowGap() throws {
        let h = try TelegramFeedHarness()
        chat(h, last: 100)
        h.session.loadAround(h.feed, message: 20)
        try h.answer("getChatHistory", page(h, [20, 30]))
        _ = try h.send()
        try h.answer("sendMessage", h.message(109, outgoing: true, state: .typed("messageSendingStatePending")))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
        h.session.load(h.feed, latest: true)
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(109),
            "message": .object(h.message(110, outgoing: true).fields)])
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .sent)
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30])
        try h.answer("getChatHistory", page(h, [90, 100]))
        XCTAssertTrue(h.feed.snapshot.hasNewer, "Send success raises the boundary even when its row is withheld")
        h.session.load(h.feed, latest: true)
        try h.answer("getChatHistory", page(h, [100, 110]))
        XCTAssertFalse(h.feed.snapshot.hasNewer)
    }

    func testLoadingOlderHistoryDoesNotInterruptLiveUpdates() throws {
        let h = try TelegramFeedHarness()
        chat(h, last: 30)
        h.session.load(h.feed, latest: true)
        try h.answer("getChatHistory", page(h, [20, 30]))
        h.session.load(h.feed, latest: false)
        lastMessage(h, 40)
        h.update("updateNewMessage", ["message": .object(h.message(40).fields)])
        try h.answer("getChatHistory", page(h, [10, 20]))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [10, 20, 30, 40])
        XCTAssertFalse(h.feed.snapshot.hasNewer)
    }

    func testSentMessageBeyondTrimmedWindowDoesNotFillHistoryGap() throws {
        let h = try TelegramFeedHarness()
        for id: Int64 in 1...550 { h.session.merge(h.message(id), into: h.feed) }
        h.session.trim(h.feed, keepOlder: true)
        XCTAssertEqual(h.feed.snapshot.messages.last?.messageID, 500)
        XCTAssertTrue(h.feed.snapshot.hasNewer)
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(599),
            "message": .object(h.message(600, outgoing: true).fields)])
        lastMessage(h, 600)
        XCTAssertTrue(h.feed.snapshot.hasNewer)
        h.update("updateNewMessage", ["message": .object(h.message(610).fields)])
        XCTAssertFalse(h.feed.snapshot.messages.contains { $0.messageID == 610 })
        XCTAssertTrue(h.feed.snapshot.hasNewer)
        h.session.loadAround(h.feed, message: 600)
        try h.answer("getChatHistory", page(h, [600, 610]))
        XCTAssertFalse(h.feed.snapshot.hasNewer)
        h.update("updateNewMessage", ["message": .object(h.message(620).fields)])
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [600, 610, 620])
    }

    func testTopicMetadataDuringLatestLoadDoesNotObserveMessages() throws {
        for details in [false, true] {
            for update: String? in [nil, "updateNewMessage", "updateMessageSendSucceeded"] {
                let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
                h.session.load(feed, latest: true)
                try h.answer("getForumTopicHistory", page(f, [20, 30]))
                if details { h.session.finishDetails(feed, completion: nil) }
                else {
                    h.session.invalidateTopic(chat: h.id.chat, topic: 7)
                    h.session.refreshInvalidTopic(feed)
                }
                h.session.load(feed, latest: true)
                var topic = f.topic(7)
                topic["last_message"] = .object(f.message(40, topic: 7).fields)
                topic["last_read_inbox_message_id"] = .integer(20)
                // The harness emits the topic updates before the RPC response, without updateNewMessage.
                try h.answer("getForumTopic", topic)
                XCTAssertFalse(feed.invalidTopics.contains(7))
                XCTAssertEqual(feed.snapshot.inbox, 20, "Accept metadata without observing its last_message")
                XCTAssertEqual(feed.newestKnown, 30)
                XCTAssertEqual(feed.newestDuringLatestLoad, 0)
                XCTAssertFalse(feed.snapshot.hasNewer)
                h.update("updateNewMessage", ["message": .object(f.message(100, topic: 8).fields)])
                if let update {
                    var fields: [String: TDLibValue] = ["message": .object(f.message(40, topic: 7, outgoing: update == "updateMessageSendSucceeded").fields)]
                    if update == "updateMessageSendSucceeded" { fields["old_message_id"] = .integer(39) }
                    h.update(update, fields)
                }
                try h.answer("getForumTopicHistory", page(f, [20, 30]))
                XCTAssertEqual(feed.newestKnown, update == nil ? 30 : 40)
                XCTAssertEqual(feed.snapshot.hasNewer, update != nil, "Only a message observed during the request survives the latest page")
                h.update("updateNewMessage", ["message": .object(f.message(50, topic: 7).fields)])
                XCTAssertEqual(feed.snapshot.messages.map(\.messageID), update == nil ? [20, 30, 50] : [20, 30])
            }
        }
    }

    func testTopicMetadataCannotRestoreDeletedNewestAfterLatestReload() throws {
        for details in [false, true] {
            for infoOnly in [false, true] {
                let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
                var topic = f.topic(7)
                topic["last_message"] = .object(f.message(30, topic: 7).fields)
                h.session.finishDetails(feed, completion: nil)
                try h.answer("getForumTopic", topic)
                h.session.load(feed, latest: true)
                try h.answer("getForumTopicHistory", page(f, [20, 30]))
                h.update("updateDeleteMessages", ["chat_id": .integer(h.id.chat), "message_ids": .array([.integer(30)]),
                    "is_permanent": .bool(true), "from_cache": .bool(false)])
                XCTAssertTrue(feed.snapshot.hasNewer)
                h.session.load(feed, latest: true)
                try h.answer("getForumTopicHistory", page(f, [20]))
                XCTAssertEqual(feed.newestKnown, 20)
                XCTAssertFalse(feed.snapshot.hasNewer)

                if infoOnly {
                    var info = try XCTUnwrap(topic["info"]?.object)
                    info["name"] = .string("Renamed topic")
                    topic["info"] = .object(info.fields)
                    h.update("updateForumTopicInfo", ["info": .object(info.fields)])
                    XCTAssertEqual(feed.snapshot.topicInfo?.name, "Renamed topic")
                } else {
                    h.update("updateForumTopic", ["chat_id": .integer(h.id.chat), "forum_topic_id": .integer(7),
                        "last_read_inbox_message_id": .integer(20), "last_read_outbox_message_id": .integer(20)])
                    XCTAssertEqual(feed.snapshot.inbox, 20)
                }
                XCTAssertEqual(feed.newestKnown, 20, "Cached topic metadata cannot restore deleted message 30")
                XCTAssertFalse(feed.snapshot.hasNewer)
                if details { h.session.finishDetails(feed, completion: nil) }
                else { h.session.refreshInvalidTopic(feed) }
                topic["last_message"] = .object(f.message(20, topic: 7).fields)
                topic["last_read_inbox_message_id"] = .integer(20)
                topic["last_read_outbox_message_id"] = .integer(20)
                try h.answer("getForumTopic", topic)
                XCTAssertFalse(feed.invalidTopics.contains(7))
                XCTAssertEqual(feed.newestKnown, 20)
                XCTAssertFalse(feed.snapshot.hasNewer)
                h.update("updateNewMessage", ["message": .object(f.message(40, topic: 7).fields)])
                XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 40])
                XCTAssertFalse(feed.snapshot.hasNewer)
            }
        }
    }

    func testAroundTopicUsesItsOwnLastMessage() throws {
        let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
        var chat = f.chat
        chat["last_message"] = .object(f.message(100, topic: 8).fields)
        TelegramFixtureSchema.check(chat)
        h.session.applyChat(chat, to: feed)
        var topic = f.topic(7)
        topic["last_message"] = .object(f.message(30, topic: 7).fields)
        TelegramFixtureSchema.check(topic)
        h.session.applyTopic(try XCTUnwrap(h.session.decodeTopic(topic, feed: feed)), to: feed)
        h.session.loadAround(feed, message: 20)
        try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array([
            .object(f.message(30, topic: 7).fields), .object(f.message(20, topic: 7).fields)])]))
        XCTAssertFalse(feed.snapshot.hasNewer)
        h.update("updateNewMessage", ["message": .object(f.message(40, topic: 7).fields)])
        lastMessage(h, 110)
        XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30, 40])
        XCTAssertFalse(feed.snapshot.hasNewer)
    }

    func testTopicMetadataAfterRacingHistoryDoesNotRetreatLastMessage() throws {
        for infoOnly in [false, true] {
            let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
            var topic = f.topic(7)
            topic["last_message"] = .object(f.message(30, topic: 7).fields)
            TelegramFixtureSchema.check(topic)
            h.session.applyTopic(try XCTUnwrap(h.session.decodeTopic(topic, feed: feed)), to: feed)
            h.session.loadAround(feed, message: 20)
            h.update("updateNewMessage", ["message": .object(f.message(40, topic: 7).fields)])
            try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array([
                .object(f.message(30, topic: 7).fields), .object(f.message(20, topic: 7).fields)])]))
            XCTAssertTrue(feed.snapshot.hasNewer)
            if infoOnly {
                var info = try XCTUnwrap(topic["info"]?.object)
                info["name"] = .string("Renamed topic")
                h.update("updateForumTopicInfo", ["info": .object(info.fields)])
                XCTAssertEqual(feed.snapshot.topicInfo?.name, "Renamed topic")
            } else {
                h.update("updateForumTopic", ["chat_id": .integer(h.id.chat), "forum_topic_id": .integer(7),
                    "last_read_inbox_message_id": .integer(20), "last_read_outbox_message_id": .integer(20)])
                XCTAssertEqual(feed.snapshot.inbox, 20)
                XCTAssertEqual(feed.snapshot.outbox, 20)
            }
            XCTAssertTrue(feed.snapshot.hasNewer, "Topic metadata carries no last_message evidence")
            h.update("updateNewMessage", ["message": .object(f.message(50, topic: 7).fields)])
            XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30])
            XCTAssertTrue(feed.snapshot.hasNewer)
            h.session.load(feed, latest: true)
            try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array(
                [50, 40, 30, 20].map { .object(f.message($0, topic: 7).fields) })]))
            XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30, 40, 50])
            XCTAssertFalse(feed.snapshot.hasNewer)
            h.update("updateNewMessage", ["message": .object(f.message(60, topic: 7).fields)])
            XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30, 40, 50, 60])
        }
    }

    func testStaleTopicResponseAfterRacingHistoryCannotLowerKnownNewest() throws {
        for details in [false, true] {
            let f = TelegramForumHarness(), h = f.h, feed = f.open(7)
            var topic = f.topic(7)
            topic["last_message"] = .object(f.message(30, topic: 7).fields)
            h.session.applyTopic(try XCTUnwrap(h.session.decodeTopic(topic, feed: feed)), to: feed)
            if details { h.session.finishDetails(feed, completion: nil) }
            else {
                h.session.invalidateTopic(chat: h.id.chat, topic: 7)
                h.session.refreshInvalidTopic(feed)
            }
            h.session.loadAround(feed, message: 20)
            h.update("updateNewMessage", ["message": .object(f.message(40, topic: 7).fields)])
            try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array(
                [30, 20].map { .object(f.message($0, topic: 7).fields) })]))
            XCTAssertTrue(feed.snapshot.hasNewer)
            topic["last_read_inbox_message_id"] = .integer(20)
            // The harness emits TDLib's matching updateForumTopic before the stale RPC response.
            try h.answer("getForumTopic", topic)
            XCTAssertFalse(feed.invalidTopics.contains(7), "The response must be accepted, not rejected by metadata validation")
            XCTAssertEqual(feed.snapshot.inbox, 20)
            XCTAssertTrue(feed.snapshot.hasNewer)
            h.update("updateNewMessage", ["message": .object(f.message(50, topic: 7).fields)])
            XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30])
            XCTAssertTrue(feed.snapshot.hasNewer)
            h.session.load(feed, latest: true)
            try h.answer("getForumTopicHistory", TDLibMessage("messages", ["messages": .array(
                [50, 40, 30, 20].map { .object(f.message($0, topic: 7).fields) })]))
            XCTAssertFalse(feed.snapshot.hasNewer)
            h.update("updateNewMessage", ["message": .object(f.message(60, topic: 7).fields)])
            XCTAssertEqual(feed.snapshot.messages.map(\.messageID), [20, 30, 40, 50, 60])
        }
    }
}
