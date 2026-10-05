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
}
