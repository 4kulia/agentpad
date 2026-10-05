import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatSyncTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let me = "aaaaaaaa-0000-4000-8000-000000000001"
    private let boris = "bbbbbbbb-0000-4000-8000-000000000002"
    private let org = "00000000-0000-4000-8000-0000000000a1"
    private let general = "00000000-0000-4000-8000-0000000000c1"
    private let ops = "00000000-0000-4000-8000-0000000000c2"
    private var transports: [FakeSocketTransport] = []
    /// What `/state` answers: members, my teams, heads.
    private var members: [(String, String)] = []
    private var myTeams: [String] = []
    /// The user's role in the snapshot; a manager's has `admin` with these teams too.
    private var myRole = "member"
    private var otherTeams: [String] = []
    private var heads: [String: Int] = [:]
    private var accountHead = 3

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-sync-\(UUID().uuidString)")
        members = [(me, "me")]
        myTeams = [general]
        heads = ["org:\(org)": 1, "team:\(general)": 1, "member:\(org):\(me)": 1]
        serve()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        // Nothing of this test keeps talking to the next test's server.
        stateGate.open()
        for service in services {
            service.stopFeed()
            for session in service.orgSessions.values { session.sync?.stop() }
        }
        services = []
        try? FileManager.default.removeItem(at: root)
    }

    private var services: [ChatService] = []
    /// Holds `/state` answers while closed.
    private let stateGate = Gate()

    private var files: ChatFiles { ChatFiles(directory: root) }
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: me, orgId: org) }
    private var orgStream: String { "org:\(org)" }
    private var memberStream: String { "member:\(org):\(me)" }

    private func stateJSON() -> Data {
        let membersJSON = members.map { #"{"account_id":"\#($0.0)","handle":"\#($0.1)","name":"\#($0.1)","role":"\#($0.0 == me ? myRole : "member")"}"# }
        let teamsJSON = myTeams.map { #"{"team_id":"\#($0)","name":"T","is_general":\#($0 == general),"archived_at":null,"members":["\#(me)"]}"# }
        let streams = try! JSONEncoder().encode(heads)
        let adminTeams = myTeams.map { #"{"team_id":"\#($0)","name":"T","is_general":\#($0 == general),"archived_at":null,"members":["\#(me)"]}"# }
            + otherTeams.map { #"{"team_id":"\#($0)","name":"Other","is_general":false,"archived_at":null,"members":["\#(boris)"]}"# }
        let admin = ["owner", "admin"].contains(myRole) ? #"{"teams":[\#(adminTeams.joined(separator: ","))],"invitations":[]}"# : "null"
        return Data(#"""
        {"org":{"org_id":"\#(org)","name":"Rabbitshat"},"members":[\#(membersJSON.joined(separator: ","))],
         "teams":[\#(teamsJSON.joined(separator: ","))],"my_teams":\#(String(decoding: try! JSONEncoder().encode(myTeams), as: UTF8.self)),
         "admin":\#(admin),"streams":\#(String(decoding: streams, as: UTF8.self))}
        """#.utf8)
    }

    /// Answers that fail, and a /state that takes its time.
    private let failingStates = Budget(), failingMe = Budget(), slowState = Budget(), slowMe = Budget(), slowCommands = Budget()
    /// Every request answers 401 from now on: the session is closed.
    private let closedSession = Budget()
    /// The next commands answer 403 forbidden.
    private let forbiddenCommands = Budget()

    private func serve(orgsInMe: Bool = true) {
        let org = self.org, me = self.me
        let failingStates = self.failingStates, failingMe = self.failingMe, slowState = self.slowState
        let slowMe = self.slowMe, slowCommands = self.slowCommands, stateGate = self.stateGate, closedSession = self.closedSession, forbiddenCommands = self.forbiddenCommands
        let meJSON = Data(#"""
        {"account_id":"\#(me)","session_id":"s-me","orgs":[\#(orgsInMe ? #"{"org_id":"\#(org)","org_name":"Rabbitshat","role":"member","handle":"me","name":"me"}"# : "")],
         "streams":{"account:\#(me)":\#(accountHead)}}
        """#.utf8)
        let state = stateJSON()
        let info = Data(#"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws"]}"#.utf8)
        ChatStubProtocol.reset { request, _ in
            if request.url?.path == "/v1/me", failingMe.take() { return .success(.init(status: 500, body: Data(#"{"error":"internal"}"#.utf8))) }
            if request.url?.path == "/v1/me", slowMe.take() { usleep(300_000) }
            if request.url?.path == "/v1/commands", slowCommands.take() { usleep(300_000) }
            if closedSession.peek() { return .success(.init(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))) }
            if request.url?.path == "/v1/commands", forbiddenCommands.take() {
                return .success(.init(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8)))
            }
            if request.url?.path.hasSuffix("/state") == true {
                stateGate.pass()
                if slowState.take() { usleep(300_000) }
                if failingStates.take() { return .success(.init(status: 500, body: Data(#"{"error":"internal"}"#.utf8))) }
            }
            return switch request.url?.path {
            case "/v1/me": .success(.init(status: 200, body: meJSON))
            case "/v1/server": .success(.init(status: 200, body: info))
            case "/v1/orgs/\(org)/state": .success(.init(status: 200, body: state))
            case let path? where path.hasPrefix("/v1/orgs/") && path.hasSuffix("/state"):
                // Another organization of the same account: a state of its own.
                .success(.init(status: 200, body: Data(String(decoding: state, as: UTF8.self)
                    .replacingOccurrences(of: org, with: path.split(separator: "/")[2]).utf8)))
            default: .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
            }
        }
    }

    private var stateRequests: Int { ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/state") == true }.count }

    private func connected(hello: Bool = true) async throws -> ChatService {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.makeSocketTransport = { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            return t
        }
        service.followsFeed = true
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-me", deviceName: "Mac", orgId: org), token: "aps_t")
        try await service.start(mode: .server)
        try await waitUntil { !self.transports.isEmpty }
        guard hello else { return service }
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { service.socket?.state == .connected }
        return service
    }

    /// A service whose `/v1/me` fails until the test lets it, with short
    /// retries; the socket is connected (hello done) with no organization yet.
    private func connectedWithoutMe() async throws -> ChatService {
        failingMe.give(1_000)
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.makeSocketTransport = { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            return t
        }
        service.followsFeed = true
        service.retryDelay = { _ in 0.05 }
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-me", deviceName: "Mac", orgId: org), token: "aps_t")
        try await service.start(mode: .server)
        try await waitUntil { !self.transports.isEmpty }
        return service
    }

    private func hello(_ generation: String = "g1") {
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"\#(generation)","heartbeat_seconds":25,"version":"0.1.0"}"#)
    }

    private var commandRequests: Int { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count }

    private var transport: FakeSocketTransport { transports.last! }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func frame(_ stream: String, _ seq: Int, _ type: String, _ body: [String: String]) -> String {
        let bodyJSON = String(decoding: try! JSONEncoder().encode(body), as: UTF8.self)
        return #"{"frame":"event","stream":"\#(stream)","seq":\#(seq),"id":"\#(UUID())","type":"\#(type)","actor":null,"body":\#(bodyJSON),"command_id":null,"at":"2026-10-03T18:20:00Z","sig":null,"sig_alg":null,"enc":null}"#
    }

    private func store(_ service: ChatService) throws -> ChatStore { try XCTUnwrap(service.orgSessions[key]?.store) }

    nonisolated private func count(_ store: ChatStore, _ table: String) throws -> Int {
        try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0 }
    }

    private func names(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM members ORDER BY account_id") }
    }

    // MARK: Checks

    /// C16-1: /v1/me fails at start and at hello; the socket connects with
    /// no organization. /v1/me comes back, the organization's synchronizer is
    /// made, its snapshots fail past its readying, then work: a new command
    /// goes on this connection, without a reconnect.
    func testLateSynchronizerReadiesItsConnectionOnceTheSnapshotWorks() async throws {
        let service = try await connectedWithoutMe()
        hello()
        try await waitUntil { service.socket?.state == .connected }
        XCTAssertNil(service.orgSessions[key]?.sync)
        failingStates.give(20)
        failingMe.clear()
        try await waitUntil { service.orgSessions[self.key]?.sync != nil }
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        try await waitUntil { outbox.isSending }
        try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("Anna")]))
        try await waitUntil { self.commandRequests == 1 }
        XCTAssertEqual(transports.count, 1, "no reconnect")
    }

    /// C17-1: the late synchronizer's snapshot works, but beginning the
    /// generation cannot be written to the journal for a while: readying is
    /// tried again on its own, and once the journal works the queue sends —
    /// without a reconnect.
    func testLateSynchronizerRetriesWhenTheGenerationCannotBegin() async throws {
        let service = try await connectedWithoutMe()
        hello()
        try await waitUntil { service.socket?.state == .connected }
        let journal = try XCTUnwrap(service.journal)
        try await journal.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_insert BEFORE INSERT ON org_generations BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
            try db.execute(sql: "CREATE TRIGGER deny_update BEFORE UPDATE ON org_generations BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
        failingMe.clear()
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
        try await Task.sleep(for: .milliseconds(300))
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        XCTAssertFalse(outbox.isSending, "not before the generation is written")
        try await journal.queue.write { db in
            try db.execute(sql: "DROP TRIGGER deny_insert")
            try db.execute(sql: "DROP TRIGGER deny_update")
        }
        try await waitUntil { outbox.isSending }
        try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("Anna")]))
        try await waitUntil { self.commandRequests == 1 }
        XCTAssertEqual(transports.count, 1, "no reconnect")
    }

    /// C17-1: a new generation begins (pending is written) and the snapshot
    /// works, but finishing the generation fails for a while: readying is
    /// tried again on its own and the connection is allowed once it can be
    /// written; after the user's Try Again a new command goes — no reconnect.
    func testLateSynchronizerRetriesWhenTheGenerationCannotFinish() async throws {
        let service = try await connectedWithoutMe()
        let journal = try XCTUnwrap(service.journal)
        try journal.finish(key, "g0")
        hello()
        try await waitUntil { service.socket?.state == .connected }
        try await journal.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_finish BEFORE UPDATE OF generation ON org_generations BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
        failingMe.clear()
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
        try await waitUntil { (try? journal.generation(self.key).pending) == "g1" }
        try await Task.sleep(for: .milliseconds(300))
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        XCTAssertNil(outbox.allowedConnection, "not before the generation is finished")
        // The snapshot is in, but actions wait for the generation too (review D8h-p2-1).
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync), socket = try XCTUnwrap(service.socket)
        XCTAssertFalse(sync.isSettled(on: socket))
        try await journal.queue.write { db in try db.execute(sql: "DROP TRIGGER deny_finish") }
        try await waitUntil { outbox.allowedConnection != nil }
        XCTAssertTrue(sync.isSettled(on: socket))
        XCTAssertEqual(try journal.generation(key).generation, "g1")
        service.retryStopped()
        try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("Anna")]))
        try await waitUntil { self.commandRequests == 1 }
        XCTAssertEqual(transports.count, 1, "no reconnect")
    }

    /// C18-1: a run recovered after a crash waits for its fact while the new
    /// generation cannot be finished; the subscriptions are done meanwhile,
    /// so nothing else will look again. Once the journal works, the late
    /// readying allows the connection and that one event looks at the
    /// recovered runs: exactly one fact, without a reconnect.
    func testRecoveredRunGetsItsFactOnceTheLateConnectionIsReady() async throws {
        let service = try await connectedWithoutMe()
        let journal = try XCTUnwrap(service.journal)
        try journal.finish(key, "g0")
        let f = try ExecutorFixture(root: root.appendingPathComponent("executor"), runner: RecordingRunner(), key: key, journal: journal)
        let approval = try f.approve()
        let params = try TeamLaunchParams.decode(approval.params)
        let row = ChatRunRecord(runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: params.conversationId, pid: nil, pgid: nil, processStartedAt: nil, startedAt: f.now)
        XCTAssertTrue(try journal.consume(approval, run: row))
        try journal.markProcessesGone(row.runId)
        service.requestState = { _, _ in "running" }
        let recovery = try XCTUnwrap(service.recovery)
        hello()
        try await waitUntil { service.socket?.state == .connected }
        try await journal.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_finish BEFORE UPDATE OF generation ON org_generations BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
        failingMe.clear()
        try await waitUntil { (try? journal.generation(self.key).pending) == "g1" }
        // The server says each followed stream is at its head: the subscriptions are done.
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
        try await waitUntil {
            self.subscribedAll()
            return service.socket?.syncing.isEmpty == true
        }
        await recovery.check()
        XCTAssertEqual(recovery.awaitingFact.map(\.runId), [row.runId], "the generation is not settled: the fact waits")
        try await journal.queue.write { db in try db.execute(sql: "DROP TRIGGER deny_finish") }
        try await waitUntil { (try? journal.run(row.runId)?.outcome) != nil }
        let facts = try journal.runCommands(key).commands().filter { $0.orderKey == "exec:run:\(row.runId)" }
        XCTAssertEqual(facts.count, 1, "exactly one fact")
        XCTAssertTrue(recovery.awaitingFact.isEmpty)
        XCTAssertEqual(transports.count, 1, "no reconnect")
    }

    /// C15-2, C16: a connection whose hello found no synchronizer (its
    /// /v1/me failed) does not let a kept queue send: its generation was not
    /// agreed.
    func testConnectionWithoutASynchronizerDoesNotLetTheQueueSend() async throws {
        let service = try await connectedWithoutMe()
        let session = service.session(for: key)
        session.startSending(api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]), token: "aps_t", sessionId: "s-me",
                             journal: service.journal, onUnauthorized: {})
        let outbox = try XCTUnwrap(session.outbox)
        try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("Anna")]))
        hello()
        try await waitUntil { service.socket?.state == .connected }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(session.sync)
        XCTAssertFalse(outbox.isSending)
        XCTAssertEqual(commandRequests, 0)
    }

    func testStartTakesTheSnapshotAndSubscribesItsStreams() async throws {
        let service = try await connected()
        XCTAssertEqual(stateRequests, 1)
        XCTAssertEqual(transport.subscribes.first, [orgStream: 1, "team:\(general)": 1, memberStream: 1, "account:\(me)": 3])
        XCTAssertEqual(try names(try store(service)), ["me"])
        XCTAssertEqual(try store(service).orgName, "Rabbitshat")
    }

    // (1)
    func testSnapshotPlusEventsEqualsAllEventsFromScratch() throws {
        let events: [ChatEvent] = [
            event(orgStream, 1, "member.joined", ["account_id": me, "handle": "me", "name": "me", "role": "owner"]),
            event(orgStream, 2, "member.joined", ["account_id": boris, "handle": "boris", "name": "boris", "role": "member"]),
            event("team:\(general)", 1, "team.add_member", ["team_id": general, "account_id": me]),
            event(orgStream, 3, "member.set_name", ["account_id": me, "name": "Me"]),
            event("team:\(general)", 2, "team.add_member", ["team_id": general, "account_id": boris]),
            event(orgStream, 4, "member.set_name", ["account_id": boris, "name": "Boris"]),
            event(orgStream, 5, "something.later", [:]),
        ]
        func dump(_ store: ChatStore) throws -> [String] {
            try store.queue.read { db in
                try Row.fetchAll(db, sql: "SELECT account_id, handle, name, role FROM members ORDER BY account_id").map(\.description)
                    + Row.fetchAll(db, sql: "SELECT team_id, account_id FROM team_members ORDER BY 1, 2").map(\.description)
                    + Row.fetchAll(db, sql: "SELECT stream, seq FROM cursors ORDER BY 1").map(\.description)
            }
        }
        let scratch = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("a")), key: key).store
        // A type this build does not know takes its number, not its effect (review D8g-p3-3).
        for e in events { XCTAssertEqual(try scratch.apply(e), e.type == "something.later" ? .passedOver : .applied) }
        for cut in 0...events.count {
            // The state after the first `cut` events, as the server's snapshot would carry it.
            let partial = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("p\(cut)")), key: key).store
            for e in events.prefix(cut) { try partial.apply(e) }
            let snapshot = try partial.queue.read { db in
                ChatSnapshot(
                    cursors: Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT stream, seq FROM cursors").map { ($0["stream"], $0["seq"]) }),
                    members: try Row.fetchAll(db, sql: "SELECT * FROM members").map { .init(accountId: $0["account_id"], handle: $0["handle"], name: $0["name"], role: $0["role"]) },
                    teamMembers: try Row.fetchAll(db, sql: "SELECT * FROM team_members").map { .init(teamId: $0["team_id"], accountId: $0["account_id"]) }
                )
            }
            let fresh = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("s\(cut)")), key: key).store
            try fresh.apply(snapshot)
            for e in events { try fresh.apply(e) }
            XCTAssertEqual(try dump(fresh), try dump(scratch), "snapshot after \(cut) events")
        }
    }

    private func event(_ stream: String, _ seq: Int, _ type: String, _ body: [String: String]) -> ChatEvent {
        ChatEvent(stream: stream, seq: seq, id: UUID().uuidString, type: type, actor: nil,
                  body: .object(body.mapValues { .string($0) }), commandId: nil, at: "2026-10-03T18:20:00Z")
    }

    // (2)
    func testNewMemberAppearsWithoutRestart() async throws {
        let service = try await connected()
        transport.frame(frame(orgStream, 2, "member.joined", ["account_id": boris, "handle": "boris", "name": "boris", "role": "member"]))
        try await waitUntil { try self.names(try self.store(service)) == ["me", "boris"] }
        XCTAssertEqual(try store(service).cursor(orgStream), 2)
    }

    // (3)
    func testMembershipChangedButStillAMemberTakesOneSnapshot() async throws {
        let service = try await connected()
        XCTAssertEqual(stateRequests, 1)
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        try await waitUntil { self.stateRequests == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stateRequests, 2)
        XCTAssertEqual(service.state, .signedIn)
    }

    func testMembershipLostDropsTheCacheAndKeepsTheConnection() async throws {
        let service = try await connected()
        let cache = files.cacheURL(key)
        serve(orgsInMe: false)
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        try await waitUntil { if case .notMember = service.state { true } else { false } }
        XCTAssertEqual(service.state, .notMember(key, "You are no longer a member of Rabbitshat."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertNotNil(service.connection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.serversURL.path))
    }

    // (4)
    /// A type this build does not know is not lost in silence: it is kept,
    /// and a snapshot brings its effect (review D8f-p3-1; was: skipped).
    func testUnknownTypeIsKeptAndASnapshotBringsItsEffect() async throws {
        let service = try await connected()
        let before = stateRequests
        transport.frame(frame(orgStream, 2, "org.something_new", ["x": "y"]))
        try await waitUntil { self.stateRequests > before }
        XCTAssertEqual(try skipped(store(service)), ["org.something_new"])
    }

    private func skipped(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT type FROM skipped_events") }
    }

    // (5)
    func testOnlyAnotherDevicesNewSessionNotifiesOnce() async throws {
        let service = try await connected()
        var notices: [String] = []
        service.onNotice = { notices.append($0) }
        let account = "account:\(me)"
        // History up to the head (3) comes again after a reconnect: skipped.
        transport.frame(frame(account, 2, "account.session_opened", ["session_id": "s-old", "device_name": "Old"]))
        transport.frame(frame(account, 3, "account.session_opened", ["session_id": "s-old2", "device_name": "Old2"]))
        transport.frame(frame(account, 4, "account.session_opened", ["session_id": "s-me", "device_name": "This Mac"]))
        transport.frame(frame(account, 5, "account.session_opened", ["session_id": "s-other", "device_name": "Boris's iMac"]))
        transport.frame(frame(account, 5, "account.session_opened", ["session_id": "s-other", "device_name": "Boris's iMac"]))
        try await waitUntil { !notices.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(notices, ["A new device signed in to your account: Boris's iMac"])
    }

    // (6)
    func testUnsubscribedTeamStreamDropsItsDataWithoutASnapshot() async throws {
        let service = try await connected()
        let store = try store(service)
        XCTAssertEqual(try count(store, "team_members"), 1)
        transport.frame(#"{"frame":"unsubscribed","stream":"team:\#(general)"}"#)
        try await waitUntil { try self.count(store, "teams") == 0 }
        XCTAssertEqual(try count(store, "team_members"), 0)
        XCTAssertEqual(try store.cursors()["team:\(general)"], nil)
        XCTAssertEqual(stateRequests, 1)
        XCTAssertEqual(service.socket?.state, .connected)
    }

    func testAddedToATeamFollowsItsStreamWithoutReconnecting() async throws {
        let service = try await connected()
        myTeams = [general, ops]
        heads["team:\(ops)"] = 4
        heads[memberStream] = 2
        serve()
        transport.frame(frame(memberStream, 2, "team.add_member", ["team_id": ops, "account_id": me]))
        try await waitUntil { self.transport.subscribes.contains { $0["team:\(self.ops)"] != nil } }
        XCTAssertTrue(transport.subscribes.contains { $0["team:\(self.ops)"] == 4 })
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(stateRequests, 1, "one snapshot since serve() reset the log")
        _ = service
    }

    /// C6: the user's own new role brings the admin stream (and takes it
    /// away) through a new snapshot, without reconnecting — and the cache
    /// ends as that snapshot has it: promoted, every team; demoted, none of
    /// others, already when the role's event is applied (review C6 p2-7).
    /// Another member's role asks for nothing; a team joined takes a snapshot.
    func testOwnRoleOrJoinedTeamTakesASnapshot() async throws {
        let service = try await connected()
        let store = try store(service)
        let other = "00000000-0000-4000-8000-0000000000c9"
        func teams() throws -> [String: Bool] {
            try store.queue.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT team_id, mine FROM teams").map { ($0["team_id"], $0["mine"]) })
            }
        }
        func role() throws -> String? {
            try store.queue.read { db in try String.fetchOne(db, sql: "SELECT role FROM members WHERE account_id = ?", arguments: [self.me]) }
        }
        heads["org-admin:\(org)"] = 5
        heads[orgStream] = 3
        myRole = "admin"
        otherTeams = [other]
        serve()
        transport.frame(frame(orgStream, 2, "member.set_role", ["account_id": boris, "role": "admin"]))
        try await waitUntil { try store.cursor(self.orgStream) == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stateRequests, 0, "another member's role changes nothing of the streams")
        transport.frame(frame(orgStream, 3, "member.set_role", ["account_id": me, "role": "admin"]))
        try await waitUntil { self.transport.subscribes.contains { $0["org-admin:\(self.org)"] == 5 } }
        try await waitUntil { try teams() == [self.general: true, other: false] }
        XCTAssertEqual(try role(), "admin")
        XCTAssertEqual(stateRequests, 1)

        // Demoted: the snapshot is late; the role's event alone leaves
        // nothing of other teams in the cache.
        heads[orgStream] = 4
        heads["org-admin:\(org)"] = nil
        myRole = "member"
        otherTeams = []
        stateGate.close()
        serve()
        transport.frame(frame(orgStream, 4, "member.set_role", ["account_id": me, "role": "member"]))
        try await waitUntil { try store.cursor(self.orgStream) == 4 }
        XCTAssertEqual(try teams(), [general: true], "gone with the role's event, before any snapshot")
        XCTAssertNil(try store.cursors()["org-admin:\(org)"])
        stateGate.open()
        try await waitUntil { self.stateRequests == 1 && service.orgSessions[self.key]?.sync?.needsSnapshot == false }
        XCTAssertEqual(try teams(), [general: true])

        heads[memberStream] = 2
        heads["team:\(ops)"] = 1
        myTeams = [general, ops]
        serve()
        transport.frame(frame(memberStream, 2, "team.join", ["team_id": ops, "account_id": me]))
        try await waitUntil { self.transport.subscribes.contains { $0["team:\(self.ops)"] != nil } }
        XCTAssertEqual(stateRequests, 1)
        XCTAssertEqual(transports.count, 1)
    }

    /// C6b p1-2: a snapshot read while the user was an admin, answered
    /// after its demotion was applied, gives nothing back — not the role,
    /// not other teams; another one is read and applied.
    func testASnapshotReadBeforeARevocationIsNotApplied() async throws {
        let other = "00000000-0000-4000-8000-0000000000c9"
        myRole = "admin"
        otherTeams = [other]
        heads["org-admin:\(org)"] = 5
        serve()
        let service = try await connected()
        let store = try store(service)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        func teams() throws -> Set<String> {
            Set(try store.queue.read { db in try String.fetchAll(db, sql: "SELECT team_id FROM teams") })
        }
        try await waitUntil { try teams() == [self.general, other] }
        // Snapshots applied from now on, as they were written.
        var seen: [Set<String>] = []
        sync.afterSnapshotApplied = { seen.append(try teams()) }

        // A snapshot is read as an admin's, and held on the way.
        serve()
        stateGate.close()
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/state") == true } }
        // Meanwhile: demoted. The server's state is a member's from now.
        myRole = "member"
        otherTeams = []
        heads["org-admin:\(org)"] = nil
        heads[orgStream] = 2
        serve()
        transport.frame(frame(orgStream, 2, "member.set_role", ["account_id": me, "role": "member"]))
        try await waitUntil { try store.cursor(self.orgStream) == 2 }
        XCTAssertEqual(try teams(), [general])
        stateGate.open()
        try await waitUntil { !sync.needsSnapshot && !seen.isEmpty }
        XCTAssertTrue(seen.allSatisfy { $0 == [general] }, "only snapshots read after the demotion were applied: \(seen)")
        XCTAssertEqual(try teams(), [general])
        XCTAssertNil(try store.cursors()["org-admin:\(org)"])
    }

    /// C6c p1-2: out of a team, its stream stops at once — what it still
    /// sends is not applied, its cursor is gone, nothing of it comes back.
    func testALeftTeamsStreamIsNoLongerApplied() async throws {
        myTeams = [general, ops]
        heads["team:\(ops)"] = 1
        serve()
        let service = try await connected()
        let store = try store(service)
        try await waitUntil { try store.cursors()["team:\(self.ops)"] == 1 }
        transport.frame(frame(memberStream, 2, "team.leave", ["team_id": ops, "account_id": me]))
        try await waitUntil { try store.cursors()["team:\(self.ops)"] == nil }
        // Late frames of the team: an add and an agent of it.
        transport.frame(frame("team:\(ops)", 2, "team.add_member", ["team_id": ops, "account_id": boris]))
        transport.frame(frame("team:\(ops)", 3, "team.rename", ["team_id": ops, "name": "Back"]))
        transport.frame(frame(orgStream, 2, "member.set_name", ["account_id": me, "name": "Later"]))
        try await waitUntil { try store.cursor(self.orgStream) == 2 }
        let team = ops
        let left = try await store.queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM teams WHERE team_id = ?", arguments: [team]) ?? 0)
                + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM team_members WHERE team_id = ?", arguments: [team]) ?? 0)
        }
        XCTAssertEqual(left, 0)
        XCTAssertNil(try store.cursors()["team:\(ops)"])
        XCTAssertTrue(transport.sent.contains { $0.contains("unsubscribe") && $0.contains("team:\(self.ops)") })
    }

    /// C6d p2-3: the user leaves the one team whose stream was still
    /// catching up: the organization is ready at once, as when the server
    /// stops a stream — no other frame needed.
    func testLeavingTheLastCatchingUpTeamMakesReady() async throws {
        myTeams = [general, ops]
        heads["team:\(ops)"] = 1
        serve()
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { self.transport.subscribes.contains { $0["team:\(self.ops)"] != nil } }
        subscribedAll()
        try await waitUntil { sync.state == .ready }
        // Ops misses an event: caught up again, not ready meanwhile.
        transport.frame(frame("team:\(ops)", 5, "team.rename", ["team_id": ops, "name": "X"]))
        try await waitUntil { sync.state != .ready }
        transport.frame(frame(memberStream, 2, "team.leave", ["team_id": ops, "account_id": me]))
        try await waitUntil { sync.state == .ready }
    }

    /// C6e p2-1: the user's own removal is a sign: `/v1/me` decides. Still
    /// a member there (invited back meanwhile): the organization stays.
    func testOwnRemovalAsksMeAndMeDecides() async throws {
        let service = try await connected()
        let session = try XCTUnwrap(service.orgSessions[key])
        heads[orgStream] = 2
        serve()
        let reads = 0
        transport.frame(frame(orgStream, 2, "member.remove", ["account_id": me]))
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/me" }.count > reads }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.state, .signedIn)
        XCTAssertTrue(service.orgSessions[key] === session)
        // Gone in /v1/me: the core's way out.
        try await waitUntil { try self.store(service).cursor(self.orgStream) == 2 && !(session.sync?.needsSnapshot ?? true) }
        heads[orgStream] = 3
        serve(orgsInMe: false)
        transport.frame(frame(orgStream, 3, "member.remove", ["account_id": me]))
        try await waitUntil { if case .notMember = service.state { true } else { false } }
        XCTAssertNil(service.orgSessions[key])
    }

    /// C6f p1-4: the organization's own stream refused is a sign: rights in
    /// doubt and `/v1/me` read — the core leaves the organization only if
    /// `/v1/me` says so.
    func testTheOrganizationsStreamRefusedAsksMe() async throws {
        let service = try await connected()
        serve(orgsInMe: false)
        transport.frame(#"{"frame":"unsubscribed","stream":"\#(orgStream)"}"#)
        try await waitUntil { if case .notMember = service.state { true } else { false } }
        XCTAssertNil(service.orgSessions[key])
    }

    /// C6f p1-3: `account.membership_changed` of the organization puts its
    /// rights in doubt until a snapshot.
    func testMembershipChangedPutsRightsInDoubt() async throws {
        let service = try await connected()
        let store = try store(service)
        stateGate.close()
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        try await waitUntil { try self.doubt(store) }
        stateGate.open()
        try await waitUntil { try !self.doubt(store) }
    }

    /// C6f p1-2: the user out of a team, but the cache could not write it:
    /// rights in doubt all the same.
    func testALeaveNotWrittenPutsRightsInDoubt() async throws {
        myTeams = [general, ops]
        heads["team:\(ops)"] = 1
        serve()
        let service = try await connected()
        let store = try store(service)
        stateGate.close()
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE team_members RENAME TO team_members_away") }
        transport.frame(frame(memberStream, 2, "team.leave", ["team_id": ops, "account_id": me]))
        try await waitUntil { try self.doubt(store) }
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE team_members_away RENAME TO team_members") }
        stateGate.open()
    }

    /// C6g p2-4: a command of the window refused as forbidden is a sign
    /// when the queue learns it — before any window shows it, so a Dismiss
    /// cannot lose it.
    func testARefusedCommandIsASignWhenTheQueueLearnsIt() async throws {
        let service = try await connected()
        let store = try store(service)
        subscribedAll()
        try await waitUntil { service.isServerKnown(service, self.key) }
        stateGate.close()
        forbiddenCommands.give(1)
        try service.enqueue(key, type: "team.create", args: .object(["team_id": .string("t9"), "name": .string("N")]))
        try await waitUntil { try self.doubt(store) }
        service.dismissRefused()
        XCTAssertTrue(try doubt(store), "dismissed or not, the sign was taken")
        stateGate.open()
    }

    /// C6h p1-3: the refusal is a sign even when its record cannot be saved.
    func testARefusalNotSavedIsASignAllTheSame() async throws {
        let service = try await connected()
        let store = try store(service)
        subscribedAll()
        try await waitUntil { service.isServerKnown(service, self.key) }
        try await waitUntil { try !self.doubt(store) }
        stateGate.close()
        slowCommands.give(1)
        forbiddenCommands.give(1)
        try service.enqueue(key, type: "team.create", args: .object(["team_id": .string("t9"), "name": .string("N")]))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE outbox RENAME TO outbox_away") }
        try await waitUntil { try self.doubt(store) }
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE outbox_away RENAME TO outbox") }
        stateGate.open()
    }

    /// C6j: the doubt's write fails, the model reads the cache again (old
    /// rights), then the write works: until a view read after that write is
    /// delivered, nothing of the old rights shows.
    func testAfterAFailedDoubtWriteOnlyAViewReadAfterTheWriteShows() async throws {
        myRole = "admin"
        heads["org-admin:\(org)"] = 5
        serve()
        let service = try await connected()
        let store = try store(service)
        let session = try XCTUnwrap(service.orgSessions[key])
        let sync = try XCTUnwrap(session.sync)
        sync.retryDelay = { _ in 3600 }
        let model = try XCTUnwrap(ChatOrgModel.current(service))
        try await waitUntil { model.manages }
        stateGate.close()
        // Reads work, the doubt's write does not.
        try await store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER no_doubt BEFORE UPDATE OF rights_in_doubt ON meta BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        sync.rightsInDoubt()
        XCTAssertTrue(session.doubtNotWritten)
        try await Task.sleep(for: .milliseconds(100))   // the model followed the cache again: the old rights
        XCTAssertFalse(model.manages)
        try await store.queue.write { db in try db.execute(sql: "DROP TRIGGER no_doubt") }
        sync.rightsInDoubt()   // written now
        XCTAssertFalse(session.doubtNotWritten)
        XCTAssertFalse(model.manages, "the view read before the write is not shown")
        try await waitUntil { model.visible }
        XCTAssertTrue(model.inDoubt)
        XCTAssertFalse(model.manages)
        stateGate.open()
    }

    /// C6g p1-2: the doubt's write fails: nothing is shown, and the write is
    /// tried again until it works.
    func testADoubtNotWrittenIsTriedAgain() async throws {
        let service = try await connected()
        let store = try store(service)
        let session = try XCTUnwrap(service.orgSessions[key])
        let sync = try XCTUnwrap(session.sync)
        sync.retryDelay = { _ in 0.05 }
        stateGate.close()
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE meta RENAME TO meta_away") }
        sync.rightsInDoubt()
        XCTAssertTrue(session.doubtNotWritten)
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE meta_away RENAME TO meta") }
        try await waitUntil { !session.doubtNotWritten }
        XCTAssertTrue(try doubt(store))
        stateGate.open()
    }

    private func doubt(_ store: ChatStore) throws -> Bool {
        try store.queue.read { db in try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") ?? false }
    }

    /// C6e: a sign puts rights in doubt — a manager's view is hidden — until
    /// a snapshot read after it; one read before it is not applied.
    func testRightsInDoubtUntilASnapshotReadAfterTheSign() async throws {
        let other = "00000000-0000-4000-8000-0000000000c9"
        myRole = "admin"
        otherTeams = [other]
        heads["org-admin:\(org)"] = 5
        serve()
        let service = try await connected()
        let store = try store(service)
        let session = try XCTUnwrap(service.orgSessions[key])
        let sync = try XCTUnwrap(session.sync)
        func teams() throws -> Set<String> {
            Set(try store.queue.read { db in try String.fetchAll(db, sql: "SELECT team_id FROM teams") })
        }
        try await waitUntil { try teams() == [self.general, other] }
        var seen: [Set<String>] = []
        sync.afterSnapshotApplied = { seen.append(try teams()) }
        serve()
        stateGate.close()
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/state") == true } }
        myRole = "member"
        otherTeams = []
        heads["org-admin:\(org)"] = nil
        serve()
        sync.rightsInDoubt()
        XCTAssertTrue(try doubt(store))
        _ = session
        stateGate.open()
        try await waitUntil { !sync.needsSnapshot && !seen.isEmpty }
        XCTAssertTrue(seen.allSatisfy { $0 == [general] }, "\(seen)")
        XCTAssertFalse(try doubt(store), "a snapshot read after the sign ends the doubt")
    }

    // (7)
    func testTwoOrganizationsOnOneSocketDoNotShareTheCache() async throws {
        let otherOrg = "00000000-0000-4000-8000-0000000000a2"
        let socket = ChatSocket(server: server, token: "aps_t") { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            return t
        }
        let api = ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self])
        let keyA = key, keyB = ChatOrgKey(server: server, accountId: me, orgId: otherOrg)
        let storeA = try ChatStore.open(files: files, key: keyA).store, storeB = try ChatStore.open(files: files, key: keyB).store
        let a = ChatSync(key: keyA, store: storeA, api: api, socket: socket, outbox: nil, token: "aps_t")
        let b = ChatSync(key: keyB, store: storeB, api: api, socket: socket, outbox: nil, token: "aps_t")
        await a.start()
        await b.start()
        socket.start()
        try await waitUntil { !self.transports.isEmpty }
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { socket.state == .connected }
        // Each took its own snapshot at hello (org head 1).
        transport.frame(frame("org:\(org)", 2, "member.set_name", ["account_id": me, "name": "A-side"]))
        transport.frame(frame("org:\(otherOrg)", 2, "member.set_name", ["account_id": me, "name": "B-side"]))
        try await waitUntil { try storeB.cursor("org:\(otherOrg)") == 2 && storeA.cursor("org:\(self.org)") == 2 }
        XCTAssertEqual(try names(storeA), ["A-side"])
        XCTAssertEqual(try names(storeB), ["B-side"])
        XCTAssertNil(try storeA.cursors()["org:\(otherOrg)"])
        XCTAssertNil(try storeB.cursors()["org:\(org)"])
        socket.stop()
    }

    /// C3: a new server generation pauses the queue and takes the snapshot again.
    func testNewGenerationPausesTheQueueAndTakesASnapshot() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        XCTAssertNil(outbox.paused)
        let before = stateRequests
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        transport.frame(#"{"frame":"hello","generation":"g2","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { service.socket?.state == .connected }
        XCTAssertEqual(outbox.paused, .generationChanged)
        try await waitUntil { self.stateRequests > before }
        XCTAssertEqual(try store(service).generation, "g2")
    }

    // MARK: Review fixes (review-client-c.md 1, 4, 9–12, 14–16)

    /// 1: another server after a sign-in gets a new socket with its own token;
    /// the old one is stopped and the old organization's state goes.
    func testSigningInToAnotherServerMakesANewConnection() async throws {
        let service = try await connected()
        let other = try ChatServerAddress(parsing: "https://other.example.com")
        let tokens = FakeTokenStore()
        _ = tokens
        try service.saveSignIn(ChatConnection(server: other, accountId: me, sessionId: "s-b", deviceName: "Mac", orgId: org), token: "aps_b")
        try await service.start(mode: .server)
        try await waitUntil { self.transports.count == 2 }
        XCTAssertEqual(transports[0].closedWith, 1000)
        XCTAssertEqual(transports[1].request?.url?.host, "other.example.com")
        XCTAssertEqual(transports[1].request?.value(forHTTPHeaderField: "Authorization"), "Bearer aps_b")
        XCTAssertNil(service.orgSessions[key], "the first server's organization stopped")
        // Nothing the old connection does reaches the service: a 4401 on it changes nothing.
        transports[0].push(.closed(code: 4401))
        XCTAssertEqual(service.state, .signedIn)
    }

    /// 4: queued commands wait for hello; a new generation keeps them back.
    func testQueueWaitsForHelloAndItsGeneration() async throws {
        let service = try await connected(hello: false)
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(commandRequests, 0, "nothing before hello")
        hello()
        try await waitUntil { self.commandRequests == 1 }

        // The connection drops; the next hello names another generation.
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("B")]))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(commandRequests, 1, "nothing while disconnected")
        hello("g2")
        try await waitUntil { outbox.paused == .generationChanged }
        XCTAssertEqual(commandRequests, 1)
        XCTAssertEqual(try store(service).commands().last?.state, .unconfirmed)
    }

    /// 9: an event applied while a snapshot is on its way is followed again
    /// from the snapshot's cursor.
    func testLateSnapshotIsFollowedByACatchUp() async throws {
        let service = try await connected()
        slowState.give(1)
        service.orgSessions[key]?.sync?.requestSnapshot()
        try await Task.sleep(for: .milliseconds(50))
        transport.frame(frame(orgStream, 2, "member.joined", ["account_id": boris, "handle": "boris", "name": "boris", "role": "member"]))
        try await waitUntil { try self.names(try self.store(service)) == ["me", "boris"] }
        // The snapshot (head 1) lands: the stream is followed again from 1.
        try await waitUntil { service.orgSessions[self.key]?.sync?.snapshots == 2 }
        XCTAssertEqual(self.transport.subscribes.last?[self.orgStream], 1, "followed again from the snapshot's cursor")
        XCTAssertEqual(try store(service).cursor(orgStream), 1)
        transport.frame(frame(orgStream, 2, "member.joined", ["account_id": boris, "handle": "boris", "name": "boris", "role": "member"]))
        try await waitUntil { try self.names(try self.store(service)) == ["me", "boris"] }
    }

    /// 10: a first snapshot that failed is taken again.
    func testFailedFirstSnapshotIsRetried() async throws {
        failingStates.give(1)
        let service = try await connected()
        try await waitUntil { self.stateRequests >= 2 }
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
        XCTAssertTrue(transport.subscribes.contains { $0[self.orgStream] != nil })
    }

    /// 11: after 4401, signing in again brings the feed back.
    func testSigningInAgainAfterAClosedSessionRestartsTheFeed() async throws {
        let service = try await connected()
        transport.push(.closed(code: 4401))
        try await waitUntil { if case .needsSignIn = service.state { true } else { false } }
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-2", deviceName: "Mac", orgId: org), token: "aps_2")
        try await service.start(mode: .server)
        try await waitUntil { self.transports.count == 2 }
        hello()
        try await waitUntil { service.socket?.state == .connected }
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer aps_2")
    }

    /// C6d: a 401 seen by the send queue ends the connection's work as one
    /// seen by the socket does — no reconnect, no snapshot retries — and
    /// the queue keeps its command.
    func testA401OfTheQueueStopsTheConnectionToo() async throws {
        let service = try await connected()
        service.socket?.retryDelay = { _ in 0.05 }
        closedSession.give(1)
        let record = try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("A")]))
        try await waitUntil { if case .needsSignIn = service.state { true } else { false } }
        XCTAssertNil(service.socket, "the feed is stopped")
        let requests = ChatStubProtocol.seen.count
        transport.push(.closed(code: 1006))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transports.count, 1, "no reconnect with the closed session's token")
        XCTAssertEqual(ChatStubProtocol.seen.count, requests, "nothing more is asked of the server")
        XCTAssertTrue(try store(service).outbox.commands().contains { $0.commandId == record.commandId })
        closedSession.clear()
    }

    /// 12: resync of the account stream takes the head from /v1/me, even behind the cursor.
    func testAccountResyncTakesTheHead() async throws {
        let service = try await connected()
        XCTAssertEqual(service.accountFeed?.cursor, 3)
        accountHead = 1
        serve()
        transport.frame(#"{"frame":"resync_required","stream":"account:\#(me)"}"#)
        try await waitUntil { service.accountFeed?.cursor == 1 }
        try await waitUntil { self.transport.subscribes.contains { $0["account:\(self.me)"] == 1 } }
    }

    /// 14: a membership change whose /v1/me failed is read again later.
    func testMembershipChangeSurvivesAFailedRead() async throws {
        let service = try await connected()
        failingMe.give(1)
        let before = stateRequests
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        try await waitUntil { self.stateRequests > before }
        _ = service
    }

    /// 15: not a member at start — the account stream is still followed, and
    /// an invitation later brings the organization back.
    func testMembershipComesBackWithoutRestart() async throws {
        serve(orgsInMe: false)
        let service = try await connected()
        guard case .notMember = service.state else { return XCTFail("\(service.state)") }
        XCTAssertNil(service.orgSessions[key])
        try await waitUntil { self.transport.subscribes.contains { $0["account:\(self.me)"] != nil } }
        serve()
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        try await waitUntil { service.orgSessions[self.key]?.sync != nil }
        XCTAssertEqual(service.state, .signedIn)
        try await waitUntil { (try? self.store(service).orgName) == "Rabbitshat" }
    }

    /// 16: Disconnect while the feed still waits for /v1/me: nothing starts after.
    func testDisconnectDuringStartLeavesNothingRunning() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.makeSocketTransport = { [unowned self] in
            let t = FakeSocketTransport()
            self.transports.append(t)
            return t
        }
        service.followsFeed = true
        service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-me", deviceName: "Mac", orgId: org), token: "aps_t")
        ChatStubProtocol.delay = 0.3
        let starting = Task { try await service.start(mode: .server) }
        try await Task.sleep(for: .milliseconds(50))
        await service.disconnect()
        try await starting.value
        try await Task.sleep(for: .milliseconds(400))
        // Disconnect waited for the start (one operation at a time) and then
        // undid it: nothing of it is left running or kept.
        XCTAssertNil(service.socket)
        XCTAssertTrue(transports.allSatisfy { $0.closedWith != nil }, "no socket left open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.cacheURL(key).path), "no cache after Disconnect")
        XCTAssertNil(service.connection)
    }

    // MARK: Second review (review-client-c2.md 5, 7, 8, 10)

    /// C2-5: a hello whose connection was replaced while its snapshot was out
    /// changes nothing: the generation stays pending, the queue held.
    func testSupersededHelloChangesNothing() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        XCTAssertNotNil(outbox.allowedConnection)
        slowState.give(1)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g2")
        try await Task.sleep(for: .milliseconds(80))
        // While the snapshot of g2 is out, this connection goes too.
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 3 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try store(service).generation, "g1", "the old hello did not finish the generation")
        XCTAssertNil(outbox.allowedConnection, "and allowed nothing")
    }

    /// C2-7: an organization brought by the account during a hello is
    /// readied for that same connection.
    func testOrganizationMadeDuringHelloMayStillSend() async throws {
        failingMe.give(1)
        let service = try await connected(hello: false)
        XCTAssertNil(service.orgSessions[key]?.sync, "the first /v1/me failed: no organization yet")
        hello()
        try await waitUntil { service.orgSessions[self.key]?.outbox?.allowedConnection != nil }
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        try await waitUntil { self.commandRequests == 1 }
    }

    /// C2-8: a generation whose queues could not be marked stays pending and
    /// is done again by the next hello; meanwhile nothing is sent.
    func testGenerationChangeIsDurable() async throws {
        let service = try await connected()
        let store = try store(service)
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        outbox.hold()
        try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        try denyOutboxUpdates(store, true)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g2")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try store.generation, "g1")
        XCTAssertEqual(try store.pendingGeneration, "g2")
        XCTAssertEqual(commandRequests, 0)
        try denyOutboxUpdates(store, false)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 3 }
        hello("g2")
        try await waitUntil { (try? store.generation) == "g2" }
        XCTAssertNil(try store.pendingGeneration)
        XCTAssertEqual(try store.commands().last?.state, .unconfirmed)
        XCTAssertEqual(commandRequests, 0, "nothing of the old generation went")
    }

    nonisolated private func denyOutboxUpdates(_ store: ChatStore, _ deny: Bool) throws {
        try store.queue.write { db in
            if deny {
                try db.execute(sql: "CREATE TRIGGER deny BEFORE UPDATE ON outbox BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
            } else {
                try db.execute(sql: "DROP TRIGGER deny")
            }
        }
    }

    /// C2-10: a Disconnect waiting for the server does not undo a sign-in made meanwhile.
    func testSignInDuringDisconnectIsKept() async throws {
        let service = try await connected()
        let tokens = FakeTokenStore()
        _ = tokens
        service.closeRemoteSession = { _, _ in try await Task.sleep(for: .milliseconds(300)) }
        let leaving = Task { await service.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        let answer = ChatSignIn(token: "aps_b", sessionId: "s-b", accountId: me, orgs: [])
        let kept = try await service.completeSignIn(answer, server: server, deviceName: "Mac", orgId: org)
        try await service.keepSignIn()
        await leaving.value
        XCTAssertEqual(service.connection, kept, "the later sign-in stands")
        XCTAssertEqual(try files.loadConnections(), [kept])
    }

    // MARK: Third review (review-client-c3.md 2–6, 13, 14)

    /// C3-2: answers read for an earlier connection change nothing.
    func testReadsOfAnEarlierConnectionChangeNothing() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let before = sync.snapshots
        slowState.give(1)
        sync.requestSnapshot()
        try await Task.sleep(for: .milliseconds(50))
        transport.push(.closed(code: 1006))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sync.snapshots, before, "the snapshot read for the old connection was not applied")
        XCTAssertTrue(sync.needsSnapshot, "and is still owed")

        // A /v1/me saying "not a member", read before a drop, does not remove the organization.
        serve(orgsInMe: false)
        slowMe.give(1)
        try await waitUntil { self.transports.count == 2 }
        transport.frame(frame("account:\(me)", 4, "account.membership_changed", ["org_id": org]))
        transport.push(.opened)
        try await Task.sleep(for: .milliseconds(50))
        transport.push(.closed(code: 1006))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(service.orgSessions[key], "the stale answer did not remove the organization")
    }

    /// C3-3: while a generation change waits for its snapshot, approvals of
    /// the old generation are void already and nothing can run.
    func testApprovalsAreVoidBeforeTheSnapshotOfANewGeneration() async throws {
        let service = try await connected()
        let journal = try XCTUnwrap(service.journal)
        try journal.save(ChatAssignment(server: server.description, accountId: me, orgId: org, agentId: "agent", state: .active,
                                        name: "a", description: "d", access: "read", teamIds: "[]", createdAt: Date()))
        let approval = ChatApproval(id: "ap", server: server.description, accountId: me, orgId: org, requestId: "rq", agentId: "agent",
                                    kind: "initial", params: "{}", paramsHash: "h", runId: "run", startCommandId: "c",
                                    generation: "g1", createdAt: Date())
        try journal.insert(approval)
        slowState.give(1)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g2")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try journal.approval("ap")?.voidReason, "server_restored", "void before the snapshot came")
        do {
            _ = try await service.launcher?.launch(approvalId: "ap")
            XCTFail("launched")
        } catch {
            XCTAssertTrue([.generationChanging, .voided("server_restored")].contains(error as? TeamLauncher.Failure))
        }
        try await waitUntil { (try? journal.generation(self.key).generation) == "g2" }
    }

    /// C3-4: the journal remembers the generation: a cache made anew does not
    /// let old executor commands go to a restored server.
    func testJournalKeepsTheGenerationWhenTheCacheIsGone() async throws {
        let files = self.files
        try files.prepareDirectory()
        let journal = try ChatJournal.open(files: files)
        try journal.finish(key, "g1")
        let old = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s-me", type: "run.started",
                                                         bodyBytes: Data("{}".utf8), orderKey: "exec:run:r", dependsOn: nil,
                                                         createdAt: Date(), state: .pending), key: key)
        let service = try await connected(hello: false)
        hello("g2")
        try await waitUntil { service.orgSessions[self.key]?.outbox?.paused == .generationChanged }
        XCTAssertEqual(try service.journal?.commands(for: key).first { $0.commandId == old.commandId }?.state, .unconfirmed)
        XCTAssertEqual(commandRequests, 0)
    }

    /// C3-5: a hello that could not be finished brings a new connection.
    func testUnfinishedHelloReconnects() async throws {
        let service = try await connected()
        let store = try store(service)
        try denyOutboxUpdates(store, true)
        try service.orgSessions[key]?.outbox?.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g2")
        try await waitUntil { self.transports.count == 3 }
        try denyOutboxUpdates(store, false)
    }

    /// C3-6: what stopped is shown, and "Try Again" sends unconfirmed changes
    /// again as new commands — never run.* — and lets the queue go.
    func testStoppedQueueCanBeTriedAgain() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        outbox.hold()
        let name = try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        let run = try outbox.enqueue(org: org, type: "run.start", args: .object([:]), orderKey: "exec:run", journal: true)
        try outbox.generationChanged()
        XCTAssertFalse(service.problems.isEmpty)
        hello()
        service.retryStopped()
        XCTAssertNil(outbox.paused)
        try await waitUntil { self.commandRequests == 1 }
        let sent = try JSONDecoder().decode(ChatCommandEnvelope.self, from: try XCTUnwrap(ChatStubProtocol.seen.last { $0.request.url?.path == "/v1/commands" }?.body))
        XCTAssertEqual(sent.type, "member.set_name")
        XCTAssertNotEqual(sent.commandId, name.commandId)
        XCTAssertEqual(try service.journal?.commands(for: key).first { $0.commandId == run.commandId }?.state, .unconfirmed)
        XCTAssertTrue(service.problems.isEmpty)
    }

    /// C3-13: Disconnect waits for queued run facts to be taken before the
    /// session closes.
    func testDisconnectWaitsForRunFacts() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        slowCommands.give(1)
        var postedBeforeClose = false
        service.closeRemoteSession = { _, _ in
            postedBeforeClose = ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" }
            postedBeforeClose = postedBeforeClose && ((try? service.journal?.commands(for: self.key).first?.state) == .sent)
        }
        try outbox.enqueue(org: org, type: "run.failed", args: .object([:]), orderKey: "exec:run:r", journal: true)
        await service.disconnect()
        XCTAssertTrue(postedBeforeClose)
    }

    /// C3-14: a reset run journal joins the organizations' queues.
    func testResetJournalJoinsTheQueue() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        try service.resetJournal()
        let fresh = try XCTUnwrap(service.journal)
        XCTAssertEqual(outbox.queues.count, 2)
        // A new hello prepares the new journal before anything is sent (review C4-6).
        try await waitUntil { self.transports.count == 2 }
        hello()
        XCTAssertTrue(service.orgSessions[key]?.sync?.generationState === fresh, "the generation is kept in the new journal")
        try await waitUntil { (try? fresh.generation(self.key).generation) == "g1" }
        try outbox.enqueue(org: org, type: "run.failed", args: .object([:]), orderKey: "exec:run:r", journal: true)
        try await waitUntil { try fresh.commands(for: self.key).first?.state == .sent }
    }

    // MARK: Fourth review (review-client-c4.md 5)

    /// C4-5: a journal without the generation the cache knows (made or
    /// migrated after it) learns it at the next hello of that generation.
    func testJournalLearnsTheGenerationTheCacheKnows() async throws {
        let service = try await connected()
        let journal = try XCTUnwrap(service.journal)
        try await waitUntil { (try? journal.generation(self.key).generation) == "g1" }
        try await journal.queue.write { db in try db.execute(sql: "DELETE FROM org_generations") }
        XCTAssertNil(try journal.generation(key).generation)
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g1")
        try await waitUntil { (try? journal.generation(self.key).generation) == "g1" }
        XCTAssertNil(service.orgSessions[key]?.outbox?.paused)
    }

    /// C5-8: after a restart the queue is not paused but holds unconfirmed
    /// changes; Try Again sends their successors at once.
    func testTryAgainSendsWhatItMade() async throws {
        let service = try await connected()
        let store = try store(service)
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        outbox.hold()
        let name = try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("A")]))
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE outbox SET state = 'unconfirmed' WHERE command_id = ?", arguments: [name.commandId])
        }
        let context = try XCTUnwrap(service.socket?.context)
        outbox.allow(connection: context.id, generation: context.generation)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(outbox.paused)
        XCTAssertEqual(commandRequests, 0)
        service.retryStopped()
        try await waitUntil { self.commandRequests == 1 }
        XCTAssertTrue(service.problems.isEmpty)
    }

    /// C6-5: a cache out of step (a snapshot owed) is not "ready": the
    /// server's state of a request is not known from it.
    func testReadinessEndsWhenTheCacheFallsOutOfStep() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        // The server says each followed stream is at its head.
        try await waitUntil { !self.transport.subscribes.isEmpty }
        for (stream, cursor) in transport.subscribes.reduce(into: [String: Int](), { $0.merge($1) { $1 } }) {
            transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(cursor)}"#)
        }
        try await waitUntil { sync.state == .ready && service.isServerKnown(service, self.key) }
        sync.requestSnapshot()
        XCTAssertFalse(service.isServerKnown(service, key), "out of step until it is ready again")
        XCTAssertNil(sync.readyEpoch)
    }

    /// C7-6: a snapshot is owed until its answer is applied for the current
    /// connection. A hello of the same generation while one is on its way
    /// waits for it; an answer read on the connection before is not applied,
    /// one more is taken; never two at once.
    func testSnapshotOnItsWayHoldsTheNextHello() async throws {
        let service = try await connected()
        let outbox = try XCTUnwrap(service.orgSessions[key]?.outbox)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let applied = sync.snapshots
        let asked = stateRequests
        stateGate.close()
        sync.requestSnapshot()
        try await waitUntil { self.stateRequests == asked + 1 }
        // The connection goes; the next one says the same generation.
        transport.push(.closed(code: 1006))
        try await waitUntil { self.transports.count == 2 }
        hello("g1")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(outbox.allowedConnection, "the hello waits for the snapshot owed")
        XCTAssertEqual(stateRequests, asked + 1, "and starts no second one meanwhile")
        stateGate.open()
        try await waitUntil { outbox.allowedConnection != nil }
        XCTAssertEqual(outbox.allowedConnection, service.socket?.context?.id)
        XCTAssertEqual(stateRequests, asked + 2, "the answer read on the old connection was not used; one more was taken")
        XCTAssertEqual(sync.snapshots, applied + 1, "only the current connection's answer was applied")
        XCTAssertFalse(sync.needsSnapshot)
        XCTAssertEqual(try store(service).generation, "g1")
    }

    /// An action made while a snapshot asked for on the same connection was
    /// on its way runs once the snapshot is in — not at the next event
    /// (D8 core, found in D4).
    func testAnActionMadeDuringASnapshotRunsOnceItIsIn() async throws {
        let service = try await connected()
        try await waitUntil {
            self.subscribedAll()
            return service.isServerKnown(service, self.key)
        }
        let handler = RecordingActionHandler()
        service.actionHandlers[.receive] = handler
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let asked = stateRequests
        stateGate.close()
        sync.requestSnapshot()
        try await waitUntil { self.stateRequests == asked + 1 }
        // Made meanwhile: not handed over while the snapshot is owed.
        let id = "0b7c6d5e-4f3a-4b2c-9d1e-0f9a8b7c6d5e"
        try store(service).apply(ChatSnapshot(cursors: [:], requests: [CallJSON.wire(CallJSON.request(id, state: "submitted", version: 1, onThisDevice: true))]),
                                 facts: [id: ChatLocalFacts()])
        service.runner(for: key).run()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(handler.seen.isEmpty)
        stateGate.open()
        try await waitUntil {
            self.subscribedAll()
            return !handler.seen.isEmpty
        }
    }

    /// C7-7: a missed event after being ready: not ready until caught up.
    func testMissedEventEndsReadiness() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !self.transport.subscribes.isEmpty }
        for (stream, cursor) in transport.subscribes.reduce(into: [String: Int](), { $0.merge($1) { $1 } }) {
            transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(cursor)}"#)
        }
        try await waitUntil { sync.state == .ready && service.isServerKnown(service, self.key) }
        transport.frame(frame(orgStream, 9, "org.renamed", ["name": "X"]))
        try await waitUntil { !service.isServerKnown(service, self.key) }
        XCTAssertNotEqual(sync.state, .ready)
    }

    private func subscribedAll() {
        for (stream, cursor) in transport.subscribes.reduce(into: [String: Int](), { $0.merge($1) { $1 } }) {
            transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(cursor)}"#)
        }
    }

    /// C8-5: while a snapshot is owed or on its way, `subscribed` does not
    /// make the organization ready.
    func testSubscribedWithASnapshotOwedIsNotReady() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !self.transport.subscribes.isEmpty }
        subscribedAll()
        try await waitUntil { service.isServerKnown(service, self.key) }
        stateGate.close()
        sync.requestSnapshot()
        subscribedAll()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(sync.state, .ready)
        XCTAssertFalse(service.isServerKnown(service, key))
        stateGate.open()
        try await waitUntil { !sync.needsSnapshot }
        subscribedAll()
        try await waitUntil { service.isServerKnown(service, self.key) }
    }

    /// C8-6: a failure after the snapshot was written keeps it owed: the
    /// retry takes it again.
    func testFailureAfterApplyKeepsTheSnapshotOwed() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.retryDelay = { _ in 0.05 }
        let asked = stateRequests
        var failures = 1
        sync.afterSnapshotApplied = {
            if failures > 0 {
                failures -= 1
                throw ChatError.storage("cursors could not be read")
            }
        }
        sync.requestSnapshot()
        try await waitUntil { self.stateRequests == asked + 1 }
        try await Task.sleep(for: .milliseconds(20))
        try await waitUntil { !sync.needsSnapshot }
        XCTAssertEqual(stateRequests, asked + 2, "taken again after the failure")
    }

    /// C9-5: a stream's data that could not be removed keeps the
    /// organization out of step; a snapshot is owed and retried.
    func testFailedDropOwesASnapshot() async throws {
        let service = try await connected()
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.retryDelay = { _ in 0.05 }
        let store = try store(service)
        try await waitUntil { !self.transport.subscribes.isEmpty }
        subscribedAll()
        try await waitUntil { service.isServerKnown(service, self.key) }
        try await store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER deny BEFORE DELETE ON cursors BEGIN SELECT RAISE(ABORT, 'disk says no'); END")
        }
        // The team is no longer readable; its data cannot be removed.
        heads = ["org:\(org)": 1, "member:\(org):\(me)": 1]
        myTeams = []
        serve()
        transport.frame(#"{"frame":"unsubscribed","stream":"team:\#(general)"}"#)
        try await waitUntil { sync.needsSnapshot }
        XCTAssertFalse(service.isServerKnown(service, key), "not in step while the data stays")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sync.needsSnapshot, "still owed while removing fails")
        try await store.queue.write { db in try db.execute(sql: "DROP TRIGGER deny") }
        try await waitUntil { !sync.needsSnapshot }
        XCTAssertNil(try store.cursors()["team:\(general)"])
    }

    /// C5-12: Disconnect is done only once it is on disk; a step that fails
    /// is shown, the connection stays, and Disconnect can be pressed again.
    func testDisconnectFinishesOnlyOnDisk() async throws {
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-me", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        service.closeRemoteSession = { _, _ in }
        tokens.deleteFailure = .keychain("locked")
        await service.disconnect()
        XCTAssertNotNil(service.connection, "the token could not go: not disconnected")
        XCTAssertEqual(try files.loadConnections().count, 1)
        guard case .needsSignIn(let text) = service.state else { return XCTFail("\(service.state)") }
        XCTAssertTrue(text.contains("keychain"))
        tokens.deleteFailure = nil
        // The server record cannot be written: still not disconnected.
        let serversFile = files.serversURL
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.directory.path)
        await service.disconnect()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path)
        XCTAssertNotNil(service.connection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: serversFile.path))
        await service.disconnect()
        XCTAssertNil(service.connection)
        XCTAssertEqual(service.state, .off)
        XCTAssertEqual(try files.loadConnections().count, 0)
    }

    /// C4-5: commands kept from before, with no generation recorded anywhere,
    /// are not taken for a first connection: they wait for the user.
    func testKeptCommandsWithoutAGenerationWaitForTheUser() async throws {
        let files = self.files
        try files.prepareDirectory()
        let journal = try ChatJournal.open(files: files)
        let old = try journal.enqueue(ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: "s-me", type: "run.started",
                                                         bodyBytes: Data("{}".utf8), orderKey: "exec:run:r", dependsOn: nil,
                                                         createdAt: Date(timeIntervalSinceNow: -60), state: .pending), key: key)
        XCTAssertNil(try journal.generation(key).generation)
        let service = try await connected(hello: false)
        hello("g1")
        try await waitUntil { service.orgSessions[self.key]?.outbox?.paused == .generationChanged }
        XCTAssertEqual(try service.journal?.commands(for: key).first { $0.commandId == old.commandId }?.state, .unconfirmed)
        XCTAssertEqual(commandRequests, 0)
    }
}

/// A number of answers that go wrong.
final class Budget: @unchecked Sendable {
    private let lock = NSLock()
    private var left = 0
    func give(_ n: Int) { lock.withLock { left += n } }
    func take() -> Bool { lock.withLock { guard left > 0 else { return false }; left -= 1; return true } }
    func peek() -> Bool { lock.withLock { left > 0 } }
    func clear() { lock.withLock { left = 0 } }
}

/// Holds requests while closed.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    func close() { condition.withLock { closed = true } }
    func open() {
        condition.withLock {
            closed = false
            condition.broadcast()
        }
    }
    /// Passes let through before a closed gate holds.
    private var free = 0
    func letThrough(_ count: Int) { condition.withLock { free = count } }
    func pass() {
        condition.withLock {
            if free > 0 {
                free -= 1
                return
            }
            while closed { condition.wait() }
        }
    }
}
