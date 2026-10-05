import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// G1 candidates 1–5, including G6's complete compromised-server scenario.
/// This combines the server-side threat-check drafts with the existing
/// launcher/reconcile unit coverage; it never substitutes a fake launcher.
@MainActor
final class ChatAcceptanceG1Tests: XCTestCase {
    private var root: URL!
    private var scope: TeamServiceTestScope!
    private var server: FakeChatServer!
    private var clients: [FakeChatServer.Client] = []
    private var restoreNotifications: (() -> Void)?

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        let post = ChatNotifications.post, remove = ChatNotifications.remove
        let list = ChatNotifications.listIds, badge = ChatNotifications.badgeChanged
        restoreNotifications = {
            ChatNotifications.post = post; ChatNotifications.remove = remove
            ChatNotifications.listIds = list; ChatNotifications.badgeChanged = badge
        }
        ChatNotifications.post = { _, _ in }
        ChatNotifications.remove = { _, _ in }
        ChatNotifications.listIds = { [] }
        ChatNotifications.badgeChanged = {}
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-g1-\(UUID().uuidString)")
        server = FakeChatServer()
    }

    override func tearDown() async throws {
        for client in clients { await client.close() }
        // Disconnect schedules notification reconciliation. Join its final
        // badge callback before restoring the real hooks and shared service;
        // a later callback would otherwise escape this test's storage scope.
        if let service = clients.last?.service {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                ChatNotifications.badgeChanged = {
                    if !finished { finished = true; continuation.resume() }
                }
                ChatNotifications.reconcile(service)
            }
        }
        clients = []
        ChatStubProtocol.reset()
        restoreNotifications?()
        restoreNotifications = nil
        server = nil
        scope.close()
        scope = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func client(session: String = FakeChatServer.executor, assigned: Bool = true,
                        requests: [[String: Any]] = []) async throws -> FakeChatServer.Client {
        // The request exists on the server before this device/app exists.
        server.snapshot(session: session, requests: requests)
        let client = try FakeChatServer.Client(server: server, root: root.appendingPathComponent(UUID().uuidString),
                                              session: session, assigned: assigned)
        clients.append(client)
        try await client.start()
        try await client.settle()
        return client
    }

    private func approval(_ client: FakeChatServer.Client) throws -> ChatApproval? {
        try client.journal.approval(client.key, requestId: FakeChatServer.requestId)
    }

    /// Both button tasks reach the barrier before either can decide. The
    /// second device even has a stale assignment and the same local agent:
    /// only the executor session may create consent or a command.
    func testSimultaneousOwnerDevicesExecuteAndDeliverExactlyOnce() async throws {
        let a = try await client(requests: [FakeChatServer.request(state: "awaiting_decision", version: 2)])
        let b = try await client(session: "s-other", requests: [FakeChatServer.request(state: "awaiting_decision", version: 2, here: false)])
        XCTAssertEqual(a.key, b.key)
        XCTAssertNotEqual(a.service.connection?.sessionId, b.service.connection?.sessionId)
        XCTAssertNotEqual(a.journal.url, b.journal.url)
        XCTAssertEqual(a.team.calls.incoming.map(\.id), [FakeChatServer.requestId])
        XCTAssertEqual(b.team.calls.incoming.map(\.id), [FakeChatServer.requestId])
        XCTAssertNil(a.team.calls.refusal(.decide, for: try XCTUnwrap(a.team.calls.incoming.first)))
        XCTAssertNotNil(b.team.calls.refusal(.decide, for: try XCTUnwrap(b.team.calls.incoming.first)))

        let barrier = DecisionBarrier()
        func decide(_ client: FakeChatServer.Client) async -> String? {
            await barrier.arrive()
            return client.service.owner?.decide(client.key, requestId: FakeChatServer.requestId, allow: true, reason: nil)
        }
        async let first = decide(a)
        async let second = decide(b)
        let results = await (first, second)
        XCTAssertEqual(barrier.arrivals, 2)
        XCTAssertNil(results.0)
        XCTAssertNotNil(results.1)
        try await a.settle()
        try await b.settle()
        let allowed = try XCTUnwrap(approval(a))
        XCTAssertNil(try approval(b))
        XCTAssertEqual(try server.commands().filter { $0.type == "request.decide" }.count, 1)
        XCTAssertTrue(try server.commands(session: b.session).isEmpty)

        // One accepted decision; both sessions see every subsequent move.
        for client in [a, b] {
            try await client.event("request.decide", body: FakeChatServer.request(state: "approved", version: 3, here: client === a))
        }
        XCTAssertEqual(try server.commands().filter { $0.type == "run.start" }.count, 1)
        XCTAssertEqual(a.runner.calls + b.runner.calls, 0)
        for client in [a, b] {
            try await client.event("run.start", body: FakeChatServer.request(state: "starting", version: 4, here: client === a, run: allowed.runId))
        }
        // A replay and a full resync of the same start must not spend it twice.
        for client in [a, b] {
            let starting = FakeChatServer.request(state: "starting", version: 4, here: client === a, run: allowed.runId)
            try await client.event("run.start", body: starting)
            try await client.refresh([starting])
        }
        XCTAssertEqual(a.runner.calls, 1)
        XCTAssertEqual(b.runner.calls, 0)
        XCTAssertEqual(try a.journal.runs().count, 1)
        XCTAssertTrue(try b.journal.runs().isEmpty)
        XCTAssertEqual(try server.commands().filter { $0.type == "run.started" }.count, 1)
        XCTAssertEqual(try server.commands().filter { $0.type == "result.deliver" }.count, 1)
        XCTAssertTrue(try server.commands(session: b.session).isEmpty)
    }

    /// The initial snapshot alone presents an actionable decision. No event
    /// frames, event pages or second snapshot can accidentally rescue the test.
    func testOfflineExecutorGetsAnActionableDecisionFromOneSnapshotWithoutEvents() async throws {
        server.answersReceive = true
        let client = try await client(requests: [FakeChatServer.request(state: "submitted", version: 1)])
        XCTAssertEqual(client.decisionsWanted, [FakeChatServer.requestId])
        let call = try XCTUnwrap(client.team.calls.incoming.first)
        XCTAssertEqual(call.state, .awaitingApproval)
        XCTAssertNil(client.team.calls.refusal(.decide, for: call))
        XCTAssertNil(client.team.calls.decide(call.id, allow: true))
        try await client.settle()
        XCTAssertNotNil(try approval(client))
        let decisions = try server.commands().filter { $0.type == "request.decide" }
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.args["allow"], .bool(true))
        XCTAssertEqual(server.snapshotCount(session: client.session), 1)
        XCTAssertEqual(client.eventFrames, 0)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/events" })
        XCTAssertEqual(client.runner.calls, 0, "a decision still waits for the server's start")
    }

    /// Strengthens/replaces ChatTeamCallsTests.testReceiveDeclinesTermsItDoesNotKnow:
    /// the refusal crosses HTTP, and no approval or run exists afterwards.
    func testUnknownConditionsDeclineAsUnsupportedWithoutLaunching() async throws {
        let client = try await client(requests: [FakeChatServer.request(state: "submitted", version: 1, conditions: 999)])
        let commands = try client.journal.commands(for: client.key)
        XCTAssertEqual(commands.map(\.type), ["request.received", "request.decide"])
        XCTAssertEqual(commands.last?.dependsOn, commands.first?.commandId)
        let refusal = try XCTUnwrap(server.commands().last)
        XCTAssertEqual(refusal.type, "request.decide")
        XCTAssertEqual(refusal.args["allow"], .bool(false))
        XCTAssertEqual(refusal.args["reason"], .string("unsupported_conditions"))
        XCTAssertEqual(client.probes[.receive]?.completed, 1)
        XCTAssertNil(try approval(client))
        XCTAssertTrue(try client.journal.runs().isEmpty)
        XCTAssertEqual(client.runner.calls, 0)
    }

    func testReceiveAnswerRequiresTheCurrentRequestSessionGenerationAndVersion() async throws {
        let client = try await client(requests: [FakeChatServer.request(state: "submitted", version: 1)])
        let sent = try XCTUnwrap(client.journal.commands(for: client.key).first)
        XCTAssertEqual(sent.type, "request.received")
        let result: [String: ChatJSON] = ["request_id": .string(FakeChatServer.requestId), "state": .string("awaiting_decision"), "version": .number(2)]
        for mismatch in ["request", "session", "generation", "pending generation", "version", "state", "other device", "already cancelled"] {
            var record = sent, fields = result
            switch mismatch {
            case "request": fields["request_id"] = .string("someone-elses-request")
            case "session": record.sessionId = "signed-out-session"
            case "generation": record.sentGeneration = "g0"
            case "pending generation": try client.journal.setPending(client.key, "g2")
            case "version": fields["version"] = .number(1)
            case "state": fields["state"] = .string("approved")
            case "other device": try await client.store.queue.write { try $0.execute(sql: "UPDATE requests SET on_this_device = 0") }
            default: try await client.store.queue.write { try $0.execute(sql: "UPDATE requests SET state = 'cancelled'") }
            }
            client.service.commandAnswered(client.key, record, .taken(ChatCommandAnswer(events: [], result: .object(fields))))
            XCTAssertEqual(try client.request().state, mismatch == "already cancelled" ? .cancelled : .submitted, mismatch)
            XCTAssertEqual(try client.request().version, 1, mismatch)
            XCTAssertNil(try approval(client), mismatch)
            try client.journal.finish(client.key, "g1")
            try await client.store.queue.write { try $0.execute(sql: "UPDATE requests SET on_this_device = 1, state = 'submitted'") }
        }
        // Only state/version are consumed, even if a compromised server adds
        // a different fixed part or executor flag to this valid receipt.
        var extra = result
        extra["text"] = .string("forged replacement")
        extra["on_this_device"] = .bool(false)
        client.service.commandAnswered(client.key, sent, .taken(ChatCommandAnswer(events: [], result: .object(extra))))
        try await client.settle()
        XCTAssertEqual(try client.request().state, .awaitingDecision)
        XCTAssertEqual(try client.request().text, "Why twice?")
        XCTAssertTrue(try client.request().onThisDevice)
        XCTAssertEqual(client.decisionsWanted, [FakeChatServer.requestId])
        XCTAssertEqual(client.runner.calls, 0)
        XCTAssertTrue(try client.journal.approvals().isEmpty)
    }

    /// A server saying approved supplies neither assignment nor consent. Even
    /// an explicit local Allow afterwards cannot substitute for publication on
    /// this new Mac: the launcher must still refuse with not_assigned.
    func testNewDeviceWithoutAssignmentCannotExecuteServerApprovalOrLocalAllow() async throws {
        let client = try await client(assigned: false, requests: [FakeChatServer.request(state: "approved", version: 3)])
        XCTAssertNil(try client.journal.assignment(client.key, agentId: CallJSON.agent))
        XCTAssertNil(try approval(client))
        XCTAssertEqual(try server.commands().last?.args["reason"], .string("no_local_approval"))
        XCTAssertEqual(client.runner.calls, 0)
        try await client.refresh([FakeChatServer.request(state: "awaiting_decision", version: 4)])
        XCTAssertNil(client.service.owner?.decide(client.key, requestId: FakeChatServer.requestId, allow: true, reason: nil))
        let allowed = try XCTUnwrap(approval(client))
        try await client.event("request.decide", body: FakeChatServer.request(state: "approved", version: 5))
        try await client.event("run.start", body: FakeChatServer.request(state: "starting", version: 6, run: allowed.runId))
        XCTAssertEqual(try approval(client)?.voidReason, "not_assigned")
        XCTAssertTrue(try server.commands().contains { $0.type == "run.failed_to_start" && $0.args["reason"] == .string("not_assigned") })
        XCTAssertNil(try client.journal.assignment(client.key, agentId: CallJSON.agent))
        XCTAssertTrue(try client.journal.runs().isEmpty)
        XCTAssertEqual(client.runner.calls, 0)
    }

    /// G6 row 4, consolidated from the server's ChatTeamCallsG6 draft. Covers
    /// every listed forgery, repeats and reversed order, with/without a local
    /// assignment. Boundary/CLI/profile tests already live in TeamSocketOriginTests
    /// and TeamAccessProfileTests; copying TeamBoundaryG6Tests would duplicate them.
    func testForgedServerMessagesAndSnapshotsNeverCreateLocalAuthority() async throws {
        for assigned in [false, true] {
            for reversed in [false, true] {
                let client = try await client(assigned: assigned)
                let before = try client.journal.assignment(client.key, agentId: CallJSON.agent)
                let agents = client.team.calls.agents
                // The formerly missing G6 forgery: a published card for this
                // session, including a local agent and a wholly invented one.
                for id in [CallJSON.agent, "00000000-0000-4000-8000-000000000099"] {
                    try await client.event("agent.publish", body: [
                        "agent_id": id, "owner_account_id": CallJSON.anna, "name": "forged", "description": "server supplied",
                        "access": "edit", "enabled": true, "available": true,
                        "executor_session_id": client.session, "executor_device_name": "Forged Mac"
                    ], stream: "team:\(FakeChatServer.team)")
                    let consumed = try await client.store.queue.read {
                        try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM agents_catalog WHERE agent_id = ?)", arguments: [id])!
                    }
                    XCTAssertTrue(consumed, "positive control: the forged card was actually consumed")
                }
                var version = 0
                let moves = reversed ? Array(FakeChatServer.moves.reversed()) : FakeChatServer.moves
                for move in moves + moves {
                    version += 1
                    var body = FakeChatServer.request(state: move.state, version: version, run: "forged-run")
                    if move.type == "request.decide" { body["allow"] = true }
                    try await client.event(move.type, body: body)
                    XCTAssertEqual(try client.request().state.rawValue, move.state)
                    try assertNoAuthority(client, assignment: before, label: "\(move.type), assigned=\(assigned), reversed=\(reversed)")
                }
                for state in FakeChatServer.snapshots {
                    version += 1
                    try await client.refresh([FakeChatServer.request(state: state, version: version, run: "forged-run")])
                    XCTAssertEqual(try client.request().state.rawValue, state)
                    try assertNoAuthority(client, assignment: before, label: "snapshot \(state), assigned=\(assigned)")
                }
                XCTAssertEqual(client.team.calls.agents, agents)
                XCTAssertGreaterThan(client.probes[.receive]?.completed ?? 0, 0)
                XCTAssertGreaterThan(client.probes[.failStart]?.completed ?? 0, 0)
                await client.close()
            }
        }
    }

    private func assertNoAuthority(_ client: FakeChatServer.Client, assignment: ChatAssignment?, label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(client.runner.calls, 0, label, file: file, line: line)
        XCTAssertTrue(try client.journal.approvals().isEmpty, label, file: file, line: line)
        XCTAssertTrue(try client.journal.runs().isEmpty, label, file: file, line: line)
        let assignments = try client.journal.queue.read { try ChatAssignment.fetchAll($0) }
        XCTAssertEqual(assignments, assignment.map { [$0] } ?? [], label, file: file, line: line)
        XCTAssertFalse(try client.journal.commands(for: client.key).contains {
            ["run.start", "run.started", "result.deliver", "result.publish", "agent.publish"].contains($0.type)
        }, label, file: file, line: line)
        let decisions = try client.journal.commands(for: client.key).filter { $0.type == "request.decide" }
        for decision in decisions {
            let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: decision.bodyBytes)
            XCTAssertEqual(envelope.args["allow"], .bool(false), label, file: file, line: line)
        }
    }

    @MainActor private final class DecisionBarrier {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var arrivals = 0
        func arrive() async {
            arrivals += 1
            if arrivals == 2 { waiting.forEach { $0.resume() }; waiting = []; return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}
