import Foundation
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class TelegramAttentionProjectionTests: XCTestCase {
    func testSharedProjectionKeepsPriorityOverflowTopicsAndOneSidebarBudget() throws {
        let store = makeTestStore(), ledger = AttentionLedger(), chats = TelegramChatsModel()
        defer { store.terminate() }
        let terminal = try XCTUnwrap(store.active?.activeSession)
        let input = AttentionEvent(source: "terminal", object: terminal.id.uuidString, episode: terminal.attentionEpisode,
            kind: .input, destination: .terminal(terminal.id))
        ledger.upsert(input)
        let root = TelegramChatID(environment: .test, account: 42, chat: 1)
        let first = root.withTopic(.forum(1)), second = root.withTopic(.forum(2))
        let router = TabRouter(); router.stores = { [store] }
        let topicTab = try XCTUnwrap(router.open(.telegram(first), from: store))
        let otherTopic = try XCTUnwrap(router.open(.telegram(second), from: store))
        let forumTab = try XCTUnwrap(router.open(.telegram(root), from: store))
        let summary = TelegramAttentionSummary(destination: first, count: 3, firstMessage: 100, lastDate: 1000, kind: .mention, identity: "forum:1:1")
        var snapshot = TelegramChatSnapshot(); snapshot.account = root.root; snapshot.state = .complete
        snapshot.visibleCount = 7; snapshot.foundCount = 30; snapshot.automaticCount = 30
        snapshot.attention.totalCount = 32; snapshot.attention.chatCount = 30; snapshot.attention.overflowChatCount = 23
        snapshot.attention.destinations = [first: [summary], root: [summary]]
        snapshot.firstRows = (1...7).map { number in
            var row = TelegramChatRow(id: .init(environment: .test, account: 42, chat: Int64(number)), title: "Telegram \(number)", username: "", kind: .person,
                unreadCount: 1, unreadMentionCount: 0, inMain: true, inArchive: false, pinned: true, hidden: false, lastMessageDate: 100, recentOutgoingDate: 0, isAutomatic: true)
            row.attention = .init(destination: row.id, count: 1, firstMessage: 100, lastDate: 100, kind: .direct, identity: "chat:\(number)")
            return row
        }
        chats.receive(snapshot)
        let model = AttentionSidebarModel(ledger: ledger, telegram: chats, storesProvider: { [store] })
        XCTAssertEqual(model.items.filter { if case .telegram = $0.action { true } else { false } }.count, 7)
        XCTAssertEqual(model.projection.telegramPages[0], [], "A pinned addressed chat occurs only in Needs attention")
        XCTAssertEqual(model.tabIndicators[topicTab.id]?.kind, .unread)
        XCTAssertNil(model.tabIndicators[otherTopic.id])
        XCTAssertEqual(model.tabIndicators[forumTab.id]?.kind, .unread)
        XCTAssertEqual(model.windowIndicators[store.windowID]?.kind, .needsInput)
        ledger.markAttentionViewed(input); model.updateProjection()
        XCTAssertEqual(model.windowIndicators[store.windowID]?.kind, .unread)
        XCTAssertEqual(model.windowIndicators[store.windowID]?.reasonIDs.count, 1, "Forum and topic deduplicate the same source reason")
        snapshot.attention.destinations = [:]; snapshot.firstRows = []; chats.receive(snapshot); model.updateProjection()
        XCTAssertNil(model.windowIndicators[store.windowID])
    }

    func testOrdinaryChannelUnreadOnlyProjectsThroughAnOpenBoundTab() throws {
        let store = makeTestStore(), chats = TelegramChatsModel()
        defer { store.terminate() }
        let id = TelegramChatID(environment: .test, account: 42, chat: 99)
        var snapshot = TelegramChatSnapshot(); snapshot.account = id.root; snapshot.state = .complete
        snapshot.attention.channelUnread[id] = 10_000
        chats.receive(snapshot)
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [store] })
        XCTAssertTrue(model.workspaceIndicators.isEmpty); XCTAssertTrue(model.items.isEmpty)
        let router = TabRouter(); router.stores = { [store] }
        let tab = try XCTUnwrap(router.open(.telegram(id), from: store)); model.updateProjection()
        XCTAssertEqual(model.tabIndicators[tab.id]?.kind, .unread)
        XCTAssertEqual(model.projection.telegram.attention.totalCount, 0)
        XCTAssertTrue(model.items.isEmpty)
        snapshot.account = .init(environment: .test, account: 43, chat: 0); chats.receive(snapshot); model.updateProjection()
        XCTAssertTrue(model.tabIndicators.isEmpty)
    }
}
