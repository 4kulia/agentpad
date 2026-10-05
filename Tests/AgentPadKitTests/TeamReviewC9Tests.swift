import Darwin
import XCTest
@testable import AgentPadKit

/// Ninth client review (review-client-c9.md): after a crash only the
/// recorded leader is looked at; the move to a server waits for direct runs.
@MainActor
final class TeamReviewC9Tests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c9-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// C9-1: a run's processes are its recorded leader (and what this app saw
    /// under it) — never a process found by its arguments.
    func testOnlyTheRecordedLeaderIsLookedAt() async throws {
        let f = try ExecutorFixture(root: root.appendingPathComponent("f1"), runner: RecordingRunner())
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/bin/sleep")
        leader.arguments = ["30"]
        try leader.run()
        defer { leader.terminate() }
        // Another process naming the run's conversation.
        let script = root.appendingPathComponent("claude").path
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let namer = Process()
        namer.executableURL = URL(fileURLWithPath: script)
        namer.arguments = ["--session-id", params.conversationId]
        try namer.run()
        defer { namer.terminate() }
        let start = try XCTUnwrap(TeamProcesses.startTime(leader.processIdentifier))
        XCTAssertTrue(try f.journal.consume(approval, run: ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, pid: leader.processIdentifier, pgid: leader.processIdentifier,
            processStartedAt: start, startedAt: f.now)))
        let r = TeamRunRecovery(journal: f.journal) { _ in false }
        let facts = RecordingFacts()
        r.facts = facts
        await r.check()
        XCTAssertEqual(r.blocked.first?.found, [ProcessIdentity(pid: leader.processIdentifier, startTime: start)])
    }

}
