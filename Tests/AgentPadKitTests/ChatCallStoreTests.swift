import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// A handler that records what it was handed.
@MainActor
final class RecordingActionHandler: ChatActionHandler {
    var seen: [ChatAction] = []
    var requests: [ChatRequest] = []
    var result: ChatActionResult = .done

    func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
        seen.append(action)
        requests.append(request)
        return result
    }
}

/// A handler held until released: what a handler still running when its
/// cache is let go of does.
@MainActor
final class GatedActionHandler: ChatActionHandler {
    private(set) var began = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
        began += 1
        if !open { await withCheckedContinuation { waiting.append($0) } }
        return .done
    }

    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Builders of server JSON for the calls of stage D.
enum CallJSON {
    static let anna = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    static let boris = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    static let agent = "2d7c6e0a-1f3b-4c5d-9e8f-0a1b2c3d4e5f"

    static func json(_ object: Any) -> ChatJSON {
        try! JSONDecoder().decode(ChatJSON.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The whole request (`request.create`, snapshot), or only its changing part.
    static func request(_ id: String, state: String, version: Int, fixed: Bool = true, runId: String? = nil,
                        onThisDevice: Bool? = nil, result: [String: Any]? = nil, owner: String = anna,
                        initiator: String = boris) -> [String: Any] {
        var body: [String: Any] = [
            "request_id": id, "state": state, "version": version, "run_id": runId ?? NSNull(),
            "decline_reason": NSNull(), "failure_reason": NSNull(),
        ]
        if fixed {
            body.merge([
                "kind": "personal", "agent_id": agent, "owner_account_id": owner, "executor_device_name": "Anna's Mac",
                "initiator_account_id": initiator, "text": "Why twice?", "origin": ["session": "Refund bug", "project": "billing-web"],
                "thread_id": NSNull(), "conditions_version": 1, "deliver_by": "2026-10-11T18:20:00.123456Z",
                "created_at": "2026-10-04T18:20:00.123456Z", "updated_at": "2026-10-04T18:20:00.123456Z",
            ]) { $1 }
        }
        if let onThisDevice { body["on_this_device"] = onThisDevice }
        if let result { body["result"] = result }
        return body
    }

    static func wire(_ body: [String: Any]) -> ChatRequestWire {
        try! JSONDecoder().decode(ChatRequestWire.self, from: JSONSerialization.data(withJSONObject: body))
    }

    static func event(_ stream: String, _ seq: Int, _ type: String, _ body: [String: Any]) -> ChatEvent {
        ChatEvent(stream: stream, seq: seq, id: UUID().uuidString, type: type, actor: nil, body: json(body), commandId: nil,
                  at: "2026-10-04T18:20:00Z")
    }

    static func card(_ name: String = "billing", id: String = agent, owner: String = anna, teams: [String]? = nil) -> ChatAgentCard {
        ChatAgentCard(agentId: id, ownerAccountId: owner, name: name, description: "d", access: "read", enabled: true,
                      executorSessionId: "s-anna", executorDeviceName: "Anna's Mac", available: true, teamIds: teams)
    }
}

@MainActor
final class ChatCallStoreTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let req = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
    private let general = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-calls-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root) }
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: org) }
    private var device: String { "device:\(org):s-anna" }
    private var member: String { "member:\(org):\(CallJSON.anna)" }

    private func open(_ key: ChatOrgKey? = nil) throws -> ChatStore { try ChatStore.open(files: files, key: key ?? self.key).store }

    private func actions(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT kind FROM actions ORDER BY created_at, kind") }
    }

    private func actionState(_ store: ChatStore) throws -> String? {
        try store.queue.read { db in try String.fetchOne(db, sql: "SELECT state FROM actions") }
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: (2) One stream late

    /// The device stream takes the request to `running` (version 5); the
    /// member stream's events of versions 2–5 come later: nothing goes back,
    /// the member cursor moves, no action is added, `receive` ran once.
    func testLateMemberStreamDoesNotRollBackOrRepeat() async throws {
        let store = try open()
        let runner = ChatActionRunner(key: key, calls: store.calls)
        let handler = RecordingActionHandler()
        runner.handler = { _ in handler }
        let run = "9c8b7a6f-5e4d-4c3b-9a2f-1e0d9c8b7a6f"
        var facts = ChatLocalFacts()
        let steps: [(String, String, [String: Any])] = [
            ("request.create", "submitted", CallJSON.request(req, state: "submitted", version: 1)),
            ("request.received", "awaiting_decision", CallJSON.request(req, state: "awaiting_decision", version: 2, fixed: false)),
            ("request.decide", "approved", CallJSON.request(req, state: "approved", version: 3, fixed: false)),
            ("run.start", "starting", CallJSON.request(req, state: "starting", version: 4, fixed: false, runId: run)),
            ("run.started", "running", CallJSON.request(req, state: "running", version: 5, fixed: false, runId: run)),
        ]
        for (i, (type, state, body)) in steps.enumerated() {
            // The journal as it would be: allowed at version 3, the run live from 4.
            if i == 2 { facts.approval = .valid; facts.approvalId = "ap-1" }
            if i == 3 { facts.approval = .spent; facts.run = .init(runId: run, ended: false, live: true) }
            XCTAssertEqual(try store.apply(CallJSON.event(device, i + 1, type, body), facts: [req: facts]), .applied)
            runner.run()
            try await waitUntil { handler.seen.count >= min(i + 1, 3) }
            XCTAssertEqual(try store.calls.request(req)?.state.rawValue, state)
        }
        XCTAssertEqual(try actions(store), ["receive", "notify_decision", "start"])

        for (i, (type, _, body)) in steps.enumerated() {
            XCTAssertEqual(try store.apply(CallJSON.event(member, i + 1, type, body), facts: [req: facts]), .applied)
            XCTAssertEqual(try store.calls.request(req)?.state, .running, "not rolled back by version \(i + 1)")
            runner.run()
        }
        try await Task.sleep(for: .milliseconds(50))
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.state, .running)
        XCTAssertEqual(request.version, 5)
        XCTAssertEqual(try store.cursor(member), 5)
        XCTAssertEqual(try actions(store), ["receive", "notify_decision", "start"])
        XCTAssertEqual(handler.seen.filter { $0.kind == .receive }.count, 1)
    }

    // MARK: A pause per row

    /// Rows that end `.retry` wait out their own pause, whatever wakes the
    /// runner meanwhile: two failing rows cannot hand each other over at
    /// the main thread's pace (review D4b-p1-2).
    func testRowsThatFailWaitTheirPauseWhateverWakesTheRunner() async throws {
        final class WakingHandler: ChatActionHandler {
            weak var runner: ChatActionRunner?
            var turns = 0
            func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
                turns += 1
                // What another row's end does: wakes the runner once this one ended.
                Task { @MainActor [weak runner] in runner?.run() }
                return .retry
            }
        }
        let store = try open()
        let runner = ChatActionRunner(key: key, calls: store.calls)
        runner.rewriteDelay = .seconds(5)
        let handler = WakingHandler()
        handler.runner = runner
        runner.handler = { _ in handler }
        let other = "7f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f"
        for (n, id) in [req, other].enumerated() {
            try store.apply(CallJSON.event(device, n + 1, "request.create", CallJSON.request(id, state: "submitted", version: 1, onThisDevice: true)),
                            facts: [id: ChatLocalFacts()])
        }
        runner.run()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(handler.turns, 2, "each row once until its pause is over")
    }

    // MARK: (3) One state, three paths

    /// By event, then — after its action was done — by snapshot and at
    /// launch: one row, done once.
    func testThreeReconcilesOfOneStateMakeOneRow() async throws {
        let store = try open()
        let runner = ChatActionRunner(key: key, calls: store.calls)
        let handler = RecordingActionHandler()
        runner.handler = { _ in handler }
        let body = CallJSON.request(req, state: "submitted", version: 1, onThisDevice: true)
        try store.apply(CallJSON.event(device, 1, "request.create", body), facts: [req: ChatLocalFacts()])
        runner.run()
        try await waitUntil { try self.actionState(store) == "done" }
        try store.apply(ChatSnapshot(cursors: [device: 1], requests: [CallJSON.wire(body)]), facts: [req: ChatLocalFacts()])
        runner.run()
        try store.reconcileAll(facts: [req: ChatLocalFacts()])
        runner.run()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try actions(store), ["receive"])
        XCTAssertEqual(try actionState(store), "done")
        XCTAssertEqual(handler.seen.count, 1)
    }

    // MARK: (4) One transaction

    func testFailureInsideTheTransactionLeavesNoCursorCallOrAction() throws {
        let store = try open()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                                             facts: [req: ChatLocalFacts()]) { _, _ in throw Boom() })
        XCTAssertEqual(try store.cursor(device), 0)
        XCTAssertNil(try store.calls.request(req))
        XCTAssertEqual(try actions(store), [])
    }

    // MARK: (5) Restart with an action in progress

    func testActionInProgressRunsAgainAfterRestart() async throws {
        let store = try open()
        try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let first = RecordingActionHandler()
        first.result = .later
        let runner = ChatActionRunner(key: key, calls: store.calls)
        runner.handler = { _ in first }
        runner.run()
        try await waitUntil { first.seen.count == 1 }
        XCTAssertEqual(try actionState(store), "in_progress")

        // The app again: a new runner over the same file.
        let again = try open()
        let second = RecordingActionHandler()
        let restarted = ChatActionRunner(key: key, calls: again.calls)
        restarted.handler = { _ in second }
        restarted.run()
        try await waitUntil { second.seen.count == 1 }
        XCTAssertEqual(second.seen.first?.requestId, req)
        XCTAssertEqual(second.seen.first?.kind, .receive)
        try await waitUntil { try self.actionState(again) == "done" }
    }

    func testFailedHandlerMarksTheActionFailed() async throws {
        let store = try open()
        try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        handler.result = .failed("forbidden")
        let runner = ChatActionRunner(key: key, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { try self.actionState(store) == "failed" }
        runner.run()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(handler.seen.count, 1)
    }

    // MARK: (7) Organizations and accounts apart

    func testTwoOrganizationsAndTwoAccountsDoNotMix() throws {
        let journal = try ChatJournal.open(files: files)
        let otherOrg = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        let otherAccount = ChatOrgKey(server: server, accountId: CallJSON.boris, orgId: org)
        // Allowed in this organization only.
        try journal.insert(ChatApproval(
            id: "ap-1", server: server.description, accountId: key.accountId, orgId: key.orgId, requestId: req, agentId: CallJSON.agent,
            kind: "initial", params: "{}", paramsHash: "h", runId: "run-1", startCommandId: "c-1", generation: "g1", createdAt: Date()
        ))
        var kinds: [ChatOrgKey: [String]] = [:]
        for k in [key, otherOrg, otherAccount] {
            let store = try open(k)
            let facts = try journal.facts(k, requestIds: [req]) { _ in false }
            try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "approved", version: 3, onThisDevice: true))]),
                            facts: facts)
            kinds[k] = try actions(store)
        }
        XCTAssertEqual(kinds[key], ["start"])
        XCTAssertEqual(kinds[otherOrg], ["fail_start"])
        XCTAssertEqual(kinds[otherAccount], ["fail_start"])
        XCTAssertNotEqual(files.cacheURL(key), files.cacheURL(otherOrg))
        XCTAssertNotEqual(files.cacheURL(key), files.cacheURL(otherAccount))
    }

    // MARK: (8) Local columns kept

    func testSnapshotKeepsTheLocalFullText() throws {
        let store = try open()
        try store.apply(CallJSON.event(member, 1, "request.create", CallJSON.request(req, state: "running", version: 5)))
        try store.calls.setLocal(req, text: "the whole answer", log: "/runs/r.jsonl", runId: "run-1")
        let result: [String: Any] = ["run_id": "run-1", "text": "the whole", "truncated": true, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"]
        try store.apply(ChatSnapshot(cursors: [member: 9], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: "run-1", result: result))]))
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.state, .finished)
        XCTAssertEqual(request.localText, "the whole answer")
        XCTAssertEqual(request.localLog, "/runs/r.jsonl")
        XCTAssertEqual(request.result?.text, "the whole")
        XCTAssertTrue(request.answered)
    }

    // MARK: (10) The result's size

    func testResultOfQuotesIsCutToTheEncodedLimit() throws {
        let full = String(repeating: "\"", count: 131_072)
        let (args, truncated) = try ChatResultText.deliverArgs(org: org, requestId: req, runId: "run-1", text: full, threadId: nil)
        XCTAssertTrue(truncated)
        XCTAssertEqual(args["truncated"], .bool(true))
        let body = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: org, type: "result.deliver", args: args).encoded()
        XCTAssertLessThanOrEqual(body.count, 128 * 1024)
        let sent = try XCTUnwrap(args["text"]?.string)
        XCTAssertTrue(full.hasPrefix(sent))
        XCTAssertGreaterThan(sent.count, 60_000)
        XCTAssertEqual(full.count, 131_072)

        let short = try ChatResultText.deliverArgs(org: org, requestId: req, runId: "run-1", text: "fine", threadId: "t")
        XCTAssertFalse(short.truncated)
        XCTAssertEqual(short.args["text"], .string("fine"))
    }

    // MARK: Rule of versions

    func testOlderVersionChangesNothingAndUnknownRequestIsKept() throws {
        let store = try open()
        // A move of a request not known yet: its changing part is kept.
        try store.apply(CallJSON.event(member, 1, "request.decide", CallJSON.request(req, state: "approved", version: 3, fixed: false)))
        var request = try XCTUnwrap(store.calls.request(req))
        XCTAssertFalse(request.hasFixed)
        XCTAssertEqual(request.state, .approved)
        // An older whole request brings the fixed part only.
        try store.apply(CallJSON.event(member, 2, "request.create", CallJSON.request(req, state: "submitted", version: 1)))
        request = try XCTUnwrap(store.calls.request(req))
        XCTAssertTrue(request.hasFixed)
        XCTAssertEqual(request.text, "Why twice?")
        XCTAssertEqual(request.state, .approved)
        XCTAssertEqual(request.version, 3)
        // The same version again changes nothing either.
        try store.apply(CallJSON.event(member, 3, "run.failed_to_start", CallJSON.request(req, state: "failed_to_start", version: 3, fixed: false)))
        XCTAssertEqual(try store.calls.request(req)?.state, .approved)
        XCTAssertEqual(try store.cursor(member), 3)
    }

    func testResultIsTakenOncePerRun() throws {
        let store = try open()
        try store.apply(CallJSON.event(member, 1, "request.create", CallJSON.request(req, state: "finished", version: 6, runId: "run-1")))
        for (seq, text) in [(2, "first"), (3, "second")] {
            try store.apply(CallJSON.event(member, seq, "result.deliver", [
                "request_id": req, "run_id": "run-1", "text": text, "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z",
            ]))
        }
        XCTAssertEqual(try store.calls.request(req)?.result?.text, "first")
    }

    func testDeviceStreamMarksTheRequestThisDevicesAndOwesReceive() throws {
        let store = try open()
        let body = CallJSON.request(req, state: "submitted", version: 1)
        try store.apply(CallJSON.event(member, 1, "request.create", body), facts: [req: ChatLocalFacts()])
        XCTAssertEqual(try actions(store), [], "another device of the owner, as far as the member stream tells")
        try store.apply(CallJSON.event(device, 1, "request.create", body), facts: [req: ChatLocalFacts()])
        XCTAssertEqual(try store.calls.request(req)?.onThisDevice, true)
        XCTAssertEqual(try actions(store), ["receive"])
    }

    func testWithoutAJournalNothingOfTheExecutorIsDecided() throws {
        let store = try open()
        try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "approved", version: 3)), facts: nil)
        XCTAssertEqual(try actions(store), [])
    }

    // MARK: Catalog

    func testCatalogFollowsTheTeamStreams() throws {
        let store = try open()
        let ops = "00000000-0000-4000-8000-0000000000c2"
        let card = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CallJSON.card())) as! [String: Any]
        try store.apply(CallJSON.event("team:\(general)", 1, "agent.publish", card))
        try store.apply(CallJSON.event("team:\(ops)", 1, "agent.publish", card))
        XCTAssertEqual(try store.calls.catalog().first?.teamIds, [ops, general].sorted())
        try store.apply(CallJSON.event("team:\(general)", 2, "agent.unpublish", ["agent_id": CallJSON.agent]))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["billing"], "still published to ops")
        try store.drop(stream: "team:\(ops)")
        XCTAssertEqual(try store.calls.catalog(), [])

        try store.apply(ChatSnapshot(cursors: [:], agents: [CallJSON.card(teams: [general]), CallJSON.card("payroll", id: "a-2", teams: [general])]))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["billing", "payroll"])
        try store.apply(ChatSnapshot(cursors: [:], agents: [CallJSON.card("payroll", id: "a-2", teams: [general])]))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["payroll"])
    }

    // MARK: History

    func testHistoryShowsRecentFinalRequestsAndKeepsEveryRow() throws {
        let store = try open()
        var old = CallJSON.request("r-old", state: "declined", version: 3)
        old["updated_at"] = "2026-01-01T00:00:00Z"
        let fresh = CallJSON.request("r-new", state: "declined", version: 3)
        let open = CallJSON.request("r-open", state: "running", version: 5)
        try store.apply(ChatSnapshot(cursors: [:], requests: [old, fresh, open].map(CallJSON.wire)))
        let now = ChatStore.date("2026-10-04T18:20:00Z")!
        XCTAssertEqual(Set(try store.calls.historyIds(now: now)), ["r-open", "r-new"])
        XCTAssertEqual(Set(try store.calls.requestIds()), ["r-old", "r-open", "r-new"])
    }

    // MARK: Executor reads the cache (D9, D11)

    func testServiceReadsRequestStateAndLaunchInputsFromTheCache() throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let store = try XCTUnwrap(service.session(for: key).store)
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
                                     requests: [CallJSON.wire(CallJSON.request(req, state: "starting", version: 4))]))
        XCTAssertEqual(service.requestState(key, req), "starting")
        XCTAssertNil(service.requestState(key, "unknown"))
        let launch = try XCTUnwrap(service.launchRequest(req))
        XCTAssertEqual(launch.prompt, "Why twice?")
        XCTAssertEqual(launch.callerName, "Boris")
        XCTAssertEqual(launch.callerProject, "billing-web")
        XCTAssertEqual(launch.expiresAt, ChatStore.date("2026-10-11T18:20:00.123456Z"))
    }
}
