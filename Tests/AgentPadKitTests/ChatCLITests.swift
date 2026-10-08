import AgentPadHookKit
import AppKit
import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// `agentpad-cli team status|login|logout|members|invite` in the app
/// (docs/agentpad/DESIGN-C7.md): each in each state of the connection, as the
/// organization's window would have it.
@MainActor
final class ChatCLITests: XCTestCase {
    private var root: URL!
    private var tabs: ConnectionTabs!
    private var workspace: WorkspaceStore!
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let anna = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    private let boris = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private var server: ChatServerAddress { try! ChatServerAddress(parsing: "https://chat.example.com") }
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: anna, orgId: org) }
    private var connection: ChatConnection {
        ChatConnection(server: server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org)
    }

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-cli-\(UUID().uuidString)")
        workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: {
            XCTFail("Connection must not create a terminal"); return TestEngine()
        })
        let router = TabRouter(), store = workspace!
        router.stores = { [store] }; router.ensureHost = { store }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        tabs = ConnectionTabs(navigation: navigation)
        ChatCLI.connectionTabs = tabs
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        workspace.terminate(); workspace = nil
        ChatCLI.connectionTabs = .shared
        ChatCLI.openConnection = { ConnectionTabs.shared.show() }
        tabs = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// A service signed in to the organization; `role` and its teams as a
    /// snapshot of this session has them (rights confirmed), unless `confirmed` is false.
    private func signedIn(role: String = "admin", confirmed: Bool = true) throws -> (ChatService, ChatStore) {
        let service = ChatService(files: ChatFiles(directory: root.appendingPathComponent(UUID().uuidString)), tokens: FakeTokenStore())
        try service.saveSignIn(connection, token: "aps_t")
        let store = try XCTUnwrap(service.session(for: key).store)
        var cursors = ["org:\(org)": 1, "team:g": 1, "member:\(org):\(anna)": 1]
        if ChatOrgView.manages(role) { cursors["org-admin:\(org)"] = 1 }
        try store.apply(ChatSnapshot(cursors: cursors, orgName: "Rabbitshat",
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: role),
                                               .init(accountId: boris, handle: "boris", name: "Boris", role: "member")],
                                     teams: [.init(teamId: "g", name: "General", isGeneral: true),
                                             .init(teamId: "ops", name: "Ops", mine: false),
                                             .init(teamId: "old", name: "Old", archivedAt: "2026-10-01T00:00:00Z", mine: false),
                                             .init(teamId: "d1", name: "Design", mine: false), .init(teamId: "d2", name: "design", mine: false)],
                                     teamMembers: [.init(teamId: "g", accountId: anna), .init(teamId: "g", accountId: boris),
                                                   .init(teamId: "ops", accountId: boris)]),
                        confirmsRights: confirmed ? "s1" : nil)
        return (service, store)
    }

    private func info(_ answer: ChatCLI.Answer) -> AgentPadCLITeamInfo {
        var info = AgentPadCLITeamInfo(status: "server", detail: nil)
        answer.fill(&info)
        return info
    }

    private func queued(_ store: ChatStore) throws -> [ChatCommandRecord] { try store.outbox.commands() }

    // MARK: status, login

    func testStatusSaysEveryState() throws {
        // Off.
        let off = ChatService(files: ChatFiles(directory: root.appendingPathComponent("off")), tokens: FakeTokenStore())
        var info = AgentPadCLITeamInfo(status: "off", detail: nil)
        ChatCLI.status(off)(&info)
        XCTAssertEqual(info.connection, "off")
        XCTAssertNil(info.org)
        // Signed in, rights confirmed.
        let (service, _) = try signedIn()
        info = AgentPadCLITeamInfo(status: "server", detail: nil)
        ChatCLI.status(service)(&info)
        XCTAssertEqual(info.server, server.description)
        XCTAssertEqual(info.org, "Rabbitshat")
        XCTAssertEqual(info.account, "Anna @anna")
        XCTAssertEqual(info.connection, "connecting")
        XCTAssertNil(info.rightsInDoubt)
        // Closed by the server, or the record unreadable: the core's text, in problems too.
        service.sessionEnded("The server closed this session. Sign in again.")
        info = AgentPadCLITeamInfo(status: "server", detail: nil)
        ChatCLI.status(service)(&info)
        XCTAssertEqual(info.connection, "closed")
        XCTAssertEqual(info.detail, "The server closed this session. Sign in again.")
        XCTAssertTrue(info.problems?.contains("The server closed this session. Sign in again.") == true)
        // Not a member: the core's text about this organization.
        try service.saveSignIn(connection, token: "aps_t")
        service.membershipLost(key)
        info = AgentPadCLITeamInfo(status: "server", detail: nil)
        ChatCLI.status(service)(&info)
        XCTAssertEqual(info.connection, "not a member")
        XCTAssertEqual(info.detail, "You are no longer a member of Rabbitshat.")
    }

    /// The send queue stopped on storage: `status` says it, as the window does.
    func testStatusSaysTheQueueStopped() async throws {
        let (service, store) = try signedIn()
        let session = try XCTUnwrap(service.orgSessions[key])
        session.startSending(api: ChatAPI(server: server), token: "aps_t", sessionId: "s1", journal: nil) {}
        // Allowed to send, the queue cannot read its table: it stops on storage.
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE outbox RENAME TO outbox_away") }
        session.outbox?.allow(connection: 1, generation: "g1")
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE outbox_away RENAME TO outbox") }
        var info = AgentPadCLITeamInfo(status: "server", detail: nil)
        ChatCLI.status(service)(&info)
        XCTAssertTrue(info.problems?.contains { $0.hasPrefix("Changes cannot be saved on this Mac") } == true, "\(info.problems ?? [])")
    }

    func testLoginOpensTheConnectionTabInAnyState() {
        var opened = 0
        ChatCLI.openConnection = { opened += 1 }
        let answer = ChatCLI.login()
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(info(answer).outcome, "opened")
        XCTAssertEqual(opened, 1)
    }

    // MARK: members

    func testMembersAreWhatTheWindowShows() throws {
        let (admin, _) = try signedIn(role: "admin")
        let all = info(ChatCLI.members(admin))
        XCTAssertEqual(all.outcome, "members")
        XCTAssertNotNil(all.detail)
        XCTAssertEqual(all.members?.map(\.name), ["Anna", "Boris"])
        XCTAssertEqual(all.members?.first?.you, true)
        XCTAssertEqual(Set(all.teams?.map(\.name) ?? []), ["General", "Ops", "Old", "Design", "design"])
        XCTAssertEqual(all.teams?.first { $0.name == "Ops" }?.members, ["Boris"])

        let (member, _) = try signedIn(role: "member")
        XCTAssertEqual(info(ChatCLI.members(member)).teams?.map(\.name), ["General"], "a member's own teams only")

        // In doubt: the user's own name only, no team.
        let (doubting, _) = try signedIn(role: "admin", confirmed: false)
        let doubt = info(ChatCLI.members(doubting))
        XCTAssertEqual(doubt.members?.map(\.name), ["Anna"])
        XCTAssertEqual(doubt.teams, [])
        XCTAssertEqual(doubt.rightsInDoubt, true)

        // A storage problem: nothing, refused.
        let (troubled, _) = try signedIn()
        troubled.orgSessions[key]?.doubtNotWritten = true
        troubled.orgSessions[key]?.doubtWriteFailures += 1
        let answer = ChatCLI.members(troubled)
        XCTAssertFalse(answer.ok)
        XCTAssertEqual(info(answer).outcome, "unavailable")
        XCTAssertNil(info(answer).members)
    }

    func testMembersAndInviteNeedTheOrganization() throws {
        let off = ChatService(files: ChatFiles(directory: root.appendingPathComponent("off")), tokens: FakeTokenStore())
        XCTAssertEqual(info(ChatCLI.members(off)).outcome, "not_connected")
        XCTAssertEqual(ChatCLI.members(off).error, "not connected to a server")
        let (service, _) = try signedIn()
        service.sessionEnded("The server closed this session. Sign in again.")
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: [], service)).outcome, "closed")
        try service.saveSignIn(connection, token: "aps_t")
        service.membershipLost(key)
        let notMember = ChatCLI.members(service)
        XCTAssertEqual(info(notMember).outcome, "not_member")
        XCTAssertEqual(notMember.error, "You are no longer a member of Rabbitshat.")
    }

    // MARK: invite

    func testInviteQueuesWhatTheButtonWould() throws {
        let (service, store) = try signedIn(role: "admin")
        let answer = ChatCLI.invite(email: "c@example.com", role: "admin", teams: ["ops"], service)
        XCTAssertTrue(answer.ok, answer.error ?? "")
        XCTAssertEqual(info(answer).outcome, "queued")
        let record = try XCTUnwrap(try queued(store).last)
        XCTAssertEqual(record.type, "invitation.create")
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes)
        XCTAssertEqual(envelope.args, .object(["email": .string("c@example.com"), "role": .string("admin"), "team_ids": .array([.string("ops")])]))
    }

    func testInviteIsRefusedBeforeTheQueue() async throws {
        let (member, memberStore) = try signedIn(role: "member")
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: [], member)).outcome, "forbidden")
        XCTAssertEqual(try queued(memberStore), [])

        let (doubting, doubtStore) = try signedIn(role: "admin", confirmed: false)
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: [], doubting)).outcome, "rights_in_doubt")
        XCTAssertEqual(try queued(doubtStore), [])

        let (admin, store) = try signedIn(role: "admin")
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: ["Nope"], admin)).outcome, "unknown_team")
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: ["Old"], admin)).outcome, "archived_team")
        XCTAssertEqual(info(ChatCLI.invite(email: "c@example.com", role: nil, teams: ["DESIGN"], admin)).outcome, "ambiguous_team")
        XCTAssertEqual(try queued(store), [])

        // The queue cannot take it: nothing queued, said so.
        try await store.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER no_queue BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        let failed = ChatCLI.invite(email: "c@example.com", role: nil, teams: [], admin)
        XCTAssertEqual(info(failed).outcome, "not_queued")
        try await store.queue.write { db in try db.execute(sql: "DROP TRIGGER no_queue") }
        XCTAssertEqual(try queued(store), [])
    }

    // MARK: logout

    private func decision(_ work: @escaping @MainActor () async -> ChatCLI.Answer,
                          press: (ConfirmationCoordinator) -> Void) async throws -> ChatCLI.Answer {
        var answer: ChatCLI.Answer?
        let task = Task { @MainActor in answer = await work() }
        let until = Date().addingTimeInterval(3)
        while workspace.allSessions.first?.tabState?.confirmation.isAwaiting != true, Date() < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        let coordinator = try XCTUnwrap(workspace.allSessions.first?.tabState?.confirmation)
        XCTAssertTrue(coordinator.isAwaiting)
        coordinator.canShow = { true }
        coordinator.shown(true)
        press(coordinator)
        await task.value
        return try XCTUnwrap(answer)
    }

    func testLogoutOutcomes() async throws {
        let (service, _) = try signedIn()
        var disconnected: [ChatConnection] = []
        tabs.disconnectCall = { disconnected.append($1); return .done }
        let answer1 = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { true }) }) { $0.confirm() }
        XCTAssertEqual(info(answer1).outcome, "disconnected")
        XCTAssertEqual(disconnected, [connection])

        let answer2 = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { true }) }) { $0.cancel() }
        XCTAssertEqual(info(answer2).outcome, "cancelled")

        tabs.disconnectCall = { _, _ in .notFinished("Disconnect could not finish: x. Try Disconnect again.") }
        let unfinished = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { true }) }) { $0.confirm() }
        XCTAssertEqual(info(unfinished).outcome, "not_finished")
        XCTAssertEqual(unfinished.error, "Disconnect could not finish: x. Try Disconnect again.")
        guard case .failed = workspace.allSessions.first?.tabState?.confirmation.phase else { return XCTFail("missing inline error") }

        let off = ChatService(files: ChatFiles(directory: root.appendingPathComponent("off")), tokens: FakeTokenStore())
        let answer3 = await ChatCLI.logout(off, isCallerWaiting: { true })
        XCTAssertEqual(info(answer3).outcome, "not_connected")
        XCTAssertEqual(disconnected.count, 1)
    }

    func testThePressChecksDeadlineCallerAndConnection() async throws {
        let (service, _) = try signedIn()
        var calls = 0, clock = Date(), waiting = true
        tabs.disconnectCall = { _, _ in calls += 1; return .done }
        tabs.now = { clock }
        let start = clock
        let expired = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { true }, now: start) }) {
            clock = start.addingTimeInterval(46); $0.confirm()
        }
        XCTAssertEqual(info(expired).outcome, "no_answer")
        clock = Date()
        let gone = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { waiting }) }) {
            waiting = false; $0.confirm()
        }
        XCTAssertEqual(info(gone).outcome, "cancelled")
        let changed = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { true }) }) {
            try? service.saveSignIn(ChatConnection(server: self.server, accountId: self.anna, sessionId: "s2", deviceName: "Mac",
                                                   orgId: self.org), token: "aps_u")
            $0.confirm()
        }
        XCTAssertEqual(info(changed).outcome, "stale")
        XCTAssertEqual(calls, 0)
    }

    func testCallerDisappearingEndsAnUnansweredDecision() async throws {
        let (service, _) = try signedIn()
        var waiting = true
        tabs.disconnectCall = { _, _ in XCTFail("caller gone"); return .done }
        let gone = try await decision({ await ChatCLI.logout(service, isCallerWaiting: { waiting }) }) { _ in waiting = false }
        XCTAssertEqual(info(gone).outcome, "cancelled")
        XCTAssertFalse(tabs.busy)
    }

    func testOneLogoutAtATimeAndStarted() async throws {
        let (service, _) = try signedIn()
        let gate = AsyncGate()
        var ended = false
        tabs.disconnectCall = { _, _ in await gate.wait(); ended = true; return .done }
        let first = Task { await self.tabs.confirmAndDisconnect(expecting: self.connection, service: service, answerBy: Date().addingTimeInterval(0.1)) }
        let until = Date().addingTimeInterval(3)
        while workspace.allSessions.first?.tabState?.confirmation.isAwaiting != true, Date() < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        let c = try XCTUnwrap(workspace.allSessions.first?.tabState?.confirmation)
        c.canShow = { true }; c.shown(true); c.confirm(); c.confirm()
        let started = await first.value
        XCTAssertEqual(started, .started)
        XCTAssertFalse(ended)
        let answer = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(answer).outcome, "busy")
        // Already sent work survives closing the tab; consent itself cannot be reused.
        workspace.closeTab(workspace.allSessions[0], in: workspace.active!)
        XCTAssertTrue(tabs.busy)
        await gate.open()
        while tabs.busy, Date() < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(tabs.busy)
        XCTAssertTrue(ended)
    }

    func testNoHostAndCompetingDecisionAreBusyWithoutDisconnect() async throws {
        let (service, _) = try signedIn()
        tabs.disconnectCall = { _, _ in XCTFail("no consent"); return .done }
        tabs.navigation.router.ensureHost = { nil }
        let noHost = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(noHost).outcome, "busy")
        tabs.navigation.router.ensureHost = { self.workspace }
        let state = try XCTUnwrap(tabs.show()?.tabState)
        state.confirmation.request(.init(tabID: UUID(), targetID: "other"), title: "Other", consequences: "", verb: "Apply", stillValid: { true }, operation: {})
        let other = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(other).outcome, "busy")
        state.confirmation.cancel()
    }
}
