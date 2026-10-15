import Foundation
import GRDB
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

final class SidebarFolderFixture: @unchecked Sendable {
    let root: URL
    let profile: URL
    let connection = UUID()
    let account: Int64
    let chat: Int64 = 77123456789123
    let folder: Int64 = 612345
    let name = "FolderPrivacySentinel__X"
    var catalogURL: URL { root.appendingPathComponent("sidebar-folders.json") }
    init(legacy: Bool = false, account: Int64 = 89912398712345) throws {
        self.account = account
        let temporary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/tmp")
        root = temporary.appendingPathComponent(UUID().uuidString)
        profile = root.appendingPathComponent(connection.uuidString)
        try FileManager.default.createDirectory(at: profile,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        var manifest = TelegramProfileManifest(connectionID: connection,environment: .test)
        manifest.schemaVersion = legacy ? 1 : 2
        try TelegramProfileStore.write(JSONEncoder().encode(manifest),to: profile.appendingPathComponent("profile.json"))
        if legacy {
            let url = profile.appendingPathComponent("chat-index.sqlite")
            try TelegramProfileStore.write(Data(),to: url)
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AgentPadTelegramTests/Fixtures/chat-index-v1.sql")
            let db = try DatabaseQueue(path: url.path)
            try db.write { db in
                try db.execute(sql: String(contentsOf: schema,encoding: .utf8))
                for id in 1...205 {
                    try db.execute(sql: "INSERT INTO chats(id,title,kind,pinOrder,mainOrder) VALUES (?,'Legacy','person',?,?)",arguments: [id,id,id])
                    try db.execute(sql: "INSERT INTO tg_state(chat) VALUES (?)",arguments: [id])
                }
            }
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func rollback() throws {
        for (source,destination) in [("chat-index.v1.sqlite","chat-index.sqlite"),("profile.v1.json","profile.json")] {
            try TelegramProfileStore.write(Data(contentsOf: profile.appendingPathComponent(source)),to: profile.appendingPathComponent(destination))
        }
    }
}

actor SidebarFolderProvider: TelegramChatProvider {
    let fixture: SidebarFolderFixture
    let includesSummaries: Bool
    var index: TelegramChatIndex?
    var suspended: CheckedContinuation<Void,Never>?
    var shouldSuspend = false
    var failAdd = false
    var actions: [String] = []
    init(_ fixture: SidebarFolderFixture, summaries: Bool = false) throws {
        self.fixture = fixture; includesSummaries = summaries
        index = try TelegramChatIndex(directory: fixture.profile,environment: .test,account: fixture.account)
    }
    func binding() -> TelegramProfileBinding { index!.binding }
    func close() { index = nil }
    func reopen() throws { index = try TelegramChatIndex(directory: fixture.profile,environment: .test,account: fixture.account) }
    func seed() throws {
        try index!.db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO chats(id,title,kind) VALUES (?,?,'person')",arguments: [fixture.chat,fixture.name])
            try db.execute(sql: "INSERT OR IGNORE INTO tg_folder VALUES (?,?, 'Work',0)",arguments: [fixture.folder,fixture.name])
            try db.execute(sql: "INSERT OR IGNORE INTO tg_slot VALUES (?,1)",arguments: ["folder:\(fixture.folder)"])
        }
        index!.listStates[.folder(fixture.folder)] = .init()
    }
    func pauseNextAdd() { shouldSuspend = true }
    func waiting() -> Bool { suspended != nil }
    func resume() { suspended?.resume(); suspended = nil }
    func fail(_ value: Bool) { failAdd = value }
    func recorded() -> [String] { actions }
    func customMembers(binding: TelegramProfileBinding) async throws -> [UUID:Set<Int64>] { try index!.customMembers(binding: binding) }
    func customSummaries(binding: TelegramProfileBinding) async throws -> [TelegramFolderSummary] {
        guard includesSummaries else { return [] }
        return try index!.customSummaries(binding: binding, now: Int64(Date().timeIntervalSince1970))
    }
    func setCustomMember(folder: UUID,chat: Int64,member: Bool,binding: TelegramProfileBinding) async throws {
        if shouldSuspend { shouldSuspend = false; await withCheckedContinuation { suspended = $0 } }
        try Task.checkCancellation()
        if failAdd { throw TelegramFolderError.unavailable }
        try index!.setCustomMember(folder: folder,chat: chat,member: member,binding: binding); actions.append(member ? "add" : "remove")
    }
    func applyTombstones(_ values: Set<UUID>,binding: TelegramProfileBinding) async throws {
        try index!.applyTombstones(values,binding: binding); if !values.isEmpty { actions.append("delete") }
    }
    func setListVisible(_ list: TelegramListKey,visible: Bool,binding: TelegramProfileBinding) async throws {
        try index!.validate(binding); try index!.setListVisible(list,visible: visible)
        actions.append("visible")
    }
    func setListCollapsed(window: UUID,list: TelegramListKey,collapsed: Bool,binding: TelegramProfileBinding) async throws {
        try index!.setListCollapsed(window: window,list: list,collapsed: collapsed,binding: binding)
        actions.append("collapsed")
    }
    func retainFolderWindows(_ windows: Set<UUID>,binding: TelegramProfileBinding) async throws {
        try index!.retainWindows(windows,binding: binding); actions.append("windows")
    }
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> { AsyncStream { $0.finish() } }
    func setChatMode(_ id: TelegramChatID,mode: TelegramChatMode) {}
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> { AsyncStream { $0.finish() } }
    func resolveChat(_ hit: TelegramSearchHit) -> TelegramChatRow? { nil }
    func didOpenChat(_ id: TelegramChatID) {}
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { nil }
    func setChatScanPaused(_ reason: String?) {}
}

final class FolderWriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func set(_ value: Bool) { lock.withLock { failing = value } }
    func write(_ bytes: Data,_ url: URL) throws {
        if lock.withLock({ failing }) { throw SidebarFolderFailure.storage }
        try SidebarFoldersDisk.write(bytes,to: url)
    }
}

@MainActor final class SidebarFoldersTests: XCTestCase {
    private func success(_ store: SidebarFoldersStore,_ operation: SidebarFoldersStore.Operation,file: StaticString = #filePath,line: UInt = #line) async {
        let origin = await store.current()
        let result = await store.perform(operation, binding: origin.binding); XCTAssertEqual(result,.success,file: file,line: line)
    }
    private func waitForAdd(_ provider: SidebarFolderProvider) async throws {
        for _ in 0..<200 { if await provider.waiting() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Provider add did not suspend")
    }
    private func waitForQueuedOperations(_ count: Int, in store: SidebarFoldersStore) async throws {
        for _ in 0..<200 {
            if await store.queuedOperationCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected exactly \(count) queued operations")
        throw SidebarFolderFailure.timeout
    }
    private func checkActionQueuedBehindProfileSwitch(
        _ action: (UUID, SidebarFolderFixture) -> SidebarFoldersStore.Operation,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let a = try SidebarFolderFixture(), b = try SidebarFolderFixture(account: 89912398712346)
        let providerA = try SidebarFolderProvider(a), providerB = try SidebarFolderProvider(b)
        try await providerA.seed(); try await providerB.seed()
        let bindingA = await providerA.binding(), bindingB = await providerB.binding()
        let store = SidebarFoldersStore(url: a.catalogURL), holding = UUID(), target = UUID()
        await success(store, .load(defaults: [])); await success(store, .attach(providerA, bindingA))
        await success(store, .create(holding, name: "Holding", symbol: "folder"))
        await success(store, .create(target, name: "Target", symbol: "folder"))
        await providerA.pauseNextAdd()
        let hold = Task { await store.perform(.member(holding, .telegram(a.chat), true), binding: bindingA) }
        try await waitForAdd(providerA)
        let attach = Task { await store.perform(.attach(providerB, bindingB), binding: bindingB) }
        try await waitForQueuedOperations(1, in: store)
        // attach(B) is already queued, but readers still see A. Capture exactly
        // that published snapshot as a row/menu action would.
        let origin = await store.current()
        XCTAssertEqual(origin.binding, bindingA)
        let operation = action(target, a)
        let stale = Task { await store.perform(operation, binding: origin.binding) }
        try await waitForQueuedOperations(2, in: store)
        await providerA.resume()
        let held = await hold.value, attached = await attach.value, result = await stale.value
        XCTAssertEqual(held, .success); XCTAssertEqual(attached, .success)
        XCTAssertEqual(result, .failure(.staleBinding), file: file, line: line)
        let membersA = try await providerA.customMembers(binding: bindingA)
        let membersB = try await providerB.customMembers(binding: bindingB)
        XCTAssertEqual(membersA, [holding: [a.chat]])
        XCTAssertTrue(membersB.isEmpty, file: file, line: line)
        let callsB = await providerB.recorded()
        XCTAssertEqual(callsB, [], file: file, line: line)
        let current = await store.current()
        XCTAssertEqual(current.binding, bindingB)
        XCTAssertEqual(current.catalog, origin.catalog, file: file, line: line)
    }
    func testQueuedMemberFromPublishedARejectsAttachBAheadOfIt() async throws {
        try await checkActionQueuedBehindProfileSwitch { .member($0, .telegram($1.chat), true) }
    }
    func testEveryQueuedTelegramOperationRejectsItsStaleSnapshot() async throws {
        try await checkActionQueuedBehindProfileSwitch { .member($0, .telegram($1.chat), false) }
        try await checkActionQueuedBehindProfileSwitch { _, a in .createAndAdd(UUID(), name: "New", symbol: "folder", item: .telegram(a.chat)) }
        try await checkActionQueuedBehindProfileSwitch { id, _ in .delete(id) }
        try await checkActionQueuedBehindProfileSwitch { _, a in .telegramVisible(.folder(a.folder), false) }
        try await checkActionQueuedBehindProfileSwitch { _, a in .telegramCollapsed(UUID(), .folder(a.folder), true) }
        try await checkActionQueuedBehindProfileSwitch { _, _ in .windows([]) }
        try await checkActionQueuedBehindProfileSwitch { _, _ in .recover }
    }
    func testRoundTripDefaultsOrderingAndPermanentDeletion() async throws {
        let fixture = try SidebarFolderFixture(), store = SidebarFoldersStore(url: fixture.catalogURL)
        let scope = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"),accountId: "owner",orgId: "org")
        let team = SidebarEntryIdentity.team(scope,team: "one"), people = SidebarEntryIdentity.people(scope), agents = SidebarEntryIdentity.teamAgents(scope)
        await success(store,.load(defaults: [team,people,"telegram","myAgents",agents]))
        let a = UUID(), b = UUID(), item = SidebarItemReference.agentpad(.myAgent(UUID()))
        await success(store,.create(a,name: "Launch",symbol: "folder"))
        await success(store,.createAndAdd(b,name: "Work",symbol: "briefcase",item: item))
        await success(store,.member(b,item,true)); await success(store,.visible(team,false))
        await success(store,.rename(a,name: "Renamed",symbol: "star"))
        await success(store,.move("telegram",0))
        let first = await store.current()
        XCTAssertEqual(first.catalog.order.first,"telegram"); XCTAssertEqual(first.catalog.custom.first { $0.id == b }?.items.count,1)
        let reopened = SidebarFoldersStore(url: fixture.catalogURL)
        await success(reopened,.load(defaults: []))
        let restored = await reopened.current(); XCTAssertEqual(restored.catalog,first.catalog)
        await success(reopened,.delete(a)); await success(reopened,.delete(a))
        let deleted = await reopened.current(); XCTAssertEqual(deleted.catalog.tombstones,[a])
        let retry = await reopened.perform(.create(a,name: "Again",symbol: "folder"), binding: nil); XCTAssertEqual(retry,.failure(.deleted))
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.catalogURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
    }
    func testRecoveryAfterCorruptionAndWriteFailureRetriesByUUID() async throws {
        let fixture = try SidebarFolderFixture(), provider = try SidebarFolderProvider(fixture), switcher = FolderWriteSwitch()
        try await provider.seed()
        let binding = await provider.binding(), id = UUID()
        try await provider.setCustomMember(folder: id,chat: fixture.chat,member: true,binding: binding)
        let store = SidebarFoldersStore(url: fixture.catalogURL,write: switcher.write)
        await success(store,.load(defaults: [])); switcher.set(true)
        let failed = await store.perform(.attach(provider,binding), binding: binding); XCTAssertEqual(failed,.failure(.storage))
        switcher.set(false); await success(store,.recover); await success(store,.recover)
        var value = await store.current()
        XCTAssertEqual(value.catalog.custom.map(\.id),[id]); XCTAssertEqual(value.catalog.custom[0].name,"Recovered folder")
        XCTAssertEqual(value.catalog.order.prefix(2),[SidebarEntryIdentity.custom(id),"telegram"])
        await success(store,.viewport([id: 0..<1]))
        let row = TelegramChatRow(id: .init(environment: binding.environment,account: binding.account,chat: fixture.chat),
            title: fixture.name,username: "",kind: .person,unreadCount: 0,unreadMentionCount: 0,inMain: true,inArchive: false,
            pinned: false,hidden: false,lastMessageDate: 0,knownRelevant: false)
        await store.updateTelegramRows([row],binding: .init(environment: binding.environment,account: binding.account,connectionID: UUID()))
        let stale = await store.current(); XCTAssertEqual(stale.rows[id]?.first?.available,false)
        await store.updateTelegramRows([row],binding: binding)
        let current = await store.current(); XCTAssertEqual(current.rows[id]?.first?.title,fixture.name); XCTAssertEqual(current.binding,binding)
        try Data("broken catalog".utf8).write(to: fixture.catalogURL)
        await success(store,.load(defaults: [])); value = await store.current()
        XCTAssertEqual(value.catalog.custom.map(\.id),[id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix("sidebar-folders.corrupt-") })
    }
    func testSuspendedAddBlocksDeleteAndTenSecondTimeoutReleasesFIFO() async throws {
        for timeout in [false,true] {
            let fixture = try SidebarFolderFixture(), provider = try SidebarFolderProvider(fixture), store = SidebarFoldersStore(url: fixture.catalogURL)
            try await provider.seed(); let binding = await provider.binding(), id = UUID()
            await success(store,.load(defaults: [])); await success(store,.attach(provider,binding))
            await success(store,.create(id,name: "Queue",symbol: "folder")); await provider.pauseNextAdd()
            let start = ContinuousClock.now
            let add = Task { await store.perform(.member(id,.telegram(fixture.chat),true), binding: binding) }
            try await waitForAdd(provider)
            let deletion = Task { await store.perform(.delete(id), binding: binding) }
            let readable = await store.current(); XCTAssertEqual(readable.catalog.custom.count,1)
            try await Task.sleep(for: .milliseconds(25))
            let before = await provider.recorded(); XCTAssertFalse(before.contains("delete"))
            if !timeout { await provider.resume() }
            let added = await add.value
            XCTAssertEqual(added,timeout ? .failure(.timeout) : .success)
            if timeout { XCTAssertGreaterThanOrEqual(start.duration(to: .now),.seconds(10)) }
            let removed = await deletion.value; XCTAssertEqual(removed,.success)
            if timeout { await provider.resume(); await Task.yield() }
            let members = try await provider.customMembers(binding: binding); XCTAssertNil(members[id])
            let recorded = await provider.recorded(); XCTAssertEqual(recorded,timeout ? ["delete"] : ["add","delete"])
        }
    }
    func testFailedCreateAndAddKeepsFolderAndOfflineDeleteAppliesLater() async throws {
        let fixture = try SidebarFolderFixture(), provider = try SidebarFolderProvider(fixture), store = SidebarFoldersStore(url: fixture.catalogURL)
        try await provider.seed(); let binding = await provider.binding(), id = UUID()
        await success(store,.load(defaults: [])); await success(store,.attach(provider,binding))
        await provider.fail(true)
        let failed = await store.perform(.createAndAdd(id,name: "Saved",symbol: "folder",item: .telegram(fixture.chat)), binding: binding)
        XCTAssertEqual(failed,.failure(.unavailable))
        let partial = await store.current(); XCTAssertEqual(partial.catalog.custom.map(\.id),[id])
        await provider.fail(false); await success(store,.member(id,.telegram(fixture.chat),true))
        await success(store,.attach(nil,binding)); await success(store,.delete(id))
        let retained = try await provider.customMembers(binding: binding); XCTAssertEqual(retained[id],[fixture.chat])
        await success(store,.attach(provider,binding))
        let removed = try await provider.customMembers(binding: binding); XCTAssertNil(removed[id])
    }
    func testCProviderAddSurvivesCatalogWriteFailureAndIdenticalSummaryRefresh() async throws {
        let fixture = try SidebarFolderFixture(), provider = try SidebarFolderProvider(fixture, summaries: true), switcher = FolderWriteSwitch()
        try await provider.seed()
        let binding = await provider.binding(), a = UUID(), b = UUID()
        let store = SidebarFoldersStore(url: fixture.catalogURL, write: switcher.write)
        await success(store, .load(defaults: [])); await success(store, .attach(provider, binding))
        await success(store, .create(a, name: "A", symbol: "folder"))
        await success(store, .create(b, name: "B", symbol: "folder"))
        await success(store, .member(a, .telegram(fixture.chat), true))
        await success(store, .refreshTelegram)
        let summaries = try await provider.customSummaries(binding: binding)
        XCTAssertEqual(summaries.map(\.chat), [fixture.chat])
        let before = await store.current()
        switcher.set(true)
        let failed = await store.perform(.member(b, .telegram(fixture.chat), true), binding: binding)
        XCTAssertEqual(failed, .failure(.storage))
        let partial = await store.current()
        XCTAssertEqual(partial.members[b], [.telegram(fixture.chat)], "A failed operation must publish its completed membership change")
        let saved = try await provider.customMembers(binding: binding)
        XCTAssertEqual(saved[b], [fixture.chat], "Provider add must have succeeded before the catalog write failed")
        let unchanged = try await provider.customSummaries(binding: binding)
        func metadata(_ values: [TelegramFolderSummary]) -> [SidebarItemSummary] {
            values.map { .init(reference: .telegram($0.chat), title: $0.title,
                activity: Date(timeIntervalSince1970: Double($0.date)), unread: $0.unread, muted: $0.muted,
                attention: $0.attention, available: $0.available, hidden: $0.hidden) }
        }
        XCTAssertEqual(metadata(unchanged), metadata(summaries))
        await success(store, .refreshTelegram)
        let after = await store.current()
        XCTAssertEqual(after.members[b], [.telegram(fixture.chat)])
        XCTAssertGreaterThan(after.revision, before.revision)
        let projection = await store.presentation(scope: nil, query: "", ranges: [b: 0..<8], telegramOpen: true)
        XCTAssertEqual(projection[b]?.items, [.telegram(fixture.chat)])
        XCTAssertEqual(projection[b]?.rows[.telegram(fixture.chat)]?.title, fixture.name)
        await success(store, .refreshTelegram)
        let duplicate = await store.current()
        XCTAssertEqual(duplicate.revision, after.revision)
        await provider.close()
    }
    func testUpgradeDeleteRestartAndBothRollbackRoundTripsShareOneCatalog() async throws {
        for (delete,rollback) in [(true,false),(false,true),(true,true)] {
            let fixture = try SidebarFolderFixture(legacy: true), provider = try SidebarFolderProvider(fixture)
            let store = SidebarFoldersStore(url: fixture.catalogURL), binding = await provider.binding(), id = binding.migratedPinsID
            await success(store,.load(defaults: [])); await success(store,.attach(provider,binding))
            let adopted = await store.current(); XCTAssertEqual(adopted.catalog.custom.map(\.id),[id])
            XCTAssertEqual(adopted.catalog.custom.first?.name,"Pinned here"); XCTAssertEqual(adopted.members[id]?.count,205)
            if delete { await success(store,.delete(id)) }
            await provider.close()
            if rollback { try fixture.rollback() }
            try await provider.reopen()
            let reopened = SidebarFoldersStore(url: fixture.catalogURL)
            await success(reopened,.load(defaults: [])); await success(reopened,.attach(provider,binding))
            let result = await reopened.current(), members = try await provider.customMembers(binding: binding)
            XCTAssertEqual(result.catalog.custom.map(\.id),delete ? [] : [id])
            XCTAssertEqual(result.catalog.tombstones,delete ? [id] : [])
            XCTAssertEqual(members[id]?.count,delete ? nil : 205)
        }
    }
    func testSafetyBoundsAndIncrementalActivitySort() async throws {
        let fixture = try SidebarFolderFixture(), store = SidebarFoldersStore(url: fixture.catalogURL), id = UUID()
        await success(store,.load(defaults: [])); await success(store,.create(id,name: "Sort",symbol: "folder"))
        let a = SidebarItemReference.agentpad(.myAgent(UUID())), b = SidebarItemReference.agentpad(.myAgent(UUID()))
        await success(store,.member(id,a,true)); await success(store,.member(id,b,true))
        await store.updateSummaries([.init(reference: a,title: "A",activity: nil),.init(reference: b,title: "B",activity: Date(timeIntervalSince1970: 10))])
        let outsideViewport = await store.current(); XCTAssertTrue(outsideViewport.rows.isEmpty)
        await success(store,.viewport([id: 0..<2]))
        let sorted = await store.current(); XCTAssertEqual(sorted.rows[id]?.map(\.reference),[b,a])
        await store.updateSummaries([.init(reference: b,title: "B",activity: Date(timeIntervalSince1970: 10))])
        let unchanged = await store.current(); XCTAssertEqual(unchanged.revision,sorted.revision)
        let large = await store.perform(.rename(id,name: String(repeating: "é",count: 513),symbol: "folder"), binding: nil)
        XCTAssertEqual(large,.failure(.tooLarge))
        let largeViewport = await store.perform(.viewport([id: 0..<77]), binding: nil); XCTAssertEqual(largeViewport,.failure(.tooLarge))
        var catalog = SidebarFolderCatalog()
        catalog.tombstones = Set((0..<100_001).map { _ in UUID() }); XCTAssertThrowsError(try catalog.validate())
        catalog.tombstones = []
        catalog.custom = (0..<10_001).map { _ in .init(id: UUID(),name: "Collection") }
        XCTAssertThrowsError(try catalog.validate()) { XCTAssertEqual($0 as? SidebarFolderFailure,.tooLarge) }
        let items = (0..<20_001).map { _ in SidebarAgentPadReference.myAgent(UUID()) }
        catalog.custom = [.init(id: UUID(),name: "Collection",items: items)]
        XCTAssertThrowsError(try catalog.validate()) { XCTAssertEqual($0 as? SidebarFolderFailure,.tooLarge) }
        catalog.custom = (0..<6).map { _ in .init(id: UUID(),name: "Collection",items: Array(items.prefix(20_000))) }
        XCTAssertThrowsError(try catalog.validate()) { XCTAssertEqual($0 as? SidebarFolderFailure,.tooLarge) }
    }
}
