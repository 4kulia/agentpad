import Darwin
import XCTest
@testable import AgentPadKit

/// Eleventh client review (review-client-c11.md).
@MainActor
final class TeamReviewC11Tests: XCTestCase {
    private var root: URL!
    private var savedSend: ((pid_t, Int32, Bool) -> Void)?

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c11-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedSend = TeamProcesses.sendSignal
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        if let savedSend { TeamProcesses.sendSignal = savedSend }
        TeamRunAdmission.journalBlocks = { _ in false }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// C11-3: a run journal that cannot be opened: no agent starts, in any mode.
    func testUnopenableJournalBlocksEveryRun() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc"))
        try files.prepareDirectory()
        try Data("not a database".utf8).write(to: files.journalURL)
        let service = ChatService(files: files, tokens: FakeTokenStore())
        await service.recoverRunsAtLaunch()
        XCTAssertNotNil(service.journalProblem)
        let agent = TeamPublishedAgent(name: "x", description: "d", folder: root.path)
        XCTAssertTrue(TeamRunAdmission.journalBlocks(agent.id.uuidString.lowercased()))
        let request = TeamRunRequest(agent: agent, prompt: "p", sessionId: "s", resume: false, callerName: "M", callerProject: nil)
        do {
            _ = try await ClaudeCodeRunner(claudePath: "/usr/bin/true").run(request, onActivity: { _ in })
            XCTFail("ran")
        } catch TeamRunnerError.didNotStart {
        } catch { XCTFail("\(error)") }
    }

    /// C11-4: one left-over's button reaches its own processes only.
    func testOneLeftOversStopReachesOnlyIt() async throws {
        var processes: [Process] = []
        for _ in 0..<2 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["30"]
            try p.run()
            processes.append(p)
        }
        defer { processes.forEach { $0.terminate() } }
        let leaders = try processes.map { p in
            TeamProcessStart(pid: p.processIdentifier, pgid: getpgid(p.processIdentifier),
                             startTime: try XCTUnwrap(TeamProcesses.startTime(p.processIdentifier)))
        }
        for (i, leader) in leaders.enumerated() {
            TeamProcesses.shared.add(leader, agentId: "agent-\(i)")
            TeamProcesses.shared.markLeftOver(leader)
        }
        defer { leaders.forEach { TeamProcesses.shared.remove($0) } }
        let log = SignalLog()
        TeamProcesses.sendSignal = { pid, sig, group in log.add(pid, sig, group) }
        let task = Task { await TeamProcesses.shared.stopLeftOver(leaders[0]) }
        try await Task.sleep(for: .milliseconds(200))
        TeamProcesses.sendSignal = savedSend!
        processes[0].terminate()
        await task.value
        XCTAssertFalse(log.calls.isEmpty)
        XCTAssertTrue(log.calls.allSatisfy { $0.pid == leaders[0].pid }, "only the chosen left-over's processes")
    }
}
