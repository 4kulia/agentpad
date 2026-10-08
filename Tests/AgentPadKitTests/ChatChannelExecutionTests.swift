import Foundation
import GRDB
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatChannelExecutionTests: XCTestCase {
    private var root: URL!
    private var fixtures: [Fixture] = []
    nonisolated private static let secretResult = "F5 local draft: never send before Publish 🦊"
    nonisolated private static let channel = "f5000000-0000-4000-8000-000000000001"
    nonisolated private static let message = "f5000000-0000-4000-8000-000000000002"
    nonisolated private static let request = "f5000000-0000-4000-8000-000000000003"
    nonisolated private static let team = "f5000000-0000-4000-8000-000000000004"
    nonisolated private static let org = "f5000000-0000-4000-8000-000000000005"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-f5-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        for f in fixtures { f.sender?.hold(); await f.service.disconnect() }
        fixtures = []
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor final class Fixture {
        let service: ChatService
        let store: ChatStore
        let journal: ChatJournal
        let key: ChatOrgKey
        let calls: TeamCalls
        let teamService: TeamService
        let runner: ChatTeamCallsTests.OwnerRunner
        let owner: ChatOwnerSide
        var agent: TeamPublishedAgent
        var sender: ChatOutbox?

        init(root: URL, executor: TeamAgentRunner? = nil, sessionId: String = "s-anna") async throws {
            let server = try ChatServerAddress(parsing: "https://chat.example.com")
            key = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: ChatChannelExecutionTests.org)
            service = ChatService(files: ChatFiles(directory: root.appendingPathComponent("chat")), tokens: FakeTokenStore())
            service.claudeProjectsRoot = root.appendingPathComponent("claude-projects")
            service.followsFeed = false
            service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
            service.closeRemoteSession = { _, _ in }
            runner = ChatTeamCallsTests.OwnerRunner()
            runner.holds = false
            runner.answer = TeamRunResult(text: ChatChannelExecutionTests.secretResult, isError: false)
            service.executorRunner = executor ?? runner
            try service.saveSignIn(ChatConnection(server: server, accountId: key.accountId, sessionId: sessionId, deviceName: "Mac", orgId: key.orgId), token: "test-only")
            try await service.start(mode: .server)
            journal = try XCTUnwrap(service.journal)
            store = try XCTUnwrap(service.orgSessions[key]?.store)
            try store.finishGeneration("g1")
            try journal.finish(key, "g1")
            let folder = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            agent = TeamPublishedAgent(name: "billing", description: "Billing", folder: folder.path)
            agent.id = UUID(uuidString: CallJSON.agent)!
            agent.access = .read
            let storage = TeamStorage(directory: root.appendingPathComponent("team"))
            try storage.save([agent], to: storage.agentsURL)
            let team = TeamService(storage: storage, offCalls: TeamOffCallStore())
            teamService = team
            calls = team.calls
            try calls.load()
            calls.serverMode = true
            calls.useServer(store.calls, key: key)
            service.onCallStore = { [weak calls] key, store in calls?.useServer(store, key: key) }
            owner = ChatOwnerSide.install(service: service, calls: calls)
            service.localAgent = { [weak self] id in self.flatMap { $0.agent.id.uuidString.lowercased() == id ? $0.agent : nil } }
            try assign()
            try store.apply(ChatSnapshot(cursors: [:], members: [
                .init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
                teams: [.init(teamId: ChatChannelExecutionTests.team, name: "Billing", mine: true)],
                teamMembers: [.init(teamId: ChatChannelExecutionTests.team, accountId: CallJSON.anna), .init(teamId: ChatChannelExecutionTests.team, accountId: CallJSON.boris)],
                channels: [.init(channelId: ChatChannelExecutionTests.channel, teamId: ChatChannelExecutionTests.team, name: "billing", archived: false, version: 1)],
                channelsComplete: true, agentChannels: []), confirmsRights: sessionId)
            try store.endChannelsRead(since: 0, seen: [ChatChannelExecutionTests.channel])
            service.orgSessions[key]?.snapshotOwed = false
            try write("INSERT INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available) VALUES (?, ?, 'billing', ?, 'read', 1, 1)",
                      [ChatChannelExecutionTests.channel, CallJSON.agent, key.accountId])
        }
        func assign() throws {
            try journal.save(ChatAssignment(server: key.server.description, accountId: key.accountId, orgId: key.orgId,
                                            agentId: agent.id.uuidString.lowercased(), state: .active, name: agent.name,
                                            description: agent.description, access: agent.access.rawValue, teamIds: "[]", createdAt: Date()))
        }
        func write(_ sql: String, _ args: StatementArguments = []) throws { try store.queue.write { try $0.execute(sql: sql, arguments: args) } }
        func request(_ id: String = ChatChannelExecutionTests.request) throws -> ChatRequest { try XCTUnwrap(store.calls.request(id)) }
        func move(_ state: String, _ version: Int, fixed: Bool = true, id: String = ChatChannelExecutionTests.request, run: String? = nil,
                  kind: String = "channel", here: Bool = true, publication: String? = nil, refs: Bool = false) throws {
            var body = CallJSON.request(id, state: state, version: version, fixed: fixed, runId: run, onThisDevice: here)
            body["kind"] = kind
            body["channel_id"] = ChatChannelExecutionTests.channel
            body["thread_root_id"] = ChatChannelExecutionTests.message
            body["deliver_by"] = ChatCallStore.timestamp(Date().addingTimeInterval(3600))
            if let publication { body["publication"] = publication }
            if refs { body["context"] = [["message_id": ChatChannelExecutionTests.message, "revision": 2]] }
            try store.queue.write { try ChatCallStore.apply($0, CallJSON.wire(body), onThisDevice: here) }
            calls.reload()
        }
        func content() -> ChatChannelContent {
            ChatChannelContent(requestId: ChatChannelExecutionTests.request, text: "Why twice?", context: [
                .init(messageId: ChatChannelExecutionTests.message, revision: 2, authorAccountId: CallJSON.boris, text: "A refund was retried.")])
        }
        func serve(_ content: ChatChannelContent? = nil, gate: Gate? = nil) throws {
            let bytes = try JSONEncoder().encode(content ?? self.content())
            ChatStubProtocol.reset { request, body in
                if request.url?.path.hasSuffix("/content") == true {
                    gate?.pass()
                    return .success(.init(status: 200, body: bytes))
                }
                if request.url?.path == "/v1/commands",
                   let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body), envelope.type == "result.publish" {
                    let result: ChatJSON = .object(["request_id": envelope.args["request_id"]!, "version": .number(8),
                                                    "publication": .string("published"), "publish_reason": .null, "message_id": .string("answer")])
                    return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatCommandAnswer(events: [], result: result))))
                }
                return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
            }
        }
        func commands() throws -> [ChatCommandRecord] { try store.outbox.commands() + journal.commands(for: key) }
        func send() {
            if sender == nil {
                let made = ChatOutbox(queues: [store.outbox, journal.runCommands(key)], api: service.makeAPI(key.server), token: "test-only", sessionId: "s-anna", held: true)
                made.retryDelay = { _ in 0.01 }
                made.onSent = { [weak self] record, answer in
                    guard let self else { return }
                    self.service.commandAnswered(self.key, record, .taken(answer))
                }
                sender = made
            }
            sender?.allow(connection: 1, generation: "g1")
        }
        func allow() async throws -> ChatApproval {
            try move("awaiting_decision", 2, refs: true)
            try serve()
            let loaded = try await service.loadChannelContent(key, request: request())
            XCTAssertTrue(loaded)
            let problem = await owner.decideChannel(key, requestId: ChatChannelExecutionTests.request, allow: true, reason: nil)
            XCTAssertNil(problem)
            return try XCTUnwrap(journal.approval(key, requestId: ChatChannelExecutionTests.request))
        }
        func finish() async throws -> ChatRunRecord {
            let approval = try await allow()
            try move("starting", 4, run: approval.runId)
            _ = try await XCTUnwrap(service.launcher).launch(approvalId: approval.id)
            try move("finished", 7, run: approval.runId, publication: "awaiting_publish")
            return try XCTUnwrap(journal.run(approval.runId))
        }
    }

    private func fixture() async throws -> Fixture {
        let f = try await Fixture(root: root.appendingPathComponent(UUID().uuidString))
        fixtures.append(f)
        return f
    }

    func testApprovalIdentityKeepsCallerAndChannelScopeTogether() async throws {
        for column in ["agent_id", "text", "initiator_account_id", "channel_id", "thread_root_id"] {
            let f = try await fixture()
            let approval = try await f.allow()
            XCTAssertFalse(try f.service.disownForeignApproval(f.key, f.request()), column)
            try f.write("UPDATE requests SET \(column) = ? WHERE request_id = ?", ["changed", Self.request])
            XCTAssertTrue(try f.service.disownForeignApproval(f.key, f.request()), column)
            XCTAssertNil(try f.journal.approval(f.key, requestId: Self.request), column)
            XCTAssertEqual(try f.journal.approval(approval.id)?.kind, "superseded:\(approval.id)", column)
        }
    }

    func testPublicationOf131072CharactersMatchesThePreviewAndFitsTheWholeEnvelope() async throws {
        for unit in ["x", "\"", "\\", "\n", "🦊", "e\u{301}", "👩🏽‍💻"] {
            let f = try await fixture()
            let run = try await f.finish()
            let full = String(repeating: unit, count: 131_072)
            try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = ? WHERE run_id = ?", arguments: [full, run.runId]) }
            let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
            let preview = try XCTUnwrap(model.publicationText(Self.request))
            XCTAssertNotEqual(preview, full)
            let marker = try XCTUnwrap(preview.range(of: "\n\n…(truncated, "))
            let prefix = String(preview[..<marker.lowerBound])
            XCTAssertEqual(prefix, String(full.prefix(prefix.count)), "no broken character")
            let omitted = (full.utf8.count - prefix.utf8.count + 1023) / 1024
            XCTAssertTrue(preview.hasSuffix("…(truncated, \(omitted) KiB omitted)"))
            let made = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            XCTAssertLessThanOrEqual(made.bodyBytes.count, 131_072)
            let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: made.bodyBytes)
            XCTAssertEqual(envelope.args["text"]?.string, preview)
            XCTAssertEqual(try f.journal.run(run.runId)?.resultText, full, "only the publication is shortened")
            f.send()
            try await wait { try f.store.outbox.commands().first { $0.commandId == made.commandId }?.state == .sent }
            let sent = try XCTUnwrap(ChatStubProtocol.seen.first { $0.body == made.bodyBytes })
            XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: sent.body).args["text"]?.string, preview)
        }
    }

    func testSmallPublicationKeepsEveryCharacter() throws {
        let text = "\n # Answer \\ \" 🦊 e\u{301}\n"
        XCTAssertEqual(try ChatPublication.text(text, org: Self.org, request: Self.request, run: UUID().uuidString), text)
    }

    func testQueuedPublicationPreviewUsesTheBytesThatRetryWillSend() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = 'changed draft'") }
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        XCTAssertEqual(model.publicationText(Self.request), Self.secretResult)
        XCTAssertEqual(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true).bodyBytes, first.bodyBytes)

        // A legacy oversized command that has never begun sending is replaced
        // with a bounded one; a known failed command follows the same path.
        for state in ["pending", "failed"] {
            let large = String(repeating: "x", count: 131_072)
            let legacy = try ChatCommandEnvelope(commandId: first.commandId, org: Self.org, type: "result.publish",
                args: .object(["request_id": .string(Self.request), "run_id": .string(run.runId), "text": .string(large)])).encoded()
            try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = ?", arguments: [large]) }
            try f.write("UPDATE outbox SET body_bytes = ?, state = ? WHERE type = 'result.publish'", [legacy, state])
            let preview = try XCTUnwrap(model.publicationText(Self.request))
            let replacement = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            XCTAssertLessThanOrEqual(replacement.bodyBytes.count, 131_072)
            XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: replacement.bodyBytes).args["text"]?.string, preview)
            XCTAssertTrue(preview.contains("…(truncated, "))
        }
    }

    func testPersonalContinueCannotForkAChannelConversation() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        _ = try transcript(f, id: run.conversationId)
        f.calls.sessionFilesRoot = f.service.claudeProjectsRoot
        f.calls.conversationVisibility = { .current(journalURL: f.journal.url) }
        f.calls.useServer(nil, key: nil)
        f.calls.serverMode = false
        let stale = TeamCalls.Incoming(id: "stale", peer: "fixture", peerName: "Fixture", agentId: f.agent.id,
            agentName: f.agent.name, prompt: "fixture", threadId: run.conversationId, resume: true, origin: nil,
            receivedAt: Date(), decideBy: Date().addingTimeInterval(60), state: .done)
        let previous = TeamUI.openTab
        defer { TeamUI.openTab = previous }
        var opened = false
        TeamUI.openTab = { _, _, _ in opened = true }
        XCTAssertFalse(f.calls.refuses(stale), "reach the conversation gate, not an earlier server refusal")
        XCTAssertNotNil(TeamUI.continueYourself(stale, in: f.calls))
        XCTAssertFalse(opened)
        f.calls.conversationVisibility = { ChannelConversationFilter(channelIds: []) }
        XCTAssertNil(TeamUI.continueYourself(stale, in: f.calls))
        XCTAssertTrue(opened)
    }

    func testPersonalContinueRequiresAnExistingFullId() async throws {
        let f = try await fixture()
        f.calls.useServer(nil, key: nil)
        f.calls.serverMode = false
        f.calls.sessionFilesRoot = f.service.claudeProjectsRoot
        let personal = UUID().uuidString.lowercased()
        let file = try transcript(f, id: personal)
        func call(_ id: String) -> TeamCalls.Incoming {
            TeamCalls.Incoming(id: "fixture", peer: "fixture", peerName: "Fixture", agentId: f.agent.id,
                agentName: f.agent.name, prompt: "fixture", threadId: id, resume: true, origin: nil,
                receivedAt: Date(), decideBy: Date().addingTimeInterval(60), state: .done)
        }
        let previous = TeamUI.openTab
        defer { TeamUI.openTab = previous }
        var commands: [String] = []
        TeamUI.openTab = { _, command, _ in commands.append(command) }
        for id in ["billing", String(personal.prefix(8)), UUID().uuidString] {
            XCTAssertNotNil(TeamUI.continueYourself(call(id), in: f.calls))
        }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(TeamUI.continueYourself(call(personal.uppercased()), in: f.calls))
        XCTAssertEqual(commands, ["claude --resume \(personal) --fork-session"])
        try FileManager.default.removeItem(at: file)
        XCTAssertNotNil(TeamUI.continueYourself(call(personal), in: f.calls))
        XCTAssertEqual(commands.count, 1)
    }

    private func transcript(_ f: Fixture, id: String, project: String = "-project") throws -> URL {
        let folder = f.service.claudeProjectsRoot.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        try Data("fixture transcript".utf8).write(to: file)
        return file
    }

    func testRevocationErasesOnlyItsTranscriptAndRetriesAfterLateFinish() async throws {
        for revoke in ["channel", "membership"] {
            let f = try await fixture()
            let run = try await f.finish()
            let file = try transcript(f, id: run.conversationId)
            let neighbor = try transcript(f, id: UUID().uuidString)
            let checkpoint = file.deletingPathExtension()
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
            let checkpointFile = checkpoint.appendingPathComponent("checkpoint")
            try Data("checkpoint".utf8).write(to: checkpointFile)
            switch revoke {
            case "channel": try f.write("DELETE FROM channels")
            default: break
            }
            f.service.reconcileChannelResults(revoked: revoke == "membership" ? f.key : nil)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), revoke)
            XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointFile.path))
            XCTAssertTrue(try XCTUnwrap(f.journal.run(run.runId)).resultErased)
            XCTAssertNil(try f.journal.run(run.runId)?.resultText)
            await f.service.disconnect()
            // A late writer may recreate the transcript; repeat cleanup works
            // from the durable erasure even without current channel rights.
            try Data("late write".utf8).write(to: file)
            f.service.reconcileChannelResults()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testUnsafeOrUnremovableTranscriptDoesNotBlockResultErasure() async throws {
        for kind in ["outside-symlink", "directory", "missing", "unwritable"] {
            let f = try await fixture()
            let run = try await f.finish()
            let target = root.appendingPathComponent("outside-\(UUID().uuidString).jsonl")
            try Data("must survive".utf8).write(to: target)
            let folder = f.service.claudeProjectsRoot.appendingPathComponent("-project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(run.conversationId).jsonl")
            if kind == "outside-symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
            if kind == "directory" { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }
            if kind == "unwritable" {
                try Data("fixture".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            f.service.reconcileChannelResults(revoked: f.key)
            XCTAssertTrue(try XCTUnwrap(f.journal.run(run.runId)).resultErased)
            XCTAssertNil(try f.journal.run(run.runId)?.resultText)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must survive")
            if kind != "missing" { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        }
    }
    private func wait(_ predicate: () throws -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while try !predicate() {
            if ContinuousClock.now > limit { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func acceptNewGeneration(_ f: Fixture, run: String) throws {
        try f.store.beginGeneration("g2", keeping: [Self.request])
        try f.store.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
            .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            teams: [.init(teamId: Self.team, name: "Billing", mine: true)],
            teamMembers: [.init(teamId: Self.team, accountId: CallJSON.anna), .init(teamId: Self.team, accountId: CallJSON.boris)],
            channels: [.init(channelId: Self.channel, teamId: Self.team, name: "billing", archived: false, version: 1)],
            agentChannels: []), confirmsRights: "s-anna")
        try f.store.finishGeneration("g2")
        try f.journal.finish(f.key, "g2")
        try f.move("finished", 7, run: run, publication: "awaiting_publish")
        try f.write("INSERT OR REPLACE INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available) VALUES (?, ?, 'billing', ?, 'read', 1, 1)",
                    [Self.channel, CallJSON.agent, f.key.accountId])
        XCTAssertTrue(f.service.channelAgentAllowed(f.key, channel: Self.channel))
    }

    func testPublication429ThenWithholdReplacesTheIntent() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        ChatStubProtocol.reset { _, body in
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: body)
            return .success(.init(status: command.type == "result.publish" ? 429 : 200, headers: ["Retry-After": "3600"], body: Data("{}".utf8)))
        }
        let old = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send()
        try await wait { try f.store.outbox.commands().first { $0.commandId == old.commandId }?.attempts == 1 }
        let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
        XCTAssertEqual(next.type, "result.withhold")
        XCTAssertNotEqual(next.commandId, old.commandId)
        XCTAssertFalse(try f.store.outbox.commands().contains { $0.commandId == old.commandId })
        let intent = try await f.store.queue.read { try String.fetchOne($0, sql: "SELECT command_id FROM publication_intents WHERE run_id = ?", arguments: [run.runId]) }
        XCTAssertEqual(intent, next.commandId)
        f.sender?.pump()
        try await wait { try f.store.outbox.commands().first { $0.commandId == next.commandId }?.state == .sent }
        let decisions = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
            .filter { ChatPublication.isDecision($0.type) }
        XCTAssertEqual(decisions.map(\.type), ["result.publish", "result.withhold"])
    }

    func testInFlightPublicationLocksBothDecisionsAndKeepsItsAnswer() async throws {
        for publish in [true, false] {
            let f = try await fixture()
            let run = try await f.finish()
            let gate = Gate()
            gate.close()
            defer { gate.open() }
            let publication = publish ? "published" : "withheld"
            let body = try JSONEncoder().encode(ChatCommandAnswer(events: [], result: .object([
                "request_id": .string(Self.request), "version": .number(8), "publication": .string(publication)])))
            ChatStubProtocol.reset { _, data in
                let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: data)
                if ChatPublication.isDecision(command.type) { gate.pass(); return .success(.init(status: 200, body: body)) }
                return .success(.init(status: 200))
            }
            let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: publish)
            XCTAssertNil(f.service.channelPublicationInFlight(f.key, requestId: Self.request))
            f.send()
            try await wait { ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.commandId == first.commandId } }
            let expected = publish ? "Publishing…" : "Withholding…"
            XCTAssertEqual(f.service.channelPublicationInFlight(f.key, requestId: Self.request), expected, "both SwiftUI buttons share this disabled gate")
            XCTAssertEqual(f.service.channelPublicationIssue(f.key, requestId: Self.request), expected)
            // Reopening the database/preview cannot forget an HTTP send.
            let reopened = try DatabaseQueue(path: f.store.url.path)
            let durable = try await reopened.read { try ChatPublication.inFlight($0, run: run.runId) }
            XCTAssertEqual(durable?.commandId, first.commandId)
            XCTAssertThrowsError(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: !publish))
            XCTAssertEqual(try f.store.outbox.commands().map(\.commandId), [first.commandId])
            gate.open()
            try await wait { try f.request().publication == publication }
            XCTAssertEqual(try f.store.outbox.commands().first?.state, .sent)
            XCTAssertNil(f.service.channelPublicationInFlight(f.key, requestId: Self.request))
            let decisions = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
                .filter { ChatPublication.isDecision($0.type) }
            XCTAssertEqual(decisions.map(\.commandId), [first.commandId])
            f.sender?.hold()
        }
    }

    func testPublicationWithAnUnknownAnswerStaysLockedUntilRetry() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        ChatStubProtocol.reset { _, data in
            let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: data)
            return command.type == "result.publish" ? .failure(URLError(.networkConnectionLost)) : .success(.init(status: 200))
        }
        let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send()
        f.sender?.retryDelay = { _ in 3600 }
        try await wait { try f.store.outbox.commands().first?.attempts == 1 }
        XCTAssertEqual(f.service.channelPublicationInFlight(f.key, requestId: Self.request), "Publishing…")
        XCTAssertThrowsError(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false))
        // A later attempt can be rate-limited even if the earlier command
        // succeeded. That 429 must not pretend the original send was unsent.
        ChatStubProtocol.reset { _, _ in .success(.init(status: 429, headers: ["Retry-After": "3600"])) }
        try f.write("UPDATE outbox SET next_attempt_at = NULL")
        f.sender?.pump()
        try await wait { try f.store.outbox.commands().first?.attempts == 2 }
        XCTAssertEqual(f.service.channelPublicationInFlight(f.key, requestId: Self.request), "Publishing…")
        XCTAssertThrowsError(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false))
        f.sender?.hold()
        try f.serve()
        try f.write("UPDATE outbox SET next_attempt_at = NULL")
        f.send()
        try await wait { try f.request().publication == "published" }
        let retried = try XCTUnwrap(ChatStubProtocol.seen.first { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.type == "result.publish" })
        XCTAssertEqual(retried.body, first.bodyBytes)
    }

    func testPublicationSendStartUpdatesAnOpenPreview() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent'") }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        ChatStubProtocol.reset { _, _ in gate.pass(); return .success(.init(status: 200)) }
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        let before = model.revision
        f.send()
        try await wait { !ChatStubProtocol.seen.isEmpty }
        // While HTTP is held, only publication_intents changed: the open
        // sheet must redraw its disabled buttons before the answer arrives.
        try await wait { model.revision > before }
        XCTAssertEqual(model.service.channelPublicationInFlight(model.key, requestId: Self.request), "Publishing…")
        gate.open()
        try await wait { try f.store.outbox.commands().first?.state == .sent }
    }

    func testPublicationSendStartMustBeWrittenBeforeHTTP() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        try f.write("CREATE TRIGGER fail_send_start BEFORE UPDATE OF send_started_at ON publication_intents BEGIN SELECT RAISE(ABORT, 'test'); END")
        f.send()
        try await wait { f.sender?.paused != nil }
        XCTAssertFalse(ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.type == "result.publish" })
        XCTAssertNil(f.service.channelPublicationInFlight(f.key, requestId: Self.request))
        let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
        XCTAssertEqual(next.type, "result.withhold")
    }

    func testKnownUnsuccessfulDecisionCanBeReplacedAfterSendingBegan() async throws {
        for state in ["unconfirmed", "failed", "dropped"] {
            let f = try await fixture()
            _ = try await f.finish()
            let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            XCTAssertNotNil(try f.store.outbox.beginSending(first))
            try f.write("UPDATE outbox SET state = ?", [state])
            XCTAssertNil(f.service.channelPublicationInFlight(f.key, requestId: Self.request), state)
            let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
            XCTAssertEqual(try f.store.outbox.commands().map(\.commandId), [next.commandId], state)
            XCTAssertEqual(next.type, "result.withhold", state)
        }
    }

    func testUpgradeKeepsEveryPreviouslyPendingDecisionLocked() async throws {
        let cache = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(cache, upTo: "release-10")
        let table = ChatCommandTable(queue: cache, table: "outbox")
        for state in ["pending", "failed", "unconfirmed", "dropped", "sent"] {
            let record = ChatCommandRecord(commandId: state, sessionId: "s-anna", type: "result.publish", bodyBytes: Data(),
                                           orderKey: "publish:\(state)", createdAt: Date(), state: .init(rawValue: state)!)
            try table.enqueue(record)
            try await cache.write { try $0.execute(sql: "INSERT INTO publication_intents (run_id, command_id) VALUES (?, ?)", arguments: [state, state]) }
        }
        try ChatStoreMigrations.cache.migrate(cache)
        for state in ["pending", "failed", "unconfirmed", "dropped", "sent"] {
            let inFlight = try await cache.read { try ChatPublication.inFlight($0, run: state) }
            XCTAssertEqual(inFlight != nil, state == "pending", state)
        }
    }

    func testRevocationDuringPublicationErasesBodiesButStillReportsSuccess() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        ChatStubProtocol.reset { _, data in
            if (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: data))?.type == "result.publish" { gate.pass() }
            return .success(.init(status: 200))
        }
        let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send()
        var answered: [String] = []
        f.sender?.onSent = { record, _ in answered.append(record.commandId) }
        try await wait { ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.commandId == first.commandId } }
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertNil(try f.journal.run(run.runId)?.resultText)
        gate.open()
        try await wait { answered.contains(first.commandId) }
        XCTAssertEqual(answered.filter { $0 == first.commandId }.count, 1)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testNewGenerationWithholdCannotBeUndoneByTryAgain() async throws {
        for oldState in ["unconfirmed", "sent"] {
            let f = try await fixture()
            let run = try await f.finish()
            let old = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            try f.write("UPDATE outbox SET state = ?, sent_generation = 'g1' WHERE command_id = ?", [oldState, old.commandId])
            let session = try XCTUnwrap(f.service.orgSessions[f.key])
            session.startSending(api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna", journal: nil, onUnauthorized: {})
            let box = try XCTUnwrap(session.outbox)
            f.sender = box
            try box.generationChanged()
            try acceptNewGeneration(f, run: run.runId)
            XCTAssertFalse(f.service.channelPublicationIssue(f.key, requestId: Self.request)?.contains("on its way") == true)
            XCTAssertNil(try box.resend(old.commandId))
            XCTAssertTrue(try box.resendUnconfirmed().isEmpty)
            let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
            XCTAssertNotEqual(next.commandId, old.commandId, oldState)
            XCTAssertEqual(next.type, "result.withhold")
            XCTAssertTrue(try box.resendUnconfirmed().isEmpty)
            try f.serve()
            box.allow(connection: 2, generation: "g2")
            f.service.retryStopped() // the actual Try Again action
            try await wait { try f.store.outbox.commands().first { $0.commandId == next.commandId }?.state == .sent }
            let sent = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
            XCTAssertEqual(sent.map(\.type), ["result.withhold"])
            box.hold()
        }
    }

    func testPublicationIntentAndQueueChangeAtomically() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let old = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        // INSERT OR REPLACE uses an INSERT trigger, including replacement.
        try f.write("CREATE TRIGGER fail_insert_intent BEFORE INSERT ON publication_intents BEGIN SELECT RAISE(ABORT, 'test'); END")
        XCTAssertThrowsError(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false))
        XCTAssertEqual(try f.store.outbox.commands().map(\.commandId), [old.commandId])
        XCTAssertNotNil(try f.store.outbox.beginSending(old))
    }

    func testPreparedPublicationIsCheckedAgainBeforeSending() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let old = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send() // schedules a send, but has not yielded to its Task yet
        let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
        XCTAssertNil(try f.store.outbox.beginSending(old))
        try await wait { try f.store.outbox.commands().first { $0.commandId == next.commandId }?.state == .sent }
        let sent = ChatStubProtocol.seen.compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertFalse(sent.contains { $0.type == "result.publish" })
    }

    func testLatestIntentRetiresEveryUnsentDecision() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let original = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        for type in ["result.publish", "result.withhold"] {
            for state in [ChatCommandRecord.State.pending, .unconfirmed, .failed, .dropped] {
                var old = original
                old.commandId = ChatUUID.v7()
                old.type = type
                old.state = state
                old.bodyBytes = try ChatCommandEnvelope(commandId: old.commandId, org: f.key.orgId, type: type, args: .object(ChatService.args(original))).encoded()
                try f.store.outbox.enqueue(old)
            }
        }
        let next = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
        XCTAssertEqual(try f.store.outbox.commands().map(\.commandId), [next.commandId])
        // Even a stale command restored outside the normal queue cannot go.
        try f.store.outbox.enqueue(original)
        XCTAssertNil(try f.store.outbox.beginSending(original))
        XCTAssertEqual(try f.store.outbox.commands().map(\.commandId), [next.commandId])
    }

    func testPublicationCannotSendBeforeRevocationObservationRuns() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let command = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        try f.write("DELETE FROM channels")
        XCTAssertNil(try f.store.outbox.beginSending(command))
        f.send()
        try await wait { try f.store.outbox.commands().first { $0.commandId == command.commandId }?.attempts == 1 }
        XCTAssertFalse(ChatStubProtocol.seen.contains { String(decoding: $0.body, as: UTF8.self).contains(Self.secretResult) })
        f.service.reconcileChannelResults()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testPublicationMigrationKeepsOnlyTheLastIntent() async throws {
        let cache = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(cache, upTo: "release-9")
        let table = ChatCommandTable(queue: cache, table: "outbox")
        var last: String?
        for (index, type) in ["result.publish", "result.withhold", "result.publish", "result.withhold"].enumerated() {
            let id = ChatUUID.v7()
            let bytes = try ChatCommandEnvelope(commandId: id, org: Self.org, type: type,
                                                args: .object(["run_id": .string("run"), "request_id": .string(Self.request)])).encoded()
            let record = ChatCommandRecord(commandId: id, sessionId: "s-anna", type: type, bodyBytes: bytes,
                                           orderKey: "publish:run", dependsOn: nil, createdAt: Date(), state: index == 1 ? .sent : .pending)
            try table.enqueue(record)
            last = id
        }
        try ChatStoreMigrations.cache.migrate(cache)
        let intent = try await cache.read { try ChatPublication.current($0, run: "run") }
        XCTAssertEqual(intent?.commandId, last)
        XCTAssertEqual(try table.commands().filter { $0.state != .sent }.map(\.commandId), [try XCTUnwrap(last)])
    }

    func testFolderScopeSurvivesRequestRemovalAndIsClearedOnDisconnect() async throws {
        for loss in ["cache", "disconnect", "membership"] {
            let f = try await fixture()
            _ = try await f.allow()
            try f.move("running", 5, run: "run")
            try f.write("UPDATE requests SET kind = NULL") // a partial cache cannot reclassify the saved approval
            let folder = root.appendingPathComponent("folder-\(loss)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let access = try await f.calls.requestAccess(callId: Self.request, path: folder.path, reason: "private channel context")
            XCTAssertEqual(access.scope?.key, f.key)
            XCTAssertEqual(access.scope?.kind, "channel")
            XCTAssertEqual(access.scope?.channelId, Self.channel)
            try f.write("DELETE FROM requests")
            XCTAssertTrue(f.calls.pendingAccess.isEmpty)
            XCTAssertEqual(f.calls.channelPendingAccess(Self.request).map(\.id), [access.id])
            if loss == "membership" { f.service.membershipLost(f.key) }
            else { f.calls.useServer(nil, key: nil) }
            XCTAssertTrue(f.calls.pendingAccess.isEmpty)
            XCTAssertTrue(f.calls.channelPendingAccess(Self.request).isEmpty)
            XCTAssertTrue(f.calls.accessRequests.isEmpty)
            let status = await f.calls.accessStatus(access.id, wait: 0)
            XCTAssertNil(status)
        }
    }

    func testAllowFetchesCurrentContentEvenWhenCached() async throws {
        let f = try await fixture()
        try f.move("awaiting_decision", 2)
        try f.serve()
        _ = try await f.service.loadChannelContent(f.key, request: f.request())
        var fresh = f.content()
        fresh.context = []
        try f.serve(fresh)
        XCTAssertNotNil(f.owner.decide(f.key, requestId: Self.request, allow: true, reason: nil), "no synchronous cached-content bypass")
        let problem = await f.owner.decideChannel(f.key, requestId: Self.request, allow: true, reason: nil)
        XCTAssertNil(problem)
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/content") == true }.count, 1)
        let approval = try XCTUnwrap(f.journal.approval(f.key, requestId: Self.request))
        XCTAssertEqual(try TeamLaunchParams.decode(approval.params).inputs.context, "[]")
        try f.move("starting", 4, run: approval.runId)
        _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
        XCTAssertFalse(f.runner.requests[0].prompt.contains("A refund was retried."))
    }

    private func deleteContext(_ f: Fixture, kind: String) throws {
        if kind == "event" {
            let event = CallJSON.event("channel:\(Self.channel)", 1, "message.delete", ["message_id": Self.message, "revision": 3])
            try f.store.queue.write { _ = try ChatMessages.apply($0, event) }
        } else {
            let json: [String: Any] = ["message_id": Self.message, "channel_id": Self.channel, "author_account_id": CallJSON.boris,
                "seq": 1, "created_at": "2026-10-05T10:00:00Z", "revision": 3, "text": "", "mentions": [],
                "deleted_at": kind == "tombstone" ? "2026-10-05T10:01:00Z" : NSNull()]
            let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: json))
            try f.store.queue.write { _ = try ChatMessages.write($0, wire) }
            if kind == "delete" { try f.write("DELETE FROM messages") }
        }
    }

    func testDeletedContextIsRemovedFromContentCacheAndPreview() async throws {
        for kind in ["event", "tombstone", "delete"] {
            let f = try await fixture()
            try f.move("awaiting_decision", 2)
            try f.serve()
            _ = try await f.service.loadChannelContent(f.key, request: f.request())
            try deleteContext(f, kind: kind)
            let cached = try await f.store.queue.read { try String.fetchAll($0, sql: "SELECT content FROM request_contents") }
            XCTAssertTrue(cached.isEmpty, kind)
            let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
            XCTAssertNil(model.content(try f.request()), kind)
        }
    }

    func testLateAllowContentCannotCreateAnApproval() async throws {
        for change in ["session", "generation", "rejoin", "delete"] {
            let f = try await fixture()
            try f.move("awaiting_decision", 2)
            let gate = Gate(); gate.close()
            try f.serve(gate: gate)
            let deciding = Task { await f.owner.decideChannel(f.key, requestId: Self.request, allow: true, reason: nil) }
            try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/content") == true } }
            switch change {
            case "session":
                var connection = try XCTUnwrap(f.service.connection)
                connection.sessionId = "s-new"
                try f.service.saveSignIn(connection, token: "test-only")
            case "generation": try f.store.finishGeneration("g2")
            case "rejoin":
                try f.write("DELETE FROM team_members WHERE account_id = ?", [CallJSON.anna])
                try f.write("INSERT INTO team_members (team_id, account_id) VALUES (?, ?)", [Self.team, CallJSON.anna])
            default: try deleteContext(f, kind: "event")
            }
            gate.open()
            let problem = await deciding.value
            XCTAssertNotNil(problem, change)
            XCTAssertTrue(try f.journal.approvals().isEmpty, change)
            XCTAssertFalse(try f.commands().contains { $0.type == "request.decide" }, change)
            let contents = try await f.store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM request_contents") }
            XCTAssertEqual(contents, 0, change)
        }
    }

    func testRevocationErasesEveryPublicationBodyIncludingOldErasure() async throws {
        for loss in ["channel", "membership", "already-erased"] {
            let f = try await fixture()
            let run = try await f.finish()
            let original = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            for state in [ChatCommandRecord.State.pending, .unconfirmed, .failed, .dropped, .sent] {
                var copy = original
                copy.commandId = ChatUUID.v7()
                copy.bodyBytes = try ChatCommandEnvelope(commandId: copy.commandId, org: f.key.orgId, type: "result.publish", args: .object(ChatService.args(original))).encoded()
                copy.state = state
                try f.store.outbox.enqueue(copy)
            }
            if loss == "already-erased" { try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = NULL, result_erased = 1") } }
            var remaining: [ChatCommandRecord]?
            if loss == "membership" {
                // Inspect before unlinking the cache, as the Team adapter is
                // detached. An open SQLite handle cannot be read after unlink.
                f.service.onCallStore = { _, _ in remaining = try? f.store.outbox.commands() }
                f.service.membershipLost(f.key)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.url.path))
            } else {
                try f.write("DELETE FROM channels"); f.service.reconcileChannelResults()
                remaining = try f.store.outbox.commands()
                XCTAssertNil(try f.store.outbox.beginSending(original), loss)
            }
            XCTAssertNil(try f.journal.run(run.runId)?.resultText, loss)
            XCTAssertEqual(try f.journal.run(run.runId)?.resultErased, true, loss)
            XCTAssertFalse(try XCTUnwrap(remaining).contains { String(decoding: $0.bodyBytes, as: UTF8.self).contains(Self.secretResult) }, loss)
        }
    }

    func testErasureMarkerWaitsForOutboxErasure() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        try f.write("CREATE TRIGGER fail_erasure BEFORE DELETE ON outbox BEGIN SELECT RAISE(ABORT, 'test storage failure'); END")
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(run.runId)?.resultErased, false)
        try f.write("DROP TRIGGER fail_erasure")
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(run.runId)?.resultErased, true)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testRevocationErasesResultsWithoutAnyTerminalCommand() async throws {
        for state in ["lost", "failed", "cancelled", "stop_requested", "stopped", "stop_failed"] {
            let f = try await fixture()
            let approval = try await f.allow()
            let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                    conversationId: "c", startedAt: Date())
            XCTAssertTrue(try f.journal.consume(approval, run: row))
            try f.store.beginGeneration("g2", keeping: [Self.request])
            _ = try f.service.end(row, outcome: .finished, reason: "", result: Self.secretResult, at: Date(), journal: f.journal, waitForState: false)
            XCTAssertEqual(try f.journal.run(row.runId)?.resultText, Self.secretResult, "an incomplete snapshot keeps the result")
            XCTAssertFalse(try f.journal.commands(for: f.key).contains { $0.orderKey == ChatService.runKey(row.runId) })
            try acceptNewGeneration(f, run: row.runId)
            _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            try f.move(state, 8, run: row.runId)
            if ["lost", "failed"].contains(state) { try f.write("DELETE FROM channels") }
            f.service.reconcileChannelResults()
            XCTAssertNil(try f.journal.run(row.runId)?.resultText, state)
            XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true, state)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty, state)
            XCTAssertFalse(try f.journal.commands(for: f.key).contains { $0.orderKey == ChatService.runKey(row.runId) }, state)
        }
    }

    func testDetachedCacheMustBeGoneBeforeMarkingTheResultErased() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        f.service.membershipLost(f.key)
        // Simulate an earlier interrupted cleanup: an unmarked result and
        // an unavailable, detached cache whose file was not removed.
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_erased = 0") }
        try Data(Self.secretResult.utf8).write(to: f.store.url)
        _ = try f.journal.finish(row.runId, .finished, at: Date(), result: Self.secretResult)
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, false)
        try FileManager.default.removeItem(at: f.store.url)
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true)
        XCTAssertNil(try f.journal.run(row.runId)?.resultText)
    }

    func testInitiatorCanCancelEveryActiveChannelStateFromPanelAndCLI() async throws {
        let f = try await fixture()
        f.teamService.enterServerMode()
        ChatOutgoing.install(calls: f.calls, service: f.service)
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        for (i, state) in ["submitted", "awaiting_decision", "approved", "starting", "running", "stop_requested", "finished"].enumerated() {
            try f.move(state, i + 1)
            try f.write("UPDATE requests SET initiator_account_id = ?", [f.key.accountId])
            let request = try f.request()
            let active = i < 5
            XCTAssertEqual(model.canCancel(request), active, state)
            if active { XCTAssertNil(model.cancel(request), state) }
            var command = AgentPadCLIRequest(verb: .team)
            command.teamAction = "cancel"
            command.teamCall = Self.request
            let response = await TeamCLIHandler.handle(command, service: f.teamService)
            XCTAssertEqual(response.ok, active, state)
            XCTAssertNil(response.team?.call, "CLI cancellation returns no channel text")
        }
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "request.cancel" }.count, 10)
        try f.write("UPDATE requests SET state = 'running', initiator_account_id = ?", [CallJSON.boris])
        XCTAssertNotNil(f.service.cancelChannelRequest(f.key, requestId: Self.request))
        try f.write("UPDATE requests SET initiator_account_id = ?", [f.key.accountId])
        try f.write("DELETE FROM channels")
        XCTAssertFalse(model.canCancel(try f.request()))
        XCTAssertNotNil(f.service.cancelChannelRequest(f.key, requestId: Self.request))
    }

    func testSignalWaitsForFullFormAndVerifiedContent() async throws {
        let f = try await fixture()
        try f.serve()
        try f.move("submitted", 1, fixed: false)
        let signal = await f.owner.perform(.receive, request: try f.request(), key: f.key)
        XCTAssertEqual(signal, .later)
        XCTAssertTrue(try f.commands().isEmpty)
        XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        try f.move("submitted", 1, refs: true)
        let full = await f.owner.perform(.receive, request: try f.request(), key: f.key)
        XCTAssertEqual(full, .done)
        XCTAssertEqual(try f.commands().map(\.type), ["request.received"])
        XCTAssertEqual(f.runner.calls, 0)
        XCTAssertTrue(ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/content") == true })
    }

    func testReceiveRetriesDiscardedContentAndReachesDecisionWithoutAnotherEvent() async throws {
        let f = try await fixture()
        try f.move("submitted", 1, refs: true)
        try await f.store.queue.write { try ChatReconcile.reconcile($0, [Self.request], facts: [Self.request: ChatLocalFacts()]) }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        try f.serve(gate: gate)
        let actions = ChatActionRunner(key: f.key)
        actions.rewriteDelay = .milliseconds(80)
        actions.handler = { f.service.actionHandlers[$0] }
        actions.attach(f.store.calls)
        defer { actions.mayRun = { false } }
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/content") == true } }
        // No request event and no runner.run(): only an unrelated deletion.
        let deletion = CallJSON.event("channel:\(Self.channel)", 1, "message.delete", ["message_id": "unrelated-message", "revision": 2])
        try await f.store.queue.write { _ = try ChatMessages.apply($0, deletion) }
        gate.open()
        try await wait { try f.commands().contains { $0.type == "request.received" } }
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/content") == true }.count, 2)
        var wanted = false
        f.service.onDecisionWanted = { _ in wanted = true }
        f.send()
        f.sender?.onSent = { record, answer in
            f.service.commandAnswered(f.key, record, .taken(answer))
            if record.type == "request.received" {
                // The stub server's transition after it receives the command.
                try! f.move("awaiting_decision", 2, refs: true)
                try! f.store.queue.write { try ChatReconcile.reconcile($0, [Self.request], facts: [Self.request: ChatLocalFacts()]) }
                actions.run()
            }
        }
        try await wait { wanted }
        XCTAssertTrue(f.service.channelDecisionReady(f.key, request: try f.request()))
        XCTAssertEqual(f.runner.calls, 0)
    }

    func testWrongContentOrReferencesNeverEnableDecision() async throws {
        for fault in ["id", "text", "revision", "message", "missing", "duplicate"] {
            let f = try await fixture()
            try f.move("awaiting_decision", 2, refs: true)
            var content = f.content()
            switch fault {
            case "id": content.requestId = "another"
            case "text": content.text = "another request"
            case "revision": content.context?[0].revision = 3
            case "message": content.context?[0].messageId = "another-message"
            case "missing": content.context = nil
            default: let first = content.context![0]; content.context?.append(first)
            }
            try f.serve(content)
            let loaded = try await f.service.loadChannelContent(f.key, request: f.request())
            XCTAssertFalse(loaded, fault)
            XCTAssertFalse(f.service.channelDecisionReady(f.key, request: try f.request()), fault)
            let problem = await f.owner.decideChannel(f.key, requestId: Self.request, allow: true, reason: nil)
            XCTAssertNotNil(problem, fault)
            XCTAssertTrue(try f.journal.approvals().isEmpty, fault)
        }
    }

    func testLateContentIsDiscardedAfterSessionGenerationOrRevokeAndRejoin() async throws {
        for change in ["session", "generation", "rejoin", "snapshot"] {
            let f = try await fixture()
            try f.move("awaiting_decision", 2, refs: true)
            let gate = Gate()
            gate.close()
            try f.serve(gate: gate)
            let loading = Task { try await f.service.loadChannelContent(f.key, request: f.request()) }
            try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/content") == true } }
            switch change {
            case "session":
                var connection = try XCTUnwrap(f.service.connection)
                connection.sessionId = "s-later"
                try f.service.saveSignIn(connection, token: "test-only-later")
            case "generation": try f.store.finishGeneration("g2")
            case "snapshot": f.service.orgSessions[f.key]?.snapshotOwed = true
            default:
                try f.write("DELETE FROM team_members WHERE account_id = ?", [CallJSON.anna])
                try f.write("INSERT INTO team_members (team_id, account_id) VALUES (?, ?)", [Self.team, CallJSON.anna])
            }
            gate.open()
            let loaded = try await loading.value
            XCTAssertFalse(loaded, change)
            let count = try await f.store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM request_contents") }
            XCTAssertEqual(count, 0, change)
        }
    }

    func testChannelRequestsNeverReachDViewsButExecutionStillFindsThem() async throws {
        let f = try await fixture()
        try f.move("running", 5, run: "run")
        try f.move("awaiting_decision", 2, id: "personal", kind: "personal")
        try f.write("UPDATE requests SET kind = NULL WHERE request_id = 'personal'")
        let adapter = ChatTeamCallStore(calls: f.store.calls, key: f.key)
        XCTAssertEqual(try adapter.loadLog().incoming.map(\.id), ["personal"], "NULL kinds remain visible")
        XCTAssertTrue(try adapter.loadCall(Self.request).incoming.isEmpty)
        XCTAssertTrue(f.calls.incoming.allSatisfy { $0.id != Self.request })
        XCTAssertNotNil(f.calls.executionIncoming(Self.request))
        try f.write("INSERT INTO threads (thread_id, peer, agent_id, created_at) VALUES (?, ?, ?, ?)", [Self.message, CallJSON.boris, CallJSON.agent, Date()])
        XCTAssertTrue(try adapter.loadThreads().isEmpty)
        try f.write("UPDATE agent_channels SET owner_account_id = ?", [CallJSON.boris])
        XCTAssertTrue(f.calls.colleaguesAgents.isEmpty, "channel-only agents never enter team agents")
    }

    func testNoResultInAnyHTTPBodyUntilExplicitPublishAndDuplicateClickIsOneCommand() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        XCTAssertEqual(run.resultText, Self.secretResult)
        XCTAssertEqual(f.runner.calls, 1)
        XCTAssertEqual(run.kind, "channel")
        XCTAssertEqual(run.org, f.key.orgId)
        XCTAssertEqual(run.channelId, Self.channel)
        XCTAssertEqual(run.threadRootId, Self.message)
        try f.service.tellRun(run.runId) // recovery must not append result.deliver either
        f.service.onRunActivity(run, Self.secretResult)
        f.send()
        try await wait { try f.commands().allSatisfy { $0.state == .sent } }
        XCTAssertFalse(try f.commands().contains { $0.type == "result.deliver" })
        XCTAssertFalse(ChatStubProtocol.seen.contains { String(decoding: $0.body, as: UTF8.self).contains(Self.secretResult) }, "ALL HTTP bodies, not only result commands")
        XCTAssertTrue(f.service.undeliveredResults().isEmpty)
        XCTAssertNotNil(f.service.channelPreview(f.key, requestId: Self.request))
        XCTAssertNil(f.service.channelPublishProblem(f.key, requestId: Self.request))
        let first = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        let twice = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        XCTAssertEqual(first.commandId, twice.commandId)
        f.send()
        try await wait { try f.request().publication == "published" }
        let containing = ChatStubProtocol.seen.filter { String(decoding: $0.body, as: UTF8.self).contains(Self.secretResult) }
        XCTAssertEqual(containing.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: XCTUnwrap(containing.first).body).type, "result.publish")
    }

    /// F5 (2): receiving an agent's mention must never take the composer's
    /// human-send path. Observe the actual feed before asserting no offer.
    func testAgentMentionNeverOffersOrCreatesAnotherRequest() async throws {
        let f = try await fixture()
        let model = ChatChannelModel(key: f.key, channel: Self.channel)
        model.service = f.service
        model.follow(f.store)
        let agents = try f.store.channelAgents(Self.channel)
        let mention = "@billing@anna please answer"
        XCTAssertEqual(ChatChannelAsk.asked(in: mention, agents: agents).map(\.agentId), [CallJSON.agent])
        let authorAgent = "00000000-0000-4000-8000-000000000099"
        var event = CallJSON.event("channel:\(Self.channel)", 1, "message.post", ["message_id": Self.message, "revision": 1, "message_seq": 1])
        event.message = CallJSON.json([
            "message_id": Self.message, "channel_id": Self.channel, "author_account_id": CallJSON.anna,
            "author_agent_id": authorAgent, "run_id": "another-agents-run", "seq": 1,
            "created_at": "2026-10-05T10:00:00Z", "revision": 1, "text": mention, "mentions": []
        ])
        XCTAssertEqual(try f.store.apply(event), .applied)
        try await wait { model.feed.messages.first?.messageId == Self.message }
        XCTAssertEqual(model.feed.messages.first?.authorAgentId, authorAgent)
        XCTAssertTrue(model.offers.isEmpty)
        XCTAssertTrue(try f.store.calls.requests().isEmpty)
        XCTAssertFalse(try f.commands().contains { $0.type == "request.create" })
        XCTAssertEqual(f.runner.calls, 0)
        // Positive control: the identical mention typed by the user offers
        // the agent, but still requires a separate confirmation to ask it.
        XCTAssertTrue(model.send(mention, root: nil, members: [], agents: agents))
        XCTAssertEqual(model.offers.map(\.agentId), [CallJSON.agent])
        XCTAssertFalse(try f.commands().contains { $0.type == "request.create" })
    }

    func testEveryProfileAndFrozenContextReachTeamLauncherFromAllow() async throws {
        for profile in TeamAccessProfile.allCases {
            let f = try await fixture()
            f.agent.access = profile
            f.agent.sessionId = "personal-memory"
            try f.assign()
            let original = try contextMessage(revision: 2, text: "A refund was retried.")
            try await f.store.queue.write { _ = try ChatMessages.write($0, original) }
            let approval = try await f.allow()
            let params = try TeamLaunchParams.decode(approval.params)
            XCTAssertEqual(params.channelId, Self.channel)
            XCTAssertEqual(params.threadRootId, Self.message)
            XCTAssertEqual(params.inputs.thread, "channel:\(Self.channel):\(Self.message)")
            XCTAssertEqual(params.inputs.context, f.content().launchContext)
            XCTAssertEqual(params.inputs.access, profile.rawValue)
            XCTAssertFalse(ChatService.ThreadScope.personal(initiator: CallJSON.boris).admits(params))
            XCTAssertEqual(approval.paramsHash, TeamLaunchParams.hash(Data(approval.params.utf8)))
            var changed = params
            changed.inputs.context = "changed revision or snapshot text"
            XCTAssertNotEqual(approval.paramsHash, TeamLaunchParams.hash(try changed.canonical()))
            changed = params; changed.inputs.access = "a different profile"
            XCTAssertNotEqual(approval.paramsHash, TeamLaunchParams.hash(try changed.canonical()))
            let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
            let terms = try XCTUnwrap(model.decisionText(f.request()))
            XCTAssertTrue(terms.contains(profile.rawValue))
            XCTAssertTrue(terms.contains("personal session"))
            XCTAssertTrue(terms.contains("Audience:") && terms.contains("Deadline:") && terms.contains("Limits:"))
            XCTAssertEqual(terms.contains("EX-7"), profile.runsShell)
            // An actual later revision is visible in the message cache, but
            // neither the reviewed context nor the launch may pick it up.
            let edited = try contextMessage(revision: 3, text: "Changed AFTER Allow; do not execute this context")
            try await f.store.queue.write { _ = try ChatMessages.write($0, edited) }
            let cached = try await f.store.queue.read {
                try String.fetchOne($0, sql: "SELECT text FROM messages WHERE message_id = ?", arguments: [Self.message])
            }
            XCTAssertEqual(cached, edited.text)
            try f.move("starting", 4, run: approval.runId)
            _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
            XCTAssertEqual(f.runner.requests.first?.agent.access, profile)
            XCTAssertEqual(f.runner.requests.first?.isChannelConversation, true)
            XCTAssertTrue(f.runner.requests.first?.prompt.contains("A refund was retried.") == true)
            XCTAssertFalse(f.runner.requests.first?.prompt.contains("Changed AFTER Allow") == true)
            XCTAssertEqual(f.runner.calls, 1)
        }
    }

    private func contextMessage(revision: Int, text: String) throws -> ChatMessageWire {
        let json: [String: Any] = ["message_id": Self.message, "channel_id": Self.channel, "author_account_id": CallJSON.boris,
            "seq": 1, "created_at": "2026-10-05T10:00:00Z", "revision": revision, "text": text, "mentions": []]
        return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDecisionAndPreviewAreClosedByChannelGateAndOtherDeviceCannotDecide() async throws {
        let f = try await fixture()
        _ = try await f.allow()
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        XCTAssertFalse(model.requests.isEmpty)
        try f.write("UPDATE requests SET on_this_device = 0")
        XCTAssertFalse(f.service.channelDecisionReady(f.key, request: try f.request()))
        let problem = await f.owner.decideChannel(f.key, requestId: Self.request, allow: true, reason: nil)
        XCTAssertNotNil(problem)
        try f.write("UPDATE meta SET rights_in_doubt = 1")
        XCTAssertFalse(model.visible)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertNil(model.decisionText(try f.request()))
        XCTAssertNil(model.content(try f.request()))
        XCTAssertNil(f.service.channelPreview(f.key, requestId: Self.request))
    }

    func testDecisionNoticeUsesChannelAndReconcilesWithoutMessage() async throws {
        let f = try await fixture()
        _ = try await f.allow()
        let previous = ChatNotifications.post
        defer { ChatNotifications.post = previous }
        var ids: [String] = []
        ChatNotifications.post = { id, title in ids.append(id); XCTAssertEqual(title, "A request waits for your decision") }
        ChatNotifications.requestAwaitsDecision(f.key, requestId: Self.request, service: f.service)
        ChatNotifications.requestAwaitsDecision(f.key, requestId: Self.request, service: f.service)
        let id = "chat:\(f.key.orgId):\(Self.channel):request-\(Self.request)"
        XCTAssertEqual(ids, [id])
        XCTAssertTrue(ChatNotifications.stillDue(id, f.service))
        try f.write("UPDATE requests SET state = 'approved'")
        XCTAssertFalse(ChatNotifications.stillDue(id, f.service))
        try f.write("UPDATE requests SET state = 'awaiting_decision'")
        try f.write("DELETE FROM channels")
        XCTAssertFalse(ChatNotifications.stillDue(id, f.service))
    }

    func testEveryCachedRevocationPreventsPublish() async throws {
        for change in ["initiator", "owner", "member", "agent", "disabled", "archived", "team", "doubt"] {
            let f = try await fixture()
            _ = try await f.finish()
            switch change {
            case "initiator": try f.write("DELETE FROM team_members WHERE account_id = ?", [CallJSON.boris])
            case "owner": try f.write("DELETE FROM team_members WHERE account_id = ?", [CallJSON.anna])
            case "member": try f.write("DELETE FROM members WHERE account_id = ?", [CallJSON.boris])
            case "agent": try f.write("DELETE FROM agent_channels")
            case "disabled": try f.write("UPDATE agent_channels SET enabled = 0")
            case "archived": try f.write("UPDATE channels SET archived = 1")
            case "team": try f.write("UPDATE teams SET archived_at = 'now'")
            default: try f.write("UPDATE meta SET rights_in_doubt = 1")
            }
            XCTAssertNotNil(f.service.channelPublishProblem(f.key, requestId: Self.request), change)
            XCTAssertThrowsError(try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true), change)
            XCTAssertFalse(try f.commands().contains { $0.type == "result.publish" }, change)
        }
    }

    func testWithholdAndPublishFailedKeepDraftLocal() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        let withheld = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: false)
        XCTAssertEqual(withheld.type, "result.withhold")
        XCTAssertNil(ChatService.args(withheld)["text"])
        let answer = ChatCommandAnswer(events: [], result: .object(["request_id": .string(Self.request), "version": .number(8),
                                                                     "publication": .string("publish_failed"), "publish_reason": .string("initiator_left_team")]))
        f.service.commandAnswered(f.key, withheld, .taken(answer))
        XCTAssertEqual(try f.request().publication, "publish_failed")
        XCTAssertEqual(f.service.channelPublishProblem(f.key, requestId: Self.request), "the person who asked left the team")
        XCTAssertEqual(try f.journal.run(run.runId)?.resultText, Self.secretResult)
        XCTAssertTrue(f.service.undeliveredResults().isEmpty)
    }

    func testResultErasedAfterChannelLossButNotDuringIncompleteSnapshot() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = ?", arguments: [Self.secretResult]) }
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        XCTAssertNil(try f.journal.run(row.runId)?.resultText, "still running: erase any existing result")
        try f.move("running", 5, run: row.runId)
        f.service.orgSessions[f.key]?.snapshotOwed = true
        _ = try f.service.end(row, outcome: .finished, reason: "", result: Self.secretResult, at: Date(), journal: f.journal, waitForState: false)
        XCTAssertNil(try f.journal.run(row.runId)?.resultText, "an erased result cannot return during a later snapshot")
        f.service.orgSessions[f.key]?.snapshotOwed = false
        ChatNotifications.reconcile(f.service)
        XCTAssertNil(try f.journal.run(row.runId)?.resultText)
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true)
        XCTAssertTrue(try f.commands().contains { $0.type == "run.finished" })
        XCTAssertNotNil(try f.journal.run(row.runId))
    }

    func testRevokedRunCannotStoreALateResultAfterDisconnect() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true, "revocation also covers a result not yet produced")
        await f.service.disconnect()
        _ = try f.journal.finish(row.runId, .finished, result: Self.secretResult)
        XCTAssertEqual(try f.journal.run(row.runId)?.outcome, .finished)
        XCTAssertNil(try f.journal.run(row.runId)?.resultText)
    }

    func testReLoginKeepsPreviewButQueuedPublicationNeedsNewDecision() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let record = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send(); f.sender?.hold()
        f.sender?.adoptSession("s-new", token: "test-new")
        var connection = try XCTUnwrap(f.service.connection)
        connection.sessionId = "s-new"
        try f.service.saveSignIn(connection, token: "test-new")
        try f.write("UPDATE meta SET rights_session = 's-new', rights_in_doubt = 0")
        XCTAssertNotNil(f.service.channelPreview(f.key, requestId: Self.request))
        let now = try XCTUnwrap(f.store.outbox.commands().first { $0.commandId == record.commandId })
        XCTAssertNotEqual(now.state, .pending)
        XCTAssertFalse(ChatOutbox.carriedOver.contains("result.publish"))
        XCTAssertFalse(ChatOutbox.carriedOver.contains("result.withhold"))
        XCTAssertTrue(f.service.undeliveredResults().isEmpty)
        f.service.orgSessions[f.key]?.snapshotOwed = true
        XCTAssertNil(f.service.channelPreview(f.key, requestId: Self.request))
    }

    func testFolderConsentUsesExecutionLookupAndChannelGate() async throws {
        let f = try await fixture()
        _ = try await f.allow()
        try f.move("running", 5, run: "run")
        let folder = root.appendingPathComponent("another-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = try await f.calls.requestAccess(callId: Self.request, path: folder.path, reason: "need a file")
        XCTAssertTrue(f.calls.pendingAccess.isEmpty, "no Team or Dock card")
        XCTAssertEqual(f.calls.channelPendingAccess(Self.request).map(\.id), [access.id])
        try f.write("DELETE FROM channels")
        XCTAssertTrue(f.calls.channelPendingAccess(Self.request).isEmpty)
        let refused = await f.calls.decideAccess(access.id, .once)
        XCTAssertNotNil(refused)
    }
    func testChannelAskUsesItsOwnCommandAndStopsShowingOnceConfirmed() async throws {
        let f = try await fixture()
        let id = try f.service.askInChannel(f.key, channel: Self.channel, agentId: CallJSON.agent, root: Self.message,
                                          text: "Please answer", context: [])
        let command = try XCTUnwrap(f.store.outbox.commands().first)
        XCTAssertEqual(command.type, "request.create_in_channel")
        XCTAssertEqual(ChatService.args(command)["context"], .array([]))
        let before = try await f.store.queue.read { try ChatChannelAsk.asks($0, channel: Self.channel) }
        XCTAssertEqual(before.count, 1)
        try f.move("submitted", 1, id: id)
        let after = try await f.store.queue.read { try ChatChannelAsk.asks($0, channel: Self.channel) }
        XCTAssertTrue(after.isEmpty)
    }

    func testServerApprovalAloneCannotLaunchAndDeclineMakesNoApproval() async throws {
        let f = try await fixture()
        try f.move("approved", 3)
        let started = await f.owner.perform(.start, request: try f.request(), key: f.key)
        XCTAssertEqual(started, .done)
        XCTAssertTrue(try f.journal.approvals().isEmpty)
        XCTAssertEqual(f.runner.calls, 0)
        try f.write("UPDATE requests SET state = 'awaiting_decision'")
        try f.serve()
        _ = try await f.service.loadChannelContent(f.key, request: f.request())
        let problem = await f.owner.decideChannel(f.key, requestId: Self.request, allow: false, reason: "later")
        XCTAssertNil(problem)
        XCTAssertTrue(try f.journal.approvals().isEmpty)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(f.commands().first))["allow"], .bool(false))
        XCTAssertEqual(f.runner.calls, 0)
    }

    func testRestartAfterAllowUsesTheApprovedSnapshotAndHashIsChecked() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        // Restart invalidates the HTTP cache's authority, but preserves the
        // journal's immutable snapshot and consent in the same session.
        try f.write("DELETE FROM request_contents")
        try await f.service.start(mode: .server)
        try f.move("starting", 4, run: approval.runId)
        _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
        XCTAssertEqual(f.runner.calls, 1)
        XCTAssertTrue(f.runner.requests[0].prompt.contains("A refund was retried."))
        let bad = try await fixture()
        let tampered = try await bad.allow()
        try await bad.journal.queue.write { try $0.execute(sql: "UPDATE approvals SET params_hash = 'corrupt'") }
        try bad.move("starting", 4, run: tampered.runId)
        do { _ = try await XCTUnwrap(bad.service.launcher).launch(approvalId: tampered.id); XCTFail("a corrupt approval ran") }
        catch { XCTAssertEqual(error as? TeamLauncher.Failure, .voided("params_changed")) }
        XCTAssertEqual(bad.runner.calls, 0)
    }

    func testEndingARevokedRunErasesTheDraftAfterRecordingItsFinalFact() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try f.move("running", 5, run: row.runId)
        try f.write("DELETE FROM channels")
        _ = try f.service.end(row, outcome: .finished, reason: "", result: Self.secretResult, at: Date(), journal: f.journal, waitForState: false)
        XCTAssertNil(try f.journal.run(row.runId)?.resultText)
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true)
        XCTAssertTrue(try f.commands().contains { $0.type == "run.finished" })
    }

    func testAPublicationWhoseAnswerWasLostRepeatsIdenticalBytes() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let body = try JSONEncoder().encode(ChatCommandAnswer(events: [], result: .object([
            "request_id": .string(Self.request), "version": .number(8), "publication": .string("published"),
            "publish_reason": .null, "message_id": .string("one-message")])))
        ChatStubProtocol.reset { request, data in
            if let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: data), envelope.type == "result.publish" {
                let publications = ChatStubProtocol.seen.filter { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.type == "result.publish" }
                if publications.count == 1 { return .failure(URLError(.networkConnectionLost)) }
                return .success(.init(status: 200, body: body))
            }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        f.send()
        try await wait { try f.request().publication == "published" }
        let sent = ChatStubProtocol.seen.filter { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.type == "result.publish" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.body, sent.last?.body)
    }

    func testFolderGrantContinuesTheSameChannelRunThroughD9() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        f.runner.holds = true
        try f.move("starting", 4, run: approval.runId)
        let running = Task { try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id) }
        try await wait { f.runner.waiting == 1 }
        try f.move("running", 5, run: approval.runId)
        let folder = root.appendingPathComponent("granted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = try await f.calls.requestAccess(callId: Self.request, path: folder.path, reason: "need a file")
        let problem = await f.calls.decideAccess(access.id, .once)
        XCTAssertNil(problem)
        let original = try XCTUnwrap(f.journal.approval(approval.id))
        let continuation = try XCTUnwrap(f.journal.pendingContinuation(of: original))
        let params = try TeamLaunchParams.decode(continuation.params)
        XCTAssertEqual(params.channelId, Self.channel)
        XCTAssertEqual(params.inputs.context, f.content().launchContext)
        XCTAssertEqual(params.runId, approval.runId)
        f.runner.holds = false
        f.runner.release()
        _ = try await running.value
        XCTAssertEqual(f.runner.calls, 2)
        XCTAssertEqual(f.runner.requests.first?.sessionId, f.runner.requests.last?.sessionId)
        XCTAssertEqual(f.runner.requests.last?.isChannelConversation, true)
        XCTAssertEqual(f.runner.requests.last?.agent.extraFolders, [folder.path])
        XCTAssertEqual(try f.journal.runs().count, 1)
    }

    func testNewGenerationWithLocalResultNeverPublishesAutomatically() async throws {
        let f = try await fixture()
        let run = try await f.finish()
        try f.store.beginGeneration("g2", keeping: [Self.request])
        try f.journal.finish(f.key, "g2")
        _ = try f.service.tellRun(run.runId)
        XCTAssertNil(f.service.channelPreview(f.key, requestId: Self.request))
        XCTAssertEqual(try f.journal.run(run.runId)?.resultText, Self.secretResult)
        XCTAssertFalse(try f.commands().contains { ["result.deliver", "result.publish", "result.withhold"].contains($0.type) })
    }

    func testCapabilityAndQueuedPublicationFailuresStayInTheChannel() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        try f.write("UPDATE meta SET agents_served = 0")
        XCTAssertFalse(model.visible)
        XCTAssertNil(f.service.channelPreview(f.key, requestId: Self.request))
        XCTAssertNotNil(f.service.channelPublishProblem(f.key, requestId: Self.request))
        try f.write("UPDATE meta SET agents_served = 1")
        let command = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        XCTAssertEqual(f.service.channelPublicationIssue(f.key, requestId: Self.request), "Your publication decision is on its way.")
        try f.write("UPDATE outbox SET state = 'failed', error = 'too_large' WHERE command_id = ?", [command.commandId])
        XCTAssertTrue(f.service.channelPublicationIssue(f.key, requestId: Self.request)?.contains("Not published") == true)
        XCTAssertEqual(try f.request().publication, "awaiting_publish", "a queue error cannot invent server state")
        let retry = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
        XCTAssertNotEqual(retry.commandId, command.commandId)
        try f.write("UPDATE outbox SET state = 'unconfirmed' WHERE command_id = ?", [retry.commandId])
        XCTAssertTrue(f.service.channelPublicationIssue(f.key, requestId: Self.request)?.contains("not confirmed") == true)
        try f.write("UPDATE meta SET rights_in_doubt = 1")
        XCTAssertNil(f.service.channelPublicationIssue(f.key, requestId: Self.request))
    }

    func testErasureDoesNotWaitForAnUnknownOutcomeToBeTold() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try f.write("DELETE FROM channels")
        try f.write("DELETE FROM requests")
        _ = try f.service.end(row, outcome: .finished, reason: "", result: Self.secretResult, at: Date(), journal: f.journal, waitForState: false)
        f.service.reconcileChannelResults()
        XCTAssertNil(try f.journal.run(row.runId)?.resultText, "erasure needs no terminal command")
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true)
        try f.move("running", 5, run: row.runId)
        try f.service.tellRun(row.runId)
        XCTAssertTrue(try f.commands().contains { $0.type == "run.finished" })
        XCTAssertNil(try f.journal.run(row.runId)?.resultText)
        XCTAssertEqual(try f.journal.run(row.runId)?.resultErased, true)
    }

    func testConfirmedOrganizationRemovalErasesEvenBeforeTheLocalFinalFact() async throws {
        let f = try await fixture()
        let done = try await f.finish()
        f.service.membershipLost(f.key)
        XCTAssertNil(try f.journal.run(done.runId)?.resultText)
        XCTAssertEqual(try f.journal.run(done.runId)?.resultErased, true)
        let running = try await fixture()
        let approval = try await running.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try running.journal.consume(approval, run: row))
        try await running.journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_text = ?", arguments: [Self.secretResult]) }
        running.service.membershipLost(running.key)
        XCTAssertNil(try running.journal.run(row.runId)?.resultText, "existing text is erased even before the run ends")
        XCTAssertEqual(try running.journal.run(row.runId)?.resultErased, true)
        _ = try running.service.end(row, outcome: .finished, reason: "", result: Self.secretResult, at: Date(), journal: running.journal, waitForState: false)
        XCTAssertNil(try running.journal.run(row.runId)?.resultText)
        XCTAssertEqual(try running.journal.run(row.runId)?.resultErased, true)
        let offline = try await fixture()
        let kept = try await offline.finish()
        await offline.service.disconnect()
        XCTAssertEqual(try offline.journal.run(kept.runId)?.resultText, Self.secretResult, "Disconnect is not a confirmed revocation")
        XCTAssertNil(offline.service.channelPreview(offline.key, requestId: Self.request))
    }

    private func otherKey(_ key: ChatOrgKey, changing component: String) throws -> ChatOrgKey {
        ChatOrgKey(server: component == "server" ? try ChatServerAddress(parsing: "https://other.example.com") : key.server,
                   accountId: component == "account" ? CallJSON.boris : key.accountId,
                   orgId: component == "org" ? UUID().uuidString.lowercased() : key.orgId)
    }

    func testConnectingAfterMembershipLossPreservesOtherOrganizationsHistory() async throws {
        for component in ["org", "account", "server"] {
            // B's journal and transcript survive Disconnect; its cache does not.
            let f = try await fixture()
            let kept = try await f.finish()
            let resultBytes = Data(try XCTUnwrap(kept.resultText).utf8)
            let file = try transcript(f, id: kept.conversationId)
            let bytes = Data("B transcript: e\u{301} 🦊\r\nsecond turn\n".utf8)
            try bytes.write(to: file)
            await f.service.disconnect()
            XCTAssertNil(f.service.orgSessions[f.key])
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.url.path))
            XCTAssertEqual(try f.journal.run(kept.runId), kept)

            // Keep A in the same journal, with matching channel/request ids:
            // every part of (server, account, org) must bound the erasure.
            let removedKey = try otherKey(f.key, changing: component)
            var approval = try XCTUnwrap(f.journal.approval(kept.approvalId))
            approval.id = ChatUUID.v7()
            approval.runId = ChatUUID.v7()
            approval.startCommandId = ChatUUID.v7()
            approval.server = removedKey.server.description
            approval.accountId = removedKey.accountId
            approval.orgId = removedKey.orgId
            var removed = kept
            removed.runId = approval.runId
            removed.approvalId = approval.id
            removed.org = removedKey.orgId
            removed.conversationId = UUID().uuidString.lowercased()
            try f.journal.insert(approval)
            let removedRun = removed
            try await f.journal.queue.write { try removedRun.insert($0) }
            let removedFile = try transcript(f, id: removed.conversationId)
            try await f.service.completeSignIn(.init(token: "test-a", sessionId: "s-a", accountId: removedKey.accountId, orgs: []),
                server: removedKey.server, deviceName: "Mac", orgId: removedKey.orgId)
            try await f.service.keepSignIn()
            try await f.service.start(mode: .server)
            f.service.membershipLost(removedKey)
            guard case .notMember = f.service.state else { return XCTFail("A's removal was not recorded") }
            XCTAssertEqual(try f.journal.run(removed.runId)?.channelRevoked, true, component)
            XCTAssertNil(try f.journal.run(removed.runId)?.resultText, component)
            XCTAssertFalse(FileManager.default.fileExists(atPath: removedFile.path), component)
            XCTAssertEqual(try f.journal.run(kept.runId), kept, component)
            XCTAssertEqual(try? Data(contentsOf: file), bytes, component)

            // Connect directly from A's notMember state: no Disconnect here.
            try await f.service.completeSignIn(.init(token: "test-b", sessionId: "s-b", accountId: f.key.accountId, orgs: []),
                server: f.key.server, deviceName: "Mac", orgId: f.key.orgId)
            XCTAssertEqual(f.service.connection?.orgKey, f.key)
            XCTAssertEqual(f.service.state, .signedIn)
            XCTAssertEqual(try f.journal.run(kept.runId), kept, component)
            XCTAssertEqual(try f.journal.run(kept.runId)?.resultText.map { Data($0.utf8) }, resultBytes, component)
            XCTAssertEqual(try? Data(contentsOf: file), bytes, component)
            try await f.service.keepSignIn()
            try await f.service.start(mode: .server)
            f.service.reconcileChannelResults()
            XCTAssertEqual(try f.journal.run(kept.runId), kept, component)
            XCTAssertEqual(try f.journal.run(kept.runId)?.resultText.map { Data($0.utf8) }, resultBytes, component)
            XCTAssertEqual(try? Data(contentsOf: file), bytes, component)
        }
    }

    func testRevocationRechecksEveryOrgKeyComponentInTheErasureTransaction() async throws {
        for component in ["org", "account", "server"] {
            let f = try await fixture()
            let kept = try await f.finish()
            let file = try transcript(f, id: kept.conversationId)
            let bytes = try Data(contentsOf: file)
            _ = try f.service.publishChannelResult(f.key, requestId: Self.request, publish: true)
            let movedKey = try otherKey(f.key, changing: component)
            let journal = f.journal
            // Inject a scope change after candidate selection, at cache erasure.
            // The journal transaction must check ownership again before writing.
            let moveApproval = DatabaseFunction("move_approval", argumentCount: 0) { _ in
                try journal.queue.write { db in
                    try db.execute(sql: "UPDATE approvals SET server = ?, account_id = ?, org_id = ? WHERE id = ?",
                        arguments: [movedKey.server.description, movedKey.accountId, movedKey.orgId, kept.approvalId])
                }
                return nil
            }
            try await f.store.queue.write { $0.add(function: moveApproval) }
            try f.write("CREATE TRIGGER move_scope BEFORE DELETE ON outbox BEGIN SELECT move_approval(); END")
            f.service.reconcileChannelResults(revoked: f.key)
            XCTAssertEqual(try f.journal.approval(kept.approvalId)?.key, movedKey, component)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty, component)
            XCTAssertEqual(try f.journal.run(kept.runId), kept, component)
            XCTAssertEqual(try? Data(contentsOf: file), bytes, component)
        }
    }

    func testMembershipStateFollowsOnlyTheConfirmedOrganization() async throws {
        for component in ["org", "account", "server"] {
            let f = try await fixture()
            let other = try otherKey(f.key, changing: component)
            f.service.membershipLost(other)
            XCTAssertEqual(f.service.state, .signedIn, component)
            f.service.membershipLost(f.key)
            guard case .notMember(let removed, _) = f.service.state else { return XCTFail("removal not recorded") }
            XCTAssertEqual(removed, f.key)
            let state = f.service.state
            f.service.membershipRegained(other)
            XCTAssertEqual(f.service.state, state, component)
            f.service.membershipRegained(f.key)
            XCTAssertEqual(f.service.state, .signedIn, component)
        }
    }

    func testOtherOwnerDeviceShowsTheChannelProfileButNoDecision() async throws {
        let f = try await fixture()
        try f.move("awaiting_decision", 2, here: false)
        f.service.localAgent = { _ in nil }
        try f.write("UPDATE agent_channels SET access = 'read-git'")
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: Self.channel)
        let terms = try XCTUnwrap(model.decisionText(f.request()))
        XCTAssertTrue(terms.contains("From #billing") && terms.contains("read-git") && terms.contains("EX-7"))
        XCTAssertTrue(terms.contains("Audience:") && terms.contains("executor Mac"))
        XCTAssertFalse(f.service.channelDecisionReady(f.key, request: try f.request()))
        let problem = await f.owner.decideChannel(f.key, requestId: Self.request, allow: true, reason: nil)
        XCTAssertNotNil(problem)
        XCTAssertTrue(try f.journal.approvals().isEmpty)
    }

    func testLauncherChecksChannelAndRootAsWellAsHashedInputs() async throws {
        for field in ["channel", "root"] {
            let f = try await fixture()
            let approval = try await f.allow()
            var launch = try XCTUnwrap(f.service.launchRequest(Self.request))
            if field == "channel" { launch.channelId = "another-channel" } else { launch.threadRootId = "another-root" }
            f.service.launchRequest = { _ in launch }
            try f.move("starting", 4, run: approval.runId)
            do { _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id); XCTFail("another scope ran") }
            catch { XCTAssertEqual(error as? TeamLauncher.Failure, .voided("params_changed")) }
            XCTAssertEqual(f.runner.calls, 0)
        }
    }

    func testAnExplicitChannelAskFollowsC2AcrossSignIn() async throws {
        let f = try await fixture()
        _ = try f.service.askInChannel(f.key, channel: Self.channel, agentId: CallJSON.agent, root: Self.message, text: "Ask before signing out", context: [])
        let original = try XCTUnwrap(f.store.outbox.commands().first)
        let queue = ChatOutbox(queues: [f.store.outbox], api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna", held: true)
        queue.adoptSession("s-new", token: "test-new")
        let records = try f.store.outbox.commands()
        let carried = try XCTUnwrap(records.first { $0.sessionId == "s-new" })
        XCTAssertEqual(records.first { $0.commandId == original.commandId }?.state, .dropped)
        XCTAssertNotEqual(carried.commandId, original.commandId)
        XCTAssertEqual(carried.state, .pending)
        XCTAssertEqual(carried.sessionId, "s-new")
        XCTAssertEqual(carried.type, original.type)
        XCTAssertEqual(ChatService.args(carried), ChatService.args(original))
        XCTAssertTrue(ChatOutbox.carriedOver.contains(ChatChannelAsk.commandType))
        XCTAssertFalse(ChatOutbox.carriedOver.contains("result.publish"))
    }

    func testErasedPreviewReturnsOnlyTheMarkerAfterRejoining() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        try f.write("UPDATE requests SET text = ''")
        _ = try f.store.apply(channels: [.init(channelId: Self.channel, teamId: Self.team, name: "billing", archived: false, version: 2)])
        let erased = try XCTUnwrap(f.service.channelPreview(f.key, requestId: Self.request))
        XCTAssertTrue(erased.resultErased)
        XCTAssertNil(erased.resultText)
        XCTAssertNotNil(f.service.channelPublishProblem(f.key, requestId: Self.request))
    }

    func testChannelFailureDetailsStayOutOfEveryCommandBody() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let row = ChatRunRecord(runId: approval.runId, requestId: Self.request, approvalId: approval.id, agentId: CallJSON.agent,
                                conversationId: "c", startedAt: Date())
        XCTAssertTrue(try f.journal.consume(approval, run: row))
        try f.move("running", 5, run: row.runId)
        _ = try f.service.end(row, outcome: .failed, reason: Self.secretResult, result: Self.secretResult,
                              at: Date(), journal: f.journal, waitForState: false)
        let failed = try XCTUnwrap(f.commands().first { $0.type == "run.failed" })
        XCTAssertEqual(ChatService.args(failed)["reason"], .string("failed"))
        f.send()
        try await wait { try f.commands().allSatisfy { $0.state != .pending } }
        XCTAssertFalse(ChatStubProtocol.seen.contains { String(decoding: $0.body, as: UTF8.self).contains(Self.secretResult) })
    }

    func testChannelBranchJournalMigrationsKeepDataFromBothNumberings() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        for release in [6, 7] {
            let legacy = try DatabaseQueue()
            try ChatStoreMigrations.journal.migrate(legacy, upTo: "release-5")
            try await legacy.write { db in
                // st-c6 used 6–7 for channel identity and revocation; Y5/Y2
                // independently used those numbers for process evidence.
                try db.alter(table: "runs") { t in
                    t.add(column: "kind", .text)
                    t.add(column: "org", .text)
                    t.add(column: "channel_id", .text)
                    t.add(column: "thread_root_id", .text)
                    t.add(column: "result_erased", .boolean).notNull().defaults(to: false)
                }
                if release == 7 {
                    try db.alter(table: "runs") { t in t.add(column: "channel_revoked", .boolean).notNull().defaults(to: false) }
                    try db.create(index: "runs_conversation", on: "runs", columns: ["conversation_id"])
                }
                for number in 6...release {
                    try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["release-\(number)"])
                }
                try approval.insert(db)
                try db.execute(sql: """
                    INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at,
                                      kind, org, channel_id, thread_root_id, outcome, result_text, result_erased)
                    VALUES (?, ?, ?, ?, 'channel-conversation', ?, 'channel', ?, ?, ?, 'finished', ?, 0)
                    """, arguments: [approval.runId, Self.request, approval.id, CallJSON.agent, Date(),
                                      Self.org, Self.channel, Self.message, Self.secretResult])
                if release == 7 {
                    try db.execute(sql: "UPDATE runs SET result_erased = 1, channel_revoked = 1, result_text = NULL")
                }
            }
            try ChatStoreMigrations.journal.migrate(legacy)
            try ChatStoreMigrations.journal.migrate(legacy)
            let restored = try await legacy.read { try XCTUnwrap(ChatRunRecord.fetchOne($0)) }
            XCTAssertEqual(restored.approvalId, approval.id)
            XCTAssertEqual(restored.kind, "channel")
            XCTAssertEqual(restored.org, Self.org)
            XCTAssertEqual(restored.channelId, Self.channel)
            XCTAssertEqual(restored.threadRootId, Self.message)
            XCTAssertEqual(restored.conversationId, "channel-conversation")
            XCTAssertEqual(restored.resultText, release == 6 ? Self.secretResult : nil)
            XCTAssertEqual(restored.resultErased, release == 7)
            XCTAssertEqual(restored.channelRevoked, release == 7)
            XCTAssertNil(restored.stopConfirmedAt)
            XCTAssertNil(restored.preflightPID)
            XCTAssertNil(restored.launchFailure)
            let kept = try await legacy.read { try ChatApproval.fetchOne($0, key: approval.id) }
            XCTAssertEqual(kept?.params, approval.params)
            let versions = try await legacy.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
            XCTAssertEqual(versions, ((1...9).map { "release-\($0)" } + ["release-10-ux1", "release-11-notification-diagnostics"]).sorted())
        }
    }

    func testExistingCacheAndRunJournalUpgradeWithoutLosingTheirContents() async throws {
        let f = try await fixture()
        let approval = try await f.allow()
        let journal = try DatabaseQueue()
        try ChatStoreMigrations.journal.migrate(journal, upTo: "release-5")
        try await journal.write { db in
            try approval.insert(db)
            try db.execute(sql: """
                INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, outcome, result_text)
                VALUES (?, ?, ?, ?, 'old-conversation', ?, 'finished', ?)
                """, arguments: [approval.runId, Self.request, approval.id, CallJSON.agent, Date(), Self.secretResult])
        }
        try ChatStoreMigrations.journal.migrate(journal)
        let restored = try await journal.read { try XCTUnwrap(ChatRunRecord.fetchOne($0)) }
        XCTAssertEqual(restored.kind, "channel")
        XCTAssertEqual(restored.org, Self.org)
        XCTAssertEqual(restored.channelId, Self.channel)
        XCTAssertEqual(restored.threadRootId, Self.message)
        XCTAssertEqual(restored.agentId, CallJSON.agent)
        XCTAssertEqual(restored.conversationId, "old-conversation")
        XCTAssertEqual(restored.resultText, Self.secretResult)
        XCTAssertFalse(restored.resultErased)
        XCTAssertFalse(restored.channelRevoked)

        // Old result erasures include request cancellations. Upgrading must
        // not infer permission to delete their shared transcript.
        let legacy = try DatabaseQueue()
        try ChatStoreMigrations.journal.migrate(legacy, upTo: "release-8")
        try await legacy.write { db in
            try approval.insert(db)
            try db.execute(sql: """
                INSERT INTO runs (run_id, request_id, approval_id, agent_id, conversation_id, started_at, kind, result_erased)
                VALUES (?, ?, ?, ?, 'shared-conversation', ?, 'channel', 1)
                """, arguments: [approval.runId, Self.request, approval.id, CallJSON.agent, Date()])
        }
        try ChatStoreMigrations.journal.migrate(legacy)
        let cancelled = try await legacy.read { try XCTUnwrap(ChatRunRecord.fetchOne($0)) }
        XCTAssertTrue(cancelled.resultErased)
        XCTAssertFalse(cancelled.channelRevoked)

        let cache = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(cache, upTo: "release-8")
        try await cache.write { db in
            try db.execute(sql: "INSERT INTO agent_channels (channel_id, agent_id, name, owner_account_id, access, enabled, available) VALUES (?, ?, 'billing', ?, 'read', 1, 1)",
                           arguments: [Self.channel, CallJSON.agent, CallJSON.anna])
        }
        try ChatStoreMigrations.cache.migrate(cache)
        let kept = try await cache.read { try String.fetchOne($0, sql: "SELECT name FROM agent_channels WHERE channel_id = ?", arguments: [Self.channel]) }
        XCTAssertEqual(kept, "billing")
        let versions = try await cache.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
        XCTAssertEqual(versions, ((1...11).map { "release-\($0)" } + ["release-12-ux1", "release-13-ux1-review", "release-14-ux2-thread-read-floor", "release-15-ux2-draft-options", "release-16-conversation-read-marks", "release-17-b1", "release-18-b1-review", "release-19-chat-reply-heads", "release-20-pin-preferences", "release-21-attachments", "release-22-attachment-access", "release-23-attachment-retention", "release-24-composition-drafts"]).sorted())
    }

}


extension ChatChannelExecutionTests {
    func testAttentionRetainsOldDecisionAndPublicationBeyondCompletedHistoryLimit() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        try f.move("awaiting_decision", 1, id: "old-decision", kind: "personal")
        try f.write("UPDATE requests SET channel_id = NULL WHERE request_id = 'old-decision'")
        try f.write("UPDATE requests SET updated_at = '2020-01-01T00:00:00Z'")
        let ledger = AttentionLedger(), client = RecordingNotificationCenter()
        let manager = NotificationManager(client: client)
        ledger.delivery = manager
        let waits = ChatAttention.events(service: f.service, calls: f.calls).filter { $0.kind.needsDecision }
        XCTAssertEqual(Set(waits.map(\.kind)), [.decision, .publicationReview])
        for wait in waits { ledger.upsert(wait) }
        await manager.drain()

        try await f.store.queue.write { db in
            for index in 0..<501 {
                var body = CallJSON.request("new-outcome-\(index)", state: "failed", version: 1, onThisDevice: true)
                body["updated_at"] = ChatCallStore.timestamp(Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
                try ChatCallStore.apply(db, CallJSON.wire(body), onThisDevice: true)
            }
        }
        let projected = ChatAttention.events(service: f.service, calls: f.calls)
        XCTAssertEqual(projected.filter { !$0.kind.needsDecision }.count, 500, "only completed history is bounded")
        XCTAssertEqual(Set(projected.filter { $0.kind.needsDecision }.map(\.id)), Set(waits.map(\.id)))
        let ids = Set(projected.map(\.id))
        for source in ["request", "publication-review"] { ledger.reconcile(source: source, keeping: ids) }
        for wait in projected where wait.kind.needsDecision { ledger.upsert(wait) }
        await manager.drain()
        XCTAssertEqual(ledger.pendingCount, 2)
        XCTAssertEqual(client.delivered, Set(waits.map(\.id)), "history churn cannot revoke a live banner")
        XCTAssertEqual(client.submitted.count, 2)
    }

    func testAttentionOutcomesKeepSourceTimestampsAcrossProjection() async throws {
        let f = try await fixture()
        let sourceTime = Date(timeIntervalSince1970: 1_700_000_000)
        try await f.store.queue.write { db in
            for index in 0..<101 {
                var body = CallJSON.request("history-\(index)", state: "failed", version: 1, onThisDevice: true)
                body["updated_at"] = ChatCallStore.timestamp(sourceTime.addingTimeInterval(Double(index)))
                try ChatCallStore.apply(db, CallJSON.wire(body), onThisDevice: true)
            }
        }
        let events = ChatAttention.events(service: f.service, calls: f.calls)
        XCTAssertEqual(events.count, 101)
        XCTAssertEqual(events.first?.timestamp, sourceTime.addingTimeInterval(100))
        XCTAssertEqual(events.last?.timestamp, sourceTime)
        XCTAssertEqual(ChatAttention.events(service: f.service, calls: f.calls), events,
                       "a periodic projection must not manufacture fresh event dates")
        let ledger = AttentionLedger(), client = RecordingNotificationCenter()
        let manager = NotificationManager(client: client)
        ledger.delivery = manager
        for event in events { ledger.upsert(event) }
        await manager.drain()
        XCTAssertEqual(ledger.events.first?.id, events.first?.id)
        XCTAssertEqual(ledger.events.last?.timestamp, sourceTime.addingTimeInterval(1))
        XCTAssertEqual(client.delivered, Set(events.prefix(100).map(\.id)))
    }

    func testAttentionProjectionOffersPublicationReviewInsteadOfSuccess() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let events = ChatAttention.events(service: f.service, calls: f.calls)
        XCTAssertEqual(events.filter { $0.kind == .publicationReview }.count, 1)
        XCTAssertFalse(events.contains { $0.kind == .completion || $0.kind == .publication })
        let review = try XCTUnwrap(events.first { $0.kind == .publicationReview })
        XCTAssertEqual(review.body, "")
        XCTAssertTrue(ChatAttention.valid(review, service: f.service))
        try f.write("UPDATE requests SET publication = 'published'")
        XCTAssertFalse(ChatAttention.valid(review, service: f.service))
        XCTAssertFalse(ChatAttention.events(service: f.service, calls: f.calls).contains { $0.kind == .publication },
                       "ACK without the actual published message is not a message notification")
    }

    func testAttentionCannotRevealCachedChannelAfterRevocation() async throws {
        let f = try await fixture()
        _ = try await f.finish()
        let event = try XCTUnwrap(ChatAttention.events(service: f.service, calls: f.calls).first { $0.kind == .publicationReview })
        try f.write("UPDATE meta SET rights_in_doubt = 1")
        XCTAssertFalse(ChatAttention.valid(event, service: f.service))
        XCTAssertTrue(ChatAttention.events(service: f.service, calls: f.calls).isEmpty)
    }
}
