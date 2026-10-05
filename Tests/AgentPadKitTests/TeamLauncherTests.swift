import Foundation
import XCTest
@testable import AgentPadKit

/// Counts runs and keeps what each got; can hold a run until released.
final class RecordingRunner: TeamAgentRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TeamRunRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    var holds = false
    /// Read in the runner's call: the journal's run rows at that moment.
    var onCall: (TeamRunRequest) -> Void = { _ in }

    var requests: [TeamRunRequest] { lock.withLock { _requests } }

    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        lock.withLock { _requests.append(request) }
        onCall(request)
        if holds {
            await withCheckedContinuation { c in
                let go = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = c
                    return false
                }
                if go { c.resume() }
            }
        }
        return TeamRunResult(text: "done", isError: false, turns: 1, durationMs: 1)
    }

    private var released = false

    func release() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let g = gate
            gate = nil
            return g
        }?.resume()
    }
}

/// The facts the executor owed: recorded and stored as plain commands.
@MainActor
final class RecordingFacts: TeamRunFacts {
    var facts: [(runId: String, reason: String)] = []
    /// The next facts that cannot be made.
    var failing = 0
    func end(_ run: ChatRunRecord, outcome: ChatRunRecord.Outcome, reason: String, result: String?, at: Date,
             journal: ChatJournal, waitForState: Bool) throws -> Bool {
        if failing > 0 {
            failing -= 1
            throw ChatError.storage("cannot make the fact")
        }
        guard let key = try journal.approval(run.approvalId)?.key else { throw ChatError.storage("no approval") }
        facts.append((run.runId, reason))
        var record = ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s", type: "run.failed_to_start", bodyBytes: Data("{}".utf8),
                                       orderKey: "exec:run:\(run.runId)", dependsOn: nil, createdAt: Date(), state: .pending)
        record.seq = Int64(facts.count) + 1_000
        return try journal.finish(run.runId, outcome, at: at, result: result) { db in
            _ = try journal.runCommands(key).insert(db, record, seq: record.seq)
        }
    }
    func processStarted(_ run: ChatRunRecord) {}
    func factStored(_ key: ChatOrgKey) {}
    /// Whether the server is known; a recovered run's fact waits while false.
    var serverKnown = true
    func canChooseFact(for run: ChatRunRecord) -> Bool { serverKnown }
}

/// One owner Mac in server mode: journal, an agent, a request and a launcher.
@MainActor
final class ExecutorFixture {
    let root: URL
    let files: ChatFiles
    var journal: ChatJournal
    let key: ChatOrgKey
    var agent: TeamPublishedAgent
    var request: TeamLaunchRequest
    var generation = "g1"
    var pendingGeneration: String?
    var generationFails: Error?
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    let runner: TeamAgentRunner
    var launcher: TeamLauncher!

    init(root: URL, runner: TeamAgentRunner, key: ChatOrgKey? = nil, journal: ChatJournal? = nil) throws {
        self.root = root
        files = ChatFiles(directory: root.appendingPathComponent("chat"))
        self.journal = try journal ?? ChatJournal.open(files: files)
        self.key = try key ?? ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"), accountId: "acc", orgId: "org")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        agent = TeamPublishedAgent(name: "backend", description: "d", folder: folder.path)
        agent.allowedCommands = ["swift test"]
        agent.extraFolders = ["/tmp"]
        agent.model = "sonnet"
        request = TeamLaunchRequest(requestId: "req-1", prompt: "How is auth done?", context: nil, callerName: "Masha",
                                    callerProject: nil, conversationId: nil, expiresAt: now.addingTimeInterval(3600))
        self.runner = runner
        try assign(.active)
        makeLauncher()
    }

    func makeLauncher() {
        let launcher = TeamLauncher(journal: journal, runner: runner)
        launcher.agent = { [unowned self] id in self.agent.id.uuidString.lowercased() == id ? self.agent : nil }
        launcher.request = { [unowned self] id in self.request.requestId == id ? self.request : nil }
        launcher.generationState = { [unowned self] _ in
            if let failing = self.generationFails { throw failing }
            return (self.generation, self.pendingGeneration)
        }
        launcher.now = { [unowned self] in self.now }
        self.launcher = launcher
    }

    func assign(_ state: ChatAssignment.State) throws {
        try journal.save(ChatAssignment(
            server: key.server.description, accountId: key.accountId, orgId: key.orgId, agentId: agent.id.uuidString.lowercased(),
            state: state, name: agent.name, description: agent.description, access: agent.access.rawValue, teamIds: "[]", createdAt: now
        ))
    }

    func removeAssignments() throws {
        try journal.queue.write { db in try db.execute(sql: "DELETE FROM assignments") }
    }

    func approve() throws -> ChatApproval {
        try TeamApprovals.approve(request: request, agent: agent, key: key, generation: generation, journal: journal, now: now)
    }
}

@MainActor
final class TeamLauncherTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ runner: RecordingRunner = RecordingRunner()) throws -> (ExecutorFixture, RecordingRunner) {
        (try ExecutorFixture(root: root, runner: runner), runner)
    }

    private func expectFailure(_ expected: TeamLauncher.Failure, _ launch: () async throws -> TeamRunResult,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await launch()
            XCTFail("launched", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, expected, file: file, line: line)
        }
    }

    // (1)
    func testServerStateWithoutALocalApprovalStartsNothing() async throws {
        let (f, runner) = try fixture()
        for state in ["approved", "starting"] {
            XCTAssertEqual(try TeamApprovals.action(f.key, requestId: "req-1", state: state, journal: f.journal) { _ in false },
                           .failStart(reason: "not_approved_here"))
        }
        XCTAssertEqual(try TeamApprovals.action(f.key, requestId: "req-1", state: "running", journal: f.journal) { _ in false }, TeamApprovals.Action.none)
        await expectFailure(.unknownApproval) { try await f.launcher.launch(approvalId: UUID().uuidString) }
        XCTAssertEqual(runner.requests.count, 0)
    }

    // (2)
    func testChangedAgentOrRequestVoidsTheApproval() async throws {
        let changes: [(String, (inout TeamPublishedAgent, inout TeamLaunchRequest) -> Void)] = [
            ("folder", { a, _ in a.folder = "/tmp" }),
            ("profile", { a, _ in a.access = .edit }),
            ("model", { a, _ in a.model = "opus" }),
            ("allowed commands", { a, _ in a.allowedCommands = ["rm -rf"] }),
            ("extra folders", { a, _ in a.extraFolders = ["/tmp", "/Users"] }),
            ("memory source", { a, _ in a.sessionId = "another-conversation" }),
            ("denied paths", { a, _ in a.deniedPaths = [] }),
            ("limits", { a, _ in a.maxTurns = 99 }),
            ("request text", { _, r in r = TeamLaunchRequest(requestId: r.requestId, prompt: "other", context: nil, callerName: r.callerName,
                                                            callerProject: nil, conversationId: nil, expiresAt: r.expiresAt) }),
        ]
        for (name, change) in changes {
            try? FileManager.default.removeItem(at: root)
            let (f, runner) = try fixture()
            let approval = try f.approve()
            change(&f.agent, &f.request)
            await expectFailure(.voided("params_changed")) { try await f.launcher.launch(approvalId: approval.id) }
            XCTAssertEqual(runner.requests.count, 0, name)
            XCTAssertEqual(try f.journal.approval(approval.id)?.voidReason, "params_changed", name)
            XCTAssertEqual(try TeamApprovals.action(f.key, requestId: "req-1", state: "approved", journal: f.journal) { _ in false },
                           .failStart(reason: "params_changed"), name)
            // No second decision on the same request: the approval stays void.
            await expectFailure(.voided("params_changed")) { try await f.launcher.launch(approvalId: approval.id) }
        }
    }

    /// C2-13: another conversation to continue, or another deadline, voids too.
    func testChangedConversationOrDeadlineVoidsTheApproval() async throws {
        // The thread a run goes on is part of what was allowed; its
        // conversation is not — that is chosen at the start (F6, D9).
        for (name, change) in [("thread", { (r: TeamLaunchRequest) in
                                    var other = r
                                    other.thread = "personal:another"
                                    return other }),
                                ("deadline", { (r: TeamLaunchRequest) in
                                    TeamLaunchRequest(requestId: r.requestId, prompt: r.prompt, context: nil, callerName: r.callerName,
                                                      callerProject: nil, conversationId: r.conversationId, expiresAt: r.expiresAt.addingTimeInterval(600)) })] {
            try? FileManager.default.removeItem(at: root)
            let (f, runner) = try fixture()
            f.request = TeamLaunchRequest(requestId: "req-1", prompt: "p", context: nil, callerName: "M", callerProject: nil,
                                          conversationId: "conv-a", expiresAt: f.now.addingTimeInterval(3600))
            let approval = try f.approve()
            f.request = change(f.request)
            await expectFailure(.voided("params_changed")) { try await f.launcher.launch(approvalId: approval.id) }
            XCTAssertEqual(runner.requests.count, 0, name)
        }
        // A deadline moved earlier: expired by the request as it stands now.
        try? FileManager.default.removeItem(at: root)
        let (g, _) = try fixture()
        let approval = try g.approve()
        g.now = g.now.addingTimeInterval(1800)
        g.request = TeamLaunchRequest(requestId: "req-1", prompt: g.request.prompt, context: nil, callerName: g.request.callerName,
                                      callerProject: nil, conversationId: nil, expiresAt: g.now.addingTimeInterval(-1))
        await expectFailure(.voided("expired")) { try await g.launcher.launch(approvalId: approval.id) }
    }

    // (3)
    func testOneApprovalStartsOneRunEvenInParallel() async throws {
        let (f, runner) = try fixture()
        runner.holds = true
        let approval = try f.approve()
        let first = Task { try await f.launcher.launch(approvalId: approval.id) }
        let second = Task { try await f.launcher.launch(approvalId: approval.id) }
        do {
            _ = try await second.value
            XCTFail("second launch ran")
        } catch {
            XCTAssertEqual(error as? TeamLauncher.Failure, .alreadyUsed)
        }
        while runner.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        runner.release()
        _ = try await first.value
        await expectFailure(.alreadyUsed) { try await f.launcher.launch(approvalId: approval.id) }
        XCTAssertEqual(runner.requests.count, 1)
    }

    /// What colleagues were shown is what runs: an agent changed here and
    /// not published (its name, description or rights differ from the
    /// assignment) does not start (D3).
    func testAChangeNotPublishedDoesNotRun() async throws {
        for change in ["name", "description", "access"] {
            let (f, runner) = try fixture()
            let approval = try f.approve()
            var accepted = try XCTUnwrap(f.journal.assignment(f.key, agentId: f.agent.id.uuidString.lowercased()))
            switch change {
            case "name": accepted.name = "other"
            case "description": accepted.description = "other"
            default: accepted.access = TeamAccessProfile.edit.rawValue
            }
            try f.journal.save(accepted)
            await expectFailure(.voided("params_changed")) { try await f.launcher.launch(approvalId: approval.id) }
            XCTAssertEqual(runner.requests.count, 0, change)
            try? FileManager.default.removeItem(at: root)
        }
    }

    // (4)
    func testRepeatedEventsStartNothingMore() async throws {
        let (f, runner) = try fixture()
        let approval = try f.approve()
        XCTAssertEqual(try TeamApprovals.action(f.key, requestId: "req-1", state: "approved", journal: f.journal) { _ in false },
                       .start(approvalId: approval.id))
        _ = try await f.launcher.launch(approvalId: approval.id)
        // Its end on its way, as the app writes it with the outcome (this
        // launcher has no server to make it).
        let runId = try TeamLaunchParams.decode(approval.params).runId
        let body = try ChatCommandEnvelope(commandId: "c-end", org: f.key.orgId, type: "run.finished",
                                           args: .object(["request_id": .string("req-1"), "run_id": .string(runId)])).encoded()
        _ = try f.journal.enqueue(ChatCommandRecord(commandId: "c-end", sessionId: "s", type: "run.finished", bodyBytes: body,
                                                    orderKey: "exec:run:\(runId)", dependsOn: nil, createdAt: Date(), state: .pending), key: f.key)
        for state in ["approved", "starting", "running", "starting", "running"] {
            let action = try TeamApprovals.action(f.key, requestId: "req-1", state: state, journal: f.journal) { _ in false }
            XCTAssertEqual(action, TeamApprovals.Action.none, state)
        }
        XCTAssertEqual(runner.requests.count, 1)
    }

    // (5)
    func testNewServerGenerationVoidsAnUnspentApproval() async throws {
        let (f, runner) = try fixture()
        let approval = try f.approve()
        f.generation = "g2"
        await expectFailure(.voided("server_restored")) { try await f.launcher.launch(approvalId: approval.id) }
        XCTAssertEqual(runner.requests.count, 0)

        // On hello: voided before anything asks to launch.
        try? FileManager.default.removeItem(at: root)
        let (g, _) = try fixture()
        let other = try g.approve()
        let voided = try TeamApprovals.voidOtherGenerations(current: "g2", key: g.key, journal: g.journal)
        XCTAssertEqual(voided.map(\.id), [other.id])
        XCTAssertEqual(try TeamApprovals.action(g.key, requestId: "req-1", state: "approved", journal: g.journal) { _ in false },
                       .failStart(reason: "server_restored"))
        XCTAssertTrue(try TeamApprovals.voidOtherGenerations(current: "g1", key: g.key, journal: g.journal).isEmpty, "void stays void")
    }

    // (6)
    func testNoActiveAssignmentMeansNotAssigned() async throws {
        for state in [nil, ChatAssignment.State.pending, .removing] as [ChatAssignment.State?] {
            try? FileManager.default.removeItem(at: root)
            let (f, runner) = try fixture()
            if let state { try f.assign(state) } else {
                try f.removeAssignments()
            }
            let approval = try f.approve()
            await expectFailure(.voided("not_assigned")) { try await f.launcher.launch(approvalId: approval.id) }
            XCTAssertEqual(runner.requests.count, 0, "\(String(describing: state))")
        }
    }

    func testExpiredRequestVoidsTheApproval() async throws {
        let (f, runner) = try fixture()
        let approval = try f.approve()
        f.now = f.request.expiresAt
        await expectFailure(.voided("expired")) { try await f.launcher.launch(approvalId: approval.id) }
        XCTAssertEqual(runner.requests.count, 0)
    }

    // (7) and (8)
    func testRestartBetweenApprovalAndLaunchRunsOnceAndAResyncDoesNotRepeat() async throws {
        let (f, runner) = try fixture()
        let approval = try f.approve()
        // The app quits and starts again: a new journal handle and launcher.
        f.journal = try ChatJournal.open(files: f.files)
        f.makeLauncher()
        XCTAssertEqual(try TeamApprovals.action(f.key, requestId: "req-1", state: "approved", journal: f.journal) { _ in false },
                       .start(approvalId: approval.id))
        _ = try await f.launcher.launch(approvalId: approval.id)
        XCTAssertEqual(runner.requests.count, 1)

        // The cache is deleted and resynced; the journal is not.
        let cache = f.files.cacheURL(f.key)
        _ = try ChatStore.open(files: f.files, key: f.key)
        try FileManager.default.removeItem(at: cache)
        f.journal = try ChatJournal.open(files: f.files)
        f.makeLauncher()
        await expectFailure(.alreadyUsed) { try await f.launcher.launch(approvalId: approval.id) }
        XCTAssertEqual(runner.requests.count, 1)
    }

    // (9) and (10)
    func testRunGetsTheSavedParametersAndItsRowExistsFirst() async throws {
        let runner = RecordingRunner()
        let (f, _) = try fixture(runner)
        let fixture = try ClaudeResumeFixture()
        f.agent.sessionId = fixture.id
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        var rowAtCall: ChatRunRecord?
        let journal = f.journal
        runner.onCall = { request in rowAtCall = try? journal.run(params.runId) }
        _ = try await f.launcher.launch(approvalId: approval.id)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.sessionId, params.conversationId)
        XCTAssertEqual(request.agent.sessionId, fixture.id)
        XCTAssertEqual(request.agent.folder, f.agent.folder)
        XCTAssertFalse(request.resume)
        let args = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: fixture.root)
        XCTAssertTrue(args.joined(separator: " ").contains("--resume \(fixture.id) --fork-session --session-id \(params.conversationId)"))
        XCTAssertEqual(rowAtCall?.conversationId, params.conversationId)
        XCTAssertNil(rowAtCall?.outcome)
        XCTAssertEqual(try f.journal.run(params.runId)?.outcome, .finished)
        XCTAssertEqual(approval.paramsHash, TeamLaunchParams.hash(Data(approval.params.utf8)))
    }

    /// The guarantee by reading the code: approvals are made only by the
    /// Allow button's function, and in server mode runs start only from
    /// `TeamLauncher`.
    func testOnlyTheLauncherRunsAndOnlyAllowApproves() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var approvers: [String] = [], serverRunners: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            if text.contains("TeamApprovals.approve(") { approvers.append(name) }
            if text.contains("onProcessStarted:") && text.contains(".run(") && name != "TeamRunner.swift" { serverRunners.append(name) }
        }
        // D4 adds the Allow buttons (TeamPanelSection, TeamCallsSidebar); nothing else may.
        XCTAssertTrue(Set(approvers).isSubset(of: ["TeamPanelSection.swift", "TeamCallsSidebar.swift"]), "\(approvers)")
        XCTAssertEqual(serverRunners, ["TeamLauncher.swift"])
        let chat = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent("AgentPadKit/AgentPad/Chat"), includingPropertiesForKeys: nil)
        for url in chat {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("runner.run("), url.lastPathComponent)
        }
        let cli = try String(contentsOf: sources.appendingPathComponent("AgentPadKit/AgentPad/Team/TeamCLIHandler.swift"), encoding: .utf8)
        XCTAssertFalse(cli.contains("TeamApprovals"))
    }
}
