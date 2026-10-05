import Darwin
import XCTest
@testable import AgentPadKit

/// Seventh client review (review-client-c7.md) and the decision after it:
/// recovery after a crash is the owner's; in a running app a stop is
/// confirmed only by a complete look; generation and server state that are
/// not known make runs and facts wait; leftovers of any mode block.
@MainActor
final class TeamReviewC7Tests: XCTestCase {
    private var root: URL!
    private var started: [pid_t] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c7-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TeamProcesses.wholeTableUnreadable = false
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

    // MARK: 2 — a look that failed is not an empty tree

    func testFailedLookForDescendantsIsNeverGone() async throws {
        let leader = try TeamSpawn.suspended(path: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:], directory: root.path,
                                             stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
        started.append(leader.pid)
        let ended = TeamExit()
        leader.onExit { ended.finish($0) }
        Darwin.kill(leader.pid, SIGCONT)
        _ = await ended.wait(timeout: .seconds(5))
        let seen = TeamPidSet()
        // The descendants cannot be read; the leader and its group can.
        TeamProcesses.wholeTableUnreadable = true
        TeamProcesses.signal(leader.identity, SIGTERM, also: seen, holder: leader)
        XCTAssertTrue(seen.isIncomplete)
        XCTAssertEqual(TeamProcesses.liveness(leader.identity, also: seen, holder: leader), .unknown,
                       "what the look missed cannot be confirmed gone")
        TeamProcesses.wholeTableUnreadable = false
        let gone = await TeamProcesses.stop(leader, also: seen) == .stopped
        XCTAssertFalse(gone)
        leader.release()
    }

    // MARK: 5 — one number, two identities

    func testANumberSeenTwiceIsTwoProcesses() {
        let first = ProcessIdentity(pid: 4242, startTime: 1)
        let second = ProcessIdentity(pid: 4242, startTime: 2)
        let seen = TeamPidSet([first])
        seen.insert([second])
        XCTAssertEqual(Set(seen.identities), [first, second])
    }

    // MARK: 8 — the generation read as one, and not known = wait

    func testUnknownGenerationMakesTheLaunchWait() async throws {
        let runner = RecordingRunner()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f8"), runner: runner)
        let approval = try f.approve()
        f.generationFails = ChatError.storage("disk")
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("launched")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .generationChanging)
        }
        f.generationFails = nil
        f.pendingGeneration = "g2"
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("launched")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .generationChanging)
        }
        XCTAssertNil(try f.journal.approval(approval.id)?.voidReason, "the approval waits, not void")
        XCTAssertTrue(runner.requests.isEmpty)
        f.pendingGeneration = nil
        _ = try await f.launcher.launch(approvalId: approval.id)
        XCTAssertEqual(runner.requests.count, 1)
    }

    // MARK: 9 — a local stop's fact waits for the server too

    func testLocalStopFactWaitsForTheServer() async throws {
        let script = root.appendingPathComponent("claude").path
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let f = try ExecutorFixture(root: root.appendingPathComponent("f9"), runner: ClaudeCodeRunner(fixturePath: script))
        let facts = RecordingFacts()
        facts.serverKnown = false
        f.launcher.facts = facts
        let recovery = TeamRunRecovery(journal: f.journal) { [weak launcher = f.launcher] in launcher?.isLive($0) ?? false }
        recovery.facts = facts
        f.launcher.recovery = recovery
        let approval = try f.approve()
        let launcher = f.launcher!
        let run = Task { try? await launcher.launch(approvalId: approval.id) }
        try await waitUntil { try f.journal.runs().first?.pid != nil }
        await TeamRunStopper(launcher: launcher).stopAll()
        _ = await run.value
        let row = try XCTUnwrap(try f.journal.runs().first)
        XCTAssertNil(row.outcome, "no fact, no outcome")
        // Y5 confirmed the stop; only its fact waits for the server.
        XCTAssertNotNil(row.processesGoneAt)
        XCTAssertNotNil(row.stopConfirmedAt)
        XCTAssertEqual(row.stopReason, "stopped_by_owner")
        XCTAssertTrue(facts.facts.isEmpty)
        XCTAssertTrue(recovery.blocked.isEmpty)
        XCTAssertEqual(recovery.awaitingFact.map(\.runId), [row.runId], "the server's state is not known: the fact waits")
        facts.serverKnown = true
        await recovery.check()
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .stoppedLocally)
        XCTAssertEqual(facts.facts.map(\.reason), ["stopped_by_owner"])
    }

    // MARK: 11 — processes left over in any mode block the agent

    func testLeftOverOfAnyModeBlocksUntilTheOwnerSaysGone() async throws {
        let runner = RecordingRunner()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f11"), runner: runner)
        let recovery = TeamRunRecovery(journal: f.journal) { _ in false }
        recovery.facts = RecordingFacts()
        f.launcher.recovery = recovery
        let agentId = f.agent.id.uuidString.lowercased()
        // A direct run whose stop was not confirmed: no journal row.
        let leader = TeamProcessStart(pid: 999_991, pgid: 999_991, startTime: 1)
        TeamProcesses.shared.add(leader, agentId: agentId)
        TeamProcesses.shared.markLeftOver(leader)
        defer { TeamProcesses.shared.remove(leader) }
        let approval = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("launched")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .blocked(agentId: agentId, pid: nil))
        }
        // The owner: "They Are Gone" (the leader is gone): no longer in the way.
        XCTAssertNil(TeamProcesses.shared.confirmGone(leader))
        XCTAssertFalse(TeamProcesses.shared.blocks(agentId: agentId))
        _ = try await f.launcher.launch(approvalId: approval.id)
        XCTAssertEqual(runner.requests.count, 1)
    }

    // MARK: 1–5 — after a crash nothing is signalled by itself

    func testNothingIsSignalledAfterACrashWithoutTheOwner() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f1"), runner: RecordingRunner())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        started.append(p.processIdentifier)
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        XCTAssertTrue(try f.journal.consume(approval, run: ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, pid: p.processIdentifier, pgid: p.processIdentifier,
            processStartedAt: TeamProcesses.startTime(p.processIdentifier), startedAt: f.now)))
        let log = SignalLog()
        let saved = TeamProcesses.sendSignal
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        defer { TeamProcesses.sendSignal = saved }
        let recovery = TeamRunRecovery(journal: f.journal) { _ in false }
        recovery.facts = RecordingFacts()
        await recovery.check()
        await TeamRunStopper(launcher: f.launcher).stopAll()
        XCTAssertTrue(log.calls.isEmpty, "no signal without the owner's press")
        XCTAssertEqual(recovery.blocked.first?.found?.map(\.pid), [p.processIdentifier])
        XCTAssertNil(try f.journal.run(params.runId)?.outcome)
    }
}
