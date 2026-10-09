import AgentPadHookKit
import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatPersonalLifecycleTests: XCTestCase {
    private var root: URL!
    private var f: ChatChannelExecutionTests.Fixture!
    private var socket: ChatSocket!
    private let processes = AnswerProcessFixture()
    private let mcp: Int32 = 99_999_980
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let attachment = UUID().uuidString.lowercased()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("personal-lifecycle-\(UUID())")
        f = try await ChatChannelExecutionTests.Fixture(root: root)
        f.service.isServerKnown = { _, _ in true }
        f.service.dmToolsEnabled = { true }
        f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.dm.session_signature", "chat.session_tools", "chat.attachments"]
        f.service.serverAttachmentLimits[f.key.server] = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        socket = ChatSocket(server: f.key.server, token: "test-only", makeTransport: { FakeSocketTransport() })
        let sync = ChatSync(key: f.key, store: f.store, api: f.service.makeAPI(f.key.server), socket: socket, outbox: nil, token: "test-only")
        f.service.orgSessions[f.key]?.sync = sync
        sync.dm.sessionId = f.service.connection?.sessionId
        sync.dm.configure(true)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"dms":[],"next":null}"#.utf8))) }
        try await sync.dm.reloadCatalog(valid: { true })
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        socket?.stop()
        await f?.service.disconnect()
        f = nil
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ tab: Session, download: Bool = false, pid: Int32? = nil) async -> AgentPadCLIResponse {
        var request = AgentPadCLIRequest(verb: .team)
        request.chatArguments = download
            ? "{\"tool\":\"chat_read\",\"org_id\":\"\(f.key.orgId)\",\"channel_id\":\"\(channel)\",\"attachment_id\":\"\(attachment)\"}"
            : #"{"tool":"chat_channels","scope":"members"}"#
        return await ChatSessionTools.handle(request, origin: .localProcess(pid: pid ?? mcp, startedAtUs: 100),
            sessions: { [tab] }, service: f.service, signatureVerifier: processes.inspector.signed,
            scan: processes.inspector.scan, kernel: processes.inspector.kernel)
    }

    private func bind(_ tab: Session, _ id: String) throws {
        try processes.bind(tab, conversation: id)
        tab.conversationId = id
    }

    func testRestoredResumeAllowsMembersAndAttachmentWhenMCPStartsDuringHookDelivery() async throws {
        let transcript = try ClaudeResumeFixture()
        let original = makeTestStore(claudeProjectsRoot: transcript.root)
        let opened = original.addTab(in: try XCTUnwrap(original.active), template: .claudeCode, conversationId: transcript.id)
        let saved = PersistedState(workspaces: original.workspaces.map(PersistedWorkspace.init), activeWorkspaceId: original.activeWorkspaceId)
        original.terminate()
        let store = makeTestStore(persistence: InMemoryPersistence(initial: saved), claudeProjectsRoot: transcript.root)
        defer { store.terminate() }
        let tab = try XCTUnwrap(store.active?.root.allPanes.flatMap(\.tabs).first { $0.id == opened.id })
        XCTAssertEqual((tab.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"], "claude --resume \(transcript.id)")
        XCTAssertEqual(tab.launchedConversationId, transcript.id)
        (tab.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
        let proof = try XCTUnwrap(processes.capture())
        // SessionStart is authenticated before ACK; Claude starts its MCP child
        // before the main actor applies the hook. Export's TTY snapshot expires.
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        AgentAnswerSource.recordHook(conversation: transcript.id, session: tab, provenance: proof, inspector: processes.inspector)
        XCTAssertNil(tab.answerBinding)
        XCTAssertEqual(tab.answerBindingProblem, .changed)

        let members = await call(tab)
        XCTAssertTrue(members.ok, members.chatResult ?? "")
        XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(transcript.id))
        let body = Data("""
        {"messages":[{"message_id":"\(UUID())","channel_id":"\(channel)","author_account_id":"\(CallJSON.boris)","text":"file","mentions":[],"revision":1,"seq":1,"created_at":"2026-10-09T00:00:00Z","attachments":[{"attachment_id":"\(attachment)","position":0,"name":"notes.txt","mime":"text/plain","size":5,"has_preview":false}]}],"next":null}
        """.utf8)
        ChatStubProtocol.reset { request, _ in
            .success(.init(status: 200, body: request.url!.path.hasSuffix("/original") ? Data("notes".utf8) : body))
        }
        let downloaded = await call(tab, download: true)
        XCTAssertTrue(downloaded.ok, downloaded.chatResult ?? "")
        let result = try JSONDecoder().decode(ChatJSON.self, from: Data((downloaded.chatResult ?? "{}").utf8))
        let path = try XCTUnwrap(result["path"]?.string)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("notes".utf8))
    }

    func testFreshTabWaitsForLateHookAndClearUsesNewConversationThroughMCPParentChain() async throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let tab = store.addTab(in: try XCTUnwrap(store.active), template: .claudeCode)
        XCTAssertNil(tab.launchedConversationId)
        XCTAssertNil(tab.conversationId)
        (tab.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let helper: Int32 = 99_999_981
        processes.add(helper, parent: mcp, name: "agentpad-cli")
        let first = UUID().uuidString.lowercased()
        let pending = Task { await self.call(tab, pid: helper) }
        try await Task.sleep(for: .milliseconds(100))
        try bind(tab, first)
        let members = await pending.value
        XCTAssertTrue(members.ok, members.chatResult ?? "")
        let cleared = UUID().uuidString.lowercased()
        try bind(tab, cleared)
        let afterClear = await call(tab, pid: helper)
        XCTAssertTrue(afterClear.ok, afterClear.chatResult ?? "")
        let history = ChatDMHistory(files: f.service.files)
        XCTAssertTrue(try history.contains(first))
        XCTAssertTrue(try history.contains(cleared))
    }

    func testSocketRetainsAuthenticatedConversationWhenUnrelatedTTYProcessExitsDuringExportScan() async throws {
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        (tab.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        processes.add(AnswerProcessFixture.hook, parent: AnswerProcessFixture.claude, name: "agentpad-hook", terminal: nil)
        let transient: Int32 = 99_999_982
        processes.add(transient, parent: AnswerProcessFixture.claude, name: "helper")
        var inspector = processes.inspector
        let scan = inspector.scan, processes = processes
        inspector.scan = { pid in
            let rows = scan(pid)
            processes.remove(transient)
            return rows
        }
        let path = NSTemporaryDirectory() + "personal-hook-\(UUID().uuidString.prefix(8)).sock"
        let received = expectation(description: "authenticated conversation despite failed export scan")
        let id = UUID().uuidString.lowercased()
        let server = HookServer(socketPath: path, answerInspector: inspector) { message in
            guard case .conversationId(let conversation, _, let proof, let failure, let hook) = message else { return }
            XCTAssertNil(proof)
            XCTAssertEqual(failure, .processUnavailable)
            XCTAssertEqual(hook?.owner.process.pid, AnswerProcessFixture.claude)
            AgentAnswerSource.recordHook(conversation: conversation, session: tab, provenance: proof,
                failure: failure, hook: hook, inspector: processes.inspector)
            tab.conversationId = conversation
            received.fulfill()
        }
        server.originOf = { _ in .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100) }
        server.start()
        defer { server.stop() }
        let payload = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString, conversationId: id,
            claudeParentPID: AnswerProcessFixture.claude)
        let sent = await Task.detached { AgentPadHookKit.sendPayload(payload, to: path) }.value
        XCTAssertTrue(sent)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertNil(tab.answerBinding)
        let members = await call(tab)
        XCTAssertTrue(members.ok, members.chatResult ?? "")
    }

    func testPersonalBindingStillDeniesPublishedSurfacesSourcesAndEveryRunHistory() async throws {
        let launch = UUID().uuidString.lowercased(), current = UUID().uuidString.lowercased()
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode, launchedConversationId: launch)
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        try bind(tab, current)
        tab.answerBinding = nil // exercise the independent personal binding
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
        }
        for id in [launch, current] {
            for kind in ["personal", "channel", "future-kind"] {
                try await f.journal.queue.write { db in
                    try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, ended_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, ?, ?)", arguments: [id.uppercased(), Date(), Date(), kind])
                }
                for download in [false, true] {
                    let result = await call(tab, download: download)
                    XCTAssertEqual(result.error, "dm_not_allowed", "\(kind): \(id)")
                }
                try await f.journal.queue.write { try $0.execute(sql: "DELETE FROM runs") }
            }
            f.agent.sessionId = id
            f.agent.enabled = false
            let result = await call(tab)
            XCTAssertEqual(result.error, "dm_not_allowed")
        }
        f.agent.sessionId = nil
        let key = f.key, surface = tab.id.uuidString.lowercased()
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO publication_surfaces (server, account_id, org_id, agent_id, surface_id, session_id, generation) VALUES (?, ?, ?, ?, ?, 's-anna', 'g1')",
                arguments: [key.server.description, key.accountId, key.orgId, CallJSON.agent, surface])
        }
        let published = await call(tab)
        XCTAssertEqual(published.error, "dm_not_allowed")
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(current))
    }

    func testLateHookCannotAuthorizeReusedCallerPID() async throws {
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        (tab.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let pending = Task { await self.call(tab) }
        try await Task.sleep(for: .milliseconds(100))
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli", start: 101)
        try bind(tab, UUID().uuidString.lowercased())
        let result = await pending.value
        XCTAssertEqual(result.error, "dm_not_allowed")
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testClearDuringPrivateReadDiscardsResponseWithoutTaintingEitherConversation() async throws {
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let first = UUID().uuidString.lowercased(), cleared = UUID().uuidString.lowercased()
        try bind(tab, first)
        let gate = Gate(), entered = expectation(description: "DM read in flight")
        gate.close()
        defer { gate.open() }
        ChatStubProtocol.reset { _, _ in
            entered.fulfill()
            gate.pass()
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null}"#.utf8)))
        }
        var request = AgentPadCLIRequest(verb: .team)
        request.chatArguments = "{\"tool\":\"chat_read\",\"org_id\":\"\(f.key.orgId)\",\"kind\":\"dm\",\"dm_id\":\"\(UUID())\"}"
        let pending = Task {
            await ChatSessionTools.handle(request, origin: .localProcess(pid: mcp, startedAtUs: 100),
                sessions: { [tab] }, service: f.service, signatureVerifier: processes.inspector.signed,
                scan: processes.inspector.scan, kernel: processes.inspector.kernel)
        }
        await fulfillment(of: [entered], timeout: 3)
        try bind(tab, cleared)
        gate.open()
        let response = await pending.value
        XCTAssertEqual(response.error, "dm_not_allowed")
        let history = ChatDMHistory(files: f.service.files)
        XCTAssertFalse(try history.contains(first))
        XCTAssertFalse(try history.contains(cleared))
    }
}
