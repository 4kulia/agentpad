import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramSenderNameTests: XCTestCase {
    private func owner(_ h: TelegramFeedHarness) -> TDLibMessage {
        var user = h.user()
        user["id"] = .integer(h.id.account); user["first_name"] = .string("Taylor")
        return user
    }

    func testOwnMessageAuthorIsYouWithIndexedOrCachedUserInEveryChat() throws {
        for cached in [false, true] {
            for kind: TelegramChatKind in [.person, .savedMessages, .bot, .group, .supergroup, .channel] {
                let h = try TelegramFeedHarness(), user = owner(h)
                let index = try TelegramChatIndex(directory: h.fixture.directory, environment: .test, account: h.id.account)
                let update = TDLibMessage("updateUser", ["user": .object(user.fields)])
                TelegramFixtureSchema.check(update)
                try index.apply(update, now: 10000); try index.bind(h.id.account, now: 10000)
                XCTAssertEqual(h.session.senderName(.user(h.id.account)), "You") // no cached identity
                h.session.nameLookup = { try? index.userTitle($0) }
                if cached { h.session.rememberUser(user) }

                let destination = h.session.destination(chat: kind == .savedMessages ? h.id.account : kind == .person || kind == .bot ? 202 : -303)
                _ = h.session.subscribe(destination, pane: UUID())
                let feed = try XCTUnwrap(h.session.feeds[destination])
                var peer = h.user(), chat = h.chat()
                chat["id"] = .integer(destination.chat)
                if kind == .savedMessages {
                    peer = user; chat["type"] = .typed("chatTypePrivate", ["user_id": .integer(h.id.account)])
                    chat["title"] = .string("Saved Messages")
                } else if kind == .bot {
                    peer = h.user(type: "userTypeBot")
                } else if [.group, .supergroup, .channel].contains(kind) {
                    let basic = kind == .group
                    chat["type"] = basic ? .typed("chatTypeBasicGroup", ["basic_group_id": .integer(303)])
                        : .typed("chatTypeSupergroup", ["supergroup_id": .integer(303), "is_channel": .bool(kind == .channel)])
                    peer = TDLibMessage(basic ? "basicGroup" : "supergroup", ["id": .integer(303), "status": .typed("chatMemberStatusMember")])
                    if basic { peer["is_active"] = .bool(true) }
                    else { peer["is_channel"] = .bool(kind == .channel) }
                    feed.fullInfo = basic ? nil : TDLibMessage("supergroupFullInfo")
                }
                TelegramFixtureSchema.check(chat); TelegramFixtureSchema.check(peer)
                h.session.applyChat(chat, to: feed); feed.peer = peer; h.session.capabilities(feed)
                XCTAssertEqual(feed.snapshot.kind, kind)
                var message = h.message(10, outgoing: true); message["chat_id"] = .integer(destination.chat)
                TelegramFixtureSchema.check(message)
                h.session.merge(message, into: feed)
                XCTAssertEqual(feed.snapshot.messages.first?.author, "You", "\(kind), cached: \(cached)")
                if kind == .savedMessages { XCTAssertEqual(feed.snapshot.title, "Saved Messages") }
                if kind != .channel { XCTAssertEqual(feed.snapshot.capabilities.sender, "You") }
                XCTAssertEqual(h.session.senderName(.user(202)), "Casey")
            }
        }
    }

    func testOwnUserUpdateKeepsAuthorAndComposerAsYou() throws {
        let h = try TelegramFeedHarness()
        h.session.nameLookup = { _ in "Saved Messages" }
        h.session.merge(h.message(10, outgoing: true), into: h.feed)
        XCTAssertEqual(h.feed.snapshot.messages.first?.author, "You")
        var chatSender = h.message(11)
        chatSender["sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(h.id.account)])
        h.session.chatNameLookup = { _ in "Channel identity" }
        h.session.merge(chatSender, into: h.feed)
        h.session.merge(h.message(12, reply: 10), into: h.feed)
        h.update("updateUser", ["user": .object(owner(h).fields)])
        h.session.capabilities(h.feed)
        XCTAssertEqual(h.feed.snapshot.messages.map(\.author), ["You", "Channel identity", "Casey"])
        XCTAssertEqual(h.feed.snapshot.capabilities.sender, "You")
        XCTAssertEqual(h.feed.snapshot.messages.last?.replyPreview, "hello")
        XCTAssertEqual(h.session.userName(owner(h)), "You")
    }

    func testIndexPersonNameIsYouWhileSavedChatAndSearchKeepTitle() throws {
        let h = try TelegramFeedHarness()
        let index = try TelegramChatIndex(directory: h.fixture.directory, environment: .test, account: 0)
        let update = TDLibMessage("updateUser", ["user": .object(owner(h).fields)])
        TelegramFixtureSchema.check(update)
        try index.apply(update, now: 10000)
        try index.bind(h.id.account, now: 10000)
        XCTAssertEqual(try index.userTitle(h.id.account), "You")
        XCTAssertEqual(try index.contact(h.id.account, now: 10000)?.row.title, "Saved Messages")
        var chat = h.chat(type: .typed("chatTypePrivate", ["user_id": .integer(h.id.account)]))
        chat["id"] = .integer(h.id.account); chat["title"] = .string("Taylor")
        let newChat = TDLibMessage("updateNewChat", ["chat": .object(chat.fields)])
        TelegramFixtureSchema.check(newChat)
        try index.apply(newChat, now: 10000)
        try index.apply(update, now: 10000)
        XCTAssertEqual(try index.userTitle(h.id.account), "You")
        XCTAssertEqual(try index.get(h.id.account, now: 10000)?.title, "Saved Messages")
        XCTAssertEqual(try index.contact(h.id.account, now: 10000)?.row.title, "Saved Messages")
        XCTAssertEqual(try index.localMatches("Saved Messages", now: 10000).map(\.title), ["Saved Messages"])
    }
}
