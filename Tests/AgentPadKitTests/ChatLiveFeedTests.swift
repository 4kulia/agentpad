import Foundation
import GRDB
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

/// The real socket, with every event frame noted on the way in. Nothing is
/// made up: frames come from the server through `ChatURLSessionTransport`.
@MainActor
final class RecordingSocketTransport: ChatSocketTransport {
    struct Seen: Equatable { let stream: String; let seq: Int; let type: String }

    private let inner = ChatURLSessionTransport()
    private var report: (@MainActor (ChatTransportEvent) -> Void)?
    private(set) var events: [Seen] = []

    func open(_ request: URLRequest, onEvent: @escaping @MainActor (ChatTransportEvent) -> Void) {
        report = onEvent
        inner.open(request) { [weak self] event in
            if case .text(let data) = event,
               let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               frame["frame"] as? String == "event",
               let stream = frame["stream"] as? String, let seq = frame["seq"] as? Int, let type = frame["type"] as? String {
                self?.events.append(Seen(stream: stream, seq: seq, type: type))
            }
            onEvent(event)
        }
    }

    func send(_ text: String) { inner.send(text) }

    func close(code: Int) {
        report = nil
        inner.close(code: code)
    }

    /// The network goes away under the socket: the connection ends and the
    /// socket hears an abnormal close, as from a dropped Wi-Fi.
    func drop() {
        let report = self.report
        self.report = nil
        inner.close(code: 1000)
        report?(.closed(code: 1006))
    }
}

/// Live checks of C3 and C8 against the deployed server: sign-in, socket,
/// hello, subscriptions, the send queue, catching up after a drop, two
/// clients of one organization, revoking a session. Opt-in:
///
/// - `AGENTPAD_LIVE_FEED_A`, `AGENTPAD_LIVE_FEED_B`: two addresses, members
///   of one organization;
/// - `AGENTPAD_LIVE_FEED_ORG`: that organization's name or id;
/// - `AGENTPAD_LIVE_CODES`: a folder; after asking for a code the test waits
///   (up to 15 minutes) for a file named by the address holding the code,
///   reads it and removes it. Without it the code comes from the operator
///   command `issue-code` over ssh (the existing live test's way).
///
/// Shared deployment settings: Tests/LIVE-TESTS.md.
/// Codes and tokens are never printed.
@MainActor
final class ChatLiveFeedTests: XCTestCase {
    private var root: URL!
    private var live: ChatLiveConfiguration!
    private let server = try! ChatServerAddress(parsing: "https://agentpad.rabbitshat.ai")
    private var services: [ChatService] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-live-feed-\(UUID().uuidString)")
        live = try ChatLiveConfiguration()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        for service in services { await service.disconnect() }
        services = []
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private struct Client {
        let service: ChatService
        let key: ChatOrgKey
        let transports: () -> [RecordingSocketTransport]
        var transport: RecordingSocketTransport { transports().last! }
        var store: ChatStore { service.orgSessions[key]!.store! }
    }

    private final class Box { var transports: [RecordingSocketTransport] = [] }

    private func code(for address: String) async throws -> String {
        guard let folder = ProcessInfo.processInfo.environment["AGENTPAD_LIVE_CODES"] else { return try issueCode(address) }
        let file = URL(fileURLWithPath: folder).appendingPathComponent(address)
        let deadline = ContinuousClock.now + .seconds(15 * 60)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let range = text.range(of: #"\b\d{8}\b"#, options: .regularExpression) {
                try? FileManager.default.removeItem(at: file)
                return String(text[range])
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("no code arrived for the address in 15 minutes")
    }

    /// D5 on the deployed server: a member asks a colleague's agent as
    /// `team ask` does — the call and its `request.create` in one write, sent
    /// by the queue — and the server has the request, from its own snapshot.
    /// Opt-in, `AGENTPAD_LIVE_D5=1`; its own organization «E2E D5 <mark>».
    /// The owner's side (D4) is not in: the request stays with the server.
    func testAskReachesTheServer() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_D5"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_D5=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "ask-\(mark)-a"), guestAddress = try live.email(id: "ask-\(mark)-b")
        let org = try createOrg(name: "E2E D5 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages") { owner.manages }
        let general = try XCTUnwrap(owner.teams.first { $0.isGeneral }?.teamId)
        try owner.invite(email: guestAddress, role: "member", teams: [])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == guestAddress } }

        // The owner publishes an agent to General.
        let agentId = UUID().uuidString.lowercased(), name = "e2e-\(mark.replacingOccurrences(of: "-", with: ""))"
        let publish = try a.service.enqueue(a.key, type: "agent.publish", args: .object([
            "agent_id": .string(agentId), "name": .string(name), "description": .string("E2E agent"),
            "access": .string("read"), "team_ids": .array([.string(general)]),
        ]))
        try await waitUntil("owner: published") { try self.sent(a, publish) }
        let handle = try XCTUnwrap(owner.member(owner.me)?.handle)

        // The guest asks it, as `team ask` does.
        let b = try await signIn(guestAddress, org: org, name: "guest")
        let team = makeTeam("team-guest", service: b.service)
        team.calls.useServer(b.store.calls, key: b.key)
        ChatOutgoing.asksOn = true
        defer { ChatOutgoing.asksOn = false }
        ChatOutgoing.install(calls: team.calls, service: b.service)
        try await waitUntil("guest: the agent in its catalog") {
            (try? b.store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agents_catalog WHERE agent_id = ?", arguments: [agentId]) }) == 1
        }
        let call = try team.calls.ask("\(name)@\(handle)", prompt: "E2E: are you there?", threadId: nil, origin: nil)
        let state = try await ChatAPI(server: server).orgState(b.key.orgId, token: XCTUnwrap(b.service.token))
        var found = state.requests?.contains { $0.requestId == call.id } == true
        let deadline = ContinuousClock.now + .seconds(30)
        while !found, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            found = try await ChatAPI(server: server).orgState(b.key.orgId, token: XCTUnwrap(b.service.token)).requests?
                .contains { $0.requestId == call.id } == true
        }
        XCTAssertTrue(found, "the server has the request \(call.id)")
        try await waitUntil("guest: the call is the server's now", seconds: 30) {
            (try? b.store.calls.request(call.id))?.flatMap { $0 }?.version ?? 0 > 0
        }
    }

    /// C7 on the deployed server: `team invite` as the CLI's handler runs it
    /// queues the invitation, and the server has it — read from the server's
    /// own snapshot, not the cache. Opt-in, `AGENTPAD_LIVE_C7=1`; its own
    /// organization «E2E C7 <mark>».
    func testInviteFromTheCLI() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_C7"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_C7=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "cli-\(mark)-a"), guestAddress = try live.email(id: "cli-\(mark)-b")
        let org = try createOrg(name: "E2E C7 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages, its rights confirmed") { owner.manages }
        let answer = ChatCLI.invite(email: guestAddress, role: "member", teams: [], a.service)
        XCTAssertTrue(answer.ok, answer.error ?? "")
        let api = ChatAPI(server: server)
        let token = try XCTUnwrap(a.service.token)
        var found = false
        let deadline = ContinuousClock.now + .seconds(30)
        while !found, ContinuousClock.now < deadline {
            let state = try await api.orgState(a.key.orgId, token: token)
            found = state.admin?.invitations.contains { $0.email == guestAddress } == true
            if !found { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertTrue(found, "the server has the invitation of \(guestAddress)")
    }

    /// A mark of this run, for names and addresses: the time, to the second.
    static func runMark(_ now: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: now)
    }

    private func createOrg(name: String, owner: String) throws -> String {
        try live.createOrg(name: name, owner: owner)
    }

    private func issueCode(_ address: String) throws -> String {
        try live.issueCode(address)
    }

    private func waitUntil(_ what: String, seconds: Int = 30, _ condition: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func makeTeam(_ name: String, service: ChatService) -> TeamService {
        let team = TeamService(storage: TeamStorage(directory: root.appendingPathComponent(name)),
                               runner: UnconfiguredLiveRunner(), offCalls: TeamOffCallStore())
        team.calls.sessionFilesRoot = service.claudeProjectsRoot
        return team
    }

    /// Signs in through the service's own steps and starts the feed with
    /// the real socket; returns once the organization's queue may send.
    private func signIn(_ address: String, org: String, name: String, executor: TeamAgentRunner? = nil) async throws -> Client {
        try live.validate(email: address)
        let files = ChatFiles(directory: root.appendingPathComponent(name))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        service.claudeProjectsRoot = root.appendingPathComponent("\(name)-claude-projects")
        service.executorRunner = executor ?? UnconfiguredLiveRunner()
        services.append(service)
        let box = Box()
        service.makeSocketTransport = {
            let made = RecordingSocketTransport()
            box.transports.append(made)
            return made
        }
        service.followsFeed = true
        _ = try await service.makeAPI(server).serverInfo(requiring: ChatAPI.requiredCapabilities)
        // `issue-code` makes a code itself: a mailed one would only spend the
        // address's five codes an hour.
        if ProcessInfo.processInfo.environment["AGENTPAD_LIVE_CODES"] != nil {
            try await service.requestCode(server: server, email: address)
        }
        let answer = try await service.authenticate(server: server, email: address, code: try await code(for: address),
                                                    deviceName: "e2e client feed \(name)")
        guard let membership = answer.orgs.first(where: { $0.orgId == org || $0.orgName == org }) else {
            throw XCTSkip("\(name) is not a member of the organization \(org)")
        }
        let connection = try await service.completeSignIn(answer, server: server, deviceName: "e2e client feed \(name)",
                                                          orgId: membership.orgId)
        try await service.keepSignIn()
        try await service.start(mode: .server)
        let key = try XCTUnwrap(connection.orgKey)
        let client = Client(service: service, key: key, transports: { box.transports })
        try await waitUntil("\(name): connected") { service.socket?.state == .connected }
        try await waitUntil("\(name): the queue may send") { service.orgSessions[key]?.outbox?.isSending == true }
        return client
    }

    private func memberName(_ client: Client, _ account: String) throws -> String? {
        try client.store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM members WHERE account_id = ?", arguments: [account])
        }
    }

    private func setName(_ client: Client, _ name: String) throws -> ChatCommandRecord {
        try client.service.enqueue(client.key, type: "member.set_name", args: .object(["name": .string(name)]))
    }

    private func sent(_ client: Client, _ record: ChatCommandRecord) throws -> Bool {
        try client.store.outbox.commands().first { $0.commandId == record.commandId }?.state == .sent
    }

    func testTwoClientsFollowTheServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let addressA = env["AGENTPAD_LIVE_FEED_A"], let addressB = env["AGENTPAD_LIVE_FEED_B"],
              let org = env["AGENTPAD_LIVE_FEED_ORG"]
        else { throw XCTSkip("set AGENTPAD_LIVE_FEED_A, AGENTPAD_LIVE_FEED_B and AGENTPAD_LIVE_FEED_ORG") }
        try live.validate(email: addressA)
        try live.validate(email: addressB)
        let mark = Int(Date().timeIntervalSince1970) % 100_000

        // 1. Sign-in, socket, hello, the account's and the organization's
        //    streams, member.set_name from the queue, its event by the socket
        //    applied to the cache.
        let a = try await signIn(addressA, org: org, name: "a")
        let accountA = a.key.accountId
        let followed = try XCTUnwrap(a.service.socket?.streams)
        XCTAssertTrue(followed.contains("account:\(accountA)"), "the account stream is followed")
        XCTAssertTrue(followed.contains("org:\(a.key.orgId)"), "the organization stream is followed")
        let nameA = "E2E A \(mark)"
        let renameA = try setName(a, nameA)
        try await waitUntil("A: set_name accepted") { try self.sent(a, renameA) }
        try await waitUntil("A: its event by the socket") { a.transport.events.contains { $0.type == "member.set_name" } }
        try await waitUntil("A: the cache has the name") { try self.memberName(a, accountA) == nameA }

        // 3. A second client of the organization: A's command reaches B, B's reaches A.
        let b = try await signIn(addressB, org: org, name: "b")
        let accountB = b.key.accountId
        XCTAssertEqual(b.key.orgId, a.key.orgId)
        XCTAssertEqual(try memberName(b, accountA), nameA, "B's snapshot has A's name")
        let nameB = "E2E B \(mark)"
        let renameB = try setName(b, nameB)
        try await waitUntil("B: set_name accepted") { try self.sent(b, renameB) }
        try await waitUntil("A: B's name by the socket") { try self.memberName(a, accountB) == nameB }
        let nameA2 = "E2E A2 \(mark)"
        let renameA2 = try setName(a, nameA2)
        try await waitUntil("A: second set_name accepted") { try self.sent(a, renameA2) }
        try await waitUntil("B: A's name by the socket") { try self.memberName(b, accountA) == nameA2 }

        // 2. A's socket drops; B changes its name meanwhile; A comes back and
        //    catches up from its cursors: every missed event once, none lost.
        a.service.socket?.retryDelay = { _ in 4 }
        let before = try a.store.cursors()
        let dropped = a.transport
        dropped.drop()
        try await waitUntil("A: disconnected") { a.service.socket?.state != .connected }
        var lastB = nameB
        for i in 1...3 {
            lastB = "E2E B\(i) \(mark)"
            let record = try setName(b, lastB)
            try await waitUntil("B: rename \(i) accepted") { try self.sent(b, record) }
        }
        try await waitUntil("A: reconnected", seconds: 60) { a.service.socket?.state == .connected && a.transport !== dropped }
        try await waitUntil("A: caught up with B's names") { try self.memberName(a, accountB) == lastB }
        let state = try await ChatAPI(server: server).orgState(a.key.orgId, token: XCTUnwrap(a.service.token))
        let after = try a.store.cursors()
        for (stream, head) in state.streams where after[stream] != nil {
            XCTAssertEqual(after[stream], head, "\(stream): the cursor is at the server's head")
        }
        let caughtUp = a.transport.events
        for stream in Set(caughtUp.map(\.stream)) {
            let seqs = caughtUp.filter { $0.stream == stream }.map(\.seq)
            let from = (before[stream] ?? 0) + 1
            XCTAssertEqual(seqs, Array(from..<(from + seqs.count)), "\(stream): from the cursor on, no gaps, no repeats")
        }
        XCTAssertGreaterThanOrEqual(caughtUp.filter { $0.type == "member.set_name" }.count, 3, "the three missed renames came")

        // 4. A disconnects: its session is closed (401); B goes on.
        let tokenA = try XCTUnwrap(a.service.token)
        await a.service.disconnect()
        services.removeAll { $0 === a.service }
        do {
            _ = try await ChatAPI(server: server).me(token: tokenA)
            XCTFail("A's session still works after Disconnect")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.code, "unauthorized")
        }
        XCTAssertEqual(b.service.socket?.state, .connected)
        let nameB2 = "E2E B5 \(mark)"
        let renameB2 = try setName(b, nameB2)
        try await waitUntil("B: works after A left") { try self.sent(b, renameB2) }
        try await waitUntil("B: its own event") { try self.memberName(b, accountB) == nameB2 }
    }

    /// C6 on the deployed server, through `ChatOrgModel` as the window uses
    /// it: the owner makes a team, invites a second address into it; the
    /// second sees that team and no other; promoted it sees every team,
    /// demoted none of others again — in its cache, not only on screen; it
    /// leaves the team, is removed, and keeps neither team nor organization.
    /// Opt-in, `AGENTPAD_LIVE_C6=1`. Each run makes its own organization
    /// «E2E C6 <mark>» with new addresses from `AGENTPAD_LIVE_EMAIL`
    /// (operator `create-org` over ssh), so the limit of five codes an hour
    /// per address is never reached.
    func testOrganizationManagedFromTheWindow() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_C6"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_C6=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "org-\(mark)-a"), guestAddress = try live.email(id: "org-\(mark)-b")
        let org = try createOrg(name: "E2E C6 \(mark)", owner: ownerAddress)

        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        // Every organization starts in doubt until its first snapshot (C6h).
        try await waitUntil("owner: manages, its rights confirmed") { owner.myRole == "owner" && owner.manages }

        // The owner makes two teams: one for the guest, one it never joins.
        try owner.createTeam("E2E Team \(mark)")
        try owner.createTeam("E2E Secret \(mark)")
        try await waitUntil("owner: both teams by its admin stream") {
            Set(owner.teams.map(\.name)).isSuperset(of: ["E2E Team \(mark)", "E2E Secret \(mark)"])
        }
        let teamId = try XCTUnwrap(owner.teams.first { $0.name == "E2E Team \(mark)" }?.teamId)
        let secretId = try XCTUnwrap(owner.teams.first { $0.name == "E2E Secret \(mark)" }?.teamId)
        try owner.invite(email: guestAddress, role: "member", teams: [teamId])
        // The guest signs in only once the invitation is on the server (C6j).
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == guestAddress } }

        // The guest signs in: General and its team, nothing of the secret one.
        let b = try await signIn(guestAddress, org: org, name: "guest")
        let guest = try XCTUnwrap(ChatOrgModel.current(b.service))
        try await waitUntil("guest: its team") { guest.myTeams.contains { $0.teamId == teamId } }
        func cachedTeams() throws -> Set<String> {
            Set(try b.store.queue.read { db in try String.fetchAll(db, sql: "SELECT team_id FROM teams") })
        }
        XCTAssertFalse(try cachedTeams().contains(secretId), "the guest's cache has no team it is not in")
        XCTAssertEqual(guest.myRole, "member")
        XCTAssertFalse(guest.actions.contains(.createTeam))
        let guestId = guest.me
        try await waitUntil("owner: the guest in the team") {
            owner.view.teams.first { $0.teamId == teamId }?.members.contains(guestId) == true
        }

        // Promoted: every team. Demoted: other teams leave its cache again.
        // Each action waits for what it needs in the model that acts (C6i p2-3).
        try await waitUntil("owner: sees the guest, manages") { owner.manages && owner.member(guestId) != nil }
        let guestMember = try XCTUnwrap(owner.member(guestId))
        try owner.setRole(guestMember, to: "admin")
        try await waitUntil("guest: an admin sees every team") { guest.myRole == "admin" && (try? cachedTeams().contains(secretId)) == true }
        try await waitUntil("owner: sees the guest as admin") { owner.manages && owner.member(guestId)?.role == "admin" }
        try owner.setRole(try XCTUnwrap(owner.member(guestId)), to: "member")
        try await waitUntil("guest: demoted, the secret team is gone from its cache") {
            guest.myRole == "member" && (try? cachedTeams().contains(secretId)) == false
        }

        // The guest leaves its team: nothing of it stays; the owner sees it go.
        // Its demotion put its rights in doubt: Leave waits for the snapshot (C6h p2-5).
        try await waitUntil("guest: rights confirmed, its team shown") { !guest.inDoubt && guest.myTeams.contains { $0.teamId == teamId } }
        try guest.leave(try XCTUnwrap(guest.myTeams.first { $0.teamId == teamId }))
        try await waitUntil("guest: the team left its cache") { (try? cachedTeams().contains(teamId)) == false }
        try await waitUntil("owner: the guest out of the team") {
            owner.view.teams.first { $0.teamId == teamId }?.members.contains(guestId) == false
        }

        // Devices and the security log.
        let devices = try XCTUnwrap(ChatDevicesModel.current(a.service))
        await devices.load()
        XCTAssertEqual(devices.devices?.filter(\.current).count, 1, devices.problem ?? "")
        await owner.loadAudit()
        XCTAssertTrue(owner.audit?.contains { $0.action == "team.create" && $0.object == "team:\(teamId)" } == true, owner.problem ?? "")

        // Removed: the guest has neither the organization nor its cache.
        try await waitUntil("owner: sees the guest as member") { owner.manages && owner.member(guestId)?.role == "member" }
        try owner.remove(try XCTUnwrap(owner.member(guestId)))
        try await waitUntil("guest: no longer a member") {
            if case .notMember = b.service.state { return b.service.orgSessions[b.key] == nil }
            return false
        }
        let cache = ChatFiles(directory: root.appendingPathComponent("guest")).cacheURL(b.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "the guest's cache of the organization is deleted")
        XCTAssertTrue(owner.refused.isEmpty, "\(owner.refused)")
        XCTAssertTrue(guest.refused.isEmpty, "\(guest.refused)")

        // Tidy: the teams of this run are archived.
        try await waitUntil("owner: manages") { owner.manages }
        for id in [teamId, secretId] {
            if let team = owner.teams.first(where: { $0.teamId == id }) { try owner.archiveTeam(team) }
        }
        try await waitUntil("owner: teams archived") { owner.teams.filter { [teamId, secretId].contains($0.teamId) }.allSatisfy(\.archived) }
    }
    /// D3 on the deployed server: the owner publishes an agent from the
    /// window's path (no claude runs: publishing only); the member sees it
    /// in its catalog — the cache's `agents_catalog`, the Team window's list
    /// and `team agents` (MCP `team_agents` asks the same) — by
    /// `name@handle`. Opt-in, `AGENTPAD_LIVE_D3=1`; its own organization
    /// «E2E D3 <mark>» and addresses (operator `create-org` over ssh).
    func testAPublishedAgentReachesAColleaguesCatalog() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_D3"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_D3=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "pub-\(mark)-a"), memberAddress = try live.email(id: "pub-\(mark)-b")
        let org = try createOrg(name: "E2E D3 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages, its rights confirmed") { owner.myRole == "owner" && owner.manages }
        try owner.invite(email: memberAddress, role: "member", teams: [])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == memberAddress } }
        let b = try await signIn(memberAddress, org: org, name: "member")

        // The owner publishes to General, as the Published Agents window does.
        let general = try XCTUnwrap(a.service.myTeams(a.key).first(where: \.isGeneral)?.teamId)
        let team = makeTeam("owner-team", service: a.service)
        team.calls.serverMode = true
        team.calls.publishing = a.service
        team.calls.useServer(a.store.calls, key: a.key)
        a.service.localAgent = { id in team.calls.agents.first { $0.id.uuidString.lowercased() == id } }
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var agent = TeamPublishedAgent.fresh(serverMode: true)
        agent.name = "e2e-billing"
        agent.description = "E2E D3 \(mark): publishing only"
        agent.folder = folder.path
        try await team.calls.saveAndPublish([agent], teams: [general], key: a.key)
        let id = agent.id.uuidString.lowercased()
        let journal = try XCTUnwrap(a.service.journal)
        try await waitUntil("owner: the server took the publication") { try journal.assignment(a.key, agentId: id)?.state == .active }
        XCTAssertEqual(a.service.publishStatus(agent, key: a.key).status, .published(teams: [general]))

        // The member: its cache, the Team window's list, `team agents`.
        try await waitUntil("member: the card in its catalog") { try b.store.calls.catalog().contains { $0.agentId == id } }
        let card = try XCTUnwrap(b.store.calls.catalog().first { $0.agentId == id })
        XCTAssertEqual(card.name, "e2e-billing")
        XCTAssertEqual(card.access, "read")
        let memberTeam = makeTeam("member-team", service: b.service)
        memberTeam.enterServerMode()
        memberTeam.calls.useServer(b.store.calls, key: b.key)
        func ownerHandle() throws -> String? {
            try b.store.queue.read { db in
                try String.fetchOne(db, sql: "SELECT handle FROM members WHERE account_id = ?", arguments: [a.key.accountId])
            }
        }
        let handle = try XCTUnwrap(ownerHandle())
        XCTAssertTrue(memberTeam.calls.colleaguesAgents.contains { $0.address == "e2e-billing@\(handle)" })
        var list = AgentPadCLIRequest(verb: .team)
        list.teamAction = AgentPadCLITeamAction.agents.rawValue
        let listed = await TeamCLIHandler.handle(list, service: memberTeam)
        XCTAssertTrue(listed.team?.agents?.contains { $0.address == "e2e-billing@\(handle)" } == true, listed.error ?? "")

        // D3b: the member asks; the owner's Mac does not take it (no owner's
        // side here), so it waits. The owner unpublishes: the card leaves the
        // member's catalog, the waiting request is declined, and the agent
        // leaves the owner's Mac once the server took it.
        ChatOutgoing.asksOn = true
        defer { ChatOutgoing.asksOn = false }
        b.service.onCallsChanged = { _ in memberTeam.calls.reload() }
        ChatOutgoing.install(calls: memberTeam.calls, service: b.service)
        let waiting = try memberTeam.calls.ask("e2e-billing@\(handle)", prompt: "E2E D3b: wait", threadId: nil, origin: nil).id
        try await waitUntil("member: the server has the call", seconds: 60) {
            (try? b.store.calls.request(waiting))?.flatMap { $0 }?.version ?? 0 > 0
        }
        a.service.onAgentUnpublished = { id in try? team.calls.removeUnpublished(UUID(uuidString: id)!) }
        try team.calls.unpublish(agent.id)
        XCTAssertEqual(try journal.assignment(a.key, agentId: id)?.state, .removing)
        try await waitUntil("owner: the server took the unpublishing", seconds: 60) { try journal.assignment(a.key, agentId: id) == nil }
        XCTAssertFalse(team.calls.agents.contains { $0.id == agent.id })
        try await waitUntil("member: the card left its catalog", seconds: 60) { try !b.store.calls.catalog().contains { $0.agentId == id } }
        try await waitUntil("member: the waiting call declined", seconds: 60) {
            (try? b.store.calls.request(waiting))??.state == .declined
        }
    }
    /// The owner's executor: the stand-in (no claude runs) or the real
    /// `claude -p`; `broken` — a `claude` that does not exist, for the run
    /// that fails to start.
    private final class LiveRunner: TeamAgentRunner, @unchecked Sendable {
        let real: Bool
        var isolation: IsolatedClaudeFixture?
        var answer = "E2E answer from the stand-in executor"
        var broken = false
        /// Runs until stopped (D4b).
        var holds = false
        /// Tells an activity, then waits for `release` once (D4b-2).
        var gated = false
        var versionGate: ClaudeVersionPreflight?
        private var released = false
        private(set) var requests: [TeamRunRequest] = []
        func release() { released = true }
        init(real: Bool) { self.real = real }
        func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
            try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
        }
        func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
                 onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
            requests.append(request)
            if gated {
                // A process of its own (a child `sleep`, ended here), told as
                // a real run tells its process: the request becomes `running`,
                // and the server takes the run's activity only then.
                gated = false
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sleep")
                child.arguments = ["120"]
                try child.run()
                defer { child.terminate() }
                let pid = child.processIdentifier
                try onProcessStarted(TeamProcessStart(pid: pid, pgid: pid, startTime: TeamProcesses.startTime(pid) ?? 1))
                while !released {
                    onActivity("E2E activity")
                    try await Task.sleep(for: .seconds(1))
                }
            }
            if holds {
                // A real child through Y5, even with the stand-in answer:
                // cancellation must exercise the kernel and output checks.
                let script = URL(fileURLWithPath: request.agent.folder).appendingPathComponent("e2e-hold")
                try "#!/bin/sh\nexec /bin/sleep 300\n".write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                return try await ClaudeCodeRunner(fixturePath: script.path)
                    .run(request, onActivity: onActivity, onProcessStarted: onProcessStarted)
            }
            if broken {
                return try await ClaudeCodeRunner(claudePath: "/nonexistent/agentpad-e2e/claude")
                    .run(request, onActivity: onActivity, onProcessStarted: onProcessStarted)
            }
            if real {
                let isolated = try XCTUnwrap(isolation, "A real executor needs its isolated test profile")
                let path = try XCTUnwrap(isolated.executablePath)
                var req = request
                req.onVersionReady = { ready in
                    XCTAssertEqual(ready.version, "2.1.289", "the live Y2 run must use the probed version")
                }
                return try await isolated.runner(claudePath: path, preflight: versionGate)
                    .run(req, onActivity: onActivity, onProcessStarted: onProcessStarted)
            }
            return TeamRunResult(text: answer, isError: false, turns: 1, durationMs: 1)
        }
    }

    /// D4 on the deployed server, two clients: the owner publishes (D3), the
    /// member asks (D5); the owner's side takes it (`receive`), the owner
    /// allows it the way the Allow button does (`TeamCalls.decide`), the run
    /// goes through `TeamLauncher`, and the member gets the answer
    /// (`result.deliver`). A second call is declined. Opt-in, `AGENTPAD_LIVE_D4=1`: a
    /// stand-in executor; with `AGENTPAD_LIVE_REAL_CLAUDE=1` the real
    /// `claude -p` (`ClaudeCodeRunner`), the agent with the Read rights. Its
    /// own organization «E2E D4 <mark>» (operator `create-org` over ssh).
    func testACallGoesFromAskToAnswer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTPAD_LIVE_D4"] == "1" || env["AGENTPAD_LIVE_REAL_CLAUDE"] == "1" else {
            throw XCTSkip("set AGENTPAD_LIVE_D4=1 (stand-in executor) or AGENTPAD_LIVE_REAL_CLAUDE=1 (real claude)")
        }
        let real = env["AGENTPAD_LIVE_REAL_CLAUDE"] == "1"
        let isolated = real ? try IsolatedClaudeFixture() : nil
        defer { isolated?.remove() }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "run-\(mark)-a"), memberAddress = try live.email(id: "run-\(mark)-b")
        let org = try createOrg(name: "E2E D4 \(mark)", owner: ownerAddress)
        let runner = LiveRunner(real: real)
        runner.isolation = isolated
        let a = try await signIn(ownerAddress, org: org, name: "owner", executor: runner)
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages, its rights confirmed") { owner.myRole == "owner" && owner.manages }
        try owner.invite(email: memberAddress, role: "member", teams: [])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == memberAddress } }

        // The owner's Mac: its agent published, its side installed.
        let ownerTeam = makeTeam("owner-team", service: a.service)
        isolated?.configure(service: a.service, calls: ownerTeam.calls)
        ownerTeam.calls.serverMode = true
        ownerTeam.calls.publishing = a.service
        ownerTeam.calls.useServer(a.store.calls, key: a.key)
        a.service.localAgent = { id in ownerTeam.calls.agents.first { $0.id.uuidString.lowercased() == id } }
        a.service.onCallsChanged = { _ in ownerTeam.calls.reload() }
        ChatOutgoing.asksOn = true
        defer { ChatOutgoing.asksOn = false }
        _ = ChatOwnerSide.install(service: a.service, calls: ownerTeam.calls)
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "The refund was made twice by a retry of the webhook.\n".write(to: folder.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        var agent = TeamPublishedAgent.fresh(serverMode: true)
        agent.name = "e2e-runner"
        agent.description = "E2E D4 \(mark)"
        agent.folder = folder.path
        let general = try XCTUnwrap(a.service.myTeams(a.key).first(where: \.isGeneral)?.teamId)
        try await ownerTeam.calls.saveAndPublish([agent], teams: [general], key: a.key)
        let journal = try XCTUnwrap(a.service.journal)
        try await waitUntil("owner: published") { try journal.assignment(a.key, agentId: agent.id.uuidString.lowercased())?.state == .active }
        let handle = try XCTUnwrap(owner.member(owner.me)?.handle)

        // The member's Mac asks.
        let b = try await signIn(memberAddress, org: org, name: "member")
        let memberTeam = makeTeam("member-team", service: b.service)
        memberTeam.calls.serverMode = true
        memberTeam.calls.useServer(b.store.calls, key: b.key)
        b.service.onCallsChanged = { _ in memberTeam.calls.reload() }
        ChatOutgoing.install(calls: memberTeam.calls, service: b.service)
        try await waitUntil("member: the agent in its catalog", seconds: 60) { try b.store.calls.catalog().contains { $0.name == "e2e-runner" } }
        func ask(_ text: String) throws -> String { try memberTeam.calls.ask("e2e-runner@\(handle)", prompt: text, threadId: nil, origin: nil).id }
        func waiting(_ id: String) async throws {
            try await waitUntil("owner: \(id) waits for the decision", seconds: 60) {
                ownerTeam.calls.reload()
                return ownerTeam.calls.incoming.contains { $0.id == id && $0.state == .awaitingApproval }
            }
        }
        func outcome(_ id: String) -> TeamCalls.Outgoing? {
            memberTeam.calls.reload()
            return memberTeam.calls.outgoing.first { $0.id == id }
        }

        // The owner's Mac is off (its feed and socket stopped, its session and
        // publication kept — not Disconnect, which closes the session): the
        // member asks; the server takes it; the owner comes back and gets the
        // request by its snapshot, with no `request.create` event (7.1, steps 4–5).
        a.service.stopFeed()
        let seenBefore = a.transports().count
        let allowed = try ask(real ? "Read NOTES.md and say in one sentence why the refund happened twice." : "E2E: are you there?")
        try await waitUntil("member: the server has the call", seconds: 60) {
            (try? b.store.calls.request(allowed))?.flatMap { $0 }?.version ?? 0 > 0
        }
        XCTAssertNil(try a.store.calls.request(allowed), "the owner's Mac is off")
        try await a.service.start(mode: .server)
        try await waiting(allowed)
        let creates = a.transports().dropFirst(seenBefore).flatMap(\.events).filter { $0.type == "request.create" }
        XCTAssertEqual(creates, [], "by its snapshot, not by an event")
        XCTAssertNil(ownerTeam.calls.decide(allowed, allow: true))
        try await waitUntil("member: the answer", seconds: real ? 300 : 90) { outcome(allowed)?.report.state == .done }
        if outcome(allowed)?.report.state != .done { dumpD4(allowed, owner: a, member: b, journal: journal) }
        let text = try XCTUnwrap(outcome(allowed)?.report.text)
        XCTAssertFalse(text.isEmpty)
        if !real { XCTAssertEqual(text, "E2E answer from the stand-in executor") }
        XCTAssertEqual(a.service.undeliveredResults(), [], "delivered")

        // Y2: service processes and owner decisions must not produce started.
        // A deliberately unprobed configuration forces the real local card;
        // the binary itself is the same probed 2.1.289, with identical rights.
        if real, env["AGENTPAD_LIVE_Y2"] == "1" {
            let versions = ClaudeVersionApprovals()
            runner.versionGate = try XCTUnwrap(runner.isolation).preflight(configuration: "live-y2-unprobed", approvals: { versions })
            let versionCall = try ask("Read NOTES.md and give one brief sentence.")
            try await waiting(versionCall)
            XCTAssertNil(ownerTeam.calls.decide(versionCall, allow: true))
            try await waitUntil("owner: the version card", seconds: 60) { versions.pending.count == 1 }
            let card = try XCTUnwrap(versions.pending.first)
            try await waitUntil("member: version activity in starting", seconds: 15) {
                outcome(versionCall)?.report.activity?.contains("Ожидает разрешения владельца на версию Claude Code") == true
            }
            XCTAssertEqual(outcome(versionCall)?.serverState, "starting")
            XCTAssertFalse(outcome(versionCall)?.report.state.isFinal ?? true)
            let approval = try XCTUnwrap(journal.approval(a.key, requestId: versionCall))
            XCTAssertNil(try journal.run(approval.runId)?.pid)
            versions.decide(card.id, allow: true)
            try await waitUntil("member: version-approved answer", seconds: 120) { outcome(versionCall)?.report.state == .done }
            runner.versionGate = nil
        }

        // D5b: the member goes on with the thread of that answer: the owner's
        // Mac runs it in the same conversation.
        let thread = try XCTUnwrap(outcome(allowed)?.report.threadId)
        let followUp = try memberTeam.calls.ask("e2e-runner@\(handle)", prompt: real ? "And how was it fixed?" : "E2E: and then?",
                                                threadId: thread, origin: nil).id
        try await waiting(followUp)
        XCTAssertNil(ownerTeam.calls.decide(followUp, allow: true))
        try await waitUntil("member: the follow-up answered", seconds: real ? 300 : 90) { outcome(followUp)?.report.state == .done }
        if !real {
            let resumed = try XCTUnwrap(runner.requests.last)
            XCTAssertTrue(resumed.resume, "the same conversation")
            XCTAssertEqual(resumed.sessionId, runner.requests.dropLast().last?.sessionId)
        }

        // Declined.
        let declined = try ask("E2E: decline me")
        try await waiting(declined)
        XCTAssertNil(ownerTeam.calls.decide(declined, allow: false, reason: "E2E decline"))
        try await waitUntil("member: declined", seconds: 60) { outcome(declined)?.report.state == .denied }

        // A `claude` that cannot run: the member gets `failed_to_start` with its reason.
        runner.broken = true
        let broken = try ask("E2E: fail to start")
        try await waiting(broken)
        XCTAssertNil(ownerTeam.calls.decide(broken, allow: true))
        try await waitUntil("member: failed to start", seconds: 90) { outcome(broken)?.serverState == "failed_to_start" }
        let reason = (try? b.store.calls.request(broken))??.failureReason
        XCTAssertNotNil(reason, "with its reason")

        // D4b-2: the run's activity reaches the member; a folder granted while
        // it runs continues the same run once, and the member gets the answer.
        runner.broken = false
        runner.gated = true
        let extended = try ask("E2E: ask for a folder")
        try await waiting(extended)
        XCTAssertNil(ownerTeam.calls.decide(extended, allow: true))
        try await waitUntil("member: the run's activity", seconds: 60) { outcome(extended)?.report.activity == "E2E activity" }
        let extra = root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        ownerTeam.calls.reload()
        let folderAsked = try await ownerTeam.calls.requestAccess(callId: extended, path: extra.path, reason: "E2E")
        let granted = await ownerTeam.calls.decideAccess(folderAsked.id, .once)
        XCTAssertNil(granted)
        runner.release()
        try await waitUntil("member: answered after the continuation", seconds: 90) { outcome(extended)?.serverState == "finished" && outcome(extended)?.report.text != nil }
        XCTAssertEqual(runner.requests.filter { $0.prompt.contains("granted access") }.count, 1, "one continuation")

        // D4b/D5b: the member cancels while the agent runs: `stop_requested`,
        // the owner's Mac confirms the real child's stop through Y5 and
        // tells `run.stopped`.
        runner.broken = false
        runner.holds = true
        let cancelled = try ask("E2E: cancel me while I run")
        try await waiting(cancelled)
        XCTAssertNil(ownerTeam.calls.decide(cancelled, allow: true))
        try await waitUntil("member: it runs", seconds: 60) { outcome(cancelled)?.serverState == "running" }
        _ = await memberTeam.calls.cancel(cancelled)
        try await waitUntil("member: the stop is told", seconds: 90) { outcome(cancelled)?.serverState == "stopped" }
        XCTAssertEqual(a.service.launcher?.live.isEmpty, true, "the run stopped on the owner's Mac")
    }
    /// Where a call stands on both sides, when it did not come through:
    /// states, actions, approvals, runs and the executor's commands with
    /// their answers. No token or code.
    private func dumpD4(_ id: String, owner: Client, member: Client, journal: ChatJournal) {
        func line(_ text: String) { FileHandle.standardError.write(Data("D4DIAG \(text)\n".utf8)) }
        for (side, client) in [("owner", owner), ("member", member)] {
            let request = (try? client.store.calls.request(id)) ?? nil
            line("\(side) request state=\(request?.state.rawValue ?? "none") v=\(request?.version ?? -1) run=\(request?.runId ?? "-") onThisDevice=\(request?.onThisDevice ?? false) result=\(request?.result != nil)")
            let actions = (try? client.store.queue.read { db in
                try Row.fetchAll(db, sql: "SELECT kind, state, error FROM actions WHERE request_id = ?", arguments: [id])
                    .map { "\($0["kind"] as String):\($0["state"] as String):\(($0["error"] as String?) ?? "")" }
            }) ?? []
            line("\(side) actions \(actions)")
            let outbox = ((try? client.store.outbox.commands()) ?? []).map { "\($0.type):\($0.state.rawValue):\($0.error ?? "")" }
            line("\(side) outbox \(outbox)")
        }
        for approval in (try? journal.approvals()) ?? [] where approval.requestId == id {
            line("approval consumed=\(approval.consumedAt != nil) void=\(approval.voidReason ?? "-")")
        }
        for run in (try? journal.runs()) ?? [] where run.requestId == id {
            line("run outcome=\(run.outcome?.rawValue ?? "-") pid=\(run.pid.map(String.init) ?? "-") result=\(run.resultText != nil)")
        }
        for command in (try? journal.commands(for: owner.key)) ?? [] {
            line("journal \(command.type):\(command.state.rawValue):\(command.error ?? "") gen=\(command.sentGeneration ?? "-") key=\(command.orderKey)")
        }
        line("owner launcher live=\(owner.service.launcher?.live.count ?? -1) serverKnown=\(owner.service.isServerKnown(owner.service, owner.key))")
    }

    /// F2 on the deployed server, its own organization «E2E F2 <mark>»:
    /// channels made, renamed and archived from the left panel's model; a
    /// member's rename of another's channel refused; out of a team, its
    /// channel is "no access"; no channel event passed over. Opt-in,
    /// `AGENTPAD_LIVE_F2=1`.
    func testChannelsFromTheLeftPanel() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_F2"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_F2=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "f2-\(mark)-a"), guestAddress = try live.email(id: "f2-\(mark)-b")
        let org = try createOrg(name: "E2E F2 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages") { owner.manages && owner.view.channelsServed }
        let general = try XCTUnwrap(owner.myTeams.first(where: \.isGeneral))

        // A team for the "no access" part: the owner joins it, the guest is invited to it.
        try owner.createTeam("E2E F2 Team \(mark)")
        try await waitUntil("owner: the team") { owner.teams.contains { $0.name == "E2E F2 Team \(mark)" } }
        let teamId = try XCTUnwrap(owner.teams.first { $0.name == "E2E F2 Team \(mark)" }?.teamId)
        try owner.join(try XCTUnwrap(owner.teams.first { $0.teamId == teamId }))
        try await waitUntil("owner: in the team") { owner.myTeams.contains { $0.teamId == teamId } }
        try owner.invite(email: guestAddress, role: "member", teams: [teamId])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == guestAddress } }

        // Channels made by the owner: one in General, one in the team.
        let lobby = try owner.createChannel("lobby-\(mark)", in: general)
        let inner = try owner.createChannel("inner-\(mark)", in: try XCTUnwrap(owner.myTeams.first { $0.teamId == teamId }))
        try await waitUntil("owner: both cards") { owner.visibleChannel(lobby) != nil && owner.visibleChannel(inner) != nil }

        let b = try await signIn(guestAddress, org: org, name: "guest")
        let guest = try XCTUnwrap(ChatOrgModel.current(b.service))
        let lobbyRef = ChannelRef(b.key, channel: lobby), innerRef = ChannelRef(b.key, channel: inner)
        try await waitUntil("guest: both channels") { guest.visibleChannel(lobby) != nil && guest.visibleChannel(inner) != nil }
        if case .ready(let card, _, _) = ChannelTabState.of(lobbyRef, model: guest) {
            XCTAssertEqual(card.name, "lobby-\(mark)")
        } else { XCTFail("guest: lobby not ready") }

        // A member renames another's channel: the server refuses, the name stays.
        let card = try XCTUnwrap(guest.visibleChannel(lobby))
        XCTAssertFalse(guest.canRenameChannel(card), "the panel offers no rename")
        _ = try b.service.enqueue(b.key, type: "channel.rename", args: .object(["channel_id": .string(lobby), "name": .string("taken-over")]))
        try await waitUntil("guest: the refusal, in words") { guest.channelRefusals.contains { $0.reason == "Your role does not allow this" } }
        // A refusal is a sign of changed rights (C6): nothing is shown until the snapshot.
        try await waitUntil("guest: rights confirmed again") { !guest.inDoubt && guest.visibleChannel(lobby) != nil }
        XCTAssertEqual(guest.visibleChannel(lobby)?.name, "lobby-\(mark)")

        // The owner renames and archives: the guest's tab follows by events.
        try owner.renameChannel(try XCTUnwrap(owner.visibleChannel(lobby)), to: "hall-\(mark)")
        try await waitUntil("guest: renamed") { guest.visibleChannel(lobby)?.name == "hall-\(mark)" }
        XCTAssertEqual(ChannelTabState.of(lobbyRef, model: guest).title, "#hall-\(mark)")
        try owner.archiveChannel(try XCTUnwrap(owner.visibleChannel(lobby)))
        try await waitUntil("guest: archived") { guest.visibleChannel(lobby)?.archived == true }

        // Out of the team: its channel is "no access" — after the doubt, never a name meanwhile.
        try await waitUntil("owner: sees the guest") { owner.manages && owner.member(guest.me) != nil }
        try owner.removeMember(guest.me, from: try XCTUnwrap(owner.teams.first { $0.teamId == teamId }))
        try await waitUntil("guest: no access to the team's channel", seconds: 60) {
            ChannelTabState.of(innerRef, model: guest) == .noAccess
        }
        XCTAssertNil(guest.visibleChannel(inner))

        // No channel event was passed over (before F2 each asked for a snapshot).
        let guestStore = b.store
        let skipped = try await guestStore.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skipped_events WHERE type LIKE 'channel.%'")
        }
        XCTAssertEqual(skipped, 0)
        XCTAssertTrue(owner.channelRefusals.isEmpty, "\(owner.channelRefusals)")
    }

    /// F3 on the deployed server, its own organization «E2E F3 <mark>»: two
    /// members write in a channel and in a thread; an edit and a deletion
    /// reach the other; a stale edit is a revision conflict that keeps the
    /// author's text. Opt-in, `AGENTPAD_LIVE_F3=1`.
    func testTwoMembersTalkInAChannel() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_F3"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_F3=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "f3-\(mark)-a"), guestAddress = try live.email(id: "f3-\(mark)-b")
        let org = try createOrg(name: "E2E F3 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages") { owner.manages && owner.view.channelsServed }
        try owner.invite(email: guestAddress, role: "member", teams: [])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == guestAddress } }
        let general = try XCTUnwrap(owner.myTeams.first(where: \.isGeneral))
        let channel = try owner.createChannel("talk-\(mark)", in: general)
        try await waitUntil("owner: the card") { owner.visibleChannel(channel) != nil }

        let b = try await signIn(guestAddress, org: org, name: "guest")
        let guest = try XCTUnwrap(ChatOrgModel.current(b.service))
        try await waitUntil("guest: the channel") { guest.visibleChannel(channel) != nil }
        // Both have the channel open: followed live.
        a.service.channelTab(ChannelRef(a.key, channel: channel), open: true)
        b.service.channelTab(ChannelRef(b.key, channel: channel), open: true)
        func text(_ client: Client, _ id: String) -> String? {
            try? client.store.queue.read { db in try String.fetchOne(db, sql: "SELECT text FROM messages WHERE message_id = ? AND has_mutable = 1", arguments: [id]) }
        }
        func deleted(_ client: Client, _ id: String) -> Bool {
            (try? client.store.queue.read { db in try Bool.fetchOne(db, sql: "SELECT deleted_at IS NOT NULL FROM messages WHERE message_id = ?", arguments: [id]) }) == true
        }

        let first = try a.service.post(a.key, channel: channel, root: nil, text: "**hello** from the owner", mentions: [])
        try await waitUntil("guest: the post", seconds: 30) { text(b, first) == "**hello** from the owner" }
        try await waitUntil("owner: confirmed") {
            (try? a.store.queue.read { db in try String.fetchOne(db, sql: "SELECT local_state FROM messages WHERE message_id = ?", arguments: [first]) }) == nil
        }
        let reply = try b.service.post(b.key, channel: channel, root: first, text: "a reply in the thread", mentions: [])
        try await waitUntil("owner: the reply", seconds: 30) { text(a, reply) == "a reply in the thread" }
        func rootOf(_ client: Client, _ id: String) -> String? {
            try? client.store.queue.read { db in try String.fetchOne(db, sql: "SELECT thread_root_id FROM messages WHERE message_id = ?", arguments: [id]) }
        }
        XCTAssertEqual(rootOf(a, reply), first)

        try a.service.change(a.key, messageId: first, text: "hello, edited", expectedRevision: 1)
        try await waitUntil("guest: the edit", seconds: 30) { text(b, first) == "hello, edited" }
        // A stale edit: opened on revision 1, saved after the revision moved on.
        try a.service.change(a.key, messageId: first, text: "too late", expectedRevision: 1)
        try await waitUntil("owner: the conflict") {
            (try? a.store.queue.read { db in try String.fetchOne(db, sql: "SELECT error FROM local_edits WHERE message_id = ?", arguments: [first]) }) == "revision_conflict"
        }
        XCTAssertEqual(text(a, first), "hello, edited")

        try a.service.change(a.key, messageId: first, text: nil, expectedRevision: 2)
        try await waitUntil("guest: deleted", seconds: 30) { deleted(b, first) }
        XCTAssertEqual(text(b, first), "")
        XCTAssertEqual(text(b, reply), "a reply in the thread", "replies stay")
    }

    /// F4 on the deployed server: a mention on one Mac is a notice — with
    /// nothing of what it is about — and the Dock's count on the other;
    /// reading the channel takes both back. Opt-in, `AGENTPAD_LIVE_F4=1`.
    func testAMentionIsToldAndReadAway() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_F4"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_F4=1") }
        var notices: [String] = []
        var takenBack = 0
        var shown: Set<String> = []
        let kept = (ChatNotifications.post, ChatNotifications.remove, ChatNotifications.badgeChanged, ChatNotifications.listIds)
        defer { (ChatNotifications.post, ChatNotifications.remove, ChatNotifications.badgeChanged, ChatNotifications.listIds) = kept }
        ChatNotifications.post = { id, title in notices.append(title); shown.insert(id) }
        ChatNotifications.remove = { ids, _ in takenBack += ids.count; shown.subtract(ids) }
        ChatNotifications.listIds = { Array(shown) }
        ChatNotifications.badgeChanged = {}
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "f4-\(mark)-a"), guestAddress = try live.email(id: "f4-\(mark)-b")
        let org = try createOrg(name: "E2E F4 \(mark)", owner: ownerAddress)
        let a = try await signIn(ownerAddress, org: org, name: "owner")
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: manages") { owner.manages && owner.view.channelsServed }
        try owner.invite(email: guestAddress, role: "member", teams: [])
        try await waitUntil("owner: the invitation is there") { owner.invitations.contains { $0.email == guestAddress } }
        let general = try XCTUnwrap(owner.myTeams.first(where: \.isGeneral))
        let channel = try owner.createChannel("ping-\(mark)", in: general)
        try await waitUntil("owner: the card") { owner.visibleChannel(channel) != nil }
        let b = try await signIn(guestAddress, org: org, name: "guest")
        let guest = try XCTUnwrap(ChatOrgModel.current(b.service))
        try await waitUntil("guest: the channel, followed") {
            guest.visibleChannel(channel) != nil && b.service.orgSessions[b.key]?.sync?.followedChannels.contains("channel:\(channel)") == true
        }
        try await waitUntil("owner: sees the guest") { owner.member(guest.me) != nil }
        _ = try a.service.post(a.key, channel: channel, root: nil, text: "@guest look", mentions: [guest.me])
        try await waitUntil("guest: told", seconds: 30) { notices == ["New mention in AgentPad"] }
        try await waitUntil("guest: the Dock's count") { ChatNotifications.mentionsForBadge(b.service) == 1 && guest.unread(channel)?.count == 1 }
        let reading = ChatChannelModel(key: b.key, channel: channel)
        reading.service = b.service
        reading.follow(b.store)
        try await waitUntil("feed") { !reading.feed.messages.isEmpty }
        reading.markRead()
        try await waitUntil("read away") { ChatNotifications.mentionsForBadge(b.service) == 0 && guest.unread(channel)?.count == 0 }
        XCTAssertGreaterThan(takenBack, 0)
    }
    /// F6: two channel participants, two explicit decisions, one transcript.
    /// The real production feed and queue reach a stand-in that checks argv.
    /// Checks the mechanism (the same UUID and --resume), not semantic model
    /// memory: F6Runner returns a fixed answer and never invokes Claude.
    func testTwoParticipantsContinueAChannelThread() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_F6"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_F6=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "f6-\(mark)-a"), memberAddress = try live.email(id: "f6-\(mark)-b")
        let org = try createOrg(name: "E2E F6 \(mark)", owner: ownerAddress)
        let runner = F6Runner(projects: root.appendingPathComponent("owner-claude-projects"))
        let a = try await signIn(ownerAddress, org: org, name: "owner", executor: runner)
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: channels and agents") { owner.manages && owner.agentsVisible }
        let teamName = "F6 team \(mark)"
        try owner.createTeam(teamName)
        try await waitUntil("owner: F6 team") { owner.teams.contains { $0.name == teamName } }
        try owner.join(try XCTUnwrap(owner.teams.first { $0.name == teamName }))
        try await waitUntil("owner: joined F6 team") { owner.myTeams.contains { $0.name == teamName } }
        let channelTeam = try XCTUnwrap(owner.myTeams.first { $0.name == teamName })
        try owner.invite(email: memberAddress, role: "member", teams: [channelTeam.teamId])
        try await waitUntil("owner: invitation") { owner.invitations.contains { $0.email == memberAddress } }
        let channel = try owner.createChannel("agent-\(mark)", in: channelTeam)
        try await waitUntil("owner: channel") { owner.visibleChannel(channel) != nil }
        let team = makeTeam("owner-team", service: a.service)
        team.calls.serverMode = true
        team.calls.publishing = a.service
        team.calls.useServer(a.store.calls, key: a.key)
        a.service.localAgent = { id in team.calls.agents.first { $0.id.uuidString.lowercased() == id } }
        a.service.onCallsChanged = { _ in team.calls.reload() }
        _ = ChatOwnerSide.install(service: a.service, calls: team.calls)
        let folder = root.appendingPathComponent("project-f6")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var agent = TeamPublishedAgent.fresh(serverMode: true)
        agent.name = "e2e-channel"
        agent.description = "F6 stand-in executor"
        agent.folder = folder.path
        try await team.calls.saveAndPublish([agent], teams: [channelTeam.teamId], key: a.key)
        let agentId = agent.id.uuidString.lowercased()
        let journal = try XCTUnwrap(a.service.journal)
        try await waitUntil("owner: published") { try journal.assignment(a.key, agentId: agentId)?.state == .active }
        try await waitUntil("owner: channel allows this agent") {
            guard let card = owner.visibleChannel(channel) else { return false }
            return owner.addableAgents(card).contains { $0.agentId == agentId }
        }
        try owner.addAgent(agentId, to: XCTUnwrap(owner.visibleChannel(channel)))
        try await waitUntil("owner: agent in channel") { owner.agents(in: channel).contains { $0.agentId == agentId } }
        let b = try await signIn(memberAddress, org: org, name: "member")
        let member = try XCTUnwrap(ChatOrgModel.current(b.service))
        try await waitUntil("member: channel agent") { member.agents(in: channel).contains { $0.agentId == agentId } }
        a.service.channelTab(ChannelRef(a.key, channel: channel), open: true)
        b.service.channelTab(ChannelRef(b.key, channel: channel), open: true)
        let reading = ChatChannelModel(key: b.key, channel: channel)
        reading.service = b.service
        reading.follow(b.store)
        let address = try XCTUnwrap(member.agents(in: channel).first { $0.agentId == agentId }?.address)
        // This scenario tests an explicit manual request. UX1 Send now
        // creates a request immediately; prepare its thread without invoking it.
        let question = "@\(address) please answer in this thread"
        let source = try b.service.post(b.key, channel: channel, root: nil, text: question, mentions: [])
        let offer = ChatChannelAsk.Offer(messageId: source, agentId: agentId, address: address, text: question, root: source)
        try await waitUntil("member: confirmed root") { reading.contextCandidates(root: offer.root).contains { $0.messageId == offer.root && ChatChannelAsk.eligible($0) } }
        let first = try b.service.askInChannel(b.key, channel: channel, agentId: agentId, root: offer.root,
                                               text: "Remember the first participant's request", context: reading.contextCandidates(root: offer.root))
        try await waitUntil("owner: first F6 decision", seconds: 60) {
            guard let request = try a.store.calls.request(first) else { return false }
            return a.service.channelDecisionReady(a.key, request: request)
        }
        XCTAssertTrue(runner.arguments.isEmpty)
        let firstProblem = await a.service.owner?.decideChannel(a.key, requestId: first, allow: true, reason: nil)
        XCTAssertNil(firstProblem)
        try await waitUntil("owner: first F6 result", seconds: 60) {
            a.service.channelPreview(a.key, requestId: first)?.resultText != nil
                && (try? a.store.calls.request(first))?.publication == "awaiting_publish"
        }
        let firstRun = try XCTUnwrap(a.service.channelPreview(a.key, requestId: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runner.transcript(firstRun.conversationId).path))
        _ = try a.service.publishChannelResult(a.key, requestId: first, publish: true)
        try await waitUntil("member: first published answer", seconds: 60) { (try? b.store.calls.request(first))?.publication == "published" }

        // The owner is also a participant of this channel, with a different
        // account from the first caller. Self-calls still require Allow.
        let second = try a.service.askInChannel(a.key, channel: channel, agentId: agentId, root: offer.root,
                                               text: "Continue the first participant's conversation", context: [])
        try await waitUntil("owner: second F6 decision", seconds: 60) {
            guard let request = try a.store.calls.request(second) else { return false }
            return a.service.channelDecisionReady(a.key, request: request)
        }
        XCTAssertEqual(runner.arguments.count, 1)
        XCTAssertNil(try journal.approval(a.key, requestId: second))
        XCTAssertEqual(try a.store.calls.request(first)?.initiatorAccountId, b.key.accountId)
        XCTAssertEqual(try a.store.calls.request(second)?.initiatorAccountId, a.key.accountId)
        let panel = ChatChannelOwnerModel(service: a.service, key: a.key, channel: channel)
        let terms = try XCTUnwrap(panel.decisionText(XCTUnwrap(a.store.calls.request(second))))
        XCTAssertTrue(terms.contains("remembers 1 earlier request") && terms.contains("may grow before the run starts"))
        let secondProblem = await a.service.owner?.decideChannel(a.key, requestId: second, allow: true, reason: nil)
        XCTAssertNil(secondProblem)
        try await waitUntil("owner: second F6 result", seconds: 60) {
            a.service.channelPreview(a.key, requestId: second)?.resultText != nil
                && (try? a.store.calls.request(second))?.publication == "awaiting_publish"
        }
        let secondRun = try XCTUnwrap(a.service.channelPreview(a.key, requestId: second))
        XCTAssertEqual(secondRun.conversationId, firstRun.conversationId)
        XCTAssertEqual(runner.arguments.count, 2)
        let args = try XCTUnwrap(runner.arguments.last)
        let resume = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(args[resume + 1], firstRun.conversationId)
        XCTAssertFalse(args.contains("--fork-session"))
        let transcript = try String(contentsOf: runner.transcript(firstRun.conversationId), encoding: .utf8)
        XCTAssertTrue(transcript.contains("Remember the first participant") && transcript.contains("Continue the first participant"))
        _ = try a.service.publishChannelResult(a.key, requestId: second, publish: true)
        try await waitUntil("member: both F6 answers in one thread", seconds: 60) {
            try b.store.queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE channel_id = ? AND thread_root_id = ? AND author_agent_id = ?",
                                 arguments: [channel, offer.root, agentId]) == 2
            }
        }
        XCTAssertTrue(try ChatTeamCallStore(calls: a.store.calls, key: a.key).loadLog().incoming.isEmpty)
    }

    /// F5 on production, a fresh organization per run; the executor is a
    /// stand-in. Uses the same model/buttons, queue, launcher and feed as the UI.
    func testAnAgentInAChannelWaitsForPublish() async throws {
        guard ProcessInfo.processInfo.environment["AGENTPAD_LIVE_F5"] == "1" else { throw XCTSkip("set AGENTPAD_LIVE_F5=1") }
        let mark = Self.runMark()
        let ownerAddress = try live.email(id: "f5-\(mark)-a"), memberAddress = try live.email(id: "f5-\(mark)-b")
        let org = try createOrg(name: "E2E F5 \(mark)", owner: ownerAddress)
        let runner = LiveRunner(real: false)
        let largeResult = String(repeating: "x", count: 131_072)
        runner.answer = largeResult
        let a = try await signIn(ownerAddress, org: org, name: "owner", executor: runner)
        let owner = try XCTUnwrap(ChatOrgModel.current(a.service))
        try await waitUntil("owner: channels and agents") { owner.manages && owner.agentsVisible }
        let teamName = "F5 team \(mark)"
        try owner.createTeam(teamName)
        try await waitUntil("owner: F5 team") { owner.teams.contains { $0.name == teamName } }
        try owner.join(try XCTUnwrap(owner.teams.first { $0.name == teamName }))
        try await waitUntil("owner: joined F5 team") { owner.myTeams.contains { $0.name == teamName } }
        let channelTeam = try XCTUnwrap(owner.myTeams.first { $0.name == teamName })
        try owner.invite(email: memberAddress, role: "member", teams: [channelTeam.teamId])
        try await waitUntil("owner: invitation") { owner.invitations.contains { $0.email == memberAddress } }
        let channel = try owner.createChannel("agent-\(mark)", in: channelTeam)
        try await waitUntil("owner: channel") { owner.visibleChannel(channel) != nil }
        let team = makeTeam("owner-team", service: a.service)
        team.calls.serverMode = true
        team.calls.publishing = a.service
        team.calls.useServer(a.store.calls, key: a.key)
        a.service.localAgent = { id in team.calls.agents.first { $0.id.uuidString.lowercased() == id } }
        a.service.onCallsChanged = { _ in team.calls.reload() }
        _ = ChatOwnerSide.install(service: a.service, calls: team.calls)
        let folder = root.appendingPathComponent("project-f5")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var agent = TeamPublishedAgent.fresh(serverMode: true)
        agent.name = "e2e-channel"
        agent.description = "F5 stand-in executor"
        agent.folder = folder.path
        try await team.calls.saveAndPublish([agent], teams: [channelTeam.teamId], key: a.key)
        let agentId = agent.id.uuidString.lowercased()
        let journal = try XCTUnwrap(a.service.journal)
        try await waitUntil("owner: published") { try journal.assignment(a.key, agentId: agentId)?.state == .active }
        try await waitUntil("owner: channel allows this agent") {
            guard let card = owner.visibleChannel(channel) else { return false }
            return owner.addableAgents(card).contains { $0.agentId == agentId }
        }
        try owner.addAgent(agentId, to: XCTUnwrap(owner.visibleChannel(channel)))
        try await waitUntil("owner: agent in channel") { owner.agents(in: channel).contains { $0.agentId == agentId } }
        let b = try await signIn(memberAddress, org: org, name: "member")
        let member = try XCTUnwrap(ChatOrgModel.current(b.service))
        try await waitUntil("member: channel agent") { member.agents(in: channel).contains { $0.agentId == agentId } }
        a.service.channelTab(ChannelRef(a.key, channel: channel), open: true)
        b.service.channelTab(ChannelRef(b.key, channel: channel), open: true)
        let reading = ChatChannelModel(key: b.key, channel: channel)
        reading.service = b.service
        reading.follow(b.store)
        let address = try XCTUnwrap(member.agents(in: channel).first { $0.agentId == agentId }?.address)
        // This scenario tests an explicit manual request. UX1 Send now
        // creates a request immediately; prepare its thread without invoking it.
        let question = "@\(address) please answer in this thread"
        let source = try b.service.post(b.key, channel: channel, root: nil, text: question, mentions: [])
        let offer = ChatChannelAsk.Offer(messageId: source, agentId: agentId, address: address, text: question, root: source)
        try await waitUntil("member: confirmed root") { reading.contextCandidates(root: offer.root).contains { $0.messageId == offer.root && ChatChannelAsk.eligible($0) } }
        let deletedText = "F5 context removed before Allow"
        let extra = try b.service.post(b.key, channel: channel, root: offer.root, text: deletedText, mentions: [])
        try await waitUntil("member: extra context") { reading.contextCandidates(root: offer.root).contains { $0.messageId == extra && ChatChannelAsk.eligible($0) } }
        var context = reading.contextCandidates(root: offer.root)
        XCTAssertNil(reading.ask(offer, text: "Answer the channel request", context: context, agents: member.agents(in: channel)))
        try await waitUntil("owner: decision and context", seconds: 60) {
            try a.store.calls.requests().contains { $0.kind == "channel" && $0.state == .awaitingDecision && a.service.channelDecisionReady(a.key, request: $0) }
        }
        let request = try XCTUnwrap(a.store.calls.requests().first { $0.kind == "channel" })
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertTrue(try ChatTeamCallStore(calls: a.store.calls, key: a.key).loadCall(request.requestId).incoming.isEmpty)
        try b.service.change(b.key, messageId: extra, text: nil, expectedRevision: 1)
        try await waitUntil("owner: context deletion") {
            guard a.transport.events.contains(where: { $0.type == "message.delete" && $0.stream == "channel:\(channel)" }) else { return false }
            return try a.store.queue.read { try ChatChannelContent.read($0, request: request.requestId) == nil }
        }
        let allowProblem = await a.service.owner?.decideChannel(a.key, requestId: request.requestId, allow: true, reason: nil)
        XCTAssertNil(allowProblem)
        try await waitUntil("owner: local preview", seconds: 60) {
            a.service.channelPreview(a.key, requestId: request.requestId)?.resultText == largeResult
                && (try? a.store.calls.request(request.requestId))?.publication == "awaiting_publish"
        }
        func agentMessages() throws -> [Row] {
            try b.store.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM messages WHERE channel_id = ? AND author_agent_id = ?", arguments: [channel, agentId]) }
        }
        XCTAssertTrue(try agentMessages().isEmpty, "no automatic publication")
        XCTAssertFalse(try journal.commands(for: a.key).contains { $0.type == "result.deliver" })
        let panel = ChatChannelOwnerModel(service: a.service, key: a.key, channel: channel)
        let preview = try XCTUnwrap(panel.publicationText(request.requestId))
        XCTAssertTrue(preview.contains("…(truncated, "))
        let publication = try a.service.publishChannelResult(a.key, requestId: request.requestId, publish: true)
        XCTAssertLessThanOrEqual(publication.bodyBytes.count, 131_072)
        XCTAssertEqual(try JSONDecoder().decode(ChatCommandEnvelope.self, from: publication.bodyBytes).args["text"]?.string, preview)
        let repeated = try a.service.publishChannelResult(a.key, requestId: request.requestId, publish: true)
        XCTAssertEqual(publication.commandId, repeated.commandId)
        try await waitUntil("member: one agent answer in the original thread", seconds: 60) {
            let rows = try agentMessages()
            return rows.count == 1 && (rows[0]["text"] as String) == preview
                && (rows[0]["thread_root_id"] as String?) == offer.root
        }
        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertFalse(runner.requests[0].prompt.contains(deletedText))
        let received = try XCTUnwrap(agentMessages().first)
        XCTAssertEqual(received["author_account_id"] as String, a.key.accountId)
        XCTAssertNotNil(received["run_id"] as String?)
        context = context.filter { $0.messageId != extra }

        func ask(_ text: String) throws -> String {
            try b.service.askInChannel(b.key, channel: channel, agentId: agentId, root: offer.root, text: text, context: context)
        }
        let declined = try ask("Decline this request")
        try await waitUntil("owner: second decision", seconds: 60) { (try? a.store.calls.request(declined))?.state == .awaitingDecision }
        try await waitUntil("owner: second context") {
            guard let request = try a.store.calls.request(declined) else { return false }
            return a.service.channelDecisionReady(a.key, request: request)
        }
        let declineProblem = await a.service.owner?.decideChannel(a.key, requestId: declined, allow: false, reason: "not today")
        XCTAssertNil(declineProblem)
        try await waitUntil("member: declined") { (try? b.store.calls.request(declined))?.state == .declined }
        let cancelled = try ask("Cancel this request")
        try await waitUntil("member: cancellable") { (try? b.store.calls.request(cancelled))?.hasFixed == true }
        XCTAssertNil(b.service.cancelChannelRequest(b.key, requestId: cancelled))
        try await waitUntil("owner: cancelled") { (try? a.store.calls.request(cancelled))?.state == .cancelled }
        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertEqual(try agentMessages().count, 1)

        let draft = try ask("Keep this result private, then revoke access")
        try await waitUntil("owner: private request decision") { (try? a.store.calls.request(draft))?.state == .awaitingDecision }
        let draftProblem = await a.service.owner?.decideChannel(a.key, requestId: draft, allow: true, reason: nil)
        XCTAssertNil(draftProblem)
        try await waitUntil("owner: private result") { a.service.channelPreview(a.key, requestId: draft)?.resultText != nil }
        let draftRun = try XCTUnwrap(a.service.channelPreview(a.key, requestId: draft))
        let projects = a.service.claudeProjectsRoot
        let transcriptFolder = projects.appendingPathComponent("-f5-fixture")
        try FileManager.default.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
        let transcript = transcriptFolder.appendingPathComponent("\(draftRun.conversationId).jsonl")
        let neighbor = transcriptFolder.appendingPathComponent("\(UUID().uuidString).jsonl")
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": transcriptFolder.path, "message": ["content": "F5 fixture context"]]) + Data("\n".utf8)
        try bytes.write(to: transcript)
        try bytes.write(to: neighbor)
        let visibility = ChannelConversationFilter.current(journalURL: journal.url)
        XCTAssertNil(AgentSessionScanner.findRecord(agentId: AgentTemplate.claudeCodeID, conversationId: draftRun.conversationId, root: projects, visibility: visibility))
        XCTAssertEqual(WorkspaceStore.resumeRefusal(agentId: AgentTemplate.claudeCodeID, conversationId: draftRun.conversationId, options: { _ in nil }, visibility: visibility), .channelConversation)

        runner.gated = true
        let running = try ask("Cancel after Allow")
        try await waitUntil("owner: running request decision") { (try? a.store.calls.request(running))?.state == .awaitingDecision }
        let runningProblem = await a.service.owner?.decideChannel(a.key, requestId: running, allow: true, reason: nil)
        XCTAssertNil(runningProblem)
        try await waitUntil("member: running") { (try? b.store.calls.request(running))?.state == .running }
        let memberPanel = ChatChannelOwnerModel(service: b.service, key: b.key, channel: channel)
        let runningRequest = try XCTUnwrap(b.store.calls.request(running))
        XCTAssertTrue(memberPanel.canCancel(runningRequest))
        XCTAssertNil(memberPanel.cancel(runningRequest))
        try await waitUntil("member: running cancellation ended", seconds: 60) {
            (try? b.store.calls.request(running))?.state.isFinal == true
        }
        XCTAssertEqual(a.service.launcher?.live.isEmpty, true)
        XCTAssertEqual(runner.requests.count, 3)
        XCTAssertEqual(try agentMessages().count, 1)

        try owner.leave(try XCTUnwrap(owner.myTeams.first { $0.teamId == channelTeam.teamId }))
        try await waitUntil("owner: revoked transcript and draft erased") {
            try journal.run(draftRun.runId)?.resultErased == true && !FileManager.default.fileExists(atPath: transcript.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        XCTAssertNil(try journal.run(draftRun.runId)?.resultText)
        XCTAssertNil(a.service.channelPreview(a.key, requestId: draft))
        XCTAssertFalse(ChannelConversationFilter.current(journalURL: journal.url).allows(conversationId: draftRun.conversationId))
    }

}
