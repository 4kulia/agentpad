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
                personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab]) }, revalidate: { true })
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
                        personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab]) }, revalidate: { true })
                }
            }
        }
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
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
            personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab]) }, revalidate: { true })
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
        func bind(_ id: String, pid: Int32, start: UInt64, name: String) -> ChatLocalCaller {
            let process = ChatSessionIdentity.Process(pid: pid, parent: 21, startedAtUs: start, terminal: 42)
            tab.answerBinding = .init(conversation: id, process: process, provenance: .init(process: process, snapshots: []))
            tab.conversationId = id
            return ChatLocalCaller(surface: tab.id.uuidString.lowercased(), claudePID: pid, claudeStart: start, signature: name)
        }
        let originalCaller = bind(conversation, pid: 22, start: 100, name: "Original title")
        let args: ChatJSON = .object(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "kind": .string("dm"), "dm_id": .string(dm), "message_id": .string(UUID().uuidString.lowercased()), "text": .string("retry this exact message")])
        func post(_ caller: ChatLocalCaller) async throws -> ChatJSON {
            try await ChatSessionTools.call(args, caller: caller, service: f.service,
                personalConversation: { try ChatPersonalAccess.conversation(caller: caller, sessions: [tab]) }, revalidate: { true })
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
