import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// G1/G6's untrusted server. Adapted from scripts/threat-checks/client/
/// FakeChatServer.swift and ChatTeamCallsG6.swift.inc in agentpad-server-cx.
/// HTTP and WebSocket use the production decoders, cache, reconcile and outbox.
/// Only the test advances server state; an HTTP acknowledgement carries no events.
final class FakeChatServer: @unchecked Sendable {
    static let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    static let team = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    static let requestId = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
    static let executor = "s-executor"
    private static let deadline = ChatCallStore.timestamp(Date().addingTimeInterval(3600))
    static let moves: [(type: String, state: String)] = [
        ("request.create", "submitted"), ("request.decide", "approved"),
        ("run.start", "starting"), ("run.started", "running")
    ]
    static let snapshots = ["approved", "starting", "running"]

    private let lock = NSLock()
    private var states: [String: Data] = [:]
    private var receiveAnswer = false
    var answersReceive: Bool {
        get { lock.withLock { receiveAnswer } }
        set { lock.withLock { receiveAnswer = newValue } }
    }

    init() {
        ChatStubProtocol.reset { [self] request, data in
            let session = Self.session(request)
            let body: Data
            switch request.url?.path {
            case "/v1/me":
                body = Self.bytes([
                    "account_id": CallJSON.anna, "session_id": session,
                    "orgs": [["org_id": Self.org, "org_name": "G1", "role": "owner", "handle": "anna", "name": "Anna"]],
                    "streams": ["account:\(CallJSON.anna)": 0]
                ])
            case "/v1/server":
                body = Self.bytes(["name": "G1", "version": "0.1.0", "generation": "g1", "api_versions": ["v1"],
                                   "capabilities": ["auth.email_code", "events.ws", "agents.calls"]])
            case "/v1/orgs/\(Self.org)/state":
                guard let snapshot = lock.withLock({ states[session] }) else {
                    return .success(.init(status: 404))
                }
                body = snapshot
            case "/v1/commands":
                if answersReceive, let command = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: data), command.type == "request.received" {
                    // The server's real Transition response (requests.rs):
                    // only id/state/version, no fixed fields or event bodies.
                    body = Self.bytes(["events": [], "result": ["request_id": Self.requestId, "state": "awaiting_decision", "version": 2]])
                } else {
                    body = Self.bytes(["events": [], "result": [:]])
                }
            default:
                // Unexpected fetches must fail, not silently supply missing evidence.
                return .success(.init(status: 404))
            }
            return .success(.init(status: 200, body: body))
        }
    }

    private static func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private static func session(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer fixture-", with: "") ?? ""
    }

    static func request(state: String, version: Int, here: Bool = true, run: String? = nil, conditions: Int = 1) -> [String: Any] {
        var body = CallJSON.request(requestId, state: state, version: version, runId: run, onThisDevice: here)
        body["conditions_version"] = conditions
        body["deliver_by"] = deadline
        return body
    }

    func snapshot(session: String, requests: [[String: Any]], cursors: [String: Int]? = nil) {
        let body = Self.bytes([
            "org": ["org_id": Self.org, "name": "G1"],
            "members": [["account_id": CallJSON.anna, "handle": "anna", "name": "Anna", "role": "owner"],
                        ["account_id": CallJSON.boris, "handle": "boris", "name": "Boris", "role": "member"]],
            "teams": [["team_id": Self.team, "name": "General", "is_general": true, "members": [CallJSON.anna, CallJSON.boris]]],
            "my_teams": [Self.team], "admin": NSNull(), "agents": [],
            "requests": requests, "requests_next": NSNull(),
            "streams": cursors ?? ["org:\(Self.org)": 0, "team:\(Self.team)": 0,
                                    "member:\(Self.org):\(CallJSON.anna)": 0, "device:\(Self.org):\(session)": 0]
        ])
        lock.withLock { states[session] = body }
    }

    func commands(session: String? = nil) throws -> [ChatCommandEnvelope] {
        try ChatStubProtocol.seen.filter {
            $0.request.url?.path == "/v1/commands" && (session == nil || Self.session($0.request) == session)
        }.map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
    }

    func snapshotCount(session: String) -> Int {
        ChatStubProtocol.seen.filter { Self.session($0.request) == session && $0.request.url?.path.hasSuffix("/state") == true }.count
    }

    @MainActor
    static func wait(_ check: () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !check() {
            if ContinuousClock.now >= deadline {
                XCTFail("FakeChatServer timed out", file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Records completion of the real action handlers so negative assertions
    /// never depend on an arbitrary sleep or an unstarted action runner.
    @MainActor final class ActionProbe: ChatActionHandler {
        let handler: ChatActionHandler
        var active = 0
        var scheduled = 0
        var completed = 0
        init(_ handler: ChatActionHandler) { self.handler = handler }
        func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
            active += 1
            defer { active -= 1; completed += 1 }
            return await handler.perform(action, request: request, key: key)
        }
    }

    @MainActor final class Client {
        let service: ChatService
        let team: TeamService
        let runner = ChatTeamCallsTests.OwnerRunner()
        let session: String
        let key: ChatOrgKey
        let server: FakeChatServer
        private(set) var sockets: [FakeSocketTransport] = []
        private(set) var eventFrames = 0
        private(set) var decisionsWanted: [String] = []
        private(set) var probes: [ChatActionKind: ActionProbe] = [:]
        var store: ChatStore { service.orgSessions[key]!.store! }
        var journal: ChatJournal { service.journal! }

        init(server: FakeChatServer, root: URL, session: String, assigned: Bool = true) throws {
            self.server = server
            self.session = session
            let address = try ChatServerAddress(parsing: "https://chat.example.com")
            key = ChatOrgKey(server: address, accountId: CallJSON.anna, orgId: FakeChatServer.org)
            let files = ChatFiles(directory: root.appendingPathComponent("chat"))
            let folder = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var agent = TeamPublishedAgent(name: "billing", description: "G1 fixture", folder: folder.path, access: .read)
            agent.id = UUID(uuidString: CallJSON.agent)!
            let storage = TeamStorage(directory: root.appendingPathComponent("team"))
            try storage.save([agent], to: storage.agentsURL)
            team = TeamService(storage: storage, runner: runner, offCalls: TeamOffCallStore())
            try team.calls.load()
            team.enterServerMode()
            if assigned {
                let journal = try ChatJournal.open(files: files)
                try journal.save(ChatAssignment(server: address.description, accountId: key.accountId, orgId: key.orgId,
                    agentId: CallJSON.agent, state: .active, name: agent.name, description: agent.description,
                    access: agent.access.rawValue, teamIds: "[]", createdAt: Date(), publishedSession: session))
            }
            runner.holds = false
            runner.tellsProcess = false
            service = ChatService(files: files, tokens: FakeTokenStore())
            service.claudeProjectsRoot = root.appendingPathComponent("claude-projects")
            service.executorRunner = runner
            service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
            service.closeRemoteSession = { _, _ in }
            service.followsFeed = true
            service.retryDelay = { _ in 0.01 }
            let calls = team.calls
            service.localAgent = { id in calls.agents.first { $0.id.uuidString.lowercased() == id } }
            service.onCallStore = { key, store in calls.useServer(store, key: key) }
            service.onCallsChanged = { key in if calls.serverKey == key { calls.reload() } }
            _ = ChatOwnerSide.install(service: service, calls: calls)
            for (kind, handler) in service.actionHandlers {
                let probe = ActionProbe(handler)
                probes[kind] = probe
                service.actionHandlers[kind] = probe
            }
            service.runner(for: key).handler = { [weak self] kind in
                guard let probe = self?.probes[kind] else { return nil }
                probe.scheduled += 1
                return probe
            }
            service.makeSocketTransport = { [weak self] in
                let transport = FakeSocketTransport()
                self?.sockets.append(transport)
                return transport
            }
            service.onDecisionWanted = { [weak self] in self?.decisionsWanted.append($0) }
            try service.saveSignIn(ChatConnection(server: address, accountId: key.accountId, sessionId: session,
                                                  deviceName: session, orgId: key.orgId), token: "fixture-\(session)")
        }

        func start() async throws {
            try await service.start(mode: .server)
            try await FakeChatServer.wait { self.sockets.first?.request != nil }
            let socket = sockets[0]
            socket.push(.opened)
            socket.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
            try await subscribe()
        }

        private func subscribe() async throws {
            let socket = sockets[0]
            try await FakeChatServer.wait {
                for streams in socket.subscribes {
                    for (stream, head) in streams {
                        socket.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(head)}"#)
                    }
                }
                return self.service.orgSessions[self.key]?.sync?.needsSnapshot == false
                    && self.service.runner(for: self.key).mayRun()
            }
        }

        func event(_ type: String, body: [String: Any], stream: String? = nil) async throws {
            let stream = stream ?? (session == FakeChatServer.executor ? "device:\(key.orgId):\(session)" : "member:\(key.orgId):\(key.accountId)")
            let seq = try store.cursor(stream) + 1
            var frame: [String: Any] = ["frame": "event", "stream": stream, "seq": seq, "id": UUID().uuidString,
                "type": type, "actor": ["account_id": CallJSON.boris, "session_id": "forged-session"], "body": body,
                "command_id": NSNull(), "at": "2026-10-05T18:20:00Z"]
            frame["sig"] = NSNull()
            eventFrames += 1
            sockets[0].frame(String(decoding: FakeChatServer.bytes(frame), as: UTF8.self))
            try await FakeChatServer.wait { try self.store.cursor(stream) == seq }
            try await settle()
        }

        func refresh(_ requests: [[String: Any]]) async throws {
            let before = server.snapshotCount(session: session)
            var cursors: [String: Int] = [:]
            for streams in sockets[0].subscribes {
                for stream in streams.keys { cursors[stream] = try store.cursor(stream) }
            }
            server.snapshot(session: session, requests: requests, cursors: cursors)
            service.orgSessions[key]?.sync?.requestSnapshot()
            try await FakeChatServer.wait { self.server.snapshotCount(session: self.session) > before }
            try await subscribe()
            try await settle()
        }

        func settle() async throws {
            service.runner(for: key).run()
            try await FakeChatServer.wait {
                let pending = try self.store.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM actions WHERE state = 'pending'")! }
                let sent = try self.journal.commands(for: self.key).allSatisfy { $0.state == .sent }
                return pending == 0 && self.probes.values.allSatisfy { $0.active == 0 && $0.completed == $0.scheduled }
                    && sent
            }
        }

        func request() throws -> ChatRequest { try XCTUnwrap(store.calls.request(FakeChatServer.requestId)) }
        func close() async { runner.release(); await service.disconnect() }
    }
}
