import Darwin
import GRDB
import XCTest
@testable import AgentPadKit

/// Sixth client review (review-client-c6.md): "not known" is never taken for
/// "confirmed" — the hold of our own child, identities from one read,
/// the run's processes kept until confirmed gone, a check that cannot be made
/// refusing a launch; facts only with the request's state known; resend order;
/// approvals per organization; the token file's removal.
@MainActor
final class TeamReviewC6Tests: XCTestCase {
    private var root: URL!
    private var started: [pid_t] = []
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c6-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        TeamProcesses.tableUnreadable = false
        for pid in started { Darwin.kill(pid, SIGKILL) }
        started = []
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func spawn(_ script: String) throws -> TeamSpawned {
        let spawned = try TeamSpawn.suspended(path: "/bin/sh", arguments: ["-c", script], environment: [:], directory: root.path,
                                              stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
        started.append(spawned.pid)
        Darwin.kill(spawned.pid, SIGCONT)
        return spawned
    }

    private func recordSignals() -> SignalLog {
        let log = SignalLog()
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        return log
    }

    // MARK: 1 — the hold ends exactly when the child is reaped

    func testReapingWaitsForASignalUnderTheHold() async throws {
        let child = try spawn("exit 0")
        let ended = TeamExit()
        child.onExit { ended.finish($0) }
        _ = await ended.wait(timeout: .seconds(5))
        // A signal under the hold takes 300 ms; the reaping waits for it.
        let inside = Counter()
        let holding = Task.detached {
            child.whileHeld { held in
                if held { inside.increment() }
                usleep(300_000)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let before = ContinuousClock.now
        await Task.detached { child.release() }.value
        XCTAssertGreaterThan(ContinuousClock.now - before, .milliseconds(150), "release waited for the signal in progress")
        await holding.value
        XCTAssertEqual(inside.value, 1)
        // Reaped: no right to the group any more.
        XCTAssertFalse(child.whileHeld { $0 })
        let log = recordSignals()
        TeamProcesses.signal(child.identity, SIGKILL, holder: child)
        XCTAssertTrue(log.calls.isEmpty, "after reaping, nothing goes to its number or group")
    }

    // MARK: 2 — PID and start time from one read; checked again before each signal

    func testIdentitiesComeFromOneReadAndAreCheckedBeforeEachSignal() throws {
        let leader = try spawn("sleep 30 & wait")
        var kids: [ProcessIdentity] = []
        for _ in 0..<100 where kids.isEmpty {
            kids = TeamProcesses.descendantIdentities(of: leader.pid) ?? []
            if kids.isEmpty { usleep(20_000) }
        }
        let kid = try XCTUnwrap(kids.first)
        XCTAssertEqual(TeamProcesses.startTime(kid.pid), kid.startTime, "the pair is the process's own")
        // A number now held by another process (another start time) gets no signal.
        let stale = ProcessIdentity(pid: kid.pid, startTime: kid.startTime &+ 1)
        let log = recordSignals()
        TeamProcesses.signal(TeamProcessStart(pid: 0, pgid: 0, startTime: 0), SIGKILL, also: TeamPidSet([stale]))
        XCTAssertTrue(log.calls.isEmpty)
        TeamProcesses.signal(TeamProcessStart(pid: 0, pgid: 0, startTime: 0), SIGKILL, also: TeamPidSet([kid]))
        XCTAssertEqual(log.calls.map(\.pid), [kid.pid])
    }

    // MARK: 4 — a read that fails is "unknown", never "gone"

    func testUnreadableTableIsNeverGone() async throws {
        let leader = try spawn("sleep 30")
        let seen = TeamPidSet([ProcessIdentity(pid: leader.pid, startTime: leader.startTime)])
        TeamProcesses.tableUnreadable = true
        XCTAssertEqual(TeamProcesses.liveness(leader.identity.identity), .unknown)
        XCTAssertEqual(seen.states, [.unknown])
        XCTAssertEqual(TeamProcesses.liveness(TeamProcessStart(pid: 999_995, pgid: 999_995, startTime: 1), also: seen), .unknown)
        XCTAssertEqual(TeamProcesses.liveness(leader.identity, holder: leader), .unknown)
        let log = recordSignals()
        let gone = await TeamProcesses.stop(TeamProcessStart(pid: 999_995, pgid: 999_995, startTime: 1), also: seen) == .stopped
        XCTAssertFalse(gone, "a stop that cannot see is not confirmed")
        XCTAssertTrue(log.calls.isEmpty)
        // Recovery: unknown, the agent blocked.
        TeamProcesses.tableUnreadable = false
        let f = try ExecutorFixture(root: root.appendingPathComponent("f4"), runner: RecordingRunner())
        let row = try spentRun(f, pid: leader.pid, startTime: leader.startTime)
        TeamProcesses.tableUnreadable = true
        let r = recovery(f)
        await r.check()
        XCTAssertEqual(r.stuck.map(\.runId), [row.runId])
        XCTAssertNil(try f.journal.run(row.runId)?.processesGoneAt)
    }

    // MARK: 3 — the stop's result is kept: in the launcher, the journal and recovery

    func testUnconfirmedStopKeepsTheRowBlocked() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f3"), runner: ReportingRunner())
        // The runner could not confirm its processes gone.
        f.launcher.processesLeft = { _ in TeamPidSet() }
        f.launcher.recovery = recovery(f)
        let approval = try f.approve()
        _ = try? await f.launcher.launch(approvalId: approval.id)
        let row = try XCTUnwrap(try f.journal.runs().first)
        XCTAssertNil(row.outcome, "not confirmed gone: the row stays open")
        XCTAssertNil(row.processesGoneAt)
        f.request = TeamLaunchRequest(requestId: "req-next", prompt: "p", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let next = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: next.id)
            XCTFail("launched")
        } catch TeamLauncher.Failure.blocked {
        } catch { XCTFail("\(error)") }
    }


    // MARK: 6 — "processes gone" is kept: the numbers are not looked at again

    func testConfirmedGoneIsNotCheckedAgain() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f6"), runner: RecordingRunner())
        let row = try spentRun(f, pid: 999_992, startTime: 3)
        let facts = RecordingFacts()
        facts.serverKnown = false
        let r = recovery(f, facts: facts)
        r.find = { _ in [] }
        await r.check()
        let gone1 = await r.confirmGone(row.runId)
        XCTAssertNil(gone1)
        XCTAssertEqual(r.awaitingFact.map(\.runId), [row.runId])
        XCTAssertNotNil(try f.journal.run(row.runId)?.processesGoneAt)
        // The number now belongs to someone else's busy group: not looked at.
        let next = recovery(f, facts: facts)
        next.find = { _ in
            XCTFail("a run confirmed gone is not looked at again")
            return nil
        }
        await next.check()
        XCTAssertEqual(next.awaitingFact.map(\.runId), [row.runId])
        XCTAssertTrue(next.stuck.isEmpty, "the agent is not blocked again")
    }

    // MARK: 7 — a check that cannot be made refuses the launch

    func testUnreadableJournalRefusesTheLaunch() async throws {
        let runner = RecordingRunner()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f7"), runner: runner)
        let approval = try f.approve()
        f.launcher.recovery = recovery(f)
        // A row the journal cannot read.
        try await f.journal.queue.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: """
                INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at)
                VALUES ('bad', 'r', ?, 'a', 'c', 'not a date')
                """, arguments: [approval.id])
        }
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("it launched")
        } catch TeamLauncher.Failure.recoveryFailed {
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertNotNil(f.launcher.recovery?.problem)
        XCTAssertNil(try f.journal.approval(approval.id)?.consumedAt, "the approval stays valid")
    }

    // MARK: 9 — approvals per server, account and organization

    func testApprovalsAreKeptPerOrganization() throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f9"), runner: RecordingRunner())
        let first = try f.approve()
        let other = ChatOrgKey(server: try ChatServerAddress(parsing: "https://other.example.com"), accountId: "acc", orgId: "org")
        let second = try TeamApprovals.approve(request: f.request, agent: f.agent, key: other, generation: "g1", journal: f.journal, now: f.now)
        XCTAssertNotEqual(first.id, second.id, "the same request id on another server is another request")
        XCTAssertEqual(second.key, other)
        XCTAssertEqual(try f.journal.approval(f.key, requestId: f.request.requestId)?.id, first.id)
        XCTAssertEqual(try f.journal.approval(other, requestId: f.request.requestId)?.id, second.id)
        XCTAssertEqual(try TeamApprovals.action(other, requestId: f.request.requestId, state: "approved", journal: f.journal) { _ in false },
                       .start(approvalId: second.id))
    }

    // MARK: 5 — a fact only with the request's state known

    func testFactWaitsForTheRequestsState() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        try files.prepareDirectory()
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let f = try ExecutorFixture(root: root.appendingPathComponent("f5"), runner: RecordingRunner())
        f.journal = try ChatJournal.open(files: files)
        try f.assign(.active)
        await service.recoverRunsAtLaunch()
        try f.journal.finish(f.key, "g1")
        let row = try spentRun(f)
        service.isServerKnown = { _, _ in true }
        service.requestState = { _, _ in nil }
        XCTAssertFalse(service.canChooseFact(for: row), "the request's state is not known: wait")
        service.requestState = { key, id in key == f.key && id == row.requestId ? "running" : nil }
        XCTAssertTrue(service.canChooseFact(for: row))
    }

    // MARK: 10 — the token file that cannot be removed is an error

    func testTokenFileThatStaysIsAnError() throws {
        let files = ChatFiles(directory: root.appendingPathComponent("tok"))
        try files.prepareDirectory()
        let store = ChatDevTokenFile(files: files)
        try store.write("aps_x", account: "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path) }
        XCTAssertThrowsError(try store.delete(account: "a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path)
        XCTAssertNoThrow(try store.delete(account: "a"))
        XCTAssertNoThrow(try store.delete(account: "a"), "already gone is fine")
    }

    // MARK: helpers

    private func spentRun(_ f: ExecutorFixture, pid: pid_t? = nil, startTime: UInt64? = nil) throws -> ChatRunRecord {
        f.request = TeamLaunchRequest(requestId: "req-\(UUID().uuidString.prefix(6))", prompt: "p", context: nil, callerName: "M",
                                      callerProject: nil, conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, pid: pid, pgid: pid, processStartedAt: startTime, startedAt: f.now)
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        return row
    }

    private func recovery(_ f: ExecutorFixture, facts: RecordingFacts = RecordingFacts()) -> TeamRunRecovery {
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        r.facts = facts
        retained.append(facts)
        return r
    }
    private var retained: [RecordingFacts] = []
}
