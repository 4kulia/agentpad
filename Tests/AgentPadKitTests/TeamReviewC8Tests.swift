import Darwin
import XCTest
@testable import AgentPadKit

/// Eighth client review (review-client-c8.md): the owner's stop reaches only
/// what was shown; left-over runs are kept by identity and on disk; a fact
/// only from a state read and known.
@MainActor
final class TeamReviewC8Tests: XCTestCase {
    private var root: URL!
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c8-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 1 — a `claude` found is the process whose arguments were read


    func testStopReachesOnlyWhatWasShown() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f1"), runner: RecordingRunner())
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        XCTAssertTrue(try f.journal.consume(approval, run: ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, startedAt: f.now)))
        // What was shown: a process that ended; its number now holds another.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        let now = ProcessIdentity(pid: other.processIdentifier, startTime: try XCTUnwrap(TeamProcesses.startTime(other.processIdentifier)))
        let shown = ProcessIdentity(pid: now.pid, startTime: now.startTime &- 1)
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        r.facts = facts
        r.stopGrace = .milliseconds(50)
        r.find = { _ in [shown] }
        await r.check()
        XCTAssertEqual(r.blocked.first?.found, [shown])
        // At the press the number holds another process.
        r.find = { _ in [now] }
        let log = SignalLog()
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        _ = await r.stopProcesses(params.runId)
        XCTAssertTrue(log.calls.isEmpty, "not what was shown: no signal")
    }
    private let facts = RecordingFacts()

    // MARK: 2 — left-overs by identity: a new run with the same number keeps the old one

    func testLeftOverIsNotReplacedByARunWithTheSameNumber() {
        let registry = TeamProcesses()
        let first = TeamProcessStart(pid: 999_980, pgid: 999_980, startTime: 1)
        let second = TeamProcessStart(pid: 999_980, pgid: 999_980, startTime: 2)
        XCTAssertTrue(registry.add(first, seen: TeamPidSet([ProcessIdentity(pid: 999_979, startTime: 5)]), agentId: "a"))
        registry.markLeftOver(first)
        XCTAssertTrue(registry.add(second, agentId: "b"))
        XCTAssertTrue(registry.blocks(agentId: "a"), "the earlier run's left-over is still there")
        XCTAssertEqual(registry.seen(of: first)?.identities, [ProcessIdentity(pid: 999_979, startTime: 5)])
        registry.remove(second)
        XCTAssertTrue(registry.blocks(agentId: "a"))
    }

    func testRunnerRefusesAnAgentWithALeftOver() async throws {
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: root.path)
        let leader = TeamProcessStart(pid: 999_978, pgid: 999_978, startTime: 1)
        TeamProcesses.shared.add(leader, agentId: agent.id.uuidString.lowercased())
        TeamProcesses.shared.markLeftOver(leader)
        defer { TeamProcesses.shared.remove(leader) }
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: "c", resume: false, callerName: "M", callerProject: nil)
        do {
            _ = try await ClaudeCodeRunner(claudePath: "/usr/bin/true").run(request, onActivity: { _ in })
            XCTFail("ran")
        } catch TeamRunnerError.didNotStart {
        } catch { XCTFail("\(error)") }
    }

    // MARK: 3 — a left-over kept on disk blocks across a crash



    // MARK: 4 — the state used for the fact is the state read for it

    func testStateThatCannotBeReadAgainMakesNoFact() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        try files.prepareDirectory()
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let f = try ExecutorFixture(root: root.appendingPathComponent("f4"), runner: RecordingRunner())
        f.journal = try ChatJournal.open(files: files)
        try f.assign(.active)
        await service.recoverRunsAtLaunch()
        let journal = try XCTUnwrap(service.journal)
        try journal.finish(f.key, "g1")
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, startedAt: f.now)
        XCTAssertTrue(try journal.consume(approval, run: row))
        service.isServerKnown = { _, _ in true }
        // "running", then a read that fails.
        var reads = 0
        service.requestState = { _, _ in
            reads += 1
            return reads == 1 ? "running" : nil
        }
        XCTAssertFalse(TeamLauncher.finish(row, .executorRestarted, reason: "executor_restarted", journal: journal, facts: service))
        XCTAssertNil(try journal.run(row.runId)?.outcome)
        XCTAssertTrue(try journal.commands(for: f.key).isEmpty, "no fact")
        XCTAssertNotNil(try journal.run(row.runId)?.processesGoneAt, "the row waits")
    }
}
