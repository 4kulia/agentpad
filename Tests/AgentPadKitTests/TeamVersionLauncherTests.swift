import XCTest
@testable import AgentPadKit

@MainActor
final class TeamVersionLauncherTests: XCTestCase {
    var root: URL!
    var binary: URL!
    var approvals: ClaudeVersionApprovals!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("y2-launch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binary = try NativeVersionFixture.make(in: root)
        approvals = ClaudeVersionApprovals()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    func wait(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while try !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition(), file: file, line: line)
    }
    func fixture(version: String = "2.1.290", runner: TeamAgentRunner? = nil) throws -> ExecutorFixture {
        let store = approvals!
        let checker = ClaudeVersionPreflight(readVersion: { _, _ in version }, approvals: { store })
        let f = try ExecutorFixture(root: root, runner: runner ?? ClaudeCodeRunner(claudePath: binary.path, preflight: checker))
        f.agent.access = .read
        try f.assign(.active)
        return f
    }

    // §4.2–4: the existing D9 approval and journal row remain spent while
    // waiting. Refusal produces exactly the first segment's failure fact.
    func testWaitAndDeclineSpendD9OnlyOnce() async throws {
        let f = try fixture()
        let facts = VersionFacts(); f.launcher.facts = facts
        let allowed = try f.approve()
        let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
        try await wait { self.approvals.pending.count == 1 }
        XCTAssertNotNil(try f.journal.approval(allowed.id)?.consumedAt)
        XCTAssertEqual(try f.journal.runs().count, 1)
        XCTAssertNil(try f.journal.run(allowed.runId)?.outcome)
        XCTAssertEqual(facts.steps, [])
        XCTAssertEqual(facts.starts, 0)
        do { _ = try await f.launcher.launch(approvalId: allowed.id); XCTFail("spent twice") }
        catch { XCTAssertEqual(error as? TeamLauncher.Failure, .alreadyUsed) }
        approvals.decide(try XCTUnwrap(approvals.pending.first?.id), allow: false)
        _ = await launch.result
        XCTAssertEqual(facts.steps, ["run.failed_to_start"])
        XCTAssertEqual(facts.reasons, ["version_not_allowed"])
        XCTAssertEqual(try f.journal.run(allowed.runId)?.outcome, .didNotStart)
    }

    func testAcceptResumesSameRunExactlyOnce() async throws {
        let f = try fixture()
        let facts = VersionFacts(); f.launcher.facts = facts
        let allowed = try f.approve()
        let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
        try await wait { self.approvals.pending.count == 1 }
        let id = try XCTUnwrap(approvals.pending.first?.id)
        approvals.decide(id, allow: true); approvals.decide(id, allow: true)
        _ = try await launch.value
        XCTAssertEqual(facts.starts, 1)
        XCTAssertEqual(try f.journal.runs().map(\.runId), [allowed.runId])
        XCTAssertEqual(try f.journal.approvals().count, 1)
        XCTAssertEqual(try f.journal.run(allowed.runId)?.outcome, .finished)
    }

    func testUnknownProfileIsAParameterErrorAndNeverBecomesRead() throws {
        let f = try fixture()
        let approval = try f.approve()
        var params = try TeamLaunchParams.decode(approval.params)
        params.inputs.access = "unknown-profile"
        XCTAssertThrowsError(try params.runRequest(logURL: nil)) {
            XCTAssertEqual($0 as? TeamRunnerError, .didNotStart("unknown_access_profile"))
        }
    }

    func testExpiryAndChangedTermsDuringWaitExcludeLateConsent() async throws {
        for rule in ["expired", "params_changed", "not_assigned", "server_restored", "executor_signed_out", "approval_void", "request_not_active"] {
            let f = try fixture()
            let facts = VersionFacts(); f.launcher.facts = facts
            let allowed = try f.approve()
            let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
            try await wait { !self.approvals.pending.isEmpty }
            let item = try XCTUnwrap(approvals.pending.first)
            switch rule {
            case "expired": f.now = f.request.expiresAt
            case "params_changed": f.agent.model = "different"
            case "not_assigned": try f.removeAssignments()
            case "server_restored": f.generation = "g2"
            case "executor_signed_out": f.launcher.currentSession = { "other" }
            case "request_not_active": f.launcher.requestCanExecute = { _ in false }
            default:
                try await f.journal.queue.write { db in
                    try db.execute(sql: "UPDATE approvals SET void_reason = 'test' WHERE id = ?", arguments: [allowed.id])
                }
            }
            approvals.decide(item.id, allow: true)
            _ = await launch.result
            XCTAssertFalse(approvals.contains(item.grant), rule)
            XCTAssertEqual(facts.starts, 0, rule)
            XCTAssertEqual(facts.steps, ["run.failed_to_start"], rule)
            XCTAssertTrue(facts.reasons.first?.contains(rule == "request_not_active" ? "stopped_by_owner" : rule) ?? false, "\(rule): \(facts.reasons)")
            // A fresh isolated journal for the next variant.
            try FileManager.default.removeItem(at: root.appendingPathComponent("chat"))
        }
    }

    // §4.14–15: a folder grant does not grant a version. No second started;
    // rejection/technical failure belong to the already running run.
    func testFolderContinuationWaitAcceptDeclineAndTechnicalFailure() async throws {
        for decision in ["allow", "decline", "technical", "stop"] {
            let store = approvals!
            let checker = ClaudeVersionPreflight(readVersion: { _, _ in "2.1.290" }, approvals: { store })
            let segment = VersionSegmentRunner(path: binary.path, preflight: checker)
            segment.failContinuation = decision == "technical"
            let f = try fixture(runner: segment)
            let facts = VersionFacts(); f.launcher.facts = facts
            let allowed = try f.approve()
            segment.beforeFirstEnd = {
                let grant = try TeamApprovals.continuation(of: allowed, segment: 1, granted: [self.root.path],
                                                          generation: f.generation, session: nil, now: f.now)
                try f.journal.queue.write { db in try grant.insert(db) }
            }
            let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
            if decision != "technical" {
                try await wait { !self.approvals.pending.isEmpty }
                XCTAssertNil(try f.journal.run(allowed.runId)?.outcome)
                XCTAssertEqual(facts.starts, 1)
                XCTAssertEqual(facts.steps, ["run.started"])
                let item = try XCTUnwrap(approvals.pending.first)
                if decision == "stop" {
                    facts.state = .stopRequested
                    let stop = try await f.launcher.stopForServer(allowed.runId)
                    XCTAssertEqual(stop, .stopped)
                    let row = try XCTUnwrap(f.journal.run(allowed.runId))
                    XCTAssertNotNil(row.processesGoneAt)
                    XCTAssertTrue(f.launcher.finish(row, .stoppedLocally, reason: "stopped_by_owner"))
                    approvals.decide(item.id, allow: true)
                    XCTAssertFalse(approvals.contains(item.grant))
                } else {
                    approvals.decide(item.id, allow: decision == "allow")
                }
            }
            _ = await launch.result
            XCTAssertEqual(try f.journal.runs().count, 1)
            let row = try XCTUnwrap(f.journal.run(allowed.runId))
            XCTAssertEqual(row.runId, allowed.runId)
            if decision == "allow" {
                XCTAssertEqual(row.outcome, .finished)
                XCTAssertEqual(segment.executors, 2)
            } else if decision == "stop" {
                XCTAssertEqual(row.outcome, .stoppedLocally)
                XCTAssertEqual(facts.steps.last, "run.stopped")
            } else {
                XCTAssertEqual(row.outcome, .failed)
                XCTAssertEqual(facts.steps.last, "run.failed")
                XCTAssertEqual(segment.executors, 1)
                if decision == "decline" { XCTAssertEqual(facts.reasons.last, "version_not_allowed") }
            }
            XCTAssertEqual(facts.steps.filter { $0 == "run.started" }.count, 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("chat"))
            approvals = ClaudeVersionApprovals()
        }
    }

    // §4.17–18,20: both real version cancellation and owner wait unblock;
    // lost network saves absence of processes for D11, with no rerun.
    func testConfirmedPreflightStopUnblocksEvenWithoutNetwork() async throws {
        for mode in ["hang", "2.1.290 (Claude Code)\n"] {
            let store = approvals!
            let checker = ClaudeVersionPreflight(approvals: { store })
            let f = try fixture(runner: ClaudeCodeRunner(claudePath: binary.path, preflight: checker))
            try mode.write(to: URL(fileURLWithPath: f.agent.folder).appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            let facts = VersionFacts(); facts.known = false; f.launcher.facts = facts
            let allowed = try f.approve()
            let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
            try await wait {
                mode == "hang" ? try f.journal.run(allowed.runId)?.preflightPID != nil : !self.approvals.pending.isEmpty
            }
            _ = await f.launcher.stop(allowed.runId)
            _ = await launch.result
            let saved = try XCTUnwrap(f.journal.run(allowed.runId))
            XCTAssertNil(saved.outcome, "fact awaits known server")
            XCTAssertNotNil(saved.processesGoneAt)
            XCTAssertNotNil(saved.stopConfirmedAt)
            XCTAssertNil(saved.pid)
            XCTAssertNil(saved.preflightPID)
            let recovery = TeamRunRecovery(journal: f.journal) { f.launcher.isLive($0) }
            recovery.facts = facts
            _ = await recovery.check()
            XCTAssertTrue(recovery.stuck.isEmpty)
            XCTAssertEqual(recovery.awaitingFact.count, 1)
            facts.known = true; facts.state = .stopRequested
            _ = await recovery.check()
            XCTAssertEqual(facts.steps, ["run.stopped"])
            XCTAssertEqual(facts.starts, 0)
            XCTAssertEqual(try f.journal.run(allowed.runId)?.outcome, .stoppedLocally)
            f.request = TeamLaunchRequest(requestId: "next", prompt: "p", context: nil, callerName: "test", callerProject: nil,
                                          conversationId: nil, expiresAt: f.request.expiresAt)
            try "2.1.289 (Claude Code)\n".write(to: URL(fileURLWithPath: f.agent.folder).appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            // A new runner/application cache, but the same journal and agent.
            f.makeLauncher()
            // The previous checker cached the unknown version in the wait case;
            // changing the file invalidates it for the next process.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: binary.path)
            let next = try f.approve()
            _ = try await f.launcher.launch(approvalId: next.id)
            XCTAssertEqual(try f.journal.run(next.runId)?.outcome, .finished)
            try FileManager.default.removeItem(at: root.appendingPathComponent("chat"))
        }
    }

    // §4.19: unconfirmed cleanup retains the service identity and blocks.
    func testUnconfirmedServiceCleanupPersistsAndReportsStopFailed() async throws {
        let runner = UnconfirmedVersionRunner()
        let f = try fixture(runner: runner)
        let allowed = try f.approve()
        let launch = Task { try await f.launcher.launch(approvalId: allowed.id) }
        try await wait { runner.waiting }
        let stop = try await f.launcher.stopForServer(allowed.runId)
        _ = await launch.result
        XCTAssertEqual(stop?.stopFailedReason, "preflight_cleanup_unconfirmed")
        let saved = try XCTUnwrap(f.journal.run(allowed.runId))
        XCTAssertNil(saved.outcome); XCTAssertNil(saved.processesGoneAt); XCTAssertNil(saved.pid)
        XCTAssertEqual(saved.preflightPID, runner.helper.pid)
        let reopened = try ChatJournal.open(files: f.files)
        XCTAssertEqual(try reopened.run(allowed.runId)?.preflightPID, runner.helper.pid)
        let recovery = TeamRunRecovery(journal: reopened) { _ in false }
        recovery.find = { _ in [] }
        _ = await recovery.check()
        XCTAssertEqual(recovery.blocked.first?.leader, runner.helper)
        f.request = TeamLaunchRequest(requestId: "next", prompt: "p", context: nil, callerName: "test", callerProject: nil,
                                      conversationId: nil, expiresAt: f.request.expiresAt)
        let next = try f.approve()
        do { _ = try await f.launcher.launch(approvalId: next.id); XCTFail("not blocked") }
        catch { guard case .blocked = error as? TeamLauncher.Failure else { return XCTFail("\(error)") } }
        XCTAssertNil(try f.journal.approval(next.id)?.consumedAt)
    }

    func testCleanupUnconfirmedFromRealVersionProcess() async throws {
        let f = try fixture()
        var req = TeamRunRequest(agent: f.agent, prompt: "p", sessionId: UUID().uuidString, resume: false,
                                 callerName: "test", callerProject: nil)
        let helper = TeamStartBox()
        req.onPreflightProcess = { start in
            if let start { helper.set(start); TeamProcesses.wholeTableUnreadable = true }
        }
        defer {
            TeamProcesses.wholeTableUnreadable = false
            if let start = helper.get() { TeamProcesses.shared.remove(start) }
        }
        do {
            _ = try await ClaudeVersionCommand.read(ClaudeExecutable.inspect(binary.path), request: req, timeout: .seconds(1))
            XCTFail("unknown process table became clean")
        } catch {
            guard case .preflightCleanupUnconfirmed(let start, _) = error as? TeamRunnerError else { return XCTFail("\(error)") }
            XCTAssertEqual(start, helper.get())
            XCTAssertTrue(TeamProcesses.shared.blocks(agentId: f.agent.id.uuidString.lowercased()))
        }
    }
}

@MainActor
private final class VersionFacts: TeamRunFacts {
    var state: TeamRequestState = .starting
    var starts = 0
    var known = true
    var steps: [String] = []
    var reasons: [String] = []
    func processStarted(_ run: ChatRunRecord) {
        starts += 1
        if state == .starting { steps.append("run.started"); state = .running }
    }
    func factStored(_ key: ChatOrgKey) {}
    func canChooseFact(for run: ChatRunRecord) -> Bool { known }
    func end(_ run: ChatRunRecord, outcome: ChatRunRecord.Outcome, reason: String, result: String?, at: Date,
             journal: ChatJournal, waitForState: Bool, diagnosis: ClaudeLaunchDiagnostic.Failure?) throws -> Bool {
        let current = try journal.run(run.runId) ?? run
        let next = ChatFactChain.plan(state: state, outcome: outcome, processStarted: current.pid != nil,
                                      stopConfirmed: current.stopConfirmedAt != nil, hasResult: result != nil, answered: false)
        let done = try journal.finish(run.runId, outcome, at: at, result: result, diagnosis: diagnosis)
        if done { steps += next; reasons.append(reason) }
        return done
    }
}

@MainActor
private final class VersionSegmentRunner: TeamAgentRunner {
    let path: String
    let preflight: ClaudeVersionPreflight
    var beforeFirstEnd: () throws -> Void = {}
    var failContinuation = false
    var executors = 0
    init(path: String, preflight: ClaudeVersionPreflight) { self.path = path; self.preflight = preflight }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        if executors == 0 {
            try onProcessStarted(.init(pid: 900_001, pgid: 900_001, startTime: 1))
            executors += 1
            try beforeFirstEnd()
        } else {
            if failContinuation { throw TeamRunnerError.didNotStart("version unreadable") }
            _ = try await preflight.prepare(selectedPath: path, request: request, onActivity: onActivity)
            try onProcessStarted(.init(pid: 900_002, pgid: 900_002, startTime: 2))
            executors += 1
        }
        return .init(text: "done", isError: false)
    }
}

@MainActor
private final class UnconfirmedVersionRunner: TeamAgentRunner {
    let helper = TeamProcessStart(pid: 900_003, pgid: 900_003, startTime: 3)
    var waiting = false
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try request.onPreflightProcess?(helper)
        waiting = true
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        throw TeamRunnerError.preflightCleanupUnconfirmed(helper, .unknown("service output open"))
    }
}
