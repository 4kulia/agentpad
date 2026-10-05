import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// The caller's side through the server (docs/agentpad/DESIGN-D5.md): the
/// call and its `request.create` together, the queue's repeats, refusals
/// ending the call, the outcome told once, the cause told with the state.
@MainActor
final class ChatOutgoingCallTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let general = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private var boris: ChatOrgKey { ChatOrgKey(server: server, accountId: CallJSON.boris, orgId: org) }
    private var memberStream: String { "member:\(org):\(CallJSON.boris)" }

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-out-\(UUID().uuidString)")
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        ChatOutgoing.asksOn = false
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root.appendingPathComponent("chat")) }

    /// Boris's cache: Anna's agent `billing` in General.
    private func cache() throws -> ChatStore {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(
            cursors: [:],
            members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                      .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card(teams: [general])]
        ))
        return store
    }

    /// Team work over `store`, its commands through `outbox` as the app wires it.
    private func team(_ store: ChatStore, outbox: ChatOutbox? = nil) -> TeamService {
        let service = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")), runner: RecordingRunner(),
                                  offCalls: TeamOffCallStore())
        service.calls.deliversAsks = true
        if let outbox {
            service.calls.prepareCommand = { [unowned store, unowned outbox] key, type, args in
                (try outbox.prepare(org: key.orgId, type: type, args: args), store.outbox, { outbox.pump() })
            }
        }
        service.calls.useServer(store.calls, key: boris)
        return service
    }

    private func outbox(_ store: ChatStore) -> ChatOutbox {
        let outbox = ChatOutbox(queues: [store.outbox], api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]),
                                token: "aps_t", sessionId: "s1")
        outbox.retryDelay = { _ in 0.05 }
        return outbox
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func creates(_ store: ChatStore) throws -> [ChatCommandRecord] {
        try store.outbox.commands().filter { $0.type == "request.create" }
    }

    // MARK: One transaction, the server's body

    /// The call and its `request.create` are written together, with the
    /// body the server's `CreateArgs` reads — its fields as its sample has
    /// them (DESIGN-D5, amendment 1); a failed write leaves neither.
    func testTheCallAndItsCommandAreOneWrite() throws {
        let store = try cache()
        let service = team(store)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil,
                                         origin: TeamCallOrigin(session: "Refund bug", project: "billing-web"),
                                         deliverBy: Date(timeIntervalSince1970: 1_791_000_000))
        let command = try XCTUnwrap(try creates(store).first)
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes)
        guard case .object(let args) = envelope.args else { return XCTFail("args") }
        let sample = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/chat/request_create_request.json"))) as? [String: Any]
        let sampleArgs = try XCTUnwrap(sample?["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), Set(sampleArgs.keys))
        XCTAssertEqual(args["request_id"], .string(call.id))
        XCTAssertEqual(args["agent_id"], .string(CallJSON.agent))
        XCTAssertEqual(args["text"], .string("Why twice?"))
        XCTAssertEqual(args["conditions_version"], .number(1))
        XCTAssertEqual(args["thread_id"], .null)
        XCTAssertEqual(args["origin"], .object(["session": .string("Refund bug"), "project": .string("billing-web")]))
        XCTAssertNotNil(args["deliver_by"]?.string)
        XCTAssertEqual(envelope.type, "request.create")
        XCTAssertEqual(envelope.org, org)
        // On its way: said so, not as a state this build does not know (review D5-p2-2).
        XCTAssertEqual(service.calls.outgoing.first?.report.detail, "Not on the server yet: it goes as soon as this Mac can send it.")

        // The command cannot be stored: no call either.
        try store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER no_queue BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "Again", threadId: nil, origin: nil))
        let requests = try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM requests") ?? 0 }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try creates(store).count, 1)
    }

    // MARK: Repeats

    /// No network, then a lost answer: the queue repeats the same bytes —
    /// same `command_id`, same `request_id` — and the server has one request.
    func testRepeatsSendTheSameCommandAndRequest() async throws {
        let posted = PostedBodies()
        ChatStubProtocol.reset { request, body in
            guard request.url?.path == "/v1/commands" else { return .success(.init(status: 200)) }
            let attempt = posted.add(body)
            // First: no network. Second: the server does it, the answer is lost. Third: its saved answer.
            if attempt == 1 { return .failure(URLError(.notConnectedToInternet)) }
            if attempt == 2 { return .failure(URLError(.networkConnectionLost)) }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{"request_id":"x"}}"#.utf8)))
        }
        let store = try cache()
        let outbox = outbox(store)
        let service = team(store, outbox: outbox)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        try await waitUntil { try self.creates(store).first?.state == .sent }
        XCTAssertEqual(posted.count, 3)
        XCTAssertEqual(Set(posted.all).count, 1, "the same bytes each time")
        XCTAssertTrue(posted.all.first.map { String(decoding: $0, as: UTF8.self).contains(call.id) } == true)
        XCTAssertEqual(service.calls.outgoing.first?.report.state, .queued, "accepted; the state comes with the server's events")
    }

    // MARK: Refusals

    /// 404 and 409 `agent_unavailable` end the call as `failed` with the
    /// code; whoever waits on it wakes with the end; told once.
    func testARefusedCreateEndsTheCall() async throws {
        for (status, code) in [(404, "not_found"), (409, "agent_unavailable")] {
            ChatStubProtocol.reset { request, _ in
                guard request.url?.path == "/v1/commands" else { return .success(.init(status: 200)) }
                return .success(.init(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8)))
            }
            let store = try cache()
            let outbox = outbox(store)
            let service = team(store, outbox: outbox)
            var told: [String] = []
            service.calls.onOutgoingFinished = { told.append($0.id) }
            // As the app wires it: the queue's refusal settles, the calls are read again.
            outbox.onPermanentFailure = { record, _ in
                if record.type == "request.create", (try? store.calls.settleCreates())?.isEmpty == false { service.calls.reload() }
            }
            let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
            let checked = try await service.calls.check(call.id, wait: 5)
            XCTAssertEqual(checked?.report.state, .failed, code)
            // The server's codes said in words (D5b §3.3); the rest by its code.
            let said = ChatTeamCallStore.createRefusals[code].map { "Not sent: \($0)" } ?? "Not sent: the server refused it (\(code))."
            XCTAssertEqual(checked?.report.detail, said)
            let request = try XCTUnwrap(try store.calls.request(call.id))
            XCTAssertEqual(request.state, .failed)
            XCTAssertEqual(request.version, 0)
            try FileManager.default.removeItem(at: root)
        }
    }

    /// The rule is by request, not by row: a command dropped when the core
    /// carried it to a new session is no refusal while its successor lives;
    /// one only dropped ends the call. A refusal a crash left unsettled is
    /// settled when the organization starts.
    func testDroppedOnlyEndsACallWithNoLivingCommand() throws {
        let store = try cache()
        let service = team(store)
        let carried = try service.calls.ask("billing@anna", prompt: "Carried", threadId: nil, origin: nil)
        let lost = try service.calls.ask("billing@anna", prompt: "Lost", threadId: nil, origin: nil)
        let first = try XCTUnwrap(try creates(store).first)
        func body(_ id: String) throws -> Data {
            try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: org, type: "request.create",
                                    args: .object(["request_id": .string(id), "agent_id": .string(CallJSON.agent), "text": .string("x"),
                                                   "conditions_version": .number(1), "thread_id": .null])).encoded()
        }
        try store.queue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'dropped'")
            // The core carried the first to the new session: a living row of the same request.
            var successor = first
            successor.commandId = ChatUUID.v7()
            successor.bodyBytes = try body(carried.id)
            successor.state = .pending
            _ = try store.outbox.insert(db, successor, seq: 99)
        }
        XCTAssertEqual(try store.calls.settleCreates(), [lost.id])
        XCTAssertEqual(try store.calls.request(carried.id)?.state, .creating)
        let ended = try XCTUnwrap(try store.calls.request(lost.id))
        XCTAssertEqual(ended.state, .failed)
        XCTAssertEqual(ended.failureReason, ChatCallStore.sessionEnded)

        // A refusal written, the settling not (a crash between): done when the organization starts.
        let another = try service.calls.ask("billing@anna", prompt: "Refused", threadId: nil, origin: nil)
        try store.queue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'failed', error = 'not_found' WHERE state = 'pending' AND body_bytes LIKE ?",
                           arguments: ["%\(another.id)%"])
        }
        let chat = ChatService(files: files, tokens: FakeTokenStore())
        try chat.saveSignIn(ChatConnection(server: server, accountId: CallJSON.boris, sessionId: "s1", deviceName: "Mac", orgId: org), token: "aps_t")
        let session = chat.session(for: boris)
        XCTAssertEqual(try session.store?.calls.request(another.id)?.state, .failed)
    }

    /// Until the owner's side is in the build, `ask` keeps its refusal: a
    /// request would wait with no Mac to take it (review D5-p2-1).
    func testAskIsOffUntilTheOwnersSideIsIn() throws {
        let store = try cache()
        let service = team(store)
        let chat = ChatService(files: ChatFiles(directory: root.appendingPathComponent("off")), tokens: FakeTokenStore())
        ChatOutgoing.install(calls: service.calls, service: chat)
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil)) {
            XCTAssertEqual($0 as? TeamError, .notYet(TeamServerCore.askNotYet))
        }
        XCTAssertEqual(try creates(store), [])
        ChatOutgoing.asksOn = true
        ChatOutgoing.install(calls: service.calls, service: chat)
        service.calls.prepareCommand = nil
        XCTAssertNoThrow(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil))
    }

    /// Settling a refusal that cannot be written is tried again after a
    /// pause, until it is (review D5-p1-1).
    func testASettleThatCannotBeWrittenIsTriedAgain() async throws {
        let chat = ChatService(files: files, tokens: FakeTokenStore())
        chat.reconcileDelay = .milliseconds(50)
        try chat.saveSignIn(ChatConnection(server: server, accountId: CallJSON.boris, sessionId: "s1", deviceName: "Mac", orgId: org), token: "aps_t")
        let store = try XCTUnwrap(chat.session(for: boris).store)
        try store.apply(ChatSnapshot(
            cursors: [:],
            members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                      .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card(teams: [general])]
        ))
        let service = team(store)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'failed', error = 'agent_unavailable'")
            try db.execute(sql: "CREATE TRIGGER no_settle BEFORE UPDATE OF state ON requests BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        chat.settleCreates(boris)
        XCTAssertEqual(try store.calls.request(call.id)?.state, .creating)
        try await store.queue.write { db in try db.execute(sql: "DROP TRIGGER no_settle") }
        try await waitUntil { try store.calls.request(call.id)?.state == .failed }
    }

    /// The server's own version wins over a call ended here: it reached the
    /// server after all.
    func testTheServersVersionWinsOverALocalEnd() throws {
        let store = try cache()
        let service = team(store)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        try store.queue.write { db in try db.execute(sql: "UPDATE outbox SET state = 'failed', error = 'not_found'") }
        XCTAssertEqual(try store.calls.settleCreates(), [call.id])
        try store.apply(CallJSON.event(memberStream, 1, "request.create",
                                       CallJSON.request(call.id, state: "submitted", version: 1, owner: CallJSON.anna, initiator: CallJSON.boris)))
        XCTAssertEqual(try store.calls.request(call.id)?.state, .submitted)
    }

    // MARK: Outcomes

    /// A declined or not-started call ends with the server's reason; a
    /// cause is told with the state's own words, not instead of them.
    func testOutcomesTellTheCauseWithTheState() throws {
        let store = try cache()
        let service = team(store)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        var declined = CallJSON.request(call.id, state: "declined", version: 3, owner: CallJSON.anna, initiator: CallJSON.boris)
        declined["cause"] = "agent_disabled"
        try store.apply(CallJSON.event(memberStream, 1, "request.decide", declined))
        service.calls.reload()
        let detail = try XCTUnwrap(service.calls.outgoing.first?.report.detail)
        XCTAssertTrue(detail.hasPrefix("The agent was disabled or taken down by its owner or an admin."), detail)
        XCTAssertTrue(detail.contains("The owner declined it"), detail)
        XCTAssertEqual(service.calls.outgoing.first?.report.state.isFinal, true)

        // Finished though asked to stop for a cause: its own outcome first (review D5-p2-3).
        let finished = try service.calls.ask("billing@anna", prompt: "Finished", threadId: nil, origin: nil)
        var ran = CallJSON.request(finished.id, state: "finished", version: 7, runId: "run-1", owner: CallJSON.anna, initiator: CallJSON.boris)
        ran["cause"] = "agent_disabled"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(ran)]))
        service.calls.reload()
        let ranDetail = try XCTUnwrap(service.calls.outgoing.first { $0.id == finished.id }?.report.detail)
        XCTAssertTrue(ranDetail.hasPrefix("The agent finished; the result follows."), ranDetail)
        XCTAssertTrue(ranDetail.contains("The agent was disabled"), ranDetail)

        let other = try service.calls.ask("billing@anna", prompt: "Again", threadId: nil, origin: nil)
        var notStarted = CallJSON.request(other.id, state: "failed_to_start", version: 5, owner: CallJSON.anna, initiator: CallJSON.boris)
        notStarted["failure_reason"] = "folder_missing"
        try store.apply(CallJSON.event(memberStream, 2, "run.failed_to_start", notStarted))
        service.calls.reload()
        let failed = try XCTUnwrap(service.calls.outgoing.first { $0.id == other.id })
        XCTAssertEqual(failed.report.state, .failed)
        XCTAssertEqual(failed.report.detail, "The agent could not be started (folder_missing).")
        // An older version changes nothing.
        try store.apply(CallJSON.event(memberStream, 3, "request.received",
                                       CallJSON.request(other.id, state: "awaiting_decision", version: 2, fixed: false)))
        XCTAssertEqual(try store.calls.request(other.id)?.state, .failedToStart)
    }

    /// The outcome is told once: by the action runner, whatever brings the
    /// end again — a repeated event, a snapshot.
    func testTheOutcomeIsToldOnce() async throws {
        let chat = ChatService(files: files, tokens: FakeTokenStore())
        // In step with the server: actions may run.
        chat.isServerKnown = { _, _ in true }
        try chat.saveSignIn(ChatConnection(server: server, accountId: CallJSON.boris, sessionId: "s1", deviceName: "Mac", orgId: org), token: "aps_t")
        let session = chat.session(for: boris)
        let store = try XCTUnwrap(session.store)
        try store.apply(ChatSnapshot(
            cursors: [:],
            members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                      .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card(teams: [general])]
        ))
        let service = team(store)
        var told: [String] = []
        service.calls.onOutgoingFinished = { told.append($0.id) }
        ChatOutgoing.asksOn = true
        ChatOutgoing.install(calls: service.calls, service: chat)
        service.calls.prepareCommand = nil
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        var declined = CallJSON.request(call.id, state: "declined", version: 3, owner: CallJSON.anna, initiator: CallJSON.boris)
        declined["decline_reason"] = "not now"
        let event = CallJSON.event(memberStream, 1, "request.decide", declined)
        try store.apply(event)
        service.calls.reload()
        session.actions?.run()
        try await waitUntil { told.count == 1 }
        // A refusal through the one dispatcher of the queue's answers ends a call too.
        let refused = try service.calls.ask("billing@anna", prompt: "Refused", threadId: nil, origin: nil)
        let record = try XCTUnwrap(try store.outbox.commands().first { String(decoding: $0.bodyBytes, as: UTF8.self).contains(refused.id) })
        try await store.queue.write { db in try db.execute(sql: "UPDATE outbox SET state = 'failed', error = 'not_found' WHERE command_id = ?", arguments: [record.commandId]) }
        chat.commandAnswered(boris, record, .refused("not_found"))
        XCTAssertEqual(try store.calls.request(refused.id)?.state, .failed)
        try await waitUntil { told.count == 2 }
        told.removeAll { $0 == refused.id }
        // The same end again: by the repeated event, then by a snapshot.
        try store.apply(event)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(declined)]))
        session.actions?.run()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(told, [call.id])
    }
}

/// Bodies the stub server was sent, in order.
final class PostedBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func add(_ body: Data) -> Int { lock.withLock { bodies.append(body); return bodies.count } }
    var count: Int { lock.withLock { bodies.count } }
    var all: [Data] { lock.withLock { bodies } }
}
