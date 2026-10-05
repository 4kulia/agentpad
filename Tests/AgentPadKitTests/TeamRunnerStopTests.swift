import Darwin
import XCTest
@testable import AgentPadKit

/// Y5 (DESIGN-Y5): a stop says how it ended — stopped, still alive (which),
/// or unknown — and "no process known" alone is never "stopped". Real child
/// processes, own groups only; waits shortened.
@MainActor
final class TeamRunnerStopTests: XCTestCase {
    private var root: URL!
    private var started: [pid_t] = []
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("y5-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
    }

    override func tearDown() async throws {
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        TeamProcesses.tableUnreadable = false
        TeamProcesses.tableHang = nil
        TeamProcesses.lookupHook = nil
        for pid in started { Darwin.kill(pid, SIGKILL) }
        started = []
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A leader, suspended in a group of its own, then let go on.
    private func start(_ script: String) throws -> TeamSpawned {
        let spawned = try TeamSpawn.suspended(path: "/bin/sh", arguments: ["-c", script], environment: [:],
                                              directory: root.path, stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
        started.append(spawned.pid)
        Darwin.kill(spawned.pid, SIGCONT)
        return spawned
    }

    /// The first descendant of `leader` matching `where`, once it is there.
    private func descendant(of leader: TeamSpawned, _ test: @escaping (pid_t) -> Bool = { _ in true }) async throws -> ProcessIdentity {
        var found: ProcessIdentity?
        try await waitUntil {
            found = TeamProcesses.descendantIdentities(of: leader.pid)?.first { test($0.pid) }
            return found != nil
        }
        let identity = try XCTUnwrap(found)
        started.append(identity.pid)
        return identity
    }

    private func gone(_ identity: ProcessIdentity) -> Bool { TeamProcesses.liveness(identity) == .gone }

    // 1, 2 — SIGTERM, then SIGKILL

    func testLeaderThatEndsOnTerminateIsStopped() async throws {
        let leader = try start("exec sleep 30")
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .seconds(2), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped)
        leader.release()
    }

    func testLeaderThatIgnoresTerminateIsStoppedByKill() async throws {
        let leader = try start("trap '' TERM; while :; do sleep 0.1; done")
        try await Task.sleep(for: .milliseconds(200))
        let begin = ContinuousClock.now
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .milliseconds(500), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - begin, .milliseconds(500), "SIGKILL only after the grace")
        leader.release()
    }

    // 3, 4, 5 — the group, a descendant out of it, an early leader

    func testGrandchildInTheGroupIsStopped() async throws {
        let leader = try start("sleep 30 & wait")
        let child = try await descendant(of: leader)
        XCTAssertEqual(getpgid(child.pid), leader.pid)
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .seconds(2), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped)
        XCTAssertTrue(gone(child))
        leader.release()
    }

    func testDescendantInASessionOfItsOwnIsStopped() async throws {
        let leader = try start("perl -MPOSIX -e 'POSIX::setsid(); sleep 30' & wait")
        let child = try await descendant(of: leader) { getsid($0) == $0 }
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .seconds(2), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped)
        XCTAssertTrue(gone(child))
        leader.release()
    }

    func testMemberOfAnEndedHeldLeadersGroupIsStopped() async throws {
        let pidFile = root.appendingPathComponent("member").path
        let leader = try start("sleep 30 & echo $! > '\(pidFile)'; sleep 0.3; exit 0")
        try await waitUntil { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } != nil }
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        started.append(pid)
        let child = ProcessIdentity(pid: pid, startTime: try XCTUnwrap(TeamProcesses.startTime(pid)))
        let ended = TeamExit()
        leader.onExit { ended.finish($0) }
        _ = await ended.wait(timeout: .seconds(5))
        XCTAssertNotEqual(TeamProcesses.liveness(child), .gone, "the group's member outlives its leader")
        // Not released: the group's number is still the run's.
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .seconds(2), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped)
        XCTAssertTrue(gone(child))
        leader.release()
    }

    // 6 — a process that cannot be stopped is named

    func testProcessThatCannotBeStoppedIsNamed() async throws {
        let leader = try start("perl -MPOSIX -e 'POSIX::setsid(); sleep 30' & wait")
        let child = try await descendant(of: leader) { getsid($0) == $0 }
        let real = TeamProcesses.sendSignal
        TeamProcesses.sendSignal = { pid, sig, group in if pid != child.pid { real(pid, sig, group) } }
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .milliseconds(300), killWait: .milliseconds(300))
        XCTAssertEqual(outcome, .stillAlive([child]))
        leader.release()
    }

    // A look that failed is never "stopped" (DESIGN-Y5 2.1, 3)

    func testFailedLookIsUnknownNotStopped() async throws {
        let leader = try start("exec sleep 30")
        let seen = TeamPidSet()
        seen.markIncomplete()
        let outcome = await TeamProcesses.stop(leader, also: seen, grace: .seconds(2), killWait: .seconds(1))
        guard case .unknown = outcome else { return XCTFail("\(outcome)") }
        leader.release()
    }

    // 7 — the known gap: out of the tree and the group before any look

    func testOrphanThatLeftBeforeAnyLookIsTheKnownGap() async throws {
        // Double fork with a new session; its parent ends at once. Nothing of
        // the run links to it any more (KNOWN-ISSUES, Y5): the processes'
        // outcome cannot see it. The run's open output does (TeamRunStop).
        let pidFile = root.appendingPathComponent("orphan").path
        let leader = try start("perl -MPOSIX -e 'exit if fork; POSIX::setsid(); exit if fork; open(my $f, \">\", \"\(pidFile)\"); print $f $$; close $f; close STDOUT; close STDERR; sleep 30'; sleep 30")
        try await waitUntil { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0) } != nil }
        let orphan = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile, encoding: .utf8)))
        started.append(orphan)
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .seconds(2), killWait: .seconds(1))
        XCTAssertEqual(outcome, .stopped, "the gap, as it is: recorded in KNOWN-ISSUES")
        XCTAssertNotNil(TeamProcesses.startTime(orphan), "the orphan is still there")
        leader.release()
    }

    // 12 — the tree's root is checked in the same read

    func testTreeIsTakenOnlyUnderItsOwnRoot() {
        let table = [
            TeamProcesses.TableEntry(pid: 100, ppid: 1, startTime: 5),
            TeamProcesses.TableEntry(pid: 200, ppid: 100, startTime: 6),
            TeamProcesses.TableEntry(pid: 300, ppid: 200, startTime: 7),
        ]
        XCTAssertEqual(TeamProcesses.tree(table, root: 100, rootStart: 5),
                       [ProcessIdentity(pid: 200, startTime: 6), ProcessIdentity(pid: 300, startTime: 7)])
        XCTAssertEqual(TeamProcesses.tree(table, root: 100, rootStart: 4), [], "another process has the number now")
        XCTAssertEqual(TeamProcesses.tree(table, root: 150, rootStart: 5), [], "the root is gone")
    }

    // MARK: the run's one stop (DESIGN-Y5 2.2)

    private let quick = TeamRunStop.Timing(grace: .milliseconds(300), killWait: .milliseconds(300), output: .milliseconds(500))

    /// A fake `claude`: the script, run as the run's leader.
    private func fakeClaude(_ body: String) throws -> String {
        let path = root.appendingPathComponent("claude-\(UUID().uuidString.prefix(6))").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Runs `script` as a run, cancels it once its process exists, and
    /// returns the error, the leader and how long the answer took.
    private func cancelledRun(_ script: String, after: Duration = .milliseconds(300),
                              ready: @escaping @MainActor () -> Bool = { true },
                              meanwhile: @escaping @Sendable () -> Void = {}) async throws -> (Error?, TeamProcessStart?, Duration) {
        let runner = ClaudeCodeRunner(fixturePath: try fakeClaude(script), stopTiming: quick)
        let agent = TeamPublishedAgent(name: "y5", description: "d", folder: root.path, access: .read)
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: UUID().uuidString, resume: false,
                                     callerName: "M", callerProject: nil)
        let box = TeamStartBox()
        let task = Task { try await runner.run(request, onActivity: { _ in }, onProcessStarted: { box.set($0) }) }
        try await waitUntil { box.get() != nil }
        if let leader = box.get() { started.append(leader.pid) }
        try await Task.sleep(for: after)
        // What the case needs in place before the cancel (not a fixed time:
        // under load a fork comes late).
        try await waitUntil(ready)
        meanwhile()
        let begin = ContinuousClock.now
        task.cancel()
        var failure: Error?
        do { _ = try await task.value } catch { failure = error }
        let took = ContinuousClock.now - begin
        if let leader = box.get() { TeamProcesses.shared.remove(leader) }
        return (failure, box.get(), took)
    }

    // 8 — a leader that does not die: the answer still comes in time

    func testCancelledRunAnswersInTimeWhenItsLeaderDoesNotDie() async throws {
        TeamProcesses.sendSignal = { _, _, _ in }
        let (error, leader, took) = try await cancelledRun("trap '' TERM; exec sleep 30")
        let start = try XCTUnwrap(leader)
        guard case TeamRunnerError.stopped(.stillAlive(let left))? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(left, [start.identity])
        XCTAssertLessThan(took, quick.maxResponse, "not the run's time limit")
    }

    // 9 — the table cannot be read: unknown, in time

    func testCancelledRunIsUnknownWhenItsProcessesCannotBeLookedAt() async throws {
        let (error, _, took) = try await cancelledRun("exec sleep 30", meanwhile: { TeamProcesses.tableUnreadable = true })
        TeamProcesses.tableUnreadable = false
        guard case TeamRunnerError.stopped(.unknown)? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        XCTAssertLessThan(took, quick.maxResponse)
    }

    // 10 — output held open by a process out of sight: not stopped

    func testRunWhoseOutputStaysOpenIsNotStopped() async throws {
        let pidFile = root.appendingPathComponent("holder").path
        let (error, _, _) = try await cancelledRun(
            "perl -MPOSIX -e 'exit if fork; POSIX::setsid(); exit if fork; open(my $f, \">\", \"\(pidFile)\"); print $f $$; close $f; close STDOUT; sleep 30'; exec sleep 30",
            ready: { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0) } != nil })
        if let holder = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0) }) { started.append(holder) }
        guard case TeamRunnerError.stopped(.unknown(let why))? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(why, "the run's output is still open")
    }

    // A plain cancel of a run that ends on SIGTERM: stopped.

    func testCancelledRunThatEndsIsStopped() async throws {
        let (error, _, _) = try await cancelledRun("exec sleep 30")
        guard case TeamRunnerError.stopped(.stopped)? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
    }

    // 13 — begun from two places at once: one stop, one outcome

    func testStopBegunTwiceStopsOnce() async throws {
        let leader = try start("exec sleep 30")
        let log = SignalLog()
        let real = TeamProcesses.sendSignal
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group); real(pid, sig, group) }
        let stop = TeamRunStop(spawned: leader, seen: TeamPidSet(), output: [], timing: quick)
        async let first = stop.outcome()
        stop.begin()
        async let second = stop.outcome()
        let (a, b) = await (first, second)
        XCTAssertEqual(a, .stopped)
        XCTAssertEqual(a, b)
        XCTAssertEqual(log.calls.filter { $0.sig == SIGTERM && $0.group }.count, 1)
        leader.release()
    }

    // 11 — a failed look, then the owner's word: unblocked, outcome kept

    func testOwnerConfirmsGoneAfterAFailedLookAndTheOutcomeStaysUnknown() async throws {
        let processes = TeamProcesses()
        let leader = try start("exec sleep 30")
        let seen = TeamPidSet()
        processes.add(leader.identity, seen: seen, spawned: leader, agentId: "y5-agent")
        // The look fails during the stop: the automatic outcome is unknown.
        TeamProcesses.tableUnreadable = true
        let outcome = await TeamProcesses.stop(leader, also: seen, grace: .milliseconds(300), killWait: .milliseconds(300))
        guard case .unknown = outcome else { return XCTFail("\(outcome)") }
        seen.markIncomplete()
        processes.markLeftOver(leader.identity)
        XCTAssertTrue(processes.blocks(agentId: "y5-agent"))
        XCTAssertEqual(processes.confirmGone(leader.identity), "AgentPad could not look for its processes; try again.",
                       "while it still cannot look, the owner's word is not taken")
        // Reading works again and the processes are gone.
        TeamProcesses.tableUnreadable = false
        try await waitUntil { TeamProcesses.liveness(leader.identity) == .gone }
        guard case .unknown = TeamProcesses.outcome(leader.identity, also: seen) else {
            return XCTFail("the automatic check does not forget the failed look")
        }
        XCTAssertNil(processes.confirmGone(leader.identity), "the owner's word unblocks")
        XCTAssertFalse(processes.blocks(agentId: "y5-agent"))
        leader.release()
    }

    // MARK: live — a real claude whose MCP server starts processes

    /// A stdio MCP server (python) that first runs `spawn`, then answers.
    private func mcpServer(_ spawn: String) throws -> String {
        let path = root.appendingPathComponent("mcp-\(UUID().uuidString.prefix(6)).py").path
        let code = """
        import json, os, subprocess, sys
        \(spawn)
        for line in sys.stdin:
            req = json.loads(line)
            if "id" not in req: continue
            m = req.get("method")
            res = {"protocolVersion": req.get("params", {}).get("protocolVersion", "2024-11-05"),
                   "capabilities": {"tools": {}}, "serverInfo": {"name": "y5", "version": "1"}} if m == "initialize" \\
                  else {"tools": []} if m == "tools/list" else {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": res}) + "\\n"); sys.stdout.flush()
        """
        try code.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func liveRun(spawn: String, pidFile: String) async throws -> (Error?, pid_t, Duration) {
        guard ProcessInfo.processInfo.environment["AGENTPAD_Y5_LIVE"] == "1", let claude = ClaudeCodeRunner.locateClaude() else {
            throw XCTSkip("set AGENTPAD_Y5_LIVE=1 to run with the real claude")
        }
        let server = try mcpServer(spawn)
        let config = "{\"mcpServers\":{\"y5\":{\"type\":\"stdio\",\"command\":\"/usr/bin/python3\",\"args\":[\"\(server)\"]}}}"
        var runner = ClaudeCodeRunner(claudePath: claude)
        runner.extraArguments = ["--mcp-config", config]
        var agent = TeamPublishedAgent(name: "y5", description: "d", folder: root.path, access: .read)
        agent.model = "haiku"
        let request = TeamRunRequest(agent: agent, prompt: "Count slowly from 1 to 200, one number per line.",
                                     sessionId: UUID().uuidString.lowercased(), resume: false, callerName: "M", callerProject: nil)
        let box = TeamStartBox()
        let task = Task { try await runner.run(request, onActivity: { _ in }, onProcessStarted: { box.set($0) }) }
        try await waitUntil { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0) } != nil }
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile, encoding: .utf8)))
        started.append(pid)
        if let leader = box.get() { started.append(leader.pid) }
        let begin = ContinuousClock.now
        task.cancel()
        var failure: Error?
        do { _ = try await task.value } catch { failure = error }
        if let leader = box.get() { TeamProcesses.shared.remove(leader) }
        return (failure, pid, ContinuousClock.now - begin)
    }

    func testLiveMCPGrandchildInTheGroupIsStopped() async throws {
        let pidFile = root.appendingPathComponent("grandchild").path
        let (error, grandchild, took) = try await liveRun(
            spawn: "p = subprocess.Popen(['sleep', '300']); open('\(pidFile)', 'w').write(str(p.pid))", pidFile: pidFile)
        guard case TeamRunnerError.stopped(.stopped)? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        XCTAssertNil(TeamProcesses.startTime(grandchild), "the MCP server's child is gone")
        XCTAssertLessThan(took, TeamRunStop.Timing.standard.maxResponse)
    }

    /// The residual risk (KNOWN-ISSUES, Y5): an orphan holding only the MCP
    /// channel, out of the group and the tree — what happens is recorded.
    func testLiveMCPOrphanOutOfSightIsTheKnownGap() async throws {
        let pidFile = root.appendingPathComponent("orphan").path
        let spawn = "pid = os.fork()\nif pid == 0:\n    os.setsid()\n    if os.fork() == 0:\n        open('\(pidFile)', 'w').write(str(os.getpid()))\n        os.execvp('sleep', ['sleep', '300'])\n    os._exit(0)\nos.waitpid(pid, 0)"
        let (error, orphan, _) = try await liveRun(spawn: spawn, pidFile: pidFile)
        guard case TeamRunnerError.stopped(let outcome)? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        print("Y5 live, orphan out of sight: outcome \(outcome), orphan alive: \(TeamProcesses.startTime(orphan) != nil)")
        XCTAssertNotNil(TeamProcesses.startTime(orphan), "the gap, as it is: recorded in KNOWN-ISSUES")
    }

    // MARK: review Y5 round 1

    /// p1-1, p2-2: a left-over whose output was never seen closed is not
    /// cleared by "Stop These Processes", only by the owner's word.
    func testLeftOverWithOpenOutputIsNotClearedByStoppingItsProcesses() async throws {
        let processes = TeamProcesses()
        let leader = try start("exec sleep 30")
        let seen = TeamPidSet()
        processes.add(leader.identity, seen: seen, spawned: leader, agentId: "y5-open")
        processes.markLeftOver(leader.identity, outputOpen: true)
        let outcome = await processes.stopLeftOver(leader.identity)
        guard case .unknown = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(processes.blocks(agentId: "y5-open"), "known processes gone is not enough")
        XCTAssertNil(processes.confirmGone(leader.identity), "the owner's word clears it")
        XCTAssertFalse(processes.blocks(agentId: "y5-open"))
    }

    /// p2-1: a read that hangs does not hold the answer past the bound.
    func testHungLookStillAnswersInTime() async throws {
        let begin = ContinuousClock.now
        let (error, _, took) = try await cancelledRun("exec sleep 30", meanwhile: { TeamProcesses.tableHang = 3 })
        TeamProcesses.tableHang = nil
        guard case TeamRunnerError.stopped(.unknown)? = error as? TeamRunnerError else { return XCTFail("\(String(describing: error))") }
        XCTAssertLessThan(took, quick.maxResponse + .milliseconds(700))
        XCTAssertLessThan(ContinuousClock.now - begin, .seconds(10), "taking the entry away does not wait for the hung look")
    }

    /// p1-3: a look that failed in the middle of the stop is not forgotten
    /// when later looks work again.
    func testLookThatFailedMidStopIsRemembered() async throws {
        let leader = try start("trap '' TERM; while :; do sleep 0.1; done")
        try await Task.sleep(for: .milliseconds(200))
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            TeamProcesses.tableUnreadable = true
            try? await Task.sleep(for: .milliseconds(250))
            TeamProcesses.tableUnreadable = false
        }
        let outcome = await TeamProcesses.stop(leader, also: TeamPidSet(), grace: .milliseconds(800), killWait: .milliseconds(500))
        guard case .unknown = outcome else { return XCTFail("\(outcome)") }
        leader.release()
    }

    /// p2-3: a leader that ends after its entry is gone is reaped, not left a zombie.
    func testLeaderEndingAfterItsEntryIsGoneIsReaped() async throws {
        TeamProcesses.sendSignal = { _, _, _ in }
        let (_, start, _) = try await cancelledRun("trap '' TERM; exec sleep 30")
        let leader = try XCTUnwrap(start)
        // cancelledRun took the entry away; the leader still runs, unreaped.
        XCTAssertEqual(Darwin.kill(leader.pid, 0), 0)
        Darwin.kill(leader.pid, SIGKILL)
        try await waitUntil { Darwin.kill(leader.pid, 0) == -1 && errno == ESRCH }
    }

    // MARK: review Y5 round 2

    /// 1: a process the watcher added late, still alive, is not "stopped".
    func testProcessAddedLateByTheWatcherIsNotStopped() async throws {
        let leader = try start("exec sleep 30")
        let other = try start("exec sleep 30")
        let seen = TeamPidSet()
        let stop = TeamRunStop(spawned: leader, seen: seen, output: [], timing: quick,
                               beforeVerdict: { seen.insert([other.identity.identity]) })
        let outcome = await stop.outcome()
        XCTAssertEqual(outcome, .stillAlive([other.identity.identity]))
        leader.release()
    }

    /// 2: "Stop These Processes" and "They Are Gone" answer in time while
    /// a look hangs and an earlier stop still holds the leader's lock.
    func testLeftOverActionsAnswerInTimeWhileALookHangs() async throws {
        let processes = TeamProcesses()
        let leader = try start("exec sleep 30")
        processes.add(leader.identity, seen: TeamPidSet(), spawned: leader, agentId: "y5-hang")
        processes.markLeftOver(leader.identity)
        TeamProcesses.tableHang = 3
        for _ in 0..<2 {
            let begin = ContinuousClock.now
            let outcome = await processes.stopLeftOver(leader.identity, timing: quick)
            guard case .unknown = outcome else { return XCTFail("\(outcome)") }
            XCTAssertLessThan(ContinuousClock.now - begin, quick.maxResponse + .milliseconds(500))
        }
        let begin = ContinuousClock.now
        let answer = await processes.confirmGoneInTime(leader.identity, within: .seconds(1))
        XCTAssertEqual(answer, "AgentPad could not look for its processes in time; try again.")
        XCTAssertLessThan(ContinuousClock.now - begin, .milliseconds(1500))
        XCTAssertTrue(processes.blocks(agentId: "y5-hang"))
        TeamProcesses.tableHang = nil
    }

    /// 3: one process's failed read is remembered even when another is alive.
    func testFailedReadIsRememberedBesideAnAliveOne() throws {
        let leader = try start("exec sleep 30")
        let other = try start("exec sleep 30")
        let seen = TeamPidSet([other.identity.identity])
        var failed = false
        TeamProcesses.lookupHook = { pid in
            guard pid == other.pid, !failed else { return nil }
            failed = true
            return .failure(POSIXError(.EIO))
        }
        XCTAssertEqual(TeamProcesses.liveness(leader.identity, also: seen), .alive)
        XCTAssertTrue(failed)
        XCTAssertTrue(seen.isIncomplete, "the alive leader does not hide the other's failed read")
        TeamProcesses.lookupHook = nil
        leader.release()
        other.release()
    }

    /// 4: nothing to stop is never "stopped".
    func testNothingToStopIsNotStopped() async throws {
        let processes = TeamProcesses()
        let leader = try start("exec sleep 30")
        guard case .unknown = await processes.stopLeftOver(leader.identity) else { return XCTFail("no entry") }
        processes.add(leader.identity, seen: TeamPidSet(), spawned: leader, agentId: "y5-live")
        guard case .unknown = await processes.stopLeftOver(leader.identity) else { return XCTFail("a live run's entry") }
        processes.remove(leader.identity)
    }
}
