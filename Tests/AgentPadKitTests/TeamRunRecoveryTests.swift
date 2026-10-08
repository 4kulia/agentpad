import Darwin
import Foundation
import XCTest
@testable import AgentPadKit

/// A runner that loses the PID notice, like an app that ends right after
/// `Process.run()`.
struct ForgetfulRunner: TeamAgentRunner {
    let inner: ClaudeCodeRunner
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await inner.run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        let result: Result<TeamRunResult, Error>
        do { result = .success(try await inner.run(request, onActivity: onActivity, onProcessStarted: { _ in })) } catch { result = .failure(error) }
        // The app that ended learns how its run ended only after the next
        // app's recovery is done (it tries to write its outcome then).
        if hangsAfter { try? await Task.sleep(for: .seconds(3)) }
        return try result.get()
    }
    var hangsAfter = false
}

/// Real processes: a script named `claude` that sleeps.
@MainActor
final class TeamRunRecoveryTests: XCTestCase {
    private var root: URL!
    private var script: String!
    private var spawned: [Process] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        script = bin.appendingPathComponent("claude").path
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        for p in spawned where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for row in (try? ChatJournal.open(files: ChatFiles(directory: root.appendingPathComponent("chat"))).runs()) ?? [] {
            if let pid = row.pid, let start = row.processStartedAt {
                TeamProcesses.signal(TeamProcessStart(pid: pid, pgid: pid, startTime: start), SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ runner: TeamAgentRunner? = nil) throws -> ExecutorFixture {
        try ExecutorFixture(root: root, runner: runner ?? ClaudeCodeRunner(fixturePath: script))
    }

    private func waitUntil(_ seconds: Double = 8, _ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && TeamProcesses.startTime(pid) != nil }

    func testY5StopConfirmationSurvivesReopeningJournal() throws {
        let f = try fixture()
        let row = try spentRun(f, pid: 900_001, startTime: 1)
        try f.journal.markStopping(row.runId, reason: "stopped_by_owner", confirmed: true)
        let reopened = try ChatJournal.open(files: ChatFiles(directory: root.appendingPathComponent("chat")))
        let saved = try XCTUnwrap(reopened.run(row.runId))
        XCTAssertNotNil(saved.stopConfirmedAt)
        XCTAssertEqual(saved.stopConfirmedAt, saved.processesGoneAt)
        // A later local stop marker cannot erase the automatic verdict.
        try reopened.markStopping(row.runId, reason: "stopped_by_owner")
        XCTAssertEqual(try reopened.run(row.runId)?.stopConfirmedAt, saved.stopConfirmedAt)
    }

    func testY5MigrationLeavesOldStopsUnconfirmed() throws {
        let f = try fixture()
        let row = try spentRun(f, pid: 900_001, startTime: 1)
        try f.journal.markStopping(row.runId, reason: "stopped_by_owner")
        try f.journal.markProcessesGone(row.runId)
        // Restore the exact previous schema in this temporary journal.
        try f.journal.queue.write { db in
            try db.execute(sql: "ALTER TABLE runs DROP COLUMN stop_confirmed_at")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'release-6'")
        }
        let reopened = try ChatJournal.open(files: ChatFiles(directory: root.appendingPathComponent("chat")))
        let saved = try XCTUnwrap(reopened.run(row.runId))
        XCTAssertNotNil(saved.processesGoneAt)
        XCTAssertNil(saved.stopConfirmedAt, "an older owner's confirmation is not Y5's verdict")
    }

    /// A process left by an "earlier app": the script with the conversation id in its arguments.
    private func orphan(conversation: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: script)
        p.arguments = ["-p", "--session-id", conversation]
        try p.run()
        spawned.append(p)
        return p
    }

    /// An approval spent and its run row written, as a launch would leave them.
    private func spentRun(_ f: ExecutorFixture, pid: pid_t?, startTime: UInt64?, requestId: String = "req-1") throws -> ChatRunRecord {
        f.request = TeamLaunchRequest(requestId: requestId, prompt: "p", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, pid: pid, pgid: pid, processStartedAt: startTime, startedAt: f.now)
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        return row
    }

    private func recovery(_ f: ExecutorFixture, facts: RecordingFacts) -> TeamRunRecovery {
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        r.facts = facts
        return r
    }

    // (1) and (7)
    func testProcessNoticeIsWrittenAndStopAllStopsEveryRun() async throws {
        let f = try fixture()
        let facts = RecordingFacts()
        let stopper = TeamRunStopper(launcher: f.launcher)
        f.launcher.facts = facts
        let first = try f.approve()
        let launcher = f.launcher!
        let a = Task { try? await launcher.launch(approvalId: first.id) }
        try await waitUntil { try f.journal.runs().first?.pid != nil }
        // A second request to the same agent, while the first still runs.
        f.request = TeamLaunchRequest(requestId: "req-2", prompt: "two", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let second = try f.approve()
        let b = Task { try? await launcher.launch(approvalId: second.id) }
        try await waitUntil { try f.journal.runs().count == 2 && f.journal.runs().allSatisfy { $0.pid != nil } }

        for row in try f.journal.runs() {
            let pid = try XCTUnwrap(row.pid)
            XCTAssertTrue(alive(pid), "the notice came while the process runs")
            XCTAssertEqual(row.pgid, getpgid(pid))
            XCTAssertEqual(row.processStartedAt, TeamProcesses.startTime(pid))
            XCTAssertNil(row.outcome)
        }
        let pids = try f.journal.runs().compactMap(\.pid)
        await stopper.stopAll()
        _ = await (a.value, b.value)
        for row in try f.journal.runs() {
            XCTAssertFalse(TeamProcesses.alive(TeamProcessStart(pid: row.pid!, pgid: row.pid!, startTime: row.processStartedAt!)))
        }
        _ = pids
        // Y5 confirms the processes and their output are gone.
        XCTAssertEqual(try f.journal.runs().map(\.outcome), [.stoppedLocally, .stoppedLocally])
        XCTAssertEqual(try f.journal.runs().map(\.stopReason), ["stopped_by_owner", "stopped_by_owner"])
        XCTAssertTrue(try f.journal.runs().allSatisfy { $0.processesGoneAt != nil && $0.stopConfirmedAt != nil })
        XCTAssertEqual(facts.facts.map(\.reason), ["stopped_by_owner", "stopped_by_owner"])
    }

    // (2)
    func testClaudeThatCannotStartIsDidNotStart() async throws {
        let broken = root.appendingPathComponent("bin/broken").path
        try "not a program".write(toFile: broken, atomically: true, encoding: .utf8)
        let f = try fixture(ClaudeCodeRunner(fixturePath: broken))
        let approval = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("started")
        } catch let error as TeamLauncher.Failure {
            guard case .didNotStart = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try f.journal.runs().first?.outcome, .didNotStart)
        XCTAssertNil(try f.journal.runs().first?.pid)
    }

    // (3)
    func testLeftRunIsBlockedUntilTheOwnerDealsWithIt() async throws {
        let f = try fixture()
        let p = try orphan(conversation: "conv-3")
        let start = try XCTUnwrap(TeamProcesses.startTime(p.processIdentifier))
        let row = try spentRun(f, pid: p.processIdentifier, startTime: start)
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        r.stopGrace = .milliseconds(300)
        await r.check()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(p.isRunning, "after a crash AgentPad stops nothing by itself")
        XCTAssertEqual(r.blocked.map(\.id), [row.runId])
        XCTAssertEqual(r.blocked.first?.found, [ProcessIdentity(pid: p.processIdentifier, startTime: start)])
        let refused = await r.confirmGone(row.runId)
        XCTAssertNotNil(refused, "They Are Gone is refused while it runs")
        let stopped1 = await r.stopProcesses(row.runId)
        XCTAssertNil(stopped1)
        try await waitUntil { !p.isRunning }
        XCTAssertNil(try f.journal.run(row.runId)?.outcome, "stopped, but the owner says when it is over")
        let gone2 = await r.confirmGone(row.runId)
        XCTAssertNil(gone2)
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .executorRestarted)
        XCTAssertEqual(facts.facts.map(\.reason), ["executor_restarted"])
    }

    // (4) Narrowed after the fifth review: another process holds the number
    // and its group is not empty — nothing is confirmed, nothing is signalled.
    func testPidOfAnotherProcessIsNotTouched() async throws {
        let f = try fixture()
        let stranger = try orphan(conversation: "someone-else")
        let start = try XCTUnwrap(TeamProcesses.startTime(stranger.processIdentifier))
        let row = try spentRun(f, pid: stranger.processIdentifier, startTime: start - 1_000_000)
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        await r.check()
        XCTAssertEqual(r.stuck.map(\.runId), [row.runId], "blocked until the owner says")
        XCTAssertEqual(r.blocked.first?.found, [], "another process's number is not the run's")
        let stopped3 = await r.stopProcesses(row.runId)
        XCTAssertNil(stopped3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(stranger.isRunning, "the other process lives")
        XCTAssertNil(try f.journal.run(row.runId)?.outcome)
    }

    // (5) A row without a PID never ran (the identity is written before the
    // process goes on): a `claude` naming its conversation is not signalled —
    // it is unknown until it is gone.
    func testRowWithoutALeaderIsTheOwnersToCheck() async throws {
        let f = try fixture()
        let row = try spentRun(f, pid: nil, startTime: nil)
        let p = try orphan(conversation: row.conversationId)
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        await r.check()
        XCTAssertTrue(p.isRunning, "no signal, no search")
        XCTAssertEqual(r.stuck.map(\.runId), [row.runId])
        XCTAssertNil(r.blocked.first?.leader)
        XCTAssertNil(r.blocked.first?.found, "nothing to look at: the owner is asked")
        let stopped = await r.stopProcesses(row.runId)
        XCTAssertNotNil(stopped, "nothing AgentPad could stop")
        p.terminate()
        try await waitUntil { !p.isRunning }
        let gone = await r.confirmGone(row.runId)
        XCTAssertNil(gone, "the owner's word")
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .executorRestarted)
    }

    // (6)
    func testProcessThatCannotBeStoppedBlocksOnlyItsAgent() async throws {
        let runner = RecordingRunner()
        let f = try fixture(runner)
        let p = try orphan(conversation: "conv-6")
        let row = try spentRun(f, pid: p.processIdentifier, startTime: TeamProcesses.startTime(p.processIdentifier))
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        f.launcher.recovery = r
        await r.check()
        XCTAssertNil(try f.journal.run(row.runId)?.outcome)
        XCTAssertEqual(r.stuck.map(\.runId), [row.runId])
        XCTAssertTrue(facts.facts.isEmpty)

        // The same agent: refused, the approval still valid.
        f.request = TeamLaunchRequest(requestId: "req-next", prompt: "next", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let blocked = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: blocked.id)
            XCTFail("launched")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .blocked(agentId: blocked.agentId, pid: p.processIdentifier))
        }
        XCTAssertNil(try f.journal.approval(blocked.id)?.voidReason)
        XCTAssertNil(try f.journal.approval(blocked.id)?.consumedAt)

        // Another agent runs.
        var other = f.agent
        other.id = UUID()
        other.name = "frontend"
        f.agent = other
        try f.assign(.active)
        f.request = TeamLaunchRequest(requestId: "req-other", prompt: "x", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let fine = try f.approve()
        _ = try await f.launcher.launch(approvalId: fine.id)
        XCTAssertEqual(runner.requests.count, 1)
    }

    // (8)
    func testDisconnectStopsRunsBeforeClosingTheSession() async throws {
        // A local terminal/agent outside the server executor must survive.
        let local = Process()
        local.executableURL = URL(fileURLWithPath: "/bin/sleep"); local.arguments = ["30"]
        try local.run()
        defer { if local.isRunning { local.terminate() }; local.waitUntilExit() }
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        service.executorRunner = ClaudeCodeRunner(fixturePath: script)
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let key = ChatOrgKey(server: server, accountId: "acc", orgId: "org")
        try service.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"), token: "aps_t")
        try await service.start(mode: .server)
        let journal = try XCTUnwrap(service.journal)
        // The generation the journal keeps for the organization (as a hello writes it).
        try journal.finish(key, "g1")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let agent = TeamPublishedAgent(name: "backend", description: "d", folder: folder.path)
        let request = TeamLaunchRequest(requestId: "req-d", prompt: "p", context: nil, callerName: "M", callerProject: nil,
                                        conversationId: nil, expiresAt: Date().addingTimeInterval(3600))
        service.localAgent = { _ in agent }
        service.launchRequest = { _ in request }
        // Y2 rechecks the server's state before creating the executor.
        // Establish the fixture's starting state before asking it to run.
        service.requestState = { _, _ in "starting" }
        try journal.save(ChatAssignment(server: server.description, accountId: "acc", orgId: "org", agentId: agent.id.uuidString.lowercased(),
                                        state: .active, name: "backend", description: "d", access: "read-git", teamIds: "[]", createdAt: Date()))
        let approval = try TeamApprovals.approve(request: request, agent: agent, key: key, generation: "g1", journal: journal, session: "s1")
        let launcher = try XCTUnwrap(service.launcher)
        let run = Task { try? await launcher.launch(approvalId: approval.id) }
        try await waitUntil { try journal.runs().first?.pid != nil }
        // What the server says of the request is known: the fact can be chosen (review C7-9).
        service.isServerKnown = { _, _ in true }
        var factsAtClose: [String] = []
        service.closeRemoteSession = { _, _ in
            factsAtClose = (try journal.commands(for: key)).map(\.type)
        }
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: {
            XCTFail("Disconnect created a terminal"); return TestEngine()
        })
        defer { workspace.terminate() }
        let router = TabRouter(); router.stores = { [workspace] }; router.ensureHost = { workspace }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let tabs = ConnectionTabs(navigation: navigation, service: service)
        let confirmation = try XCTUnwrap(tabs.show()?.tabState?.confirmation)
        let disconnect = Task { await tabs.confirmAndDisconnect(expecting: service.connection!) }
        try await waitUntil { confirmation.isAwaiting }
        confirmation.canShow = { true }; confirmation.shown(true); confirmation.confirm()
        let outcome = await disconnect.value
        XCTAssertEqual(outcome, .disconnected)
        XCTAssertTrue(local.isRunning, "Disconnect must stop only server-request processes")
        _ = await run.value
        // Y5 confirms the stop before the session closes. The server still
        // has `starting`, so the chain owes run.started and run.failed.
        XCTAssertTrue(factsAtClose.contains("run.failed"))
        XCTAssertEqual(try journal.runs().first?.outcome, .stoppedLocally)
        XCTAssertEqual(try journal.runs().first?.stopReason, "stopped_by_owner")
        XCTAssertNotNil(try journal.runs().first?.processesGoneAt)
        XCTAssertNotNil(try journal.runs().first?.stopConfirmedAt)
    }

    // (9)
    func testAppEndingRightAfterProcessCreationIsRecoveredByConversation() async throws {
        let f = try fixture(ForgetfulRunner(inner: ClaudeCodeRunner(fixturePath: script), hangsAfter: true))
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let launcher = f.launcher!
        let first = Task { try? await launcher.launch(approvalId: approval.id) }
        try await waitUntil { !pgrep(params.conversationId).isEmpty }
        XCTAssertNil(try f.journal.run(params.runId)?.pid, "the PID was never written")
        // The next app: nothing of this run is live in it.
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        await r.check()
        XCTAssertEqual(r.stuck.map(\.runId), [params.runId], "no leader recorded: blocked, nothing signalled")
        for pid in pgrep(params.conversationId) { kill(pid, SIGKILL) }
        try await waitUntil { pgrep(params.conversationId).isEmpty }
        let gone5 = await r.confirmGone(params.runId)
        XCTAssertNil(gone5)
        XCTAssertEqual(try f.journal.run(params.runId)?.outcome, .executorRestarted)
        XCTAssertEqual(facts.facts.map(\.reason), ["executor_restarted"])
        _ = await first.value
        XCTAssertEqual(try f.journal.run(params.runId)?.outcome, .executorRestarted, "the first outcome stays")
    }

    // MARK: Second review (review-client-c2.md 14–19)

    /// C2-14: nothing of the run executes before it is registered and journaled.
    func testRunDoesNotExecuteBeforeItIsRegistered() async throws {
        let marker = root.appendingPathComponent("ran").path
        let early = root.appendingPathComponent("bin/claude-mark").path
        try "#!/bin/sh\ntouch \(marker)\nsleep 2\n".write(toFile: early, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: early)
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: root.path)
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: UUID().uuidString, resume: false, callerName: "M", callerProject: nil)
        let seen = TeamStartBox()
        let markerExisted = Counter(), registered = Counter()
        let run = Task.detached {
            try? await ClaudeCodeRunner(fixturePath: early).run(request, onActivity: { _ in }, onProcessStarted: { start in
                seen.set(start)
                if FileManager.default.fileExists(atPath: marker) { markerExisted.increment() }
                if case .run = TeamProcesses.shared.run(containing: start.pid) { registered.increment() }
            })
        }
        try await waitUntil { seen.get() != nil }
        XCTAssertEqual(markerExisted.value, 0, "the run had not executed yet")
        XCTAssertEqual(registered.value, 1, "and was registered for the control socket")
        try await waitUntil { FileManager.default.fileExists(atPath: marker) }
        run.cancel()
        _ = await run.value
    }

    /// C2-15, narrowed by C5-1: the leader gone, a member of its group left —
    /// the group proves nothing: no signal, the row stays open and blocks
    /// until the group is empty; a check that cannot be made keeps it open.
    func testLeftGroupWithoutItsLeaderIsNotSignalled() async throws {
        let f = try fixture()
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/sh")
        leader.arguments = ["-c", "/bin/sleep 30 & exit 0"]
        try leader.run()
        let pgid = leader.processIdentifier
        let start = TeamProcesses.startTime(pgid)
        try await waitUntil { !leader.isRunning }
        let members = try XCTUnwrap(TeamProcesses.members(ofGroup: pgid))
        XCTAssertEqual(members.count, 1, "the sleep is left in the group")
        let row = try spentRun(f, pid: pgid, startTime: start)
        let facts = RecordingFacts()
        let first = recovery(f, facts: facts)
        await first.check()
        XCTAssertEqual(TeamProcesses.members(ofGroup: pgid), members, "not signalled")
        XCTAssertEqual(first.stuck.map(\.runId), [row.runId])
        for pid in members { kill(pid, SIGKILL) }
        try await waitUntil { TeamProcesses.members(ofGroup: pgid) == [] }
        let gone6 = await first.confirmGone(row.runId)
        XCTAssertNil(gone6)
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .executorRestarted)

        let other = try spentRun(f, pid: 999_960, startTime: 1, requestId: "req-unknown")
        let r = recovery(f, facts: facts)
        r.find = { _ in nil }
        await r.check()
        XCTAssertEqual(r.stuck.map(\.runId), [other.runId])
        let refused = await r.confirmGone(other.runId)
        XCTAssertNotNil(refused, "what cannot be looked at is not confirmed gone")
        XCTAssertNil(try f.journal.run(other.runId)?.outcome, "stays open")
    }

    /// C2-16: once Disconnect began, no run is accepted.
    func testNoRunIsAcceptedWhileStopping() async throws {
        let runner = RecordingRunner()
        runner.holds = true
        let f = try fixture(runner)
        let first = try f.approve()
        let launcher = f.launcher!
        let a = Task { try? await launcher.launch(approvalId: first.id) }
        try await waitUntil { runner.requests.count == 1 }
        let stopper = TeamRunStopper(launcher: launcher)
        let stopping = Task { await stopper.stopAll() }
        try await Task.sleep(for: .milliseconds(10))
        f.request = TeamLaunchRequest(requestId: "req-2", prompt: "two", context: nil, callerName: "M", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let second = try f.approve()
        do {
            _ = try await launcher.launch(approvalId: second.id)
            XCTFail("launched while stopping")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .closed)
        }
        runner.release()
        await stopping.value
        _ = await a.value
        XCTAssertEqual(runner.requests.count, 1)
    }

    /// C2-17: an outcome is final only with the group gone; at quit it waits for the next start.
    func testOutcomeWaitsForTheGroupToBeGone() async throws {
        let f = try fixture(ReportingRunner())
        f.launcher.processesLeft = { _ in TeamPidSet() }
        let approval = try f.approve()
        _ = try? await f.launcher.launch(approvalId: approval.id)
        let row = try XCTUnwrap(try f.journal.runs().first)
        XCTAssertNil(row.outcome, "the group is still there: the row stays open")
        // Quit marks it; the next start, finding it gone, writes the outcome and its fact.
        try f.journal.markStopping(row.runId, reason: "stopped_by_owner")
        let facts = RecordingFacts()
        let r = recovery(f, facts: facts)
        r.find = { _ in [] }
        await r.check()
        let gone7 = await r.confirmGone(row.runId)
        XCTAssertNil(gone7)
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .stoppedLocally)
        XCTAssertEqual(facts.facts.map(\.reason), ["stopped_by_owner"])
    }

    /// C2-18 and C2-19: outcome and fact in one transaction, and the fact's
    /// kind by what the server knows of the run.
    func testOutcomeAndFactAreOneAndTheKindFollowsTheServer() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let key = ChatOrgKey(server: server, accountId: "acc", orgId: "org")
        try service.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"), token: "aps_t")
        try await service.start(mode: .server)
        let journal = try XCTUnwrap(service.journal)
        service.isServerKnown = { _, _ in true }
        // The request's state as the server has it: not started there.
        service.requestState = { _, _ in "starting" }
        try journal.finish(key, "g1")
        let f = try fixture()
        f.journal = journal
        f.makeLauncher()
        // Not started on the server: run.failed_to_start.
        let first = try spentRun(f, pid: nil, startTime: nil, requestId: "req-a")
        let r = TeamRunRecovery(journal: journal) { _ in false }
        r.facts = service
        try journal.markProcessesGone(first.runId)
        await r.check()
        var types = try journal.commands(for: key).map(\.type)
        XCTAssertEqual(types, ["run.failed_to_start"])
        XCTAssertEqual(try journal.run(first.runId)?.outcome, .executorRestarted)

        // A run.started of the run is queued: run.failed.
        let second = try spentRun(f, pid: 1, startTime: 1, requestId: "req-b")
        let started = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: "org", type: "run.started",
                                              args: .object(["run_id": .string(second.runId)])).encoded()
        try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "run.started", bodyBytes: started,
                                              orderKey: "exec:run:\(second.runId)", dependsOn: nil, createdAt: Date(), state: .pending), key: key)
        try journal.markProcessesGone(second.runId)
        await r.check()
        types = try journal.commands(for: key).map(\.type)
        XCTAssertEqual(types.last, "run.failed")

        // The fact cannot be stored: neither is the outcome.
        let third = try spentRun(f, pid: nil, startTime: nil, requestId: "req-c")
        try journal.markProcessesGone(third.runId)
        try denyFacts(journal)
        await r.check()
        XCTAssertNil(try journal.run(third.runId)?.outcome, "no outcome without its fact")
    }

    nonisolated private func denyFacts(_ journal: ChatJournal) throws {
        try journal.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny BEFORE INSERT ON run_commands BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
    }

    // MARK: Third review (review-client-c3.md 8–12, 18)

    /// C3-8: cancelled before it is let go of, the run never executes and is gone.
    func testCancelledStartNeverExecutes() async throws {
        let marker = root.appendingPathComponent("ran8").path
        let early = root.appendingPathComponent("bin/claude-8").path
        try "#!/bin/sh\ntouch \(marker)\nsleep 5\n".write(toFile: early, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: early)
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: root.path)
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: UUID().uuidString, resume: false, callerName: "M", callerProject: nil)
        let seen = TeamStartBox()
        let run = Task.detached {
            try await ClaudeCodeRunner(fixturePath: early).run(request, onActivity: { _ in }, onProcessStarted: {
                seen.set($0)
                // The journal write takes its time; the run is cancelled meanwhile.
                usleep(300_000)
            })
        }
        try await waitUntil { seen.get() != nil }
        let pid = try XCTUnwrap(seen.get()?.pid)
        XCTAssertEqual(TeamProcesses.shared.run(containing: pid), .run(callId: nil), "registered at once, before it is let go of")
        run.cancel()
        _ = await run.result
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "never continued")
        XCTAssertFalse(TeamProcesses.alive(try XCTUnwrap(seen.get())))
    }

    /// C3-9: a found run's processes stay a run's while they are not stopped.
    func testSurvivorsAreNotTouchedAfterACrash() async throws {
        let f = try fixture()
        let p = try orphan(conversation: "conv-9")
        let row = try spentRun(f, pid: p.processIdentifier, startTime: TeamProcesses.startTime(p.processIdentifier))
        let r = recovery(f, facts: RecordingFacts())
        await r.check()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(p.isRunning)
        XCTAssertNil(try f.journal.run(row.runId)?.outcome)
        XCTAssertEqual(r.stuck.map(\.runId), [row.runId])
    }

    /// C3-10: Disconnect stops the journal's open rows too, and a later start
    /// in any mode finds and stops them.
    func testOpenRowsStayBlockedThroughDisconnectAndLaunch() async throws {
        let f = try fixture()
        f.launcher.recovery = recovery(f, facts: RecordingFacts())
        let p = try orphan(conversation: "conv-10")
        let row = try spentRun(f, pid: p.processIdentifier, startTime: TeamProcesses.startTime(p.processIdentifier))
        await TeamRunStopper(launcher: f.launcher).stopAll()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(p.isRunning, "a run left by an earlier app is the owner's to stop")
        XCTAssertNil(try f.journal.run(row.runId)?.outcome)
        XCTAssertEqual(f.launcher.recovery?.stuck.map(\.runId), [row.runId])

        // At launch, in off mode: the journal on disk is opened and its rows block.
        let files = ChatFiles(directory: root.appendingPathComponent("launch"))
        try files.prepareDirectory()
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let g = try ExecutorFixture(root: root.appendingPathComponent("g"), runner: RecordingRunner())
        g.journal = try ChatJournal.open(files: files)
        let q = try orphan(conversation: "conv-10b")
        let left = try spentRun(g, pid: q.processIdentifier, startTime: TeamProcesses.startTime(q.processIdentifier), requestId: "req-l")
        await service.recoverRunsAtLaunch()
        XCTAssertTrue(q.isRunning)
        XCTAssertEqual(service.recovery?.stuck.map(\.runId), [left.runId])
    }

    /// C3-11: a fact that cannot be made leaves the row open — no outcome without it.
    func testUnmadeFactKeepsTheRowOpen() async throws {
        let f = try fixture()
        let row = try spentRun(f, pid: nil, startTime: nil)
        let facts = RecordingFacts()
        facts.failing = 1
        let r = recovery(f, facts: facts)
        try f.journal.markProcessesGone(row.runId)
        await r.check()
        XCTAssertNil(try f.journal.run(row.runId)?.outcome)
        XCTAssertEqual(r.awaitingFact.map(\.runId), [row.runId])
        await r.check()
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .executorRestarted)
    }

    /// One chain (DESIGN-D4 §0.2): a run whose process existed, ending
    /// while the server says `starting`, owes `run.started` then `run.failed`;
    /// an unconfirmed `run.started` proves nothing and is superseded; a
    /// waiting one is kept and followed (review C3-12, D4b-1).
    func testFactKindFollowsTheStartedChain() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc12"))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let key = ChatOrgKey(server: server, accountId: "acc", orgId: "org")
        try service.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"), token: "aps_t")
        try await service.start(mode: .server)
        let journal = try XCTUnwrap(service.journal)
        try journal.finish(key, "g1")
        let f = try fixture()
        f.journal = journal
        func started(_ row: ChatRunRecord, _ state: ChatCommandRecord.State) throws -> ChatCommandRecord {
            let body = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: "org", type: "run.started",
                                               args: .object(["run_id": .string(row.runId)])).encoded()
            return try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "run.started", bodyBytes: body,
                                                         orderKey: "exec:run:\(row.runId)", dependsOn: nil, createdAt: Date(), state: state), key: key)
        }
        func chain(_ row: ChatRunRecord) throws -> [ChatCommandRecord] {
            try journal.commands(for: key).filter { $0.orderKey == "exec:run:\(row.runId)" && $0.state != .dropped }
        }
        service.requestState = { _, _ in "starting" }
        let first = try spentRun(f, pid: 1, startTime: 1, requestId: "req-12a")
        let unconfirmed = try started(first, .unconfirmed)
        XCTAssertTrue(try service.end(first, outcome: .executorRestarted, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        var made = try chain(first)
        XCTAssertEqual(made.map(\.type), ["run.started", "run.failed"])
        XCTAssertNotEqual(made.first?.commandId, unconfirmed.commandId, "the unconfirmed one is superseded")
        XCTAssertEqual(made.last?.dependsOn, made.first?.commandId)
        let second = try spentRun(f, pid: 1, startTime: 1, requestId: "req-12b")
        let waiting = try started(second, .pending)
        XCTAssertTrue(try service.end(second, outcome: .executorRestarted, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        made = try chain(second)
        XCTAssertEqual(made.map(\.type), ["run.started", "run.failed"])
        XCTAssertEqual(made.last?.dependsOn, waiting.commandId, "after the run.started that is waiting to go")
        service.requestState = { _, _ in "running" }
        let third = try spentRun(f, pid: 1, startTime: 1, requestId: "req-12c")
        XCTAssertTrue(try service.end(third, outcome: .executorRestarted, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        XCTAssertEqual(try chain(third).map(\.type), ["run.failed"])
    }

    /// C4-7: a run.started taken by an earlier server generation proves
    /// nothing to the current one; without the server's state only the
    /// outcome is written (review C8-4), and `recover` tells the end later.
    func testStartedFactOfAnEarlierGenerationProvesNothing() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc-c4-7"))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        let key = ChatOrgKey(server: server, accountId: "acc", orgId: "org")
        try service.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s1", deviceName: "Mac", orgId: "org"), token: "aps_t")
        try await service.start(mode: .server)
        let journal = try XCTUnwrap(service.journal)
        try journal.finish(key, "g1")
        let f = try fixture()
        f.journal = journal
        func sentStarted(_ row: ChatRunRecord) throws {
            let body = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: "org", type: "run.started",
                                               args: .object(["run_id": .string(row.runId)])).encoded()
            var started = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s1", type: "run.started", bodyBytes: body,
                                                                orderKey: "exec:run:\(row.runId)", dependsOn: nil, createdAt: Date(),
                                                                state: .pending), key: key)
            started.state = .sent
            started.sentGeneration = "g1"
            XCTAssertTrue(try journal.runCommands(key).update(started, ifState: .pending))
        }
        func chain(_ row: ChatRunRecord) throws -> [String] {
            try journal.commands(for: key).filter { $0.orderKey == "exec:run:\(row.runId)" && $0.state == .pending }.map(\.type)
        }
        service.requestState = { _, _ in nil }
        let unknown = try spentRun(f, pid: 1, startTime: 1, requestId: "req-c4-7a")
        try sentStarted(unknown)
        XCTAssertTrue(try service.end(unknown, outcome: .failed, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        XCTAssertEqual(try chain(unknown), [], "the outcome alone")
        // Taken by this generation: only the end.
        service.requestState = { _, _ in "running" }
        let taken = try spentRun(f, pid: 1, startTime: 1, requestId: "req-c4-7b")
        try sentStarted(taken)
        XCTAssertTrue(try service.end(taken, outcome: .failed, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        XCTAssertEqual(try chain(taken), ["run.failed"])
        // A new generation restored at `starting`: run.started again, then the end.
        try journal.finish(key, "g2")
        service.requestState = { _, _ in "starting" }
        let restored = try spentRun(f, pid: 1, startTime: 1, requestId: "req-c4-7c")
        try sentStarted(restored)
        XCTAssertTrue(try service.end(restored, outcome: .failed, reason: "x", result: nil, at: Date(), journal: journal, waitForState: false))
        XCTAssertEqual(try chain(restored), ["run.started", "run.failed"], "the server's state counts over what was sent")
    }

    /// C3-18: a `claude` that cannot be executed did not start.
    func testUnexecutableClaudeDidNotStart() async throws {
        let broken = root.appendingPathComponent("bin/claude-bad").path
        try "#!/nonexistent/interpreter\n".write(toFile: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken)
        let f = try fixture(ClaudeCodeRunner(fixturePath: broken))
        let approval = try f.approve()
        do {
            _ = try await f.launcher.launch(approvalId: approval.id)
            XCTFail("started")
        } catch let error as TeamLauncher.Failure {
            guard case .didNotStart = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try f.journal.runs().first?.outcome, .didNotStart)
    }
}

/// A runner that reports a process (that does not exist) and answers.
struct ReportingRunner: TeamAgentRunner {
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        TeamRunResult(text: "done", isError: false)
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        try onProcessStarted(TeamProcessStart(pid: 999_999, pgid: 999_999, startTime: 1))
        return TeamRunResult(text: "done", isError: false)
    }
}

/// Processes of this user whose command line contains `pattern` (tests).
func pgrep(_ pattern: String) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", pattern]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").compactMap { pid_t($0) }
}
