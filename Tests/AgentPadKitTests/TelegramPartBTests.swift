import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

private actor PartBProvider: TelegramChatProvider {
    var snapshot: TelegramChatSnapshot
    var requested: [(Int,UInt64,TelegramProfileBinding)] = []
    var held: [(Bool,UUID)] = []
    var reads: [(Int64,Set<TelegramMarkReadStep>?)] = []
    var follows: [(Int64,Bool)] = []
    var result = TelegramMarkReadResult()
    var deferred = false
    var pending: CheckedContinuation<TelegramChatPage,Never>?
    var pages: [Int:TelegramChatPage] = [:]
    init(_ snapshot: TelegramChatSnapshot) { self.snapshot = snapshot }
    func holdChatOrder(list: TelegramListKey, held: Bool, owner: UUID, binding: TelegramProfileBinding) { XCTFail("Attention must hold its independent order") }
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> { AsyncStream { $0.yield(snapshot) } }
    func chatPage(list: TelegramListKey, from: Int, revision: UInt64, binding: TelegramProfileBinding) -> TelegramChatPage {
        .init(revision: revision, offset: from, rows: Self.page(from,revision).rows, next: from + 50)
    }
    func holdAttentionOrder(_ value: Bool, owner: UUID, binding: TelegramProfileBinding) { held.append((value,owner)) }
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) {}
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> { AsyncStream { _ in } }
    func resolveChat(_ hit: TelegramSearchHit) -> TelegramChatRow? { hit.row }
    func didOpenChat(_ id: TelegramChatID) {}
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { PartBRows.row(id.chat) }
    func setChatScanPaused(_ reason: String?) {}
    func attentionPage(start: Int, revision: UInt64, binding: TelegramProfileBinding) async -> TelegramChatPage {
        requested.append((start,revision,binding))
        if deferred { return await withCheckedContinuation { pending = $0 } }
        return pages[start] ?? Self.page(start, revision)
    }
    static func page(_ start: Int, _ revision: UInt64) -> TelegramChatPage {
        let rows = (start..<start+50).map { PartBRows.row(Int64($0+1), time: 1000-Int64($0)) }
        return .init(revision: revision, offset: start, rows: rows, next: start < 150 ? start+50 : nil, attentionFrontier: rows.last?.attentionOrderKey, attentionKeys: rows.compactMap(\.attentionOrderKey))
    }
    func markAsRead(_ chat: Int64, retry: Set<TelegramMarkReadStep>?, binding: TelegramProfileBinding) -> TelegramMarkReadResult { reads.append((chat,retry)); return result }
    func setFollow(_ chat: Int64, enabled: Bool, binding: TelegramProfileBinding) { follows.append((chat,enabled)) }
    func setResult(_ value: TelegramMarkReadResult) { result = value }
    func suspend() { deferred = true }
    func waiting() -> Bool { pending != nil }
    func resume(_ page: TelegramChatPage) { pending?.resume(returning: page); pending = nil; deferred = false }
    func readRequests() -> [(Int64,Set<TelegramMarkReadStep>?)] { reads }
    func followRequests() -> [(Int64,Bool)] { follows }
    func holds() -> [(Bool,UUID)] { held }
    func setPage(_ page: TelegramChatPage) { pages[page.offset] = page }
    func pageRequests() -> [Int] { requested.map(\.0) }
    func receiveCostSnapshots(_ count: Int) -> [TelegramChatSnapshot] {
        var value = snapshot
        value.prepareAttention(keys: (0..<count).map { .init(chat: Int64($0+1),tier: 3,rankingTime: 1000-Int64($0)) },
            liveChats: Set((1...count).map(Int64.init)))
        value.attentionTotal = count
        let initial = value
        value.prepareAttention(liveChats: value.attentionLiveChats!.subtracting([Int64(count)])); value.attentionTotal -= 1
        let held = value
        value.attentionRevision += 1; value.prepareAttention()
        return [initial,held,value]
    }
}

private enum PartBRows {
    static func row(_ chat: Int64, time: Int64 = 100, kind: TelegramAttentionKind = .direct) -> TelegramChatRow {
        var row = TelegramChatRow(id: .init(environment: .test, account: 42, chat: chat), title: "Chat \(chat)", username: "", kind: .person,
            unreadCount: 1, unreadMentionCount: 0, inMain: true, inArchive: false, pinned: false, hidden: false, lastMessageDate: time, knownRelevant: true)
        row.attention = .init(destination: row.id, count: 1, firstMessage: 100, lastDate: time, kind: kind, identity: "chat:\(chat)")
        row.attentionOrderKey = .init(chat: chat, tier: kind.tier, rankingTime: time)
        return row
    }
    static func snapshot() -> TelegramChatSnapshot {
        var value = TelegramChatSnapshot(); value.binding = .init(environment: .test, account: 42, connectionID: UUID())
        value.account = .init(environment: .test, account: 42, chat: 0); value.state = .complete; value.attentionRevision = 1
        let page = PartBProvider.page(0,1)
        value.attentionRows = page.rows; value.attentionNext = page.next; value.attentionFrontier = page.attentionFrontier; value.attentionTotal = 200
        value.prepareAttention(keys: (0..<200).map { TelegramAttentionOrderKey(chat: Int64($0+1),tier: 3,rankingTime: 1000-Int64($0)) },liveChats: Set(1...200))
        value.mainRows = Array(page.rows.prefix(8)); value.suggestionRows = Array(page.rows.reversed())
        return value
    }
}

@MainActor final class TelegramPartBTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    func testHeldReadFirstOfSixKeepsShowMoreAndReachesSixthChat() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true,forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousEnhancedUI,forAttribute: enhancedUI) }
        var snapshot = PartBRows.snapshot()
        snapshot.prepareAttention(keys: Array(snapshot.attentionKeys!.prefix(6)),liveChats: Set(1...6))
        snapshot.attentionRows = Array(snapshot.attentionRows.prefix(6))
        snapshot.attentionTotal = 6
        snapshot.attentionNext = nil; snapshot.attentionFrontier = nil
        let provider = PartBProvider(snapshot), chats = TelegramChatsModel(), owner = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        await chats.holdAttention(true,owner: owner)
        let model = AttentionSidebarModel(ledger: AttentionLedger(),telegram: chats,storesProvider: { [] })
        let store = makeTestStore()
        defer { store.terminate() }
        store.attentionExpanded = false; store.chatSidebarPreferences.attentionCollapsed = false
        let host = FoldersUIHost(VStack {
            AttentionSidebarSection(store: store,model: model,telegram: chats)
            Spacer()
        },height: 500)
        defer { host.close() }
        try await host.settle()
        XCTAssertTrue(host.labels().contains("Show 1 more"),"Initial controls: \(host.labels())")
        let frozen = model.items.map(\.id)
        snapshot.attentionRows.removeFirst()
        snapshot.prepareAttention(liveChats: Set(2...6)); snapshot.attentionTotal = 5
        chats.receive(snapshot)
        try await host.settle()
        XCTAssertEqual(model.items.map(\.id),frozen)
        XCTAssertEqual(model.items.first?.telegramPlaceholder,.inactive)
        XCTAssertEqual(AttentionList.visible(model.items,expanded: false).count,5,"Keep five geometry slots")
        XCTAssertTrue(host.press("Show 1 more"),"The inactive first slot must not hide the sixth unread chat: \(host.labels())")
        try await host.settle()
        XCTAssertTrue(store.attentionExpanded)
        XCTAssertTrue(host.labels().contains { $0.contains("Chat 6") },"Show more reaches the unread sixth chat during the hold")
        XCTAssertFalse(host.labels().contains { $0.hasPrefix("Show ") && $0.hasSuffix(" more") })
        let holds = await provider.holds()
        XCTAssertFalse(holds.contains { !$0.0 && $0.1 == owner })
        await chats.holdAttention(false,owner: owner)
    }

    func testAttentionReceiveWorkIsIndependentOfFrozenChatCount() async {
        let provider = PartBProvider(PartBRows.snapshot())
        func costs(_ count: Int) async -> [Int] {
            let snapshots = await provider.receiveCostSnapshots(count)
            let chats = TelegramChatsModel(), owner = UUID()
            chats.receive(snapshots[0])
            let initial = chats.attentionReceiveWorkCount
            chats.attentionViewport([1,2,3,4,5],owner: owner)
            chats.receive(snapshots[1])
            let held = chats.attentionReceiveWorkCount
            chats.receive(snapshots[2])
            let revised = chats.attentionReceiveWorkCount
            XCTAssertEqual(chats.attentionState,snapshots[2].attentionState)
            XCTAssertEqual(chats.attentionState?.order.positions[Int64(count)],count-1)
            XCTAssertTrue(chats.attentionState?.inactive.contains(Int64(count)) == true)
            return [initial,held,revised]
        }
        let small = await costs(200), large = await costs(5000)
        XCTAssertEqual(large,small,"Initial receive, held live marks, and a new revision must all have bounded MainActor work")
        XCTAssertTrue(large.allSatisfy { $0 <= 256 },"Five visible rows and snapshot metadata need no full-order traversal: \(large)")
        print("Attention receive visits (initial, held, new revision): N=200 \(small); N=5000 \(large)")
    }

    func testReadyAttentionStateMustMatchSnapshotBindingAndRevision() {
        var snapshot = PartBRows.snapshot()
        let chats = TelegramChatsModel()
        chats.receive(snapshot)
        let first = chats.attentionState
        snapshot.prepareAttention(liveChats: Set(2...200))
        chats.receive(snapshot)
        XCTAssertEqual(first?.order,chats.attentionState?.order)
        XCTAssertNotEqual(first?.version,chats.attentionState?.version,"Live state changes without changing frozen geometry")
        XCTAssertTrue(chats.attentionState?.inactive.contains(1) == true)
        snapshot.attentionRevision += 1
        chats.receive(snapshot)
        XCTAssertTrue(chats.attentionKeys.isEmpty,"A stale position index cannot be paired with a new revision")
        snapshot.prepareAttention(); chats.receive(snapshot)
        XCTAssertEqual(chats.attentionKeys.count,200)
        snapshot.binding = .init(environment: .test,account: 42,connectionID: UUID())
        chats.receive(snapshot)
        XCTAssertTrue(chats.attentionKeys.isEmpty,"A stale connection's index and live marks cannot cross a rebind")
        snapshot.prepareAttention(); chats.receive(snapshot)
        XCTAssertEqual(chats.attentionKeys.count,200)
        XCTAssertEqual(chats.attentionRevealed,50)
    }

    func testPageReadCorrectionsStayBoundedAndLeaveProviderMarkersImmutable() async throws {
        let snapshot = PartBRows.snapshot(), provider = PartBProvider(snapshot), chats = TelegramChatsModel(), owner = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        await chats.expandAttention(); await chats.expandAttention()
        let page = PartBProvider.page(50,1)
        await provider.setPage(.init(revision: 1,offset: 50,rows: [],next: page.next,
            attentionFrontier: page.attentionFrontier,attentionKeys: page.attentionKeys))
        chats.attentionViewport([60,61,62,63,64],owner: owner)
        try await eventually { chats.attentionInactive.contains(62) }
        XCTAssertLessThanOrEqual(chats.attentionInactive.count,11,"Page corrections cover only the viewport and margin")
        XCTAssertTrue(chats.attentionState?.inactive.isEmpty == true,"Page replies never mutate the provider's shared set")
        XCTAssertEqual(chats.attentionState,snapshot.attentionState)
        let settled = await provider.pageRequests()
        chats.attentionViewport([60,61,62,63,64],owner: owner)
        try await Task.sleep(for: .milliseconds(30))
        let repeated = await provider.pageRequests()
        XCTAssertEqual(repeated,settled,"An empty page must settle without a reload loop")
        chats.attentionViewport([120],owner: owner)
        try await eventually { chats.attentionRows[120] != nil }
        XCTAssertTrue(chats.attentionInactive.isEmpty,"Offscreen corrections must not accumulate across the frozen revision")
    }

    func testAttentionBoundaryPagesStayLoadedWithoutRepeatedRequests() async throws {
        let snapshot = PartBRows.snapshot(), provider = PartBProvider(snapshot), chats = TelegramChatsModel(), owner = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        await chats.expandAttention(); await chats.expandAttention()
        chats.attentionViewport([100,101],owner: owner)
        try await eventually { chats.attentionRows[100] != nil && chats.attentionRows[101] != nil }
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        for _ in 0..<3 {
            XCTAssertNotNil(chats.attentionRows[100]); XCTAssertNotNil(chats.attentionRows[101])
            XCTAssertNil(model.items.first { $0.telegramChat == 100 }?.telegramPlaceholder)
            XCTAssertNil(model.items.first { $0.telegramChat == 101 }?.telegramPlaceholder)
            chats.attentionViewport([100,101],owner: owner)
            try await Task.sleep(for: .milliseconds(10))
            model.updateProjection()
        }
        let requests = await provider.pageRequests()
        XCTAssertEqual(requests,[50,100], "Visible rows must settle instead of repeatedly reloading both pages")
        XCTAssertLessThanOrEqual(chats.attentionRows.count,8,"Only two visible rows and the fixed margin need metadata")
    }

    func testHostedPartiallyReadHeldPageKeepsGeometryAcrossTwoWindows() async throws {
        var snapshot = PartBRows.snapshot()
        snapshot.attentionWindowCounts = [0:50,50:50,100:50,150:50]
        let provider = PartBProvider(snapshot), chats = TelegramChatsModel(), hold = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        await chats.holdAttention(true, owner: hold)
        for _ in 0..<3 { await chats.expandAttention() }
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        let frozenIDs = model.items.map(\.id)
        let first = makeTestStore(), second = makeTestStore()
        defer { first.terminate(); second.terminate() }
        first.attentionExpanded = true; second.attentionExpanded = true
        first.chatSidebarPreferences.attentionCollapsed = false; second.chatSidebarPreferences.attentionCollapsed = false
        let a = FoldersUIHost(VStack {
            AttentionSidebarSection(store: first,model: model,telegram: chats,maximumHeight: 300)
            Spacer()
        },height: 500)
        let b = FoldersUIHost(VStack {
            AttentionSidebarSection(store: second,model: model,telegram: chats,maximumHeight: 300)
            Spacer()
        },height: 500)
        defer { a.close(); b.close() }
        try await a.settle(); try await b.settle()
        let firstScroll = try XCTUnwrap(a.scrolls().first), secondScroll = try XCTUnwrap(b.scrolls().first)
        func scroll(_ view: NSScrollView, _ position: Int) {
            view.contentView.scroll(to: NSPoint(x: 0,y: position * 39))
            view.reflectScrolledClipView(view.contentView)
        }
        scroll(firstScroll,55); scroll(secondScroll,155)
        try await a.settle(); try await b.settle()
        try await eventually { chats.attentionRows[56] != nil && chats.attentionRows[156] != nil }
        let original = PartBProvider.page(50,1)
        await provider.setPage(.init(revision: 1, offset: 50, rows: Array(original.rows.prefix(10)),
            next: original.next, attentionFrontier: original.attentionFrontier, attentionKeys: original.rows.compactMap(\.attentionOrderKey)))
        snapshot.attentionTotal = 160; snapshot.attentionWindowCounts[50] = 10
        snapshot.prepareAttention(liveChats: snapshot.attentionLiveChats!.subtracting(61...100))
        chats.receive(snapshot)
        try await a.settle(); try await b.settle()
        try await eventually { chats.attentionRows[56] != nil && chats.attentionRows[156] != nil }
        XCTAssertEqual(model.items.map(\.id),frozenIDs,"Read state must only mark frozen slots, never remove them")
        let before = await provider.pageRequests().count
        // At this offset the old compacted page shows page 100; eviction then
        // restores fifty slots and puts page 50 back under the same viewport.
        scroll(firstScroll,80)
        try await a.settle(); try await b.settle()
        let atReadSlots = await provider.pageRequests().count
        for _ in 0..<3 { try await a.settle(); try await b.settle() }
        let stillAtReadSlots = await provider.pageRequests().count
        XCTAssertEqual(stillAtReadSlots,atReadSlots,"A fixed offset must not alternate between pages 50 and 100")
        XCTAssertEqual(model.items.map(\.id),frozenIDs)
        XCTAssertEqual(firstScroll.contentView.bounds.origin.y,3120,accuracy: 1)
        scroll(firstScroll,100)
        try await a.settle(); try await b.settle()
        try await eventually { chats.attentionRows[101] != nil && chats.attentionRows[56] == nil }
        let settled = await provider.pageRequests().count
        for _ in 0..<4 { try await a.settle(); try await b.settle() }
        let after = await provider.pageRequests().count
        XCTAssertEqual(model.items.map(\.id),frozenIDs,"Eviction must preserve row count, IDs and sort positions")
        XCTAssertEqual(firstScroll.contentView.bounds.origin.y,3900,accuracy: 1)
        XCTAssertEqual(secondScroll.contentView.bounds.origin.y,6045,accuracy: 1)
        XCTAssertLessThanOrEqual(after - before,4,"Moving from page 50 to 100 must not loop")
        XCTAssertEqual(after,settled,"Unchanged native viewports must stop requesting metadata")
        await chats.holdAttention(false, owner: hold)
    }

    func testManyAttentionOwnersCannotExceedSharedMetadataCeiling() async throws {
        var snapshot = PartBRows.snapshot()
        snapshot.prepareAttention(keys: (0..<2800).map { .init(chat: Int64($0+1),tier: 3,rankingTime: 1000-Int64($0)) },liveChats: Set(1...2800)); snapshot.attentionTotal = 2800
        snapshot.mainList.capacity = 2000
        snapshot.mainList.windows = Dictionary(uniqueKeysWithValues: stride(from: 0,to: 250,by: 50).map { start in
            (start,PartBProvider.page(start,1))
        })
        let provider = PartBProvider(snapshot), chats = TelegramChatsModel()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        while chats.attentionNext != nil { await chats.expandAttention() }
        await chats.setViewport(list: .main,windows: [0,50,100,150,200])
        await chats.customViewport(Set(10_000..<10_076))
        var owners: [UUID] = []
        for index in 0..<24 {
            let start = 250 + index * 100, owner = UUID()
            owners.append(owner)
            chats.attentionViewport(Set((start+38...start+63).map(Int64.init)),owner: owner)
            try await eventually { chats.attentionRows[Int64(start+38)] != nil }
            XCTAssertLessThanOrEqual(chats.retainedMetadataCount,1000,"All visible owners share one hard ceiling")
        }
        try await eventually { chats.retainedMetadataCount == 1000 }
        let requests = await provider.pageRequests()
        try await Task.sleep(for: .milliseconds(100))
        let settled = await provider.pageRequests()
        XCTAssertEqual(settled,requests,"Over-budget visible placeholders must not start an eviction/reload loop")
        XCTAssertEqual(chats.attentionKeys,snapshot.attentionKeys,"Even inadmissible rows retain their geometry")
        for owner in owners { chats.attentionViewport([],owner: owner) }
        XCTAssertTrue(chats.attentionRows.isEmpty)
        let returning = UUID()
        chats.attentionViewport([288],owner: returning)
        try await eventually { chats.attentionRows[288] != nil }
        let refetched = await provider.pageRequests()
        XCTAssertGreaterThan(refetched.count,settled.count,"An evicted row is fetched when it becomes visible again")
        XCTAssertLessThanOrEqual(chats.retainedMetadataCount,1000)
    }

    func testAttentionViewportsShareBudgetWithListsAndReleaseOwnersIndependently() async throws {
        var snapshot = PartBRows.snapshot()
        snapshot.mainList.capacity = 2000
        let provider = PartBProvider(snapshot), chats = TelegramChatsModel(), first = UUID(), second = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        for _ in 0..<3 { await chats.expandAttention() }
        chats.attentionViewport([100,101], owner: first)
        chats.attentionViewport([150,151], owner: second)
        try await eventually { [100,101,150,151].allSatisfy { chats.attentionRows[$0] != nil } }
        await chats.setViewport(list: .main,windows: [0,50])
        await chats.loadPage(list: .main,start: 50)
        XCTAssertLessThanOrEqual(chats.retainedMetadataCount,1000)
        XCTAssertNotNil(chats.listPages[.main]?[0]); XCTAssertNotNil(chats.listPages[.main]?[50])
        chats.receive(snapshot)
        for chat: Int64 in [100,101,150,151] { XCTAssertNil(chats.attentionRows[chat], "Live reasons invalidate synchronously") }
        try await eventually { [100,101,150,151].allSatisfy { chats.attentionRows[$0] != nil } }
        chats.attentionViewport([], owner: first)
        XCTAssertNil(chats.attentionRows[100]); XCTAssertNotNil(chats.attentionRows[150]); XCTAssertNotNil(chats.attentionRows[151])
        chats.attentionViewport([], owner: second)
        XCTAssertTrue(chats.attentionRows.isEmpty)
        XCTAssertEqual(chats.attentionKeys.count,200)
    }

    func testHostedAttentionBoundaryAcrossTwoWindowsSettlesAndReleasesOnlyClosedWindow() async throws {
        let snapshot = PartBRows.snapshot(), provider = PartBProvider(snapshot), chats = TelegramChatsModel()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        for _ in 0..<3 { await chats.expandAttention() }
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        let first = makeTestStore(), second = makeTestStore()
        defer { first.terminate(); second.terminate() }
        first.attentionExpanded = true; second.attentionExpanded = true
        first.chatSidebarPreferences.attentionCollapsed = false; second.chatSidebarPreferences.attentionCollapsed = false
        let a = FoldersUIHost(VStack {
            AttentionSidebarSection(store: first,model: model,telegram: chats,maximumHeight: 300)
            Spacer()
        },height: 500)
        let b = FoldersUIHost(VStack {
            AttentionSidebarSection(store: second,model: model,telegram: chats,maximumHeight: 300)
            Spacer()
        },height: 500)
        defer { a.close(); b.close() }
        try await a.settle(); try await b.settle()
        let firstScroll = try XCTUnwrap(a.scrolls().first), secondScroll = try XCTUnwrap(b.scrolls().first)
        firstScroll.contentView.scroll(to: NSPoint(x: 0,y: 99 * 39 - 80)); firstScroll.reflectScrolledClipView(firstScroll.contentView)
        secondScroll.contentView.scroll(to: NSPoint(x: 0,y: 149 * 39 - 80)); secondScroll.reflectScrolledClipView(secondScroll.contentView)
        try await a.settle(); try await b.settle()
        try await eventually { [100,101,150,151].allSatisfy { chats.attentionRows[$0] != nil } }
        let requests = await provider.pageRequests()
        try await a.settle(); try await b.settle()
        let settledRequests = await provider.pageRequests()
        XCTAssertEqual(settledRequests,requests, "Native viewport rows must not alternate between rows and placeholders")
        for chat: Int64 in [100,101,150,151] {
            let item = try XCTUnwrap(model.items.first { $0.telegramChat == chat })
            XCTAssertNil(item.telegramPlaceholder)
        }
        a.window.contentView = nil
        try await b.settle()
        try await eventually { chats.attentionRows[100] == nil }
        XCTAssertNotNil(chats.attentionRows[150]); XCTAssertNotNil(chats.attentionRows[151])
    }

    func testHeldReadWindowKeepsKeysAfterEvictionAndRevealsNewDM() async throws {
        var snapshot = PartBRows.snapshot()
        let provider = PartBProvider(snapshot), chats = TelegramChatsModel(), owner = UUID()
        chats.attach(provider)
        try await eventually { chats.snapshot.binding == snapshot.binding }
        await chats.holdAttention(true, owner: owner)
        await chats.expandAttention(); await chats.expandAttention()
        chats.attentionViewport([51],owner: owner)
        try await eventually { chats.attentionRows[51] != nil }
        let frozen = chats.attentionKeys
        let original = PartBProvider.page(50,snapshot.attentionRevision)
        await provider.setPage(.init(revision: original.revision, offset: 50, rows: [],
            next: original.next, attentionFrontier: original.attentionFrontier, attentionKeys: original.attentionKeys))
        snapshot.attentionTotal = 150; snapshot.prepareAttention(liveChats: snapshot.attentionLiveChats!.subtracting(51...100))
        chats.receive(snapshot)
        XCTAssertNil(chats.attentionRows[51])
        XCTAssertEqual(chats.attentionKeys, frozen, "Read state must not erase frozen membership")
        chats.attentionViewport([101], owner: owner)
        XCTAssertNil(chats.attentionRows[51], "Exercise the evicted empty window")
        let readProjection = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        XCTAssertEqual(readProjection.items.first { $0.telegramChat == 51 }?.telegramPlaceholder,.inactive)
        XCTAssertEqual(readProjection.items.count,150,"Read slots still occupy their frozen positions")

        var incoming = original.rows[0]
        incoming.attention?.firstMessage = 200; incoming.attention?.lastDate = 2000
        await provider.setPage(.init(revision: original.revision, offset: 50, rows: [incoming],
            next: original.next, attentionFrontier: original.attentionFrontier, attentionKeys: original.attentionKeys))
        snapshot.attentionTotal = 151; snapshot.prepareAttention(liveChats: snapshot.attentionLiveChats!.union([51]))
        chats.receive(snapshot)
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        XCTAssertEqual(model.total,151); XCTAssertEqual(model.projection.telegram.attentionNewCount,0)
        let placeholder = try XCTUnwrap(model.items.first { $0.telegramChat == incoming.id.chat },
            "A renewed DM in a held window must remain reachable without ending the hold")
        XCTAssertEqual(placeholder.telegramPlaceholder,.loading)
        chats.attentionViewport([51],owner: owner)
        try await eventually { chats.attentionRows[51]?.attention?.firstMessage == 200 }
        model.updateProjection()
        let visible = try XCTUnwrap(model.items.first { $0.telegramChat == incoming.id.chat })
        XCTAssertNil(visible.telegramPlaceholder)
        XCTAssertEqual(visible.time,Date(timeIntervalSince1970: Double(try XCTUnwrap(incoming.attentionOrderKey).rankingTime)))
        XCTAssertEqual(chats.attentionKeys,frozen)
        let holds = await provider.holds(); XCTAssertEqual(holds.map(\.0),[true])
        await chats.holdAttention(false, owner: owner)
    }

    func testMergedComparatorFrontierCommonLimitAndCollapsedCriticalItems() {
        let scope = AttentionScope(server: "https://test.example", account: "me", organization: "org", generation: "1")
        let mentions = [AttentionConversation(scope: scope, id: "mention", title: "Mention", count: 1, time: .init(timeIntervalSince1970: 350))]
        let dms = [AttentionConversation(scope: scope, id: "dm", title: "DM", count: 1, time: .init(timeIntervalSince1970: 250))]
        let events: [AttentionEvent] = [.init(source: "test", object: "approval", kind: .decision, destination: .connect), .init(source: "test", object: "input", kind: .input, destination: .connect)]
        let native = AttentionList.items(ledger: events, current: .init(aggregateScope: scope), mentions: mentions, dms: dms)
        let tg = [PartBRows.row(1,time: 400),PartBRows.row(2,time: 300,kind: .mention),PartBRows.row(3,time: 200),PartBRows.row(4,time: 900,kind: .groupMessage),PartBRows.row(5,time: 800,kind: .channelPost)]
        let merged = AttentionList.merged(native, telegram: tg, frontier: nil)
        XCTAssertEqual(Array(merged.dropFirst(2).map(\.title)), ["Chat 1","Mention","Chat 2","DM","Chat 3","Chat 4","Chat 5"])
        XCTAssertEqual(AttentionList.visible(merged, expanded: false).count, 7)
        XCTAssertEqual(AttentionList.visible(merged, expanded: false, collapsed: true).map(\.tier), [0,1])
        XCTAssertEqual(AttentionList.visible(merged, expanded: true, collapsed: true).map(\.tier), [0,1])
        let frontier = TelegramAttentionOrderKey(chat: 2,tier: 3,rankingTime: 300)
        XCTAssertEqual(AttentionList.merged(native, telegram: tg, frontier: frontier).map(\.title).suffix(3), ["Chat 1","Mention","Chat 2"])
        var promoted = tg[4]; promoted.attention?.kind = .reply; promoted.attention?.lastDate = 9999
        XCTAssertEqual(AttentionList.merged([], telegram: [tg[0],promoted], frontier: nil).map(\.title), ["Chat 1","Chat 5"], "Frozen keys win over live reason promotion")
    }

    func testProjectionUsesAttentionPagesKeepsFolderRowsAndCountsUnloadedItems() {
        let chats = TelegramChatsModel(), snapshot = PartBRows.snapshot()
        chats.receive(snapshot)
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        XCTAssertEqual(model.items.count, 50); XCTAssertEqual(model.total, 200)
        XCTAssertEqual(chats.listPages[.main]?[0]?.rows, snapshot.mainRows)
        XCTAssertEqual(model.items.last?.title, "Chat 50")
    }

    func testAttentionPagesRefreshLiveRowsAndRejectStaleProfileAndRevision() async throws {
        let snapshot = PartBRows.snapshot(), chats = TelegramChatsModel(), provider = PartBProvider(PartBRows.snapshot()), owner = UUID()
        chats.attach(provider)
        try await eventually { chats.connected }
        chats.receive(snapshot)
        for _ in 0..<3 { await chats.expandAttention() }
        chats.attentionViewport([155],owner: owner)
        try await eventually { chats.attentionRows[155] != nil }
        let model = AttentionSidebarModel(ledger: AttentionLedger(), telegram: chats, storesProvider: { [] })
        XCTAssertEqual(model.items.count, 200)
        var read = snapshot; read.attentionTotal = 190; read.prepareAttention(liveChats: read.attentionLiveChats!.subtracting(61...70))
        chats.receive(read); model.updateProjection()
        XCTAssertEqual(model.projection.revealedCount,190,"Read rows in evicted windows must not distort the exact remainder")
        await chats.holdAttention(true, owner: owner); await chats.holdAttention(false, owner: owner)
        let holds = await provider.holds(); XCTAssertEqual(holds.map(\.0), [true,false]); XCTAssertEqual(holds.map(\.1), [owner,owner])
        try await eventually { chats.attentionRows[155] != nil }
        await provider.suspend()
        chats.receive(snapshot)
        XCTAssertNil(chats.attentionRows[155], "Do not keep stale read badges while held metadata reloads")
        try await eventually { await provider.waiting() }
        var changed = snapshot; changed.attentionRevision = 2; changed.prepareAttention(); chats.receive(changed)
        await provider.resume(PartBProvider.page(150,1))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(chats.attentionRows[155]); XCTAssertEqual(chats.attentionRevealed,50)
        await provider.suspend()
        await chats.expandAttention()
        chats.attentionViewport([55],owner: owner)
        try await eventually { await provider.waiting() }
        changed.binding = .init(environment: .test, account: 42, connectionID: UUID()); changed.prepareAttention(); chats.receive(changed)
        await provider.resume(PartBProvider.page(50,2))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(chats.attentionRows[55]); XCTAssertEqual(chats.attentionRevealed,50)
    }

    func testMarkReadFailureRetriesOnlyFailedStepsAndFollowMenuState() async throws {
        let snapshot = PartBRows.snapshot(), provider = PartBProvider(PartBRows.snapshot()), chats = TelegramChatsModel()
        chats.attach(provider)
        for _ in 0..<50 where !chats.connected { await Task.yield() }
        chats.receive(snapshot)
        var row = PartBRows.row(1); row.markedUnread = true; row.unreadMentionCount = 1
        var result = TelegramMarkReadResult(); result.failed = [.markedUnread]
        await provider.setResult(result); await chats.markAsRead(row)
        XCTAssertEqual(chats.readNotice?.message, "Could not mark Chat 1 as read")
        XCTAssertEqual(chats.snapshot.mainRows.first?.unreadCount, 1)
        await provider.setResult(.init()); await chats.retryMarkAsRead()
        let requests = await provider.readRequests(); XCTAssertEqual(requests.count,2); XCTAssertNil(requests[0].1); XCTAssertEqual(requests[1].1,[.markedUnread])
        XCTAssertNil(chats.readNotice)
        row.kind = .forum; XCTAssertFalse(row.canMarkAsRead)
        await chats.markAsRead(row); let afterForum = await provider.readRequests(); XCTAssertEqual(afterForum.count,2)
        XCTAssertTrue(row.canFollow); XCTAssertEqual(row.followTitle,"New messages → Needs attention")
        row.followActivating = true; XCTAssertEqual(row.followTitle,"Turning on…")
        row.followActivating = false; await chats.follow(row)
        let follows = await provider.followRequests(); XCTAssertEqual(follows.count,1); XCTAssertEqual(follows[0].0,1); XCTAssertTrue(follows[0].1)
    }

    func testSummaryCaptionUsesStrongestCountAndBoundsOnlyPresentation() {
        var summary = PartBRows.row(1,kind: .mention).attention!
        summary.count = 15; summary.classCount = 2
        XCTAssertEqual(summary.caption,"Mentioned you · 2 · 13 other new")
        summary.kind = .groupMessage; summary.count = 1200; summary.classCount = 1200
        XCTAssertEqual(summary.caption,"New messages · 999+ new"); XCTAssertEqual(summary.count,1200)
        summary.count = 10; summary.classCount = 10; summary.incomplete = true
        XCTAssertEqual(summary.caption,"New messages · 10+ new")
    }

    func testSuggestionsAndSharedRankAndGenericChooserAfterOpening() async throws {
        let chats = TelegramChatsModel(), provider = PartBProvider(PartBRows.snapshot()), store = makeTestStore()
        defer { SidebarFolderActions.shared.request = nil; store.terminate() }
        let router = TabRouter(); router.stores = { [store] }
        chats.attach(provider)
        for _ in 0..<50 where !chats.connected { await Task.yield() }
        var snapshot = PartBRows.snapshot()
        var exact = PartBRows.row(99); exact.title = "Chat"; exact.hidden = true; exact.inArchive = true
        snapshot.suggestionRows = [PartBRows.row(2),exact]
        chats.receive(snapshot)
        let search = TelegramSearchModel(chats: chats); search.search("")
        XCTAssertEqual(search.hits.map(\.row.id.chat),[2,99])
        search.search("Chat"); XCTAssertEqual(search.hits.map(\.row.id.chat),[99,2])
        let opened = await search.open(.init(row: exact), from: store, beside: false, addToFolder: true, router: router)
        XCTAssertTrue(opened); XCTAssertEqual(store.active?.activeSession?.toolRoute, .telegram(exact.id))
        XCTAssertEqual(SidebarFolderActions.shared.request?.item, .telegram(99)); XCTAssertEqual(SidebarFolderActions.shared.request?.binding, snapshot.binding)
        let conversation = TelegramConversationModel(id: exact.id); conversation.addToFolder(chats: chats, windowID: store.windowID)
        XCTAssertEqual(SidebarFolderActions.shared.request?.windowID,store.windowID)
        snapshot.binding = .init(environment: .test,account: 42,connectionID: UUID()); snapshot.prepareAttention(); chats.receive(snapshot)
        XCTAssertNil(SidebarFolderActions.shared.request)
    }
}
