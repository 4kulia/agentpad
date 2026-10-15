import Foundation
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

extension SidebarFoldersUITests {
    func testCUnavailableTeamAgentKeepsAttentionUntilOrgGateCloses() async throws {
        let worker = SidebarFolderSummaryWorker(), key = fixture.key
        let reference = SidebarAgentPadReference.teamAgent(.init(server: key.server.description,
            account: key.accountId, org: key.orgId, agent: "docs"))
        _ = await worker.apply(.members([reference]))
        var view = fixture.org.view
        view.channelAgents[0].available = false
        _ = await worker.apply(.chat(.init(key: key, view: view, me: "me")))
        var item = AttentionItem(id: "agent-attention", tier: 1, time: .now,
            title: "Docs reviewer", subtitle: "Unread", action: .event("agent-attention"))
        item.subjectID = "docs"; item.subjectIsAgent = true
        let changed = await worker.apply(.attention([item], [:]))
        let summary = try XCTUnwrap(changed.first { $0.reference == .agentpad(reference) })
        XCTAssertFalse(summary.available)
        XCTAssertTrue(summary.attention, "Agent availability must not hide existing attention")
        let gated = await worker.apply(.chat(.init()))
        let hidden = try XCTUnwrap(gated.first { $0.reference == .agentpad(reference) })
        XCTAssertFalse(hidden.available)
        XCTAssertFalse(hidden.attention, "Closing the organization gate removes its attention")
    }

    func testCCatalogDeltaDoesNotReadLiveSessionsOrChannelsAndCanLowerActivity() async throws {
        let records = FolderCatalogRecords()
        let catalog = SessionCatalog { _ in
            let values = records.get()
            return .init(records: values, scanned: values.count, total: values.count, skipped: 0)
        }
        fixture.close(); fixture = try FoldersUIFixture(catalog: catalog); try await fixture.start()
        fixture.folders.viewport([fixture.launch: 0..<8])
        let profile = fixture.store.agentProfiles.profiles[0]
        let ref = SidebarItemReference.agentpad(.myAgent(profile.id))
        let source = try XCTUnwrap(fixture.folders.summarySource)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var values: [AgentSessionRecord] = []
        for size in [8, 64] {
            for index in values.count..<size {
                let session = try fixture.store.startAgentProfile(profile.id).get()
                session.conversationId = "catalog-\(index)"
                let record = AgentSessionRecord(agentId: profile.rosterID, conversationId: "catalog-\(index)", title: "History",
                    cwd: profile.folder, lastActivity: date.addingTimeInterval(Double(index))).scanned(at: date)
                try fixture.store.agentProfiles.bind(record, to: profile.id)
                values.append(record)
            }
            var view = fixture.org.view
            view.channels += (view.channels.count..<size).map {
                .init(channelId: "catalog-\($0)", teamId: "aster", name: "Channel \($0)", createdBy: "me", archived: false, version: 1)
            }
            fixture.org.set(view)
            records.set(values); catalog.refresh(force: true)
            try await eventually { !catalog.isScanning && self.fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == values.last?.lastActivity }
            await source.delivery?.value
            let liveReads = source.sessionReadCount, chatReads = source.chatReadCount, catalogReads = catalog.recordReadCount
            var changed = values
            changed[0].lastActivity = date.addingTimeInterval(1_000)
            records.set(changed); catalog.refresh(force: true)
            try await eventually { !catalog.isScanning && self.fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == changed[0].lastActivity }
            XCTAssertEqual(source.sessionReadCount - liveReads, 0)
            XCTAssertEqual(source.chatReadCount - chatReads, 0)
            XCTAssertEqual(catalog.recordReadCount - catalogReads, 0)
            // Removing the winner must reveal the next contribution, including
            // the saved binding; a cached maximum must not stick forever.
            records.set(Array(values.dropFirst())); catalog.refresh(force: true)
            try await eventually { !catalog.isScanning && self.fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == values.last?.lastActivity }
            try fixture.store.agentProfiles.discover([changed[0]])
            try await eventually { self.fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == changed[0].lastActivity }
            XCTAssertEqual(source.sessionReadCount - liveReads, 0, "A changed binding must also use the keyed live inputs")
            XCTAssertEqual(source.chatReadCount - chatReads, 0)
            XCTAssertEqual(catalog.recordReadCount - catalogReads, 0)
            try fixture.store.agentProfiles.discover([values[0]])
            try await eventually { self.fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == values.last?.lastActivity }
            print("Folder catalog/binding regression: \(size) sessions/channels, 0 live/chat/catalog item reads")
        }
    }

    func testCCachedSummariesUpdateOnlyChangedMembersAndDoNotReadHistoryOnChatChanges() async throws {
        fixture.folders.viewport([fixture.launch: 0..<8])
        try await eventually { fixture.folders.custom[self.fixture.launch]?.rows.count == 5 }
        let source = try XCTUnwrap(fixture.folders.summarySource)
        var historyReads = 0
        fixture.store.conversationVisibility = { historyReads += 1; return .init(channelIds: []) }
        // Policy observation enqueues work behind any remaining initial summaries.
        // Drain those deliveries before measuring subsequent single-member updates.
        try await eventually { historyReads > 0 }
        await source.delivery?.value
        let before = source.updatedSummaryCount
        historyReads = 0
        let ref = SidebarItemReference.agentpad(.channel(.init(server: fixture.key.server.description,
            account: fixture.key.accountId, org: fixture.key.orgId, channel: "launch")))
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        var view = fixture.org.view; view.channelActivity["launch"] = date
        fixture.org.set(view)
        try await eventually { fixture.folders.custom[self.fixture.launch]?.rows[ref]?.activity == date }
        XCTAssertEqual(source.updatedSummaryCount, before + 1)
        XCTAssertEqual(historyReads, 0, "Chat source changes must not visit profile history")
        // The newest bound record can arrive without a sidebar being mounted.
        let profile = fixture.store.agentProfiles.profiles[0]
        let record = AgentSessionRecord(agentId: profile.rosterID, conversationId: "latest", title: "",
            cwd: profile.folder, lastActivity: date.addingTimeInterval(100)).scanned(at: date)
        try fixture.store.agentProfiles.bind(record, to: profile.id)
        try await eventually { fixture.folders.custom[self.fixture.launch]?.rows[.agentpad(.myAgent(profile.id))]?.activity == record.lastActivity }
        XCTAssertEqual(source.updatedSummaryCount, before + 2)
        try fixture.store.agentProfiles.rename(profile.id, to: "Updated agent")
        try await eventually { fixture.folders.custom[self.fixture.launch]?.rows[.agentpad(.myAgent(profile.id))]?.title == "Updated agent" }
        XCTAssertEqual(source.updatedSummaryCount, before + 3)
    }
}

private final class FolderCatalogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AgentSessionRecord] = []
    func set(_ values: [AgentSessionRecord]) { lock.withLock { records = values } }
    func get() -> [AgentSessionRecord] { lock.withLock { records } }
}

@MainActor final class SidebarFolderRetryTests: XCTestCase {
    func testRetryUsesTheSameFIFOAsNewMutations() async throws {
        let fixture = try SidebarFolderFixture()
        let provider = try SidebarFolderProvider(fixture)
        try await provider.seed()
        let binding = await provider.binding()
        let store = SidebarFoldersStore(url: fixture.catalogURL)
        _ = await store.perform(.load(defaults: []), binding: nil)
        _ = await store.perform(.attach(provider, binding), binding: binding)
        let model = SidebarFoldersModel(store: store)
        model.start()
        let id = UUID()
        await provider.fail(true)
        let created = await model.perform(.createAndAdd(id, name: "Retry FIFO", symbol: "folder", item: .telegram(fixture.chat)), binding: binding)
        XCTAssertFalse(created)
        await provider.fail(false); await provider.pauseNextAdd()
        model.retry()
        for _ in 0..<200 {
            if await provider.waiting() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await provider.waiting()
        XCTAssertTrue(waiting)
        let deletion = Task { await model.perform(.delete(id), binding: binding) }
        for _ in 0..<200 {
            if await store.queuedOperationCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = await provider.recorded()
        XCTAssertEqual(before, [])
        await provider.resume()
        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        let after = await provider.recorded()
        XCTAssertEqual(after, ["add", "delete"])
        XCTAssertTrue(model.failures.isEmpty)
        await provider.close()
    }
}
