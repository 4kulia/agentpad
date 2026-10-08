import Darwin
import XCTest
@testable import AgentPadKit

/// Fifth client review (review-client-c5.md) and the narrowing decided after
/// it (CHAT-PLAN-decisions.md, "Упрощение защиты сокета и управления
/// процессами"): identities before a run goes on, no signal without a
/// confirmed leader, recovery facts after the server is known, checks redone
/// after the last wait, Try Again sends, Disconnect only once on disk.
@MainActor
final class TeamReviewC5Tests: XCTestCase {
    private var root: URL!
    private var started: [pid_t] = []
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?
    private var savedLookup: ((pid_t) -> Result<TeamProcesses.ProcessFound?, POSIXError>)?

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c5-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
        savedLookup = TeamSpawn.identityLookup
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        if let savedLookup { TeamSpawn.identityLookup = savedLookup }
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

    private func spawn(_ script: String, directory: String? = nil) throws -> TeamSpawned {
        try TeamSpawn.suspended(path: "/bin/sh", arguments: ["-c", script], environment: [:], directory: directory ?? root.path,
                                stdin: Pipe(), stdout: Pipe(), stderr: Pipe())
    }

    /// `claude` processes (scripts) whose arguments contain `marker`.
    private func running(_ marker: String) -> [pid_t] { pgrep(marker) }

    // MARK: 1 — a group without its confirmed leader is never signalled

    func testLeaderlessGroupGetsNoSignal() throws {
        let log = SignalLog()
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        // A leader that is gone (no such process), its group number still
        // used: nothing is sent, neither to the group nor to the number.
        let gone = TeamProcessStart(pid: 999_998, pgid: 999_998, startTime: 1)
        TeamProcesses.signal(gone, SIGKILL)
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertFalse(TeamProcesses.alive(gone))
    }

    // MARK: 2, 3 — every step of the spawn checked; the identity before it goes on

    func testSpawnPreparationFailureStartsNothing() async throws {
        // A folder whose path is too long for chdir: refused before the process exists.
        let long = "/" + String(repeating: "a", count: 2000)
        let marker = root.appendingPathComponent("ran").path
        XCTAssertThrowsError(try spawn("touch \(marker)", directory: long))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "it never ran anywhere")

        // The runner now rejects an uninspectable folder before spawn preparation.
        let script = root.appendingPathComponent("claude").path
        try "#!/bin/sh\ntouch \(marker)\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: long)
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: UUID().uuidString, resume: false, callerName: "M", callerProject: nil)
        let process = TeamValueBox<TeamProcessStart>()
        do {
            _ = try await ClaudeCodeRunner(fixturePath: script).run(request, onActivity: { _ in }, onProcessStarted: { process.set($0) })
            XCTFail("it started")
        } catch { XCTAssertEqual(error as? ChatAttachmentError, .folders) }
        XCTAssertNil(process.get(), "folder validation must finish before a child is created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testUnreadableIdentityKillsTheChild() async throws {
        TeamSpawn.identityLookup = { _ in .failure(POSIXError(.EIO)) }
        let marker = "c5-3-\(UUID().uuidString)"
        let file = root.appendingPathComponent("ran").path
        XCTAssertThrowsError(try spawn("touch \(file) # \(marker)"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "never continued")
        XCTAssertTrue(running(marker).isEmpty, "and not left behind")
    }

    func testIdentityThatCannotBeRecordedStopsTheRun() async throws {
        let file = root.appendingPathComponent("ran").path
        let script = root.appendingPathComponent("claude").path
        try "#!/bin/sh\ntouch \(file)\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: root.path)
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: UUID().uuidString, resume: false, callerName: "M", callerProject: nil)
        do {
            _ = try await ClaudeCodeRunner(fixturePath: script).run(request, onActivity: { _ in }, onProcessStarted: { _ in
                throw ChatError.storage("disk full")
            })
            XCTFail("it ran")
        } catch TeamRunnerError.didNotStart {
        } catch { XCTFail("\(error)") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    // MARK: 4 — descendants are taken before the first signal

    func testDescendantInItsOwnGroupIsStoppedWithTheRun() async throws {
        // The leader's child moves to a group of its own and stays linked to
        // the leader only by its parent.
        let marker = "c5-4-\(UUID().uuidString)"
        let leader = try spawn("perl -e 'setpgrp(0, 0); sleep 30' \(marker) & wait")
        Darwin.kill(leader.pid, SIGCONT)
        var child: pid_t?
        try await waitUntil {
            child = TeamProcesses.descendants(of: leader.pid).first { getpgid($0) == $0 }
            return child != nil
        }
        let pid = try XCTUnwrap(child)
        started.append(pid)
        let gone = await TeamProcesses.stop(leader, also: TeamPidSet()) == .stopped
        XCTAssertTrue(gone)
        try await waitUntil { TeamProcesses.startTime(pid) == nil }
        leader.release()
    }

    // MARK: 5 — a stale leader does not hide the processes seen under it

    func testProcessesSeenUnderAGoneLeaderStayARunsProcesses() throws {
        let other = try spawn("sleep 30")
        Darwin.kill(other.pid, SIGCONT)
        started.append(other.pid)
        let seen = TeamPidSet()
        seen.insert([other.identity.identity])
        let registry = TeamProcesses()
        XCTAssertTrue(registry.add(TeamProcessStart(pid: 999_997, pgid: 999_997, startTime: 1), seen: seen, callId: "call"))
        XCTAssertEqual(registry.run(containing: other.pid), .run(callId: "call"))
    }

    // MARK: 6 — every check of the approval after the last wait

    private func launcherWaitingInRecovery(_ change: @escaping @MainActor (ExecutorFixture) throws -> Void)
        async throws -> (ExecutorFixture, RecordingRunner, Result<TeamRunResult, Error>) {
        let runner = RecordingRunner()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f\(UUID().uuidString.prefix(4))"), runner: runner)
        let approval = try f.approve()
        // An open row of another run: recovery stops "its" process, and the
        // world changes meanwhile.
        let otherRequest = f.request
        f.request = TeamLaunchRequest(requestId: "req-left", prompt: "p", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let left = try f.approve()
        let params = try TeamLaunchParams.decode(left.params)
        XCTAssertTrue(try f.journal.consume(left, run: ChatRunRecord(
            runId: params.runId, requestId: left.requestId, approvalId: left.id, agentId: "another-agent",
            conversationId: params.conversationId, pid: 999_996, pgid: 999_996, processStartedAt: 1, startedAt: f.now)))
        f.request = otherRequest
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        let facts = RecordingFacts()
        r.facts = facts
        // Looking at it is where the world changes.
        r.find = { _ in
            try? change(f)
            return []
        }
        f.launcher.recovery = r
        let result: Result<TeamRunResult, Error>
        do { result = .success(try await f.launcher.launch(approvalId: approval.id)) } catch { result = .failure(error) }
        return (f, runner, result)
    }

    func testApprovalExpiringDuringRecoveryDoesNotRun() async throws {
        let (_, runner, result) = try await launcherWaitingInRecovery { $0.now = $0.now.addingTimeInterval(7200) }
        XCTAssertEqual(result.failure as? TeamLauncher.Failure, .voided("expired"))
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testAssignmentEndedDuringRecoveryDoesNotRun() async throws {
        let (_, runner, result) = try await launcherWaitingInRecovery { try $0.removeAssignments() }
        XCTAssertEqual(result.failure as? TeamLauncher.Failure, .voided("not_assigned"))
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testAgentChangedDuringRecoveryDoesNotRun() async throws {
        let (_, runner, result) = try await launcherWaitingInRecovery { $0.agent.model = "opus" }
        XCTAssertEqual(result.failure as? TeamLauncher.Failure, .voided("params_changed"))
        XCTAssertTrue(runner.requests.isEmpty)
    }

    // MARK: 7 — a recovered run's fact waits until the server is known

    func testRecoveredFactWaitsForTheServer() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f7"), runner: RecordingRunner())
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        XCTAssertTrue(try f.journal.consume(approval, run: ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, startedAt: f.now)))
        let facts = RecordingFacts()
        facts.serverKnown = false
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        r.facts = facts
        try f.journal.markProcessesGone(params.runId)
        await r.check()
        XCTAssertNil(try f.journal.run(params.runId)?.outcome, "no fact chosen before the server is known")
        XCTAssertTrue(facts.facts.isEmpty)
        XCTAssertEqual(r.awaitingFact.map(\.runId), [params.runId])
        XCTAssertTrue(r.stuck.isEmpty, "its processes are gone: the agent is not blocked")
        facts.serverKnown = true
        await r.check()
        XCTAssertEqual(try f.journal.run(params.runId)?.outcome, .executorRestarted)
        XCTAssertEqual(facts.facts.map(\.reason), ["executor_restarted"])
    }

    func testServiceKnowsTheServerOnlyWithASettledGeneration() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        try files.prepareDirectory()
        let f = try ExecutorFixture(root: root.appendingPathComponent("f7b"), runner: RecordingRunner())
        f.journal = try ChatJournal.open(files: files)
        try f.assign(.active)
        await service.recoverRunsAtLaunch()
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, startedAt: f.now)
        service.isServerKnown = { _, _ in true }
        service.requestState = { _, _ in "starting" }
        XCTAssertFalse(service.canChooseFact(for: row), "no generation known yet")
        try f.journal.finish(f.key, "g1")
        XCTAssertTrue(service.canChooseFact(for: row))
        try f.journal.setPending(f.key, "g2")
        XCTAssertFalse(service.canChooseFact(for: row), "a generation change under way")
        service.isServerKnown = { _, _ in false }
        try f.journal.finish(f.key, "g2")
        XCTAssertFalse(service.canChooseFact(for: row), "no ready connection")
    }

    // MARK: D9 — the main guarantee: nothing on the socket makes an approval

    func testOnlyTheAllowButtonMakesAnApproval() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var writers: [String] = []
        var approvers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("journal.insert(") { writers.append(url.lastPathComponent) }
            if text.contains("TeamApprovals.approve(") { approvers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(writers, ["TeamApprovals.swift"], "an approval row is written only by TeamApprovals.approve")
        XCTAssertTrue(Set(approvers).isSubset(of: ["TeamPanelSection.swift", "TeamCallsSidebar.swift"]), "\(approvers)")
        for name in ["Sessions/HookServer.swift", "App/CLIController.swift", "AgentPad/Team/TeamCLIHandler.swift",
                     "AgentPad/Team/TeamSocketOrigin.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent("AgentPadKit/\(name)"), encoding: .utf8)
            XCTAssertFalse(text.contains("TeamApprovals"), name)
            XCTAssertFalse(text.contains("ChatApproval"), name)
        }
    }
}

extension Result where Failure == Error {
    var failure: Error? { if case .failure(let error) = self { error } else { nil } }
}
