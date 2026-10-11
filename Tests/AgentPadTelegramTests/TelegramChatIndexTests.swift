import Foundation
import XCTest
@testable import AgentPadTelegram

enum ChatFixture {
    static let me: Int64 = 9007199254740991
    static let now: Int64 = 1_800_000_000
    static func message(date: Int64 = now - 60, content: String = "messageText", sender: Int64 = me,
                        outgoing: Bool = true, sending: TDLibValue = .null, scheduled: TDLibValue = .null, id: Int64 = 1 << 20) -> TDLibValue {
        .object(["@type": .string("message"), "id": .integer(id), "date": .integer(date), "is_outgoing": .bool(outgoing),
                 "sender_id": .object(["@type": .string("messageSenderUser"), "user_id": .integer(sender)]),
                 "sending_state": sending, "scheduling_state": scheduled, "content": .object(["@type": .string(content)])])
    }
    static func position(_ list: String = "Main", _ order: Int64 = 100) -> TDLibValue {
        .object(["@type": .string("chatPosition"), "list": .object(["@type": .string("chatList" + list)]), "order": .integer(order), "is_pinned": .bool(true)])
    }
    static func chat(_ id: Int64, title: String? = nil, type: String = "chatTypePrivate", message: TDLibValue = .null,
                     positions: [TDLibValue] = [position()], user: Int64? = nil, unread: Int64 = 0, mentions: Int64 = 0) -> TDLibMessage {
        let fields: [String: TDLibValue] = switch type {
        case "chatTypeSupergroup": ["supergroup_id": .integer(id)]
        case "chatTypeBasicGroup": ["basic_group_id": .integer(id)]
        case "chatTypeSecret": ["secret_chat_id": .integer(id), "user_id": .integer(user ?? id)]
        default: ["user_id": .integer(user ?? id)]
        }
        return TDLibMessage("updateNewChat", ["chat": .object([
            "@type": .string("chat"), "id": .integer(id), "title": .string(title ?? "Chat \(id)"),
            "type": .typed(type, fields),
            "last_message": message, "positions": .array(positions), "unread_count": .integer(unread), "unread_mention_count": .integer(mentions)
        ])])
    }
    static func group(_ id: Int64, channel: Bool = false, forum: Bool = false, direct: Bool = false) -> TDLibMessage {
        TDLibMessage("updateSupergroup", ["supergroup": .typed("supergroup", ["id": .integer(id), "is_channel": .bool(channel),
            "is_forum": .bool(forum), "is_direct_messages_group": .bool(direct)])])
    }
}

final class TelegramChatIndexTests: XCTestCase {
    func testDefaultBudgetExpansionOrderingHiddenAndPersistentRecency() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for id in 1...30 {
            try index!.apply(ChatFixture.chat(Int64(id), message: ChatFixture.message(date: ChatFixture.now - Int64(id))), now: ChatFixture.now)
        }
        var snapshot = try index!.project(now: ChatFixture.now)
        XCTAssertEqual(snapshot.visibleCount, 7); XCTAssertEqual(snapshot.overflow, 23)
        XCTAssertFalse(snapshot.firstRows.contains(where: \.pinned), "Telegram pins are not local pins")
        for expected in [17, 27, 30] {
            index!.expandedCapacity = snapshot.visibleCount + 10
            snapshot = try index!.project(now: ChatFixture.now)
            XCTAssertEqual(snapshot.visibleCount, expected)
        }
        XCTAssertTrue(snapshot.expanded); XCTAssertEqual(snapshot.overflow, 0)
        index!.expandedCapacity = nil
        try index!.mode(30, .pinned); try index!.mode(29, .pinned); try index!.mode(1, .hidden)
        snapshot = try index!.project(now: ChatFixture.now)
        XCTAssertEqual(snapshot.firstRows.prefix(3).map(\.id.chat), [30, 29, 2])
        XCTAssertEqual(snapshot.visibleCount, 7); XCTAssertEqual(snapshot.foundCount, 29)
        XCTAssertEqual(try index!.localMatches("Chat 1", now: ChatFixture.now).first { $0.id.chat == 1 }?.hidden, true)
        let later = ChatFixture.now + TelegramChatLimits.recentSeconds
        _ = try index!.expire(now: later)
        snapshot = try index!.project(now: later)
        XCTAssertEqual(snapshot.automaticCount, 2)
        index = nil
        let reopened = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        snapshot = try reopened.project(now: later)
        XCTAssertFalse(snapshot.expanded); XCTAssertEqual(snapshot.visibleCount, 2)
        XCTAssertTrue(try XCTUnwrap(reopened.get(1, now: later)).hidden)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("chat-index.sqlite").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testOnlyConfirmedUserOutgoingAndAllEligibleTypes() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        let excluded = [ChatFixture.message(content: "messagePinMessage"), ChatFixture.message(outgoing: false),
                        ChatFixture.message(sending: .object(["@type": .string("messageSendingStatePending")])),
                        ChatFixture.message(scheduled: .object(["@type": .string("messageSchedulingStateSendAtDate")])),
                        ChatFixture.message(content: "messageFutureUnknown"), ChatFixture.message(id: 7),
                        ChatFixture.message(date: now - TelegramChatLimits.recentSeconds)]
        for (offset, message) in excluded.enumerated() { try index.apply(ChatFixture.chat(Int64(offset + 1), message: message), now: now) }
        XCTAssertEqual(try index.project(now: now).automaticCount, 0)
        for (id, type) in [(11, "chatTypePrivate"), (12, "chatTypeBasicGroup"), (13, "chatTypeSupergroup"), (14, "chatTypeSupergroup"), (15, "chatTypeSupergroup"), (16, "chatTypePrivate"), (17, "chatTypePrivate")] {
            if type == "chatTypeSupergroup" { try index.apply(ChatFixture.group(Int64(id), channel: id == 14, forum: id == 15), now: now) }
            if id == 16 { try index.apply(TDLibMessage("updateUser", ["user": .object(["id": .integer(16), "type": .object(["@type": .string("userTypeBot")])])]), now: now) }
            try index.apply(ChatFixture.chat(Int64(id), type: type, message: ChatFixture.message(), user: id == 17 ? ChatFixture.me : nil), now: now)
        }
        let rows = try index.automatic(now: now)
        XCTAssertEqual(Set(rows.map(\.kind)), Set([.person, .group, .supergroup, .channel, .forum, .bot, .savedMessages]))
        try index.apply(ChatFixture.group(20, channel: true), now: now)
        try index.apply(ChatFixture.chat(20, type: "chatTypeSupergroup", message: ChatFixture.message(sender: 100)), now: now)
        XCTAssertFalse(try XCTUnwrap(index.get(20, now: now)).isAutomatic)
        try index.apply(ChatFixture.group(21, direct: true), now: now)
        try index.apply(ChatFixture.chat(21, type: "chatTypeSupergroup", message: ChatFixture.message()), now: now)
        try index.apply(ChatFixture.chat(22, type: "chatTypeSecret", message: ChatFixture.message()), now: now)
        try index.mode(21, .pinned); try index.mode(22, .pinned)
        XCTAssertFalse(try index.page(offset: 0, now: now).contains { [21, 22].contains($0.id.chat) })
    }
    func testPositionsDraftsLastMessagesAndUnreadAreIndependent() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try index.apply(ChatFixture.chat(1, message: ChatFixture.message(), positions: [ChatFixture.position("Main", Int64.max), ChatFixture.position("Archive", Int64.max - 1)]), now: now)
        try index.apply(TDLibMessage("updateChatDraftMessage", ["chat_id": .integer(1), "positions": .array([ChatFixture.position("Archive")])]), now: now)
        var row = try XCTUnwrap(index.get(1, now: now))
        XCTAssertFalse(row.inMain); XCTAssertTrue(row.inArchive)
        try index.apply(TDLibMessage("updateChatPosition", ["chat_id": .integer(1), "position": ChatFixture.position("Archive", 0)]), now: now)
        try index.apply(TDLibMessage("updateChatLastMessage", ["chat_id": .integer(1), "last_message": ChatFixture.message(date: now, outgoing: false), "positions": .array([ChatFixture.position()])]), now: now)
        try index.apply(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "unread_count": .integer(0)]), now: now)
        try index.apply(TDLibMessage("updateChatUnreadMentionCount", ["chat_id": .integer(1), "unread_mention_count": .integer(0)]), now: now)
        row = try XCTUnwrap(index.get(1, now: now))
        XCTAssertTrue(row.inMain); XCTAssertFalse(row.inArchive); XCTAssertEqual(row.unreadCount, 0); XCTAssertEqual(row.unreadMentionCount, 0)
        XCTAssertEqual(row.recentOutgoingDate, now - 60); XCTAssertEqual(row.lastMessageDate, now)
        try index.apply(TDLibMessage("updateChatLastMessage", ["chat_id": .integer(1), "last_message": .null, "positions": .array([])]), now: now)
        XCTAssertEqual(try index.project(now: now).automaticCount, 1, "Deletion does not erase the observed outgoing fact")
    }
    func testLargeDirectoryIsPagedAndInteractionDefersReordering() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for id in 1...1205 { try index.apply(ChatFixture.chat(Int64(id), message: ChatFixture.message(date: now - Int64(id), outgoing: false)), now: now) }
        var snapshot = try index.project(now: now)
        XCTAssertEqual(snapshot.foundCount, 1205); XCTAssertEqual(snapshot.visibleCount, 0)
        index.expandedCapacity = 1300; snapshot = try index.project(now: now)
        XCTAssertEqual(snapshot.visibleCount, 1205); XCTAssertEqual(snapshot.firstRows.count, 50)
        XCTAssertEqual(try index.page(offset: 1200, now: now).count, 5)
        index.orderHeld = true
        try index.apply(TDLibMessage("updateChatLastMessage", ["chat_id": .integer(1205), "last_message": ChatFixture.message(date: now), "positions": .array([])]), now: now)
        XCTAssertEqual(try index.project(now: now).firstRows.first?.id.chat, 1)
        index.orderHeld = false
        XCTAssertEqual(try index.project(now: now).firstRows.first?.id.chat, 1205)
    }
    func testExpandAndShowLessSurviveUpdatesWhilePointerHoldsTheSection() throws {
        for showLess in [false, true] {
            let fixture = try TelegramFixture(), now = ChatFixture.now
            let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
            for id in 1...30 {
                try index.apply(ChatFixture.chat(Int64(id), message: ChatFixture.message(date: now - Int64(id))), now: now)
            }
            index.expandedCapacity = showLess ? 17 : nil
            let before = try index.project(now: now)
            index.orderHeld = true; index.heldVisibleCount = before.visibleCount
            index.expandedCapacity = showLess ? nil : before.visibleCount + 10
            let clicked = try index.project(now: now, force: true)
            XCTAssertEqual(clicked.visibleCount, showLess ? 7 : 17)

            for offset in 1...3 {
                try index.apply(TDLibMessage("updateChatLastMessage", ["chat_id": .integer(30),
                    "last_message": ChatFixture.message(date: now + Int64(offset)), "positions": .array([])]), now: now)
                let updated = try index.project(now: now)
                XCTAssertEqual(updated.visibleCount, clicked.visibleCount)
                XCTAssertEqual(updated.expanded, !showLess)
                XCTAssertEqual(updated.firstRows.map(\.id), clicked.firstRows.map(\.id), "Incoming updates must still defer reordering")
            }
            index.orderHeld = false; index.heldVisibleCount = nil
            let released = try index.project(now: now)
            XCTAssertEqual(released.visibleCount, clicked.visibleCount)
            XCTAssertEqual(released.firstRows.first?.id.chat, 30)
        }
    }
    func testSuccessfulLiveSendIsIdempotentAndSurvivesRestartWithIncomingLastMessage() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try index!.apply(ChatFixture.chat(1, message: ChatFixture.message(outgoing: false)), now: now)
        XCTAssertEqual(try index!.project(now: now).automaticCount, 0)
        var message = try XCTUnwrap(ChatFixture.message().object); message["chat_id"] = .integer(1)
        let success = TDLibMessage("updateMessageSendSucceeded", ["old_message_id": .integer(3), "message": .object(message.fields)])
        for _ in 0..<3 { try index!.apply(success, now: now) }
        try index!.apply(TDLibMessage("updateChatLastMessage", ["chat_id": .integer(1), "last_message": ChatFixture.message(date: now, outgoing: false), "positions": .array([])]), now: now)
        try index!.apply(TDLibMessage("updateMessageContent", ["chat_id": .integer(1), "message_id": .integer(1 << 20), "new_content": .object(["@type": .string("messageText")])]), now: now + 100)
        XCTAssertEqual(try index!.get(1, now: now)?.recentOutgoingDate, now - 60)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        XCTAssertEqual(try restored.project(now: now).automaticCount, 1)
        _ = try restored.expire(now: now + TelegramChatLimits.recentSeconds)
        XCTAssertEqual(try restored.project(now: now + TelegramChatLimits.recentSeconds).automaticCount, 0)
    }
    func testMetadataByteBoundIncludesLongCombiningSequences() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        let title = "e" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertEqual(title.count, 1)
        try index.apply(ChatFixture.chat(1, title: title), now: ChatFixture.now)
        let row = try XCTUnwrap(index.get(1, now: ChatFixture.now))
        XCTAssertLessThanOrEqual(row.title.utf8.count, 1026)
    }
    func testExactMatchSurvivesTheLocalResultLimit() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        for id in 1...60 { try index.apply(ChatFixture.chat(Int64(id), title: "Ada \(id)", message: ChatFixture.message()), now: now) }
        try index.apply(ChatFixture.chat(61, title: "Ada", message: .null), now: now)
        let matches = try index.localMatches("Ada", now: now)
        XCTAssertEqual(matches.count, 50); XCTAssertEqual(matches.first?.id.chat, 61)
    }
    func testColdAccountBindingClassifiesSelfAndUserUpdatesNeverPromoteSecrets() throws {
        let fixture = try TelegramFixture(), now = ChatFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: 0)
        let user = TDLibMessage("updateUser", ["user": .object(FakeTDLibClient.user.fields)])
        try index.apply(user, now: now)
        try index.bind(ChatFixture.me, now: now)
        try index.apply(ChatFixture.chat(1, user: ChatFixture.me), now: now)
        XCTAssertEqual(try index.get(1, now: now)?.kind, .savedMessages)
        try index.apply(ChatFixture.chat(2, type: "chatTypeSecret", message: ChatFixture.message(), user: ChatFixture.me), now: now)
        try index.apply(user, now: now); try index.bind(ChatFixture.me, now: now)
        XCTAssertEqual(try index.get(2, now: now)?.kind, .secret)
        XCTAssertEqual(try index.project(now: now).foundCount, 1)
    }
}
