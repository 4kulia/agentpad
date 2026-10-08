import AgentPadHookKit
import Darwin
import XCTest
@testable import AgentPadKit

/// Fourth client review (review-client-c4.md): process identity before every
/// signal, the registry closed at quit, recovery off the main actor, hook order.
@MainActor
final class TeamReviewC4Tests: XCTestCase {
    private var root: URL!
    private var started: [pid_t] = []
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c4-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
    }

    override func tearDown() async throws {
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        for pid in started {
            Darwin.kill(pid, SIGKILL)
            killpg(pid, SIGKILL)
        }
        started = []
        try? FileManager.default.removeItem(at: root)
    }

    /// Records signals instead of sending them.
    private func recordSignals() -> SignalLog {
        let log = SignalLog()
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        return log
    }

    /// A process leading its own group, as a run's `claude` does.
    private func groupLeader(_ script: String = "sleep 30") throws -> TeamSpawned {
        let spawned = try TeamSpawn.suspended(path: "/bin/sh", arguments: ["-c", script], environment: [:], directory: root.path,
                                              stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
        started.append(spawned.pid)
        Darwin.kill(spawned.pid, SIGCONT)
        return spawned
    }

    // MARK: 1, 4 — signals only to confirmed processes

    /// C4-1: a process that does not lead a group is never signalled as a
    /// group (its PID would name someone else's group, or none); numbers of 1
    /// or less are never signalled.
    func testGroupSignalOnlyForAGroupOurLeaderLeads() throws {
        // A process inside another's group: its PID names no group of its own.
        let outer = try groupLeader("sleep 30 & wait")
        var inner: pid_t?
        for _ in 0..<100 where inner == nil {
            inner = TeamProcesses.descendants(of: outer.pid).first
            if inner == nil { usleep(20_000) }
        }
        let p = try XCTUnwrap(inner)
        XCTAssertNotEqual(getpgid(p), p, "the situation of the finding")
        let log = recordSignals()
        TeamProcesses.signal(.of(p), SIGTERM)
        XCTAssertFalse(log.calls.contains { $0.group }, "no group signal: the PID leads no group")
        XCTAssertTrue(log.calls.contains { $0.pid == p && !$0.group }, "the process itself, confirmed, is signalled")

        let leader = try groupLeader()
        log.clear()
        TeamProcesses.signal(leader.identity, SIGTERM)
        XCTAssertTrue(log.calls.contains { $0.pid == leader.pid && $0.group }, "our own group is signalled as one")

        log.clear()
        for pid in [pid_t(-1), 0, 1] { TeamProcesses.signal(TeamProcessStart(pid: pid, pgid: pid, startTime: 0), SIGKILL) }
        XCTAssertEqual(log.calls.count, 0)
        XCTAssertFalse(TeamProcesses.shared.add(TeamProcessStart(pid: -1, pgid: -1, startTime: 0)))
        XCTAssertFalse(TeamProcesses.shared.add(TeamProcessStart(pid: 1, pgid: 1, startTime: 0)))
    }

    /// C4-4: a number now held by another process (another start time) gets
    /// no signal, and is no run's leader any more.
    func testReusedNumberGetsNoSignal() throws {
        let leader = try groupLeader()
        let log = recordSignals()
        let stale = TeamProcessStart(pid: leader.pid, pgid: leader.pid, startTime: leader.startTime &+ 1)
        TeamProcesses.signal(stale, SIGKILL)
        XCTAssertEqual(log.calls.count, 0, "the start time does not match: another process")
        XCTAssertFalse(TeamProcesses.alive(stale))

        let registry = TeamProcesses()
        XCTAssertTrue(registry.add(stale))
        XCTAssertEqual(registry.runs().map(\.leader), [nil], "a root whose number was given again leads no run")
        XCTAssertTrue(registry.add(leader.identity))
        XCTAssertEqual(registry.runs().compactMap(\.leader), [leader.pid], "two entries: the stale one leads nothing")
    }

    // MARK: 2 — nothing registered after quit began

    func testRegistryClosedByKillAll() throws {
        let registry = TeamProcesses()
        let leader = try groupLeader()
        XCTAssertTrue(registry.add(leader.identity))
        let log = recordSignals()
        registry.killAll()
        XCTAssertTrue(log.calls.contains { $0.pid == leader.pid && $0.sig == SIGKILL })
        let late = try groupLeader()
        XCTAssertFalse(registry.add(late.identity), "a run starting after quit began is refused")
        XCTAssertTrue(registry.runs().allSatisfy { $0.leader != late.pid })
    }

    // MARK: 14 — recovery waits off the main actor, one check at a time

    func testStoppingLeftProcessesDoesNotHoldTheMainActor() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f14"), runner: RecordingRunner())
        // A process that ignores SIGTERM: stopping it waits the whole grace.
        let leader = try groupLeader("trap '' TERM; sleep 30")
        try await Task.sleep(for: .milliseconds(100))
        let row = try spentRun(f, pid: leader.pid, startTime: leader.startTime)
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        let facts = RecordingFacts()
        r.facts = facts
        r.stopGrace = .seconds(1)
        await r.check()
        let stopping = Task { await r.stopProcesses(row.runId) }
        var worst: Duration = .zero
        let clock = ContinuousClock()
        for _ in 0..<20 {
            let before = clock.now
            try await Task.sleep(for: .milliseconds(50))
            worst = max(worst, clock.now - before)
        }
        XCTAssertLessThan(worst, .milliseconds(500), "the main actor stayed free while the processes were stopped")
        _ = await stopping.value
        XCTAssertFalse(TeamProcesses.isAlive(leader.identity))
        let answer = await r.confirmGone(row.runId)
        XCTAssertNil(answer)
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .executorRestarted)
        XCTAssertEqual(facts.facts.count, 1)
    }

    private func spentRun(_ f: ExecutorFixture, pid: pid_t? = nil, startTime: UInt64? = nil) throws -> ChatRunRecord {
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, pid: pid, pgid: pid, processStartedAt: startTime, startedAt: f.now)
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        return row
    }

    // MARK: 12, 13 — hooks

    /// C4-12: one sender's messages arrive in the order sent, also when the
    /// main queue is busy while they come.
    func testOneSendersHookMessagesKeepTheirOrder() async throws {
        let path = NSTemporaryDirectory() + "agentpad-c4-\(UUID().uuidString.prefix(6)).sock"
        var seen: [String] = []
        let server = HookServer(socketPath: path) { message in
            if case .conversationId(let id, _, _, _) = message { seen.append(id) }
        }
        server.originOf = { _ in .outside }
        server.start()
        defer { server.stop(); unlink(path) }
        let surface = UUID().uuidString
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.3) }
        let sent = await Task.detached { () -> Bool in
            (0..<40).allSatisfy { i in
                AgentPadHookKit.sendPayload(["kind": "conversationId", "surface": surface, "conversationId": "c\(i)"], to: path)
            }
        }.value
        XCTAssertTrue(sent)
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.count < 40, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(seen, (0..<40).map { "c\($0)" })
    }

    /// Y4: a team run's environment carries none of AgentPad's variables.
    func testTeamRunsGetNoAgentPadVariables() {
        setenv("AGENTPAD_SURFACE_ID", "x", 1)
        defer { unsetenv("AGENTPAD_SURFACE_ID") }
        let env = ClaudeCodeRunner.environment(claudePath: "/usr/bin/true", isolateGit: true)
        XCTAssertNil(env["AGENTPAD_SURFACE_ID"])
        XCTAssertTrue(env.keys.allSatisfy { !$0.hasPrefix("AGENTPAD_") })
    }
}

/// Signals recorded instead of sent.
final class SignalLog: @unchecked Sendable {
    struct Call { let pid: pid_t; let sig: Int32; let group: Bool }
    private let lock = NSLock()
    private var all: [Call] = []
    var calls: [Call] { lock.withLock { all } }
    func add(_ pid: pid_t, _ sig: Int32, _ group: Bool) { lock.withLock { all.append(Call(pid: pid, sig: sig, group: group)) } }
    func clear() { lock.withLock { all = [] } }
}
