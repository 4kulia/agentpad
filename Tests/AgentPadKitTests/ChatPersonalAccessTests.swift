import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatPersonalAccessTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-boundary-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root); ChatStubProtocol.reset() }

    func testHistorySurvivesCacheRemovalAndJournalResetAndFailsClosed() throws {
        let files = ChatFiles(directory: root), id = UUID().uuidString.lowercased()
        let history = ChatDMHistory(files: files)
        XCTAssertFalse(try history.contains(id))
        try history.record(id)
        try history.record(id.uppercased())
        _ = try ChatJournal.reset(files: files)
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"), accountId: "a", orgId: "o")
        files.removeCache(key)
        XCTAssertTrue(try ChatDMHistory(files: files).contains(id))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: history.url)), [id])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: history.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("broken".utf8).write(to: history.url)
        XCTAssertThrowsError(try history.record(UUID().uuidString))
        XCTAssertTrue(history.needsFreshSession(UUID().uuidString))
    }

    func testDMHistoryStartsExecutorFreshForSourceAndResume() throws {
        let transcripts = try ClaudeResumeFixture()
        let files = ChatFiles(directory: root)
        var agent = TeamPublishedAgent(name: "fixture", description: "", folder: root.path)
        agent.sessionId = transcripts.id
        let freshID = UUID().uuidString.lowercased()
        var request = TeamRunRequest(agent: agent, prompt: "", sessionId: freshID, resume: false, callerName: "Peer", callerProject: nil)
        request.dmHistoryFiles = files
        XCTAssertTrue(try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcripts.root).contains("--fork-session"))
        try ChatDMHistory(files: files).record(transcripts.id)
        let args = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcripts.root)
        XCTAssertFalse(args.contains("--resume")); XCTAssertFalse(args.contains("--fork-session"))
        XCTAssertTrue(args.contains(freshID))
        request = TeamRunRequest(agent: agent, prompt: "", sessionId: transcripts.id, resume: true, callerName: "Peer", callerProject: nil)
        request.dmHistoryFiles = files
        let resumed = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcripts.root)
        XCTAssertFalse(resumed.contains("--resume")); XCTAssertFalse(resumed.contains(transcripts.id))
    }

    func testAllRunKindsAndPublicationAreDeniedIndependentlyOfSignature() async throws {
        let f = try await ChatChannelExecutionTests.Fixture(root: root)
        let conversation = ChatPersonalAccess.Conversation(UUID().uuidString)
        let caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 2, claudeStart: 3, signature: "Personal")
        try ChatPersonalAccess.require(conversation, caller: caller, service: f.service)
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
        }
        for kind in ["personal", "channel", "future-kind"] {
            try await f.journal.queue.write { db in
                try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, kind) VALUES (?, 'r', 'a', 'agent', ?, ?, ?)",
                               arguments: [UUID().uuidString, conversation.id, Date(), kind])
            }
            XCTAssertThrowsError(try ChatPersonalAccess.require(conversation, caller: caller, service: f.service))
            try await f.journal.queue.write { try $0.execute(sql: "DELETE FROM runs") }
        }
        f.agent.sessionId = conversation.id
        f.agent.enabled = false
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: caller, generation: "g1"), .session("Personal"))
        XCTAssertThrowsError(try ChatPersonalAccess.require(conversation, caller: caller, service: f.service))
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        await f.service.disconnect()
    }

    func testUntrustedHistorySurfaceAndProcessCannotBorrowPersonalBinding() throws {
        let fixture = AnswerProcessFixture()
        let engine = TestEngine(); engine.foregroundPid = AnswerProcessFixture.claude
        let session = Session(engine: engine, currentDirectory: root, agent: .claudeCode)
        let id = UUID().uuidString.lowercased()
        session.conversationId = id
        let process = try XCTUnwrap(fixture.inspector.kernel.process(AnswerProcessFixture.claude))
        let caller = ChatLocalCaller(surface: session.id.uuidString.lowercased(), claudePID: process.pid, claudeStart: process.startedAtUs, signature: "Personal")
        func conversation(_ caller: ChatLocalCaller) throws -> ChatPersonalAccess.Conversation {
            try ChatPersonalAccess.conversation(caller: caller, sessions: [session], kernel: fixture.inspector.kernel)
        }
        XCTAssertThrowsError(try conversation(caller))
        session.answerBinding = .init(conversation: id, process: process)
        XCTAssertThrowsError(try conversation(caller))
        try fixture.bind(session, conversation: id)
        XCTAssertEqual(try conversation(caller), .init(id))
        for altered in [ChatLocalCaller(surface: UUID().uuidString, claudePID: process.pid, claudeStart: process.startedAtUs, signature: "Personal"),
                        ChatLocalCaller(surface: caller.surface, claudePID: process.pid + 1, claudeStart: process.startedAtUs, signature: "Personal"),
                        ChatLocalCaller(surface: caller.surface, claudePID: process.pid, claudeStart: process.startedAtUs + 1, signature: "Personal")] {
            XCTAssertThrowsError(try conversation(altered))
        }
        session.conversationId = UUID().uuidString
        XCTAssertThrowsError(try conversation(caller))
        session.conversationId = id
        fixture.add(process.pid, parent: process.parent, name: "replaced-image")
        XCTAssertThrowsError(try conversation(caller), "same PID/start must not survive exec")
    }

    func testSavedResumeIDsUnverifiedHooksAndForeignOwnersCannotAuthorizePersonalTools() throws {
        let fixture = AnswerProcessFixture(), id = UUID().uuidString.lowercased()
        let session = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode,
            conversationId: id, launchedConversationId: id)
        session.resumedConversationId = id
        let caller = ChatLocalCaller(surface: session.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
            claudeStart: 100, signature: "Personal")
        func conversation() throws -> ChatPersonalAccess.Conversation {
            try ChatPersonalAccess.conversation(caller: caller, sessions: [session], kernel: fixture.inspector.kernel)
        }
        XCTAssertThrowsError(try conversation(), "restored metadata is not process evidence")
        try fixture.bind(session, conversation: id)
        XCTAssertNoThrow(try conversation())
        AgentAnswerSource.recordHook(conversation: id, session: session, provenance: nil, inspector: fixture.inspector)
        XCTAssertThrowsError(try conversation(), "an unauthenticated hook cannot retain old trust")
        let foreign: Int32 = 99_999_990
        fixture.add(foreign, parent: AnswerProcessFixture.shell, name: "claude", trusted: true)
        fixture.add(AnswerProcessFixture.hook, parent: foreign, name: "agentpad-hook")
        let hook = try AgentAnswerProvenance.verifyHook(parentPID: foreign,
            origin: .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100), inspector: fixture.inspector)
        AgentAnswerSource.recordHook(conversation: id, session: session, provenance: nil, hook: hook, inspector: fixture.inspector)
        XCTAssertThrowsError(try conversation(), "a hook routed to another surface cannot borrow its caller")
    }
}
