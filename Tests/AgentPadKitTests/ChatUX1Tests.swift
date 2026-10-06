import AgentPadHookKit
import AppKit
import Foundation
import GRDB
import Observation
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatUX1Tests: XCTestCase {
    private var root: URL!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let thread = "f5000000-0000-4000-8000-000000000002"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ux1-tests-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        for f in fixtures { f.sender?.hold(); await f.service.disconnect() }
        fixtures = []
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture() async throws -> ChatChannelExecutionTests.Fixture {
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent(UUID().uuidString))
        fixtures.append(f)
        f.calls.sessionFilesRoot = f.service.claudeProjectsRoot
        f.service.serverCapabilities[f.key.server] = ["chat.channel_ux1", "chat.session_tools"]
        f.service.isServerKnown = { _, _ in true }
        try f.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
        return f
    }
    private func card(_ f: ChatChannelExecutionTests.Fixture) throws -> ChatChannelAgent { try XCTUnwrap(f.store.channelAgents(channel).first) }
    private func model(_ f: ChatChannelExecutionTests.Fixture) -> ChatChannelModel {
        let m = ChatChannelModel(key: f.key, channel: channel); m.service = f.service; m.follow(f.store); return m
    }
    private func send(_ f: ChatChannelExecutionTests.Fixture, text: String = "@billing@anna why?", root: String? = nil,
                      mentionOnly: Bool = false) throws -> (message: String, request: String?, version: String) {
        let m = model(f); m.saveDraft(text, root: root)
        let version = try XCTUnwrap(m.draftVersion(root: root))
        let id = try f.service.sendChannel(f.key, channel: channel, root: root, text: text, mentions: [], agents: [card(f)],
            draftVersion: version, mentionOnly: mentionOnly)
        let request = try f.store.queue.read { try String.fetchOne($0, sql: "SELECT request_id FROM channel_call_intents WHERE message_id = ?", arguments: [id]) }
        return (id, request, version)
    }
    private func acknowledge(_ f: ChatChannelExecutionTests.Fixture) throws {
        try f.write("UPDATE outbox SET state = 'sent', sent_generation = 'g1' WHERE type = 'message.post'")
    }
    private func receive(_ f: ChatChannelExecutionTests.Fixture, request: String, initiator: String? = nil, state: String = "awaiting_decision") throws -> ChatRequest {
        let command = try XCTUnwrap(f.store.outbox.commands().first { ChatService.args($0)["request_id"]?.string == request })
        let args = ChatService.args(command)
        var body = CallJSON.request(request, state: state, version: 2, onThisDevice: true)
        body["kind"] = "channel"; body["agent_id"] = CallJSON.agent
        body["initiator_account_id"] = initiator ?? f.key.accountId
        body["channel_id"] = channel; body["thread_root_id"] = args["thread_root_id"]?.string ?? args["source_message_id"]?.string
        body["source_message_id"] = args["source_message_id"]?.string
        if case .number(let revision)? = args["source_revision"] { body["source_revision"] = Int(revision) }
        body["reply_mode"] = args["reply_mode"]?.string; body["requested_policy_id"] = args["requested_policy_id"]?.string
        body["text"] = args["text"]?.string; body["deliver_by"] = args["deliver_by"]?.string
        try f.store.queue.write { try ChatCallStore.apply($0, CallJSON.wire(body), onThisDevice: true) }
        return try XCTUnwrap(f.store.calls.request(request))
    }
    private func verified(_ f: ChatChannelExecutionTests.Fixture, request: ChatRequest, context: [ChatChannelContent.Message]? = nil) throws -> ChatChannelContent {
        let a = try f.journal.channelAuthority(request.requestId)
        let content = ChatChannelContent(requestId: request.requestId, text: request.text ?? "", context: context ?? a?.context)
        let bytes = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        try f.write("""
            INSERT OR REPLACE INTO request_contents (request_id, channel_id, session_id, generation, epoch, content)
            VALUES (?, ?, 's-anna', 'g1', (SELECT channel_access_epoch FROM meta WHERE id = 1), ?)
            """, [request.requestId, channel, bytes])
        return content
    }
    private func caller(_ suffix: Int32 = 1, surface: UUID = UUID(), name: String = "Tab") -> ChatLocalCaller {
        .init(surface: surface.uuidString.lowercased(), claudePID: 100 + suffix, claudeStart: UInt64(1000 + suffix), signature: name)
    }

    private func scalar(_ queue: DatabaseQueue, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
        try queue.read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
    }

    private func wait(_ predicate: () throws -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while try !predicate() {
            if ContinuousClock.now > limit { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func message(_ f: ChatChannelExecutionTests.Fixture, id: String, text: String = "Question", revision: Int = 1,
                         root: String? = nil, attributes: [String: String] = [:]) throws -> ChatMessageWire {
        var body: [String: Any] = ["message_id": id, "channel_id": channel, "author_account_id": f.key.accountId,
            "text": text, "revision": revision, "seq": 1, "created_at": "2026-10-06T10:00:00Z", "mentions": []]
        body["thread_root_id"] = root
        for (key, value) in attributes { body[key] = value }
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        try f.store.queue.write { _ = try ChatMessages.write($0, wire) }
        return wire
    }

    private func automaticRun(_ f: ChatChannelExecutionTests.Fixture) async throws -> ChatApproval {
        let sent = try send(f); try acknowledge(f)
        let request = try receive(f, request: XCTUnwrap(sent.request)); _ = try verified(f, request: request)
        _ = await f.owner.perform(.notifyDecision, request: request, key: f.key)
        let approval = try XCTUnwrap(f.journal.approval(f.key, requestId: request.requestId))
        try f.write("UPDATE requests SET state = 'starting', version = 4, run_id = ?, decision_basis = 'self_call' WHERE request_id = ?", [approval.runId, request.requestId])
        _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
        XCTAssertNotNil(try f.journal.run(approval.runId)?.outcome)
        try f.write("UPDATE requests SET state = 'finished', version = 7, publication = 'awaiting_publish' WHERE request_id = ?", [request.requestId])
        return approval
    }

    func testMentionsIgnoreMailCodeQuotesAndPartialAddressesDeduplicate() async throws {
        let f = try await fixture(), agent = try card(f)
        for text in ["x@billing@anna", "`@billing@anna`", "```swift\n@billing@anna\n```", "> @billing@anna", "\"@billing@anna\"", "«@billing@anna»", "@billing@ann", "@billing@anna-x", "@billing@anna@x", "    @billing@anna", "'@billing@anna'", "\\@billing@anna", "@billing@anna.example"] {
            XCTAssertTrue(ChatMentions.agents(in: text, agents: [agent]).isEmpty, text)
        }
        XCTAssertEqual(ChatMentions.agents(in: "@BILLING@ANNA @billing@anna", agents: [agent, agent]).map(\.agentId), [agent.agentId])
    }

    func testMarkdownCodeAndLazyQuotesNeverCreateCallsOrConsentThroughSend() async throws {
        let f = try await fixture()
        let samples = ["``@billing@anna``", "```@billing@anna```", "``code ` @billing@anna``",
            "``line\n@billing@anna``", "````swift\n```\n@billing@anna\n````",
            "~~~~~\n~~~\n@billing@anna\n~~~~~", "    @billing@anna", "\t@billing@anna",
            "> quoted paragraph\n@billing@anna", "> first\n> continuation\n@billing@anna",
            "> - quoted list\n@billing@anna", "> > nested quote\n@billing@anna",
            "- ``@billing@anna``", "| code |\n|---|\n| ``@billing@anna`` |",
            "- ```\n  @billing@anna\n  ```", "1. ````swift\n   ```\n   @billing@anna\n   ````"]
        for text in samples { XCTAssertNil(try send(f, text: text).request, text) }
        XCTAssertEqual(try scalar(f.journal.queue, "SELECT COUNT(*) FROM channel_authorities"), 0)
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "request.create_in_channel_v2" }.count, 0)
        XCTAssertNotNil(try send(f, text: "> quote\n\n@billing@anna outside").request)
        XCTAssertNotNil(try send(f, text: "``code`` **@billing@anna**").request)
    }

    func testNestedListQuotesAndMultilineCodeNeverCreateCallsThroughSend() async throws {
        let f = try await fixture()
        let samples = [
            "- > @billing@anna", "1. > @billing@anna", "- [ ] > @billing@anna",
            "- outer\n  - > @billing@anna", "1. outer\n   2. > > @billing@anna",
            "- - > @billing@anna", "- > quote\n  > @billing@anna", "- > quote\n  @billing@anna",
            "- > quote\n@billing@anna", "- outer\n  > @billing@anna",
            "- `code\n  @billing@anna`", "- ``code\n  @billing@anna``",
            "1. outer\n   - ``code\n     @billing@anna``", "- ``code\n@billing@anna``",
            "- outer\n\n      @billing@anna", "- outer\n  - ~~~\n    @billing@anna\n    ~~~"
        ]
        for text in samples { XCTAssertNil(try send(f, text: text).request, text) }
        XCTAssertEqual(try scalar(f.journal.queue, "SELECT COUNT(*) FROM channel_authorities"), 0)
        XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "request.create_in_channel_v2" })
        for text in ["- > quote\n- @billing@anna", "- `code\n  ends` @billing@anna", "- > quote\n\n@billing@anna"] {
            XCTAssertNotNil(try send(f, text: text).request, text)
        }
        XCTAssertTrue(MarkdownRenderer.html("- > quoted", mode: .chat).contains("<blockquote>"))
    }

    func testEverySavedAgentChangeRevokesTrustBeforeReconcileAndNeverRestoresIt() async throws {
        let changes: [(String, (inout TeamPublishedAgent) -> Void)] = [
            ("maxTurns", { $0.maxTurns += 1 }), ("timeout", { $0.timeoutMinutes += 1 }),
            ("budget", { $0.maxBudgetUSD = 1 }), ("model", { $0.model = "sonnet" }),
            ("profile", { $0.access = .editFiles }), ("folders", { $0.extraFolders = [self.root.path] }),
            ("folder", { $0.folder = self.root.path }), ("rules", { $0.deniedPaths.append("private/**") }),
            ("commands", { $0.allowedCommands = ["swift test"] }), ("enabled", { $0.enabled = false }),
            ("name", { $0.name = "renamed" }), ("description", { $0.description = "changed" }),
            ("audience", { $0.audience = ["someone"] })
        ]
        for (name, change) in changes {
            let f = try await fixture(), channel = channel
            f.service.localAgent = { [weak calls = f.calls] id in calls?.agents.first { $0.id.uuidString.lowercased() == id } }
            let original = try XCTUnwrap(f.calls.agents.first)
            try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
            let policy = try XCTUnwrap(f.store.outbox.commands().first.flatMap { ChatService.args($0)["policy_id"]?.string })
            try await f.store.queue.write { try ChatChannelAgents.writeTrust($0, channel: channel, agent: CallJSON.agent,
                trust: .init(enabled: true, policyId: policy, executorSessionId: "s-anna")) }
            try await f.calls.save(original)
            XCTAssertNotNil(try f.journal.channelAuthority(policy), "unchanged save: \(name)")
            var edited = original; change(&edited)
            try await f.calls.save(edited)
            XCTAssertNil(try f.journal.channelAuthority(policy), name)
            let commands = try f.journal.commands(for: f.key).filter { $0.type == "agent.channel_trust.set" }
            XCTAssertEqual(commands.count, 1, name)
            XCTAssertEqual(commands.first.map(ChatService.args)?["expected_policy_id"]?.string, policy, name)
            XCTAssertEqual(commands.first.map(ChatService.args)?["enabled"], .bool(false), name)
            XCTAssertEqual(commands.first?.state, .pending, "offline revoke must be queued: \(name)")
            try await f.calls.save(original)
            let reopened = try ChatJournal.open(files: f.service.files)
            XCTAssertNil(try reopened.channelAuthority(policy), "returning settings / reopening must not restore \(name)")
        }
    }

    func testSaveAndPublishRevokesEvenWhenOnlyLocalLimitChanges() async throws {
        let f = try await fixture()
        f.calls.publishing = f.service
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
        let policy = try XCTUnwrap(f.store.outbox.commands().first.flatMap { ChatService.args($0)["policy_id"]?.string })
        var edited = f.agent; edited.maxTurns += 1
        try await f.calls.saveAndPublish([edited], teams: ["f5000000-0000-4000-8000-000000000004"], key: f.key)
        XCTAssertNil(try f.journal.channelAuthority(policy))
        XCTAssertTrue(try f.journal.commands(for: f.key).contains { ChatService.args($0)["expected_policy_id"]?.string == policy })
    }

    func testRevocationFailurePreventsWritingAgentSettings() async throws {
        let f = try await fixture()
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
        try await f.journal.queue.write { try $0.execute(sql: """
            CREATE TRIGGER refuse_revocation BEFORE UPDATE ON channel_authorities
            BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END
            """) }
        let old = f.calls.agents
        var edited = f.agent; edited.maxTurns += 1
        do { try await f.calls.save(edited); XCTFail("settings cannot change without durable revocation") } catch {}
        XCTAssertEqual(f.calls.agents, old)
        try f.calls.load()
        XCTAssertEqual(f.calls.agents, old)
        XCTAssertTrue(try f.journal.commands(for: f.key).isEmpty)
    }

    func testDisconnectedSaveRevokesAllStoredScopesAndQueuesTheirServerCommands() async throws {
        let f = try await fixture()
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
        let policy = try XCTUnwrap(f.store.outbox.commands().first.flatMap { ChatService.args($0)["policy_id"]?.string })
        var other = try XCTUnwrap(f.journal.channelAuthority(policy))
        other.id = UUID().uuidString.lowercased(); other.org = UUID().uuidString.lowercased()
        other.channel = UUID().uuidString.lowercased()
        try f.journal.storeAuthority(other)
        let otherKey = ChatOrgKey(server: f.key.server, accountId: f.key.accountId, orgId: other.org)
        await f.service.disconnect()
        XCTAssertNotNil(try f.journal.channelAuthority(policy))
        XCTAssertNotNil(try f.journal.channelAuthority(other.id))
        var edited = f.agent; edited.maxTurns += 1
        try await f.calls.save(edited)
        XCTAssertNil(try f.journal.channelAuthority(policy))
        XCTAssertNil(try f.journal.channelAuthority(other.id))
        for (key, id) in [(f.key, policy), (otherKey, other.id)] {
            XCTAssertTrue(try f.journal.commands(for: key).contains { $0.state == .pending && ChatService.args($0)["expected_policy_id"]?.string == id })
        }
    }

    func testPendingTrustAndSelfConsentAreRevokedBySaveAndRemoval() async throws {
        for remove in [false, true] {
            let f = try await fixture()
            try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
            let policy = try XCTUnwrap(f.store.outbox.commands().first.flatMap { ChatService.args($0)["policy_id"]?.string })
            let own = try XCTUnwrap(send(f).request)
            if remove { try f.calls.removeUnpublished(f.agent.id) }
            else { var edited = f.agent; edited.maxTurns += 1; try await f.calls.save(edited) }
            XCTAssertNil(try f.journal.channelAuthority(policy))
            XCTAssertNil(try f.journal.channelAuthority(own))
            let revoke = try XCTUnwrap(f.journal.commands(for: f.key).first { $0.type == "agent.channel_trust.set" })
            XCTAssertEqual(ChatService.args(revoke)["expected_policy_id"]?.string, policy)
            XCTAssertGreaterThan(revoke.seq, try XCTUnwrap(f.store.outbox.commands().first?.seq))
        }
    }

    func testFinishedEventAndACKBothOrdersPublishWithoutAnotherCacheChange() async throws {
        for eventFirst in [true, false] {
            let f = try await fixture(), approval = try await automaticRun(f)
            try f.write("UPDATE requests SET state = 'running', publication = NULL WHERE request_id = ?", [approval.requestId])
            try f.write("UPDATE outbox SET state = 'sent', sent_generation = 'g1'")
            try await f.journal.queue.write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type <> 'run.finished'") }
            ChatNotifications.follow(f.service, session: try XCTUnwrap(f.service.orgSessions[f.key]))
            let gate = Gate(); gate.close(); defer { gate.open() }
            ChatStubProtocol.reset { _, data in
                if (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: data))?.type == "run.finished" { gate.pass() }
                return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
            }
            f.send()
            try await wait { ChatStubProtocol.seen.contains { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body))?.type == "run.finished" } }
            if eventFirst {
                try f.write("UPDATE requests SET state = 'finished', publication = 'awaiting_publish' WHERE request_id = ?", [approval.requestId])
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "result.publish" })
            }
            gate.open()
            try await wait { try f.journal.commands(for: f.key).contains { $0.type == "run.finished" && $0.state == .sent } }
            if !eventFirst {
                XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "result.publish" })
                try f.write("UPDATE requests SET state = 'finished', publication = 'awaiting_publish' WHERE request_id = ?", [approval.requestId])
            }
            try await wait { try f.store.outbox.commands().contains { $0.type == "result.publish" } }
            let posts = try f.store.outbox.commands().filter { $0.type == "result.publish" }
            XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(posts.first.map(ChatService.args)?["run_id"]?.string, approval.runId)
            f.sender?.hold()
        }
    }

    func testAutomaticResultOffersManualPublishAndWithholdAfterNewLogin() async throws {
        for publish in [true, false] {
            let f = try await fixture(), approval = try await automaticRun(f)
            let owner = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
            XCTAssertTrue(owner.isAutomatic(try XCTUnwrap(f.store.calls.request(approval.requestId))))
            let previous = try f.service.publishChannelResult(f.key, requestId: approval.requestId, publish: true, automatic: true)
            // Model the rejected 401 attempt and the normal outbox session adoption.
            try f.write("UPDATE outbox SET state = 'unconfirmed', error = 'unauthorized' WHERE command_id = ?", [previous.commandId])
            XCTAssertFalse(owner.isAutomatic(try XCTUnwrap(f.store.calls.request(approval.requestId))))
            let queue = ChatOutbox(queues: [f.store.outbox, f.journal.runCommands(f.key)], api: f.service.makeAPI(f.key.server), token: "test-only", sessionId: "s-anna", held: true)
            queue.adoptSession("s-new", token: "test-new")
            var connection = try XCTUnwrap(f.service.connection); connection.sessionId = "s-new"
            try f.service.saveSignIn(connection, token: "test-new")
            try f.write("UPDATE meta SET rights_session = 's-new', rights_in_doubt = 0")
            f.service.reconcileChannelResults()
            let request = try XCTUnwrap(owner.requests.first { $0.requestId == approval.requestId })
            XCTAssertFalse(owner.isAutomatic(request))
            XCTAssertNotNil(owner.publicationText(request.requestId))
            XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "result.publish" && $0.sessionId == "s-new" })
            let decision = try f.service.publishChannelResult(f.key, requestId: request.requestId, publish: publish)
            XCTAssertEqual(decision.type, publish ? "result.publish" : "result.withhold")
            XCTAssertEqual(decision.sessionId, "s-new")
            XCTAssertEqual(ChatService.args(decision)["run_id"]?.string, approval.runId)
            f.service.reconcileChannelResults()
            XCTAssertEqual(try f.store.outbox.commands().first { $0.commandId == decision.commandId }?.state, .pending,
                           "old automatic consent must not cancel the new manual decision")
        }
    }

    func testExplicitDecisionSupersedesAutomaticConsentInTheSameLogin() async throws {
        for publish in [true, false] {
            let f = try await fixture(), approval = try await automaticRun(f)
            let automatic = try f.service.publishChannelResult(f.key, requestId: approval.requestId, publish: true, automatic: true)
            if !publish { try f.write("UPDATE outbox SET state = 'failed' WHERE command_id = ?", [automatic.commandId]) }
            let manual = try f.service.publishChannelResult(f.key, requestId: approval.requestId, publish: publish)
            if publish { XCTAssertEqual(manual.commandId, automatic.commandId, "explicit confirmation keeps the same attempt") }
            let automaticOrigin = try await f.store.queue.read { try ChatPublication.isAutomatic($0, command: manual.commandId) }
            XCTAssertFalse(automaticOrigin)
            let owner = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
            XCTAssertFalse(owner.isAutomatic(try XCTUnwrap(f.store.calls.request(approval.requestId))))
            f.agent.maxTurns += 1
            f.service.reconcileChannelResults()
            f.service.reconcileChannelResults()
            XCTAssertEqual(try f.store.outbox.commands().first { $0.commandId == manual.commandId }?.state, .pending)
            XCTAssertFalse(owner.isAutomatic(try XCTUnwrap(f.store.calls.request(approval.requestId))))
        }
    }

    func testPublicationOriginUpgradeDoesNotInventManualConsent() throws {
        let queue = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(queue, upTo: "release-12-ux1")
        try queue.write { try $0.execute(sql: "INSERT INTO publication_intents (run_id, command_id) VALUES ('run', 'old')") }
        try ChatStoreMigrations.cache.migrate(queue)
        XCTAssertTrue(try queue.read { try ChatPublication.isAutomatic($0, command: "old") })
    }

    func testClosedMCPSocketDuringPreflightCannotQueueAPostFromALiveProcess() async throws {
        let f = try await fixture(), gate = Gate(); gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { _, _ in gate.pass(); return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
        var waiting = true
        let task = Task { try await ChatSessionTools.call(.object(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "channel_id": .string(channel), "text": .string("late post")]), caller: caller(), service: f.service,
            isCallerWaiting: { waiting }, revalidate: { true }) }
        try await wait { !ChatStubProtocol.seen.isEmpty }
        waiting = false
        gate.open()
        do { _ = try await task.value; XCTFail("closed socket must cancel preflight") }
        catch let error as ChatSessionTools.Failure { XCTAssertEqual(error.code, "not_found") }
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertEqual(try scalar(f.store.queue, "SELECT COUNT(*) FROM session_posts"), 0)
    }

    private final class MCPOutput: @unchecked Sendable {
        let lock = NSLock()
        var lines: [[String: Any]] = []
        func append(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.withLock { lines.append(object) }
        }
        var notices: [String] { lock.withLock {
            lines.filter { $0["method"] as? String == "notifications/message" }
                .compactMap { ($0["params"] as? [String: Any])?["data"] as? String }
        } }
        func response(_ id: Int) -> [String: Any]? { lock.withLock { lines.first { $0["id"] as? Int == id } } }
    }

    func testMCPCancelClosesIPCDuringPreflightAndReportsQueuedPostForExactRetry() async throws {
        for beforeQueue in [true, false] {
            let f = try await fixture(), output = MCPOutput(), caller = caller()
            let gate = Gate(); if beforeQueue { gate.close() }; defer { gate.open() }
            ChatStubProtocol.reset { _, _ in gate.pass(); return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
            let path = NSTemporaryDirectory() + "ux1-mcp-\(UUID().uuidString.prefix(8)).sock"
            let hook = HookServer(socketPath: path) { _ in }
            defer { hook.stop(); try? FileManager.default.removeItem(atPath: path) }
            var socketWaiting: (@MainActor () -> Bool)?
            var completed = 0
            hook.onCLIRequest = { request, _, waiting, completion in
                socketWaiting = waiting
                Task {
                    do {
                        let json = try JSONDecoder().decode(ChatJSON.self, from: Data(request.chatArguments!.utf8))
                        let result = try await ChatSessionTools.call(json, caller: caller, service: f.service,
                            isCallerWaiting: waiting, revalidate: { true })
                        var response = AgentPadCLIResponse(ok: true)
                        response.chatResult = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                        completion(response)
                    } catch { completion(ChatSessionTools.failure("interrupted")) }
                    completed += 1
                }
            }
            hook.start()
            try await wait { FileManager.default.fileExists(atPath: path) }
            let mcp = AgentPadTeamMCPServer(cwd: root.path, version: "test", send: { request, timeout, cancellation in
                guard let line = request.encodedLine(),
                      case .success(let data) = AgentPadCLITransport.roundTrip(line: line, socketPath: path, timeout: timeout, cancellation: cancellation),
                      let response = AgentPadCLIResponse.decode(from: data) else { return .failure(.init("IPC interrupted")) }
                return .success(response)
            }, write: { output.append($0) })
            func rpc(_ body: [String: Any]) throws { mcp.handle(line: try JSONSerialization.data(withJSONObject: body)) }
            try rpc(["id": 1, "method": "initialize"])
            var args: [String: Any] = ["org_id": f.key.orgId, "channel_id": channel, "text": "cancelled post"]
            try rpc(["id": 2, "method": "tools/call", "params": ["name": "chat_post", "arguments": args]])
            try await wait { !ChatStubProtocol.seen.isEmpty }
            if !beforeQueue { try await wait { try self.scalar(f.store.queue, "SELECT COUNT(*) FROM session_posts") == 1 } }
            try rpc(["method": "notifications/cancelled", "params": ["requestId": 2]])
            try await wait { socketWaiting?() == false }
            try await wait { !output.notices.isEmpty }
            XCTAssertNil(output.response(2))
            let notice = try XCTUnwrap(output.notices.first)
            XCTAssertTrue(notice.contains("message_id:"), notice)
            XCTAssertTrue(notice.contains("unknown"), notice)
            XCTAssertFalse(notice.contains("cancelled post"), "message text is not logged")
            gate.open()
            try await wait { completed == 1 }
            let count = try scalar(f.store.queue, "SELECT COUNT(*) FROM session_posts")
            XCTAssertEqual(count, beforeQueue ? 0 : 1)
            if !beforeQueue {
                let storedID = try await f.store.queue.read { try String.fetchOne($0, sql: "SELECT message_id FROM session_posts") }
                let id = try XCTUnwrap(storedID)
                XCTAssertTrue(notice.contains(id), notice)
                args["message_id"] = id
                try rpc(["id": 3, "method": "tools/call", "params": ["name": "chat_post", "arguments": args]])
                try await wait { output.response(3) != nil }
                let result = output.response(3)?["result"] as? [String: Any]
                let status = result?["structuredContent"] as? [String: Any]
                XCTAssertEqual(status?["message_id"] as? String, id)
                XCTAssertEqual(status?["status"] as? String, "pending")
                XCTAssertEqual(try scalar(f.store.queue, "SELECT COUNT(*) FROM session_posts"), 1)
                XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "message.post_from_session" }.count, 1)
            }
        }
    }

    func testMentionPopupUsesCaretNamesAndCanonicalAddress() {
        XCTAssertNil(ChatMentionCandidate.token("mail@domain", caret: 11))
        let token = ChatMentionCandidate.token("Hi @billing@an rest", caret: 14)
        XCTAssertEqual(token?.query, "billing@an")
        XCTAssertEqual(token?.range, NSRange(location: 3, length: 11))
        let candidates = [ChatMentionCandidate(id: "a", address: "billing@anna", label: "Payments", addToChannel: true)]
        XCTAssertEqual(ChatMentionCandidate.filtered(candidates, query: "pay"), candidates)
        XCTAssertEqual(ChatMentionCandidate.filtered(candidates, query: "@anna"), candidates)
    }

    func testDraftAttemptIsAtomicSharedAndNewIdenticalDraftIsAllowed() async throws {
        let f = try await fixture(), a = model(f), b = model(f)
        a.saveDraft("@billing@anna why?", root: nil)
        let version = try XCTUnwrap(a.draftVersion(root: nil))
        b.saveDraft("@billing@anna why?", root: nil)
        XCTAssertEqual(b.draftVersion(root: nil), version)
        let first = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "@billing@anna why?", mentions: [], agents: [card(f)], draftVersion: version, mentionOnly: false)
        let again = try f.service.sendChannel(f.key, channel: channel, root: nil, text: "@billing@anna why?", mentions: [], agents: [card(f)], draftVersion: version, mentionOnly: false)
        XCTAssertEqual(first, again)
        XCTAssertEqual(try f.store.outbox.commands().count, 2)
        XCTAssertEqual(a.draft(root: nil), "")
        let next = try send(f)
        XCTAssertNotEqual(first, next.message)
        XCTAssertEqual(try f.store.outbox.commands().count, 4)
    }

    func testChangedDraftRejectsOldWindowWithoutQueueing() async throws {
        let f = try await fixture(), m = model(f)
        m.saveDraft("one", root: nil); let version = try XCTUnwrap(m.draftVersion(root: nil)); m.saveDraft("two", root: nil)
        XCTAssertThrowsError(try f.service.sendChannel(f.key, channel: channel, root: nil, text: "one", mentions: [], agents: [], draftVersion: version, mentionOnly: false))
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertEqual(m.draft(root: nil), "two")
    }

    func testCallDependsOnMessageACKAndHasFixedSourceRoute() async throws {
        let f = try await fixture(), sent = try send(f)
        let commands = try f.store.outbox.commands()
        let post = try XCTUnwrap(commands.first { $0.type == "message.post" }), call = try XCTUnwrap(commands.first { $0.type == "request.create_in_channel_v2" })
        XCTAssertEqual(call.dependsOn, post.commandId)
        XCTAssertEqual(ChatService.args(call)["source_message_id"]?.string, sent.message)
        XCTAssertEqual(ChatService.args(call)["reply_mode"]?.string, "channel")
        XCTAssertNil(ChatService.args(call)["thread_root_id"])
        let request = try receive(f, request: XCTUnwrap(sent.request))
        let content = try verified(f, request: request)
        XCTAssertNil(f.service.automaticAuthority(f.key, request: request, content: content), "server event cannot supply consent's send ACK")
        try acknowledge(f)
        XCTAssertNotNil(f.service.automaticAuthority(f.key, request: request, content: content))
    }

    func testMentionOnlyDoesNotCreateAnIntentOrConsent() async throws {
        let f = try await fixture(), sent = try send(f, mentionOnly: true)
        XCTAssertNil(sent.request)
        XCTAssertEqual(try f.store.outbox.commands().map(\.type), ["message.post"])
        XCTAssertEqual(try scalar(f.journal.queue, "SELECT COUNT(*) FROM channel_authorities"), 0)
    }

    func testLocalCancelLeavesQuestionAndBlocksIntentBeforeSend() async throws {
        let f = try await fixture(), sent = try send(f), request = try XCTUnwrap(sent.request)
        XCTAssertNil(f.service.cancelChannelIntent(f.key, request: request))
        XCTAssertEqual(try scalar(f.store.queue, "SELECT COUNT(*) FROM messages WHERE message_id = ?", [sent.message]), 1)
        XCTAssertNil(try f.journal.channelAuthority(request))
        XCTAssertEqual(try f.store.outbox.commands().first { $0.type == "request.create_in_channel_v2" }?.state, .dropped)
    }

    func testCancelInFlightWaitsForCreateAndKeepsItsBytes() async throws {
        let f = try await fixture(), sent = try send(f), request = try XCTUnwrap(sent.request)
        let call = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "request.create_in_channel_v2" })
        XCTAssertNotNil(try f.store.outbox.beginSending(call))
        XCTAssertNil(f.service.cancelChannelIntent(f.key, request: request))
        let kept = try f.store.outbox.commands()
        XCTAssertEqual(kept.first { $0.commandId == call.commandId }?.bodyBytes, call.bodyBytes)
        XCTAssertEqual(kept.first { $0.commandId == call.commandId }?.state, .pending)
        XCTAssertEqual(kept.first { $0.type == "request.cancel" }?.dependsOn, call.commandId)
    }

    func testSelfConsentMaterializesOneOrdinaryD9ApprovalWithoutAllow() async throws {
        let f = try await fixture(), sent = try send(f)
        try acknowledge(f)
        let request = try receive(f, request: XCTUnwrap(sent.request)); _ = try verified(f, request: request)
        _ = await f.owner.perform(.notifyDecision, request: request, key: f.key)
        let first = try XCTUnwrap(f.journal.approval(f.key, requestId: request.requestId))
        let params = try TeamLaunchParams.decode(first.params)
        XCTAssertEqual(params.consentBasis, "self_call"); XCTAssertEqual(params.consentReference, request.requestId)
        XCTAssertEqual(params.inputs.sourceMessageId, sent.message); XCTAssertEqual(params.inputs.replyMode, "channel")
        XCTAssertEqual(params.inputs.thread, "channel:\(channel):\(sent.message)")
        XCTAssertEqual(params.inputs.termsVersion, 2)
        _ = await f.owner.perform(.notifyDecision, request: request, key: f.key)
        XCTAssertEqual(try f.journal.approval(f.key, requestId: request.requestId)?.id, first.id)
        XCTAssertEqual(try f.journal.commands(for: f.key).filter { $0.type == "request.decide_automatic" }.count, 1)
    }

    func testSelfEqualityOnServerWithoutLocalSendNeverAuthorizes() async throws {
        let f = try await fixture(), sent = try send(f)
        try acknowledge(f)
        let request = try receive(f, request: XCTUnwrap(sent.request)), content = try verified(f, request: request)
        try f.write("DELETE FROM channel_sends")
        XCTAssertNil(f.service.automaticAuthority(f.key, request: request, content: content))
        _ = await f.owner.perform(.notifyDecision, request: request, key: f.key)
        XCTAssertNil(try f.journal.approval(f.key, requestId: request.requestId))
    }

    func testContentAuthorRevisionTextAndRouteAreAllBoundToSelfConsent() async throws {
        let f = try await fixture(), sent = try send(f)
        try acknowledge(f)
        let request = try receive(f, request: XCTUnwrap(sent.request)), good = try verified(f, request: request)
        for mutate in [0, 1, 2, 3, 4, 5, 6] {
            var content = good, changed = request
            switch mutate {
            case 0: content.context?[0].authorAccountId = CallJSON.boris
            case 1: content.context?[0].revision += 1
            case 2: content.context?[0].text = "changed"
            case 3: changed.replyMode = "thread"
            case 4: changed.threadRootId = thread
            case 5: changed.sourceMessageId = thread
            default: changed.initiatorAccountId = CallJSON.boris
            }
            XCTAssertNil(f.service.automaticAuthority(f.key, request: changed, content: content), "mutation \(mutate)")
        }
    }

    func testSettingsChangePermanentlyRevokesAuthorityEvenAfterReverting() async throws {
        let f = try await fixture(), sent = try send(f)
        try acknowledge(f)
        let request = try receive(f, request: XCTUnwrap(sent.request)), content = try verified(f, request: request)
        let old = f.agent
        f.agent.maxTurns += 1
        f.service.invalidateChannelAuthorities(f.key)
        f.agent = old
        XCTAssertNil(f.service.automaticAuthority(f.key, request: request, content: content))
    }

    func testAnotherExecutorMacCannotRecordSelfConsentOrEnableTrust() async throws {
        let f = try await fixture()
        try f.write("UPDATE agent_channels SET executor_session_id = 'another-mac'")
        let sent = try send(f)
        XCTAssertNil(try f.journal.channelAuthority(XCTUnwrap(sent.request)))
        XCTAssertThrowsError(try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true))
    }

    func testTrustRequiresLocalAndPublicPolicyAndDoesNotApproveOldRequests() async throws {
        let f = try await fixture()
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
        let command = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "agent.channel_trust.set" })
        let policy = try XCTUnwrap(ChatService.args(command)["policy_id"]?.string)
        let old = try send(f)
        try f.journal.revokeAuthority(XCTUnwrap(old.request))
        let request = try receive(f, request: XCTUnwrap(old.request), initiator: CallJSON.boris)
        let content = ChatChannelContent(requestId: request.requestId, text: request.text ?? "", context: [])
        XCTAssertNil(f.service.automaticAuthority(f.key, request: request, content: content))
        var current = request; current.requestedPolicyId = policy
        XCTAssertNil(f.service.automaticAuthority(f.key, request: current, content: content), "local policy needs public ACK")
        let trust = ChatChannelTrust(enabled: true, policyId: policy, executorSessionId: "s-anna", executorDeviceName: "Mac", access: "read")
        let channel = channel
        try await f.store.queue.write { try ChatChannelAgents.writeTrust($0, channel: channel, agent: CallJSON.agent, trust: trust) }
        XCTAssertNil(f.service.automaticAuthority(f.key, request: request, content: content), "no retroactive policy")
        XCTAssertEqual(f.service.automaticAuthority(f.key, request: current, content: content)?.basis, "channel_trust")
        try f.journal.revokeAuthority(policy)
        XCTAssertNil(f.service.automaticAuthority(f.key, request: current, content: content), "snapshot alone cannot rebuild trust")
    }

    func testShellCannotEnableTrustAndDisablingRevokesBeforeNetwork() async throws {
        let f = try await fixture()
        f.agent.access = .readGit; try f.write("UPDATE agent_channels SET access = 'read-git'")
        XCTAssertThrowsError(try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true))
        f.agent.access = .read; try f.write("UPDATE agent_channels SET access = 'read'")
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: true)
        let id = try XCTUnwrap(f.store.outbox.commands().first.flatMap { ChatService.args($0)["policy_id"]?.string })
        let trust = ChatChannelTrust(enabled: true, policyId: id, executorSessionId: "s-anna")
        let channel = channel
        try await f.store.queue.write { try ChatChannelAgents.writeTrust($0, channel: channel, agent: CallJSON.agent, trust: trust) }
        try f.service.setChannelTrust(f.key, channel: channel, agent: card(f), enabled: false)
        XCTAssertNil(try f.journal.channelAuthority(id))
        XCTAssertEqual(try f.store.outbox.commands().last.map(ChatService.args)?["enabled"], .bool(false))
    }

    func testPIDIdentityMustBeUniqueLiveClaudeAncestorOnTheTab() {
        let surface = UUID()
        let rows: [SessionProcessScanner.Raw] = [
            .init(pid: 10, ppid: 1, name: "zsh", isForeground: false, startedAtUs: 100),
            .init(pid: 11, ppid: 10, name: "claude", isForeground: true, startedAtUs: 110),
            .init(pid: 12, ppid: 11, name: "agentpad-cli", isForeground: true, startedAtUs: 120)]
        let tab = ChatSessionIdentity.Tab(id: surface, customTitle: "Mine", folderName: "project", processes: rows)
        XCTAssertEqual(ChatSessionIdentity.resolve(pid: 12, startedAt: 120, tabs: [tab], identity: { _, _ in true }, signatureVerifier: { $0 == 11 })?.surface, surface.uuidString.lowercased())
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 12, startedAt: 121, tabs: [tab], identity: { _, _ in true }, signatureVerifier: { $0 == 11 }), "reused PID")
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 12, startedAt: 120, tabs: [tab], identity: { _, _ in false }, signatureVerifier: { $0 == 11 }), "ended process")
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 12, startedAt: 120, tabs: [tab, tab], identity: { _, _ in true }, signatureVerifier: { $0 == 11 }), "ambiguous tab")
        var noClaude = tab; noClaude.processes.removeAll { $0.pid == 11 }
        XCTAssertNil(ChatSessionIdentity.resolve(pid: 12, startedAt: 120, tabs: [noClaude], identity: { _, _ in true }, signatureVerifier: { $0 == 11 }), "a stale hook UUID cannot prove Claude")
    }

    func testSignatureUsesOnlyManualTitleFolderAndSafeShortFallback() {
        let id = UUID()
        var tab = ChatSessionIdentity.Tab(id: id, customTitle: "\u{202E}  My\nTab\u{0000}", folderName: "folder", processes: [])
        XCTAssertEqual(ChatSessionIdentity.name(tab), "MyTab")
        tab.customTitle = nil; XCTAssertEqual(ChatSessionIdentity.name(tab), "folder")
        tab.folderName = ""; XCTAssertTrue(ChatSessionIdentity.name(tab).hasPrefix("Claude Code "))
        XCTAssertEqual(ChatSessionIdentity.normalized(String(repeating: "a", count: 200)).count, 120)
        XCTAssertEqual(ChatSessionIdentity.normalized(String(repeating: "e\u{301}", count: 120)).unicodeScalars.count, 120)
        XCTAssertLessThanOrEqual(ChatSessionIdentity.limited(String(repeating: "e\u{301}", count: 60), scalars: 111).unicodeScalars.count + 9, 120)
    }

    func testAuthorBindingIsSurfaceNotHookConversationOrWorkingFolder() async throws {
        let f = try await fixture(), a = caller(), b = caller(2)
        f.agent.sessionId = UUID().uuidString.lowercased()
        try f.service.bindPublication(f.key, agent: CallJSON.agent, surface: UUID(uuidString: a.surface))
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g1").field, "author_agent_id")
        // A hook from the genuine B tab can claim A's session UUID, but the
        // publication binding and the kernel-verified B surface stay apart.
        let claimedHookUUID = f.agent.sessionId
        f.agent.sessionId = claimedHookUUID
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: b, generation: "g1").field, "author_session_name")
        f.agent.sessionId = UUID().uuidString.lowercased()
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g1").value, CallJSON.agent)
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g2").field, "author_session_name")
        f.agent.sessionId = nil
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g1").field, "author_session_name", "folder agents do not claim tabs")
    }

    func testSessionPostFreezesSignatureAndCannotBorrowAnotherTabsMessage() async throws {
        let f = try await fixture(); var a = caller(name: "First")
        let id = UUID().uuidString.lowercased()
        let command = try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "hi @billing@anna")
        a.signature = "Renamed"
        XCTAssertEqual(try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "hi @billing@anna"), command)
        XCTAssertEqual(try f.store.outbox.commands().first.map(ChatService.args)?["author_session_name"]?.string, "First")
        XCTAssertEqual(try f.store.outbox.commands().map(\.type), ["message.post_from_session"])
        XCTAssertThrowsError(try f.service.queueSessionPost(f.key, caller: caller(2), generation: "g1", message: id, channel: channel, root: nil, text: "hi @billing@anna"))
        XCTAssertThrowsError(try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "changed"))
        XCTAssertThrowsError(try f.service.retry(f.key, messageId: id), "generic retry must not lose attribution")
        f.service.resendPosts(f.key)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
        XCTAssertEqual(try scalar(f.journal.queue, "SELECT COUNT(*) FROM channel_authorities"), 0)
    }

    func testPendingSessionPostLimitsApplyBeforeQueueing() async throws {
        let f = try await fixture(), a = caller()
        func post(_ c: ChatLocalCaller) throws { _ = try f.service.queueSessionPost(f.key, caller: c, generation: "g1", message: UUID().uuidString.lowercased(), channel: channel, root: nil, text: "hi") }
        try post(a)
        XCTAssertThrowsError(try post(a))
        for n in 2...10 { try post(caller(Int32(n))) }
        XCTAssertThrowsError(try post(caller(11)))
        XCTAssertEqual(try f.store.outbox.commands().count, 10)
    }

    func testSessionPostsAndAutomaticDecisionsNeverCarryToNewGeneration() {
        for type in ["message.post_from_session", "request.create_in_channel_v2", "request.decide_automatic", "agent.channel_trust.set"] {
            XCTAssertTrue(ChatOutbox.neverResent(type)); XCTAssertFalse(ChatOutbox.carriedOver.contains(type))
        }
    }

    func testMissingACKIsPendingAndAcknowledgedAttributionIsReturned() async throws {
        let f = try await fixture(), id = UUID().uuidString.lowercased()
        let command = try f.service.queueSessionPost(f.key, caller: caller(), generation: "g1", message: id, channel: channel, root: nil, text: "hi")
        XCTAssertNil(try f.service.sessionPostOutcome(f.key, message: id, command: command))
        let record = try XCTUnwrap(f.store.outbox.commands().first)
        f.service.commandAnswered(f.key, record, .taken(.init(events: [], result: .object([:]))))
        try f.write("UPDATE outbox SET state = 'sent'")
        XCTAssertNil(try f.service.sessionPostOutcome(f.key, message: id, command: command))
        f.service.commandAnswered(f.key, record, .taken(.init(events: [], result: .object([
            "message_id": .string(id), "channel_id": .string(channel), "author_account_id": .string(f.key.accountId), "author_session_name": .string("Tab")]))))
        XCTAssertEqual(try f.service.sessionPostOutcome(f.key, message: id, command: command)?["status"]?.string, "sent")
    }

    func testMCPRejectsAuthorsUnverifiedCallersAndUnsupportedServerBeforePost() async throws {
        let f = try await fixture()
        var request = AgentPadCLIRequest(verb: .team); request.teamAction = "chat"; request.chatArguments = "{}"
        let refused = await ChatSessionTools.handle(request, origin: .outside, sessions: { [] }, service: f.service)
        XCTAssertFalse(refused.ok); XCTAssertEqual(refused.error, "session_process_unavailable")
        XCTAssertNotNil(AgentPadCallerOrigin.teamRun(callId: "own-self-call").refusal(for: request))
        f.service.serverCapabilities[f.key.server] = []
        do { _ = try await ChatSessionTools.call(.object(["tool": .string("chat_channels")]), caller: caller(), service: f.service, revalidate: { true }); XCTFail() }
        catch let error as ChatSessionTools.Failure { XCTAssertEqual(error.code, "unsupported") }
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testIsolatedRunnerOverridesConfigAfterFilteringWithoutWideningProduction() throws {
        let isolated = try IsolatedClaudeFixture(environment: [:], requireAuthentication: false)
        defer { isolated.remove() }
        let base = ["CLAUDE_CONFIG_DIR": "/untrusted", "ANTHROPIC_API_KEY": "synthetic-only"]
        let env = try isolated.runner().executionEnvironment(claudePath: "/usr/bin/claude", isolateGit: true, ownersPath: false, base: base)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], isolated.config.path)
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(ClaudeCodeRunner.environment(claudePath: "/usr/bin/claude", base: base)["CLAUDE_CONFIG_DIR"])
        XCTAssertFalse(ClaudeCodeRunner.inheritedVariables.contains("CLAUDE_CONFIG_DIR"))
        var mismatched = isolated.runner(); mismatched.sessionFilesRoot = isolated.root
        XCTAssertThrowsError(try mismatched.executionEnvironment(claudePath: "/usr/bin/claude", isolateGit: true, ownersPath: false, base: [:]))
    }

    func testThreadUsesRootForBothRouteAndMemoryAndBudgetsMandatoryContext() async throws {
        let f = try await fixture()
        _ = try message(f, id: thread, text: "Root")
        let sent = try send(f, root: thread)
        let call = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "request.create_in_channel_v2" })
        XCTAssertEqual(ChatService.args(call)["thread_root_id"]?.string, thread)
        XCTAssertEqual(ChatService.args(call)["reply_mode"]?.string, "thread")
        let consent = try XCTUnwrap(f.journal.channelAuthority(XCTUnwrap(sent.request)))
        XCTAssertEqual(consent.root, thread)
        XCTAssertEqual(consent.context?.map(\.messageId), [thread, sent.message])
        _ = try message(f, id: thread, text: String(repeating: "x", count: 48 * 1024), revision: 2)
        XCTAssertThrowsError(try send(f, root: thread))
        XCTAssertNoThrow(try send(f, root: thread, mentionOnly: true), "no execution context for mention-only")
    }

    func testAttributionSnapshotAndReplyLinkSurviveEditAndRunlessPost() async throws {
        let f = try await fixture(), id = UUID().uuidString.lowercased()
        _ = try message(f, id: id, attributes: ["author_agent_id": CallJSON.agent, "author_agent_name": "Original", "in_reply_to_message_id": thread])
        _ = try message(f, id: id, text: "new text", revision: 2, attributes: ["author_agent_name": "Wrong", "author_session_name": "Wrong"])
        let kept = try XCTUnwrap(model(f).message(id))
        XCTAssertEqual(kept.authorAgentName, "Original"); XCTAssertEqual(kept.authorAgentId, CallJSON.agent)
        XCTAssertNil(kept.authorSessionName); XCTAssertEqual(kept.inReplyToMessageId, thread)
        let published = ChatMessageAttribution(kept, ownerName: "Anna", ownerHandle: "anna")
        XCTAssertEqual(published.title, "Original (Anna's agent)"); XCTAssertEqual(published.publishedAgentId, CallJSON.agent)
        XCTAssertEqual(published.ownerTooltip, "@anna · \(f.key.accountId)")
        let signed = UUID().uuidString.lowercased()
        _ = try message(f, id: signed, attributes: ["author_session_name": "Local tab"])
        _ = try message(f, id: signed, text: "edited", revision: 2)
        XCTAssertEqual(model(f).message(signed)?.authorSessionName, "Local tab")
        let signature = ChatMessageAttribution(try XCTUnwrap(model(f).message(signed)), ownerName: "Anna", ownerHandle: "anna")
        XCTAssertEqual(signature.title, "Local tab (Anna's agent)"); XCTAssertNil(signature.publishedAgentId)
    }

    func testFeedMentionsKeepCanonicalTextAndIndividualTooltips() {
        let text = ChatMentionText.attributed("**Hello** @billing@anna and @nobody / mail@anna", addresses: ["billing@anna", "anna"])
        XCTAssertEqual(text.string, "Hello @billing@anna and @nobody / mail@anna")
        let location = (text.string as NSString).range(of: "@billing@anna").location
        XCTAssertEqual(text.attribute(.toolTip, at: location, effectiveRange: nil) as? String, "@billing@anna")
        XCTAssertNil(text.attribute(.toolTip, at: (text.string as NSString).range(of: "@nobody").location, effectiveRange: nil))
        XCTAssertNil(text.attribute(.toolTip, at: text.length - 4, effectiveRange: nil))
    }

    func testAutomaticPublicationWaitsForFinishedACKAndReconcileIsIdempotent() async throws {
        let f = try await fixture(), approval = try await automaticRun(f)
        f.service.reconcileAutomaticChannels()
        XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "result.publish" })
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type = 'run.finished'") }
        f.service.reconcileAutomaticChannels()
        let publication = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "result.publish" })
        XCTAssertEqual(ChatService.args(publication)["run_id"]?.string, approval.runId)
        XCTAssertTrue(ChatService.args(publication)["text"]?.string?.contains("local draft") == true)
        f.service.reconcileAutomaticChannels()
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "result.publish" }.map(\.bodyBytes), [publication.bodyBytes])
        f.agent.maxTurns += 1
        f.service.reconcileAutomaticChannels()
        XCTAssertEqual(try f.store.outbox.commands().first { $0.type == "result.publish" }?.state, .dropped)
        f.agent.maxTurns -= 1
        f.service.reconcileAutomaticChannels()
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "result.publish" }.count, 1)
    }

    func testAcceptedCancelBlocksLateFinishedButRefusalDoesNotRevokeTrust() async throws {
        let f = try await fixture(), approval = try await automaticRun(f)
        let cancellation = try f.service.prepareCommand(f.key, type: "request.cancel", args: .object(["request_id": .string(approval.requestId)])).record
        f.service.commandAnswered(f.key, cancellation, .refused("not_found"))
        XCTAssertFalse(try f.journal.automaticRequestBlocked(f.key, request: approval.requestId))
        f.service.commandAnswered(f.key, cancellation, .taken(.init(events: [], result: .object([:]))))
        XCTAssertTrue(try f.journal.automaticRequestBlocked(f.key, request: approval.requestId))
        XCTAssertTrue(f.service.sourceStatusWord(.init(id: approval.requestId, source: "question", agent: "billing", state: "finished", publication: "awaiting_publish"), key: f.key).contains("cancelled"))
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type = 'run.finished'") }
        f.service.reconcileAutomaticChannels()
        XCTAssertFalse(try f.store.outbox.commands().contains { $0.type == "result.publish" })
    }

    func testActivityExpiresAndCannotDiscloseAfterAccessLossOrCompletion() async throws {
        let f = try await fixture(), sent = try send(f)
        let request = try receive(f, request: XCTUnwrap(sent.request), state: "running"), now = Date()
        let body: ChatJSON = .object(["request_id": .string(request.requestId), "text": .string("Reading files")])
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: body, now: now)
        XCTAssertEqual(f.service.activity(f.key, request: request.requestId, now: now), "Reading files")
        f.service.pruneChannelActivity(now: now.addingTimeInterval(16)); XCTAssertTrue(f.service.channelActivity.isEmpty)
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: body)
        try f.write("UPDATE requests SET state = 'finished'")
        f.service.pruneChannelActivity(); XCTAssertTrue(f.service.channelActivity.isEmpty)
        try f.write("UPDATE requests SET state = 'running'")
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: body)
        try f.write("UPDATE teams SET mine = 0")
        f.service.pruneChannelActivity(); XCTAssertTrue(f.service.channelActivity.isEmpty)
        XCTAssertEqual(ChatService.channelAction("Read /private/personal/file"), "Reading files")
        XCTAssertEqual(ChatService.channelAction("Bash: cat private"), "Running a command")
    }

    func testRepeatedActivityAndPruningDoNotInvalidateUnchangedProgress() async throws {
        let f = try await fixture(), sent = try send(f)
        let request = try receive(f, request: XCTUnwrap(sent.request), state: "running")
        let body: ChatJSON = .object(["request_id": .string(request.requestId), "text": .string("Reading files")])
        let now = Date()
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: body, now: now)
        let changes = Counter()
        for n in 1...100 {
            withObservationTracking { _ = f.service.activity(f.key, request: request.requestId, now: now) }
                onChange: { changes.increment() }
            f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity", body: body, now: now.addingTimeInterval(Double(n) / 100))
            f.service.pruneChannelActivity(now: now)
        }
        XCTAssertEqual(changes.value, 0, "TTL refresh and a no-op prune are not display changes")
        XCTAssertEqual(f.service.activity(f.key, request: request.requestId, now: now.addingTimeInterval(15.5)), "Reading files", "TTL was extended")
        f.service.pruneChannelActivity(now: now.addingTimeInterval(17))
        XCTAssertNil(f.service.activity(f.key, request: request.requestId))
    }

    func testNoticeAndAutomaticPublicationObserversBecomeQuiet() async throws {
        let f = try await fixture(), approval = try await automaticRun(f)
        let original = ChatNotifications.listIds
        let passes = Counter()
        ChatNotifications.listIds = { passes.increment(); return [] }
        let session = try XCTUnwrap(f.service.orgSessions[f.key])
        ChatNotifications.follow(f.service, session: session)
        defer { session.noticeWatch = nil; ChatNotifications.listIds = original }
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type = 'run.finished'") }
        // One external transaction starts F4 and the automatic publisher.
        try f.write("UPDATE requests SET version = version + 1 WHERE request_id = ?", [approval.requestId])
        try await wait { try f.store.outbox.commands().contains { $0.type == "result.publish" } }
        try await Task.sleep(for: .milliseconds(200))
        let settled = passes.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(settled, 0)
        XCTAssertEqual(passes.value, settled, "F4/UX1 must settle without external changes")
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "result.publish" }.count, 1)
    }

    func testProgressPublicationChangesAreObservedWithoutATimer() async throws {
        let f = try await fixture(), approval = try await automaticRun(f), m = model(f)
        let status = try XCTUnwrap(m.sourceStatuses.first { $0.id == approval.requestId })
        try await Task.sleep(for: .milliseconds(100))
        let changed = expectation(description: "progress observes cancellation")
        withObservationTracking { _ = m.sourceStatusWord(status) } onChange: { changed.fulfill() }
        try f.journal.blockAutomaticRequest(f.key, request: approval.requestId)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(m.sourceStatusWord(status).contains("automatic publication cancelled"))
    }

    func testActivityBurstHasOneDisplayUpdateAndExpiresWithoutPollingViews() async throws {
        let f = try await fixture(), sent = try send(f)
        let request = try receive(f, request: XCTUnwrap(sent.request), state: "running")
        let before = f.service.channelActivityRevision
        for n in 0..<100 {
            f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity",
                body: .object(["request_id": .string(request.requestId), "text": .string("Working \(n)")]))
        }
        try await wait { f.service.channelActivityRevision > before }
        XCTAssertEqual(f.service.channelActivityRevision, before + 1)
        XCTAssertEqual(f.service.activity(f.key, request: request.requestId), "Working 99")
        // Bring this entry close to expiry to exercise the real expiry task.
        f.service.clearChannelActivity()
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity",
            body: .object(["request_id": .string(request.requestId), "text": .string("Last")]), now: Date().addingTimeInterval(-14.8))
        try await wait { f.service.channelActivity.isEmpty }
        XCTAssertNil(f.service.channelActivityExpiry)
        let settled = f.service.channelActivityRevision
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(f.service.channelActivityRevision, settled, "no per-row polling or leftover expiry jobs")
    }

    func testMCPFreshHistoryIsPagedAttributedAndNeverMarksUserRead() async throws {
        let f = try await fixture()
        let wire = try message(f, id: thread, attributes: ["author_session_name": "Tab"])
        let bytes = try JSONEncoder().encode(ChatMessagesPage(messages: [wire], next: 7, head: 9))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: bytes)) }
        let before = try scalar(f.store.queue, "SELECT COUNT(*) FROM read_marks")
        let result = try await ChatSessionTools.call(.object(["tool": .string("chat_read"), "org_id": .string(f.key.orgId),
            "channel_id": .string(channel), "thread_root_id": .string(thread), "before": .number(10)]), caller: caller(), service: f.service, revalidate: { true })
        XCTAssertEqual(result["next"], .number(7))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("author_session_name"))
        XCTAssertEqual(ChatStubProtocol.seen.first?.request.url?.path, "/v1/orgs/\(f.key.orgId)/channels/\(channel)/threads/\(thread)")
        XCTAssertEqual(ChatStubProtocol.seen.first?.request.url?.query, "before=10")
        XCTAssertEqual(try scalar(f.store.queue, "SELECT COUNT(*) FROM read_marks"), before)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testMCPAccessRevokedWhileReadingDoesNotReturnStaleHistory() async throws {
        let f = try await fixture(), gate = Gate(); gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { _, _ in gate.pass(); return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
        let args: ChatJSON = .object(["tool": .string("chat_read"), "org_id": .string(f.key.orgId), "channel_id": .string(channel)])
        let task = Task { try await ChatSessionTools.call(args, caller: caller(), service: f.service, revalidate: { true }) }
        try await wait { !ChatStubProtocol.seen.isEmpty }
        try f.write("UPDATE meta SET channel_access_epoch = channel_access_epoch + 1")
        gate.open()
        do { _ = try await task.value; XCTFail("revoked response must not escape") }
        catch let error as ChatSessionTools.Failure { XCTAssertEqual(error.code, "not_found") }
    }

    func testMCPPostUsesFreshRightsAndReturnsOnlyServerAcknowledgedAuthor() async throws {
        let f = try await fixture(), account = f.key.accountId
        ChatStubProtocol.reset { _, bytes in
            if let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes) {
                var result: [String: ChatJSON] = ["author_account_id": .string(account), "author_session_name": .string("Tab"), "revision": .number(1), "seq": .number(2)]
                for key in ["message_id", "channel_id", "thread_root_id"] { result[key] = envelope.args[key] ?? .null }
                return .success(.init(status: 200, body: try! JSONEncoder().encode(ChatCommandAnswer(events: [], result: .object(result)))))
            }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let task = Task { try await ChatSessionTools.call(.object(["tool": .string("chat_post"), "org_id": .string(f.key.orgId),
            "channel_id": .string(channel), "text": .string("Hello @billing@anna")]), caller: caller(), service: f.service, revalidate: { true }) }
        try await wait { try !f.store.outbox.commands().isEmpty }; f.send()
        let result = try await task.value
        XCTAssertEqual(result["status"]?.string, "sent"); XCTAssertEqual(result["author_account_id"]?.string, account)
        XCTAssertEqual(result["author_session_name"]?.string, "Tab")
        XCTAssertEqual(try f.store.outbox.commands().map(\.type), ["message.post_from_session"])
        XCTAssertEqual(try scalar(f.journal.queue, "SELECT COUNT(*) FROM channel_authorities"), 0)
    }

    func testQuotaWaitsForExplicitRetryAndKeepsCommandBytes() async throws {
        let f = try await fixture(), a = caller(), id = UUID().uuidString.lowercased()
        let command = try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "hi")
        let bytes = try XCTUnwrap(f.store.outbox.commands().first?.bodyBytes)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 429, headers: ["Retry-After": "60"], body: Data(#"{"error":"rate_limited"}"#.utf8))) }
        f.send(); try await wait { try f.store.outbox.commands().first?.state == .failed }
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(ChatStubProtocol.seen.count, 1)
        XCTAssertThrowsError(try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "hi")) {
            XCTAssertEqual(($0 as? ChatSessionTools.Failure)?.code, "rate_limited")
            XCTAssertGreaterThan(($0 as? ChatSessionTools.Failure)?.retryAfter ?? 0, 0)
        }
        try f.write("UPDATE session_posts SET retry_after = 0")
        XCTAssertEqual(try f.service.queueSessionPost(f.key, caller: a, generation: "g1", message: id, channel: channel, root: nil, text: "hi"), command)
        XCTAssertEqual(try f.store.outbox.commands().first?.bodyBytes, bytes)
        f.sender?.pump(); try await wait { ChatStubProtocol.seen.count == 2 }
    }

    func testLostACKRecoveryNeverFallsBackToHumanPostOrCrossesLogin() async throws {
        let f = try await fixture(), id = UUID().uuidString.lowercased()
        _ = try f.service.queueSessionPost(f.key, caller: caller(), generation: "g1", message: id, channel: channel, root: nil, text: "hi")
        let bytes = try XCTUnwrap(f.store.outbox.commands().first?.bodyBytes)
        try f.write("UPDATE outbox SET state = 'sent'")
        f.service.resendPosts(f.key)
        XCTAssertEqual(try f.store.outbox.commands().first?.state, .pending)
        XCTAssertEqual(try f.store.outbox.commands().map(\.bodyBytes), [bytes])
        try f.write("UPDATE outbox SET state = 'sent'; UPDATE session_posts SET session_id = 'old-login'")
        f.service.resendPosts(f.key)
        XCTAssertEqual(try f.store.outbox.commands().first?.state, .sent)
    }

    func testRealClaudeFixtureRequiresIsolatedOperatorProfileBeforeAnyRunner() {
        XCTAssertThrowsError(try IsolatedClaudeFixture(environment: [:]))
        XCTAssertThrowsError(try IsolatedClaudeFixture(environment: ["AGENTPAD_LIVE_CLAUDE_CONFIG_DIR": "/not-a-temporary-test-profile"]))
    }

    func testExplicitRetryUsesReviewedSourceRevisionAndNeverPostsQuestionTwice() async throws {
        let f = try await fixture(), sent = try send(f)
        try acknowledge(f)
        _ = try message(f, id: sent.message, text: "@billing@anna revised question", revision: 2)
        let source = try XCTUnwrap(model(f).message(sent.message)), agent = try card(f)
        XCTAssertThrowsError(try f.service.retryChannelCall(f.key, source: source, agent: agent, context: [source]), "unknown outcome cannot create another call")
        try f.write("UPDATE outbox SET state = 'failed', error = 'context_changed' WHERE type = 'request.create_in_channel_v2'")
        let id = try f.service.retryChannelCall(f.key, source: source, agent: agent, context: [source])
        XCTAssertNotEqual(id, sent.request)
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "message.post" }.count, 1)
        let call = try XCTUnwrap(f.store.outbox.commands().last { $0.type == "request.create_in_channel_v2" })
        XCTAssertEqual(ChatService.args(call)["source_revision"], .number(2))
        XCTAssertEqual(ChatService.args(call)["text"]?.string, source.text)
        XCTAssertEqual(ChatService.args(call)["reply_mode"]?.string, "channel")
        XCTAssertEqual(try f.journal.channelAuthority(id)?.sourceRevision, 2)
        XCTAssertNil(try f.journal.channelAuthority(XCTUnwrap(sent.request)))
        let request = try receive(f, request: id), content = try verified(f, request: request)
        XCTAssertNotNil(f.service.automaticAuthority(f.key, request: request, content: content))
        XCTAssertThrowsError(try f.service.retryChannelCall(f.key, source: source, agent: agent, context: [source]))
    }

    func testForgedHookUUIDFromGenuineTabCannotChoosePublishedAuthor() async throws {
        let f = try await fixture(), workspace = makeTestStore(claudeProjectsRoot: f.service.claudeProjectsRoot)
        let tab = try XCTUnwrap(workspace.active?.activeSession)
        tab.customTitle = "Tab B"
        f.agent.sessionId = UUID().uuidString.lowercased()
        let publishedSurface = UUID()
        try f.service.bindPublication(f.key, agent: CallJSON.agent, surface: publishedSurface)
        let input = try JSONSerialization.data(withJSONObject: ["surface": tab.id.uuidString, "kind": "conversationId", "conversationId": f.agent.sessionId!])
        guard case .conversationId(let forged, let surface) = HookServer.parseMessage(input) else { return XCTFail("hook not parsed") }
        workspace.applyConversationId(conversationId: forged, sessionId: surface)
        XCTAssertEqual(tab.conversationId, f.agent.sessionId, "the real B model has the forged A UUID")
        let processes: [SessionProcessScanner.Raw] = [
            .init(pid: 41, ppid: 1, name: "2.1.291", isForeground: true, startedAtUs: 400),
            .init(pid: 42, ppid: 41, name: "agentpad-cli", isForeground: true, startedAtUs: 420)]
        let identity = try XCTUnwrap(ChatSessionIdentity.resolve(pid: 42, startedAt: 420, tabs: [ChatSessionIdentity.tab(tab, processes: processes)],
            identity: { _, _ in true }, signatureVerifier: { $0 == 41 }))
        XCTAssertEqual(identity.surface, tab.id.uuidString.lowercased())
        let author = try f.service.sessionAuthor(f.key, caller: identity, generation: "g1")
        XCTAssertEqual(author.field, "author_session_name"); XCTAssertEqual(author.value, "Tab B")
        try f.service.bindPublication(f.key, agent: CallJSON.agent, surface: tab.id)
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: identity, generation: "g1").value, CallJSON.agent)
        workspace.applyConversationId(conversationId: UUID().uuidString.lowercased(), sessionId: tab.id)
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: identity, generation: "g1").value, CallJSON.agent)
    }

    func testVersionProbeUsesSameIsolatedConfigurationAsExecutor() throws {
        let isolated = try IsolatedClaudeFixture(environment: [:], requireAuthentication: false); defer { isolated.remove() }
        let request = TeamRunRequest(agent: TeamPublishedAgent(name: "test", description: "", folder: isolated.project.path),
            prompt: "test", sessionId: UUID().uuidString.lowercased(), resume: false, callerName: "Test", callerProject: nil)
        let environment = try ClaudeVersionCommand.environment(executable: "/usr/bin/claude", request: request, isolatedConfigDirectory: isolated.config)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], isolated.config.path)
        XCTAssertNil(try ClaudeVersionCommand.environment(executable: "/usr/bin/claude", request: request, isolatedConfigDirectory: nil)["CLAUDE_CONFIG_DIR"])
    }

    func testPublicationWarningsExplainAutomaticChannelAnswersAndShellRights() {
        let lines = TeamPublishWarnings.lines(access: .readGit, fromSession: true, teamNames: ["General"])
        XCTAssertTrue(lines.contains(TeamAccessProfile.shellWarning))
        XCTAssertTrue(lines.contains(TeamPublishWarnings.session))
        XCTAssertTrue(lines.joined().contains("run and publish automatically"))
        XCTAssertTrue(lines.joined().contains("current and future"))
        XCTAssertFalse(lines.joined().contains("every call still waits"))
    }

    func testPredictionUsesLocalConsentOrConfirmedShellFreeRemoteTrust() async throws {
        let f = try await fixture()
        var agent = try card(f)
        XCTAssertTrue(f.service.channelCallIsAutomatic(f.key, channel: channel, agent: agent))
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE org_generations SET pending_generation = 'g2'") }
        XCTAssertFalse(f.service.channelCallIsAutomatic(f.key, channel: channel, agent: agent))
        agent.executorSessionId = "second-mac"
        XCTAssertFalse(f.service.channelCallIsAutomatic(f.key, channel: channel, agent: agent))
        agent.trust = .init(enabled: true, policyId: UUID().uuidString.lowercased(), executorSessionId: "second-mac")
        XCTAssertTrue(f.service.channelCallIsAutomatic(f.key, channel: channel, agent: agent))
        agent.access = "read-git"
        XCTAssertFalse(f.service.channelCallIsAutomatic(f.key, channel: channel, agent: agent))
    }

    func testMissingLocalPolicyIsDisabledPubliclyAndNeverRebuiltFromSnapshot() async throws {
        let f = try await fixture(), policy = UUID().uuidString.lowercased(), channel = channel
        try await f.store.queue.write { try ChatChannelAgents.writeTrust($0, channel: channel, agent: CallJSON.agent,
            trust: .init(enabled: true, policyId: policy, executorSessionId: "s-anna")) }
        f.service.invalidateChannelAuthorities(f.key)
        XCTAssertNil(try f.journal.channelAuthority(policy))
        let commands = try f.store.outbox.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first.map(ChatService.args)?["expected_policy_id"]?.string, policy)
        XCTAssertEqual(commands.first.map(ChatService.args)?["enabled"], .bool(false))
        f.service.invalidateChannelAuthorities(f.key)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }

    func testMCPChannelsReturnsTeamIdentityArchiveAndCursorWithoutCacheFallback() async throws {
        let f = try await fixture(), channel = channel, org = f.key.orgId
        let bytes = Data("{\"channels\":[{\"channel_id\":\"\(channel)\",\"team_id\":\"f5000000-0000-4000-8000-000000000004\",\"name\":\"billing\",\"archived\":true,\"version\":2}],\"next\":\"page-two\"}".utf8)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: bytes)) }
        let result = try await ChatSessionTools.call(.object(["tool": .string("chat_channels"), "after": .string("page-one")]), caller: caller(), service: f.service, revalidate: { true })
        XCTAssertEqual(result["org_id"]?.string, org); XCTAssertEqual(result["next"]?.string, "page-two")
        guard case .array(let channels) = result["channels"] else { return XCTFail() }
        XCTAssertEqual(channels.first?["team_name"]?.string, "Billing"); XCTAssertEqual(channels.first?["can_post"], .bool(false))
        XCTAssertEqual(ChatStubProtocol.seen.first?.request.url?.query, "after=page-one")
        ChatStubProtocol.reset { _, _ in .success(.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))) }
        do { _ = try await ChatSessionTools.call(.object(["tool": .string("chat_read"), "org_id": .string(org), "channel_id": .string(channel)]), caller: caller(), service: f.service, revalidate: { true }); XCTFail("no cached fallback") }
        catch let ChatAPIError.server(status, code, _) { XCTAssertEqual(status, 404); XCTAssertEqual(code, "not_found") }
    }

    func testMCPRejectsPostIfCallerEndsOrOrganizationSwitchesDuringRead() async throws {
        for switchOrg in [false, true] {
            let f = try await fixture(), gate = Gate(); gate.close(); defer { gate.open() }
            ChatStubProtocol.reset { _, _ in gate.pass(); return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
            var alive = true
            let args: ChatJSON = .object(["tool": .string("chat_post"), "org_id": .string(f.key.orgId), "channel_id": .string(channel), "text": .string("hi")])
            let task = Task { try await ChatSessionTools.call(args, caller: caller(), service: f.service, revalidate: { alive }) }
            try await wait { !ChatStubProtocol.seen.isEmpty }
            if switchOrg {
                var connection = try XCTUnwrap(f.service.connection); connection.orgId = UUID().uuidString.lowercased()
                try f.service.saveSignIn(connection, token: "test-only")
            } else { alive = false }
            gate.open()
            do { _ = try await task.value; XCTFail("post must not be queued after scope loss") }
            catch let error as ChatSessionTools.Failure { XCTAssertEqual(error.code, "not_found") }
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        }
    }

    func testAmbiguousPublicationAndInactiveAssignmentCannotChooseAnAgent() async throws {
        let f = try await fixture(), a = caller()
        f.agent.sessionId = UUID().uuidString.lowercased()
        var second = f.agent; second.id = UUID()
        let agents = [f.agent, second]
        f.service.localAgent = { id in agents.first { $0.id.uuidString.lowercased() == id } }
        var assignment = try XCTUnwrap(f.journal.assignment(f.key, agentId: CallJSON.agent))
        assignment.agentId = second.id.uuidString.lowercased(); try f.journal.save(assignment)
        for agent in agents { try f.service.bindPublication(f.key, agent: agent.id.uuidString.lowercased(), surface: UUID(uuidString: a.surface)) }
        XCTAssertThrowsError(try f.service.sessionAuthor(f.key, caller: a, generation: "g1")) {
            XCTAssertEqual(($0 as? ChatSessionTools.Failure)?.code, "ambiguous_author")
        }
        try f.service.bindPublication(f.key, agent: second.id.uuidString.lowercased(), surface: nil)
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g1").value, CallJSON.agent)
        try await f.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 'other-device'") }
        XCTAssertEqual(try f.service.sessionAuthor(f.key, caller: a, generation: "g1").field, "author_session_name")
    }
}
