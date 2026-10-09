import Foundation
import GRDB
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSessionDMToolsTests: XCTestCase {
    var root: URL!
    var f: ChatChannelExecutionTests.Fixture!
    var sync: ChatDMSync!
    let dm = "2c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
    var conversation = UUID().uuidString.lowercased()
    var caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 321, claudeStart: 123, signature: "My tab")
    var valid = true
    var socket: ChatSocket!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-mcp-\(UUID())")
        f = try await ChatChannelExecutionTests.Fixture(root: root)
        f.service.dmToolsEnabled = { true }
        f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.dm.session_signature"]
        socket = ChatSocket(server: f.key.server, token: "test-only", makeTransport: { FakeSocketTransport() })
        let owner = ChatSync(key: f.key, store: f.store, api: f.service.makeAPI(f.key.server), socket: socket, outbox: nil, token: "test-only")
        f.service.orgSessions[f.key]?.sync = owner
        sync = owner.dm; sync.sessionId = f.service.connection?.sessionId
        sync.configure(true)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"dms":[],"next":null}"#.utf8))) }
        try await sync.reloadCatalog(valid: { true })
        ChatStubProtocol.reset()
    }
    override func tearDown() async throws {
        socket?.stop(); sync?.stop(); await f?.service.disconnect(); f = nil
        ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: root)
    }
    func call(_ tool: String, _ args: [String: ChatJSON] = [:]) async throws -> ChatJSON {
        var args = args; args["tool"] = .string(tool); args["org_id"] = .string(f.key.orgId)
        return try await ChatSessionTools.call(.object(args), caller: caller, service: f.service,
            personalConversation: { .init(self.conversation) }, revalidate: { self.valid })
    }
    func refused(_ code: String, _ operation: () async throws -> ChatJSON, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertEqual((error as? ChatSessionTools.Failure)?.code, code, file: file, line: line) }
    }
    func card() -> Data {
        Data("""
        {"dm_id":"\(dm)","peer":{"account_id":"\(CallJSON.boris)","name":"Peer","handle":"peer","active":true},"state":"active","version":1,"created_at":"2026-10-09T00:00:00Z"}
        """.utf8)
    }

    private let mcp: Int32 = 99_999_980

    private func authenticatedCall(_ args: [String: ChatJSON], tab: Session, processes: AnswerProcessFixture,
                                   origin: AgentPadCallerOrigin? = nil) async throws -> AgentPadCLIResponse {
        var request = AgentPadCLIRequest(verb: .team)
        request.chatArguments = String(decoding: try JSONEncoder().encode(ChatJSON.object(args)), as: UTF8.self)
        return await ChatSessionTools.handle(request, origin: origin ?? .localProcess(pid: mcp, startedAtUs: 100),
            sessions: { [tab] }, service: f.service, signatureVerifier: processes.inspector.signed,
            scan: processes.inspector.scan, kernel: processes.inspector.kernel)
    }

    private func serveDM(beforeResponse: @escaping @Sendable () -> Void = {}) {
        let card = card(), dm = dm
        ChatStubProtocol.reset { request, bytes in
            beforeResponse()
            if request.httpMethod == "POST" {
                let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes)
                let result: ChatJSON = command.type == "dm.open" ? .object(["dm_id": .string(dm)]) :
                    .object(["dm_id": .string(dm), "message_id": command.args["message_id"]!,
                             "author_session_name": command.args["author_session_name"]!])
                return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatCommandAnswer(events: [], result: result))))
            }
            let body: Data
            if request.url!.path.hasSuffix("/dms") {
                body = Data("{\"dms\":[\(String(decoding: card, as: UTF8.self))],\"next\":null}".utf8)
            } else if request.url!.path.hasSuffix("/messages") || request.url!.path.contains("/threads/") {
                body = Data(#"{"messages":[],"next":null}"#.utf8)
            } else { body = card }
            return .success(.init(status: 200, body: body))
        }
    }

    /// Exercise the real handler, including MCP identity and conversation
    /// binding. The lower-level call() fixture supplies an approved ID and
    /// cannot catch the released app's intermittent hook/export rejection.
    private func afterSuccessfulSendAndBatchHook(_ args: [String: ChatJSON],
                                                file: StaticString = #filePath, line: UInt = #line) async throws -> ChatJSON {
        let processes = AnswerProcessFixture()
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        tab.customTitle = "Personal fixture"
        try processes.bind(tab, conversation: conversation)
        tab.conversationId = conversation
        XCTAssertNil(tab.launchedConversationId, "This is a new tab, not a restore")
        serveDM()
        let members = try await authenticatedCall(["tool": .string("chat_channels"), "scope": .string("members")], tab: tab, processes: processes)
        XCTAssertTrue(members.ok, members.chatResult ?? "", file: file, line: line)
        let people = try JSONDecoder().decode(ChatJSON.self, from: Data((members.chatResult ?? "{}").utf8))["members"]
        guard case .array(let people) = people else { throw ChatSessionTools.Failure(code: "missing_members") }
        XCTAssertEqual(people.count, 1, file: file, line: line)
        let sent = try await authenticatedCall(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "peer_account_id": .string(CallJSON.boris), "text": .string("hello")], tab: tab, processes: processes)
        let sentJSON = try JSONDecoder().decode(ChatJSON.self, from: Data((sent.chatResult ?? "{}").utf8))
        XCTAssertTrue(sent.ok, sent.chatResult ?? "", file: file, line: line)
        XCTAssertEqual(sentJSON["status"], .string("sent"), file: file, line: line)
        XCTAssertEqual(sentJSON["dm_id"], .string(dm), file: file, line: line)
        XCTAssertEqual(sentJSON["author_session_name"], .string("Personal fixture"), file: file, line: line)
        XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(conversation))

        // PostToolBatch mirrors the ID even in 1.1.13. A helper starting
        // between authentication and delivery invalidates export provenance,
        // although the signed Claude, its conversation and MCP child are unchanged.
        let batch = AgentPadHookKit.buildToolBatchPayload(agent: "claude", surface: tab.id.uuidString)
        XCTAssertTrue(AgentPadHookKit.shouldMirrorClaudeConversationId(payload: batch, environment: [:]))
        let proof = try XCTUnwrap(processes.capture())
        processes.add(99_999_981, parent: AnswerProcessFixture.claude, name: "helper")
        AgentAnswerSource.recordHook(conversation: conversation, session: tab, provenance: proof, inspector: processes.inspector)
        XCTAssertNil(tab.answerBinding)
        XCTAssertEqual(tab.answerBindingProblem, .changed)

        let response = try await authenticatedCall(args, tab: tab, processes: processes)
        XCTAssertTrue(response.ok, response.chatResult ?? "", file: file, line: line)
        return try JSONDecoder().decode(ChatJSON.self, from: Data((response.chatResult ?? "{}").utf8))
    }

    func testFreshPersonalDMListWithOrgAfterSuccessfulSendAndBatchHook() async throws {
        let result = try await afterSuccessfulSendAndBatchHook(["tool": .string("chat_channels"),
            "scope": .string("dms"), "org_id": .string(f.key.orgId)])
        XCTAssertEqual(result["org_id"], .string(f.key.orgId))
        guard case .array(let cards) = result["dms"] else { return XCTFail("Missing DM catalog") }
        XCTAssertEqual(cards.first?["dm_id"], .string(dm))
    }

    func testFreshPersonalDMListWithoutOrgAfterSuccessfulSendAndBatchHook() async throws {
        let result = try await afterSuccessfulSendAndBatchHook(["tool": .string("chat_channels"), "scope": .string("dms")])
        XCTAssertEqual(result["org_id"], .string(f.key.orgId))
        guard case .array(let cards) = result["dms"] else { return XCTFail("Missing DM catalog") }
        XCTAssertEqual(cards.first?["dm_id"], .string(dm))
    }

    func testFreshPersonalDMOpenAfterSuccessfulSendAndBatchHook() async throws {
        let result = try await afterSuccessfulSendAndBatchHook(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "peer_account_id": .string(CallJSON.boris), "open_only": .bool(true)])
        XCTAssertEqual(result["status"], .string("opened"))
        XCTAssertEqual(result["dm_id"], .string(dm))
    }

    func testFreshPersonalDMReadAfterSuccessfulSendAndBatchHook() async throws {
        let result = try await afterSuccessfulSendAndBatchHook(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "dm_id": .string(dm)])
        XCTAssertEqual(result["messages"], .array([]))
        XCTAssertEqual(result["dm_id"], .string(dm))
        XCTAssertEqual(try f.store.dmRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_marks") }, 0)
    }

    private var personalDMOperations: [[String: ChatJSON]] {
        [
            ["tool": .string("chat_channels"), "scope": .string("members")],
            ["tool": .string("chat_channels"), "scope": .string("dms")],
            ["tool": .string("chat_channels"), "scope": .string("dms"), "org_id": .string(f.key.orgId)],
            ["tool": .string("chat_post"), "org_id": .string(f.key.orgId), "kind": .string("dm"),
             "peer_account_id": .string(CallJSON.boris), "open_only": .bool(true)],
            ["tool": .string("chat_post"), "org_id": .string(f.key.orgId), "kind": .string("dm"),
             "peer_account_id": .string(CallJSON.boris), "text": .string("hello")],
            ["tool": .string("chat_post"), "org_id": .string(f.key.orgId), "kind": .string("dm"),
             "dm_id": .string(dm), "text": .string("hello")],
            ["tool": .string("chat_read"), "org_id": .string(f.key.orgId), "kind": .string("dm"), "dm_id": .string(dm)],
            ["tool": .string("chat_read"), "org_id": .string(f.key.orgId), "kind": .string("dm"),
             "dm_id": .string(dm), "thread_root_id": .string(UUID().uuidString)]
        ]
    }

    func testEveryDMOperationAllowsPersonalConversationAlreadyInDMHistory() async throws {
        let processes = AnswerProcessFixture()
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        try processes.bind(tab, conversation: conversation)
        tab.conversationId = conversation
        tab.answerBinding = nil
        try ChatDMHistory(files: f.service.files).record(conversation)
        serveDM()
        for args in personalDMOperations {
            let response = try await authenticatedCall(args, tab: tab, processes: processes)
            XCTAssertTrue(response.ok, "\(args): \(response.chatResult ?? "")")
        }
    }

    func testEveryAwaitingDMOperationDiscardsResultWhenTabBecomesPublished() async throws {
        let processes = AnswerProcessFixture()
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        try processes.bind(tab, conversation: conversation)
        tab.conversationId = conversation
        for args in personalDMOperations where args["scope"] != .string("members") {
            let entered = expectation(description: "DM request awaiting response"), gate = Gate()
            entered.assertForOverFulfill = false
            gate.close()
            defer { gate.open() }
            serveDM { entered.fulfill(); gate.pass() }
            let pending = Task { try await self.authenticatedCall(args, tab: tab, processes: processes) }
            await fulfillment(of: [entered], timeout: 3)
            let surface = tab.id.uuidString.lowercased()
            try await f.journal.queue.write { db in
                try db.execute(sql: "INSERT INTO publication_surfaces (server, account_id, org_id, agent_id, surface_id, session_id, generation) VALUES ('s', 'a', 'o', 'agent', ?, 'session', 'generation')",
                    arguments: [surface])
            }
            gate.open()
            let response = try await pending.value
            XCTAssertEqual(response.error, "dm_not_allowed", "\(args)")
            XCTAssertEqual(response.chatResult, "{\"error\":\"dm_not_allowed\"}")
            let posts = try ChatStubProtocol.seen.filter { $0.request.httpMethod == "POST" }
                .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type }
            XCTAssertEqual(posts, args["peer_account_id"] == nil ? [] : ["dm.open"], "No message may send after publication")
            try await f.journal.queue.write { try $0.execute(sql: "DELETE FROM publication_surfaces") }
        }
    }

    func testEveryDMOperationDeniesExecutorPublicationAndAllRunHistories() async throws {
        let processes = AnswerProcessFixture(), launch = UUID().uuidString.lowercased()
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode, launchedConversationId: launch)
        try processes.bind(tab, conversation: conversation)
        tab.conversationId = conversation
        tab.answerBinding = nil // the personal binding must not weaken role checks
        func denyAll(_ origin: AgentPadCallerOrigin? = nil) async throws {
            for args in personalDMOperations {
                let result = try await authenticatedCall(args, tab: tab, processes: processes, origin: origin)
                XCTAssertEqual(result.error, "dm_not_allowed", "\(args)")
                XCTAssertEqual(result.chatResult, "{\"error\":\"dm_not_allowed\"}")
            }
        }
        for origin in [AgentPadCallerOrigin.outside, .teamRun(callId: nil)] { try await denyAll(origin) }
        for id in [launch, conversation] {
            f.agent.sessionId = id
            f.agent.enabled = false
            try await denyAll()
        }
        f.agent.sessionId = nil
        let surface = tab.id.uuidString.lowercased()
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO publication_surfaces (server, account_id, org_id, agent_id, surface_id, session_id, generation) VALUES ('s', 'a', 'o', 'agent', ?, 'old-session', 'old-generation')",
                arguments: [surface])
        }
        try await denyAll()
        try await f.journal.queue.write { db in
            try db.execute(sql: "DELETE FROM publication_surfaces")
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 'other-server', 'other-account', 'other-org', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
        }
        for id in [launch, conversation] {
            for kind in ["personal", "channel", "future-kind"] {
                try await f.journal.queue.write { db in
                    try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, ended_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, ?, ?)",
                        arguments: [id.uppercased(), Date(), Date(), kind])
                }
                try await denyAll()
                try await f.journal.queue.write { try $0.execute(sql: "DELETE FROM runs") }
            }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(conversation))
    }

    func testEveryDMOperationUsesSameSettingCapabilityAndHistoryChecks() async throws {
        let processes = AnswerProcessFixture()
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        try processes.bind(tab, conversation: conversation)
        tab.conversationId = conversation
        for code in ["dm_access_disabled", "unsupported"] {
            f.service.dmToolsEnabled = { code != "dm_access_disabled" }
            f.service.serverCapabilities[f.key.server] = code == "unsupported" ? ["chat.dm"] : ["chat.dm", "chat.dm.session_signature"]
            for args in personalDMOperations {
                let result = try await authenticatedCall(args, tab: tab, processes: processes)
                XCTAssertEqual(result.error, code, "\(args)")
            }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        f.service.dmToolsEnabled = { true }
        f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.dm.session_signature"]
        // A broken taint ledger never releases private data or sends a command.
        let history = ChatDMHistory(files: f.service.files)
        try Data("broken".utf8).write(to: history.url)
        serveDM()
        for args in personalDMOperations {
            let result = try await authenticatedCall(args, tab: tab, processes: processes)
            XCTAssertEqual(result.error, "dm_not_allowed", "\(args)")
            XCTAssertEqual(result.chatResult, "{\"error\":\"dm_not_allowed\"}")
        }
        XCTAssertTrue(ChatStubProtocol.seen.allSatisfy { $0.request.httpMethod == "GET" })
        XCTAssertTrue(history.needsFreshSession(conversation))
    }
    func testDefaultSettingAndDisabledUnsupportedDisconnectedMakeNoNetworkCalls() async throws {
        XCTAssertTrue(ChatDMSettings.enabled(in: [:]))
        XCTAssertFalse(ChatDMSettings.enabled(in: ["agents": ["directMessages": false]]))
        f.service.dmToolsEnabled = { false }
        await refused("dm_access_disabled") { try await self.call("chat_channels", ["scope": .string("dms")]) }
        f.service.dmToolsEnabled = { true }
        f.service.serverCapabilities[f.key.server] = ["chat.dm"]
        await refused("unsupported") { try await self.call("chat_read", ["kind": .string("dm"), "dm_id": .string(self.dm)]) }
        await f.service.disconnect()
        await refused("not_connected") { try await self.call("chat_channels", ["scope": .string("dms")]) }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }
    func testCatalogStripsWindowsMembersExcludeSelfAndReadReturnsCanonicalWithoutMarks() async throws {
        let card = try JSONDecoder().decode(ChatJSON.self, from: card())
        guard case .object(var fields) = card else { return XCTFail() }
        fields["messages"] = .array([.object(["text": .string("window must not escape")])])
        // Real decoder requires complete messages; use a valid signed fixture.
        let message = """
        {"message_id":"\(UUID())","dm_id":"\(dm)","author_account_id":"\(CallJSON.boris)","text":"compatibility prefix","canonical_text":"private canonical body","author_session_name":"Peer's agent","mentions":[],"revision":1,"seq":1,"created_at":"2026-10-09T00:00:00Z"}
        """
        fields["messages"] = .array([try JSONDecoder().decode(ChatJSON.self, from: Data(message.utf8))])
        let catalog = try JSONEncoder().encode(ChatJSON.object(["dms": .array([.object(fields)]), "next": .null]))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: catalog)) }
        let listed = try await call("chat_channels", ["scope": .string("dms")])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(listed), as: UTF8.self).contains("private canonical"))
        let members = try await call("chat_channels", ["scope": .string("members")])
        guard case .array(let people) = members["members"] else { return XCTFail() }
        XCTAssertEqual(people.compactMap { $0["account_id"]?.string }, [CallJSON.boris])
        let body = Data("{\"messages\":[\(message)],\"next\":null,\"head\":1}".utf8)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: body)) }
        let read = try await call("chat_read", ["kind": .string("dm"), "dm_id": .string(dm)])
        guard case .array(let messages) = read["messages"] else { return XCTFail() }
        XCTAssertEqual(messages.first?["text"]?.string, "private canonical body")
        XCTAssertEqual(messages.first?["author_session_name"]?.string, "Peer's agent")
        XCTAssertEqual(messages.first?["attachments"], .array([]))
        XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(conversation))
        for table in ["dm_marks", "dm_messages", "dm_cards", "dm_notified", "dm_preferences"] {
            XCTAssertEqual(try f.store.dmRead { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0, table)
        }
    }
    func testPostOpenRepeatFrozenSignatureAndArchiveNeverAutoSends() async throws {
        let card = card(), dm = dm
        ChatStubProtocol.reset { request, bytes in
            if request.httpMethod == "GET" { return .success(.init(status: 200, body: card)) }
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes)
            XCTAssertNil(command.args["_mcp"])
            let result: ChatJSON = command.type == "dm.open" ? .object(["dm_id": .string(dm)]) :
                .object(["dm_id": .string(dm), "message_id": command.args["message_id"]!, "author_session_name": command.args["author_session_name"]!])
            return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatJSON.object(["events": .array([]), "result": result]))))
        }
        let id = UUID().uuidString.lowercased()
        let args: [String: ChatJSON] = ["kind": .string("dm"), "peer_account_id": .string(CallJSON.boris), "message_id": .string(id), "text": .string("hello")]
        let sent = try await call("chat_post", args)
        XCTAssertEqual(sent["status"]?.string, "sent"); XCTAssertEqual(sent["dm_id"]?.string, dm)
        caller.signature = "Renamed"
        let repeated = try await call("chat_post", args)
        XCTAssertEqual(repeated["author_session_name"]?.string, "My tab")
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.httpMethod == "POST" }.count, 2)
        var changed = args; changed["text"] = .string("different")
        await refused("message_conflict") { try await self.call("chat_post", changed) }
        caller.surface = UUID().uuidString.lowercased()
        await refused("message_conflict") { try await self.call("chat_post", args) }
        try f.service.files.saveDMOutbox(f.key, store: f.store)
        let archived = try XCTUnwrap(f.service.files.savedDMOutbox(f.key)?.commands.first)
        XCTAssertTrue(archived.isSessionDM)
        XCTAssertEqual(ChatService.args(archived)["author_session_name"]?.string, "My tab")
        var queued = archived; queued.state = .pending
        try f.store.dmWrite { try queued.update($0) }
        let sender = ChatOutbox(queues: [f.store.outbox], api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna")
        let before = ChatStubProtocol.seen.count
        sender.pump(); try await Task.sleep(for: .milliseconds(50)); sender.hold()
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
    }
    func testIdentitySettingCapabilityAndEpochChangesDiscardAwaitedResponse() async throws {
        for mutation in 0..<4 {
            valid = true; f.service.dmToolsEnabled = { true }
            f.service.serverCapabilities[f.key.server] = ["chat.dm", "chat.dm.session_signature"]
            let entered = expectation(description: "read pending"), gate = Gate(); gate.close()
            ChatStubProtocol.reset { _, _ in
                entered.fulfill(); gate.pass()
                return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null}"#.utf8)))
            }
            let task = Task { try await self.call("chat_read", ["kind": .string("dm"), "dm_id": .string(self.dm)]) }
            await fulfillment(of: [entered], timeout: 3)
            switch mutation {
            case 0: valid = false
            case 1: f.service.dmToolsEnabled = { false }
            case 2: f.service.serverCapabilities[f.key.server] = ["chat.dm"]
            default: sync.invalidate()
            }
            gate.open()
            do { _ = try await task.value; XCTFail("Late response escaped") } catch {}
            XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(conversation))
        }
    }
    func testStrictArgumentsAndSpoofedAuthorRefusedBeforeNetwork() async throws {
        await refused("unsupported") {
            try await self.call("chat_read", ["kind": .string("dm"), "dm_id": .string(self.dm), "attachment_id": .string(UUID().uuidString)])
        }
        for extra: [String: ChatJSON] in [
            ["channel_id": .string(UUID().uuidString)], ["peer_account_id": .string(CallJSON.boris)],
            ["author_session_name": .string("fake")], ["surface_id": .string(caller.surface)],
            ["session_id": .string(conversation)], ["pid": .number(321)], ["before": .bool(true)]] {
            var args: [String: ChatJSON] = ["kind": .string("dm"), "dm_id": .string(dm)]; args.merge(extra) { _, b in b }
            await refused("invalid_args") { try await self.call("chat_read", args) }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testUnverifiedSocketAndPublishedTabRefusalsAreAnonymousAndOffline() async throws {
        var request = AgentPadCLIRequest(verb: .team)
        request.chatArguments = "{\"tool\":\"chat_read\",\"kind\":\"dm\",\"org_id\":\"\(f.key.orgId)\",\"dm_id\":\"\(dm)\"}"
        for origin in [AgentPadCallerOrigin.outside, .teamRun(callId: nil), .localProcess(pid: -1, startedAtUs: 1)] {
            let result = await ChatSessionTools.handle(request, origin: origin, sessions: { [] }, service: f.service)
            XCTAssertEqual(result.error, "dm_not_allowed")
            XCTAssertEqual(result.chatResult, "{\"error\":\"dm_not_allowed\"}")
        }
        f.agent.sessionId = conversation
        f.agent.enabled = false
        await refused("dm_not_allowed") { try await self.call("chat_channels", ["scope": .string("dms")]) }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testPersonalDMReadAfterClearOrResumeDoesNotInheritPreviousRunDenial() async throws {
        let process = AnswerProcessFixture()
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        let executor = UUID().uuidString.lowercased(), personal = UUID().uuidString.lowercased()
        let caller = ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
                                     claudeStart: 100, signature: "Personal")
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, ended_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, ?, 'personal')", arguments: [executor, Date(), Date()])
        }
        func bind(_ id: String) throws {
            try process.bind(tab, conversation: id)
            tab.conversationId = id
        }
        func read() async throws -> ChatJSON {
            try await ChatSessionTools.call(.object(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
                "kind": .string("dm"), "dm_id": .string(dm)]), caller: caller, service: f.service,
                personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: process.inspector.kernel) }, revalidate: { true })
        }
        try bind(personal)
        // A manually resumed executor history must stop blocking access once
        // /clear creates a new history or /resume returns to a personal one.
        for next in [UUID().uuidString.lowercased(), personal] {
            try bind(executor)
            ChatStubProtocol.reset()
            await refused("dm_not_allowed") { try await read() }
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            try bind(next)
            ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"messages":[],"next":null}"#.utf8))) }
            let result = try await read()
            XCTAssertEqual(result["messages"], .array([]))
            XCTAssertTrue(try ChatDMHistory(files: f.service.files).contains(next))
            XCTAssertFalse(try ChatDMHistory(files: f.service.files).contains(executor))
        }
    }

    func testLaunchOrCurrentRunDeniesPersonalAccessAfterRebinding() async throws {
        f.service.isServerKnown = { _, _ in true }
        f.service.serverCapabilities[f.key.server]?.insert("chat.session_tools")
        let process = AnswerProcessFixture()
        let resumed = UUID().uuidString.lowercased(), bound = UUID().uuidString.lowercased()
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode, launchedConversationId: resumed)
        tab.resumedConversationId = resumed
        try process.bind(tab, conversation: bound)
        // A restart or forged hook cannot erase AgentPad's launch ID.
        tab.answerBinding = nil; tab.resumedConversationId = nil
        let forged = UUID().uuidString.lowercased()
        try process.bind(tab, conversation: forged)
        tab.conversationId = forged
        let caller = ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
                                     claudeStart: 100, signature: "Personal")
        try await f.journal.queue.write { db in
            try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
        }
        for history in [resumed, forged] {
            try await f.journal.queue.write { db in
                try db.execute(sql: "DELETE FROM runs")
                try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, 'personal')", arguments: [history, Date()])
            }
            for payload: [String: ChatJSON] in [
                ["tool": .string("chat_read"), "kind": .string("dm"), "dm_id": .string(dm)],
                ["tool": .string("chat_read"), "channel_id": .string(UUID().uuidString), "attachment_id": .string(UUID().uuidString)]
            ] {
                var args = payload; args["org_id"] = .string(f.key.orgId)
                await refused("dm_not_allowed") {
                    try await ChatSessionTools.call(.object(args), caller: caller, service: self.f.service,
                        personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: process.inspector.kernel) }, revalidate: { true })
                }
            }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
    }

    func testReceivedConversationHookDeniesPersonalToolsUntilEveryHookSettles() async throws {
        let processes = AnswerProcessFixture(), store = makeTestStore()
        defer { store.terminate() }
        processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
        let tab = try XCTUnwrap(store.active?.activeSession)
        tab.agent = .claudeCode
        let old = UUID().uuidString.lowercased(), pending = UUID().uuidString.lowercased(), latest = UUID().uuidString.lowercased()
        try processes.bind(tab, conversation: old)
        tab.conversationId = old
        let caller = ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
                                     claudeStart: 100, signature: "Private tab title")
        let reading = expectation(description: "personal read awaiting its response"), responseGate = Gate()
        reading.assertForOverFulfill = false
        responseGate.close()
        defer { responseGate.open() }
        serveDM { reading.fulfill(); responseGate.pass() }
        let read = Task {
            try await self.authenticatedCall(["tool": .string("chat_read"), "org_id": .string(self.f.key.orgId),
                "kind": .string("dm"), "dm_id": .string(self.dm)], tab: tab, processes: processes)
        }
        await fulfillment(of: [reading], timeout: 3)
        let waiting = expectation(description: "new hook received but verification blocked")
        let applied = expectation(description: "a later hook applied while the first is still pending")
        let delayed = DelayedConversationScan(started: waiting, inspector: processes.inspector)
        defer { delayed.resume.signal() }
        var inspector = processes.inspector
        inspector.scan = { delayed.scan($0) }
        let path = NSTemporaryDirectory() + "pending-hook-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(socketPath: path, answerInspector: inspector) { message in
            guard case .conversationId(let id, let surface, let proof, let failure, let hook) = message else { return }
            store.applyHookConversationId(conversationId: id, sessionId: surface, provenance: proof,
                failure: failure, hook: hook, inspector: processes.inspector)
            if id == latest { applied.fulfill() }
        }
        server.originOf = { _ in .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100) }
        server.start()
        defer { server.stop() }
        let payload = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
            conversationId: pending, claudeParentPID: AnswerProcessFixture.claude)
        let sending = Task.detached { AgentPadHookKit.sendPayload(payload, to: path) }
        await fulfillment(of: [waiting], timeout: 3)
        _ = await sending.value // the hook client gives up after 200 ms
        XCTAssertEqual(tab.personalBinding?.conversation, old)
        responseGate.open()
        let discarded = try await read.value
        XCTAssertEqual(discarded.error, "dm_not_allowed", "Receipt must also revoke an in-flight personal read")
        serveDM()
        f.service.isServerKnown = { _, _ in true }
        f.service.serverCapabilities[f.key.server]?.insert("chat.session_tools")
        let attachment: [String: ChatJSON] = ["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
            "channel_id": .string(UUID().uuidString), "attachment_id": .string(UUID().uuidString)]
        for args in personalDMOperations + [attachment] {
            await refused("dm_not_allowed") {
                try await ChatSessionTools.call(.object(args), caller: caller, service: self.f.service,
                    personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: processes.inspector.kernel) },
                    revalidate: { true })
            }
        }
        let members: [String: ChatJSON] = ["tool": .string("chat_channels"), "scope": .string("members")]
        let denied = try await authenticatedCall(members, tab: tab, processes: processes)
        XCTAssertEqual(denied.error, "dm_not_allowed")
        XCTAssertEqual(try JSONDecoder().decode(ChatJSON.self, from: Data((denied.chatResult ?? "{}").utf8)),
                       .object(["error": .string("dm_not_allowed")]))
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        let history = ChatDMHistory(files: f.service.files)
        XCTAssertFalse(try history.contains(old))
        XCTAssertFalse(try history.contains(pending))

        let unrelated = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode)
        try processes.bind(unrelated, conversation: old)
        unrelated.conversationId = old
        var otherCaller = caller
        otherCaller.surface = unrelated.id.uuidString.lowercased()
        XCTAssertNoThrow(try ChatPersonalAccess.conversation(caller: otherCaller, sessions: [unrelated], kernel: processes.inspector.kernel))

        let next = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
            conversationId: latest, claudeParentPID: AnswerProcessFixture.claude)
        _ = await Task.detached { AgentPadHookKit.sendPayload(next, to: path) }.value
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertThrowsError(try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: processes.inspector.kernel),
                             "Applying one hook must not clear another pending hook")
        delayed.resume.signal()
        XCTAssertEqual(tab.personalBinding?.conversation, latest)
        let allowed = try await authenticatedCall(members, tab: tab, processes: processes)
        XCTAssertTrue(allowed.ok, allowed.chatResult ?? "")
        XCTAssertTrue(try history.contains(latest))
    }

    func testLateConversationHookCannotRollbackBindingTaintOrRunCheck() async throws {
        for executor in [false, true] {
            let processes = AnswerProcessFixture(), store = makeTestStore()
            defer { store.terminate() }
            processes.add(mcp, parent: AnswerProcessFixture.claude, name: "agentpad-cli")
            let tab = try XCTUnwrap(store.active?.activeSession)
            tab.agent = .claudeCode
            (tab.engine as? TestEngine)?.foregroundPid = AnswerProcessFixture.claude
            let old = UUID().uuidString.lowercased(), current = UUID().uuidString.lowercased()
            if executor {
                try await f.journal.queue.write { db in
                    try db.execute(sql: "INSERT INTO approvals (id, server, account_id, org_id, request_id, agent_id, kind, params, params_hash, run_id, start_command_id, generation, created_at) VALUES ('a', 's', 'a', 'o', 'r', 'agent', 'personal', '{}', 'hash', 'run', 'cmd', 'g', ?)", arguments: [Date()])
                    try db.execute(sql: "INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, ended_at, kind) VALUES ('run', 'r', 'a', 'agent', ?, ?, ?, 'personal')", arguments: [current.uppercased(), Date(), Date()])
                }
            }

            let waiting = expectation(description: "A authenticated and waiting in export verification")
            let applied = expectation(description: "B applied before A finishes")
            let drained = expectation(description: "late A delivery drained")
            let delayed = DelayedConversationScan(started: waiting, inspector: processes.inspector)
            defer { delayed.resume.signal() }
            var inspector = processes.inspector
            inspector.scan = { delayed.scan($0) }
            let path = NSTemporaryDirectory() + "late-hook-\(UUID().uuidString.prefix(8)).sock"
            var delivered: [String] = []
            let server = HookServer(socketPath: path, answerInspector: inspector) { message in
                if case .toolBatchResolved = message { drained.fulfill(); return }
                guard case .conversationId(let id, let surface, let proof, let failure, let hook) = message else { return }
                delivered.append(id)
                store.applyHookConversationId(conversationId: id, sessionId: surface, provenance: proof,
                    failure: failure, hook: hook, inspector: processes.inspector)
                if id == current { applied.fulfill() }
            }
            server.originOf = { _ in .localProcess(pid: AnswerProcessFixture.hook, startedAtUs: 100) }
            server.start()
            defer { server.stop() }
            let payloadA = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
                conversationId: old, claudeParentPID: AnswerProcessFixture.claude)
            let a = Task.detached { AgentPadHookKit.sendPayload(payloadA, to: path) }
            await fulfillment(of: [waiting], timeout: 3)
            let payloadB = AgentPadHookKit.buildConversationIdPayload(surface: tab.id.uuidString,
                conversationId: current, claudeParentPID: AnswerProcessFixture.claude)
            let sentB = await Task.detached { AgentPadHookKit.sendPayload(payloadB, to: path) }.value
            XCTAssertTrue(sentB)
            await fulfillment(of: [applied], timeout: 3)
            delayed.resume.signal()
            let sentA = await a.value
            XCTAssertTrue(sentA)
            let marker = AgentPadHookKit.buildToolBatchPayload(agent: "claude", surface: tab.id.uuidString)
            let sentMarker = await Task.detached { AgentPadHookKit.sendPayload(marker, to: path) }.value
            XCTAssertTrue(sentMarker)
            await fulfillment(of: [drained], timeout: 3)

            XCTAssertEqual(delivered, [current])
            XCTAssertEqual(tab.conversationId, current)
            XCTAssertEqual(tab.personalBinding?.conversation, current)
            XCTAssertEqual(tab.answerBinding?.conversation, current)
            XCTAssertNil(tab.launchedConversationId)
            serveDM()
            let response = try await authenticatedCall(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
                "kind": .string("dm"), "dm_id": .string(dm)], tab: tab, processes: processes)
            let history = ChatDMHistory(files: f.service.files)
            if executor {
                XCTAssertEqual(response.error, "dm_not_allowed")
                XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
                XCTAssertFalse(try history.contains(current))
            } else {
                XCTAssertTrue(response.ok, response.chatResult ?? "")
                XCTAssertTrue(try history.contains(current))
            }
            XCTAssertFalse(try history.contains(old))
        }
    }

    func testDMReadTaintsOnlyLaunchAndCurrentConversation() async throws {
        let process = AnswerProcessFixture()
        let resumed = UUID().uuidString.lowercased(), bound = UUID().uuidString.lowercased()
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode, launchedConversationId: resumed)
        tab.resumedConversationId = resumed
        try process.bind(tab, conversation: bound)
        tab.answerBinding = nil; tab.resumedConversationId = nil
        let current = UUID().uuidString.lowercased()
        try process.bind(tab, conversation: current)
        tab.conversationId = current
        let caller = ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: AnswerProcessFixture.claude,
                                     claudeStart: 100, signature: "Personal")
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"messages":[],"next":null}"#.utf8))) }
        _ = try await ChatSessionTools.call(.object(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "dm_id": .string(dm)]), caller: caller, service: f.service,
            personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: process.inspector.kernel) }, revalidate: { true })
        let history = ChatDMHistory(files: f.service.files)
        XCTAssertTrue(try history.contains(resumed))
        XCTAssertTrue(try history.contains(current))
        XCTAssertFalse(try history.contains(bound), "An earlier binding with no DM use must remain untainted")
    }

    func testDiscardedSignedRetryStopsAtEveryNetworkBoundaryAndPreservesDiscard() async throws {
        let card = card(), dm = dm
        for phase in ["before", "open", "card", "message"] {
            let message = UUID().uuidString.lowercased()
            var args: [String: ChatJSON] = ["kind": .string("dm"), "message_id": .string(message), "text": .string("discard \(phase)")]
            args[phase == "open" ? "peer_account_id" : "dm_id"] = .string(phase == "open" ? CallJSON.boris : dm)
            ChatStubProtocol.reset { request, _ in
                request.httpMethod == "GET" ? .success(.init(status: 200, body: card)) : .failure(URLError(.timedOut))
            }
            let unknown = try await call("chat_post", args)
            XCTAssertEqual(unknown["status"]?.string, "unknown")
            let original = try XCTUnwrap(f.store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == message })
            // Reconnecting restores the uncertain outgoing row into the DM UI.
            try f.service.files.saveDMOutbox(f.key, store: f.store)
            try f.store.dmWrite { try $0.execute(sql: "DELETE FROM outbox") }
            try f.service.files.restoreDMOutbox(f.key, store: f.store)
            try f.store.dmWrite { db in
                try ChatDMStore.writeCard(db, JSONDecoder().decode(ChatDMCard.self, from: card))
                try ChatDMStore.restoreOutgoing(db, dm: dm, me: f.key.accountId)
            }
            XCTAssertTrue(try f.store.dmRead { try ChatDMStore.messages($0, dm).contains { $0.id == message } })
            let entered = phase == "before" ? nil : expectation(description: "retry awaiting \(phase)")
            let gate = Gate()
            gate.close(); defer { gate.open() }
            ChatStubProtocol.reset { request, bytes in
                if request.httpMethod == "GET" {
                    if phase == "card" { entered?.fulfill(); gate.pass() }
                    return .success(.init(status: 200, body: card))
                }
                let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes)
                if (phase == "open" && command.type == "dm.open") || (phase == "message" && command.type == "dm.message.post") {
                    entered?.fulfill(); gate.pass()
                }
                let result: ChatJSON = command.type == "dm.open" ? .object(["dm_id": .string(dm)]) :
                    .object(["dm_id": .string(dm), "message_id": .string(message), "author_session_name": command.args["author_session_name"]!])
                return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatJSON.object(["events": .array([]), "result": result]))))
            }
            if phase == "before" {
                try f.service.discardDM(f.key, dm: dm, message: message)
                await refused("dismissed") { try await self.call("chat_post", args) }
                XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            } else {
                let task = Task { try await self.call("chat_post", args) }
                await fulfillment(of: [try XCTUnwrap(entered)], timeout: 3)
                try f.service.discardDM(f.key, dm: dm, message: message)
                gate.open()
                await refused("dismissed") { try await task.value }
            }
            let latest = try XCTUnwrap(f.store.outbox.commands().first { $0.commandId == original.commandId })
            XCTAssertEqual(latest.state, .dropped, phase)
            XCTAssertEqual(latest.error, "dismissed", phase)
            XCTAssertEqual(latest.attempts, original.attempts + (phase == "message" ? 1 : 0), phase)
            XCTAssertEqual(try f.store.dmRead { try Int.fetchOne($0, sql: "SELECT dismissed FROM outbox WHERE command_id = ?", arguments: [original.commandId]) }, 1)
            XCTAssertFalse(try f.store.dmRead { try ChatDMStore.messages($0, dm).contains { $0.id == message } })
            let posts = try ChatStubProtocol.seen.filter { $0.request.httpMethod == "POST" }
                .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type }
            XCTAssertEqual(posts, phase == "open" ? ["dm.open"] : phase == "message" ? ["dm.message.post"] : [], phase)
        }
    }

    func testUnknownPostReusesExactCommandAfterRenameAndDoesNotReviveOnPump() async throws {
        let card = card(), dm = dm
        ChatStubProtocol.reset { request, _ in
            if request.httpMethod == "GET" { return .success(.init(status: 200, body: card)) }
            return .failure(URLError(.timedOut))
        }
        let args: [String: ChatJSON] = ["kind": .string("dm"), "dm_id": .string(dm), "message_id": .string(UUID().uuidString.lowercased()), "text": .string("uncertain")]
        let unknown = try await call("chat_post", args)
        XCTAssertEqual(unknown["status"]?.string, "unknown")
        let first = try XCTUnwrap(f.store.outbox.commands().first)
        caller.signature = "New title"
        ChatStubProtocol.reset { request, bytes in
            if request.httpMethod == "GET" { return .success(.init(status: 200, body: card)) }
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes)
            XCTAssertEqual(command.commandId, first.commandId)
            XCTAssertEqual(command.args["author_session_name"]?.string, "My tab")
            return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatJSON.object([
                "events": .array([]), "result": .object(["dm_id": .string(dm), "message_id": command.args["message_id"]!, "author_session_name": .string("My tab")])]))))
        }
        let sent = try await call("chat_post", args)
        XCTAssertEqual(sent["status"]?.string, "sent")
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }

    func testSignedRetrySurvivesResumeAndClaudeRestartButCannotBorrowAnotherConversation() async throws {
        let tab = Session(engine: TestEngine(), currentDirectory: root, agent: .claudeCode, launchedConversationId: conversation)
        tab.resumedConversationId = conversation
        let process = AnswerProcessFixture()
        func bind(_ id: String, pid: Int32, start: UInt64, name: String) -> ChatLocalCaller {
            process.add(pid, parent: 21, name: "claude", trusted: true, start: start)
            tab.personalBinding = .init(conversation: id, owner: .init(process: process.inspector.kernel.process(pid)!,
                image: process.inspector.kernel.image(pid)!, isForeground: true))
            tab.conversationId = id
            return ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: pid, claudeStart: start, signature: name)
        }
        let originalCaller = bind(conversation, pid: 22, start: 100, name: "Original title")
        let args: ChatJSON = .object(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "dm_id": .string(dm), "message_id": .string(UUID().uuidString.lowercased()), "text": .string("retry this exact message")])
        func post(_ caller: ChatLocalCaller) async throws -> ChatJSON {
            try await ChatSessionTools.call(args, caller: caller, service: f.service,
                personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab], kernel: process.inspector.kernel) }, revalidate: { true })
        }
        let card = card(), dm = dm
        ChatStubProtocol.reset { request, _ in
            request.httpMethod == "GET" ? .success(.init(status: 200, body: card)) : .failure(URLError(.timedOut))
        }
        let unknown = try await post(originalCaller)
        XCTAssertEqual(unknown["status"]?.string, "unknown")
        let originalBytes = try XCTUnwrap(ChatStubProtocol.seen.first { $0.request.httpMethod == "POST" }?.body)

        ChatStubProtocol.reset()
        let different = bind(UUID().uuidString.lowercased(), pid: 22, start: 100, name: "Different history")
        await refused("message_conflict") { try await post(different) }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)

        // /resume back to the original conversation must allow the same retry,
        // including when Claude has restarted and the tab has been renamed.
        tab.answerBinding = nil; tab.resumedConversationId = nil
        let restarted = bind(conversation, pid: 23, start: 200, name: "Renamed after restart")
        ChatStubProtocol.reset { request, bytes in
            if request.httpMethod == "GET" { return .success(.init(status: 200, body: card)) }
            XCTAssertEqual(bytes, originalBytes, "Retry must preserve the command, message, text and original signature")
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes)
            return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatJSON.object([
                "events": .array([]), "result": .object(["dm_id": .string(dm), "message_id": command.args["message_id"]!,
                    "author_session_name": command.args["author_session_name"]!])]))))
        }
        let sent = try await post(restarted)
        XCTAssertEqual(sent["status"]?.string, "sent")
        XCTAssertEqual(sent["author_session_name"]?.string, "Original title")
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }
}

/// Pause only A, after verifyHook authenticated its owner. Its export check
/// fails after B is installed, exercising the personal-binding fallback too.
private final class DelayedConversationScan: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private let started: XCTestExpectation
    private let inspector: AgentAnswerProvenance.Inspector
    let resume = DispatchSemaphore(value: 0)

    init(started: XCTestExpectation, inspector: AgentAnswerProvenance.Inspector) {
        self.started = started
        self.inspector = inspector
    }

    func scan(_ pid: Int32) -> [SessionProcessScanner.Raw] {
        let pause = lock.withLock { let value = first; first = false; return value }
        if pause {
            started.fulfill()
            _ = resume.wait(timeout: .now() + 10)
            return []
        }
        return inspector.scan(pid)
    }
}
