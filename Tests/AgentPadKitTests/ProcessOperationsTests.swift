import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ProcessOperationsTests: XCTestCase {
    private var directory: URL!
    private var stores: [WorkspaceStore] = []
    private var scope: TeamServiceTestScope!
    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("process-operations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        for store in stores { store.terminate() }
        stores = []; scope.close()
        try? FileManager.default.removeItem(at: directory)
    }
    private func store() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store)
        return store
    }
    private func router() -> TabRouter {
        let router = TabRouter()
        router.stores = { [weak self] in self?.stores ?? [] }
        router.ensureHost = { [weak self] in self?.stores.first }
        return router
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "The operation did not settle")
    }
    @discardableResult private func write(_ path: String, _ text: String = "value") throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testKillRechecksPIDAndStartTimeAndSignalsOnlyOnce() async throws {
        let session = Session(engine: TestEngine(), currentDirectory: directory, agent: .terminal)
        let process = SessionProcess(pid: 4242, name: "fixture", depth: 1, isForeground: true, ports: [], cpuPercent: nil, residentMB: nil, startedAtUs: 42)
        var start: UInt64 = 42
        var signals: [Int32] = []
        func request() {
            TerminalProcessActions.requestKill(process, session: session, matches: { pid, stamp in pid == 4242 && stamp == start }, signal: { _, signal in signals.append(signal); return 0 })
        }
        request(); session.terminalConfirmation.shown(true)
        start = 43
        session.terminalConfirmation.confirm()
        XCTAssertEqual(session.terminalConfirmation.phase, .invalidated)
        XCTAssertTrue(signals.isEmpty)
        start = 42; request(); session.terminalConfirmation.shown(true)
        session.terminalConfirmation.confirm(); session.terminalConfirmation.confirm()
        try await settle { session.terminalConfirmation.phase == .completed }
        XCTAssertEqual(signals, [SIGTERM])
    }

    func testLastWorktreeReviewKeepsDirectoryAndExcludesItselfFromTargets() async throws {
        // This synthetic store represents an already running workspace. The
        // app's real startup gate is exercised separately by FirstLaunchTests.
        let sharedRouter = TabRouter.shared, admission = sharedRouter.admit
        sharedRouter.admit = { _ in true }
        defer { sharedRouter.admit = admission }
        let store = store(), source = try XCTUnwrap(store.active)
        let path = try write("worktree/file").deletingLastPathComponent()
        let worktree = store.addWorkspace(workingDirectory: path, worktreeParent: source, worktreeBranch: "fixture")
        let original = try XCTUnwrap(worktree.activeSession)
        store.closeTab(original, in: worktree)
        let review = try XCTUnwrap(store.allSessions.first { $0.tabState?.closeWorkspaces != nil })
        let batch = try XCTUnwrap(review.tabState?.closeWorkspaces)
        XCTAssertEqual(batch.rows.first?.sessions, [original.id])
        XCTAssertFalse(batch.alsoDelete)
        XCTAssertTrue(worktree.root.allPanes.flatMap(\.tabs).contains { $0 === original })
        let result = await batch.execute()
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(store.workspaces.contains { $0 === worktree })
        XCTAssertTrue(store.allSessions.contains { $0 === review }, "The review survives closing its original workspace")
        XCTAssertTrue(batch.completed)
    }

    func testBulkCloseRetriesOnlyFailedRowsAndRetainsSourceUntilChildrenClose() async throws {
        let store = store(), source = try XCTUnwrap(store.active)
        let aPath = try write("a/file").deletingLastPathComponent(), bPath = try write("b/file").deletingLastPathComponent()
        let a = store.addWorkspace(workingDirectory: aPath, worktreeParent: source, worktreeBranch: "a")
        let b = store.addWorkspace(workingDirectory: bPath, worktreeParent: source, worktreeBranch: "b")
        let batch = try XCTUnwrap(ProcessTabs(router: router()).close([a, b, source], from: store))
        batch.alsoDelete = true
        var attempts: [UUID: Int] = [:]
        batch.removeDirectory = { _, workspace in
            attempts[workspace.id, default: 0] += 1
            if workspace === b, attempts[b.id] == 1 { return "fixture disk failure" }
            try? FileManager.default.removeItem(at: workspace.diskPath)
            return nil
        }
        let first = await batch.execute()
        XCTAssertNotNil(first)
        XCTAssertEqual(attempts[a.id], 1)
        XCTAssertFalse(store.workspaces.contains { $0 === a })
        XCTAssertTrue(store.workspaces.contains { $0 === source })
        XCTAssertTrue(FileManager.default.fileExists(atPath: bPath.path))
        let second = await batch.execute()
        XCTAssertNil(second)
        XCTAssertEqual(attempts[a.id], 1, "Successful directory removal must never repeat")
        XCTAssertEqual(attempts[b.id], 2)
        XCTAssertTrue(batch.completed)
    }

    func testBulkCloseIncludesAnExistingWorkspaceDetailsTab() async throws {
        let store = store(), workspace = try XCTUnwrap(store.active), router = router()
        let details = try XCTUnwrap(router.open(.workspaceDetails(workspace.id), from: store))
        let batch = try XCTUnwrap(ProcessTabs(router: router).close([workspace], from: store))
        XCTAssertTrue(try XCTUnwrap(batch.rows.first).sessions.contains(details.id))
        XCTAssertTrue(batch.unchanged())
        let result = await batch.execute()
        XCTAssertNil(result)
        XCTAssertTrue(batch.completed)
        XCTAssertFalse(store.allSessions.contains { $0 === details })
        XCTAssertNotNil(router.owner(of: try XCTUnwrap(batch.tabID)), "Only the close review must survive")
    }

    func testCloseReviewInvalidatesWhenANewTargetTabAppears() throws {
        let store = store(), workspace = try XCTUnwrap(store.active)
        _ = store.addTab(in: workspace)
        let batch = try XCTUnwrap(ProcessTabs(router: router()).close([workspace], from: store))
        let state = try XCTUnwrap(batch.state)
        state.confirmation.canShow = { true }
        batch.request(); state.confirmation.shown(true)
        _ = store.addTab(in: workspace)
        state.confirmation.confirm()
        XCTAssertEqual(state.confirmation.phase, .invalidated)
        XCTAssertTrue(store.workspaces.contains { $0 === workspace })
    }

    func testCloseReviewRefreshesNewChildrenBeforeRequestOrExecution() async throws {
        for viaConfirmation in [false, true] {
            let store = store(), source = try XCTUnwrap(store.active)
            let a = store.addWorkspace(workingDirectory: directory.appendingPathComponent("a"), worktreeParent: source, worktreeBranch: "a")
            let unrelated = store.addWorkspace(workingDirectory: directory.appendingPathComponent("unrelated"))
            let batch = try XCTUnwrap(ProcessTabs(router: router()).close([a, source], from: store))
            let state = try XCTUnwrap(batch.state)
            let b = store.addWorkspace(workingDirectory: directory.appendingPathComponent("b"), worktreeParent: source, worktreeBranch: "b")
            store.activateWorkspace(unrelated)
            XCTAssertFalse(batch.unchanged(), "A new child makes the parent's review stale")
            if viaConfirmation {
                batch.request()
                XCTAssertFalse(state.confirmation.isAwaiting, "Updated targets need a new review before consent")
            } else {
                let result = await batch.execute()
                XCTAssertNotNil(result)
            }
            XCTAssertTrue([source, a, b, unrelated].allSatisfy { target in store.workspaces.contains { $0 === target } })
            XCTAssertEqual(Set(batch.rows.map(\.id)), [source.id, a.id, b.id], "Refresh the existing review with the current children")
            XCTAssertTrue(batch.unchanged())
            XCTAssertFalse(batch.completed)

            state.confirmation.canShow = { true }
            batch.request(); state.confirmation.shown(true); state.confirmation.confirm()
            try await settle { state.confirmation.phase == .completed }
            XCTAssertTrue(batch.completed)
            XCTAssertEqual(store.workspaces.map(\.id), [unrelated.id])
        }
    }

    func testCloseConfirmationInvalidatesAndRefreshesWhenChildSetChanges() throws {
        let store = store(), source = try XCTUnwrap(store.active)
        let a = store.addWorkspace(workingDirectory: directory.appendingPathComponent("a"), worktreeParent: source, worktreeBranch: "a")
        let b = store.addWorkspace(workingDirectory: directory.appendingPathComponent("b"))
        let batch = try XCTUnwrap(ProcessTabs(router: router()).close([a, source], from: store))
        let c = try XCTUnwrap(batch.state).confirmation
        c.canShow = { true }; batch.request(); c.shown(true)
        b.worktreeParentId = source.id
        c.confirm()
        XCTAssertEqual(c.phase, .invalidated)
        XCTAssertTrue([source, a, b].allSatisfy { target in store.workspaces.contains { $0 === target } })
        XCTAssertEqual(Set(batch.rows.map(\.id)), [source.id, a.id, b.id])
        XCTAssertTrue(batch.unchanged())
    }

    func testCloseExecutionChecksLiveChildrenAfterAwaitingDirectoryRemoval() async throws {
        let store = store(), source = try XCTUnwrap(store.active)
        let a = store.addWorkspace(workingDirectory: directory.appendingPathComponent("a"), worktreeParent: source, worktreeBranch: "a")
        _ = store.addWorkspace(workingDirectory: directory.appendingPathComponent("unrelated"))
        let batch = try XCTUnwrap(ProcessTabs(router: router()).close([a, source], from: store))
        batch.alsoDelete = true
        var resume: CheckedContinuation<String?, Never>?
        batch.removeDirectory = { _, _ in await withCheckedContinuation { resume = $0 } }
        let execution = Task { await batch.execute() }
        try await settle { resume != nil }
        let b = store.addWorkspace(workingDirectory: directory.appendingPathComponent("b"), worktreeParent: source, worktreeBranch: "b")
        resume?.resume(returning: nil)
        let result = await execution.value
        XCTAssertNotNil(result)
        XCTAssertTrue(store.workspaces.contains { $0 === source }, "A child added during execution must retain its parent")
        XCTAssertTrue(store.workspaces.contains { $0 === b })
        XCTAssertFalse(store.workspaces.contains { $0 === a })
        XCTAssertEqual(Set(batch.rows.filter { !$0.done }.map(\.id)), [source.id, b.id])
        XCTAssertTrue(batch.unchanged())
    }

    private func externalFixture() throws -> (ExternalSessionMonitor, ExternalAgentSession, WorkspaceStore) {
        let store = store()
        store.claudeProjectsRoot = directory.appendingPathComponent("projects")
        let id = UUID().uuidString.lowercased()
        try write("projects/-fixture/\(id).jsonl", "{\"type\":\"user\",\"cwd\":\"\(directory.path)\",\"message\":{\"content\":\"fixture\"}}\n")
        let source = ExternalAgentSession(pid: 4242, sessionId: id, kind: "interactive", cwd: directory, name: "fixture",
            status: .idle, statusSince: nil, startedAt: Date(timeIntervalSince1970: 43), processStart: 42)
        let monitor = ExternalSessionMonitor()
        monitor.conversationVisibility = { ChannelConversationFilter(channelIds: []) }
        store.conversationVisibility = { ChannelConversationFilter(channelIds: []) }
        monitor.snapshotProvider = { [source] }
        monitor.processInfo = { _ in .init(ppid: 1, tty: "ttys999", startTime: 42, name: "claude") }
        return (monitor, source, store)
    }

    func testTakeoverRejectsRecycledPIDAndChangedExternalConversationBeforeSignal() async throws {
        for change in ["pid", "conversation", "cwd", "busy"] {
            let (monitor, source, store) = try externalFixture()
            var signals = 0
            monitor.sendSignal = { _, _ in signals += 1; return 0 }
            if change == "pid" { monitor.processInfo = { _ in .init(ppid: 1, tty: nil, startTime: 99, name: "claude") } }
            else {
                let fresh = ExternalAgentSession(pid: source.pid, sessionId: change == "conversation" ? UUID().uuidString : source.sessionId,
                    kind: source.kind, cwd: change == "cwd" ? directory.appendingPathComponent("changed") : source.cwd, name: source.name,
                    status: change == "busy" ? .busy : .idle, statusSince: nil, startedAt: source.startedAt)
                monitor.snapshotProvider = { [fresh] }
            }
            let result = await monitor.takeOver(source, into: store)
            guard case .failure(let reason) = result else { return XCTFail("Changed source moved") }
            XCTAssertEqual(reason, change == "busy" ? .notIdle : .changed)
            XCTAssertEqual(signals, 0)
        }
    }

    func testTakeoverFailureAfterStoppingReportsActualStepsAndRetryDoesNotSignalAgain() async throws {
        let (monitor, source, store) = try externalFixture()
        await monitor.refresh()
        let router = router()
        let model = try XCTUnwrap(ProcessTabs(router: router).importExternal(source, from: store, monitor: monitor))
        var signals = 0
        monitor.sendSignal = { _, _ in signals += 1; return 0 }
        monitor.awaitExit = { _, _ in true }
        monitor.resume = { _, _ in .failure(.launchOptionsDisablePersistence) }
        let state = try XCTUnwrap(model.state)
        state.confirmation.canShow = { true }
        model.request(); state.confirmation.shown(true); state.confirmation.confirm()
        try await settle { if case .failed = state.confirmation.phase { true } else { false } }
        XCTAssertEqual(model.step, .sourceStopped)
        XCTAssertTrue(model.message?.contains("original process stopped") == true)
        XCTAssertFalse(model.message?.contains("left running") == true)
        XCTAssertEqual(signals, 1)
        model.retryResume(); state.confirmation.shown(true); state.confirmation.confirm()
        try await settle { state.confirmation.phase == .completed }
        XCTAssertEqual(signals, 1)
        XCTAssertEqual(model.step, .resumed)
        XCTAssertTrue(store.allSessions.contains { $0.conversationId == source.sessionId })
    }

    func testTakeoverStillRunningNeverClaimsRollbackOrStartsLocalSession() async throws {
        let (monitor, source, store) = try externalFixture()
        monitor.sendSignal = { _, _ in 0 }; monitor.awaitExit = { _, _ in false }
        monitor.resume = { _, _ in XCTFail("Must not resume while the source is alive"); return .failure(.agentCannotResume) }
        var step = ExternalSessionMonitor.TakeOverStep.checking
        let result = await monitor.takeOver(source, into: store, progress: { step = $0 })
        guard case .failure(let error) = result else { return XCTFail("Unexpected success") }
        XCTAssertEqual(error, .stillRunning)
        XCTAssertEqual(step, .signalSent)
        XCTAssertTrue(ImportSessionModel.failure(error, step: step).contains("SIGTERM was sent"))
        XCTAssertTrue(store.allSessions.isEmpty)
    }

    func testExecutingImportFollowsItsTabToTheCurrentWindow() async throws {
        let (monitor, source, original) = try externalFixture()
        let destination = store()
        destination.claudeProjectsRoot = original.claudeProjectsRoot
        destination.conversationVisibility = original.conversationVisibility
        await monitor.refresh()
        let model = try XCTUnwrap(ProcessTabs(router: router()).importExternal(source, from: original, monitor: monitor))
        var finishExit: CheckedContinuation<Bool, Never>?
        monitor.sendSignal = { _, _ in 0 }
        monitor.awaitExit = { _, _ in await withCheckedContinuation { finishExit = $0 } }
        let state = try XCTUnwrap(model.state)
        state.confirmation.canShow = { true }
        model.request(); state.confirmation.shown(true); state.confirmation.confirm()
        try await settle { finishExit != nil }
        XCTAssertTrue(destination.handleTabDrop(droppedId: model.tabID, in: try XCTUnwrap(destination.active)))
        finishExit?.resume(returning: true)
        try await settle { state.confirmation.phase == .completed }
        XCTAssertFalse(original.allSessions.contains { $0.conversationId == source.sessionId })
        XCTAssertTrue(destination.allSessions.contains { $0.conversationId == source.sessionId })
    }

    func testResetCountsActualLossesAndBackupRetainsUndeliveredResult() throws {
        let files = ChatFiles(directory: directory.appendingPathComponent("journal"))
        let journal = try ChatJournal.open(files: files)
        try journal.queue.write { db in
            try db.execute(sql: """
                INSERT INTO run_commands(command_id, session_id, type, body_bytes, order_key, created_at, state, server, account_id, org_id, result_text)
                VALUES ('command', 'session', 'run.result', X'7B7D', '1', '2026-10-08', 'pending', 'https://fixture.invalid', 'account', 'org', 'undelivered fixture')
                """)
        }
        XCTAssertTrue(journal.resetLosses.contains("Queued commands and results: 1"))
        try journal.queue.close()
        let fresh = try ChatJournal.reset(files: files)
        XCTAssertTrue(fresh.resetLosses.contains("Queued commands and results: 0"))
        let backup = try DatabaseQueue(path: XCTUnwrap(fresh.resetBackup).path)
        XCTAssertEqual(try backup.read { try String.fetchOne($0, sql: "SELECT result_text FROM run_commands") }, "undelivered fixture")
    }

    func testJournalResetKeepsOriginalAndSidecarsWithoutOverwritingEarlierBackup() throws {
        let files = ChatFiles(directory: directory.appendingPathComponent("chat"))
        try files.prepareDirectory()
        let bytes = Data(repeating: 7, count: 4096)
        try bytes.write(to: files.journalURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: files.journalURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: files.journalURL.path + "-shm"))
        let fresh = try ChatJournal.reset(files: files)
        let backup = try XCTUnwrap(fresh.resetBackup)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(try String(contentsOfFile: backup.path + "-wal", encoding: .utf8), "wal")
        XCTAssertEqual(try String(contentsOfFile: backup.path + "-shm", encoding: .utf8), "shm")
        XCTAssertTrue(fresh.resetLosses.contains("Queued commands and results: 0"))
        try fresh.queue.close()
        let again = try ChatJournal.reset(files: files)
        XCTAssertNotEqual(again.resetBackup, backup)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertTrue(ChatJournal.resetConsequences.contains("undelivered results"))
        XCTAssertTrue(ChatJournal.resetConsequences.contains("does not stop processes"))
    }

    func testJournalResetLivesInDeliveryAndShowsUnknownLossesForCorruptDatabase() async throws {
        let store = store(), router = router()
        let files = ChatFiles(directory: directory.appendingPathComponent("damaged"))
        try files.prepareDirectory()
        try Data(repeating: 1, count: 512).write(to: files.journalURL)
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let tabs = ProcessTabs(router: router)
        tabs.resetJournal(service: service, teams: TeamTabs(router: router))
        let state = try XCTUnwrap(store.active?.activeSession?.tabState)
        XCTAssertEqual(state.navigation.selection, "delivery")
        XCTAssertTrue(state.confirmation.consequences.contains("loss counts are unknown"))
        state.confirmation.canShow = { true }; state.confirmation.shown(true); state.confirmation.confirm()
        try await settle { state.confirmation.phase == .completed }
        XCTAssertNotNil(service.journal?.resetBackup)
        XCTAssertTrue(state.message?.contains("Backup:") == true)
    }
}
