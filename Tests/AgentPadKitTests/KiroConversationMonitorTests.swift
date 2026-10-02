import XCTest
@testable import AgentPadKit

@MainActor
final class KiroConversationMonitorTests: XCTestCase {
    func testParsesSessionNewResponseByMatchingJSONRPCId() {
        let records = """
        {"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/tmp/project"}}
        {"jsonrpc":"2.0","id":7,"result":{"sessionId":"kiro-session-1"}}
        """
        XCTAssertEqual(
            KiroConversationMonitor.latestSessionId(in: records),
            "kiro-session-1"
        )
    }

    func testParsesNestedRecorderEnvelope() {
        let records = """
        {"direction":"client-to-agent","message":{"jsonrpc":"2.0","id":"req-1","method":"session/new","params":{}}}
        {"direction":"agent-to-client","message":{"jsonrpc":"2.0","id":"req-1","result":{"session_id":"kiro-session-2"}}}
        """
        XCTAssertEqual(
            KiroConversationMonitor.latestSessionId(in: records),
            "kiro-session-2"
        )
    }

    func testIgnoresUnrelatedSessionIds() {
        let records = """
        {"jsonrpc":"2.0","method":"session/notification","params":{"sessionId":"subagent-or-tool-id"}}
        {"jsonrpc":"2.0","id":9,"result":{"sessionId":"response-without-request"}}
        """
        XCTAssertNil(KiroConversationMonitor.latestSessionId(in: records))
    }

    func testLatestSessionNewWinsAfterInTUIChatNew() {
        let records = """
        {"id":1,"method":"session/new"}
        {"id":1,"result":{"sessionId":"first"}}
        {"id":2,"method":"session/new"}
        {"id":2,"result":{"sessionId":"second"}}
        """
        XCTAssertEqual(KiroConversationMonitor.latestSessionId(in: records), "second")
    }

    func testSessionLoadUpdatesCurrentId() {
        let records = """
        {"id":1,"method":"session/new"}
        {"id":1,"result":{"sessionId":"first"}}
        {"id":2,"method":"session/load","params":{"sessionId":"restored"}}
        {"id":2,"result":{}}
        """
        XCTAssertEqual(KiroConversationMonitor.latestSessionId(in: records), "restored")
    }

    func testAcceptsRecorderLinePrefix() {
        let records = """
        outbound 2026-07-23 {"id":1,"method":"session/new"}
        inbound 2026-07-23 {"id":1,"result":{"sessionId":"prefixed"}}
        """
        XCTAssertEqual(KiroConversationMonitor.latestSessionId(in: records), "prefixed")
    }

    func testStopRemovesRecordWhenSessionEnds() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-kiro-record-\(UUID().uuidString).jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let monitor = KiroConversationMonitor()
        let sessionId = UUID()
        monitor.start(sessionId: sessionId, path: file.path) { _ in }
        monitor.stop(sessionId: sessionId, removeRecord: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testStopPreservesRecordForCrossWindowHandoff() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-kiro-handoff-\(UUID().uuidString).jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let monitor = KiroConversationMonitor()
        let sessionId = UUID()
        monitor.start(sessionId: sessionId, path: file.path) { _ in }
        monitor.stop(sessionId: sessionId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
