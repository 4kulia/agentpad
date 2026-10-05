import Foundation
import GRDB
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

/// A handler that holds each request's first turn until let go, then
/// says `.later`.
@MainActor
final class PausedActionHandler: ChatActionHandler {
    private(set) var turnsOf: [String: Int] = [:]
    var turns: Int { turnsOf.values.reduce(0, +) }
    private var held: [CheckedContinuation<Void, Never>] = []

    func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
        turnsOf[action.requestId, default: 0] += 1
        if turnsOf[action.requestId] == 1 { await withCheckedContinuation { held.append($0) } }
        return .later
    }

    func release() {
        for c in held { c.resume() }
        held = []
    }
}

@MainActor
final class Transports {
    var all: [FakeSocketTransport] = []
}

/// The calls of server mode as `TeamCalls` and the feed see them (D8): the
/// cache is their only store; the server's word is taken by generation and
/// version; history keeps its bounds.
@MainActor
final class ChatTeamCallsTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let req = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
    private let general = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private var services: [ChatService] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-team-calls-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        for service in services {
            service.stopFeed()
            for session in service.orgSessions.values { session.sync?.stop() }
        }
        services = []
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root.appendingPathComponent("chat")) }
    private var anna: ChatOrgKey { ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: org) }
    private var boris: ChatOrgKey { ChatOrgKey(server: server, accountId: CallJSON.boris, orgId: org) }
    private var member: String { "member:\(org):\(CallJSON.anna)" }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func insertAction(_ store: ChatStore, _ id: String) throws {
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO actions (request_id, kind, state, created_at, updated_at) VALUES (?, 'notify_outcome', 'pending', 0, 0)",
                           arguments: [id])
        }
    }


    private static func text(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }

    /// Anna's app, signed in, its feed against a stub server whose snapshot
    /// carries `requests` and `next`; `pages` answers `before=` (nil: an
    /// empty last page); a closed `pageGate` holds the pages.
    private func started(requests: [[String: Any]], next: String?, pages: [String: [[String: Any]]] = [:], pageGate: Gate? = nil,
                         handlers: [ChatActionKind: ChatActionHandler] = [:], executor: TeamAgentRunner? = nil) async throws -> (ChatService, Transports) {
        let me = CallJSON.anna, org = self.org
        let state = Data(#"""
        {"org":{"org_id":"\#(org)","name":"Rabbitshat"},"members":[{"account_id":"\#(me)","handle":"anna","name":"Anna","role":"owner"}],
         "teams":[],"my_teams":[],"admin":null,"agents":[],
         "requests":[\#(requests.map(Self.text).joined(separator: ","))],"requests_next":\#(next.map { "\"\($0)\"" } ?? "null"),
         "streams":{"org:\#(org)":0,"member:\#(org):\#(me)":4,"device:\#(org):s-anna":4}}
        """#.utf8)
        let pageBodies = pages.mapValues { Data(#"{"requests":[\#($0.map(Self.text).joined(separator: ","))],"next":null}"#.utf8) }
        let meJSON = Data(#"""
        {"account_id":"\#(me)","session_id":"s-anna","orgs":[{"org_id":"\#(org)","org_name":"Rabbitshat","role":"owner","handle":"anna","name":"Anna"}],
         "streams":{"account:\#(me)":0}}
        """#.utf8)
        let info = Data(#"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","agents.calls"]}"#.utf8)
        ChatStubProtocol.reset { request, _ in
            switch request.url?.path {
            case "/v1/me": return .success(.init(status: 200, body: meJSON))
            case "/v1/server": return .success(.init(status: 200, body: info))
            case "/v1/orgs/\(org)/state": return .success(.init(status: 200, body: state))
            case "/v1/orgs/\(org)/requests":
                pageGate?.pass()
                let before = request.url?.query?.replacingOccurrences(of: "before=", with: "") ?? ""
                return .success(.init(status: 200, body: pageBodies[before] ?? Data(#"{"requests":[],"next":null}"#.utf8)))
            default: return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
            }
        }
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        let transports = Transports()
        service.makeSocketTransport = {
            let t = FakeSocketTransport()
            transports.all.append(t)
            return t
        }
        service.followsFeed = true
        service.retryDelay = { _ in 0.05 }
        service.actionHandlers = handlers
        if let executor { service.executorRunner = executor }
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-anna", deviceName: "Mac", orgId: org), token: "aps_t")
        try await service.start(mode: .server)
        try await waitUntil { !transports.all.isEmpty }
        try await connect(transports.all[0])
        return (service, transports)
    }

    /// A connection's hello, then each stream it asks for is subscribed at
    /// its head: the organization becomes ready.
    private func connect(_ transport: FakeSocketTransport) async throws {
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { !transport.subscribes.isEmpty }
        // Every stream asked for — the organization's and the account's,
        // whenever each is asked.
        var answered = 0
        for _ in 0..<5 {
            for streams in transport.subscribes.dropFirst(answered) {
                for (stream, head) in streams { transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(head)}"#) }
            }
            answered = transport.subscribes.count
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Check (1): a request that came by snapshot only

    /// The cache is empty and no `request.create` ever comes: the snapshot
    /// brings a request in `submitted` for this device, and a page the
    /// snapshot left out one in `awaiting_decision`; each gets its action and
    /// the action its handler.
    func testRequestThatCameOnlyBySnapshotReachesItsHandler() async throws {
        let page = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5c"
        let handler = RecordingActionHandler()
        let (service, _) = try await started(
            requests: [CallJSON.request(req, state: "submitted", version: 1, onThisDevice: true)], next: req,
            pages: [req: [CallJSON.request(page, state: "awaiting_decision", version: 2, onThisDevice: true)]],
            handlers: [.receive: handler, .notifyDecision: handler]
        )
        try await waitUntil { handler.seen.count == 2 }
        XCTAssertEqual(Set(handler.seen.map { "\($0.requestId) \($0.kind.rawValue)" }), ["\(req) receive", "\(page) notify_decision"])
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        XCTAssertEqual(try store.calls.request(req)?.onThisDevice, true)
        XCTAssertEqual(try store.cursor("device:\(org):s-anna"), 4)
    }

    // MARK: Review D8-2: generations

    /// A restored server counts again: its `starting`/v4 replaces the cache's
    /// `running`/v5 of the generation before; within the new one, versions
    /// compare again.
    func testRestoredServerReplacesLaterVersionsOfTheEarlierGeneration() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.setGeneration("g1")
        try store.apply(CallJSON.event(member, 1, "request.create", CallJSON.request(req, state: "running", version: 5)))
        try store.setPendingGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [member: 3], requests: [CallJSON.wire(CallJSON.request(req, state: "starting", version: 4))]))
        var request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.state, .starting)
        XCTAssertEqual(request.version, 4)
        try store.finishGeneration("g2")
        try store.apply(CallJSON.event(member, 4, "request.decide", CallJSON.request(req, state: "approved", version: 3, fixed: false)))
        request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.state, .starting, "an older version of the same generation changes nothing")
        try store.apply(CallJSON.event(member, 5, "run.started", CallJSON.request(req, state: "running", version: 5, fixed: false)))
        XCTAssertEqual(try store.calls.request(req)?.state, .running)
    }

    /// A page read on a connection that has since ended — of a server that
    /// may have been restored meanwhile — is not applied.
    func testLatePageOfAnEarlierConnectionIsNotApplied() async throws {
        let stale = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5c"
        let (service, transports) = try await started(requests: [CallJSON.request(req, state: "finished", version: 6)], next: req)
        let sync = try XCTUnwrap(service.orgSessions[anna]?.sync)
        try await waitUntil { !sync.needsSnapshot }
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        // The next snapshot's page is held, and would bring a request.
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        let org = self.org, req = self.req
        let state = Data(#"""
        {"org":{"org_id":"\#(org)","name":"Rabbitshat"},"members":[],"teams":[],"my_teams":[],"admin":null,"agents":[],
         "requests":[],"requests_next":"\#(req)","streams":{"member:\#(org):\#(CallJSON.anna)":4,"device:\#(org):s-anna":4}}
        """#.utf8)
        let page = Data(#"{"requests":[\#(Self.text(CallJSON.request(stale, state: "running", version: 9)))],"next":null}"#.utf8)
        // Only that one page brings it; pages read on later connections do not.
        let first = Budget()
        first.give(1)
        ChatStubProtocol.reset { request, _ in
            if request.url?.path.hasSuffix("/requests") == true {
                guard first.take() else { return .success(.init(status: 200, body: Data(#"{"requests":[],"next":null}"#.utf8))) }
                gate.pass()
                return .success(.init(status: 200, body: page))
            }
            if request.url?.path.hasSuffix("/state") == true { return .success(.init(status: 200, body: state)) }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/requests") == true } }
        // The connection ends while the page is out.
        transports.all[0].push(.closed(code: 1006))
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(try store.calls.request(stale))
    }

    // MARK: Review D8-3: a turn asked for while a handler runs

    func testRunnerTakesATurnAskedForWhileItsHandlerRan() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = PausedActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.turns == 1 }
        // Something changed while the handler was busy.
        runner.run()
        handler.release()
        try await waitUntil { handler.turns == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handler.turns, 2, "one more turn, not a loop")
    }

    // MARK: Review D8-4, D8-5: history

    /// History shows by the latest of a move and a delivery: an old request
    /// given its result now, and one moved by an event (then snapshotted at
    /// the same version), are shown; old final ones are not — their rows stay.
    func testFreshMovesAndResultsKeepOldRequests() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        func old(_ id: String, _ state: String, version: Int) -> [String: Any] {
            var body = CallJSON.request(id, state: state, version: version)
            body["created_at"] = "2026-01-01T00:00:00Z"
            body["updated_at"] = "2026-01-01T00:00:00Z"
            return body
        }
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            old("r-result", "finished", version: 6), old("r-moved", "running", version: 5), old("r-waiting", "finished", version: 6),
            old("r-gone", "declined", version: 3),
        ].map(CallJSON.wire)))
        try store.apply(CallJSON.event(member, 1, "result.deliver", [
            "request_id": "r-result", "run_id": "run-1", "text": "late", "truncated": false, "thread_id": NSNull(),
            "delivered_at": "2026-10-04T18:25:00Z",
        ]))
        try store.queue.write { db in try db.execute(sql: "UPDATE requests SET run_id = 'run-1' WHERE request_id = 'r-result'") }
        try store.apply(CallJSON.event(member, 2, "run.failed", CallJSON.request("r-moved", state: "failed", version: 6, fixed: false)))
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(old("r-moved", "failed", version: 6))]))
        let now = try XCTUnwrap(ChatStore.date("2026-10-05T00:00:00Z"))
        try store.calls.trim(now: now)
        XCTAssertEqual(Set(try store.calls.historyIds(now: now)), ["r-result", "r-moved"])
        XCTAssertEqual(Set(try store.calls.requestIds()), ["r-result", "r-moved", "r-waiting", "r-gone"], "rows stay")
        XCTAssertEqual(try store.calls.request("r-result")?.result?.text, "late")
    }


    /// 600 final requests within 30 days come by snapshot and page: once
    /// the cycle is done, 300 are kept — the newest.
    func testHistoryKeepsItsBoundAfterSnapshotAndPages() async throws {
        func final(_ i: Int) -> [String: Any] {
            var body = CallJSON.request(String(format: "00000000-0000-4000-8000-%012d", i), state: "declined", version: 3)
            body["updated_at"] = String(format: "2026-10-03T%02d:%02d:00Z", i / 60, i % 60)
            return body
        }
        let (service, _) = try await started(requests: (300..<600).map(final), next: "page", pages: ["page": (0..<300).map(final)])
        try await waitUntil { service.orgSessions[self.anna]?.sync?.needsSnapshot == false }
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/requests") == true } }
        try await Task.sleep(for: .milliseconds(200))
        let ids = try store.calls.historyIds()
        XCTAssertEqual(ids.count, 300)
        XCTAssertTrue(ids.contains(String(format: "00000000-0000-4000-8000-%012d", 599)))
        XCTAssertFalse(ids.contains(String(format: "00000000-0000-4000-8000-%012d", 0)))
    }

    // MARK: Review D8-1: TeamCalls on the cache

    /// As the app makes it: no calls while team work is off.
    /// `asks`: the record's path of `ask`, as D5's delivery will use it
    /// (the app refuses asks until then).
    private func team(runner: TeamAgentRunner = RecordingRunner(), asks: Bool = true) -> TeamService {
        let service = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")), runner: runner, offCalls: TeamOffCallStore())
        service.calls.deliversAsks = asks
        // The server's calls are served in server mode only (review D6-3).
        service.enterServerMode()
        return service
    }

    /// `team ask` in server mode: the address through the catalog and the
    /// members, no contacts; the call is the cache's request, and `check`
    /// sees the server's states and result.
    func testAskGoesThroughTheCatalogAndCheckSeesTheServer() async throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(
            cursors: [:],
            members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                      .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card(teams: [general])]
        ))
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: TeamCallOrigin(session: "s", project: "p"))
        XCTAssertEqual(call.agent, "billing")
        XCTAssertEqual(call.colleague, "Anna")
        XCTAssertEqual(call.peer, CallJSON.anna)
        XCTAssertEqual(call.report.state, .queued)
        XCTAssertFalse(call.delivered)
        XCTAssertEqual(call.scope, TeamCallScope(boris))
        XCTAssertEqual(try store.calls.request(call.id)?.askedHere, true)
        XCTAssertEqual(service.calls.outgoing.map(\.id), [call.id])
        XCTAssertThrowsError(try service.calls.ask("billing@nobody", prompt: "x", threadId: nil, origin: nil)) {
            XCTAssertEqual($0 as? TeamError, .refused("unknown_agent"))
        }
        // A thread not had with this agent from here: refused, nothing made (D5b §3.2).
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "x", threadId: UUID().uuidString, origin: nil)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("unknown thread") == true, "\($0)")
        }
        XCTAssertEqual(service.calls.outgoing.map(\.id), [call.id])

        let waiting = Task { try await service.calls.check(call.id, wait: 5) }
        let stream = "member:\(org):\(CallJSON.boris)"
        try store.apply(CallJSON.event(stream, 1, "request.create", CallJSON.request(call.id, state: "submitted", version: 1)))
        try store.apply(CallJSON.event(stream, 2, "run.finished", CallJSON.request(call.id, state: "finished", version: 6, fixed: false, runId: "run-1")))
        service.calls.reload()
        XCTAssertEqual(service.calls.outgoing.first?.report.state, .running, "finished, the text still to come")
        try store.apply(CallJSON.event(stream, 3, "result.deliver", [
            "request_id": call.id, "run_id": "run-1", "text": "Refunded twice by a retry.", "truncated": false,
            "thread_id": "t-1", "delivered_at": "2026-10-04T18:25:00Z",
        ]))
        service.calls.reload()
        let asked = ContinuousClock.now
        let seen = try await waiting.value
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(2), "a change wakes the waiter")
        XCTAssertNotNil(seen)
        let done = try await service.calls.check(call.id, wait: 0)
        XCTAssertEqual(done?.report.state, .done)
        XCTAssertEqual(done?.report.text, "Refunded twice by a retry.")
        XCTAssertEqual(done?.report.threadId, "t-1", "the thread to go on with (D5b)")
        // Going on with it: `thread_id` in the request.create.
        let next = try service.calls.ask("billing@anna", prompt: "And then?", threadId: "t-1", origin: nil)
        let create = try XCTUnwrap(store.outbox.commands().last { $0.type == "request.create" })
        let args = try JSONDecoder().decode(ChatCommandEnvelope.self, from: create.bodyBytes).args
        XCTAssertEqual(args["thread_id"], .string("t-1"))
        XCTAssertEqual(try store.calls.request(next.id)?.threadId, "t-1")
        // A thread of this account's call the snapshot brought (another Mac,
        // or a cache made anew: not asked here): it is this caller's (review D5b-3).
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-earlier", state: "finished", version: 6, owner: CallJSON.anna, initiator: CallJSON.boris)),
        ]))
        XCTAssertEqual(try store.calls.request("r-earlier")?.askedHere, false)
        XCTAssertNoThrow(try service.calls.ask("billing@anna", prompt: "Again?", threadId: "r-earlier", origin: nil))
        // Nothing of it is in the file store of 1.0.x.
        let json = (try? String(contentsOf: TeamStorage(directory: root.appendingPathComponent("team")).callsURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(json.contains(call.id))
    }

    /// Calls to my agents are the cache's requests too: what the snapshot
    /// brought is in `incoming`, with the caller's name and the server's
    /// version; clearing history is kept locally and the server's state is
    /// never written back.
    func testIncomingCallsAreTheCachesRequests() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(
            cursors: [:], members: [.init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card(teams: [general])],
            requests: [CallJSON.wire(CallJSON.request(req, state: "awaiting_decision", version: 2, onThisDevice: true)),
                       CallJSON.wire(CallJSON.request("r-done", state: "declined", version: 3))]
        ))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        let call = try XCTUnwrap(service.calls.incoming.first { $0.id == req })
        XCTAssertEqual(call.state, .awaitingApproval)
        XCTAssertEqual(call.peer, CallJSON.boris)
        XCTAssertEqual(call.peerName, "Boris")
        XCTAssertEqual(call.agentName, "billing")
        XCTAssertEqual(call.prompt, "Why twice?")
        XCTAssertEqual(call.version, 2)
        XCTAssertEqual(call.scope, TeamCallScope(anna))
        XCTAssertEqual(service.calls.awaitingDecision.map(\.id), [req])
        XCTAssertEqual(service.calls.outgoing, [])

        service.calls.clearHistory()
        service.calls.reload()
        XCTAssertEqual(service.calls.incoming.first { $0.id == "r-done" }?.hidden, true)
        XCTAssertEqual(try store.calls.request("r-done")?.state, .declined)
        XCTAssertEqual(try store.calls.request(req)?.state, .awaitingDecision)

        // No organization: no calls.
        service.calls.useServer(nil, key: nil)
        XCTAssertEqual(service.calls.incoming, [])
    }

    // MARK: Review D8b-2: turns do not breed turns

    func testRunnerTurnsDoNotBreedTurns() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        for (seq, id) in [(1, "r-a"), (2, "r-b")] {
            try store.apply(CallJSON.event("device:\(org):s-anna", seq, "request.create", CallJSON.request(id, state: "submitted", version: 1)),
                            facts: [id: ChatLocalFacts()])
        }
        let handler = PausedActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.turns == 2 }
        runner.run()
        handler.release()
        try await waitUntil { handler.turns == 4 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.turnsOf, ["r-a": 2, "r-b": 2], "one more turn each, then quiet")
    }

    // MARK: Review D8b-3: what a restored server no longer has

    /// The cache followed generation g0; the server is now g1 (restored)
    /// and lists nothing: the organization's server cache goes and is read
    /// anew (lead's decision after review D8h). A call asked here and sent
    /// is lost; one not yet sent stays; others' requests, results, the
    /// catalog and the actions go.
    func testANewGenerationReadsTheCacheAnew() async throws {
        let seed = try ChatStore.open(files: files, key: anna).store
        try seed.setGeneration("g0")
        try seed.apply(ChatSnapshot(
            cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
            agents: [CallJSON.card(teams: [general])]
        ))
        let sent = try seed.calls.createOutgoing(address: "billing@anna", text: "x", origin: nil, initiator: CallJSON.anna)
        let local = try seed.calls.createOutgoing(address: "billing@anna", text: "y", origin: nil, initiator: CallJSON.anna)
        try seed.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(sent.requestId, state: "running", version: 5, owner: CallJSON.anna, initiator: CallJSON.anna)),
            CallJSON.wire(CallJSON.request(req, state: "awaiting_decision", version: 2, onThisDevice: true)),
            CallJSON.wire(CallJSON.request("r-answered", state: "finished", version: 6, runId: "run-1",
                                           result: ["run_id": "run-1", "text": "ok", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"],
                                           owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]), facts: [req: ChatLocalFacts()])
        XCTAssertEqual(try actionKinds(seed), ["notify_decision"])
        let (service, _) = try await started(requests: [], next: nil)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { try store.calls.request(sent.requestId)?.state == .lost }
        XCTAssertEqual(try store.calls.request(local.requestId)?.state, .creating)
        XCTAssertNil(try store.calls.request(req), "another's request goes")
        XCTAssertNil(try store.calls.request("r-answered"))
        XCTAssertEqual(try actionKinds(store), ["notify_outcome"], "the lost call is told; the earlier actions went")
        try await store.queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM results"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM agents_catalog"), 0)
        }
        let team = team()
        team.calls.useServer(store.calls, key: anna)
        let call = try XCTUnwrap(team.calls.outgoing.first { $0.id == sent.requestId })
        XCTAssertEqual(call.report.state, .failed)
        XCTAssertEqual(call.report.detail, "The server no longer lists this call (restored from a backup, or ended long ago); its outcome is not known here.")
    }

    // MARK: Review D8b-4: the current organization's calls

    func testTeamCallsFollowTheCurrentOrganization() async throws {
        let other = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        var handed: [ChatOrgKey?] = []
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.onCallStore = { key, calls in
            XCTAssertEqual(key == nil, calls == nil)
            handed.append(key)
        }
        func signIn(_ key: ChatOrgKey) async throws {
            try service.saveSignIn(ChatConnection(server: server, accountId: key.accountId, sessionId: "s-anna", deviceName: "Mac", orgId: key.orgId),
                                   token: "aps_t")
            try await service.start(mode: .server)
        }
        try await signIn(anna)
        _ = service.session(for: other)
        XCTAssertEqual(handed, [anna], "a session of another organization changes nothing")
        try await signIn(other)
        try await signIn(anna)
        XCTAssertEqual(handed, [anna, other, anna])
        service.membershipLost(anna)
        XCTAssertEqual(handed, [anna, other, anna, nil])
        _ = service.session(for: anna)
        XCTAssertEqual(handed, [anna, other, anna, nil, anna], "its state made anew is handed again")
    }

    // MARK: Review D8b-5: history after ordinary moves and actions

    /// After an ordinary move to a final state, history still shows 300.
    func testHistoryBoundHoldsAfterAMove() async throws {
        func final(_ i: Int) -> [String: Any] {
            var body = CallJSON.request(String(format: "00000000-0000-4000-8000-%012d", i), state: "declined", version: 3)
            body["updated_at"] = String(format: "2026-10-03T%02d:%02d:00Z", i / 60, i % 60)
            return body
        }
        let open = CallJSON.request(req, state: "awaiting_decision", version: 2)
        let (service, transports) = try await started(requests: (0..<300).map(final) + [open], next: nil)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { try store.calls.historyIds().count == 301 }
        let decided = Self.text(CallJSON.request(req, state: "declined", version: 3, fixed: false))
        transports.all[0].frame(#"{"frame":"event","stream":"\#(member)","seq":5,"id":"e-5","type":"request.decide","actor":null,"body":\#(decided),"command_id":null,"at":"2026-10-04T18:20:00Z","sig":null,"sig_alg":null,"enc":null}"#)
        try await waitUntil { try store.calls.request(self.req)?.state == .declined }
        XCTAssertEqual(try store.calls.historyIds().count, 300)
        XCTAssertEqual(try store.calls.requestIds().count, 301, "no row goes")
    }

    /// The address comes back as it was asked: by the member's handle, not
    /// one made from the name — also after a rename.
    func testOutgoingAddressIsTheHandleItWasAskedBy() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(
            cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna Petrova", role: "owner")],
            agents: [CallJSON.card(teams: [general])]
        ))
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        let call = try service.calls.ask("billing@anna", prompt: "Why twice?", threadId: nil, origin: nil)
        XCTAssertEqual(call.address, "billing@anna")
        try store.apply(CallJSON.event("org:\(org)", 1, "member.set_name", ["account_id": CallJSON.anna, "name": "Anna K."]))
        service.calls.reload()
        XCTAssertEqual(service.calls.outgoing.first?.address, "billing@anna")
        XCTAssertEqual(service.calls.outgoing.first?.colleague, "Anna K.")
    }

    /// A call to my own agent is two calls in the Team tab; clearing one side
    /// leaves the other as it was.
    func testClearingOneSideOfACallToMyselfKeepsIt() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, initiator: CallJSON.anna))]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.incoming.first?.state, .done)
        XCTAssertEqual(service.calls.outgoing.first?.report.state, .running)
        service.calls.clearHistory()
        service.calls.reload()
        XCTAssertEqual(service.calls.incoming.first?.hidden, true)
        XCTAssertNil(service.calls.outgoing.first?.hidden)
    }

    /// Team work off: no calls, whatever files an earlier build left.
    func testTeamWorkOffShowsNoCalls() throws {
        let storage = TeamStorage(directory: root.appendingPathComponent("team"))
        try storage.prepareDirectory()
        let old = TeamCalls.Outgoing(id: "old", peer: "p", colleague: "Masha", agent: "a", prompt: "x", createdAt: Date(), deliverBy: Date(),
                                     report: TeamCallReport(callId: "old", state: .done))
        try storage.save(TeamCalls.Log(incoming: [], outgoing: [old]), to: storage.callsURL)
        let service = team()
        try service.calls.load()
        XCTAssertEqual(service.calls.outgoing, [])
        let store = try ChatStore.open(files: files, key: anna).store
        service.calls.useServer(store.calls, key: anna)
        service.calls.useServer(nil, key: nil)
        XCTAssertEqual(service.calls.outgoing, [])
    }

    // MARK: Reviews D8b-1, D8c-1: every action on a server's request is refused

    /// A link that records what the old protocol would send.
    @MainActor
    final class CountingLink: TeamCallLink {
        var colleagues: [TeamCaller] = []
        var sent: [TeamMessage] = []
        func send(_ message: TeamMessage, to colleague: String, timeout: Duration) async throws -> TeamMessage {
            sent.append(message)
            throw TeamError.timedOut
        }
    }

    /// Every action of `TeamCalls` and of the Team UI's handlers on a
    /// server's requests — incoming waiting, allowed, running here, done,
    /// running on another device; outgoing on its way — starts nothing (no
    /// run, no tab, no message of the old protocol) and changes nothing,
    /// in memory or in the cache. Only reading and clearing history act.
    func testEveryActionOnAServersRequestIsRefused() async throws {
        let runner = RecordingRunner()
        let service = team(runner: runner)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await service.calls.save(TeamPublishedAgent(name: "billing", description: "d", folder: project.path))
        let agent = try XCTUnwrap(service.calls.agents.first)
        func mine(_ id: String, _ state: String, _ version: Int, here: Bool = true) -> ChatRequestWire {
            var body = CallJSON.request(id, state: state, version: version, onThisDevice: here, initiator: CallJSON.boris)
            body["agent_id"] = agent.id.uuidString.lowercased()
            body["thread_id"] = UUID().uuidString.lowercased()
            // Past its deadline: the queue's own sweep would expire it.
            body["deliver_by"] = "2026-01-01T00:00:00Z"
            return CallJSON.wire(body)
        }
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(
            cursors: [:],
            members: [.init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card("helper", id: "a-helper", owner: CallJSON.boris, teams: [general])],
            requests: [mine("r-wait", "awaiting_decision", 2), mine("r-approved", "approved", 3), mine("r-running", "running", 5),
                       mine("r-done", "finished", 6), mine("r-elsewhere", "running", 5, here: false),
                       CallJSON.wire(CallJSON.request("r-out", state: "awaiting_decision", version: 2, owner: CallJSON.boris, initiator: CallJSON.anna))]
        ))
        service.calls.useServer(store.calls, key: anna)
        let link = CountingLink()
        link.colleagues = [TeamCaller(id: CallJSON.boris, displayName: "Boris")]
        service.calls.link = link
        // The old protocol is closed as a whole in server mode: a new call
        // (an id no record has) and the catalog too (review D8d-p1-1).
        for message in [TeamMessage(type: .callStart, callId: UUID().uuidString.lowercased(), agent: "billing", prompt: "x"),
                        TeamMessage(type: .catalogGet)] {
            let reply = await service.calls.handle(message, from: TeamCaller(id: CallJSON.boris, displayName: "Boris"))
            XCTAssertEqual(reply.type, .error)
        }
        let before = (service.calls.incoming, service.calls.outgoing.map(\.report))
        let rows = try store.calls.requests().map { "\($0.requestId) \($0.state.rawValue) \($0.version)" }
        var opened: [String] = []
        let saved = TeamUI.openTab
        TeamUI.openTab = { _, command, _ in opened.append(command) }
        defer { TeamUI.openTab = saved }

        for call in service.calls.incoming {
            XCTAssertTrue(call.localActionsRefused, call.id)
            let allowed = service.calls.decide(call.id, allow: true)
            let declined = service.calls.decide(call.id, allow: false, reason: "no")
            let stopped = service.calls.stop(call.id)
            let refusal = service.calls.refusal(.decide, for: call)
            XCTAssertNotNil(refusal)
            if call.state == .awaitingApproval { XCTAssertEqual([allowed, declined], [refusal, refusal]) }
            if !call.state.isFinal { XCTAssertEqual(stopped, refusal, call.id) }
            for type in [TeamMessage.Kind.callAttach, .callAck, .callCancel, .callStart] {
                let reply = await service.calls.handle(TeamMessage(type: type, callId: call.id, agent: "billing", prompt: "x"),
                                                       from: TeamCaller(id: CallJSON.boris, displayName: "Boris"))
                XCTAssertEqual(reply.type, .error, "\(type) \(call.id)")
            }
            if call.state == .running {
                do {
                    _ = try await service.calls.requestAccess(callId: call.id, path: project.path, reason: "x")
                    XCTFail("folders for \(call.id)")
                } catch {
                    XCTAssertEqual(error as? TeamError, .notYet(TeamServerCore.foldersNotYet))
                }
            }
            XCTAssertFalse(TeamUI.canWatch(call, in: service.calls))
            XCTAssertNotNil(TeamUI.watch(call, in: service.calls))
            XCTAssertNotNil(TeamUI.continueYourself(call, in: service.calls))
        }
        for call in service.calls.outgoing {
            XCTAssertTrue(call.localActionsRefused)
            XCTAssertEqual(service.calls.refusal(.cancel, for: call), TeamServerCore.cancelNotYet)
            let after = await service.calls.cancel(call.id)
            XCTAssertEqual(after, call, "unchanged")
        }
        // Load as at launch keeps the cache's word.
        try service.calls.load()
        service.calls.useServer(store.calls, key: anna)
        // Each checked at once: a later reload from the cache would hide it.
        service.calls.resume()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.calls.incoming, before.0, "resume")
        XCTAssertEqual(link.sent.map(\.type), [], "resume sends nothing of the old protocol")
        let notes = service.calls.outgoing.map(\.note)
        service.calls.stopAll()
        XCTAssertEqual(service.calls.incoming, before.0, "stopAll")
        XCTAssertEqual(service.calls.outgoing.map(\.note), notes, "stopAll")
        service.calls.sweep()
        await service.calls.drain()

        XCTAssertEqual(runner.requests.count, 0, "no run")
        XCTAssertEqual(opened, [], "no tab")
        XCTAssertEqual(link.sent.map(\.type), [], "no message of the old protocol")
        XCTAssertFalse(service.calls.hasRunningCalls)
        XCTAssertEqual(service.calls.incoming, before.0)
        XCTAssertEqual(service.calls.outgoing.map(\.report), before.1)
        service.calls.reload()
        XCTAssertEqual(service.calls.incoming, before.0)
        XCTAssertEqual(try store.calls.requests().map { "\($0.requestId) \($0.state.rawValue) \($0.version)" }, rows)

        // The check is what stops them: off the server, the same call of the
        // queue's own opens both tabs.
        var own = try XCTUnwrap(service.calls.incoming.first { $0.id == "r-done" })
        own.scope = nil
        let transcript = try ClaudeResumeFixture(id: own.threadId)
        service.calls.sessionFilesRoot = transcript.root
        service.leaveServerMode()
        service.calls.useServer(nil, key: nil)
        XCTAssertNil(TeamUI.watch(own, in: service.calls))
        XCTAssertNil(TeamUI.continueYourself(own, in: service.calls))
        XCTAssertEqual(opened.count, 2)
    }

    // MARK: Review D8c-3: the old organization is left at once

    /// A sign-in to another organization: `TeamCalls` leaves the old one as
    /// the connection changes, before anything awaits — a call asked then
    /// cannot land in the old organization.
    func testTeamCallsLeaveTheOldOrganizationAtOnce() async throws {
        let other = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        let team = team()
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.onCallStore = { key, calls in team.calls.useServer(calls, key: key) }
        try service.saveSignIn(ChatConnection(server: server, accountId: CallJSON.anna, sessionId: "s-anna", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        try await service.start(mode: .server)
        XCTAssertEqual(team.calls.serverKey, anna)
        var during: ChatOrgKey?? = .none
        service.closeRemoteSession = { _, _ in during = .some(team.calls.serverKey) }
        _ = try await service.completeSignIn(ChatSignIn(token: "aps_b", sessionId: "s-b", accountId: CallJSON.anna, orgs: []),
                                             server: server, deviceName: "Mac", orgId: other.orgId)
        XCTAssertNil(team.calls.serverKey)
        XCTAssertThrowsError(try team.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil)) {
            XCTAssertEqual($0 as? TeamError, .notConnected)
        }
        try await service.keepSignIn()
        if case .some(let key) = during { XCTAssertNil(key, "while the old session closes") }
    }

    // MARK: Review D8c-4: an action that ends wakes those waiting

    @MainActor
    final class ScriptedHandler: ChatActionHandler {
        var results: [String: ChatActionResult] = [:]
        private(set) var turnsOf: [String: Int] = [:]
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
            turnsOf[action.requestId, default: 0] += 1
            if turnsOf[action.requestId] == 1 { await withCheckedContinuation { held[action.requestId] = $0 } }
            return results[action.requestId] ?? .later
        }
        func release(_ id: String) { held.removeValue(forKey: id)?.resume() }
    }

    /// A and B run; B ends `done` (it may have freed what A waits for) while
    /// A still runs; then A ends `.later`: A gets one more turn, not none.
    func testAnActionThatEndsWakesTheOnesRunning() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        for (seq, id) in [(1, "r-a"), (2, "r-b")] {
            try store.apply(CallJSON.event("device:\(org):s-anna", seq, "request.create", CallJSON.request(id, state: "submitted", version: 1)),
                            facts: [id: ChatLocalFacts()])
        }
        let handler = ScriptedHandler()
        handler.results = ["r-b": .done]
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.turnsOf.count == 2 }
        handler.release("r-b")
        try await Task.sleep(for: .milliseconds(50))
        handler.release("r-a")
        try await waitUntil { handler.turnsOf["r-a"] == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.turnsOf, ["r-a": 2, "r-b": 1])
    }

    // MARK: Review D8d-p1-1: work of the queue's own does not outlive a move to the server

    /// A call of the old path runs (its runner held); team work moves to a
    /// server: the run is cancelled, its end starts nothing more, and no
    /// call of the old protocol gets in.
    func testTheQueuesOwnRunDoesNotGoOnUnderTheServer() async throws {
        let runner = RecordingRunner()
        runner.holds = true
        let owner = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("owner")), runner: runner)
        let caller = team()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await owner.calls.save(TeamPublishedAgent(name: "billing", description: "d", folder: project.path))
        let andrey = TeamCaller(id: "aaaa", displayName: "Andrey"), masha = TeamCaller(id: "bbbb", displayName: "Masha")
        let ownerLink = FakeCallLink(me: andrey), callerLink = FakeCallLink(me: masha)
        ownerLink.colleagues = [masha]
        ownerLink.peers[masha.id] = caller.calls
        callerLink.colleagues = [andrey]
        callerLink.peers[andrey.id] = owner.calls
        owner.calls.link = ownerLink
        caller.calls.useServer(nil, key: nil)
        let fileCaller = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("caller")))
        fileCaller.calls.link = callerLink
        callerLink.peers[andrey.id] = owner.calls
        _ = try fileCaller.calls.ask("billing@andrey", prompt: "hi", threadId: nil, origin: nil)
        try await waitUntil { owner.calls.awaitingDecision.count == 1 }
        owner.calls.decide(owner.calls.awaitingDecision[0].id, allow: true)
        try await waitUntil { runner.requests.count == 1 }

        // The server's cache happens to hold a running request with the same
        // id: the old run's end must not touch it.
        let store = try ChatStore.open(files: files, key: anna).store
        let id = try XCTUnwrap(owner.calls.incoming.first).id
        var same = CallJSON.request(id, state: "running", version: 5, onThisDevice: true)
        same["agent_id"] = try XCTUnwrap(owner.calls.agents.first).id.uuidString.lowercased()
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(same)]))
        owner.calls.useServer(store.calls, key: anna)
        runner.release()
        try await Task.sleep(for: .milliseconds(100))
        await owner.calls.drain()
        XCTAssertEqual(runner.requests.count, 1, "nothing carried on")
        XCTAssertFalse(owner.calls.hasRunningCalls)
        let reply = await owner.calls.handle(TeamMessage(type: .callStart, callId: UUID().uuidString.lowercased(), agent: "billing", prompt: "x"),
                                             from: masha)
        XCTAssertEqual(reply.type, .error)
        XCTAssertEqual(owner.calls.incoming.map(\.state), [.running], "the server's request as the cache has it")
        XCTAssertNil(owner.calls.incoming.first?.answer)
        _ = (ownerLink, callerLink, caller)
    }

    // MARK: Review D8d-p2-3, p2-5, p2-6: the runner's life

    /// One runner per organization for the life of the app: the state of
    /// the organization is made anew (another account signed in, then this
    /// one again), the runner stays, and a row its handler still runs is not
    /// run beside it (lead's decision after review D8e).
    func testOneRunnerPerOrganizationAndNoRowTwice() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        func signIn(_ account: String) async throws {
            try service.saveSignIn(ChatConnection(server: server, accountId: account, sessionId: "s-\(account.prefix(4))", deviceName: "Mac", orgId: org),
                                   token: "aps_t")
            try await service.start(mode: .server)
        }
        try await signIn(CallJSON.anna)
        let runner = service.runner(for: anna)
        runner.mayRun = { true }
        let handler = ScriptedHandler()
        handler.results = [req: .done]
        service.actionHandlers = [.receive: handler]
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        runner.run()
        try await waitUntil { handler.turnsOf[self.req] == 1 }
        try await signIn(CallJSON.boris)
        XCTAssertNil(service.orgSessions[anna])
        try await signIn(CallJSON.anna)
        XCTAssertTrue(service.orgSessions[anna]?.actions === runner, "the same runner")
        runner.run()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handler.turnsOf[req], 1, "not beside the handler still running")
        handler.release(req)
        try await waitUntil { try self.actionStates(XCTUnwrap(service.orgSessions[self.anna]?.store)) == ["done"] }
        XCTAssertEqual(handler.turnsOf[req], 1)
    }
    /// A handler that ends after its organization's state went writes to
    /// the cache its action came from — never to another one.
    func testAHandlerEndingAfterItsCacheWentWritesWhereItCameFrom() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let other = try ChatStore.open(files: files, key: boris).store
        try other.apply(CallJSON.event("device:\(org):s-boris", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = ScriptedHandler()
        handler.results = [req: .done]
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.turnsOf[self.req] == 1 }
        runner.attach(other.calls)
        handler.release(req)
        try await waitUntil { try self.actionStates(store) == ["done"] }
        // The other cache's row is its own: taken on its own turn, after.
        try await waitUntil { try self.actionStates(other) == ["done"] }
        XCTAssertEqual(handler.turnsOf[req], 2)
    }

    /// A result that could not be written is written again — the handler
    /// is not run again for it.
    func testAnUnwrittenResultIsWrittenAgainNotEarnedAgain() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.rewriteDelay = .milliseconds(50)
        var failing = true
        runner.writeFails = { state in failing && state == .done }
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.seen.count == 1 }
        try await Task.sleep(for: .milliseconds(120))
        runner.run()
        XCTAssertEqual(handler.seen.count, 1, "not run again")
        failing = false
        try await waitUntil { try self.actionStates(store) == ["done"] }
        XCTAssertEqual(handler.seen.count, 1)
    }

    private static func actionError(_ store: ChatStore, _ kind: String) throws -> String? {
        try store.queue.read { db in try String.fetchOne(db, sql: "SELECT error FROM actions WHERE kind = ?", arguments: [kind]) }
    }

    private func actionStates(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT state FROM actions ORDER BY kind") }
    }

    /// The connection is ready again with nothing new: what waited for it
    /// (`.later`) is handed over again.
    func testReadinessWakesActionsThatWaited() async throws {
        let handler = ScriptedHandler()
        let (service, transports) = try await started(
            requests: [CallJSON.request(req, state: "submitted", version: 1, onThisDevice: true)], next: nil,
            handlers: [.receive: handler]
        )
        try await waitUntil { handler.turnsOf[self.req] == 1 }
        handler.release(req)
        try await Task.sleep(for: .milliseconds(100))
        let before = handler.turnsOf[req] ?? 0
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(handler.turnsOf[req], before, "quiet: nothing new")
        // The socket drops and comes back, same generation, no new events.
        transports.all[0].push(.closed(code: 1006))
        try await waitUntil { transports.all.count == 2 }
        try await connect(transports.all[1])
        // Woken by the connection being ready again (one turn per wake), then quiet.
        try await waitUntil { (handler.turnsOf[self.req] ?? 0) > before }
        try await Task.sleep(for: .milliseconds(200))
        let after = handler.turnsOf[req] ?? 0
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(handler.turnsOf[req], after, "no loop")
        _ = service
    }

    /// Actions wait for the new generation's whole read: a request the
    /// restored server no longer has is not handed over first.
    func testActionsWaitForTheWholeRead() async throws {
        let seed = try ChatStore.open(files: files, key: anna).store
        try seed.setGeneration("g0")
        try seed.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "submitted", version: 1, onThisDevice: true))]),
                       facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let (service, _) = try await started(requests: [], next: nil, handlers: [.receive: handler])
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { try store.calls.request(self.req) == nil && service.isServerKnown(service, self.anna) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handler.seen.count, 0)
        // Read anew: what the earlier generation owed is gone with it.
        XCTAssertEqual(try actionKinds(store), [])
    }

    // MARK: Review D8d-p2-7, p2-9, p2-10, p2-11, p2-12, p3-7: the calls' store

    func testAnAskBegunInOneOrganizationIsNotMadeInAnother() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        let other = ChatOrgKey(server: server, accountId: CallJSON.boris, orgId: "00000000-0000-4000-8000-0000000000b2")
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil, area: .some(other)))
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil, area: .some(nil)))
        XCTAssertEqual(try store.calls.requestIds(), [])
        XCTAssertNoThrow(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil, area: .some(boris)))
    }

    struct BrokenStore: TeamCallStore {
        struct Broken: Error {}
        func loadLog() throws -> TeamCalls.Log { throw Broken() }
        func loadCall(_ id: String) throws -> TeamCalls.Log { throw Broken() }
        func saveLog(_ log: TeamCalls.Log) throws { throw Broken() }
        func loadThreads() throws -> [TeamCalls.Thread] { throw Broken() }
        func saveThreads(_ threads: [TeamCalls.Thread]) throws { throw Broken() }
    }

    /// A store that cannot be read shows nothing — not the calls before —
    /// says why, and is not written; waiters on calls that left wake.
    func testAnUnreadableStoreShowsNoCallsAndWakesWaiters() async throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        let broken = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")), offCalls: BrokenStore())
        broken.calls.deliversAsks = true
        broken.calls.useServer(store.calls, key: boris)
        let call = try broken.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil)
        let asked = ContinuousClock.now
        let waiting = Task { try await broken.calls.check(call.id, wait: 5) }
        try await Task.sleep(for: .milliseconds(50))
        broken.calls.useServer(nil, key: nil)
        _ = try? await waiting.value
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(2), "the waiter woke")
        XCTAssertEqual(broken.calls.outgoing, [])
        XCTAssertNotNil(broken.calls.storeProblem)
        XCTAssertFalse(broken.calls.clearHistory())
    }

    /// Names and the catalog changing in the cache reach the calls without a
    /// request event.
    func testNamesAndCatalogChangesReachTheCalls() async throws {
        let team = team()
        let (service, transports) = try await started(requests: [CallJSON.request(req, state: "finished", version: 6, owner: CallJSON.boris,
                                                                                  initiator: CallJSON.anna)], next: nil)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { try store.calls.request(self.req) != nil }
        team.calls.useServer(store.calls, key: anna)
        service.onCallsChanged = { (key: ChatOrgKey) in if team.calls.serverKey == key { team.calls.reload() } }
        XCTAssertEqual(team.calls.outgoing.first?.colleague.hasPrefix("(unknown member"), true)
        let joined = Self.text(["account_id": CallJSON.boris, "handle": "boris", "name": "Boris", "role": "member"])
        transports.all[0].frame(#"{"frame":"event","stream":"org:\#(org)","seq":1,"id":"e-1","type":"member.joined","actor":null,"body":\#(joined),"command_id":null,"at":"2026-10-04T18:20:00Z","sig":null,"sig_alg":null,"enc":null}"#)
        try await waitUntil { team.calls.outgoing.first?.colleague == "Boris" }
        XCTAssertEqual(team.calls.outgoing.first?.address.hasSuffix("@boris"), true)
    }

    // MARK: Review D8d-p3-6, p3-9

    /// The agent's name and owner's handle are kept once known: the catalog
    /// changing later does not change the address; never known, it says so.
    func testAnAddressIsKeptOrSaidUnknown() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(
            cursors: [:], members: [.init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            agents: [CallJSON.card("helper", id: "a-helper", owner: CallJSON.boris, teams: [general])],
            requests: [CallJSON.wire({ var b = CallJSON.request(req, state: "finished", version: 6, owner: CallJSON.boris, initiator: CallJSON.anna)
                                       b["agent_id"] = "a-helper"; return b }()),
                       CallJSON.wire({ var b = CallJSON.request("r-other", state: "finished", version: 6, owner: CallJSON.boris, initiator: CallJSON.anna)
                                       b["agent_id"] = "a-gone"; return b }())]
        ))
        try store.apply(ChatSnapshot(cursors: [:], agents: []))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.outgoing.first { $0.id == req }?.address, "helper@boris")
        XCTAssertEqual(service.calls.outgoing.first { $0.id == "r-other" }?.agent, "(unknown agent a-gone)")
    }

    func testARequestAnotherDeviceDecidesIsNotWaitingHere() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(req, state: "awaiting_decision", version: 2, onThisDevice: false)),
            CallJSON.wire(CallJSON.request("r-here", state: "awaiting_decision", version: 2, onThisDevice: true)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.awaitingDecision.map(\.id), ["r-here"])
        let elsewhere = try XCTUnwrap(service.calls.incoming.first { $0.id == req })
        XCTAssertEqual(service.calls.refusal(.decide, for: elsewhere), TeamServerCore.decidedElsewhere("Anna's Mac"))
    }

    // MARK: Review D8d group A: history and its tombstones

    private func finals(_ n: Int, day: String = "2026-10-03") -> [ChatRequestWire] {
        (0..<n).map { i in
            var body = CallJSON.request(String(format: "00000000-0000-4000-8000-%012d", i), state: "declined", version: 3)
            body["updated_at"] = String(format: "\(day)T%02d:%02d:00Z", i / 60, i % 60)
            return CallJSON.wire(body)
        }
    }

    private func actions(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT kind FROM actions ORDER BY kind") }
    }

    private func actionStatesAll(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT state FROM actions ORDER BY kind") }
    }

    /// A final request history no longer shows keeps its row — version and
    /// done actions: a late page of an older version rolls nothing back and
    /// owes nothing.
    func testATrimmedRequestKeepsOldWordsOut() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        var old = CallJSON.request(req, state: "declined", version: 3, onThisDevice: true)
        old["updated_at"] = "2026-10-01T00:00:00Z"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(old)] + finals(300)))
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO actions (request_id, kind, state, created_at, updated_at) VALUES (?, 'notify_decision', 'done', 0, 0)",
                           arguments: [self.req])
        }
        let now = try XCTUnwrap(ChatStore.date("2026-10-04T00:00:00Z"))
        try store.calls.trim(now: now)
        XCTAssertFalse(try store.calls.historyIds(now: now).contains(req))
        try store.apply(requests: [CallJSON.wire(CallJSON.request(req, state: "awaiting_decision", version: 2, onThisDevice: true))],
                        facts: [req: ChatLocalFacts()])
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.state, .declined)
        XCTAssertEqual(request.version, 3)
        XCTAssertEqual(try actions(store), ["notify_decision"])
        XCTAssertEqual(try actionStatesAll(store), ["done"])
    }

    /// Trim takes the heavy texts of what history no longer shows, unless
    /// an action of it is not done.
    func testTrimTakesHeavyTextsOfWhatIsNotShown() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        func old(_ id: String) -> ChatRequestWire {
            var body = CallJSON.request(id, state: "finished", version: 6, runId: "run-\(id)",
                                        result: ["run_id": "run-\(id)", "text": "long answer", "truncated": false, "thread_id": NSNull(),
                                                 "delivered_at": "2026-01-01T00:00:00Z"])
            body["updated_at"] = "2026-01-01T00:00:00Z"
            return CallJSON.wire(body)
        }
        try store.apply(ChatSnapshot(cursors: [:], requests: [old("r-a"), old("r-b")]))
        try store.calls.setLocal("r-a", text: "full", log: "/log", runId: "run-r-a")
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO actions (request_id, kind, state, created_at, updated_at) VALUES ('r-b', 'notify_outcome', 'pending', 0, 0)")
        }
        try store.calls.trim(now: try XCTUnwrap(ChatStore.date("2026-10-04T00:00:00Z")))
        XCTAssertEqual(try store.calls.request("r-a")?.result?.text, "")
        XCTAssertNil(try store.calls.request("r-a")?.localText)
        XCTAssertEqual(try store.calls.request("r-b")?.result?.text, "long answer", "its action may need it")
    }

    /// A result given now to a request finished long ago comes as
    /// `request.snapshot`, then `result.deliver` — with history pruned after
    /// each event, the result reaches the call.
    func testALateResultReachesARequestLongFinished() async throws {
        let team = team()
        let seed = try ChatStore.open(files: files, key: anna).store
        var old = CallJSON.request(req, state: "finished", version: 6, runId: "run-1", owner: CallJSON.boris, initiator: CallJSON.anna)
        old["created_at"] = "2026-08-01T00:00:00Z"
        old["updated_at"] = "2026-08-01T00:00:00Z"
        try seed.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(old)]))
        let (service, transports) = try await started(requests: [], next: nil)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        team.calls.useServer(store.calls, key: anna)
        service.onCallsChanged = { (key: ChatOrgKey) in if team.calls.serverKey == key { team.calls.reload() } }
        let snapshot = Self.text(old)
        let result = Self.text(["request_id": req, "run_id": "run-1", "text": "late but here", "truncated": false, "thread_id": NSNull(),
                                "delivered_at": "2026-10-04T18:25:00Z"])
        transports.all[0].frame(#"{"frame":"event","stream":"\#(member)","seq":5,"id":"e-5","type":"request.snapshot","actor":null,"body":\#(snapshot),"command_id":null,"at":"2026-10-04T18:24:59Z","sig":null,"sig_alg":null,"enc":null}"#)
        transports.all[0].frame(#"{"frame":"event","stream":"\#(member)","seq":6,"id":"e-6","type":"result.deliver","actor":null,"body":\#(result),"command_id":null,"at":"2026-10-04T18:25:00Z","sig":null,"sig_alg":null,"enc":null}"#)
        try await waitUntil { team.calls.outgoing.first { $0.id == self.req }?.report.state == .done }
        XCTAssertEqual(team.calls.outgoing.first { $0.id == self.req }?.report.text, "late but here")
    }

    /// Within one generation, absence from a read means nothing: a request
    /// this Mac holds as running stays running.
    func testAbsenceWithinOneGenerationMeansNothing() async throws {
        let seed = try ChatStore.open(files: files, key: anna).store
        try seed.setGeneration("g1")
        try seed.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 5, owner: CallJSON.boris,
                                                                                            initiator: CallJSON.anna))]))
        let (service, _) = try await started(requests: [], next: nil)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try await waitUntil { service.orgSessions[self.anna]?.sync?.state == .ready }
        XCTAssertEqual(try store.calls.request(req)?.state, .running)
    }


    // MARK: Review D8d-p3-4, p1-2: CLI answers with the refusal

    func testTheCLIGetsTheRefusalForCancelAndWatch() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "awaiting_decision", version: 2, owner: CallJSON.boris, initiator: CallJSON.anna)),
            CallJSON.wire(CallJSON.request(req, state: "running", version: 5, onThisDevice: true)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        var cancel = AgentPadCLIRequest(verb: .team)
        cancel.teamAction = AgentPadCLITeamAction.cancel.rawValue
        cancel.teamCall = "r-out"
        let refused = await TeamCLIHandler.handle(cancel, service: service)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error, "\(TeamServerCore.cancelNotYet) Call r-out goes on.")
        XCTAssertEqual(refused.team?.call?.id, "r-out")
        XCTAssertEqual(refused.team?.call?.final, false)
        var watch = AgentPadCLIRequest(verb: .team)
        watch.teamAction = AgentPadCLITeamAction.watch.rawValue
        watch.teamCall = req
        let notWatched = await TeamCLIHandler.handle(watch, service: service)
        XCTAssertFalse(notWatched.ok)
        XCTAssertEqual(notWatched.error, TeamServerCore.watchNotYet)
        var access = AgentPadCLIRequest(verb: .team)
        access.teamAction = AgentPadCLITeamAction.access.rawValue
        access.teamCall = req
        access.teamFolder = "/tmp"
        let folders = await TeamCLIHandler.handle(access, service: service)
        XCTAssertEqual(folders.error, TeamServerCore.foldersNotYet)
    }

    // MARK: Review D8d-p2-5: a failed Disconnect does not stop actions for good


    /// The same, with history trimmed between the two events: the row is
    /// still there, and the result shows with it.
    func testTrimmingBetweenTheSnapshotAndTheResultKeepsTheRequest() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        var old = CallJSON.request(req, state: "finished", version: 6, runId: "run-1", owner: CallJSON.boris, initiator: CallJSON.anna)
        old["created_at"] = "2026-08-01T00:00:00Z"
        old["updated_at"] = "2026-08-01T00:00:00Z"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(old)]))
        let now = try XCTUnwrap(ChatStore.date("2026-10-04T18:25:00Z"))
        try store.apply(CallJSON.event(member, 1, "request.snapshot", old))
        try store.calls.trim(now: now)
        try store.apply(CallJSON.event(member, 2, "result.deliver", [
            "request_id": req, "run_id": "run-1", "text": "late but here", "truncated": false, "thread_id": NSNull(),
            "delivered_at": "2026-10-04T18:25:00Z",
        ]))
        try store.calls.trim(now: now)
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertTrue(request.hasFixed)
        XCTAssertEqual(request.result?.text, "late but here")
        XCTAssertTrue(try store.calls.historyIds(now: now).contains(req))
    }

    /// A call asked here, lost over a new generation, takes the new
    /// generation's word when it lists it.
    func testACallAskedHereTakesTheNewGenerationsWord() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        try store.setGeneration("g1")
        let sent = try store.calls.createOutgoing(address: "billing@anna", text: "x", origin: nil, initiator: CallJSON.anna)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(sent.requestId, state: "running", version: 5,
                                                                                              owner: CallJSON.anna, initiator: CallJSON.anna))]))
        try store.beginGeneration("g2")
        XCTAssertEqual(try store.calls.request(sent.requestId)?.state, .resyncing)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(sent.requestId, state: "submitted", version: 1,
                                                                                              owner: CallJSON.anna, initiator: CallJSON.anna))]))
        let request = try XCTUnwrap(store.calls.request(sent.requestId))
        XCTAssertEqual(request.state, .submitted)
        XCTAssertEqual(request.version, 1)
        XCTAssertTrue(request.askedHere)
    }


    // MARK: Review D8e: after the simplification

    /// Server mode without an organization's cache (not opened, lost
    /// membership): the old path stays closed — fail closed (review D8e-p1-1).
    func testServerModeWithoutACacheIsClosed() async throws {
        let runner = RecordingRunner()
        let service = team(runner: runner)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await service.calls.save(TeamPublishedAgent(name: "billing", description: "d", folder: project.path))
        let link = FakeCallLink(me: TeamCaller(id: "aaaa", displayName: "Anna"))
        link.colleagues = [TeamCaller(id: "x", displayName: "X")]
        service.calls.link = link
        await service.load(mode: .server)
        XCTAssertNil(service.calls.serverKey)
        let reply = await service.calls.handle(TeamMessage(type: .callStart, callId: UUID().uuidString.lowercased(), agent: "billing", prompt: "x"),
                                               from: TeamCaller(id: "x", displayName: "X"))
        XCTAssertEqual(reply.type, .error)
        XCTAssertEqual(service.calls.incoming, [])
        XCTAssertThrowsError(try service.calls.ask("billing@x", prompt: "x", threadId: nil, origin: nil)) {
            XCTAssertEqual($0 as? TeamError, .notConnected)
        }
        XCTAssertEqual(runner.requests.count, 0)
        _ = link
    }

    /// The queue's own call running on this Mac, its runner held.
    private func runningCallOfTheQueue() async throws -> (owner: TeamService, runner: RecordingRunner, id: String, extra: URL, links: [AnyObject]) {
        let runner = RecordingRunner()
        runner.holds = true
        let owner = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("owner")), runner: runner)
        let project = root.appendingPathComponent("project"), extra = root.appendingPathComponent("extra")
        for dir in [project, extra] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try await owner.calls.save(TeamPublishedAgent(name: "billing", description: "d", folder: project.path))
        let andrey = TeamCaller(id: "aaaa", displayName: "Andrey"), masha = TeamCaller(id: "bbbb", displayName: "Masha")
        let ownerLink = FakeCallLink(me: andrey), callerLink = FakeCallLink(me: masha)
        let caller = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("caller")))
        ownerLink.peers[masha.id] = caller.calls
        callerLink.colleagues = [andrey]
        callerLink.peers[andrey.id] = owner.calls
        owner.calls.link = ownerLink
        caller.calls.link = callerLink
        _ = try caller.calls.ask("billing@andrey", prompt: "hi", threadId: nil, origin: nil)
        try await waitUntil { owner.calls.awaitingDecision.count == 1 }
        let id = owner.calls.awaitingDecision[0].id
        owner.calls.decide(id, allow: true)
        try await waitUntil { runner.requests.count == 1 }
        return (owner, runner, id, extra, [ownerLink, callerLink, caller.calls])
    }

    /// A folder decision begun before team work moved to a server gives
    /// nothing after it: no folder kept, no grant (review D8e-p1-2).
    func testAFolderDecisionThatOutlivesTheMoveGivesNothing() async throws {
        let (owner, runner, id, extra, links) = try await runningCallOfTheQueue()
        let asked = try await owner.calls.requestAccess(callId: id, path: extra.path, reason: "needs it")
        let store = try ChatStore.open(files: files, key: anna).store
        // Team work moves to a server while the folder is being checked.
        owner.calls.afterFolderCheck = { owner.calls.useServer(store.calls, key: self.anna) }
        let problem = await owner.calls.decideAccess(asked.id, .always)
        XCTAssertNotNil(problem)
        XCTAssertEqual(owner.calls.agents.first?.extraFolders ?? [], [], "no folder kept")
        XCTAssertEqual(owner.calls.accessRequests.first?.state, .denied)
        runner.release()
        await owner.calls.drain()
        XCTAssertEqual(runner.requests.count, 1, "nothing carried on with it")
        _ = links
    }

    /// A folder request whose check outlives a move to a server — where a
    /// request of the same id and agent runs — makes no request (review D8f-p1-2).
    func testAFolderRequestThatOutlivesTheMoveMakesNone() async throws {
        let (owner, runner, id, extra, links) = try await runningCallOfTheQueue()
        let store = try ChatStore.open(files: files, key: anna).store
        var same = CallJSON.request(id, state: "running", version: 5, onThisDevice: true)
        same["agent_id"] = try XCTUnwrap(owner.calls.agents.first).id.uuidString.lowercased()
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(same)]))
        owner.calls.afterFolderCheck = { owner.calls.useServer(store.calls, key: self.anna) }
        do {
            _ = try await owner.calls.requestAccess(callId: id, path: extra.path, reason: "needs it")
            XCTFail("a folder request across the move")
        } catch {}
        XCTAssertEqual(owner.calls.accessRequests, [])
        runner.release()
        await owner.calls.drain()
        XCTAssertEqual(runner.requests.count, 1)
        _ = links
    }

    /// A result written only on a later try settles the action like the
    /// first try would: the runner goes on to what is due (review D8e-p2-9).
    func testAResultWrittenLaterSettlesTheAction() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.rewriteDelay = .milliseconds(50)
        var failing = true
        runner.writeFails = { state in failing && state == .done }
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.seen.count == 1 }
        // Due meanwhile, with no outside signal after it.
        try store.apply(CallJSON.event("device:\(org):s-anna", 2, "request.create", CallJSON.request("r-next", state: "submitted", version: 1)),
                        facts: ["r-next": ChatLocalFacts()])
        failing = false
        try await waitUntil { handler.seen.count == 2 }
        XCTAssertEqual(handler.seen.last?.requestId, "r-next")
    }

    /// The result answers the request's current run only (review D8e-p3-7).
    func testAResultOfAnEarlierRunDoesNotAnswer() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        let earlier: [String: Any] = ["run_id": "run-1", "text": "old run", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"]
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: "run-2",
                                                                                             result: earlier))]))
        XCTAssertNil(try store.calls.request(req)?.result)
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        XCTAssertEqual(service.calls.outgoing.first?.report.state, .running, "its own result is still to come")
    }

    /// The calls could not be read: the CLI says so, not "no such call";
    /// a final call's cancel answers its outcome (review D8e-p3-10, p3-11).
    func testTheCLITellsAnUnreadableStoreAndAFinalCallsOutcome() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "declined", version: 3, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        var cancel = AgentPadCLIRequest(verb: .team)
        cancel.teamAction = AgentPadCLITeamAction.cancel.rawValue
        cancel.teamCall = "r-out"
        let answered = await TeamCLIHandler.handle(cancel, service: service)
        XCTAssertTrue(answered.ok)
        XCTAssertEqual(answered.team?.call?.state, "denied")
        let broken = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("broken")), offCalls: BrokenStore())
        broken.enterServerMode()
        broken.calls.useServer(nil, key: nil)
        var check = AgentPadCLIRequest(verb: .team)
        check.teamAction = AgentPadCLITeamAction.check.rawValue
        check.teamCall = "r-out"
        let failed = await TeamCLIHandler.handle(check, service: broken)
        XCTAssertEqual(failed.error, broken.calls.storeProblem)
        XCTAssertNotNil(failed.error)
    }

    /// A call made and kept comes back with its id even when the calls
    /// cannot be read again (review D8e-p2-10).
    func testAnAskKeptReturnsItsIdWhenTheCallsCannotBeReadAgain() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        try store.queue.write { db in try db.execute(sql: "DROP TABLE threads") }
        let call = try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil)
        XCTAssertNotNil(try store.calls.request(call.id))
        XCTAssertEqual(call.address, "billing@anna")
    }

    /// The states as the Team tab shows them: a request not yet received
    /// asks no decision; `starting` is running (review D8e-p3-12).
    func testStatesAsTheTeamTabShowsThem() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-sub", state: "submitted", version: 1, onThisDevice: true)),
            CallJSON.wire(CallJSON.request("r-start", state: "starting", version: 4, onThisDevice: true)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.incoming.first { $0.id == "r-sub" }?.state, .queued)
        XCTAssertEqual(service.calls.awaitingDecision, [])
        XCTAssertEqual(service.calls.incoming.first { $0.id == "r-start" }?.state, .running)
    }

    // MARK: Server states of D2b and unknown ones

    /// The states the server added (D2b) show as what they are — final
    /// ones final, with the server's words — and a state this build does
    /// not know is said to be unknown, not final, and waited on no longer
    /// than asked.
    func testNewAndUnknownStatesShowAsWhatTheyAre() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        func mine(_ id: String, _ state: String) -> ChatRequestWire {
            CallJSON.wire(CallJSON.request(id, state: state, version: 7, owner: CallJSON.boris, initiator: CallJSON.anna))
        }
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            mine("r-cancelled", "cancelled"), mine("r-expired", "expired"), mine("r-stopped", "stopped"),
            { var w = mine("r-stop-failed", "stop_failed"); w.failureReason = "kill failed"; return w }(), mine("r-stopping", "stop_requested"), mine("r-new", "paused_by_moon"),
            mine(req, "awaiting_decision"),
        ]))
        try store.apply(CallJSON.event(member, 1, "request.expired", CallJSON.request(req, state: "expired", version: 8, fixed: false)))
        // An event with `cause` (D7) applies; the cause itself is shown from D4/D5.
        try store.apply(ChatSnapshot(cursors: [:], requests: [mine("r-caused", "awaiting_decision")]))
        var declined = CallJSON.request("r-caused", state: "declined", version: 9, fixed: false)
        declined["cause"] = "agent_disabled"
        XCTAssertEqual(try store.apply(CallJSON.event(member, 2, "request.decide", declined)), .applied)
        XCTAssertEqual(try store.calls.request("r-caused")?.state, .declined)
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        func report(_ id: String) -> TeamCallReport? { service.calls.outgoing.first { $0.id == id }?.report }
        XCTAssertEqual(report("r-cancelled")?.state, .cancelled)
        XCTAssertEqual(report("r-cancelled")?.detail, "The initiator cancelled it before it ran.")
        XCTAssertEqual(report("r-expired")?.state, .expired)
        XCTAssertEqual(report(req)?.state, .expired, "request.expired applied")
        XCTAssertEqual(report("r-stopped")?.state, .cancelled)
        XCTAssertEqual(report("r-stopped")?.detail, "The run was stopped before it finished.")
        XCTAssertEqual(report("r-stop-failed")?.state, .failed)
        XCTAssertEqual(report("r-stop-failed")?.detail, "The run was asked to stop, but its processes could not be stopped (kill failed).")
        XCTAssertEqual(report("r-stopping")?.state, .running)
        XCTAssertEqual(report("r-stopping")?.detail, "Someone asked to stop the run; the owner's Mac is stopping it.")
        XCTAssertEqual(report("r-new")?.state, .unknown)
        XCTAssertFalse(TeamCallState.unknown.isFinal)
        XCTAssertTrue(report("r-new")?.detail?.contains("paused_by_moon") == true)
        let asked = ContinuousClock.now
        _ = try await service.calls.check("r-new", wait: 1)
        XCTAssertLessThan(ContinuousClock.now - asked, .seconds(3), "waited on no longer than asked")
        // A frame the client does not know is passed over; an ephemeral one is read as a hint (D4b).
        if case .unknown = try ChatFrame.decode(Data(#"{"frame":"moonbeam"}"#.utf8)) {} else { XCTFail("an unknown frame") }
        XCTAssertEqual(try ChatFrame.decode(Data(#"{"frame":"ephemeral","type":"run.activity","org_id":"o","body":{"request_id":"r","text":"Grep"}}"#.utf8)),
                       .ephemeral(org: "o", type: "run.activity", body: .object(["request_id": .string("r"), "text": .string("Grep")])))
    }

    // MARK: Review D8f

    /// A new generation reads the cache anew: every action is owed again
    /// from the journal's facts — a notification may be shown once more
    /// (lead's decision after review D8h).
    func testANewGenerationIsOwedItsActionsAgain() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.setGeneration("g1")
        let device = "device:\(org):s-anna"
        try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)), facts: [req: ChatLocalFacts()])
        try store.apply(CallJSON.event(device, 2, "request.create", CallJSON.request("r-wait", state: "awaiting_decision", version: 2)),
                        facts: ["r-wait": ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.seen.count == 2 }
        // Restored: g2 lists them as they were before.
        try store.beginGeneration("g2")
        XCTAssertEqual(try store.cursors(), [:])
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(req, state: "submitted", version: 1, onThisDevice: true)),
            CallJSON.wire(CallJSON.request("r-wait", state: "awaiting_decision", version: 2, onThisDevice: true)),
        ]), facts: [req: ChatLocalFacts(), "r-wait": ChatLocalFacts()])
        runner.run()
        try await waitUntil { handler.seen.count == 4 }
        XCTAssertEqual(Set(handler.seen.suffix(2).map(\.kind)), [.receive, .notifyDecision])
    }


    /// The cache could not be read, or a row taken: the runner tries again
    /// by itself (review D8f-p2-4).
    func testTheRunnerTriesAgainAfterAFailedReadOrTake() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.rewriteDelay = .milliseconds(50)
        var readFails = true, takeFails = true
        runner.readFails = { readFails }
        runner.writeFails = { state in takeFails && state == .inProgress }
        runner.handler = { _ in handler }
        runner.run()
        try await Task.sleep(for: .milliseconds(30))
        readFails = false
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(handler.seen.count, 0, "taking it fails yet")
        takeFails = false
        try await waitUntil { handler.seen.count == 1 }
    }

    /// The journal could not be read when a request came: its reconcile is
    /// owed and done later (review D8f-p2-5).
    func testAJournalReadThatFailedIsReconciledLater() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        try service.saveSignIn(ChatConnection(server: server, accountId: CallJSON.anna, sessionId: "s-anna", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        service.reconcileDelay = .milliseconds(50)
        let store = try XCTUnwrap(service.session(for: anna).store)
        var failing = true
        service.journalReadFails = { failing }
        let facts = service.localFacts(anna, [req])
        XCTAssertNil(facts)
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)), facts: facts)
        XCTAssertEqual(try actionKinds(store), [])
        failing = false
        try await waitUntil { try self.actionKinds(store) == ["receive"] }
    }

    nonisolated private func actionState(_ store: ChatStore, _ kind: String) throws -> String? {
        try store.queue.read { db in try String.fetchOne(db, sql: "SELECT state FROM actions WHERE kind = ?", arguments: [kind]) }
    }

    private func actionKinds(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT kind FROM actions ORDER BY kind") }
    }

    /// Events of later types are not lost: a request's changing part and a
    /// card on a team stream apply (review D8f-p3-1).
    func testTheKnownPartOfALaterEventApplies() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event(member, 1, "request.create", CallJSON.request(req, state: "running", version: 5)))
        // Applied as far as known, and not taken for the whole: a snapshot follows (review D8g-p3-3).
        XCTAssertEqual(try store.apply(CallJSON.event(member, 2, "run.paused_later", CallJSON.request(req, state: "paused", version: 6, fixed: false))),
                       .passedOver)
        XCTAssertEqual(try store.calls.request(req)?.state.rawValue, "paused")
        let card = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CallJSON.card("billing-new"))) as! [String: Any]
        try store.apply(CallJSON.event("team:\(general)", 1, "agent.renamed_later", card))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["billing-new"])
        var disabled = card
        disabled["enabled"] = false
        try store.apply(CallJSON.event("team:\(general)", 2, "agent.disable", disabled))
        XCTAssertEqual(try store.calls.catalog().first?.enabled, false)
    }

    /// Two team streams tell an agent's card in any order: the catalog keeps
    /// the latest, also when a stream that fell behind leaves (review D8f-p2-6).
    func testTheCatalogKeepsTheLatestCardWhateverTheOrder() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        let ops = "00000000-0000-4000-8000-0000000000c2"
        func card(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(CallJSON.card(name))) as! [String: Any]
        }
        func event(_ team: String, _ seq: Int, _ type: String, _ body: [String: Any], at: String) -> ChatEvent {
            ChatEvent(stream: "team:\(team)", seq: seq, id: UUID().uuidString, type: type, actor: nil, body: CallJSON.json(body), commandId: nil, at: at)
        }
        // Within a stream its order, not the server's clock (review D8g-p2-7).
        try store.apply(event(general, 1, "agent.publish", try card("old"), at: "2026-10-04T11:00:00Z"))
        try store.apply(event(general, 2, "agent.publish", try card("new"), at: "2026-10-04T10:59:59.5Z"))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["new"])
        try store.apply(event(ops, 1, "agent.publish", try card("old"), at: "2026-10-04T10:00:00Z"))
        try store.apply(event(ops, 2, "agent.unpublish", ["agent_id": CallJSON.agent], at: "2026-10-04T11:00:00Z"))
        XCTAssertEqual(try store.calls.catalog().map(\.name), ["new"])
    }

    /// The local full text is the run's it came from (review D8f-p3-4).
    func testTheLocalFullTextIsTheCurrentRunsOnly() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: "run-a"))]))
        try store.calls.setLocal(req, text: "answer of A", log: "/a.jsonl", runId: "run-a")
        XCTAssertEqual(try store.calls.request(req)?.localText, "answer of A")
        try store.setPendingGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 3, runId: "run-b",
            result: ["run_id": "run-b", "text": "answer of B", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"]))]))
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertNil(request.localText)
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.incoming.first?.answer?.text, "answer of B")
    }

    /// A call out of history's view is still read by id; one awaiting its
    /// result stays in view; a trimmed answer says so (review D8f-p2-7, p3-3, p3-8).
    func testHistoryIsAViewNotALimitOnCalls() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        var old = CallJSON.request("r-old", state: "declined", version: 3, owner: CallJSON.boris, initiator: CallJSON.anna)
        old["updated_at"] = "2026-01-01T00:00:00Z"
        var awaiting = CallJSON.request("r-await", state: "finished", version: 6, runId: "run-1", owner: CallJSON.boris, initiator: CallJSON.anna)
        awaiting["updated_at"] = "2026-10-01T00:00:00Z"
        var trimmed = CallJSON.request("r-trim", state: "finished", version: 6, runId: "run-t",
                                       result: ["run_id": "run-t", "text": "long", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-01-01T00:00:00Z"],
                                       owner: CallJSON.boris, initiator: CallJSON.anna)
        trimmed["updated_at"] = "2026-01-01T00:00:00Z"
        var newer = (0..<300).map { i -> [String: Any] in
            var body = CallJSON.request(String(format: "00000000-0000-4000-8000-%012d", i), state: "declined", version: 3, owner: CallJSON.boris,
                                        initiator: CallJSON.anna)
            body["updated_at"] = String(format: "2026-10-03T%02d:%02d:00Z", i / 60, i % 60)
            return body
        }
        newer += [old, awaiting, trimmed]
        try store.apply(ChatSnapshot(cursors: [:], requests: newer.map(CallJSON.wire)))
        try store.calls.trim()
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertNil(service.calls.outgoing.first { $0.id == "r-old" }, "out of view")
        XCTAssertNotNil(service.calls.outgoing.first { $0.id == "r-await" }, "awaiting its result: in view")
        let checked = try await service.calls.check("r-old", wait: 0)
        XCTAssertEqual(checked?.report.state, .denied)
        let gone = try await service.calls.check("r-trim", wait: 0)
        XCTAssertEqual(gone?.report.text, "[The answer is no longer kept on this Mac: history limit.]")
        XCTAssertEqual(gone?.report.truncated, true)
    }

    /// Until D5 sends them, `ask` in server mode says so (review D8f-p3-7).
    func testAskRefusesUntilTheServersDeliveryIsIn() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        let service = team(asks: false)
        service.calls.useServer(store.calls, key: boris)
        XCTAssertThrowsError(try service.calls.ask("billing@anna", prompt: "x", threadId: nil, origin: nil)) {
            XCTAssertEqual($0 as? TeamError, .notYet(TeamServerCore.askNotYet))
        }
        XCTAssertEqual(try store.calls.requestIds(), [])
    }

    /// CLI: watching a call not found is no; colleagues' agents in server
    /// mode come from the organization's catalog by `name@handle`, without
    /// the member's own (review D8f-p1-1, D3 answer (а)).
    func testTheCLIRefusesAnUnknownWatchAndListsTheCatalog() async throws {
        let service = team()
        var watch = AgentPadCLIRequest(verb: .team)
        watch.teamAction = AgentPadCLITeamAction.watch.rawValue
        watch.teamCall = UUID().uuidString.lowercased()
        let unknown = await TeamCLIHandler.handle(watch, service: service)
        XCTAssertFalse(unknown.ok)
        let store = try ChatStore.open(files: files, key: boris).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                                                             .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
                                     agents: [CallJSON.card(teams: [general]),
                                              CallJSON.card("mine", id: "a-boris", owner: CallJSON.boris, teams: [general])]))
        service.calls.useServer(store.calls, key: boris)
        var agents = AgentPadCLIRequest(verb: .team)
        agents.teamAction = AgentPadCLITeamAction.agents.rawValue
        let listed = await TeamCLIHandler.handle(agents, service: service)
        XCTAssertTrue(listed.ok, listed.error ?? "")
        XCTAssertEqual(listed.team?.agents?.map(\.address), ["billing@anna"])
        XCTAssertEqual(listed.team?.agents?.first?.colleague, "Anna")
        XCTAssertEqual(listed.team?.agents?.first?.access, "read")
    }

    // MARK: Review D8g


    /// No second instance of an action because the generation was not
    /// known yet when it was first owed (review D8g-p2-2).
    func testAnActionOwedBeforeTheGenerationIsKnownIsOne() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        try store.finishGeneration("g1")
        try store.reconcileAll(facts: [req: ChatLocalFacts()])
        XCTAssertEqual(try actionKinds(store), ["receive"])
    }

    /// A task whose cache was let go of before it began does not begin; a
    /// check that could not be read is tried again (review D8g-p2-3, p2-4).
    func testATaskBeginsOnlyInItsCacheAndAFailedCheckIsTriedAgain() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(CallJSON.event("device:\(org):s-anna", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        runner.attach(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(handler.seen.count, 0, "its cache went before it began")
        runner.rewriteDelay = .milliseconds(50)
        var failing = true
        runner.checkFails = { failing }
        runner.attach(store.calls)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(handler.seen.count, 0)
        failing = false
        try await waitUntil { handler.seen.count == 1 }
    }

    /// A result owed to a cache let go of does not hold the same row of
    /// another cache (review D8g-p2-5).
    func testADebtToAnotherCacheDoesNotHoldThisOne() async throws {
        let first = try ChatStore.open(files: files, key: anna).store
        let second = try ChatStore.open(files: files, key: boris).store
        for store in [first, second] {
            try store.apply(CallJSON.event("device:\(org):s", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                            facts: [req: ChatLocalFacts()])
        }
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: first.calls)
        runner.writeFails = { $0 == .done }
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.seen.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        // The first cache stays unwritable: its debt stays.
        runner.rewriteDelay = .seconds(60)
        runner.attach(second.calls)
        try await waitUntil { handler.seen.count == 2 }
    }

    /// A wait whose calls changed meanwhile (another organization) ends and
    /// says so — never another store's call of the same id (review
    /// D8g-p2-8, D8h-p2-7, p3-4).
    func testACheckWhoseCallsChangedEnds() async throws {
        let first = try ChatStore.open(files: files, key: anna).store
        let second = try ChatStore.open(files: files, key: ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")).store
        try first.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        try second.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "declined", version: 3, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        let service = team()
        service.calls.useServer(first.calls, key: anna)
        let waiting = Task { try await service.calls.check(self.req, wait: 2) }
        try await Task.sleep(for: .milliseconds(50))
        service.calls.useServer(second.calls, key: ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2"))
        do {
            _ = try await waiting.value
            XCTFail("the wait ends")
        } catch {
            XCTAssertEqual(error as? TeamError, .scopeChanged)
        }
    }

    /// The rounds of one follow (MCP `team_check`, CLI `team ask`) carry the
    /// calls they began in: a round after the calls changed is refused, not
    /// answered from the other organization (review D8h-p2-7).
    func testTheRoundsOfAFollowKeepTheirCalls() async throws {
        let otherKey = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        let first = try ChatStore.open(files: files, key: anna).store
        let second = try ChatStore.open(files: files, key: otherKey).store
        try first.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        try second.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "declined", version: 3, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        let service = team()
        service.calls.useServer(first.calls, key: anna)
        var check = AgentPadCLIRequest(verb: .team)
        check.teamAction = AgentPadCLITeamAction.check.rawValue
        check.teamCall = req
        let round1 = await TeamCLIHandler.handle(check, service: service)
        let scope = try XCTUnwrap(round1.team?.call?.scope)
        service.calls.useServer(second.calls, key: otherKey)
        check.teamScope = scope
        let round2 = await TeamCLIHandler.handle(check, service: service)
        XCTAssertFalse(round2.ok)
        XCTAssertEqual(round2.error, TeamError.scopeChanged.errorDescription)
        XCTAssertNil(round2.team?.call)
    }

    /// A restored server that lost a result this Mac delivered is owed it
    /// again — also when the cache held that result from the earlier
    /// generation: the cache is read anew (review D8g-p3-1, D8h-p2-5, p3-1).
    func testAResultTakenByAnEarlierGenerationIsOwedAgain() throws {
        let journal = try ChatJournal.open(files: files)
        try journal.finish(anna, "g1")
        let runId = try finishedHere(journal, root: root)
        try deliverCommand(journal, runId: runId, state: .sent, generation: "g1")
        XCTAssertEqual(try journal.facts(anna, requestIds: [req]) { _ in false }[req]?.resultUndelivered, false)
        let store = try ChatStore.open(files: files, key: anna).store
        try store.setGeneration("g1")
        let result: [String: Any] = ["run_id": runId, "text": "ok", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"]
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: runId,
                                                                                              onThisDevice: true, result: result))]))
        // Restored before the delivery.
        try journal.setPending(anna, "g2")
        try store.beginGeneration("g2")
        let facts = try journal.facts(anna, requestIds: [req]) { _ in false }
        XCTAssertEqual(facts[req]?.resultUndelivered, true)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: runId,
                                                                                              onThisDevice: true))]), facts: facts)
        XCTAssertEqual(try actionKinds(store), ["deliver"])
        // The restored server has it: nothing owed.
        try store.beginGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: runId,
                                                                                              onThisDevice: true, result: result))]), facts: facts)
        XCTAssertEqual(try actionKinds(store), [])
    }

    /// The duty to deliver is the result kept: a delivery refused (`403`
    /// while the earlier session is open), or never sent, stays owed — in
    /// this generation and after a restart (review D4b-p2-1).
    func testARefusedDeliveryStaysOwed() throws {
        for (state, error) in [(ChatCommandRecord.State.failed, "forbidden"), (.pending, nil), (.unconfirmed, nil)] {
            let root = self.root.appendingPathComponent(UUID().uuidString)
            let journal = try ChatJournal.open(files: ChatFiles(directory: root.appendingPathComponent("chat")))
            try journal.finish(anna, "g1")
            let runId = try finishedHere(journal, root: root)
            try deliverCommand(journal, runId: runId, state: state, generation: nil, error: error)
            XCTAssertEqual(try journal.facts(anna, requestIds: [req]) { _ in false }[req]?.resultUndelivered, true, "\(state)")
        }
    }

    /// A run that finished here with its result, in a journal of its own.
    private func finishedHere(_ journal: ChatJournal, root: URL) throws -> String {
        let f = try ExecutorFixture(root: root, runner: RecordingRunner(), key: anna, journal: journal)
        f.request = TeamLaunchRequest(requestId: req, prompt: "x", context: nil, callerName: "Boris", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let approval = try f.approve()
        let runId = try TeamLaunchParams.decode(approval.params).runId
        XCTAssertTrue(try journal.consume(approval, run: ChatRunRecord(runId: runId, requestId: req, approvalId: approval.id, agentId: approval.agentId,
                                                                        conversationId: "c", pid: 1, pgid: 1, processStartedAt: 1, startedAt: Date())))
        XCTAssertTrue(try journal.finish(runId, .finished, result: "ok"))
        return runId
    }

    private func deliverCommand(_ journal: ChatJournal, runId: String, state: ChatCommandRecord.State, generation: String?, error: String? = nil) throws {
        let body = try ChatCommandEnvelope(commandId: "c-deliver", org: org, type: "result.deliver",
                                           args: .object(["request_id": .string(req), "run_id": .string(runId), "text": .string("ok")])).encoded()
        var command = ChatCommandRecord(commandId: "c-deliver", sessionId: "s", type: "result.deliver", bodyBytes: body,
                                        orderKey: "exec:run:\(runId)", dependsOn: nil, createdAt: Date(), state: state)
        command.sentGeneration = generation
        command.error = error
        try journal.enqueue(command, key: anna)
    }

    /// A run that ended here, whose end the server now does not have — told
    /// to an earlier generation, left unconfirmed, or `run.failed_to_start`
    /// — is told again (`recover`) from any state before the end, whenever
    /// the earlier answer was stored; nothing runs again. Within one
    /// generation an end on its way owes nothing (review D8h-p3-1, D8i-p2-3, p3-4).
    func testARunEndTheServerDoesNotHaveIsToldAgain() throws {
        func check(_ type: String, _ commandState: ChatCommandRecord.State, sentIn: String?, outcome: ChatRunRecord.Outcome,
                   serverState: String, owed: Bool, line: UInt = #line) throws {
            let root = self.root.appendingPathComponent(UUID().uuidString)
            let files = ChatFiles(directory: root.appendingPathComponent("chat"))
            let journal = try ChatJournal.open(files: files)
            try journal.finish(anna, "g1")
            let f = try ExecutorFixture(root: root, runner: RecordingRunner(), key: anna, journal: journal)
            f.request = TeamLaunchRequest(requestId: req, prompt: "x", context: nil, callerName: "Boris", callerProject: nil,
                                          conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
            let approval = try f.approve()
            let runId = try TeamLaunchParams.decode(approval.params).runId
            XCTAssertTrue(try journal.consume(approval, run: ChatRunRecord(runId: runId, requestId: req, approvalId: approval.id, agentId: approval.agentId,
                                                                            conversationId: "c", pid: nil, pgid: nil, processStartedAt: nil, startedAt: Date())))
            let body = try ChatCommandEnvelope(commandId: "c-end", org: org, type: type,
                                               args: .object(["request_id": .string(req), "run_id": .string(runId), "reason": .string("x")])).encoded()
            var command = ChatCommandRecord(commandId: "c-end", sessionId: "s", type: type, bodyBytes: body, orderKey: "exec:run:\(runId)",
                                            dependsOn: nil, createdAt: Date(), state: commandState)
            command.sentGeneration = sentIn
            try journal.finish(runId, outcome) { db in _ = try journal.runCommands(self.anna).insert(db, command, seq: command.seq) }
            try journal.setPending(anna, "g2")
            let facts = try journal.facts(anna, requestIds: [req]) { _ in false }
            let store = try ChatStore.open(files: files, key: anna).store
            try store.beginGeneration("g2")
            try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: serverState, version: 5, runId: runId,
                                                                                                  onThisDevice: true))]), facts: facts)
            XCTAssertEqual(try actionKinds(store), owed ? ["recover"] : [], "\(type) \(commandState) \(serverState)", line: line)
        }
        try check("run.finished", .sent, sentIn: "g1", outcome: .finished, serverState: "running", owed: true)
        try check("run.failed", .unconfirmed, sentIn: nil, outcome: .failed, serverState: "running", owed: true)
        try check("run.failed_to_start", .sent, sentIn: "g1", outcome: .didNotStart, serverState: "starting", owed: true)
        try check("run.finished", .sent, sentIn: "g1", outcome: .finished, serverState: "stop_requested", owed: true)
        // The new server has its end: nothing.
        try check("run.finished", .sent, sentIn: "g1", outcome: .finished, serverState: "failed", owed: false)
        // On its way to the server now: nothing.
        try check("run.finished", .pending, sentIn: nil, outcome: .finished, serverState: "running", owed: false)
        try check("run.finished", .sent, sentIn: "g2", outcome: .finished, serverState: "running", owed: false)
    }

    // MARK: Review D8h

    /// A cache deleted and made anew at the same path is another file: a
    /// debt to the old one does not hold the new one's row; the same file
    /// opened again is held (review D8h-p2-2).
    func testADebtToADeletedCacheDoesNotHoldTheOneMadeAnew() async throws {
        let first = try ChatStore.open(files: files, key: anna).store
        try first.apply(CallJSON.event("device:\(org):s", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: first.calls)
        runner.rewriteDelay = .seconds(60)
        // The old file stays unwritable: its debt is never paid.
        runner.writeFails = { $0 == .done }
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.seen.count == 1 }
        // The same file, opened again: its row is held by the debt.
        runner.attach(try ChatStore.open(files: files, key: anna).store.calls)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(handler.seen.count, 1, "the result is owed to this file, not earned again")
        // Deleted and made anew at the same path (membership lost and back).
        runner.attach(nil)
        try FileManager.default.removeItem(at: files.cacheURL(anna))
        let second = try ChatStore.open(files: files, key: anna).store
        try second.apply(CallJSON.event("device:\(org):s", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                         facts: [req: ChatLocalFacts()])
        runner.attach(second.calls)
        try await waitUntil { handler.seen.count == 2 }
    }

    /// A state that no longer owes an action voids it in the transaction
    /// that wrote it: a handler taken before does not begin; one that
    /// begins gets the request as it is now (review D8h-p2-4).
    func testAHandlerNeverBeginsOnAStateGoneBy() async throws {
        let store = try ChatStore.open(files: files, key: anna).store
        let device = "device:\(org):s-anna"
        try store.apply(CallJSON.event(device, 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)), facts: [req: ChatLocalFacts()])
        let handler = RecordingActionHandler()
        let runner = ChatActionRunner(key: anna, calls: store.calls)
        runner.handler = { _ in handler }
        runner.run()
        // Taken; before its task begins the owner's decision comes.
        try store.apply(CallJSON.event(device, 2, "request.decide", CallJSON.request(req, state: "declined", version: 3, fixed: false)),
                        facts: [req: ChatLocalFacts()])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(handler.seen.count, 0)
        XCTAssertEqual(try Self.actionError(store, "receive"), "no_longer_owed")
        // One that begins: the request as the cache has it then.
        try store.apply(CallJSON.event(device, 3, "request.create", CallJSON.request("r-2", state: "awaiting_decision", version: 2)),
                        facts: ["r-2": ChatLocalFacts()])
        // Changed after it was taken, before its task begins (no wait between).
        func change() throws { try store.queue.write { db in try db.execute(sql: "UPDATE requests SET failure_reason = 'now' WHERE request_id = 'r-2'") } }
        runner.run()
        try change()
        try await waitUntil { handler.seen.count == 1 }
        XCTAssertEqual(handler.requests.first?.failureReason, "now")
    }

    /// Clear History hides only what is final in the cache now, and a
    /// request open again is shown again (review D8h-p2-6, p3-3).
    func testClearingHistoryHidesOnlyWhatIsFinal() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(req, state: "declined", version: 3, onThisDevice: true)),
            CallJSON.wire(CallJSON.request("r-back", state: "declined", version: 3, onThisDevice: true)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(service.calls.incoming.count, 2)
        // The view holds both as final; the cache meanwhile has one open again.
        try store.queue.write { db in try db.execute(sql: "UPDATE requests SET state = 'running' WHERE request_id = 'r-back'") }
        XCTAssertTrue(service.calls.clearHistory())
        XCTAssertEqual(service.calls.incoming.filter { $0.hidden != true }.map(\.id), ["r-back"])
        XCTAssertEqual(try store.calls.request(req)?.hiddenIncoming, true)
        XCTAssertEqual(try store.calls.request("r-back")?.hiddenIncoming, false)
        // A hidden one the server moves on again (a restored server) is shown.
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 9, onThisDevice: true))]))
        XCTAssertEqual(try store.calls.request(req)?.hiddenIncoming, false)
    }

    /// A late write of an earlier run never replaces the current run's
    /// full text and log (review D8h-p2-8).
    func testALateLocalWriteOfAnEarlierRunChangesNothing() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 5, runId: "run-B"))]))
        try store.calls.setLocal(req, text: "B", log: "/b", runId: "run-B")
        try store.calls.setLocal(req, text: "A", log: "/a", runId: "run-A")
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertEqual(request.localText, "B")
        XCTAssertEqual(request.localLog, "/b")
        // Before the server names a run, the run kept first holds it.
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request("r-2", state: "approved", version: 3))]))
        try store.calls.setLocal("r-2", text: nil, log: "/c", runId: "run-C")
        try store.calls.setLocal("r-2", text: nil, log: "/d", runId: "run-D")
        try store.queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT local_log FROM requests WHERE request_id = 'r-2'"), "/c")
        }
    }

    /// A fixed part short of a field its contract requires is not taken:
    /// the snapshot after it brings the whole (review D8h-p3-2).
    func testAnIncompleteFixedPartIsCompletedLater() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        var partial = CallJSON.request(req, state: "submitted", version: 1)
        partial["conditions_version"] = nil
        partial["deliver_by"] = nil
        partial["created_at"] = nil
        try store.apply(CallJSON.event(member, 1, "request.later_kind", partial))
        XCTAssertEqual(try store.calls.request(req)?.hasFixed, false)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "submitted", version: 1))]))
        let request = try XCTUnwrap(store.calls.request(req))
        XCTAssertTrue(request.hasFixed)
        XCTAssertEqual(request.conditionsVersion, 1)
        XCTAssertEqual(request.deliverBy, "2026-10-11T18:20:00.123456Z")
        XCTAssertEqual(request.createdAt, "2026-10-04T18:20:00.123456Z")
    }

    /// Ages are times, not text: fractions of different length order as
    /// times (review D8h-p3-6).
    func testHistoryAgesCompareAsTimes() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        func final(_ id: String, _ at: String) -> ChatRequestWire {
            var body = CallJSON.request(id, state: "declined", version: 3)
            body["updated_at"] = at
            return CallJSON.wire(body)
        }
        var wires = (0..<299).map { final(String(format: "r-%03d", $0), "2026-10-04T12:00:00.5Z") }
        // As text ".123Z" sorts after ".123456Z"; as times it is the earlier.
        wires.append(final("r-later", "2026-10-04T00:00:00.123456Z"))
        wires.append(final("r-earlier", "2026-10-04T00:00:00.123Z"))
        try store.apply(ChatSnapshot(cursors: [:], requests: wires))
        let now = try XCTUnwrap(ChatStore.date("2026-10-05T00:00:00Z"))
        let shown = Set(try store.calls.historyIds(now: now))
        XCTAssertTrue(shown.contains("r-later"))
        XCTAssertFalse(shown.contains("r-earlier"))
        // The 30 days likewise.
        let edge = try XCTUnwrap(ChatStore.date("2026-11-03T00:00:00.1234Z"))
        XCTAssertTrue(Set(try store.calls.historyIds(now: edge)).contains("r-later"))
        XCTAssertEqual(ChatStore.date("2026-10-04T00:00:00.123456Z")!.timeIntervalSince(ChatStore.date("2026-10-04T00:00:00.123Z")!),
                       0.000456, accuracy: 0.000_01)
    }

    /// The right panel's cards say what a state means, as the other views
    /// do (review D8h-p3-5).
    func testThePanelCardsSayWhatAStateMeans() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(req, state: "stop_requested", version: 7, onThisDevice: true)),
            CallJSON.wire(CallJSON.request("r-out", state: "paused_by_server", version: 4, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        let incoming = try XCTUnwrap(service.calls.incoming.first { $0.id == req })
        let detail = try XCTUnwrap(incoming.detail)
        XCTAssertTrue(TeamPanelSection.details(incoming, agent: nil).contains(detail))
        let outgoing = try XCTUnwrap(service.calls.outgoing.first { $0.id == "r-out" })
        let said = TeamPanelSection.outgoingDetails(outgoing).joined(separator: " ")
        XCTAssertTrue(said.contains("paused_by_server"), said)
    }

    // MARK: Review D8i

    /// A call asked here waits while the new generation is read — not
    /// final, nothing told; listed on a later page, it takes the server's
    /// word; one the whole read did not list is lost then (review D8i-p2-1,
    /// p3-1, p3-3).
    func testACallAskedHereWaitsForTheWholeReadOfANewGeneration() async throws {
        let seed = try ChatStore.open(files: files, key: anna).store
        try seed.setGeneration("g0")
        try seed.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                    agents: [CallJSON.card(teams: [general])]))
        let back = try seed.calls.createOutgoing(address: "billing@anna", text: "x", origin: nil, initiator: CallJSON.anna)
        let gone = try seed.calls.createOutgoing(address: "billing@anna", text: "y", origin: nil, initiator: CallJSON.anna)
        var old = CallJSON.request(back.requestId, state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna)
        old["executor_device_name"] = "Old Mac"
        try seed.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(old),
            CallJSON.wire(CallJSON.request(gone.requestId, state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        // The first read (before the hello) goes; the new generation's waits.
        let gate = Gate()
        gate.close()
        gate.letThrough(1)
        var listed = CallJSON.request(back.requestId, state: "submitted", version: 1, owner: CallJSON.boris, initiator: CallJSON.anna)
        listed["executor_device_name"] = "New Mac"
        let starting = Task { try await self.started(requests: [], next: "page", pages: ["page": [listed]], pageGate: gate) }
        // The hello of g1 begins the new generation; its read waits on the page.
        let store = try ChatStore.open(files: files, key: anna).store
        try await waitUntil { try store.calls.request(back.requestId)?.state == .resyncing }
        let team = team()
        team.calls.useServer(store.calls, key: anna)
        let waiting = try XCTUnwrap(team.calls.outgoing.first { $0.id == back.requestId })
        XCTAssertFalse(waiting.report.state.isFinal, "not an outcome while the read goes on")
        XCTAssertEqual(try actionKinds(store), [])
        gate.open()
        _ = try await starting.value
        try await waitUntil { try store.calls.request(gone.requestId)?.state == .lost }
        let request = try XCTUnwrap(store.calls.request(back.requestId))
        XCTAssertEqual(request.state, .submitted)
        XCTAssertEqual(request.executorDeviceName, "New Mac", "the new server's fixed part")
        func told() throws -> [String] {
            try store.queue.read { db in try String.fetchAll(db, sql: "SELECT request_id FROM actions WHERE kind = 'notify_outcome'") }
        }
        XCTAssertEqual(try told(), [gone.requestId], "told of the lost one only")
    }

    /// A call asked here and over keeps its outcome, its result and its
    /// shown notification over a new generation that no longer lists it
    /// (review D8i-p3-2).
    func testAFinishedCallAskedHereStaysFinished() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner")],
                                     agents: [CallJSON.card(teams: [general])]))
        try store.setGeneration("g1")
        let call = try store.calls.createOutgoing(address: "billing@anna", text: "x", origin: nil, initiator: CallJSON.anna)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(call.requestId, state: "finished", version: 6, runId: "run-1",
            result: ["run_id": "run-1", "text": "ok", "truncated": false, "thread_id": NSNull(), "delivered_at": "2026-10-04T18:25:00Z"],
            owner: CallJSON.boris, initiator: CallJSON.anna))]), facts: [call.requestId: ChatLocalFacts()])
        try store.queue.write { db in try db.execute(sql: "UPDATE actions SET state = 'done'") }
        try store.beginGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: []), facts: [:])
        try store.endResync(facts: [:])
        let request = try XCTUnwrap(store.calls.request(call.requestId))
        XCTAssertEqual(request.state, .finished)
        XCTAssertEqual(request.result?.text, "ok")
        XCTAssertEqual(try actionStatesAll(store), ["done"], "not told again")
        // One not yet told, whose outcome a new generation undoes: not told.
        try store.queue.write { db in try db.execute(sql: "UPDATE actions SET state = 'pending'") }
        try store.beginGeneration("g3")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(call.requestId, state: "running", version: 5,
                                                                                              owner: CallJSON.boris, initiator: CallJSON.anna))]), facts: [:])
        XCTAssertEqual(try Self.actionError(store, "notify_outcome"), "no_longer_owed")
    }

    /// A run of this Mac without an outcome keeps its request over a new
    /// generation; one the new server does not list is lost, and its outcome
    /// is written without a fact (review D8i-p2-5).
    func testARunHereKeepsItsRequestOverANewGeneration() async throws {
        let journal = try ChatJournal.open(files: files)
        try journal.finish(anna, "g1")
        let f = try ExecutorFixture(root: root.appendingPathComponent("executor"), runner: RecordingRunner(), key: anna, journal: journal)
        f.request = TeamLaunchRequest(requestId: req, prompt: "x", context: nil, callerName: "Boris", callerProject: nil,
                                      conversationId: nil, expiresAt: f.now.addingTimeInterval(3600))
        let approval = try f.approve()
        let runId = try TeamLaunchParams.decode(approval.params).runId
        XCTAssertTrue(try journal.consume(approval, run: ChatRunRecord(runId: runId, requestId: req, approvalId: approval.id, agentId: approval.agentId,
                                                                        conversationId: "c", pid: nil, pgid: nil, processStartedAt: nil, startedAt: Date())))
        XCTAssertEqual(try journal.runningRequests(anna), [req])
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "running", version: 5, runId: runId, onThisDevice: true))]))
        try store.beginGeneration("g2", keeping: try journal.runningRequests(anna))
        XCTAssertEqual(try store.calls.request(req)?.state, .resyncing)
        let team = team()
        team.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(team.calls.incoming.map(\.id), [req], "shown while it is read anew")
        try store.endResync(facts: [:])
        XCTAssertEqual(try store.calls.request(req)?.state, .lost)
        // Its facts: none is owed to a server that does not have the request,
        // nor chosen while it is read anew (the outcome is written alone).
        _ = approval
        XCTAssertEqual(ChatFactChain.plan(state: .lost, outcome: .executorRestarted, hasResult: false, answered: false), [])
        XCTAssertEqual(ChatFactChain.plan(state: .resyncing, outcome: .executorRestarted, hasResult: false, answered: false), [])
    }

    /// A debt given up wakes the runner: the new cache's row waiting on the
    /// old handler runs then (review D8i-p2-2).
    func testADebtGivenUpWakesTheRunner() async throws {
        let first = try ChatStore.open(files: files, key: anna).store
        try first.apply(CallJSON.event("device:\(org):s", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                        facts: [req: ChatLocalFacts()])
        let handler = GatedActionHandler()
        let runner = ChatActionRunner(key: anna, calls: first.calls)
        runner.rewriteDelay = .milliseconds(50)
        runner.writeFails = { $0 == .done }
        runner.handler = { _ in handler }
        runner.run()
        try await waitUntil { handler.began == 1 }
        // Meanwhile the cache is deleted and made anew; its row waits on the old handler.
        runner.attach(nil)
        try FileManager.default.removeItem(at: files.cacheURL(anna))
        let second = try ChatStore.open(files: files, key: anna).store
        try second.apply(CallJSON.event("device:\(org):s", 1, "request.create", CallJSON.request(req, state: "submitted", version: 1)),
                         facts: [req: ChatLocalFacts()])
        runner.attach(second.calls)
        handler.release()
        try await waitUntil { handler.began == 2 }
    }

    /// Clear History does not hide a call this Mac sent that waits for its
    /// result, and one back to waiting is shown (review D8i-p2-4).
    func testClearingHistoryKeepsACallWaitingForItsResult() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request(req, state: "declined", version: 3, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        // The view holds it as final; the cache has it finished, its result on its way.
        try store.queue.write { db in try db.execute(sql: "UPDATE requests SET state = 'finished', run_id = 'run-1' WHERE request_id = ?", arguments: [self.req]) }
        XCTAssertTrue(service.calls.clearHistory())
        XCTAssertEqual(try store.calls.request(req)?.hiddenOutgoing, false)
        // Hidden when over, then back to waiting for a result: shown.
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "declined", version: 9, owner: CallJSON.boris, initiator: CallJSON.anna))]))
        service.calls.reload()
        XCTAssertTrue(service.calls.clearHistory())
        XCTAssertEqual(try store.calls.request(req)?.hiddenOutgoing, true)
        // Asked here: kept as history over the new generation, hidden.
        try store.queue.write { db in try db.execute(sql: "UPDATE requests SET asked_here = 1 WHERE request_id = ?", arguments: [self.req]) }
        try store.beginGeneration("g2")
        XCTAssertEqual(try store.calls.request(req)?.hiddenOutgoing, true)
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "finished", version: 6, runId: "run-2",
                                                                                              owner: CallJSON.boris, initiator: CallJSON.anna))]))
        XCTAssertEqual(try store.calls.request(req)?.hiddenOutgoing, false)
    }

    /// Each field of the fixed part, missing, keeps it open (review D8i-p3-5).
    func testEveryRequiredFixedFieldIsNeeded() throws {
        for field in ["kind", "agent_id", "owner_account_id", "initiator_account_id", "text", "executor_device_name",
                      "conditions_version", "deliver_by", "created_at"] {
            var body = CallJSON.request(req, state: "submitted", version: 1)
            body[field] = nil
            XCTAssertFalse(CallJSON.wire(body).hasFixed, field)
        }
        XCTAssertTrue(CallJSON.wire(CallJSON.request(req, state: "submitted", version: 1)).hasFixed)
    }

    /// An incoming call in a state this build does not know, or being read
    /// anew, has its card in the right panel (review D8i-p3-6).
    func testThePanelShowsAnIncomingCallInAnUnknownState() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(req, state: "paused_by_server", version: 4, onThisDevice: true))]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        XCTAssertEqual(TeamPanelSection.activeIncoming(service.calls).map(\.id), [req])
    }

    // MARK: D3: publishing from the client

    private let ops = "7b2d0f3c-8e4a-4b6f-9c1d-3e4f5a6b7c8d"

    /// A connected organization with the member's teams, and team work on
    /// its cache; its queue holds unless `sending`.
    private func publishingSetup(sending: Bool = false, executor: TeamAgentRunner? = nil) async throws -> (ChatService, TeamService, ChatStore, URL) {
        let (service, _) = try await started(requests: [], next: nil, executor: executor)
        let store = try XCTUnwrap(service.orgSessions[anna]?.store)
        try store.apply(ChatSnapshot(cursors: [:], teams: [.init(teamId: general, name: "General", isGeneral: true),
                                                           .init(teamId: ops, name: "Ops")]))
        if !sending { service.orgSessions[anna]?.outbox?.hold() }
        let team = team()
        team.calls.serverMode = true
        team.calls.publishing = service
        team.calls.useServer(store.calls, key: anna)
        service.localAgent = { id in team.calls.agents.first { $0.id.uuidString.lowercased() == id } }
        let folder = root.appendingPathComponent("project-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (service, team, store, folder)
    }

    private func agent(_ name: String, _ folder: URL, enabled: Bool = true) -> TeamPublishedAgent {
        var agent = TeamPublishedAgent(name: name, description: "Knows \(name)", folder: folder.path)
        agent.access = .read
        agent.enabled = enabled
        return agent
    }

    private func publishCommands(_ service: ChatService) throws -> [ChatCommandRecord] {
        try XCTUnwrap(service.journal).commands(for: anna).filter { $0.type == ChatService.publishType }
    }

    private func assignmentOf(_ service: ChatService, _ agent: TeamPublishedAgent) throws -> ChatAssignment? {
        try XCTUnwrap(service.journal).assignment(anna, agentId: agent.id.uuidString.lowercased())
    }

    private func journalWrite(_ service: ChatService, _ sql: String, _ arguments: StatementArguments = []) throws {
        try XCTUnwrap(service.journal).queue.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    /// The cards the server lists of the member's agents (as its events bring them).
    private func listed(_ store: ChatStore, _ agents: [TeamPublishedAgent]) throws {
        try store.apply(ChatSnapshot(cursors: [:], agents: agents.map {
            ChatAgentCard(agentId: $0.id.uuidString.lowercased(), ownerAccountId: CallJSON.anna, name: $0.name, description: $0.description,
                          access: $0.access.rawValue, enabled: true, executorSessionId: "s-anna", executorDeviceName: "Mac",
                          available: true, teamIds: [general])
        }))
    }

    /// The server's answer to a publication, as the queue stores it.
    private func answer(_ service: ChatService, _ state: ChatCommandRecord.State, error: String? = nil) throws {
        try XCTUnwrap(service.journal).queue.write { db in
            try db.execute(sql: "UPDATE run_commands SET state = ?, error = ? WHERE type = ? AND state IN ('pending', 'unconfirmed')",
                           arguments: [state.rawValue, error, ChatService.publishType])
        }
        service.settlePublications(anna)
    }

    /// D3(1): only the button makes an assignment — with its command, in one
    /// transaction; the server's card of the member's own agent makes none;
    /// CLI `publish` in server mode is refused and changes nothing.
    func testOnlyTheButtonPublishes() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        let row = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(ChatPublishRequest.decode(row.requested)?.teamIds, [general])
        let commands = try publishCommands(service)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.orderKey, "exec:agent:\(billing.id.uuidString.lowercased())")
        // The server's card of an agent of the member: the catalog only.
        let other = UUID()
        try store.apply(CallJSON.event("team:\(general)", 1, "agent.publish", [
            "agent_id": other.uuidString.lowercased(), "owner_account_id": CallJSON.anna, "name": "ghost", "description": "d",
            "access": "read", "enabled": true, "executor_session_id": "s-anna", "executor_device_name": "Mac", "available": true,
        ]))
        XCTAssertNil(try XCTUnwrap(service.journal).assignment(anna, agentId: other.uuidString.lowercased()))
        // CLI.
        let before = try String(contentsOf: TeamStorage(directory: root.appendingPathComponent("team")).agentsURL, encoding: .utf8)
        var publish = AgentPadCLIRequest(verb: .team)
        publish.teamAction = AgentPadCLITeamAction.publish.rawValue
        publish.teamAgent = "cli"
        publish.teamFolder = folder.path
        publish.teamDescription = "d"
        let refused = await TeamCLIHandler.handle(publish, service: team)
        XCTAssertEqual(refused.error, TeamServerCore.publishFromWindow)
        XCTAssertEqual(try String(contentsOf: TeamStorage(directory: root.appendingPathComponent("team")).agentsURL, encoding: .utf8), before)
        XCTAssertEqual(try publishCommands(service).count, 1)
    }

    /// The server takes it: active with its parameters; it refuses a new
    /// one: the assignment goes; it refuses a change: the accepted
    /// parameters stay and the change is shown not published (D3(2)).
    func testTheServersAnswerSettlesThePublication() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        var billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        var row = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(row.state, .active)
        XCTAssertNil(row.requested)
        XCTAssertEqual(row.publishedSession, "s-anna")
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .published(teams: [general]))
        // A change the server refuses.
        billing.name = "billing2"
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .failed, error: "name_taken")
        row = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(row.name, "billing")
        XCTAssertEqual(row.lastError, "name_taken")
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .changesNotPublished(error: "name_taken"))
        // A new one refused: no assignment.
        let payroll = agent("payroll", folder)
        try await team.calls.saveAndPublish([payroll], teams: [ops], key: anna)
        try answer(service, .failed, error: "forbidden")
        XCTAssertNil(try assignmentOf(service, payroll))
        XCTAssertEqual(service.publishStatus(payroll, key: anna).status, .local)
    }

    /// The assignment keeps the publication asked until it is settled
    /// (lead's decisions on D3b-2, D3c-p2-2): its command lost with its
    /// session goes on by itself under the same server generation; under
    /// another it waits for the owner — Try Again sends it, Withdraw ends
    /// it; before the new session's generation is settled it waits for the hello.
    func testThePublicationAskedStaysAskedUntilSettled() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let journal = try XCTUnwrap(service.journal)
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        // A new session, the same generation: it goes on.
        try answer(service, .dropped, error: "dropped: its session ended")
        XCTAssertEqual(try publishCommands(service).map(\.state), [.dropped, .pending])
        XCTAssertEqual(try publishCommands(service).last?.sessionId, "s-anna")
        // A new session before its hello: it waits.
        try journalWrite(service, "UPDATE run_commands SET state = 'dropped', error = 'dropped: its session ended' WHERE state = 'pending'")
        try journal.setPending(anna, "g2")
        service.settlePublications(anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 0)
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .publishing, "not the owner's yet")
        // Its hello brings a new generation: the owner decides.
        try journal.finish(anna, "g2")
        service.settlePublications(anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 0)
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .unconfirmed)
        // The owner's Try Again sends it, under the current session.
        service.retryStopped()
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 1)
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .pending)
    }

    /// Withdraw ends a publication whatever way it waits for the owner —
    /// unconfirmed by a new generation, or lost with its session under
    /// another one (review D3c-p1-1).
    func testWithdrawEndsEveryWayOfWaiting() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let journal = try XCTUnwrap(service.journal)
        let lost = agent("lost", folder), unconfirmed = agent("unconfirmed", folder)
        try await team.calls.saveAndPublish([lost], teams: [general], key: anna)
        try answer(service, .dropped, error: "dropped: its session ended")
        try journal.finish(anna, "g2")
        try journalWrite(service, "UPDATE run_commands SET state = 'dropped', error = 'dropped: its session ended' WHERE state = 'pending'")
        service.settlePublications(anna)
        XCTAssertEqual(service.publishStatus(lost, key: anna).status, .unconfirmed)
        try service.withdrawPublication(lost.id, key: anna)
        XCTAssertNil(try assignmentOf(service, lost))
        try await team.calls.saveAndPublish([unconfirmed], teams: [general], key: anna)
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE state = 'pending'")
        try service.withdrawPublication(unconfirmed.id, key: anna)
        XCTAssertNil(try assignmentOf(service, unconfirmed))
        service.retryStopped()
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 0, "nothing comes back")
    }

    /// The queue sends it and the server's answer settles it, on its own.
    func testAPublicationSentIsSettledByItsAnswer() async throws {
        let (service, team, _, folder) = try await publishingSetup(sending: true)
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try await waitUntil { try self.assignmentOf(service, billing)?.state == .active }
    }

    /// D3(3): after a new session the accepted publication is asked again
    /// as it was accepted — the same teams — without writing `agents.json`;
    /// not when the agent here differs, nor after a refusal, nor for one
    /// never published (D3(4)) (lead's decision on D3b-1).
    func testANewSessionAnnouncesWhatTheServerAccepted() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder), payroll = agent("payroll", folder), local = agent("local", folder)
        try await team.calls.saveAndPublish([billing, payroll], teams: [general, ops], key: anna)
        try answer(service, .sent)
        try await team.calls.save(local)
        // Taken from an earlier session; payroll changed here since.
        try journalWrite(service, "UPDATE assignments SET published_session = 's-old'")
        var changed = payroll
        changed.description = "other"
        try await team.calls.save(changed)
        let agentsFile = TeamStorage(directory: root.appendingPathComponent("team")).agentsURL
        let before = try String(contentsOf: agentsFile, encoding: .utf8)
        service.announceAfterNewSession(anna)
        let asked = try publishCommands(service).filter { $0.state == .pending }
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.orderKey, "exec:agent:\(billing.id.uuidString.lowercased())")
        let args = try JSONDecoder().decode(ChatCommandEnvelope.self, from: XCTUnwrap(asked.first).bodyBytes).args
        XCTAssertEqual(args["team_ids"], .array([.string(general), .string(ops)].sorted { $0.string! < $1.string! }))
        XCTAssertEqual(try String(contentsOf: agentsFile, encoding: .utf8), before, "agents.json is not written")
        XCTAssertNil(try assignmentOf(service, local))
        // Taken: told, and not asked again.
        var told: [String] = []
        service.onNotice = { told.append($0) }
        try answer(service, .sent)
        XCTAssertEqual(told, ["Agents billing are available again from this Mac."])
        service.announceAfterNewSession(anna)
        XCTAssertTrue(try publishCommands(service).allSatisfy { $0.state != .pending })
    }

    /// D3(4): an agent of agents.json without an assignment never goes,
    /// nor one saved with Published off (lead's decision on D3b-4); a
    /// published one may not be paused or removed by any path before D3b.
    func testPublishedOffSavesOnlyAndPublishedAgentsStay() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let off = agent("quiet", folder, enabled: false)
        try await team.calls.saveAndPublish([off], teams: [general], key: anna)
        XCTAssertEqual(team.calls.agents.map(\.name), ["quiet"])
        XCTAssertNil(try assignmentOf(service, off))
        XCTAssertEqual(try publishCommands(service).count, 0)
        XCTAssertThrowsError(try service.publish([off], teams: [general], key: anna), "the common path refuses Published off")
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        // Pending: no pause, no removal — by the window, the CLI, the session's Stop, the sweep.
        var paused = billing
        paused.enabled = false
        do {
            try await team.calls.save(paused)
            XCTFail("paused")
        } catch {
            XCTAssertEqual(error as? TeamError, .notYet(TeamServerCore.pauseNotYet))
        }
        // Unpublishing goes through the server first (D3b): the CLI asks it,
        // the agent stays here until the server takes it.
        var unpublish = AgentPadCLIRequest(verb: .team)
        unpublish.teamAction = AgentPadCLITeamAction.unpublish.rawValue
        unpublish.teamAgent = "billing"
        let asked = await TeamCLIHandler.handle(unpublish, service: team)
        XCTAssertTrue(asked.ok, asked.error ?? "")
        XCTAssertTrue(team.calls.agents.contains { $0.id == billing.id })
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .removing)
    }

    // MARK: D3b: unpublishing

    private func unpublishCommands(_ service: ChatService) throws -> [ChatCommandRecord] {
        try XCTUnwrap(service.journal).commands(for: anna).filter { $0.type == ChatService.unpublishType }
    }

    private func answerUnpublish(_ service: ChatService, _ state: ChatCommandRecord.State, error: String? = nil) throws {
        try journalWrite(service, "UPDATE run_commands SET state = ?, error = ? WHERE type = ? AND state = 'pending'",
                         [state.rawValue, error, ChatService.unpublishType])
        service.settlePublications(anna)
    }

    /// Unpublish: `removing` and `agent.unpublish` in one transaction; runs
    /// refused meanwhile; the agent leaves this Mac only once the server took
    /// it — or does not know it (DESIGN-D3b-D4b-D5b §1.1).
    func testUnpublishingWaitsForTheServer() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        service.onAgentUnpublished = { id in try? team.calls.removeUnpublished(UUID(uuidString: id)!) }
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .active)
        try team.calls.unpublish(billing.id)
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .removing)
        XCTAssertEqual(try unpublishCommands(service).map(\.state), [.pending])
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .unpublishing)
        try team.calls.unpublish(billing.id)
        XCTAssertEqual(try unpublishCommands(service).count, 1, "asked once")
        service.settlePublications(anna)
        XCTAssertTrue(team.calls.agents.contains { $0.id == billing.id }, "not before the server took it")
        try answerUnpublish(service, .sent)
        XCTAssertNil(try assignmentOf(service, billing))
        XCTAssertFalse(team.calls.agents.contains { $0.id == billing.id })

        // Not known to the server: gone too. Refused otherwise: published as before, said.
        let known = agent("known", folder), refused = agent("refused", folder)
        try await team.calls.saveAndPublish([known, refused], teams: [general], key: anna)
        try answer(service, .sent)
        try team.calls.unpublish(known.id)
        try answerUnpublish(service, .failed, error: "not_found")
        XCTAssertNil(try assignmentOf(service, known))
        XCTAssertFalse(team.calls.agents.contains { $0.id == known.id })
        try team.calls.unpublish(refused.id)
        try answerUnpublish(service, .failed, error: "forbidden")
        XCTAssertEqual(try assignmentOf(service, refused)?.state, .active)
        XCTAssertEqual(try assignmentOf(service, refused)?.lastError, "forbidden")
        XCTAssertTrue(team.calls.agents.contains { $0.id == refused.id })
    }

    /// Out of a team (its stream and cursor gone, the snapshot's own teams
    /// without it): the team leaves the audience whatever the boundary; a
    /// publication with no boundary counts its streams from their start
    /// (review D3b-1). The feed's every change of the catalog settles it (D3b-3).
    func testTheAudienceFollowsTheSnapshotsOwnTeams() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general, ops], key: anna)
        try answer(service, .sent)
        XCTAssertNil(try assignmentOf(service, billing)?.teamSeqs, "no answer kept: no boundary")
        // The catalog lists it in general; out of ops.
        let card = ChatAgentCard(agentId: billing.id.uuidString.lowercased(), ownerAccountId: CallJSON.anna, name: "billing",
                                 description: billing.description, access: "read", enabled: true, available: true, teamIds: [general])
        try store.apply(ChatSnapshot(cursors: ["team:\(general)": 3],
                                     teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops", mine: false)],
                                     agents: [card]))
        try XCTUnwrap(service.orgSessions[anna]?.sync).onCallsChanged()
        XCTAssertEqual(try assignmentOf(service, billing)?.accepted.teamIds, [general])
        // General's stream read past the start, the card gone: the assignment goes.
        try store.apply(ChatSnapshot(cursors: ["team:\(general)": 4],
                                     teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops", mine: false)],
                                     agents: []))
        service.settleAudiences(anna)
        XCTAssertNil(try assignmentOf(service, billing))
    }

    /// An unpublishing lost with its session under another generation waits
    /// for the owner: Unpublish Again, or Keep Published (review D3b-2).
    func testAnUnconfirmedUnpublishingWaitsForTheOwner() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder), kept = agent("kept", folder)
        try await team.calls.saveAndPublish([billing, kept], teams: [general], key: anna)
        try answer(service, .sent)
        try team.calls.unpublish(billing.id)
        try team.calls.unpublish(kept.id)
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE type = ?", [ChatService.unpublishType])
        service.settlePublications(anna)
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .unpublishUnconfirmed)
        // Kept published.
        try service.withdrawPublication(kept.id, key: anna)
        XCTAssertEqual(try assignmentOf(service, kept)?.state, .active)
        XCTAssertNil(try assignmentOf(service, kept)?.lastError)
        // Unpublished again — also by the CLI's unpublish.
        try team.calls.unpublish(billing.id)
        XCTAssertEqual(try unpublishCommands(service).filter { $0.state == .pending }.count, 1)
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .unpublishing)
    }

    /// Publish while being unpublished: the unpublish not taken gives way;
    /// the publication is asked (DESIGN-D3b-D4b-D5b §1.1).
    func testPublishingAgainWhileUnpublishing() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        try team.calls.unpublish(billing.id)
        try service.publish([billing], teams: [general, ops], key: anna)
        XCTAssertEqual(try unpublishCommands(service).map(\.state), [.dropped])
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .active, "it was published: not a new one")
        try answer(service, .sent)
        let row = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(row.state, .active)
        XCTAssertEqual(row.accepted.teamIds, [general, ops].sorted())

        // Refused, the earlier publication stays — not removed (review D3b2-1).
        try team.calls.unpublish(billing.id)
        try service.publish([billing], teams: [general], key: anna)
        try answer(service, .failed, error: "name_taken")
        let kept = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(kept.state, .active)
        XCTAssertEqual(kept.lastError, "name_taken")
        XCTAssertTrue(service.isAssigned(billing.id))
    }

    /// Publish while unpublishing is always asked of the server — also with
    /// the parameters it had (review D3b3-1); an agent has one organization
    /// at a time (D3b3-2); a new server generation forgets where the team
    /// streams stood (D3b3-3).
    func testPublishWhileUnpublishingIsAskedAndOneOrganizationPerAgent() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        // The server lists it as published: the button alone would ask nothing.
        try store.apply(ChatSnapshot(cursors: [:], teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops")],
                                     agents: [ChatAgentCard(agentId: billing.id.uuidString.lowercased(), ownerAccountId: CallJSON.anna, name: "billing",
                                                            description: billing.description, access: "read", enabled: true, available: true,
                                                            teamIds: [general])]))
        let first = try XCTUnwrap(publishCommands(service).last)
        try journalWrite(service, "UPDATE run_commands SET state = 'sent' WHERE command_id = ?", [first.commandId])
        service.commandAnswered(anna, first, .taken(ChatCommandAnswer(events: [.init(stream: "team:\(general)", seq: 5, id: "e")], result: .object([:]))))
        XCTAssertNotNil(try assignmentOf(service, billing)?.teamSeqs)
        try team.calls.unpublish(billing.id)
        try service.publish([billing], teams: [general], key: anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 1, "asked, though the same as accepted")

        let otherKey = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        try XCTUnwrap(service.journal).save(ChatAssignment(server: server.description, accountId: CallJSON.anna, orgId: otherKey.orgId,
                                                           agentId: UUID().uuidString.lowercased(), state: .active, name: "x", description: "",
                                                           access: "read", teamIds: "[]", createdAt: Date()))
        let elsewhere = agent("elsewhere", folder)
        try XCTUnwrap(service.journal).save(ChatAssignment(server: server.description, accountId: CallJSON.anna, orgId: otherKey.orgId,
                                                           agentId: elsewhere.id.uuidString.lowercased(), state: .active, name: "elsewhere",
                                                           description: "", access: "read", teamIds: "[]", createdAt: Date()))
        XCTAssertThrowsError(try service.publish([elsewhere], teams: [general], key: anna)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("another organization") == true, "\($0)")
        }

        try XCTUnwrap(service.journal).setPending(anna, "g2")
        XCTAssertNil(try assignmentOf(service, billing)?.teamSeqs, "the boundary was the earlier server's")
    }

    /// Unpublishing an agent published to another organization than the
    /// one connected is refused with what to do — never an empty success (review D3b2-2).
    func testUnpublishingNeedsItsOwnOrganization() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        let otherKey = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        let other = try ChatStore.open(files: files, key: otherKey).store
        team.calls.useServer(other.calls, key: otherKey)
        XCTAssertThrowsError(try team.calls.unpublish(billing.id)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("another organization") == true, "\($0)")
        }
        XCTAssertTrue(team.calls.agents.contains { $0.id == billing.id })
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .active)
        XCTAssertThrowsError(try service.unpublish(billing.id, key: otherKey), "no row of that organization: said, not done")
    }

    /// The audience by the team streams (§10.4, §11.3): an `agent.unpublish`
    /// of a team older than the publication the server took changes nothing;
    /// a newer one takes the team out; none left: the assignment goes, the
    /// local agent stays.
    func testALateUnpublishOfATeamDoesNotUndoANewerPublication() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general, ops], key: anna)
        let command = try XCTUnwrap(publishCommands(service).last)
        try journalWrite(service, "UPDATE run_commands SET state = 'sent' WHERE command_id = ?", [command.commandId])
        service.commandAnswered(anna, command, .taken(ChatCommandAnswer(events: [
            .init(stream: "team:\(general)", seq: 12, id: "e1"), .init(stream: "team:\(ops)", seq: 12, id: "e1"),
        ], result: .object([:]))))
        XCTAssertEqual(try assignmentOf(service, billing)?.state, .active)
        XCTAssertNotNil(try assignmentOf(service, billing)?.teamSeqs)
        // The cache lists the agent in neither team; the streams read up to 11: an older word.
        try store.apply(ChatSnapshot(cursors: ["team:\(general)": 11, "team:\(ops)": 11],
                                     teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops")]))
        service.settleAudiences(anna)
        XCTAssertEqual(try assignmentOf(service, billing)?.accepted.teamIds, [general, ops].sorted(), "older than the publication")
        // Ops read past it: ops leaves; general still older.
        try store.apply(ChatSnapshot(cursors: ["team:\(general)": 11, "team:\(ops)": 13],
                                     teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops")]))
        service.settleAudiences(anna)
        XCTAssertEqual(try assignmentOf(service, billing)?.accepted.teamIds, [general])
        // General too: the assignment goes, the agent stays here.
        try store.apply(ChatSnapshot(cursors: ["team:\(general)": 13, "team:\(ops)": 13],
                                     teams: [.init(teamId: general, name: "General", isGeneral: true), .init(teamId: ops, name: "Ops")]))
        service.settleAudiences(anna)
        XCTAssertNil(try assignmentOf(service, billing))
        XCTAssertTrue(team.calls.agents.contains { $0.id == billing.id })
    }

    /// A session agent whose conversation is gone is not swept away while
    /// it is published (removal is D3b); one not published is (review D3-7).
    func testTheSweepKeepsAPublishedSessionAgent() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        var published = agent("kept", folder), local = agent("gone", folder)
        published.sessionId = UUID().uuidString.lowercased()
        local.sessionId = UUID().uuidString.lowercased()
        let storage = TeamStorage(directory: root.appendingPathComponent("team"))
        try storage.save([published, local], to: storage.agentsURL)
        try XCTUnwrap(service.journal).save(ChatAssignment(
            server: anna.server.description, accountId: anna.accountId, orgId: anna.orgId, agentId: published.id.uuidString.lowercased(),
            state: .active, name: "kept", description: published.description, access: "read", teamIds: "[]", createdAt: Date()))
        try team.calls.load()
        XCTAssertEqual(team.calls.agents.map(\.name), ["kept"])
    }

    /// Both, and any repeat: each agent whose parameters here differ from
    /// what the server accepted is asked — an active one whose change was
    /// refused too; one the server has as it is is not (lead's decision on D3b-3).
    func testARepeatPublishesWhatDiffers() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        var session = agent("session", folder), plain = agent("plain", folder)
        try await team.calls.saveAndPublish([session, plain], teams: [general], key: anna)
        try answer(service, .sent)
        session.access = .readGit
        session.name = "taken"
        plain.description = "changed"
        try await team.calls.saveAndPublish([session, plain], teams: [general], key: anna)
        // The server refuses the session's change and takes the plain one's.
        let sessionKey = "exec:agent:\(session.id.uuidString.lowercased())"
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'name_taken' WHERE state = 'pending' AND order_key = ?", [sessionKey])
        try journalWrite(service, "UPDATE run_commands SET state = 'sent' WHERE state = 'pending'")
        service.settlePublications(anna)
        try listed(store, [session, plain])
        XCTAssertEqual(service.publishStatus(session, key: anna).status, .changesNotPublished(error: "name_taken"))
        XCTAssertEqual(service.publishStatus(plain, key: anna).status, .published(teams: [general]))
        session.name = "session2"
        try await team.calls.saveAndPublish([session, plain], teams: [general], key: anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.map(\.orderKey),
                       ["exec:agent:\(session.id.uuidString.lowercased())"], "only the one that differs")
    }

    /// The connection changing while the agents are checked: nothing is
    /// written, nothing published (review D3-9).
    func testAPublicationBegunInOneOrganizationIsNotMadeInAnother() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let other = try ChatStore.open(files: files, key: boris).store
        team.calls.afterPrepare = { team.calls.useServer(other.calls, key: self.boris) }
        do {
            try await team.calls.saveAndPublish([agent("billing", folder)], teams: [general], key: anna)
            XCTFail("published")
        } catch {
            XCTAssertEqual(error as? TeamError, .notYet(TeamServerCore.changedMeanwhile))
        }
        XCTAssertEqual(team.calls.agents, [])
        XCTAssertEqual(try publishCommands(service).count, 0)
    }

    /// Settling that cannot be written is said and tried again on its own.
    func testSettlingThatFailsIsTriedAgain() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        service.reconcileDelay = .milliseconds(50)
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        let journal = try XCTUnwrap(service.journal)
        try await journal.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_settle BEFORE UPDATE ON assignments BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
        try answer(service, .sent)
        XCTAssertNotNil(service.publishProblem)
        try await journal.queue.write { db in try db.execute(sql: "DROP TRIGGER deny_settle") }
        try await waitUntil { try self.assignmentOf(service, billing)?.state == .active }
        XCTAssertNil(service.publishProblem)
    }

    /// The queue's final answers reach their owner by type in one place:
    /// `agent.publish` is settled here, another type goes to its owner (D5).
    func testCommandAnswersGoToTheirOwnerByType() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        var heard: [String] = []
        service.commandOwners["request.create"] = { _, record, outcome in
            if case .refused(let code) = outcome { heard.append("\(record.type) \(code)") }
        }
        service.commandOwners[ChatService.publishType] = { _, _, _ in heard.append("publish") }
        func record(_ type: String) -> ChatCommandRecord {
            ChatCommandRecord(commandId: "c", sessionId: "s", type: type, bodyBytes: Data(), orderKey: "k", dependsOn: nil,
                              createdAt: Date(), state: .failed)
        }
        service.commandAnswered(anna, record("request.create"), .refused("forbidden"))
        service.commandAnswered(anna, record(ChatService.publishType), .refused("name_taken"))
        service.commandAnswered(anna, record("member.set_name"), .refused("x"))
        XCTAssertEqual(heard, ["request.create forbidden"])
    }

    // MARK: Review D3, round 1

    /// Send Again drops the waiting command and asks the publication anew
    /// under the current session; a later Try Again of the core has nothing
    /// old to send (review D3-p1-1, p2-1).
    func testSendAgainReplacesTheWaitingCommand() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        // A restored server: the queue waits for the owner.
        let outbox = try XCTUnwrap(service.orgSessions[anna]?.outbox)
        try outbox.generationChanged()
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .unconfirmed)
        try service.resendPublication(billing.id, key: anna)
        XCTAssertNil(outbox.paused, "goes on as after Try Again")
        let commands = try publishCommands(service)
        XCTAssertEqual(commands.map(\.state), [.dropped, .pending])
        XCTAssertEqual(commands.first?.error, ChatService.sentAgainError)
        XCTAssertEqual(service.publishStatus(billing, key: anna).status, .publishing)
        XCTAssertEqual(try XCTUnwrap(service.orgSessions[anna]?.outbox).unconfirmed, [], "nothing old left for Try Again")
    }

    /// Withdrawing an unconfirmed announce of an active publication keeps
    /// what was accepted, and nothing announces it again until the owner
    /// publishes (review D3-p1-2).
    func testAWithdrawnAnnounceIsNotAnnouncedAgain() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [ops], key: anna)
        try answer(service, .sent)
        try journalWrite(service, "UPDATE assignments SET published_session = 's-old'")
        service.announceAfterNewSession(anna)
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE state = 'pending'")
        try service.withdrawPublication(billing.id, key: anna)
        let row = try XCTUnwrap(assignmentOf(service, billing))
        XCTAssertEqual(row.state, .active)
        XCTAssertEqual(row.publishedSession, "s-old")
        XCTAssertEqual(row.accepted.teamIds, [ops])
        service.announceAfterNewSession(anna)
        XCTAssertFalse(try publishCommands(service).contains { $0.state == .pending })
    }

    /// A form opened for one connection does not publish for another (review D3-p1-3).
    func testAFormOpenedForAnotherConnectionDoesNotPublish() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        do {
            try await team.calls.saveAndPublish([agent("billing", folder)], teams: [general], key: boris)
            XCTFail("published")
        } catch {
            XCTAssertEqual(error as? TeamError, .notYet(TeamServerCore.changedMeanwhile))
        }
        XCTAssertEqual(team.calls.agents, [])
        XCTAssertEqual(try publishCommands(service).count, 0)
    }

    /// The forms open with the teams the owner chose — of the publication
    /// on its way, or the accepted one — and General only for a new one
    /// (review D3-p1-4, p2-3).
    func testTheChosenTeamsAreKept() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        var billing = agent("billing", folder)
        XCTAssertNil(service.chosenTeams(billing.id, key: anna))
        try await team.calls.saveAndPublish([billing], teams: [ops], key: anna)
        XCTAssertEqual(service.chosenTeams(billing.id, key: anna), [ops])
        try answer(service, .sent)
        billing.name = "taken"
        try await team.calls.saveAndPublish([billing], teams: [ops], key: anna)
        try answer(service, .failed, error: "name_taken")
        XCTAssertEqual(service.chosenTeams(billing.id, key: anna), [ops], "after a refused change too")
    }

    /// Publishing again with the same parameters asks the server when it
    /// no longer lists the agent, or took it from another session (review D3-p2-2).
    func testPublishingAgainAsksWhatTheServerLost() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        try listed(store, [billing])
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        XCTAssertFalse(try publishCommands(service).contains { $0.state == .pending }, "listed as it is: nothing to ask")
        try listed(store, [])
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 1, "not listed: asked")
    }

    /// An announce that cannot be written is said and tried again by itself (review D3-p2-4).
    func testAnAnnounceThatFailsIsTriedAgain() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        service.reconcileDelay = .milliseconds(50)
        service.isServerKnown = { _, _ in true }
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        try listed(store, [billing])
        try journalWrite(service, "UPDATE assignments SET published_session = 's-old'")
        try journalWrite(service, "CREATE TRIGGER deny_announce BEFORE UPDATE OF requested ON assignments BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        service.announceAfterNewSession(anna)
        XCTAssertNotNil(service.publishProblem)
        try journalWrite(service, "DROP TRIGGER deny_announce")
        try await waitUntil { try self.publishCommands(service).contains { $0.state == .pending } }
        XCTAssertNil(service.publishProblem)
    }

    // MARK: Review D3, round 2

    /// A publication unconfirmed by a new generation goes by itself neither
    /// by settling nor by a later settling; the owner sends it (D3b-p1-1).
    func testAnUnconfirmedPublicationWaitsForTheOwner() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE state = 'pending'")
        service.settlePublications(anna)
        service.settlePublications(anna)
        XCTAssertEqual(try publishCommands(service).map(\.state), [.unconfirmed])
        try service.resendPublication(billing.id, key: anna)
        XCTAssertEqual(try publishCommands(service).map(\.state), [.dropped, .pending])
    }

    /// A journal that exists but is not open, or failed to open, knows of
    /// assignments it cannot say: nothing is removed or paused on a guess
    /// (review D3b-p2-1).
    func testAJournalNotOpenKeepsPublishedAgents() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        XCTAssertFalse(service.isAssigned(UUID()), "no journal ever made")
        _ = try ChatJournal.open(files: files)
        XCTAssertTrue(service.isAssigned(UUID()), "a journal not open: not known")
        let team = team()
        team.calls.publishing = service
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var gone = agent("gone", folder)
        gone.sessionId = UUID().uuidString.lowercased()
        let storage = TeamStorage(directory: root.appendingPathComponent("team"))
        try storage.save([gone], to: storage.agentsURL)
        try team.calls.load()
        XCTAssertEqual(team.calls.agents.map(\.name), ["gone"], "not swept away")
        XCTAssertThrowsError(try team.calls.unpublish(gone.id))
    }

    /// The session window's teams are those of the agent it publishes in
    /// its mode — the folder agent's for Folder (review D3b-p1-4, p2-2).
    func testTheSessionWindowKeepsTheFolderAgentsTeams() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        let sessionId = UUID().uuidString.lowercased()
        let plain = agent("plain", folder)
        try await team.calls.saveAndPublish([plain], teams: [ops], key: anna)
        let edited = TeamPublishSessionView.edited(mode: .folder, sessionId: sessionId, folderName: "plain", folder: folder.path, calls: team.calls)
        XCTAssertEqual(edited.map(\.id), [plain.id])
        XCTAssertEqual(edited.compactMap { service.chosenTeams($0.id, key: anna) }.first, [ops])
        XCTAssertEqual(TeamPublishSessionView.edited(mode: .session, sessionId: sessionId, folderName: "plain", folder: folder.path,
                                                      calls: team.calls), [], "the session mode has no agent yet")
    }

    /// The session window restores the teams when the agent it edits
    /// changes — by mode or by the name typed — and keeps the owner's own
    /// choice otherwise; General only for a new one (review D3c-p2-3).
    func testTheSessionWindowRestoresTeamsWhenTheAgentChanges() {
        let a = TeamPublishedAgent(name: "billing", description: "d", folder: "/tmp"), b = TeamPublishedAgent(name: "other", description: "d", folder: "/tmp")
        let earlier: (UUID) -> [String]? = { $0 == a.id ? [self.ops] : nil }
        XCTAssertEqual(TeamPublishSessionView.restored(edited: [], previous: nil, general: [general], earlier: earlier), [general])
        XCTAssertEqual(TeamPublishSessionView.restored(edited: [a], previous: [], general: [general], earlier: earlier), [ops], "typed its name")
        XCTAssertNil(TeamPublishSessionView.restored(edited: [a], previous: [a.id], general: [general], earlier: earlier), "the same agent: the owner's choice stays")
        XCTAssertEqual(TeamPublishSessionView.restored(edited: [b], previous: [a.id], general: [general], earlier: earlier), [general])
    }

    /// Publishing again asks the server when its card differs from what
    /// was accepted — its teams too — and the window says so (review D3b-p2-3).
    func testACardThatDiffersIsPublishedAgain() async throws {
        let (service, team, store, folder) = try await publishingSetup()
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general, ops], key: anna)
        try answer(service, .sent)
        try listed(store, [billing])  // the server lists General only
        XCTAssertNotNil(service.publishStatus(billing, key: anna).note)
        try await team.calls.saveAndPublish([billing], teams: [general, ops], key: anna)
        XCTAssertEqual(try publishCommands(service).filter { $0.state == .pending }.count, 1)
    }

    /// A problem is cleared only by its own operation's success (review D3b-p2-4).
    func testAProblemIsClearedOnlyByItsOwnSuccess() async throws {
        let (service, team, _, folder) = try await publishingSetup()
        service.reconcileDelay = .seconds(60)
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try journalWrite(service, "CREATE TRIGGER deny_settle BEFORE UPDATE OF state ON assignments BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        try answer(service, .sent)
        XCTAssertNotNil(service.publishProblem)
        service.announceAfterNewSession(anna)
        XCTAssertNotNil(service.publishProblem, "the announce's success does not clear the settling's problem")
        try journalWrite(service, "DROP TRIGGER deny_settle")
        service.settlePublications(anna)
        XCTAssertNil(service.publishProblem)
    }

    // MARK: D4: the owner's side

    /// A runner of the owner's side: tells its process, holds until
    /// released, answers as told.
    final class OwnerRunner: TeamAgentRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [CheckedContinuation<Void, Never>] = []
        private var _calls = 0
        var holds = true
        /// Tells its process (as `ClaudeCodeRunner` does); a stand-in may not.
        var tellsProcess = true
        var answer = TeamRunResult(text: "Refunded twice by a retry.", isError: false, turns: 1, durationMs: 1)
        /// Its process cannot be made (held first, when `holds`).
        var cannotStart = false
        /// Its second process (a continuation) cannot be made.
        var cannotContinue = false
        /// Stopped while held: answers anyway (it had finished), else throws.
        var answersWhenStopped = false
        var stopOutcome: TeamStopOutcome?
        var preflightStopError: TeamRunnerError?
        private var _requests: [TeamRunRequest] = []
        var requests: [TeamRunRequest] { lock.withLock { _requests } }
        var calls: Int { lock.withLock { _calls } }
        func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
            try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
        }
        func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
                 onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
            if preflightStopError != nil {
                try request.onPreflightProcess?(.init(pid: 900_004, pgid: 900_004, startTime: 4))
            }
            let n = lock.withLock { () -> Int in _calls += 1; _requests.append(request); return _calls }
            if n > 1, lock.withLock({ cannotContinue }) { throw TeamRunnerError.didNotStart("no process (test)") }
            if lock.withLock({ cannotStart }) {
                if lock.withLock({ holds }) { await withCheckedContinuation { c in lock.withLock { gates.append(c) } } }
                throw TeamRunnerError.didNotStart("no process (test)")
            }
            if lock.withLock({ tellsProcess }) {
                try onProcessStarted(TeamProcessStart(pid: 900_000 + Int32(n), pgid: 900_000 + Int32(n), startTime: UInt64(n)))
            }
            if lock.withLock({ holds }) {
                // A stop (the task cancelled) lets it go, as a real run's does.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { c in
                        lock.withLock { Task.isCancelled ? c.resume() : gates.append(c) }
                    }
                } onCancel: {
                    release()
                }
                if Task.isCancelled, !lock.withLock({ answersWhenStopped }) {
                    if let error = lock.withLock({ preflightStopError }) {
                        if error == .cancelledBeforeExecutor { try request.onPreflightProcess?(nil) }
                        throw error
                    }
                    if let outcome = lock.withLock({ stopOutcome }) { throw TeamRunnerError.stopped(outcome) }
                    throw CancellationError()
                }
            }
            return lock.withLock { answer }
        }
        func release() { lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { gates = [] }; return gates }.forEach { $0.resume() } }
        var waiting: Int { lock.withLock { gates.count } }
    }

    /// An owner Mac: its agent published (active), the owner's side
    /// installed, the queue held so commands stay to be looked at.
    private func ownerSetup(_ runner: OwnerRunner = OwnerRunner()) async throws -> (ChatService, TeamService, ChatStore, TeamPublishedAgent, OwnerRunner) {
        let (service, team, store, folder) = try await publishingSetup(executor: runner)
        let billing = agent("billing", folder)
        try await team.calls.saveAndPublish([billing], teams: [general], key: anna)
        try answer(service, .sent)
        _ = ChatOwnerSide.install(service: service, calls: team.calls)
        return (service, team, store, billing, runner)
    }

    /// The server's word on the request, by the executor's device stream.
    private func server(_ store: ChatStore, _ service: ChatService, _ type: String, _ body: [String: Any]) throws {
        let stream = "device:\(org):s-anna"
        let applied = try store.apply(CallJSON.event(stream, try store.cursor(stream) + 1, type, body), facts: service.localFacts(anna, [req]))
        XCTAssertEqual(applied, .applied)
        service.onCallsChanged(anna)
        service.runner(for: anna).run()
    }

    private func incoming(_ agent: TeamPublishedAgent, state: String = "submitted", version: Int = 1, conditions: Int = 1) -> [String: Any] {
        var body = CallJSON.request(req, state: state, version: version, onThisDevice: true)
        body["agent_id"] = agent.id.uuidString.lowercased()
        body["conditions_version"] = conditions
        return body
    }

    private func move(_ state: String, _ version: Int, runId: String? = nil) -> [String: Any] {
        CallJSON.request(req, state: state, version: version, fixed: false, runId: runId)
    }

    private func executorCommands(_ service: ChatService) throws -> [ChatCommandRecord] {
        try XCTUnwrap(service.journal).commands(for: anna).filter { $0.type != ChatService.publishType }
    }

    /// D4: `receive` sends `request.received`, once; terms it does not know
    /// or an agent it cannot run decline right after it (D4(12)).
    func testReceiveTakesOrDeclines() async throws {
        let (service, _, store, billing, _) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try await waitUntil { try self.executorCommands(service).map(\.type) == ["request.received"] }
        // Handed over again, as after a restart in the middle: nothing more.
        try await store.queue.write { db in try db.execute(sql: "UPDATE actions SET state = 'in_progress' WHERE kind = 'receive'") }
        service.runner(for: anna).run()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try executorCommands(service).count, 1, "once")
    }

    /// Only the buttons decide (DESIGN-D4 §0.1): Allow makes the approval and
    /// `request.decide` together; every CLI action against the request —
    /// the way MCP asks too — makes neither; a second press nothing more.
    func testOnlyTheButtonsDecide() async throws {
        let (service, team, store, billing, _) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        let journal = try XCTUnwrap(service.journal)
        for action in AgentPadCLITeamAction.allCases {
            var request = AgentPadCLIRequest(verb: .team)
            request.teamAction = action.rawValue
            request.teamCall = req
            request.teamAgent = "billing@anna"
            request.teamPrompt = "x"
            _ = await TeamCLIHandler.handle(request, service: team)
        }
        XCTAssertEqual(try journal.approvals().count, 0, "no approval but by the button")
        // The buttons are there on the executor: the gate lets decide through, not stop (D4b).
        let call = try XCTUnwrap(team.calls.incoming.first { $0.id == self.req })
        XCTAssertNil(team.calls.refusal(.decide, for: call))
        XCTAssertNil(team.calls.refusal(.stop, for: call), "stopped through the server (D4b)")
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "request.decide" })
        XCTAssertNil(team.calls.decide(req, allow: true))
        XCTAssertEqual(try journal.approvals().count, 1)
        XCTAssertEqual(try executorCommands(service).filter { $0.type == "request.decide" }.count, 1)
        _ = team.calls.decide(req, allow: true)
        XCTAssertEqual(try journal.approvals().count, 1)
        XCTAssertEqual(try executorCommands(service).filter { $0.type == "request.decide" }.count, 1, "a second press: nothing more")
    }

    /// D4(1), (2): after Allow, `run.start` (with the approval's id) goes;
    /// the run starts only once the server says `starting`, through the
    /// launcher; its end tells `run.started`, `run.finished`, `result.deliver`
    /// in one chain, the full result kept.
    func testAnAllowedRequestRunsOnlyOnceTheServerSaysStarting() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.start" } }
        XCTAssertEqual(try executorCommands(service).first { $0.type == "run.start" }?.commandId, approval.startCommandId)
        // Its answer came (the queue was asked again): still `approved` — nothing runs.
        service.runner(for: anna).run()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(runner.calls, 0, "not before the server says starting")
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { runner.waiting == 1 }
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.started" } }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        runner.release()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "result.deliver" } }
        let chain = try executorCommands(service).filter { $0.orderKey == "exec:run:\(approval.runId)" }
        XCTAssertEqual(chain.map(\.type), ["run.start", "run.started", "run.finished", "result.deliver"])
        XCTAssertEqual(chain.last?.dependsOn, chain[2].commandId)
        XCTAssertEqual(try XCTUnwrap(service.journal).run(approval.runId)?.resultText, "Refunded twice by a retry.")
    }

    // MARK: Review D4, round 1

    /// Allowed and approved up to `starting` on the server: the approval.
    private func allowedUpTo(_ state: String, _ service: ChatService, _ team: TeamService, _ store: ChatStore,
                             _ billing: TeamPublishedAgent) throws -> ChatApproval {
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        if state == "starting" { try server(store, service, "run.start", move("starting", 4, runId: approval.runId)) }
        return approval
    }

    /// A restored server asks for the decision again: the button decides
    /// anew — a new approval for the void one never spent, a new
    /// `request.decide`; the earlier one is replaced (review D4-p1-2).
    func testARestoredServerIsDecidedAnew() async throws {
        let (service, team, store, billing, _) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let journal = try XCTUnwrap(service.journal)
        let first = try XCTUnwrap(journal.approval(anna, requestId: req))
        // Taken by the generation now restored away; the server asks again.
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try journal.finish(anna, "g2")
        try TeamApprovals.voidOtherGenerations(current: "g2", key: anna, journal: journal)
        XCTAssertNil(team.calls.decide(req, allow: true))
        let second = try XCTUnwrap(journal.approval(anna, requestId: req))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(second.voidAt)
        let decides = try executorCommands(service).filter { $0.type == "request.decide" }
        XCTAssertEqual(decides.map(\.state), [.sent, .pending])
    }

    /// A launch whose write failed before the process is tried again after
    /// a pause — never taken for done (review D4-p1-3, p2-4).
    func testALaunchThatCouldNotBeWrittenIsTriedAgain() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        service.runner(for: anna).rewriteDelay = .milliseconds(80)
        try journalWrite(service, "CREATE TRIGGER deny_spend BEFORE UPDATE OF consumed_at ON approvals BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runner.calls, 0)
        try journalWrite(service, "DROP TRIGGER deny_spend")
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        XCTAssertEqual(runner.calls, 1)
    }

    /// A launch blocked by an earlier run (D11) is tried again after a
    /// pause, not at once over and over (review D4-p1-4).
    func testABlockedLaunchWaitsBetweenTurns() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        service.runner(for: anna).rewriteDelay = .seconds(5)
        let journal = try XCTUnwrap(service.journal)
        // An earlier run of the agent, its processes not confirmed gone.
        let other = try TeamApprovals.make(request: TeamLaunchRequest(requestId: "r-earlier", prompt: "x", context: nil, callerName: "B",
                                                                    callerProject: nil, conversationId: nil, expiresAt: Date().addingTimeInterval(3600)),
                                           agent: billing, key: anna, generation: "g1")
        try journal.insert(other)
        XCTAssertTrue(try journal.consume(other, run: ChatRunRecord(runId: other.runId, requestId: "r-earlier", approvalId: other.id, agentId: other.agentId,
                                                                  conversationId: "c", pid: 999_999, pgid: 999_999, processStartedAt: 1, startedAt: Date())))
        _ = try allowedUpTo("starting", service, team, store, billing)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(runner.calls, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(service.owner).startTurns, 4, "not at once over and over")
    }

    /// One run, one slot (review D4-p1-5).
    func testARunIsCountedOnce() {
        XCTAssertEqual(ChatOwnerSide.busy(launching: [("a", "r1")], live: [("a", "r1")]), ["a"])
        XCTAssertEqual(ChatOwnerSide.busy(launching: [("a", "r1")], live: [("b", "r2")]).sorted(), ["a", "b"])
    }

    /// After a new generation the queue still sends the journal's commands
    /// made since — the executor's facts — while the rest waits for the
    /// user (review D4-p2-1).
    func testFactsGoWhileTheUserDecidesOnARestoredServer() async throws {
        let (service, _) = try await started(requests: [], next: nil)
        let outbox = try XCTUnwrap(service.orgSessions[anna]?.outbox)
        try await waitUntil { outbox.isSending }
        try outbox.generationChanged()
        let journal = try XCTUnwrap(service.journal)
        let body = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: org, type: "run.finished",
                                           args: .object(["request_id": .string(req), "run_id": .string("run-1")])).encoded()
        let fact = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s-anna", type: "run.finished", bodyBytes: body,
                                                         orderKey: "exec:run:run-1", dependsOn: nil, createdAt: Date(), state: .pending), key: anna)
        let mine = try service.enqueue(anna, type: "member.set_name", args: .object(["name": .string("Anna")]))
        outbox.allow(connection: try XCTUnwrap(service.socket?.context?.id), generation: "g1")
        outbox.pump()
        try await waitUntil { try journal.commands(for: self.anna).first { $0.commandId == fact.commandId }?.state == .sent }
        XCTAssertNotEqual(try XCTUnwrap(service.orgSessions[anna]?.store).outbox.commands().first { $0.commandId == mine.commandId }?.state, .sent,
                          "the organization's queue waits for the user")
    }

    /// `fail_start` after a restore: what an earlier generation took is not
    /// the server's now — the fact goes again (review D4-p2-2).
    func testAFailedStartToldToAnEarlierGenerationGoesAgain() async throws {
        let (service, team, store, billing, _) = try await ownerSetup()
        let approval = try allowedUpTo("starting", service, team, store, billing)
        let journal = try XCTUnwrap(service.journal)
        try journal.void(approval.id, reason: "server_restored")
        let body = try ChatCommandEnvelope(commandId: ChatUUID.v7(), org: org, type: "run.failed_to_start",
                                           args: .object(["request_id": .string(req), "run_id": .string(approval.runId), "reason": .string("x")])).encoded()
        var old = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s-anna", type: "run.failed_to_start", bodyBytes: body,
                                                        orderKey: "exec:run:\(approval.runId)", dependsOn: nil, createdAt: Date(), state: .pending), key: anna)
        old.state = .sent
        old.sentGeneration = "g0"
        XCTAssertTrue(try journal.runCommands(anna).update(old, ifState: .pending))
        try store.reconcileAll(facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await waitUntil { try self.executorCommands(service).filter { $0.type == "run.failed_to_start" && $0.state == .pending }.count == 1 }
    }

    /// The end told by the local state is refused because the server moved
    /// meanwhile (`stop_requested`): the chain is told again from the
    /// server's state — `run.stopped` (review D4-p2-3).
    func testARefusedEndIsToldAgainFromTheServersState() async throws {
        let runner = OwnerRunner()
        runner.answer = TeamRunResult(text: "", isError: true, turns: 1, durationMs: 1)
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        runner.release()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.failed" && $0.state == .pending } }
        // The stop arrives, then the server refuses the end it no longer takes.
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'invalid_state' WHERE type = 'run.failed'")
        let refused = try XCTUnwrap(executorCommands(service).first { $0.type == "run.failed" })
        service.commandAnswered(anna, refused, .refused("invalid_state"))
        // Built again from `stop_requested`: this runner gave no stop confirmation.
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.stop_failed" && $0.state == .pending } }
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stopped" })
    }

    /// The agent disabled while its process was being made, and the process
    /// never came: `run.stopped`, and a `run.failed_to_start` the server
    /// refused rebuilds the chain from its state (review D4b-p2-2).
    func testARunThatNeverStartedWhileBeingStoppedIsStopped() async throws {
        let runner = OwnerRunner()
        runner.cannotStart = true
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        // The run's own end racing the stop: the stop action left out (D4b's is tested apart).
        service.actionHandlers[.stop] = nil
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        // The stop arrives first.
        try server(store, service, "request.stop", move("stop_requested", 5, runId: approval.runId))
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .didNotStart }
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.stopped" && $0.state == .pending } }
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.failed" })
    }

    /// `run.failed_to_start` told while `starting`, refused once the server
    /// moved to `stop_requested`: the chain is built again (review D4b-p2-2).
    func testARefusedFailedStartIsToldAgainFromTheServersState() async throws {
        let runner2 = OwnerRunner()
        runner2.cannotStart = true
        runner2.holds = false
        let (service2, team2, store2, billing2, _) = try await ownerSetup(runner2)
        let approval2 = try allowedUpTo("starting", service2, team2, store2, billing2)
        try await waitUntil { try self.executorCommands(service2).contains { $0.type == "run.failed_to_start" && $0.state == .pending } }
        try server(store2, service2, "request.stop", move("stop_requested", 5, runId: approval2.runId))
        try journalWrite(service2, "UPDATE run_commands SET state = 'failed', error = 'invalid_state' WHERE type = 'run.failed_to_start'")
        let refused = try XCTUnwrap(executorCommands(service2).first { $0.type == "run.failed_to_start" })
        service2.commandAnswered(anna, refused, .refused("invalid_state"))
        try await waitUntil { try self.executorCommands(service2).contains { $0.type == "run.stopped" && $0.state == .pending } }
    }

    /// A delivery refused while the earlier session is open (`403`) stays
    /// owed and goes again — after a pause, not at the network's pace
    /// (review D4b-p2-1, p1-2).
    func testARefusedDeliveryGoesAgainAfterAPause() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        service.runner(for: anna).rewriteDelay = .milliseconds(300)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "result.deliver" } }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try server(store, service, "run.finished", move("finished", 6, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type != 'result.deliver'")
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'result.deliver'")
        let refused = try XCTUnwrap(executorCommands(service).first { $0.type == "result.deliver" })
        service.commandAnswered(anna, refused, .refused("forbidden"))
        try await Task.sleep(for: .milliseconds(100))
        service.runner(for: anna).run()
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "result.deliver" && $0.state == .pending }, "not at once")
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "result.deliver" && $0.state == .pending } }
    }

    /// A result taken by an earlier generation is shown as not delivered
    /// again (review D4-p2-5).
    func testAResultTakenByAnEarlierGenerationIsShownAgain() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type = 'result.deliver'")
        XCTAssertEqual(service.undeliveredResults(), [])
        try XCTUnwrap(service.journal).finish(anna, "g2")
        XCTAssertEqual(service.undeliveredResults().map(\.requestId), [req])
    }

    /// The decision card says what a shell may do, for the profiles with one (AG-3, track Y).
    func testTheDecisionCardSaysWhatAShellMayDo() {
        let call = TeamCalls.Incoming(id: "c", peer: "p", peerName: "Boris", agentId: UUID(), agentName: "billing", prompt: "x",
                                      threadId: "t", resume: false, origin: nil, receivedAt: Date(), decideBy: Date())
        for access in TeamAccessProfile.allCases {
            let agent = TeamPublishedAgent(name: "billing", description: "d", folder: "/p", access: access)
            XCTAssertEqual(TeamPanelSection.details(call, agent: agent).contains(TeamAccessProfile.shellWarning), access.runsShell, access.rawValue)
        }
    }

    /// A runner that does not tell its process (a stand-in): a run that
    /// finished ran — its chain is the finished one, never
    /// `run.failed_to_start` (the live test D4 on the server).
    func testARunThatFinishedRanWhateverItsRunnerTold() async throws {
        let runner = OwnerRunner()
        runner.holds = false
        runner.tellsProcess = false
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        let chain = try executorCommands(service).filter { $0.orderKey == "exec:run:\(approval.runId)" }.map(\.type)
        XCTAssertEqual(chain, ["run.start", "run.started", "run.finished", "result.deliver"])
    }

    /// D4(7): a launch refused (`params_changed`) tells `run.failed_to_start`
    /// with the reason; D4(4): a final answer to `run.start` starts nothing.
    func testALaunchRefusedOrAFinalAnswerStartsNothing() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        // The agent changed here since the Allow: the run is refused.
        var changed = billing
        changed.maxTurns += 1
        try await team.calls.save(changed)
        try server(store, service, "request.decide", move("approved", 3))
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.failed_to_start" } }
        let fact = try XCTUnwrap(executorCommands(service).first { $0.type == "run.failed_to_start" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["reason"], .string("params_changed"))
        XCTAssertEqual(runner.calls, 0)
    }

    /// The chain of facts by the server's state (DESIGN-D4 §0.2, review D4b-1, -2).
    func testTheChainOfFactsByTheServersState() {
        func plan(_ state: TeamRequestState, _ outcome: ChatRunRecord.Outcome?, started: Bool = true, result: Bool = true, answered: Bool = false) -> [String] {
            ChatFactChain.plan(state: state, outcome: outcome, processStarted: started, hasResult: result, answered: answered)
        }
        XCTAssertEqual(plan(.approved, .finished), ["run.start", "run.started", "run.finished", "result.deliver"])
        XCTAssertEqual(plan(.starting, .finished), ["run.started", "run.finished", "result.deliver"])
        XCTAssertEqual(plan(.running, .failed, result: false), ["run.failed"])
        XCTAssertEqual(plan(.finished, .finished), ["result.deliver"])
        XCTAssertEqual(plan(.finished, .finished, answered: true), [])
        XCTAssertEqual(plan(.starting, .didNotStart), ["run.failed_to_start"])
        XCTAssertEqual(plan(.starting, .failed, started: false, result: false), ["run.failed_to_start"])
        XCTAssertEqual(plan(.starting, nil), ["run.started"])
        // Being stopped: never `run.failed` (review D4b-2).
        XCTAssertEqual(plan(.stopRequested, .finished), ["run.finished", "result.deliver"])
        // Without Y5's explicit confirmation the stop remains unconfirmed;
        // with no process ever, stopped for sure (review D4b-p1-2).
        XCTAssertEqual(plan(.stopRequested, .failed, result: false), ["run.stop_failed"])
        XCTAssertEqual(plan(.stopRequested, .stoppedLocally, result: false), ["run.stop_failed"])
        XCTAssertEqual(plan(.stopRequested, .failed, started: false, result: false), ["run.stopped"])
        XCTAssertEqual(plan(.declined, .finished), [])
        // A restored server waits for the decision: only the button gives it (review D4c-p1-1).
        XCTAssertEqual(plan(.awaitingDecision, .finished), [])
        XCTAssertEqual(plan(.awaitingDecision, .didNotStart), [])
        XCTAssertEqual(plan(.awaitingDecision, nil), [])
        // No process while the server has the run going (review D4b-p2-2).
        XCTAssertEqual(plan(.stopRequested, .didNotStart), ["run.stopped"])
        XCTAssertEqual(plan(.running, .didNotStart), ["run.failed"])
    }

    /// A restored server gives an id this Mac ran to another call (another
    /// initiator, another text): nothing of the earlier one is reused — its
    /// approval set aside, the button decides anew, a new run, and the
    /// earlier result is never delivered to it (review D5b3-1).
    func testAnEarlierCallsApprovalIsNotReusedForAnotherUnderItsId() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        try store.beginGeneration("g2")
        var other = incoming(billing, state: "awaiting_decision", version: 2)
        other["initiator_account_id"] = "99999999-9999-4999-8999-999999999999"
        other["text"] = "Something else entirely"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(other)]), facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await waitUntil { try XCTUnwrap(service.journal).approval(anna, requestId: self.req) == nil }
        team.calls.reload()
        let card = try XCTUnwrap(team.calls.incoming.first { $0.id == req })
        XCTAssertNotEqual(card.detail, TeamCalls.restoredRunNote, "not the earlier call")
        XCTAssertNil(team.calls.decide(req, allow: true))
        let fresh = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        XCTAssertNotEqual(fresh.id, approval.id, "a new approval")
        XCTAssertNotEqual(fresh.runId, approval.runId, "a new run")
        let delivers = try executorCommands(service).filter { $0.type == "result.deliver" && $0.state == .pending }
        XCTAssertTrue(delivers.isEmpty, "the earlier result goes to no one")
    }

    /// Closed by default: an approval with no recorded initiator is no call's
    /// but its own — set aside, its result erased (review D45-final-2).
    func testAnApprovalWithoutItsInitiatorIsSetAside() async throws {
        let (service, _, store, billing, _) = try await ownerSetup()
        let journal = try XCTUnwrap(service.journal)
        let launch = TeamLaunchRequest(requestId: req, prompt: "Why twice?", context: nil, callerName: "B", callerProject: nil,
                                       conversationId: nil, expiresAt: Date().addingTimeInterval(3600))
        let old = try TeamApprovals.approve(request: launch, agent: billing, key: anna, generation: "g1", journal: journal)
        XCTAssertNil(try TeamLaunchParams.decode(old.params).initiator)
        XCTAssertTrue(try journal.consume(old, run: ChatRunRecord(runId: old.runId, requestId: req, approvalId: old.id, agentId: old.agentId,
                                                                  conversationId: "c", pid: 1, pgid: 1, processStartedAt: 1, startedAt: Date())))
        XCTAssertTrue(try journal.finish(old.runId, .finished, result: "an earlier answer"))
        try server(store, service, "request.create", incoming(billing))
        try await waitUntil { try journal.approval(anna, requestId: self.req) == nil }
        XCTAssertNil(try journal.run(old.runId)?.resultText, "erased: no one's to deliver")
    }

    /// A run still going when its approval is set aside stops, and its end
    /// tells nothing and keeps no result — checked in the end's own
    /// transaction (review D45-final-1).
    func testARunOfAnApprovalSetAsideTellsNothing() async throws {
        let runner = OwnerRunner()
        runner.answersWhenStopped = true
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        // The cache read anew says the id is another call's.
        let id = req
        try await store.queue.write { db in try db.execute(sql: "DELETE FROM requests WHERE request_id = ?", arguments: [id]) }
        var other = incoming(billing, state: "running", version: 6)
        other["run_id"] = approval.runId
        other["initiator_account_id"] = "99999999-9999-4999-8999-999999999999"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(other)]), facts: service.localFacts(anna, [req]))
        try server(store, service, "request.stop", { var b = move("stop_requested", 7, runId: approval.runId); return b }())
        let journal = try XCTUnwrap(service.journal)
        try await waitUntil { try journal.run(approval.runId)?.outcome != nil }
        XCTAssertNil(try journal.run(approval.runId)?.resultText)
        XCTAssertEqual(try pendingEnds(service, approval.runId), [], "its end tells nothing")
    }

    /// The button itself sets the earlier call's approval aside, whatever the
    /// action runner did yet (review D5b3-1).
    func testTheButtonDoesNotReuseAnEarlierCallsApproval() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        service.runner(for: anna).mayRun = { false }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        try store.beginGeneration("g2")
        var other = incoming(billing, state: "awaiting_decision", version: 2)
        other["initiator_account_id"] = "99999999-9999-4999-8999-999999999999"
        other["text"] = "Something else entirely"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(other)]), facts: service.localFacts(anna, [req]))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let fresh = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        XCTAssertNotEqual(fresh.id, approval.id)
    }

    /// A server restored to `awaiting_decision` for a request that ran here:
    /// nothing is decided by itself — the card asks, saying it ran here;
    /// Allow keeps the approval and its run, nothing runs again, and once
    /// the server says approved the facts and the result go from the
    /// journal (DESIGN-D4 §0.2, review D4c-p1-1).
    func testARunRestoredToItsDecisionWaitsForTheButton() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        // Restored to before the decision.
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        try store.beginGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(incoming(billing, state: "awaiting_decision", version: 2))]),
                        facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await Task.sleep(for: .milliseconds(200))
        func live() throws -> [String] {
            try executorCommands(service).filter { $0.state == .pending }.map(\.type)
        }
        XCTAssertEqual(try live(), [], "nothing decided by itself")
        team.calls.reload()
        let card = try XCTUnwrap(team.calls.incoming.first { $0.id == req })
        XCTAssertTrue(card.needsDecisionHere, "the button")
        XCTAssertEqual(card.detail, TeamCalls.restoredRunNote)
        // Allow: the same approval, no new run.
        XCTAssertNil(team.calls.decide(req, allow: true))
        let journal = try XCTUnwrap(service.journal)
        XCTAssertEqual(try journal.approval(anna, requestId: req)?.id, approval.id)
        XCTAssertEqual(try live(), ["request.decide"])
        try server(store, service, "request.decide", move("approved", 3))
        try await waitUntil { try live() == ["request.decide", "run.start", "run.started", "run.finished", "result.deliver"] }
        let start = try XCTUnwrap(executorCommands(service).last { $0.type == "run.start" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: start.bodyBytes).args["run_id"], .string(approval.runId))
        XCTAssertEqual(runner.calls, 1, "nothing runs again")
    }

    /// `403` on a run's end (the earlier session still open) after its
    /// `recover` was done: owed again, sent after a pause (review D4c-p2-1).
    func testAForbiddenEndBringsItsRecoverBack() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        service.runner(for: anna).rewriteDelay = .milliseconds(200)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        // A new generation at `running`: the end is told again by `recover`, which ends done.
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        try store.beginGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire({ var b = incoming(billing, state: "running", version: 5); b["run_id"] = approval.runId; return b }())]),
                        facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.finished" && $0.state == .pending } }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g2' WHERE state = 'pending'")
        service.runner(for: anna).run()
        try await waitUntil { try self.actionState(store, "recover") == "done" }
        // The server refuses it: `403`.
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'run.finished' AND sent_generation = 'g2'")
        let refused = try XCTUnwrap(executorCommands(service).last { $0.type == "run.finished" })
        service.commandAnswered(anna, refused, .refused("forbidden"))
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.finished" && $0.state == .pending } }
    }

    /// Dismiss in the Team window hides a refusal; what is owed by it is
    /// not cancelled — `fail_start` keeps sending after `403` (review D4c-p2-2).
    func testDismissDoesNotEndWhatIsOwed() async throws {
        let (service, team, store, billing, _) = try await ownerSetup()
        service.runner(for: anna).rewriteDelay = .milliseconds(100)
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire({ var b = incoming(billing, state: "starting", version: 4); b["run_id"] = approval.runId; b["on_this_device"] = false; return b }())]),
                        facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.failed_to_start" } }
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'run.failed_to_start'")
        let outbox = try XCTUnwrap(service.orgSessions[anna]?.outbox)
        outbox.dismissRefused()
        XCTAssertEqual(try executorCommands(service).first { $0.type == "run.failed_to_start" }?.error, "forbidden", "the code stays")
        let refused = try XCTUnwrap(executorCommands(service).first { $0.type == "run.failed_to_start" })
        service.commandAnswered(anna, refused, .refused("forbidden"))
        try await waitUntil { try self.executorCommands(service).filter { $0.type == "run.failed_to_start" && $0.state == .pending }.count == 1 }
        XCTAssertNotEqual(try actionState(store, "fail_start"), "failed")
    }

    /// A void approval with no fact stored is a debt: `start` ends only once
    /// `run.failed_to_start` is stored (review D4b-p1-3).
    func testAVoidedApprovalEndsOnlyWithItsFailedStartStored() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        let owner = try XCTUnwrap(service.owner)
        service.runner(for: anna).rewriteDelay = .milliseconds(50)
        _ = try allowedUpTo("approved", service, team, store, billing)
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.start" } }
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        // The agent changed since the Allow: the launch voids the approval,
        // in its own transaction; the write of the fact then fails once.
        var changed = billing
        changed.maxTurns += 1
        try await team.calls.save(changed)
        var fails = 1
        owner.writeFails = {
            defer { fails -= 1 }
            return fails > 0
        }
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.failed_to_start" && $0.state == .pending } }
        let fact = try XCTUnwrap(executorCommands(service).last { $0.type == "run.failed_to_start" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["reason"], .string("params_changed"))
        XCTAssertEqual(runner.calls, 0)
    }

    /// After a new generation, a void approval this Mac never spent — its
    /// session no longer the executor — still owes `run.failed_to_start`
    /// (review D4b-p2-3).
    func testAVoidApprovalOfAnEarlierSessionStillTellsItsFailedStart() {
        let request = ChatReconcile.Request(state: .starting, onThisDevice: false, askedHere: false, answered: false)
        XCTAssertEqual(ChatReconcile.actions(request, facts: ChatLocalFacts(approval: .void("executor_signed_out"), approvalId: "a")), [.failStart])
        XCTAssertEqual(ChatReconcile.actions(request, facts: ChatLocalFacts(approval: .valid, approvalId: "a")), [.failStart])
        XCTAssertEqual(ChatReconcile.actions(request, facts: ChatLocalFacts(approval: .spent, approvalId: "a")), [])
    }

    /// A new generation while the agent runs: the `run.started` not taken
    /// is replaced, and the end follows it — the chain the restored server
    /// needs, in one transaction with the outcome (review D4b-1).
    func testANewGenerationDuringARunCompletesTheChain() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.started" } }
        // Restored: what was not sent waits unconfirmed; the server is at `starting`.
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        let live = try executorCommands(service).filter { $0.orderKey == "exec:run:\(approval.runId)" && $0.state == .pending }
        XCTAssertEqual(live.map(\.type), ["run.started", "run.finished", "result.deliver"])
        XCTAssertEqual(live[1].dependsOn, live[0].commandId)
        XCTAssertEqual(live[2].dependsOn, live[1].commandId)
    }

    /// An admin disables the agent while it runs (`stop_requested`): a run
    /// that then ends badly is `run.stopped`, never `run.failed` (review D4b-2).
    func testARunEndingWhileBeingStoppedIsStopped() async throws {
        let runner = OwnerRunner()
        runner.answer = TeamRunResult(text: "", isError: true, turns: 1, durationMs: 1)
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        // The run's own end racing the stop: the stop action left out (D4b's is tested apart).
        service.actionHandlers[.stop] = nil
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        var stop = move("stop_requested", 6, runId: approval.runId)
        stop["cause"] = "agent_disabled"
        try server(store, service, "request.stop", stop)
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .failed }
        let ends = try executorCommands(service).filter { $0.orderKey == "exec:run:\(approval.runId)" && $0.state == .pending }.map(\.type)
        XCTAssertEqual(ends, ["run.stop_failed"], "its processes existed: this runner gave no stop confirmation")
    }

    // MARK: D4b: stop

    private func pendingEnds(_ service: ChatService, _ runId: String) throws -> [String] {
        try executorCommands(service).filter { $0.orderKey == "exec:run:\(runId)" && $0.state == .pending }.map(\.type)
    }

    /// `stop_requested` while the run goes on here (the owner's Stop, the
    /// caller's cancel, an event with `cause`): without a Y5 verdict from
    /// the runner, the stop is not confirmed — `run.stop_failed`, the row
    /// left open, being stopped (DESIGN-D3b-D4b-D5b §2.1, §10.1).
    func testAStopWhileRunningIsToldAsNotConfirmed() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        var stop = move("stop_requested", 6, runId: approval.runId)
        stop["cause"] = "agent_disabled"
        try server(store, service, "request.stop", stop)
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        let fact = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["reason"], .string("processes_unknown"))
        let row = try XCTUnwrap(XCTUnwrap(service.journal).run(approval.runId))
        XCTAssertNil(row.outcome, "open: not confirmed stopped")
        XCTAssertNotNil(row.stopReason)
        XCTAssertTrue(try XCTUnwrap(service.launcher).live.isEmpty)
    }

    /// The run answered as it was being stopped: its end is told —
    /// `run.finished` and its result (DESIGN-D3b-D4b-D5b §2.6).
    func testARunThatAnsweredWhileBeingStoppedFinishes() async throws {
        let runner = OwnerRunner()
        runner.answersWhenStopped = true
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.cancel", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.finished", "result.deliver"] }
        XCTAssertEqual(try XCTUnwrap(service.journal).run(approval.runId)?.outcome, .finished)
    }

    /// Stopped before its process (waiting for `starting` or a slot): it
    /// never starts — the approval voided, `run.stopped` with its run id;
    /// also after a restart, from the journal (DESIGN-D3b-D4b-D5b §10.2).
    func testAStopBeforeTheProcessStartsNothing() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        let approval = try allowedUpTo("approved", service, team, store, billing)
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.start" } }
        try server(store, service, "request.cancel", move("stop_requested", 5, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId).contains("run.stopped") }
        let fact = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stopped" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["run_id"], .string(approval.runId))
        XCTAssertEqual(try XCTUnwrap(service.journal).approval(approval.id)?.voidReason, "stop_requested")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.calls, 0)
    }

    /// The owner's Stop and the caller's cancel are asked of the server;
    /// nothing ends here before its word (D4b, D5b).
    func testStopAndCancelAreAskedOfTheServer() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        team.calls.reload()
        XCTAssertNil(team.calls.stop(req))
        let asked = try XCTUnwrap(store.outbox.commands().last)
        XCTAssertEqual(asked.type, "request.stop")
        team.calls.reload()
        XCTAssertFalse(try XCTUnwrap(team.calls.incoming.first { $0.id == req }).state.isFinal, "not ended before the server")
        XCTAssertEqual(runner.waiting, 1, "the run goes on until stop_requested")
        runner.release()
    }

    /// A new session: what the earlier one was allowed to run does not
    /// start — every unspent approval is voided (DESIGN-D3b-D4b-D5b §11.1).
    func testANewSessionVoidsTheEarlierApprovals() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        let approval = try allowedUpTo("approved", service, team, store, billing)
        XCTAssertEqual(try TeamLaunchParams.decode(approval.params).session, service.connection?.sessionId, "made under this session")
        // Any sign-in in between — the window's, or this one — changes the
        // session: the approval is never spent under the new one (review D4b-p1-1).
        try service.saveSignIn(ChatConnection(server: server, accountId: CallJSON.anna, sessionId: "s-new", deviceName: "Mac", orgId: org),
                               token: "aps_new")
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try XCTUnwrap(service.journal).approval(approval.id)?.voidReason == "executor_signed_out" }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.calls, 0)
    }

    /// The executor's session closed (`4401`): every run stops here (D4b §2.2).
    func testAClosedSessionStopsEveryRun() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        _ = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        service.sessionEnded("The server closed this session. Sign in again.")
        try await waitUntil { try XCTUnwrap(service.launcher).live.isEmpty }
    }

    /// Out of the organization (its streams gone, no `4401`): its runs stop
    /// here, with no event to wait for (§10.3).
    func testLeavingTheOrganizationStopsItsRuns() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        _ = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        service.membershipLost(anna)
        try await waitUntil { try XCTUnwrap(service.launcher).live.isEmpty }
    }

    /// The caller's cancel through the server: `request.cancel` after the
    /// call's own commands; the call is not ended here (D5b §3.1).
    func testACancelIsAskedOfTheServer() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        team.calls.reload()
        team.calls.cancelOnServer = { service.askToEnd(self.anna, $0.id, type: "request.cancel", states: nil) }
        let call = await team.calls.cancel("r-out")
        XCTAssertEqual(try store.outbox.commands().last?.type, "request.cancel")
        XCTAssertFalse(try XCTUnwrap(call).report.state.isFinal, "ended by the server's word only")
        XCTAssertNil(team.calls.refusal(.cancel, for: call))
    }

    // MARK: D4b: activity, folders

    /// Hints about a caller's run (`run.activity`, `run.access_wait`) show
    /// on its call, in memory; they never change its state (D4b §2.4).
    func testEphemeralHintsShowAndChangeNothing() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        ChatOutgoing.install(calls: team.calls, service: service)
        team.calls.reload()
        service.onEphemeral(org, "run.activity", .object(["request_id": .string("r-out"), "text": .string("Grep")]))
        XCTAssertEqual(team.calls.outgoing("r-out")?.report.activity, "Grep")
        team.calls.reload()
        XCTAssertEqual(team.calls.outgoing("r-out")?.report.activity, "Grep", "kept across a reload")
        service.onEphemeral(org, "run.access_wait", .object(["request_id": .string("r-out")]))
        XCTAssertEqual(team.calls.outgoing("r-out")?.report.activity, "waiting for the owner to grant a folder")
        XCTAssertEqual(try store.calls.request("r-out")?.state, .running, "never state")
        service.onEphemeral("another-org", "run.activity", .object(["request_id": .string("r-out"), "text": .string("Read")]))
        XCTAssertEqual(team.calls.outgoing("r-out")?.report.activity, "waiting for the owner to grant a folder", "another organization's")
    }

    func testY2ActivityInStartingIsPendingAndHasNoPaths() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "starting", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        ChatOutgoing.install(calls: team.calls, service: service)
        team.calls.reload()
        XCTAssertFalse(try XCTUnwrap(team.calls.outgoing("r-out")).report.state.isFinal, "lost activity still means pending")
        let hint = "Ожидает разрешения владельца на версию Claude Code 2.1.290"
        service.onEphemeral(org, "run.activity", .object(["request_id": .string("r-out"), "text": .string(hint)]))
        let call = try XCTUnwrap(team.calls.outgoing("r-out"))
        XCTAssertEqual(call.report.activity, hint)
        XCTAssertEqual(TeamCallsSidebar.word(call.report.state, serverState: "starting", activity: hint), hint)
        XCTAssertFalse(call.report.state.isFinal)
        XCTAssertEqual(try store.calls.request("r-out")?.state, .starting)
        service.onEphemeral("other-org", "run.activity", .object(["request_id": .string("r-out"), "text": .string("foreign")]))
        XCTAssertEqual(team.calls.outgoing("r-out")?.report.activity, hint)
    }

    /// A native executor stays alive without tool output after the owner
    /// allows its version. Its start activity reaches both UI and MCP,
    /// including a resumed segment whose server state is already running.
    func testVersionApprovalReplacesWaitingActivityInUIAndMCPForSilentExecutor() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "running", version: 5, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        ChatOutgoing.install(calls: team.calls, service: service)
        team.calls.reload()
        let folder = root.appendingPathComponent("silent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = try NativeVersionFixture.make(in: folder)
        let hold = folder.appendingPathComponent("run-hold")
        for resume in [false, true] {
            let transcripts = try ClaudeResumeFixture()
            try Data().write(to: hold)
            let versions = ClaudeVersionApprovals()
            let preflight = ClaudeVersionPreflight(readVersion: { _, _ in "2.1.290" }, approvals: { versions })
            let request = TeamRunRequest(agent: agent("silent", folder), prompt: "test", sessionId: transcripts.id,
                                         resume: resume, callerName: "test", callerProject: nil)
            let start = TeamStartBox(), organization = org
            let task = Task {
                try await ClaudeCodeRunner(claudePath: binary.path, preflight: preflight, sessionFilesRoot: transcripts.root).run(request, onActivity: { text in
                    Task { @MainActor in
                        service.onEphemeral(organization, "run.activity", .object(["request_id": .string("r-out"), "text": .string(text)]))
                    }
                }, onProcessStarted: { start.set($0) })
            }
            defer { task.cancel(); try? FileManager.default.removeItem(at: hold) }
            let waiting = "Ожидает разрешения владельца на версию Claude Code 2.1.290"
            try await waitUntil { !versions.pending.isEmpty && team.calls.outgoing("r-out")?.report.activity == waiting }
            XCTAssertNil(start.get())
            try await assertMCPActivity(try XCTUnwrap(team.calls.outgoing("r-out")), equals: waiting)
            versions.decide(try XCTUnwrap(versions.pending.first?.id), allow: true)
            let active = resume ? "Продолжает выполнение" : "Выполняет запрос"
            try await waitUntil { team.calls.outgoing("r-out")?.report.activity == active }
            XCTAssertEqual(TeamProcesses.liveness(try XCTUnwrap(start.get()).identity), .alive)
            team.calls.reload()
            let call = try XCTUnwrap(team.calls.outgoing("r-out"))
            XCTAssertEqual(call.report.activity, active)
            XCTAssertEqual(TeamCallsSidebar.word(call.report.state, serverState: call.serverState, activity: call.report.activity), "running · \(active)")
            try await assertMCPActivity(call, equals: active)
            try FileManager.default.removeItem(at: hold)
            _ = try await task.value
        }
    }

    private func assertMCPActivity(_ call: TeamCalls.Outgoing, equals activity: String) async throws {
        var reply = AgentPadCLIResponse(ok: true)
        var info = AgentPadCLITeamInfo(status: "server", detail: nil)
        info.call = TeamCLIHandler.callInfo(call)
        reply.team = info
        let answer = reply, output = TeamValueBox<Data>()
        let mcp = AgentPadTeamMCPServer(cwd: root.path, version: "1", send: { _, _ in .success(answer) }, write: { output.set($0) })
        mcp.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize"]))
        mcp.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "team_check", "arguments": ["call_id": call.id, "wait_minutes": 0]]]))
        try await waitUntil { output.get().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"] as? Int == 2 }
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(output.get())) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, "pending")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains(activity), text)
        if activity != "Ожидает разрешения владельца на версию Claude Code 2.1.290" {
            XCTAssertFalse(text.contains("Ожидает разрешения владельца"), text)
        }
    }

    /// The run's activity goes at most once per interval: the latest when it is over (D4b §2.4).
    func testActivityIsToldAtMostOncePerInterval() async throws {
        let before = ChatActivityThrottle.interval
        ChatActivityThrottle.interval = .milliseconds(200)
        defer { ChatActivityThrottle.interval = before }
        var sent: [String] = []
        let throttle = ChatActivityThrottle { _, text in sent.append(text) }
        let row = ChatRunRecord(runId: "run", requestId: req, approvalId: "a", agentId: "g", conversationId: "c",
                                pid: nil, pgid: nil, processStartedAt: nil, startedAt: Date())
        for text in ["Read", "Grep", "Edit"] { throttle.note(row, text) }
        XCTAssertEqual(sent, ["Read"])
        try await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, ["Read", "Edit"], "the latest")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sent.count, 2)
    }

    /// A folder granted while a server's run goes on: its continuation
    /// record, then the same run goes on once with it — same run id, the
    /// conversation resumed — and ends once (D4b §2.5).
    func testAGrantedFolderContinuesTheSameRun() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        var waited: [String] = []
        let approval = try allowedUpTo("starting", service, team, store, billing)
        team.calls.onAccessWait = { waited.append($0.id) }
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        team.calls.reload()
        let extra = root.appendingPathComponent("extra-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let asked = try await team.calls.requestAccess(callId: req, path: extra.path, reason: "the specs")
        XCTAssertEqual(asked.state, .pending)
        XCTAssertEqual(waited, [req], "run.access_wait told")
        let problem = await team.calls.decideAccess(asked.id, .once)
        XCTAssertNil(problem)
        let continuation = try XCTUnwrap(XCTUnwrap(service.journal).pendingContinuation(of: XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))))
        XCTAssertEqual(try TeamLaunchParams.decode(continuation.params).runId, approval.runId)
        runner.release()
        try await waitUntil { runner.calls == 2 }
        let second = try XCTUnwrap(runner.requests.dropFirst().first)
        XCTAssertTrue(second.resume)
        XCTAssertEqual(second.sessionId, runner.requests[0].sessionId, "the same conversation")
        XCTAssertTrue(second.agent.extraFolders?.contains(extra.resolvingSymlinksInPath().path) == true
                      || second.agent.extraFolders?.contains(extra.path) == true)
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        XCTAssertEqual(runner.calls, 2, "once")
        XCTAssertNil(try XCTUnwrap(service.journal).pendingContinuation(of: XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))))
        XCTAssertEqual(try pendingEnds(service, approval.runId).filter { $0 == "run.finished" }.count, 1)
    }

    /// A continuation of another organization's request under the same id
    /// is not this run's (review D5b-1).
    func testAContinuationOfAnotherOrganizationIsNotThisRuns() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        let otherKey = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        var foreign = approval
        foreign.id = UUID().uuidString.lowercased()
        foreign.orgId = otherKey.orgId
        let continuation = try TeamApprovals.continuation(of: foreign, segment: 1, granted: ["/tmp"], generation: "g1",
                                                          session: service.connection?.sessionId)
        try XCTUnwrap(service.journal).insert(continuation)
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        XCTAssertEqual(runner.calls, 1)
        XCTAssertNil(try XCTUnwrap(service.journal).approval(continuation.id)?.consumedAt)
    }

    /// No continuation without its record; one whose agent changed since is
    /// voided and the run ends with its answer (D4b(4), D9).
    func testNoContinuationWithoutItsRecord() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        XCTAssertNil(service.continueRun(req, folders: ["/tmp"]))
        var changed = billing
        changed.maxTurns += 1
        try await team.calls.save(changed)
        runner.release()
        // Refused: the run fails with why, never ends with the reply it gave
        // while waiting for the folder (review D4b-p2-5).
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .failed }
        XCTAssertEqual(runner.calls, 1)
        let voided = try XCTUnwrap(XCTUnwrap(service.journal).approvals().first { $0.kind == "continuation-1" })
        XCTAssertEqual(voided.voidReason, "params_changed")
        let failed = try XCTUnwrap(executorCommands(service).last { $0.type == "run.failed" })
        XCTAssertTrue(try JSONDecoder().decode(ChatCommandEnvelope.self, from: failed.bodyBytes).args["reason"]?.string?.contains("params_changed") == true)
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "result.deliver" })
    }

    // MARK: D5b: threads, texts

    /// Executor: a request in a thread this Mac had with the same caller and
    /// agent goes on in that conversation (`--resume`), its result carrying
    /// the thread; one in a thread it never had is declined `unknown_thread`
    /// before any button (D5b §3.2).
    func testAThreadGoesOnInItsConversation() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        let first = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { try XCTUnwrap(service.journal).run(first.runId)?.outcome == .finished }
        let deliver = try XCTUnwrap(executorCommands(service).last { $0.type == "result.deliver" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: deliver.bodyBytes).args["thread_id"], .string(req),
                       "a first call begins its own thread")
        // The owner's Continue…: a copy of the run's conversation, never the
        // thread's id, never the conversation itself (F6, AG-7/8).
        let opened = TeamUI.openTab
        defer { TeamUI.openTab = opened }
        var commands: [String] = []
        TeamUI.openTab = { _, command, _ in commands.append(command) }
        team.calls.reload()
        let call = try XCTUnwrap(team.calls.incoming.first { $0.id == req })
        let conversation = try XCTUnwrap(XCTUnwrap(service.journal).run(first.runId)?.conversationId)
        let transcript = try ClaudeResumeFixture(id: conversation)
        team.calls.sessionFilesRoot = transcript.root
        XCTAssertNil(TeamUI.continueYourself(call, in: team.calls))
        XCTAssertEqual(commands, ["claude --resume \(conversation) --fork-session"])
        func ask(_ id: String, thread: String) throws {
            var body = CallJSON.request(id, state: "submitted", version: 1, onThisDevice: true)
            body["agent_id"] = billing.id.uuidString.lowercased()
            body["conditions_version"] = 1
            body["thread_id"] = thread
            try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(body)]), facts: service.localFacts(anna, [id]))
            service.runner(for: anna).run()
        }
        // Unknown thread: declined by itself.
        let stranger = "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c"
        try ask(stranger, thread: UUID().uuidString.lowercased())
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "request.decide" && $0.orderKey == "exec:req:\(stranger)" } }
        let declined = try XCTUnwrap(executorCommands(service).last { $0.type == "request.decide" && $0.orderKey == "exec:req:\(stranger)" })
        let args = try JSONDecoder().decode(ChatCommandEnvelope.self, from: declined.bodyBytes).args
        XCTAssertEqual(args["allow"], .bool(false))
        XCTAssertEqual(args["reason"], .string("unknown_thread"))
        // Its own thread: received, decided by the button, run in the same conversation.
        let next = "6f5e4d3c-2b1a-4098-8e7d-6c5b4a3f2e1d"
        try ask(next, thread: req)
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "request.received" && $0.orderKey == "exec:req:\(next)" } }
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "request.decide" && $0.orderKey == "exec:req:\(next)" })
        // The thread is in the run's parameters by its key; its conversation
        // is the start's to choose (F6, D9).
        let launch = try XCTUnwrap(service.launchRequest(next))
        XCTAssertEqual(launch.thread, "personal:\(req)")
        XCTAssertNil(launch.conversationId)

        // The journal is every server's: a run of another organization under
        // the same request id is not this thread's (review D5b-1).
        let otherKey = ChatOrgKey(server: server, accountId: CallJSON.anna, orgId: "00000000-0000-4000-8000-0000000000b2")
        let journal = try XCTUnwrap(service.journal)
        let reused = "4d3c2b1a-0f9e-4d8c-8b7a-6f5e4d3c2b1a"
        let foreignRequest = TeamLaunchRequest(requestId: reused, prompt: "x", context: nil, callerName: "B", callerProject: nil,
                                               conversationId: nil, expiresAt: Date().addingTimeInterval(3600))
        let foreign = try TeamApprovals.make(request: foreignRequest, agent: billing, key: otherKey, generation: "g1")
        try journal.insert(foreign)
        XCTAssertTrue(try journal.consume(foreign, run: ChatRunRecord(runId: foreign.runId, requestId: reused, approvalId: foreign.id,
                                                                     agentId: foreign.agentId, conversationId: "someone-elses", pid: 1, pgid: 1,
                                                                     processStartedAt: 1, startedAt: Date())))
        XCTAssertTrue(try journal.finish(foreign.runId, .finished, result: "secret"))
        var earlier = CallJSON.request(reused, state: "finished", version: 6, onThisDevice: true)
        earlier["agent_id"] = billing.id.uuidString.lowercased()
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(earlier)]))
        // A run of an earlier server generation is not this server's
        // conversation, even for the same initiator (review D5b2-1).
        let firstConversation = try XCTUnwrap(XCTUnwrap(service.journal).run(first.runId)?.conversationId)
        let restored = try service.threadLookup(XCTUnwrap(store.calls.request(next)), store: store, key: anna)
        XCTAssertEqual(restored, .known(conversation: firstConversation), "this generation's")
        let agentId = billing.id.uuidString.lowercased()
        // Whose thread it is, chosen explicitly — no case checks nothing (lead's rule on 7a17ada).
        XCTAssertEqual(service.latestConversation([req], key: anna, agentId: agentId, scope: .personal(initiator: CallJSON.boris)), firstConversation)
        XCTAssertNil(service.latestConversation([req], key: anna, agentId: agentId, scope: .personal(initiator: "someone-else")))
        XCTAssertNil(service.latestConversation([req], key: anna, agentId: agentId, scope: .channel(channelId: "c", rootId: "r")),
                     "a personal call's run is no channel's thread")
        let kept = try XCTUnwrap(service.journal).generation(anna).generation ?? ""
        try XCTUnwrap(service.journal).finish(anna, "g-restored")
        let after = try service.threadLookup(XCTUnwrap(store.calls.request(next)), store: store, key: anna)
        XCTAssertEqual(after, .unknown, "an earlier generation's run")
        try XCTUnwrap(service.journal).finish(anna, kept)

        // The cache read anew says this conversation's request id is another
        // initiator's: the journal's initiator rules, not the server's word now (review D5b2-1).
        let original = req
        try await store.queue.write { db in try db.execute(sql: "DELETE FROM requests WHERE request_id = ?", arguments: [original]) }
        var stolen = CallJSON.request(req, state: "finished", version: 9, onThisDevice: true)
        stolen["agent_id"] = billing.id.uuidString.lowercased()
        stolen["initiator_account_id"] = "99999999-9999-4999-8999-999999999999"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(stolen)]))
        let thief = "2b1a0f9e-8d7c-4b6a-9f5e-4d3c2b1a0f9e"
        var asked = CallJSON.request(thief, state: "submitted", version: 1, onThisDevice: true)
        asked["agent_id"] = billing.id.uuidString.lowercased()
        asked["conditions_version"] = 1
        asked["thread_id"] = req
        asked["initiator_account_id"] = "99999999-9999-4999-8999-999999999999"
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(asked)]), facts: service.localFacts(anna, [thief]))
        service.runner(for: anna).run()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "request.decide" && $0.orderKey == "exec:req:\(thief)" } }
        let denied = try XCTUnwrap(executorCommands(service).last { $0.type == "request.decide" && $0.orderKey == "exec:req:\(thief)" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: denied.bodyBytes).args["reason"], .string("unknown_thread"))

        let probe = "3c2b1a0f-9e8d-4c7b-8a6f-5e4d3c2b1a0f"
        try ask(probe, thread: reused)
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "request.decide" && $0.orderKey == "exec:req:\(probe)" } }
        let refusal = try XCTUnwrap(executorCommands(service).last { $0.type == "request.decide" && $0.orderKey == "exec:req:\(probe)" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: refusal.bodyBytes).args["reason"], .string("unknown_thread"))
    }

    /// Two Allows of one thread before its first run (F6, D9): the second
    /// waits in `approved` — the agent's slot is taken before `run.start` —
    /// and starts after the first, resuming the first's conversation; the
    /// first's end voids nothing. Had the first made none, it starts its own.
    func testTwoAllowsOfOneThreadShareItsConversation() async throws { try await twoAllows(firstAnswers: true) }
    func testTwoAllowsOfOneThreadWhoseFirstMadeNoneStartTheirOwn() async throws { try await twoAllows(firstAnswers: false) }

    private func twoAllows(firstAnswers: Bool) async throws {
        do {
            let runner = OwnerRunner()
            if !firstAnswers { runner.answer = TeamRunResult(text: "", isError: true, turns: 1, durationMs: 1) }
            let (service, team, store, billing, _) = try await ownerSetup(runner)
            let b = "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d"
            func move(_ id: String, _ state: String, _ version: Int, thread: String? = nil, runId: String? = nil) throws {
                var body = CallJSON.request(id, state: state, version: version, runId: runId, onThisDevice: true)
                body["agent_id"] = billing.id.uuidString.lowercased()
                if let thread { body["thread_id"] = thread }
                try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(body)]), facts: service.localFacts(anna, [id]))
                service.runner(for: anna).run()
            }
            try move(req, "awaiting_decision", 2)
            try move(b, "awaiting_decision", 2, thread: req)
            team.calls.reload()
            XCTAssertNil(team.calls.decide(req, allow: true))
            XCTAssertNil(team.calls.decide(b, allow: true))
            let journal = try XCTUnwrap(service.journal)
            let first = try XCTUnwrap(journal.approval(anna, requestId: req)), second = try XCTUnwrap(journal.approval(anna, requestId: b))
            try move(req, "approved", 3)
            try move(b, "approved", 3, thread: req)
            try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.start" && $0.orderKey == "exec:run:\(first.runId)" } }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.start" && $0.orderKey == "exec:run:\(second.runId)" },
                           "the second waits in approved: the agent's slot is the first's")
            try move(req, "starting", 4, runId: first.runId)
            try await waitUntil { runner.waiting == 1 }
            runner.release()
            try await waitUntil { try journal.run(first.runId)?.outcome != nil }
            try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.start" && $0.orderKey == "exec:run:\(second.runId)" } }
            try move(b, "starting", 4, thread: req, runId: second.runId)
            try await waitUntil { runner.waiting == 1 }
            XCTAssertNil(try journal.approval(second.id)?.voidAt, "the first's end voids nothing")
            let resumed = try XCTUnwrap(runner.requests.last)
            if firstAnswers {
                XCTAssertTrue(resumed.resume)
                XCTAssertEqual(resumed.sessionId, try journal.run(first.runId)?.conversationId, "the first's conversation")
            } else {
                XCTAssertFalse(resumed.resume, "the first made none: its own")
            }
            XCTAssertEqual(try journal.run(second.runId)?.conversationId, resumed.sessionId, "written with the row, before the process")
            // A folder granted: the continuation goes on in its own run's
            // conversation as chosen at the start, with no new search (F6).
            // (A run that answers: the error the other variant gives ends it.)
            if firstAnswers {
                XCTAssertNil(service.continueRun(b, folders: ["/tmp"]))
                runner.release()
                try await waitUntil { runner.calls == 3 }
                XCTAssertEqual(runner.requests.last?.sessionId, resumed.sessionId)
            }
            runner.release()
        }
    }

    /// A request waiting for this owner is told once, without content (F4):
    /// `notify_decision` marks it in the organization's cache.
    func testARequestWaitingForTheOwnerIsToldOnce() async throws {
        let (service, _, store, billing, _) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        let id = req
        try await waitUntil {
            try store.queue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM notified WHERE kind = 'decision' AND object_id = ?", arguments: [id])
            } == 1
        }
    }

    /// Two kept over a restart, both with `run.start` told (as before the slot
    /// was taken first): the earlier goes first, the later after it — never
    /// waiting for each other (review D9-1).
    func testTwoStartsKeptOverARestartGoInOrder() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let b = "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d"
        func move(_ id: String, _ state: String, _ version: Int, runId: String? = nil) throws {
            var body = CallJSON.request(id, state: state, version: version, runId: runId, onThisDevice: true)
            body["agent_id"] = billing.id.uuidString.lowercased()
            try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(body)]), facts: service.localFacts(anna, [id]))
            service.runner(for: anna).run()
        }
        try move(req, "awaiting_decision", 2)
        try move(b, "awaiting_decision", 2)
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertNil(team.calls.decide(b, allow: true))
        let journal = try XCTUnwrap(service.journal)
        let first = try XCTUnwrap(journal.approval(anna, requestId: req)), second = try XCTUnwrap(journal.approval(anna, requestId: b))
        // Both told `run.start`, as an earlier build did.
        for approval in [first, second] {
            let args: ChatJSON = .object(["request_id": .string(approval.requestId), "run_id": .string(approval.runId)])
            let bytes = try ChatCommandEnvelope(commandId: approval.startCommandId, org: org, type: "run.start", args: args).encoded()
            _ = try journal.runCommands(anna).enqueue(ChatCommandRecord(commandId: approval.startCommandId, sessionId: "s", type: "run.start",
                                                                        bodyBytes: bytes, orderKey: "exec:run:\(approval.runId)", dependsOn: nil,
                                                                        createdAt: Date(), state: .sent))
        }
        try move(b, "starting", 4, runId: second.runId)
        try move(req, "starting", 4, runId: first.runId)
        try await waitUntil { runner.waiting == 1 }
        XCTAssertNotNil(try journal.run(first.runId), "the earlier first")
        XCTAssertNil(try journal.run(second.runId))
        runner.release()
        try await waitUntil { try journal.run(second.runId) != nil }
        runner.release()
    }

    /// No fact of an approval set aside is written, whatever path writes it —
    /// read in the writing transaction (review D9-2).
    func testNoFactOfAnApprovalSetAside() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        let journal = try XCTUnwrap(service.journal)
        let run = try XCTUnwrap(journal.run(approval.runId))
        try journalWrite(service, "UPDATE approvals SET kind = 'superseded:' || id WHERE id = ?", [approval.id])
        try service.tellStopFailed(run, reason: "processes_unknown")
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stop_failed" })
        runner.release()
    }

    /// The texts of `request.create`'s refusals and of a run failed for a cause (D5b §3.3).
    func testTheCallersTexts() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        let rows: [(String, String, Int, String?, String?)] = [
            ("r-404", "failed", 0, "not_found", nil), ("r-409", "failed", 0, "agent_unavailable", nil), ("r-429", "failed", 0, "rate_limited", nil),
            ("r-gone", "failed", 7, "owner_removed", "owner_removed"),
        ]
        try store.apply(ChatSnapshot(cursors: [:], requests: rows.map { id, state, version, reason, cause in
            var body = CallJSON.request(id, state: state, version: version, owner: CallJSON.anna, initiator: CallJSON.boris)
            body["failure_reason"] = reason
            body["cause"] = cause
            return CallJSON.wire(body)
        }))
        let service = team()
        service.calls.useServer(store.calls, key: boris)
        func detail(_ id: String) -> String? { service.calls.outgoing(id)?.report.detail }
        XCTAssertEqual(detail("r-404"), "Not sent: the agent is not available or does not exist.")
        XCTAssertEqual(detail("r-409"), "Not sent: the agent is turned off, or its owner's Mac is not signed in.")
        XCTAssertEqual(detail("r-429"), "Not sent: too many calls are waiting; try again later.")
        XCTAssertEqual(detail("r-gone"), "The agent's owner is no longer in the organization.")
    }

    /// The stop's fact is a debt as any end: refused (`403`, the earlier
    /// session open), the row being stopped tells it again after a pause; one
    /// not taken by a new generation is made anew (review D4b-p1-3).
    func testAStopNotConfirmedIsToldUntilTaken() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.runner(for: anna).rewriteDelay = .milliseconds(200)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'run.stop_failed'")
        let refused = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        service.commandAnswered(anna, refused, .refused("forbidden"))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        // Not taken by a new generation: made anew.
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE type = 'run.stop_failed' AND state = 'pending'")
        try XCTUnwrap(service.journal).finish(anna, "g2")
        try store.beginGeneration("g2")
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire({ var b = incoming(billing, state: "stop_requested", version: 6); b["run_id"] = approval.runId; return b }())]),
                        facts: service.localFacts(anna, [req]))
        service.runner(for: anna).run()
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
    }

    /// Cancel and Stop go in their own order, by request: never behind another
    /// call's commands; after their own `request.create` while it is on its
    /// way (review D4b-p2-2).
    func testCancelGoesInItsOwnOrder() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-out", state: "awaiting_decision", version: 2, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        team.calls.reload()
        XCTAssertNil(service.askToEnd(anna, "r-out", type: "request.cancel", states: nil))
        let cancel = try XCTUnwrap(store.outbox.commands().last)
        XCTAssertEqual(cancel.type, "request.cancel")
        XCTAssertEqual(cancel.orderKey, "out:r-out")
        XCTAssertNil(cancel.dependsOn, "its create already taken")
        // A call still being made: the cancel waits for its own create only.
        let create = try service.enqueue(anna, type: "request.create", args: .object(["request_id": .string("r-new")]))
        try store.apply(ChatSnapshot(cursors: [:], requests: [
            CallJSON.wire(CallJSON.request("r-new", state: "submitted", version: 1, owner: CallJSON.boris, initiator: CallJSON.anna)),
        ]))
        XCTAssertNil(service.askToEnd(anna, "r-new", type: "request.cancel", states: nil))
        let second = try XCTUnwrap(store.outbox.commands().last)
        XCTAssertEqual(second.orderKey, "out:r-new")
        XCTAssertEqual(second.dependsOn, create.commandId)
    }

    // MARK: D4b round 2: one session, continuations that fail

    /// Another session of this Mac is as `4401` for what the earlier one
    /// began: its runs stop, its continuations and folder grants are void,
    /// nothing carries over (lead's rule on review D4b2-A).
    func testAnotherSessionStopsRunsAndVoidsContinuations() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        XCTAssertNil(service.continueRun(req, folders: ["/tmp"]))
        let journal = try XCTUnwrap(service.journal)
        let continuation = try XCTUnwrap(journal.pendingContinuation(of: approval))
        try service.saveSignIn(ChatConnection(server: server, accountId: CallJSON.anna, sessionId: "s-new", deviceName: "Mac", orgId: org),
                               token: "aps_new")
        XCTAssertEqual(try journal.approval(continuation.id)?.voidReason, "executor_signed_out")
        try await waitUntil { try XCTUnwrap(service.launcher).live.isEmpty }
        XCTAssertEqual(runner.calls, 1, "nothing goes on")
    }

    /// A continuation promised and voided meanwhile (a new generation): the
    /// run fails with why — never ends with the reply it gave while waiting
    /// (review D4b2-4).
    func testAVoidedContinuationFailsTheRun() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        XCTAssertNil(service.continueRun(req, folders: ["/tmp"]))
        let journal = try XCTUnwrap(service.journal)
        let continuation = try XCTUnwrap(journal.pendingContinuation(of: approval))
        XCTAssertTrue(try journal.void(continuation.id, reason: "server_restored"))
        runner.release()
        try await waitUntil { try journal.run(approval.runId)?.outcome == .failed }
        XCTAssertEqual(runner.calls, 1)
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "result.deliver" })
    }

    /// A continuation whose process cannot be made: the run failed — not
    /// "did not start"; it ran, so being stopped it is not `run.stopped`
    /// (review D4b2-3).
    func testAContinuationThatCannotStartFailsTheRun() async throws {
        let runner = OwnerRunner()
        runner.cannotContinue = true
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.actionHandlers[.stop] = nil
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        XCTAssertNil(service.continueRun(req, folders: ["/tmp"]))
        try server(store, service, "request.cancel", move("stop_requested", 6, runId: approval.runId))
        runner.release()
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .failed }
        try await waitUntil { try self.pendingEnds(service, approval.runId).contains("run.stop_failed") }
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stopped" })
        // Built again from the journal (its process fields cleared for the
        // continuation): it still ran — not `run.stopped`.
        service.runner(for: anna).rewriteDelay = .milliseconds(100)
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'invalid_state' WHERE type = 'run.stop_failed'")
        let refused = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        service.commandAnswered(anna, refused, .refused("invalid_state"))
        try await waitUntil { try self.pendingEnds(service, approval.runId).contains("run.stop_failed") }
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stopped" })
    }

    /// A cancel waits for its call's `request.create` as it is in the same
    /// transaction — the one a new session made of it (review D4b2-p1-5).
    func testACancelWaitsForTheCreateThatIsThere() throws {
        let store = try ChatStore.open(files: files, key: boris).store
        let table = store.outbox
        func create(_ id: String, _ state: ChatCommandRecord.State) throws {
            let body = try ChatCommandEnvelope(commandId: id, org: org, type: "request.create", args: .object(["request_id": .string("r-x")])).encoded()
            _ = try table.enqueue(ChatCommandRecord(commandId: id, sessionId: "s", type: "request.create", bodyBytes: body, orderKey: org,
                                                    dependsOn: nil, createdAt: Date(), state: state))
        }
        let otherBody = try ChatCommandEnvelope(commandId: "c-other", org: org, type: "request.create", args: .object(["request_id": .string("r-y")])).encoded()
        _ = try table.enqueue(ChatCommandRecord(commandId: "c-other", sessionId: "s", type: "request.create", bodyBytes: otherBody, orderKey: org,
                                                dependsOn: nil, createdAt: Date(), state: .pending))
        try create("c-old", .dropped)
        try create("c-new", .pending)
        let body = try ChatCommandEnvelope(commandId: "k", org: org, type: "request.cancel", args: .object(["request_id": .string("r-x")])).encoded()
        let cancel = try table.enqueue(ChatCommandRecord(commandId: "k", sessionId: "s", type: "request.cancel", bodyBytes: body, orderKey: "out:r-x",
                                                         dependsOn: nil, createdAt: Date(), state: .pending), afterCreateOf: "r-x", seq: 10)
        XCTAssertEqual(cancel.dependsOn, "c-new")
    }

    /// A fact refused because its request had ended (its old session
    /// closed by the server) is paid: never asked again (server d8d2ea0).
    func testAFactOfAnEndedRequestIsPaid() async throws {
        let runner = OwnerRunner()
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.runner(for: anna).rewriteDelay = .milliseconds(100)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = ? WHERE type = 'run.stop_failed'", [ChatOutbox.requestEnded])
        let refused = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        service.commandAnswered(anna, refused, .refused(ChatOutbox.requestEnded))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try pendingEnds(service, approval.runId), [], "paid")
    }

    /// A call's `request.create` goes in its own order: a `429` of one call
    /// holds no other (review D5b2-3).
    func testACallsCreateGoesInItsOwnOrder() async throws {
        let (service, team, store, _, _) = try await ownerSetup()
        _ = team
        let made = try service.prepareCommand(anna, type: "request.create", args: .object(["request_id": .string("r-own")]))
        XCTAssertEqual(made.record.orderKey, "out:r-own")
        _ = store
    }

    func testY5StopReasonsAndFactPlan() {
        XCTAssertNil(TeamStopOutcome.stopped.stopFailedReason)
        XCTAssertEqual(TeamStopOutcome.stillAlive([]).stopFailedReason, "processes_alive")
        XCTAssertEqual(TeamStopOutcome.unknown("unreadable").stopFailedReason, "processes_unknown")
        XCTAssertEqual(ChatFactChain.plan(state: .stopRequested, outcome: .stoppedLocally, stopConfirmed: true,
                                         hasResult: false, answered: false), ["run.stopped"])
        XCTAssertEqual(ChatFactChain.plan(state: .stopRequested, outcome: .stoppedLocally, stopConfirmed: false,
                                         hasResult: false, answered: false), ["run.stop_failed"])
    }

    /// The runner's actual verdict reaches the journal and the server's
    /// fact, also after that fact needs to be sent again.
    func testY5ConfirmedStopIsToldAndRetriedAsStopped() async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = .stopped
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .stoppedLocally }
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stopped"])
        let row = try XCTUnwrap(XCTUnwrap(service.journal).run(approval.runId))
        XCTAssertNotNil(row.stopConfirmedAt)
        XCTAssertNotNil(row.processesGoneAt)
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE type = 'run.stopped'")
        _ = try service.tellRun(approval.runId)
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stopped"])
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stop_failed" })
    }

    func testY2ServiceStopIsToldWithoutExecutorStarted() async throws {
        let runner = OwnerRunner()
        runner.tellsProcess = false
        runner.preflightStopError = .cancelledBeforeExecutor
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 5, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stopped"] }
        let row = try XCTUnwrap(XCTUnwrap(service.journal).run(approval.runId))
        XCTAssertEqual(row.outcome, .stoppedLocally)
        XCTAssertNotNil(row.processesGoneAt)
        XCTAssertNotNil(row.stopConfirmedAt)
        XCTAssertNil(row.pid)
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.started" })
        try journalWrite(service, "UPDATE run_commands SET state = 'unconfirmed' WHERE type = 'run.stopped'")
        _ = try service.tellRun(approval.runId)
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stopped"])
        XCTAssertEqual(runner.calls, 1)
    }

    func testY2ServiceCleanupFailureReasonSurvivesRecoveryAndStopRetry() async throws {
        let runner = OwnerRunner()
        runner.tellsProcess = false
        runner.preflightStopError = .preflightCleanupUnconfirmed(.init(pid: 900_004, pgid: 900_004, startTime: 4), .unknown("output open"))
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 5, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        let row = try XCTUnwrap(XCTUnwrap(service.journal).run(approval.runId))
        XCTAssertNil(row.outcome); XCTAssertNil(row.pid); XCTAssertNil(row.processesGoneAt)
        XCTAssertEqual(row.preflightPID, 900_004)
        for kind in [ChatActionKind.recover, .stop] {
            try journalWrite(service, "DELETE FROM run_commands WHERE type = 'run.stop_failed'")
            let handler = ChatOwnerSide(service: service)
            _ = await handler.perform(kind, request: try XCTUnwrap(store.calls.request(req)), key: anna)
            let fact = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
            XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["reason"], .string("preflight_cleanup_unconfirmed"))
        }
        // The owner's later confirmation closes the local row but does not
        // change the service stop's reason when its fact must be rebuilt.
        let recovery = try XCTUnwrap(service.recovery)
        recovery.find = { _ in [] }
        _ = await recovery.check()
        let problem = await recovery.confirmGone(approval.runId)
        XCTAssertNil(problem)
        try journalWrite(service, "DELETE FROM run_commands WHERE type = 'run.stop_failed'")
        _ = try service.tellRun(approval.runId)
        let rebuilt = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: rebuilt.bodyBytes).args["reason"], .string("preflight_cleanup_unconfirmed"))
        XCTAssertFalse(try executorCommands(service).contains { ["run.started", "run.stopped", "run.failed_to_start"].contains($0.type) })
    }

    func testY5StillAliveStopStaysFailedAfterTheyAreGone() async throws {
        try await checkY5UnconfirmedStop(.stillAlive([ProcessIdentity(pid: 900_001, startTime: 1)]), reason: "processes_alive")
    }

    /// The stop finished while the request's state was unavailable; a later
    /// recover action must use the saved verdict rather than tell stop_failed.
    func testY5ConfirmedStopWaitsForTheServerAndRecoversAsStopped() async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = .stopped
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.actionHandlers[.stop] = nil
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        let launcher = try XCTUnwrap(service.launcher)
        let stopped = try await launcher.stopForServer(approval.runId)
        XCTAssertEqual(stopped, .stopped)
        let journal = try XCTUnwrap(service.journal)
        XCTAssertNil(try journal.run(approval.runId)?.outcome)
        XCTAssertNotNil(try journal.run(approval.runId)?.stopConfirmedAt)
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        let request = try XCTUnwrap(store.calls.request(req))
        let handler = ChatOwnerSide(service: service)
        _ = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stopped"])
        XCTAssertEqual(try journal.run(approval.runId)?.outcome, .stoppedLocally)
    }

    func testY5UnknownStopStaysFailedAfterTheyAreGone() async throws {
        try await checkY5UnconfirmedStop(.unknown("output is open"), reason: "processes_unknown")
    }

    func testY5UnknownStopWithoutAPIDStaysFailedAfterTheyAreGone() async throws {
        try await checkY5UnconfirmedStop(.unknown("process was not recorded"), reason: "processes_unknown", tellsProcess: false)
    }

    func testY5ConfirmedStopSurvivesAJournalWriteFailure() async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = .stopped
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.actionHandlers[.stop] = nil
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try journalWrite(service, "CREATE TRIGGER fail_stop_marker BEFORE UPDATE OF stop_reason ON runs BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        let launcher = try XCTUnwrap(service.launcher)
        do {
            _ = try await launcher.stopForServer(approval.runId)
            XCTFail("the stop action must retry the failed journal write")
        } catch {}
        XCTAssertTrue(launcher.live.isEmpty)
        XCTAssertNil(try XCTUnwrap(service.journal).run(approval.runId)?.stopConfirmedAt)
        try journalWrite(service, "DROP TRIGGER fail_stop_marker")
        // The action can try again after the live run is gone.
        let request = try XCTUnwrap(store.calls.request(req))
        let handler = ChatOwnerSide(service: service)
        _ = await handler.perform(.stop, request: request, key: anna)
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stopped"])
        XCTAssertNotNil(try XCTUnwrap(service.journal).run(approval.runId)?.stopConfirmedAt)
    }

    @MainActor
    private final class StopAttempts: ChatActionHandler {
        let owner: ChatOwnerSide
        var results: [ChatActionResult] = []
        init(_ owner: ChatOwnerSide) { self.owner = owner }
        func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
            let result = await owner.perform(.stop, request: request, key: key)
            results.append(result)
            return result
        }
    }

    func testStopRetriesFactInsertFailureAfterSavedConfirmationWithoutAnotherEvent() async throws {
        try await stopRetriesFactInsertFailure(confirmed: true)
    }

    func testStopFailedRetriesFactInsertFailureWithoutAnotherEvent() async throws {
        try await stopRetriesFactInsertFailure(confirmed: false)
    }

    private func stopRetriesFactInsertFailure(confirmed: Bool) async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = confirmed ? .stopped : .unknown("output is open")
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let attempts = StopAttempts(try XCTUnwrap(service.owner))
        service.actionHandlers[.stop] = attempts
        service.actionHandlers[.recover] = nil
        service.actionHandlers[.deliver] = nil
        let actions = service.runner(for: anna)
        actions.rewriteDelay = .milliseconds(300)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try journalWrite(service, "CREATE TRIGGER fail_stop_fact BEFORE INSERT ON run_commands WHEN NEW.type IN ('run.stopped', 'run.stop_failed') BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { !attempts.results.isEmpty }
        XCTAssertEqual(attempts.results, [.retry])
        let journal = try XCTUnwrap(service.journal)
        let row = try XCTUnwrap(journal.run(approval.runId))
        XCTAssertEqual(row.stopConfirmedAt != nil, confirmed, "the verdict was saved before the failing fact insert")
        XCTAssertNotNil(row.stopReason)
        XCTAssertNil(row.outcome, "the outcome/fact transaction rolled back")
        XCTAssertEqual(try pendingEnds(service, approval.runId), [])
        for _ in 0..<5 { actions.run() }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(attempts.results.count, 1, "other wakes must respect the retry pause")
        // The live run and its in-memory verdict are gone: exercise the
        // second stop branch using only the persisted confirmation.
        try await waitUntil { attempts.results.count >= 2 }
        XCTAssertEqual(attempts.results, [.retry, .retry])
        XCTAssertNil(try journal.run(approval.runId)?.outcome)
        try journalWrite(service, "DROP TRIGGER fail_stop_fact")
        // No event, recovery check or explicit run() after the disk recovers.
        try await waitUntil { attempts.results.last == .done }
        XCTAssertEqual(try pendingEnds(service, approval.runId), [confirmed ? "run.stopped" : "run.stop_failed"])
        XCTAssertEqual(try journal.run(approval.runId)?.outcome, confirmed ? .stoppedLocally : nil)
        XCTAssertEqual(runner.calls, 1)
    }

    func testRecoverRetriesOutcomeAndFactDebtAfterSavedConfirmation() async throws {
        try await recoverRetriesOutcomeAndFactDebt(confirmed: true)
    }

    func testRecoverRetriesOutcomeAndStopFailedDebtAfterProcessesGone() async throws {
        try await recoverRetriesOutcomeAndFactDebt(confirmed: false)
    }

    private func recoverRetriesOutcomeAndFactDebt(confirmed: Bool) async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = confirmed ? .stopped : .unknown("output is open")
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        service.actionHandlers[.stop] = nil
        service.actionHandlers[.recover] = nil
        service.actionHandlers[.deliver] = nil
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        _ = try await XCTUnwrap(service.launcher).stopForServer(approval.runId)
        let journal = try XCTUnwrap(service.journal)
        XCTAssertEqual(try journal.run(approval.runId)?.stopConfirmedAt != nil, confirmed)
        // For an unconfirmed stop, a later manual check has established
        // absence; it must retain stop_failed while closing the local row.
        if !confirmed { try journal.markProcessesGone(approval.runId) }
        try journalWrite(service, "CREATE TRIGGER fail_recovered_fact BEFORE INSERT ON run_commands WHEN NEW.type IN ('run.stopped', 'run.stop_failed') BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        let request = try XCTUnwrap(store.calls.request(req))
        let handler = ChatOwnerSide(service: service)
        let failed = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(failed, .retry, "check() succeeded but left a write debt")
        XCTAssertNil(try journal.run(approval.runId)?.outcome)
        XCTAssertEqual(service.recovery?.awaitingFact.map(\.runId), [approval.runId])
        XCTAssertEqual(try pendingEnds(service, approval.runId), [])
        try journalWrite(service, "DROP TRIGGER fail_recovered_fact")
        let waiting = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(waiting, .later, "the written fact still awaits the server")
        XCTAssertEqual(try journal.run(approval.runId)?.outcome, .stoppedLocally)
        let fact = confirmed ? "run.stopped" : "run.stop_failed"
        XCTAssertEqual(try pendingEnds(service, approval.runId), [fact])
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = ?", [fact])
        let paused = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(paused, .retry)
        let resent = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(resent, .later)
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE type = ? AND state = 'pending'", [fact])
        let paid = await handler.perform(.recover, request: request, key: anna)
        XCTAssertEqual(paid, .done)
        XCTAssertEqual(runner.calls, 1)
    }

    private func checkY5UnconfirmedStop(_ outcome: TeamStopOutcome, reason: String, tellsProcess: Bool = true) async throws {
        let runner = OwnerRunner()
        runner.stopOutcome = outcome
        runner.tellsProcess = tellsProcess
        let (service, team, store, billing, _) = try await ownerSetup(runner)
        let approval = try allowedUpTo("starting", service, team, store, billing)
        try await waitUntil { runner.waiting == 1 }
        try server(store, service, "run.started", move("running", 5, runId: approval.runId))
        try journalWrite(service, "UPDATE run_commands SET state = 'sent', sent_generation = 'g1' WHERE state = 'pending'")
        try server(store, service, "request.stop", move("stop_requested", 6, runId: approval.runId))
        try await waitUntil { try self.pendingEnds(service, approval.runId) == ["run.stop_failed"] }
        let fact = try XCTUnwrap(executorCommands(service).last { $0.type == "run.stop_failed" })
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: fact.bodyBytes).args["reason"], .string(reason))
        let journal = try XCTUnwrap(service.journal)
        XCTAssertNil(try journal.run(approval.runId)?.outcome)
        XCTAssertNil(try journal.run(approval.runId)?.stopConfirmedAt)
        let recovery = try XCTUnwrap(service.recovery)
        recovery.find = { _ in [] }
        await recovery.check()
        let problem = await recovery.confirmGone(approval.runId)
        XCTAssertNil(problem)
        XCTAssertEqual(try journal.run(approval.runId)?.outcome, .stoppedLocally)
        XCTAssertNil(try journal.run(approval.runId)?.stopConfirmedAt, "the owner's word is not Y5's verdict")
        // With the earlier fact absent, plan must still independently pick
        // stop_failed; insertChain's duplicate guard cannot hide a regression.
        try journalWrite(service, "DELETE FROM run_commands WHERE type = 'run.stop_failed'")
        _ = try service.tellRun(approval.runId)
        XCTAssertEqual(try pendingEnds(service, approval.runId), ["run.stop_failed"])
        XCTAssertFalse(try executorCommands(service).contains { $0.type == "run.stopped" })
    }

    func testResultLostExplainsTheOutcomeToTheInitiator() throws {
        let store = try ChatStore.open(files: files, key: anna).store
        var wire = CallJSON.wire(CallJSON.request("r-result-lost", state: "failed", version: 8,
                                                 owner: CallJSON.boris, initiator: CallJSON.anna))
        wire.cause = "result_lost"
        wire.failureReason = "result_lost"
        try store.apply(ChatSnapshot(cursors: [:], requests: [wire]))
        let service = team()
        service.calls.useServer(store.calls, key: anna)
        let report = try XCTUnwrap(service.calls.outgoing.first { $0.id == wire.requestId }?.report)
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.detail, "The result was lost after the server was restored. The agent was not run again.")
    }

    /// The user's word to end a call and a stop's facts go to a new session
    /// (DESIGN-D3b-D4b-D5b §10.5, §11.4).
    func testTheWordsToEndACallAreCarriedOver() {
        for type in ["request.cancel", "request.stop", "run.stopped", "run.stop_failed", "request.create"] {
            XCTAssertTrue(ChatOutbox.carriedOver.contains(type), type)
        }
    }

    /// Signed in again before the run started (DESIGN-D4 §0.3): the approval
    /// is voided, not spent, `run.failed_to_start` goes; refused while the
    /// earlier session is open (`403`), the action waits and sends it again
    /// at the next turn — also after a restart (review D4b-3).
    func testAStartLeftByAnEarlierSessionFailsAndWaitsWhileRefused() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        // The new session sees the request as another session's.
        var starting = move("starting", 4, runId: approval.runId)
        starting["on_this_device"] = false
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire({ var b = incoming(billing, state: "starting", version: 4); b["run_id"] = approval.runId; b["on_this_device"] = false; return b }())]),
                        facts: service.localFacts(anna, [req]))
        _ = starting
        service.runner(for: anna).run()
        try await waitUntil { try self.executorCommands(service).contains { $0.type == "run.failed_to_start" } }
        XCTAssertEqual(try XCTUnwrap(service.journal).approval(approval.id)?.voidReason, "executor_signed_out")
        XCTAssertEqual(runner.calls, 0)
        // Refused: the earlier session is still open. Sent again — after a
        // pause, not at once (review D4b-p1-2).
        service.runner(for: anna).rewriteDelay = .milliseconds(300)
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'run.failed_to_start'")
        service.runner(for: anna).run()
        try await Task.sleep(for: .milliseconds(100))
        service.runner(for: anna).run()
        XCTAssertEqual(try executorCommands(service).filter { $0.type == "run.failed_to_start" && $0.state == .pending }.count, 0, "not at once")
        try await waitUntil { try self.executorCommands(service).filter { $0.type == "run.failed_to_start" && $0.state == .pending }.count == 1 }
        // A restart: the action is still in progress in the cache, and goes on.
        try journalWrite(service, "UPDATE run_commands SET state = 'failed', error = 'forbidden' WHERE type = 'run.failed_to_start'")
        let fresh = ChatActionRunner(key: anna, calls: store.calls)
        fresh.rewriteDelay = .milliseconds(50)
        fresh.handler = { service.actionHandlers[$0] }
        fresh.run()
        try await waitUntil { try self.executorCommands(service).filter { $0.type == "run.failed_to_start" && $0.state == .pending }.count == 1 }
    }

    /// A passing write failure in a handler is tried again after a pause,
    /// with no other event (DESIGN-D4 §0.4).
    func testAPassingWriteFailureIsTriedAgain() async throws {
        let (service, _, store, billing, _) = try await ownerSetup()
        let owner = try XCTUnwrap(service.owner)
        service.runner(for: anna).rewriteDelay = .milliseconds(50)
        var fails = 1
        owner.writeFails = {
            defer { fails -= 1 }
            return fails > 0
        }
        try server(store, service, "request.create", incoming(billing))
        try await waitUntil { try self.executorCommands(service).map(\.type) == ["request.received"] }
    }

    /// A result not delivered is the owner's to see, from the journal —
    /// also after Disconnect, with no connection (D4(10), review D4b-4).
    func testAResultNotDeliveredIsShownFromTheJournal() async throws {
        let (service, team, store, billing, runner) = try await ownerSetup()
        runner.holds = false
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        team.calls.reload()
        XCTAssertNil(team.calls.decide(req, allow: true))
        let approval = try XCTUnwrap(XCTUnwrap(service.journal).approval(anna, requestId: req))
        try server(store, service, "request.decide", move("approved", 3))
        try server(store, service, "run.start", move("starting", 4, runId: approval.runId))
        try await waitUntil { try XCTUnwrap(service.journal).run(approval.runId)?.outcome == .finished }
        XCTAssertEqual(service.undeliveredResults().map(\.text), ["Refunded twice by a retry."])
        await service.disconnect()
        XCTAssertEqual(service.undeliveredResults().map(\.text), ["Refunded twice by a retry."], "after Disconnect, from the journal")
        let again = ChatService(files: files, tokens: FakeTokenStore())
        services.append(again)
        await again.recoverRunsAtLaunch()
        XCTAssertEqual(again.undeliveredResults().map(\.requestId), [req], "after a restart without a connection")
    }

    /// Two server runs on this Mac, one per agent (D4(13), DESIGN-D4 §0.5).
    func testTheSlotsOfServerRuns() {
        XCTAssertTrue(ChatOwnerSide.slotFree(busy: [], agentId: "a"))
        XCTAssertFalse(ChatOwnerSide.slotFree(busy: ["a"], agentId: "a"), "one per agent")
        XCTAssertTrue(ChatOwnerSide.slotFree(busy: ["b"], agentId: "a"))
        XCTAssertFalse(ChatOwnerSide.slotFree(busy: ["b", "c"], agentId: "a"), "two per Mac")
    }

    /// The owner's side turns asks on, and tells a request waiting for the
    /// owner's decision once (DESIGN-D4 §1).
    func testTheOwnersSideIsInstalled() async throws {
        ChatOutgoing.asksOn = false
        defer { ChatOutgoing.asksOn = false }
        let (service, team, store, billing, _) = try await ownerSetup()
        XCTAssertTrue(ChatOutgoing.asksOn)
        XCTAssertTrue(team.calls.deliversAsks)
        var told: [String] = []
        service.onDecisionWanted = { told.append($0) }
        try server(store, service, "request.create", incoming(billing))
        try server(store, service, "request.received", move("awaiting_decision", 2))
        try await waitUntil { told == [self.req] }
        service.runner(for: anna).run()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(told, [req], "once")
    }

    /// D3(5), D3(6): a new agent through a server has the least rights; the
    /// windows say its rights (EX-7, with the Y1 gap for Edit), its memory
    /// and who may call it.
    func testNewAgentsAndWarnings() {
        XCTAssertEqual(TeamPublishedAgent.fresh(serverMode: true).access, .read)
        let edit = TeamPublishWarnings.lines(access: .edit, fromSession: true, teamNames: ["General", "Ops"])
        XCTAssertEqual(edit, [TeamPublishWarnings.edit, TeamPublishWarnings.gitDriver, TeamPublishWarnings.editShellGap,
                              TeamAccessProfile.shellWarning, TeamPublishWarnings.session, "Members of General, Ops can call it; every call still waits for your Allow."])
        let readGit = TeamPublishWarnings.lines(access: .readGit, fromSession: false, teamNames: ["General"])
        XCTAssertEqual(Array(readGit.prefix(2)), [TeamPublishWarnings.readGit, TeamPublishWarnings.gitDriver])
        // No promise of isolation the Y1 report did not prove (review D3b-p1-3).
        for text in edit + readGit {
            for promise in ["only the commands you allow", "out of its reach", "limited to its folders"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(promise), promise)
            }
        }
        XCTAssertTrue(TeamPublishWarnings.gitDriver.contains("textconv"))
        XCTAssertTrue(TeamPublishWarnings.editShellGap.contains("folders you give it"))
    }

    private func sentCommand(_ journal: ChatJournal, type: String, generation: String) throws {
        let body = try ChatCommandEnvelope(commandId: "c-\(type)", org: org, type: type,
                                           args: .object(["request_id": .string(req), "run_id": .string("run-1"), "text": .string("ok")])).encoded()
        var command = ChatCommandRecord(commandId: "c-\(type)", sessionId: "s", type: type, bodyBytes: body, orderKey: "exec:x",
                                        dependsOn: nil, createdAt: Date(), state: .sent)
        command.sentGeneration = generation
        try journal.enqueue(command, key: anna)
    }

    struct HalfBrokenStore: TeamCallStore {
        struct Broken: Error {}
        func loadLog() throws -> TeamCalls.Log { TeamCalls.Log(incoming: [], outgoing: []) }
        func loadCall(_ id: String) throws -> TeamCalls.Log { throw Broken() }
        func saveLog(_ log: TeamCalls.Log) throws {}
        func loadThreads() throws -> [TeamCalls.Thread] { [] }
        func saveThreads(_ threads: [TeamCalls.Thread]) throws {}
    }

    /// A call read by id from a store that fails says so, not "no call"
    /// (review D8g-p3-7).
    func testAReadByIdThatFailsIsAStoreProblem() async throws {
        let service = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("half")), offCalls: HalfBrokenStore())
        service.calls.useServer(nil, key: nil)
        XCTAssertNil(service.calls.outgoing("x"))
        XCTAssertNotNil(service.calls.storeProblem)
    }

    /// A call another Mac runs shows nothing of this Mac's agent of the
    /// same id; its cause is kept; expired says what is certain (review
    /// D8g-p3-8, p3-9, p3-10).
    func testAnotherMacsCallCauseAndExpiry() async throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = team()
        try await service.calls.save(TeamPublishedAgent(name: "billing", description: "d", folder: project.path))
        let agent = try XCTUnwrap(service.calls.agents.first)
        var body = CallJSON.request(req, state: "cancelled", version: 3, onThisDevice: false)
        body["agent_id"] = agent.id.uuidString.lowercased()
        body["cause"] = "initiator_removed"
        let store = try ChatStore.open(files: files, key: anna).store
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(body)]))
        service.calls.useServer(store.calls, key: anna)
        let call = try XCTUnwrap(service.calls.incoming.first)
        XCTAssertNil(service.calls.localAgent(for: call))
        XCTAssertEqual(try store.calls.request(req)?.cause, "initiator_removed")
        XCTAssertEqual(TeamRequestState.expired.meaning, "Its deadline passed before it ran, so it was given up.")
    }

    /// A decision on a folder whose check outlives a move to a server where
    /// a request of the same id and agent runs gives nothing (review D8g-p1-1).
    func testAFolderDecisionOutlivingTheMoveToTheSameIdGivesNothing() async throws {
        let (owner, runner, id, extra, links) = try await runningCallOfTheQueue()
        let asked = try await owner.calls.requestAccess(callId: id, path: extra.path, reason: "needs it")
        let store = try ChatStore.open(files: files, key: anna).store
        var same = CallJSON.request(id, state: "running", version: 5, onThisDevice: true)
        same["agent_id"] = try XCTUnwrap(owner.calls.agents.first).id.uuidString.lowercased()
        try store.apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(same)]))
        owner.calls.afterFolderCheck = { owner.calls.useServer(store.calls, key: self.anna) }
        let problem = await owner.calls.decideAccess(asked.id, .always)
        XCTAssertNotNil(problem)
        XCTAssertEqual(owner.calls.agents.first?.extraFolders ?? [], [])
        runner.release()
        await owner.calls.drain()
        XCTAssertEqual(runner.requests.count, 1)
        _ = links
    }
}
