import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatActivitySnapshotTests: XCTestCase {
    private func write(_ store: ChatStore, _ body: (Database) throws -> Void) throws { try store.queue.write(body) }
    private func read<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.read(body) }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Snapshot did not settle", file: file, line: line)
    }

    func testConnectionOwnedModelsReleaseServiceAndJournal() async throws {
        let isolation = TeamServiceTestScope()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-lifetime-\(UUID())")
        defer { isolation.close(); try? FileManager.default.removeItem(at: root) }
        var service: ChatService? = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service?.followsFeed = false
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        try service?.saveSignIn(.init(server: server, accountId: "me", sessionId: "s", deviceName: "Mac", orgId: "org"), token: "test-only")
        try await service?.start(mode: .server)
        try await wait { service?.orgCurrent.model != nil && service?.orgCurrent.devices != nil }
        // A view may keep these models after the connection owner goes away.
        let org = try XCTUnwrap(service?.orgCurrent.model)
        let devices = try XCTUnwrap(service?.orgCurrent.devices)
        weak var releasedService = service
        weak var releasedJournal = service?.journal
        service = nil
        await Task.yield()
        XCTAssertNil(releasedService, "Connection-owned models must not retain their owner")
        XCTAssertNil(releasedJournal, "A dead connection must not keep its run-admission journal alive")
        XCTAssertFalse(org.isCurrent())
        XCTAssertFalse(devices.isCurrent())
        // A leaked fixture's journal becomes unreadable after teardown; the
        // fail-closed admission callback would then reject every later agent.
        try releasedJournal?.queue.close()
        XCTAssertFalse(TeamRunAdmission.journalBlocks(UUID().uuidString))
    }

    func testSnapshotBurstReadsOffMainAndCancellationDropsQueuedUpdates() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { try $0.execute(sql: "CREATE TABLE counter (value INTEGER); INSERT INTO counter VALUES (0); CREATE TABLE draft (text TEXT)") }
        let reads = Counter(), mainReads = Counter()
        var values: [Int] = []
        let observation = ChatSnapshotObservation(in: queue, tracking: ["counter"], fetch: { db in
            reads.increment()
            if Thread.isMainThread { mainReads.increment() }
            return try Int.fetchOne(db, sql: "SELECT value FROM counter") ?? -1
        }, onError: { XCTFail("Unexpected snapshot error: \($0)") }, onChange: { values.append($0) })
        try await wait { values == [0] }
        // Separate commits in a burst must not run a full snapshot per commit.
        for _ in 0..<500 { try writeCounter(queue) }
        try await wait { values.last == 500 }
        XCTAssertLessThan(reads.value, 10)
        XCTAssertEqual(mainReads.value, 0)
        let before = reads.value
        try await queue.write { try $0.execute(sql: "INSERT INTO draft VALUES ('typing')") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.value, before, "Unrelated writes must not refetch history")
        try writeCounter(queue)
        observation.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(values.last, 500, "Cancellation fences the pending refresh")
    }

    private func writeCounter(_ queue: DatabaseQueue) throws {
        try queue.write { try $0.execute(sql: "UPDATE counter SET value = value + 1") }
    }

    func testColdStartHiddenPanelSharesUnreadAndConnectionGateAcrossWindows() async throws {
        let isolation = TeamServiceTestScope()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-snapshot-\(UUID())")
        defer { isolation.close(); try? FileManager.default.removeItem(at: root) }
        let service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service.followsFeed = false
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "s", deviceName: "Mac", orgId: key.orgId), token: "test-only")
        try await service.start(mode: .server)
        let db = try XCTUnwrap(service.orgSessions[key]?.store)
        try write(db) { db in
            try db.execute(sql: "UPDATE meta SET me = 'me', rights_in_doubt = 0, rights_session = 's', channels_served = 1")
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES ('team', 'Team', 1)")
            try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp) VALUES ('c', 'team', 'Private channel', 0, 1, 1)")
            try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES ('c', 1, 0)")
            try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq, muted) VALUES ('c', 0, 1)")
            for (id, seq, thread) in [("root", 1, false), ("reply", 2, true)] {
                let value: [String: Any] = ["message_id": id, "channel_id": "c", "thread_root_id": thread ? "root" as Any : NSNull(),
                    "author_account_id": "other", "text": id, "mentions": [], "revision": 1, "seq": seq, "created_at": "2026-10-06T10:00:00Z"]
                let message = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
                try ChatMessages.write(db, message)
            }
        }
        service.orgSessions[key]?.snapshotOwed = false
        let a = makeTestStore(), b = makeTestStore()
        let previous = AgentMonitor.shared.storesProvider
        AgentMonitor.shared.storesProvider = { [a, b] }
        defer { AgentMonitor.shared.storesProvider = previous; a.terminate(); b.terminate() }
        a.leftNavigation.railVisible = false; a.leftNavigation.panelVisible = false
        let ref = ChannelRef(key, channel: "c")
        let one = a.openChannelTab(ref, in: a.active!), two = b.openChannelTab(ref, in: b.active!)
        _ = a.addTab(in: a.active!); _ = b.addTab(in: b.active!)
        let ledger = AttentionLedger(), projection = AttentionSidebarModel(ledger: ledger, service: service)
        try await wait { projection.tabIndicators[one.id] != nil && projection.tabIndicators[two.id] != nil }
        XCTAssertNotNil(service.orgCurrent.model, "Connection starts the model without a sidebar task")
        XCTAssertEqual(projection.tabIndicators[one.id]?.kind, .unread)
        let reason = try XCTUnwrap(projection.tabIndicators[one.id]?.reasons.first)
        XCTAssertEqual(reason.conversation, .channel(ChatAttention.scope(key, service), "c"))
        XCTAssertEqual(reason.readMarks, ["": 0])
        XCTAssertEqual(projection.tabIndicators[two.id]?.reasonIDs, [reason.id])
        XCTAssertTrue(projection.items.isEmpty, "Ordinary unread does not add Needs attention rows")
        XCTAssertEqual(projection.tabTitle(one.id), "#Private channel")
        let model = try XCTUnwrap(service.orgCurrent.model)
        service.orgCurrent.refresh(service)
        XCTAssertTrue(service.orgCurrent.model === model, "Windows share one organization observer")
        let builds = projection.projectionBuildCount
        projection.refresh(service: service, ledger: ledger)
        projection.refresh(service: service, ledger: ledger)
        XCTAssertEqual(projection.projectionBuildCount, builds)
        let initiator = makeTestStore()
        defer { initiator.terminate() }
        let router = TabRouter()
        router.stores = { [a, b, initiator] }
        router.ensureHost = { initiator }
        router.prepareDestinations = { projection.updateProjection() }
        router.destinations = { projection.projection.tabs }
        router.channelScope = { _ in ChatAttention.scope(key, service) }
        one.lastActivated = .distantPast; two.lastActivated = Date()
        var raised: UUID?
        router.revealWindow = { raised = $0.windowID }
        let mention = AttentionItem(id: "mention", tier: 3, time: .now, title: "#Private channel", subtitle: "Mentioned you",
            action: .mention(ChatAttention.scope(key, service), channel: "c", message: "root", sequence: 1))
        projection.activate(mention, from: initiator, router: router)
        XCTAssertEqual(raised, b.windowID)
        XCTAssertNil(initiator.channelTab(ref), "Needs attention must reuse the open destination in another window")
        XCTAssertEqual(ChatMessageNavigation.take(key: key, channel: "c", from: two.engine.view)?.message, "root")
        try write(db) { _ = try ChatUnread.markRead($0, channel: "c", upTo: 1) }
        try await wait { projection.tabIndicators.isEmpty }
        XCTAssertEqual(try read(db) { try ChatUnread.unreadRepliesByChannel($0)["c"] }, 1,
                       "Thread-only unread keeps its own semantics")
        let local = try XCTUnwrap(a.active?.activeSession)
        ledger.upsert(.init(source: "terminal", object: local.id.uuidString, episode: local.attentionEpisode,
                            kind: .input, destination: .terminal(local.id)))
        service.orgSessions[key]?.doubtNotWritten = true
        try await wait { projection.projection.tabs[one.id]?.available == false }
        XCTAssertEqual(projection.tabTitle(one.id), "Channel")
        XCTAssertNotNil(projection.tabIndicators[local.id], "Local attention survives a closed server gate")
        try write(db) { try $0.execute(sql: "UPDATE channels SET name = 'Late private title'") }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(projection.tabTitle(one.id), "Channel", "Late source callbacks cannot reopen the gate")
        service.orgSessions[key]?.doubtNotWritten = false
        try await wait { projection.tabTitle(one.id) == "#Late private title" }
        service.stopFeed()
        service.orgCurrent.model?.stop()
    }
}
