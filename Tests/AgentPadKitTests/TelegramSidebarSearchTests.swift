import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

private actor FakeTelegramChatProvider: TelegramChatProvider {
    var searches: [String: AsyncStream<TelegramSearchSnapshot>.Continuation] = [:]
    var searchRequests: [String] = []
    var snapshot = TelegramChatSnapshot()
    var pages: [Int: [TelegramChatRow]] = [:]
    var deferResolution = false
    var resolution: CheckedContinuation<TelegramChatRow?, Never>?
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> { AsyncStream { $0.yield(snapshot) } }
    func chatPage(offset: Int, revision: UInt64) -> TelegramChatPage { .init(revision: revision, offset: offset, rows: pages[offset] ?? []) }
    func expandChats(showLess: Bool) {}
    func holdChatOrder(_ held: Bool, owner: UUID) {}
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) {}
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> {
        searchRequests.append(query)
        let pair = AsyncStream<TelegramSearchSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        searches[query] = pair.continuation
        return pair.stream
    }
    func resolveChat(_ hit: TelegramSearchHit) async -> TelegramChatRow? {
        if deferResolution { return await withCheckedContinuation { resolution = $0 } }
        return hit.row
    }
    func deferOpening() { deferResolution = true }
    func isResolving() -> Bool { resolution != nil }
    func finishOpening(_ row: TelegramChatRow) { resolution?.resume(returning: row); resolution = nil }
    func didOpenChat(_ id: TelegramChatID) {}
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { snapshot.firstRows.first { $0.id == id } }
    func setChatScanPaused(_ reason: String?) {}
    func send(_ value: TelegramSearchSnapshot) { searches[value.query]?.yield(value) }
    func requested(_ query: String) -> Bool { searches[query] != nil }
    func requestCount(_ query: String) -> Int { searchRequests.filter { $0 == query }.count }
    func configure(_ snapshot: TelegramChatSnapshot, pages: [Int: [TelegramChatRow]] = [:]) { self.snapshot = snapshot; self.pages = pages }
}

@MainActor final class TelegramSidebarSearchTests: XCTestCase {
    private var roots: [URL] = []
    private func row(_ id: Int64, _ title: String, automatic: Bool = true) -> TelegramChatRow {
        .init(id: .init(environment: .test, account: 42, chat: id), title: title, username: "", kind: .person,
              unreadCount: 80, unreadMentionCount: 0, inMain: false, inArchive: true, pinned: false, hidden: false,
              lastMessageDate: 100, recentOutgoingDate: 100, isAutomatic: automatic)
    }
    private func snapshot(_ rows: [TelegramChatRow]) -> TelegramChatSnapshot {
        var value = TelegramChatSnapshot(); value.account = .init(environment: .test, account: 42, chat: 0)
        value.state = .complete; value.revision = 1; value.firstRows = rows; value.automaticRows = rows
        value.foundCount = rows.count; value.automaticCount = rows.count; value.visibleCount = rows.count
        return value
    }
    private func model(_ chats: TelegramChatsModel) -> EverywhereSearchModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-search-ui-\(UUID())")
        roots.append(root)
        return EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in
            XCTFail("Telegram must not use AgentPad server search"); return .init(hits: [], next: nil)
        }), indexing: .init(index: ConversationIndex(directory: root, roots: [:], visibility: { .init(channelIds: []) })),
            catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")), telegram: .init(chats: chats),
            visibility: { .init(channelIds: []) })
    }
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }; roots = []
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<150 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition was not reached")
    }
    func testWorkingSetIsImmediateWithNoTeamOrTranscriptIndexAndLateExactKeepsEnter() async throws {
        let local = row(1, "Ada notes"), exact = row(2, "Ada", automatic: false)
        let chats = TelegramChatsModel(), provider = FakeTelegramChatProvider()
        await provider.configure(snapshot([local])); chats.attach(provider)
        try await eventually { chats.connected }
        let model = model(chats); model.source = .telegram; model.query = "Ada"
        model.update()
        XCTAssertEqual(model.telegram.hits.map(\.row.id), [local.id], "No actor hop is needed for the working set")
        XCTAssertFalse(model.hasTeam); XCTAssertFalse(model.indexing.status.state.enabled)
        let selected = try XCTUnwrap(model.selected)
        try await eventually { await provider.requested("Ada") }
        await provider.send(.init(query: "Ada", hits: [.init(row: exact), .init(row: local)]))
        try await eventually { model.telegram.hits.first?.row.id == exact.id }
        XCTAssertEqual(model.selected, selected)
        var opened: TelegramChatID?
        model.openTelegram = { hit, _, _ in opened = hit.row.id }
        model.activate(); XCTAssertEqual(opened, local.id)
    }
    func testStaleQueryAndMissingSelectionCannotRetargetEnter() async throws {
        let first = row(1, "First"), second = row(2, "Second")
        let chats = TelegramChatsModel(), provider = FakeTelegramChatProvider()
        await provider.configure(snapshot([first, second])); chats.attach(provider)
        try await eventually { chats.connected }
        let model = model(chats); model.source = .telegram; model.query = "First"; model.update()
        try await eventually { await provider.requested("First") }
        model.query = "Second"; model.update()
        try await eventually { await provider.requested("Second") }
        let selected = model.selected
        await provider.send(.init(query: "First", hits: [.init(row: first)]))
        await provider.send(.init(query: "Second", hits: [.init(row: second)]))
        try await eventually { model.telegram.hits.map(\.row.id) == [second.id] }
        XCTAssertEqual(model.selected, selected)
        await provider.send(.init(query: "Second", hits: []))
        try await eventually { model.telegram.hits.isEmpty }
        XCTAssertNil(model.selected)
        await provider.send(.init(query: "Second", hits: [.init(row: first)]))
        try await eventually { !model.telegram.hits.isEmpty }
        XCTAssertNil(model.selected, "A removed target requires a fresh explicit selection")
        var opened = false; model.openTelegram = { _, _, _ in opened = true }
        model.activate(); XCTAssertFalse(opened)
        model.move(1); model.activate(); XCTAssertTrue(opened)
    }
    func testLogoutAndAccountChangeClearResultsWithoutAMountedSearchField() async throws {
        for logout in [true, false] {
            let local = row(1, "Ada"), chats = TelegramChatsModel(), provider = FakeTelegramChatProvider()
            await provider.configure(snapshot([local])); chats.attach(provider)
            try await eventually { chats.connected }
            let model = model(chats), retained = TelegramSearchModel(chats: chats)
            retained.search("Ada"); retained.stop()
            model.source = .telegram; model.query = "Ada"; model.update()
            try await eventually { await provider.requested("Ada") }
            let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                engineFactory: { XCTFail("No terminal"); return TestEngine() })
            defer { store.terminate() }
            let host = NSHostingView(rootView: SearchResultsTab(model: model, state: TabState(route: .search), store: store))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            model.showResults(); host.layoutSubtreeIfNeeded()
            XCTAssertNil(model.fieldFocus.field)
            XCTAssertEqual(model.telegram.hits.map(\.row.id), [local.id])
            XCTAssertEqual(retained.hits.map(\.row.id), [local.id])
            model.move(1); XCTAssertNotNil(model.selected)

            var next = TelegramChatSnapshot()
            if !logout { next.state = .complete; next.account = .init(environment: .test, account: 43, chat: 0) }
            chats.receive(next)
            XCTAssertTrue(model.telegram.hits.isEmpty)
            XCTAssertTrue(retained.hits.isEmpty, "Stopped searches in other windows must also be cleared")
            XCTAssertFalse(model.telegram.value.searching)
            XCTAssertNil(model.selected)

            // Rebinding the same account must not make old callbacks valid.
            chats.receive(snapshot([]))
            await provider.send(.init(query: "Ada", hits: [.init(row: local)]))
            await Task.yield()
            XCTAssertTrue(model.telegram.hits.isEmpty)
            model.update()
            try await eventually { await provider.requestCount("Ada") >= 2 }
            await provider.send(.init(query: "Ada", hits: [.init(row: local)]))
            try await eventually { model.telegram.hits.map(\.row.id) == [local.id] }
        }
    }
    func testViewAllResultsKeepsInFlightSearchAcrossFocusAndFieldDismissal() async throws {
        let local = row(1, "Ada notes"), remote = row(2, "Ada", automatic: false)
        let chats = TelegramChatsModel(), provider = FakeTelegramChatProvider()
        await provider.configure(snapshot([local])); chats.attach(provider)
        try await eventually { chats.connected }
        let model = model(chats); model.source = .telegram; model.query = "Ada"; model.update()
        try await eventually { await provider.requested("Ada") }
        XCTAssertTrue(model.telegram.value.searching)
        var opened = false
        model.openResults = {
            opened = true
            // Opening the tab changes the active pane and may unmount the field.
            model.dismiss(restoreFocus: false)
        }
        model.showResults()
        XCTAssertTrue(opened); XCTAssertFalse(model.suggestions)
        await provider.send(.init(query: "Ada", hits: [.init(row: remote), .init(row: local)]))
        try await eventually { model.telegram.hits.first?.row.id == remote.id }
        XCTAssertFalse(model.telegram.value.searching)
        let requests = await provider.requestCount("Ada")
        XCTAssertEqual(requests, 1, "The results tab continues the original search")
        model.openResults = {}
    }
    func testViewportCacheBoundAndExpansionDoesNotNeedAllRowsInMemory() async throws {
        let provider = FakeTelegramChatProvider(), model = TelegramChatsModel()
        var snapshot = snapshot([row(1, "First")]); snapshot.visibleCount = 2000; snapshot.foundCount = 2000; snapshot.expanded = true
        var pages: [Int: [TelegramChatRow]] = [:]
        for offset in stride(from: 0, to: 2000, by: 50) { pages[offset] = (offset..<offset + 50).map { row(Int64($0), "Chat \($0)") } }
        await provider.configure(snapshot, pages: pages); model.attach(provider)
        try await eventually { model.connected }
        for offset in stride(from: 50, to: 2000, by: 50) { await model.loadPage(offset) }
        XCTAssertLessThanOrEqual(model.pages.values.reduce(0) { $0 + $1.count }, 1000)
        XCTAssertEqual(model.snapshot.visibleCount, 2000)
        XCTAssertNotNil(model.pages[1950]); XCTAssertNil(model.pages[0])
        model.receive(TelegramChatSnapshot())
        XCTAssertFalse(model.connected); XCTAssertEqual(model.pages.values.flatMap { $0 }.count, 0)
    }
    func testPlaceholderUsesAccountIdentityAcrossWindowsAndBesideDoesNotDuplicate() throws {
        let origin = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: { XCTFail("Telegram cannot launch a terminal"); return TestEngine() })
        let detached = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: { XCTFail("Telegram cannot launch a terminal"); return TestEngine() })
        defer { origin.terminate(); detached.terminate() }
        let router = TabRouter(); router.stores = { [origin, detached] }
        var raised: UUID?; router.revealWindow = { raised = $0.windowID }
        let chat = row(9007199254740991, "Large exact ID")
        let first = try XCTUnwrap(TelegramTabs.open(chat, from: detached, router: router))
        let again = TelegramTabs.open(chat, from: origin, beside: true, router: router)
        XCTAssertTrue(first === again); XCTAssertEqual(raised, detached.windowID)
        XCTAssertFalse(first.hasProcess); XCTAssertEqual(first.displayTitle, chat.title)
        XCTAssertEqual(detached.active?.root.allPanes.count, 1)
        let route = ToolRoute.telegram(chat.id)
        XCTAssertEqual(try JSONDecoder().decode(ToolRoute.self, from: JSONEncoder().encode(route)), route)
        XCTAssertNotEqual(route, .telegram(.init(environment: .test, account: 43, chat: chat.id.chat)))
        let second = try XCTUnwrap(TelegramTabs.open(row(7, "Beside"), from: detached, beside: true, router: router))
        XCTAssertFalse(second === first); XCTAssertEqual(detached.active?.root.allPanes.count, 2)
    }
    func testDismissalCancelsTheIntentToOpenALateContactWithoutStealingFocus() async throws {
        let provider = FakeTelegramChatProvider(), chats = TelegramChatsModel(), row = row(7, "Contact")
        await provider.configure(snapshot([])); await provider.deferOpening(); chats.attach(provider)
        try await eventually { chats.connected }
        let model = model(chats), search = model.telegram
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: { XCTFail("No terminal"); return TestEngine() })
        defer { store.terminate() }
        let opening = Task { await search.open(.init(row: row, userID: 7), from: store, beside: false, pin: false) }
        try await eventually { await provider.isResolving() }
        model.dismiss() // Escape or moving to another pane cancels the UI intent.
        await provider.finishOpening(row)
        let didOpen = await opening.value
        XCTAssertFalse(didOpen); XCTAssertTrue(store.allSessions.isEmpty); XCTAssertFalse(search.opening)
    }
}
