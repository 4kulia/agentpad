import Foundation
import GRDB
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class TelegramAttentionProjectionTests: XCTestCase {
    func testUnchangedAttentionPublishReusesExpandedSidebarProjection() async throws {
        let fixture = try SidebarFolderFixture()
        let index = try TelegramChatIndex(directory: fixture.profile, environment: .test, account: fixture.account)
        let now: Int64 = 1_700_000_000, count = 5_000
        func seed() throws {
            try index.flushAttention(now: now)
            try index.db.write { db in
                for id in 1...count {
                    try db.execute(sql: "INSERT INTO chats(id,title,kind,lastDate) VALUES (?,?,'person',?)",
                        arguments: [id, "Chat \(id)", now - Int64(id)])
                    try db.execute(sql: "INSERT INTO tg_reason_messages VALUES (?,1,'',?,'direct',0)",
                        arguments: [id, now - Int64(id)])
                }
                try index.rebuildAttentionSummaries(db)
            }
            index.changed()
        }
        try seed()
        let initial = try index.project(now: now)
        let state = try XCTUnwrap(initial.attentionState)
        let chats = TelegramChatsModel(), owner = UUID()
        chats.receive(initial)
        chats.attentionViewport([1, 2, 3, 4, 5], owner: owner)
        while chats.attentionNext != nil { await chats.expandAttention() }
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        XCTAssertEqual(chats.attentionRevealed, count)
        XCTAssertEqual(model.items.count, count)
        XCTAssertEqual(chats.attentionRows.count, 8, "Only five visible rows and the margin retain metadata")
        let builds = model.projectionBuildCount
        var publishedBuilds = [builds]
        for held in [true, false, true, false] {
            index.hold(.main, held: held, owner: owner)
            let published = try index.project(now: now)
            XCTAssertEqual(published.attentionState?.version, state.version, "An ordinary folder hold leaves attention unchanged")
            chats.receive(published)
            model.updateProjection()
            publishedBuilds.append(model.projectionBuildCount)
            XCTAssertEqual(model.projectionBuildCount, builds, "Republishing unchanged attention must reuse all 5,000 expanded slots")
        }
        print("Unchanged attention projection builds at N=\(count): \(publishedBuilds)")
    }

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
        snapshot.binding = .init(environment: .test,account: 42,connectionID: UUID())
        snapshot.mainList.capacity = 7; snapshot.mainList.counts.rows = 30
        snapshot.attention.totalCount = 32; snapshot.attention.chatCount = 30
        snapshot.attention.destinations = [first: [summary], root: [summary]]
        snapshot.mainRows = (1...7).map { number in
            var row = TelegramChatRow(id: .init(environment: .test, account: 42, chat: Int64(number)), title: "Telegram \(number)", username: "", kind: .person,
                unreadCount: 1, unreadMentionCount: 0, inMain: true, inArchive: false, pinned: true, hidden: false, lastMessageDate: 100, knownRelevant: true)
            row.attention = .init(destination: row.id, count: 1, firstMessage: 100, lastDate: 100, kind: .direct, identity: "chat:\(number)")
            return row
        }
        snapshot.attentionRows = snapshot.mainRows; snapshot.attentionTotal = 30
        snapshot.prepareAttention()
        chats.receive(snapshot)
        let model = AttentionSidebarModel(ledger: ledger, telegram: chats, storesProvider: { [store] })
        XCTAssertEqual(model.items.filter { if case .telegram = $0.action { true } else { false } }.count, 7)
        XCTAssertEqual(chats.listPages[.main]?[0]?.rows, snapshot.mainRows, "Attention never removes a row from its folder")
        XCTAssertEqual(model.tabIndicators[topicTab.id]?.kind, .unread)
        XCTAssertNil(model.tabIndicators[otherTopic.id])
        XCTAssertEqual(model.tabIndicators[forumTab.id]?.kind, .unread)
        XCTAssertEqual(model.windowIndicators[store.windowID]?.kind, .needsInput)
        ledger.markAttentionViewed(input); model.updateProjection()
        XCTAssertEqual(model.windowIndicators[store.windowID]?.kind, .unread)
        XCTAssertEqual(model.windowIndicators[store.windowID]?.reasonIDs.count, 1, "Forum and topic deduplicate the same source reason")
        snapshot.attention.destinations = [:]; snapshot.mainRows = []; chats.receive(snapshot); model.updateProjection()
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
