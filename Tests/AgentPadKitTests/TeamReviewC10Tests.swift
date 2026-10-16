import Darwin
import XCTest
@testable import AgentPadKit

/// Tenth client review (review-client-c10.md): Stop Them holds the queue; a
/// left-over with a missed look is the owner's to close; one admission rule
/// for both modes.
@MainActor
final class TeamReviewC10Tests: XCTestCase {
    private var root: URL!

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c10-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        TeamRunAdmission.journalBlocks = { _ in false }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testConfirmingGoneIsRefusedWhileOneRuns() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate() }
        let alive = ProcessIdentity(pid: p.processIdentifier, startTime: try XCTUnwrap(TeamProcesses.startTime(p.processIdentifier)))
        let leader = TeamProcessStart(pid: 999_967, pgid: 999_967, startTime: 1)
        TeamProcesses.shared.add(leader, seen: TeamPidSet([alive]), agentId: "agent-w")
        TeamProcesses.shared.markLeftOver(leader)
        defer { TeamProcesses.shared.remove(leader) }
        XCTAssertNotNil(TeamProcesses.shared.confirmGone(leader))
        XCTAssertEqual(TeamProcesses.shared.leftOvers().count, 1)
    }

    /// C10-6: a server run not confirmed gone after a crash blocks the agent
    /// with team work off too — the one runner asks the journal; after the owner's
    /// "They Are Gone" it runs.
    func testJournalBlocksTheAgentInEveryMode() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        try files.prepareDirectory()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f6"), runner: RecordingRunner())
        f.journal = try ChatJournal.open(files: files)
        try f.assign(.active)
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        XCTAssertTrue(try f.journal.consume(approval, run: ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, pid: 999_966, pgid: 999_966, processStartedAt: 1, startedAt: f.now)))
        // The next app, off after a Disconnect: the journal on disk is opened.
        let service = ChatService(files: files, tokens: FakeTokenStore())
        await service.recoverRunsAtLaunch()
        let request = TeamRunRequest(agent: f.agent, prompt: "p", sessionId: "s", resume: false, callerName: "M", callerProject: nil)
        do {
            _ = try await ClaudeCodeRunner(claudePath: "/usr/bin/true").run(request, onActivity: { _ in })
            XCTFail("ran")
        } catch TeamRunnerError.didNotStart {
        } catch { XCTFail("\(error)") }
        let recovery = try XCTUnwrap(service.recovery)
        let answer = await recovery.confirmGone(params.runId)
        XCTAssertNil(answer)
        XCTAssertFalse(TeamRunAdmission.journalBlocks(f.agent.id.uuidString.lowercased()))
    }

    func testReopenedJournalKeepsLiveSetsidChildBlockedInNewRegistry() async throws {
        try await checkReopenedChild(exitsBeforeRecovery: false)
    }

    func testReopenedJournalAllowsExitedSetsidChildInNewRegistry() async throws {
        try await checkReopenedChild(exitsBeforeRecovery: true)
    }

    func testReopenedJournalRestoresPreflightSetsidChild() async throws {
        try await checkReopenedChild(exitsBeforeRecovery: false, preflight: true)
    }

    private func checkReopenedChild(exitsBeforeRecovery: Bool, preflight: Bool = false) async throws {
        let binary = try NativeTeamChildFixture.make(in: root)
        let spawned = try TeamSpawn.suspended(path: binary.path, arguments: [], environment: [:],
                                              directory: root.path, stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
        let processes = TeamProcesses()
        defer {
            spawned.kill()
            if let child = NativeTeamChildFixture.child(in: root) { NativeTeamChildFixture.stop(child) }
            _ = TeamSpawn.waitForExit(spawned.pid)
            processes.remove(spawned.identity)
            spawned.release()
        }
        let runner = JournalChildRunner(processes: processes, spawned: spawned, root: root, preflight: preflight)
        let f = try ExecutorFixture(root: root, runner: runner)
        let approval = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("the child's cleanup must stay unconfirmed")
        } catch let error as TeamRunnerError {
            if preflight {
                guard case .preflightCleanupUnconfirmed = error else { return XCTFail("\(error)") }
            } else {
                guard case .stopped(.stillAlive) = error else { return XCTFail("\(error)") }
            }
        }
        try f.journal.markStopping(approval.runId, reason: "stopped_by_owner")
        let child = try XCTUnwrap(NativeTeamChildFixture.child(in: root))
        XCTAssertEqual(getsid(child.pid), child.pid)
        XCTAssertEqual(TeamProcesses.liveness(spawned.identity.identity), .gone)
        XCTAssertEqual(TeamProcesses.groupIdentities(spawned.pid), [])
        let saved = try XCTUnwrap(f.journal.run(approval.runId))
        XCTAssertTrue(saved.seen?.identities.contains(child) == true)
        XCTAssertEqual(saved.seen?.incomplete, true)
        XCTAssertNil(saved.processesGoneAt)
        // Discard the first app's account, close its database, and reap its dead
        // leader. Recovery has only the disk evidence and PID/start-time checks.
        processes.remove(spawned.identity)
        spawned.release()
        try f.journal.queue.close()
        if exitsBeforeRecovery { NativeTeamChildFixture.stop(child) }
        let reopened = try ChatJournal.open(files: f.files)
        defer { try? reopened.queue.close() }
        let fresh = TeamProcesses()
        let recovery = TeamRunRecovery(journal: reopened, processes: fresh) { _ in false }
        try await recovery.check().get()
        XCTAssertEqual(recovery.blocked.map(\.id), [approval.runId])
        XCTAssertTrue(fresh.seen(of: spawned.identity)?.identities.contains(child) == true)
        XCTAssertEqual(fresh.seen(of: spawned.identity)?.isIncomplete, true)
        XCTAssertEqual(recovery.blocked.first?.found, exitsBeforeRecovery ? [] : [child])
        if !exitsBeforeRecovery {
            // Recovery is passive even when this new app quits: only the
            // owner's explicit Stop These Processes may signal the survivor.
            let send = TeamProcesses.sendSignal
            let signalled = TeamValueBox<pid_t>()
            TeamProcesses.sendSignal = { pid, _, _ in signalled.set(pid) }
            fresh.killAll()
            TeamProcesses.sendSignal = send
            XCTAssertNil(signalled.get())
            let refused = await recovery.confirmGone(approval.runId)
            XCTAssertNotNil(refused, "a live child outside the dead leader's group still blocks")
            XCTAssertNil(try reopened.run(approval.runId)?.processesGoneAt)
            XCTAssertNil(try reopened.run(approval.runId)?.outcome)
            recovery.stopGrace = .zero
            let stopped = await recovery.stopProcesses(approval.runId)
            XCTAssertNil(stopped)
            XCTAssertTrue(NativeTeamChildFixture.waitUntil { TeamProcesses.liveness(child) == .gone })
            XCTAssertEqual(try reopened.run(approval.runId)?.seen, saved.seen,
                           "a stop of selected processes must retain the earlier cleanup evidence")
        }
        let confirmed = await recovery.confirmGone(approval.runId)
        XCTAssertNil(confirmed)
        XCTAssertTrue(recovery.blocked.isEmpty)
        XCTAssertNil(fresh.seen(of: spawned.identity))
        XCTAssertNotNil(try reopened.run(approval.runId)?.processesGoneAt)
        XCTAssertEqual(try reopened.run(approval.runId)?.outcome, .stoppedLocally)
    }

    func testJournalWithoutSeenMigratesAndKeepsLegacyRecovery() async throws {
        let f = try ExecutorFixture(root: root, runner: RecordingRunner())
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id,
                                agentId: approval.agentId, conversationId: params.conversationId,
                                pid: 999_965, pgid: 999_965, processStartedAt: 1, startedAt: f.now)
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try f.journal.markStopping(row.runId, reason: "stopped_by_owner")
        let before = try XCTUnwrap(f.journal.run(row.runId))
        // The shipped schema, before the additive seen-process migration.
        try await f.journal.queue.write { db in
            try db.execute(sql: "ALTER TABLE runs DROP COLUMN seen")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'release-12-seen-processes'")
        }
        try f.journal.queue.close()
        let reopened = try ChatJournal.open(files: f.files)
        defer { try? reopened.queue.close() }
        let saved = try XCTUnwrap(reopened.run(row.runId))
        XCTAssertEqual(saved, before)
        XCTAssertNil(saved.seen)
        let fresh = TeamProcesses()
        let recovery = TeamRunRecovery(journal: reopened, processes: fresh) { _ in false }
        try await recovery.check().get()
        XCTAssertEqual(recovery.blocked.map(\.id), [row.runId])
        XCTAssertEqual(recovery.blocked.first?.found, [])
        let confirmed = await recovery.confirmGone(row.runId)
        XCTAssertNil(confirmed, "old rows keep the owner's confirmation path")
        XCTAssertTrue(recovery.blocked.isEmpty)
        XCTAssertEqual(try reopened.run(row.runId)?.outcome, .stoppedLocally)
    }
}

/// Exercise the launcher's real journal wiring while controlling when a native
/// child is discovered, leaves the group, and survives its dead leader.
private struct JournalChildRunner: TeamAgentRunner {
    let processes: TeamProcesses
    let spawned: TeamSpawned
    let root: URL
    let preflight: Bool

    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }

    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        let seen = TeamPidSet()
        processes.add(spawned.identity, seen: seen, spawned: spawned, agentId: request.agent.id.uuidString.lowercased())
        if preflight { try request.onPreflightProcess?(spawned.identity) }
        else { try onProcessStarted(spawned.identity) }
        try Data().write(to: root.appendingPathComponent("fork"))
        Darwin.kill(spawned.pid, SIGCONT)
        XCTAssertTrue(NativeTeamChildFixture.waitUntil {
            NativeTeamChildFixture.child(in: root) != nil && TeamProcesses.liveness(spawned.identity.identity) == .gone
        })
        let child = try XCTUnwrap(NativeTeamChildFixture.child(in: root))
        seen.insert([ProcessIdentity(pid: child.pid, startTime: child.startTime - 1)])
        if preflight {
            XCTAssertEqual(TeamProcesses.liveness(spawned.identity, also: seen, holder: spawned), .alive)
        } else {
            XCTAssertEqual(TeamProcesses.outcome(spawned.identity, also: seen, holder: spawned), .stillAlive([child]))
        }
        seen.markIncomplete()
        try Data().write(to: root.appendingPathComponent("detach"))
        XCTAssertTrue(NativeTeamChildFixture.waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("detached").path) })
        processes.markLeftOver(spawned.identity)
        if preflight { throw TeamRunnerError.preflightCleanupUnconfirmed(spawned.identity, .stillAlive([child])) }
        throw TeamRunnerError.stopped(.stillAlive([child]))
    }
}
