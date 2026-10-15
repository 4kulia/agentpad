import Foundation
import XCTest
@testable import AgentPadTelegram

enum ChatFixture {
    static let me: Int64 = 9007199254740991
    static let now: Int64 = 1_800_000_000
    static func message(date: Int64 = now - 60, content: String = "messageText", sender: Int64 = me,
                        outgoing: Bool = true, sending: TDLibValue = .null, scheduled: TDLibValue = .null, id: Int64 = 1 << 20) -> TDLibValue {
        var fields: [String:TDLibValue] = ["@type": .string("message"),"id": .integer(id),"date": .integer(date),"is_outgoing": .bool(outgoing),
            "sender_id": .typed("messageSenderUser",["user_id": .integer(sender)]),"content": .typed(content)]
        if sending != .null { fields["sending_state"] = sending }; if scheduled != .null { fields["scheduling_state"] = scheduled }
        return .object(fields)
    }
    static func position(_ list: String = "Main", _ order: Int64 = 100, pinned: Bool = false) -> TDLibValue {
        position(list: list == "Archive" ? .archive : .main, order: order, pinned: pinned)
    }
    static func position(list: TelegramListKey, order: Int64 = 100, pinned: Bool = false) -> TDLibValue {
        .typed("chatPosition",["list": list.tdlib,"order": .integer(order),"is_pinned": .bool(pinned)])
    }
    static func chat(_ id: Int64, title: String? = nil, type: String = "chatTypePrivate", message: TDLibValue = .null,
                     positions: [TDLibValue]? = nil, user: Int64? = nil, unread: Int64 = 0, mentions: Int64 = 0) -> TDLibMessage {
        let fields: [String: TDLibValue] = switch type {
        case "chatTypeSupergroup": ["supergroup_id": .integer(id)]
        case "chatTypeBasicGroup": ["basic_group_id": .integer(id)]
        case "chatTypeSecret": ["secret_chat_id": .integer(id), "user_id": .integer(user ?? id)]
        default: ["user_id": .integer(user ?? id)]
        }
        var chat: [String:TDLibValue] = [
            "@type": .string("chat"), "id": .integer(id), "title": .string(title ?? "Chat \(id)"),
            "type": .typed(type, fields),
            "positions": .array(positions ?? [position("Main",Int64.max / 2 - id)]), "unread_count": .integer(unread), "unread_mention_count": .integer(mentions)
        ]
        if message != .null { chat["last_message"] = message }
        return TDLibMessage("updateNewChat",["chat": .object(chat)])
    }
    static func group(_ id: Int64, channel: Bool = false, forum: Bool = false, direct: Bool = false) -> TDLibMessage {
        TDLibMessage("updateSupergroup", ["supergroup": .typed("supergroup", ["id": .integer(id), "is_channel": .bool(channel),
            "is_forum": .bool(forum), "is_direct_messages_group": .bool(direct)])])
    }
}

final class TelegramChatIndexTests: XCTestCase {
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
        XCTAssertEqual(try index.project(now: now).lists.first { $0.key == .main }?.counts.rows, 1)
    }
}
