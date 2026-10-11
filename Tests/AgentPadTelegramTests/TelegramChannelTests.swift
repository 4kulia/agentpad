import Foundation
import XCTest
@testable import AgentPadTelegram

extension TelegramFeedHarness {
    func channel(status: String = "chatMemberStatusMember") {
        session.applyChat(chat(type: .typed("chatTypeSupergroup", ["supergroup_id": .integer(303), "is_channel": .bool(true)])), to: feed)
        feed.peer = TDLibMessage("supergroup", ["id": .integer(303), "is_channel": .bool(true),
            "status": .typed(status, ["chatMemberStatusCreator", "chatMemberStatusRestricted"].contains(status) ? ["is_member": .bool(true)] : [:])])
        feed.fullInfo = TDLibMessage("supergroupFullInfo")
        session.capabilities(feed)
    }
}

final class TelegramChannelTests: XCTestCase {
    func testSubscriberCreatorAndAdminShareReadOnlyFeed() throws {
        for role in ["chatMemberStatusMember", "chatMemberStatusCreator", "chatMemberStatusAdministrator"] {
            let h = try TelegramFeedHarness(); h.channel(status: role)
            XCTAssertTrue(h.feed.snapshot.capabilities.canRead)
            XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
            XCTAssertFalse(h.feed.snapshot.capabilities.canSendPhotos)
            XCTAssertFalse(h.feed.snapshot.capabilities.canSendDocuments)
            h.session.load(h.feed, latest: true)
            try h.answer("getChatHistory", TDLibMessage("messages", ["messages": .array([.object(h.message(10).fields)])]))
            XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [10])
            let draft = TelegramDraft(text: "Must not post")
            h.session.draft(h.id, epoch: h.epoch, value: draft)
            h.session.sendDraft(h.id, epoch: h.epoch, draft: draft)
            h.session.composer(h.id, epoch: h.epoch, pane: h.pane, typing: true)
            XCTAssertTrue(h.feed.snapshot.draft.isEmpty)
            XCTAssertFalse(h.client.requests.contains { ["sendMessage", "sendChatAction", "joinChat", "leaveChat"].contains($0.type) })
        }
    }
    func testChannelReadRequiresVisibleOrdinaryContentAndServerInboxUpdate() throws {
        let h = try TelegramFeedHarness(); h.channel()
        h.session.merge(h.message(10), into: h.feed)
        h.observe(h.id, .init(pane: h.pane, epoch: h.epoch, active: false, shown: true, ordinaryIDs: [10]))
        try h.answer("openChat")
        h.session.reconcilePresentation(h.feed)
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        h.observe(h.id, .init(pane: h.pane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [10, 999]))
        let read = try h.answer("viewMessages")
        XCTAssertEqual(read["message_ids"], .array([.integer(10)]))
        XCTAssertEqual(read["source"]?.object?.type, "messageSourceChatHistory")
        XCTAssertEqual(read["force_read"], .bool(false))
        XCTAssertEqual(h.feed.snapshot.inbox, 0)
        h.update("updateChatReadInbox", ["chat_id": .integer(202), "last_read_inbox_message_id": .integer(10)])
        XCTAssertEqual(h.feed.snapshot.inbox, 10)
    }
    func testLeavingOrLosingAccessDropsContentAndLateHistory() throws {
        for role in ["chatMemberStatusLeft", "chatMemberStatusBanned"] {
            let h = try TelegramFeedHarness(); h.channel()
            h.session.merge(h.message(10), into: h.feed); h.session.load(h.feed, latest: true)
            h.update("updateSupergroup", ["supergroup": .typed("supergroup", ["id": .integer(303), "is_channel": .bool(true), "status": .typed(role)])])
            try h.answer("getChatHistory", TDLibMessage("messages", ["messages": .array([.object(h.message(11).fields)])]))
            XCTAssertFalse(h.feed.snapshot.capabilities.canRead)
            XCTAssertTrue(h.feed.snapshot.messages.isEmpty)
            XCTAssertFalse(h.client.requests.contains { $0.type == "joinChat" })
        }
    }
    func testInteractionCountersStayUnknownUntilSuppliedAndUpdateInPlace() throws {
        let h = try TelegramFeedHarness(); h.channel(); h.session.merge(h.message(10), into: h.feed)
        XCTAssertNil(h.feed.snapshot.messages.first?.viewCount)
        h.update("updateMessageInteractionInfo", ["chat_id": .integer(202), "message_id": .integer(10),
            "interaction_info": .typed("messageInteractionInfo", ["view_count": .integer(82), "reply_info": .typed("messageReplyInfo", ["reply_count": .integer(3)])])])
        XCTAssertEqual(h.feed.snapshot.messages.first?.viewCount, 82)
        XCTAssertEqual(h.feed.snapshot.messages.first?.replyCount, 3)
        h.feed.peer?["is_direct_messages_group"] = .bool(true); h.session.capabilities(h.feed)
        XCTAssertEqual(h.feed.snapshot.kind, .channelDirect)
        XCTAssertFalse(h.feed.snapshot.capabilities.canRead)
    }
}
