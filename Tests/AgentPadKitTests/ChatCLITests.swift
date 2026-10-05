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
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        ChatConnectWindow.answerConfirmation = nil
        ChatConnectWindow.disconnectCall = { await $0.disconnect(expecting: $1) }
        ChatConnectWindow.now = { Date() }
        ChatCLI.openConnectWindow = { ChatConnectWindow.show() }
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

    func testLoginOpensTheWindowInAnyState() {
        var opened = 0
        ChatCLI.openConnectWindow = { opened += 1 }
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

    /// C7 review p2-1: the key window may be another's open sheet: the
    /// confirmation's host is its parent, which has that sheet — busy.
    func testTheHostOfAnOpenSheetIsItsParent() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        parent.beginSheet(sheet, completionHandler: nil)
        let deadline = Date().addingTimeInterval(2)
        while sheet.sheetParent == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ChatConnectWindow.host(for: sheet) === parent)
        XCTAssertNotNil(ChatConnectWindow.host(for: sheet).attachedSheet, "so the confirmation answers busy")
        XCTAssertTrue(ChatConnectWindow.host(for: parent) === parent)
        parent.endSheet(sheet)
    }

    func testLogoutOutcomes() async throws {
        let (service, _) = try signedIn()
        var disconnected: [ChatConnection] = []
        ChatConnectWindow.disconnectCall = { disconnected.append($1); return .done }

        ChatConnectWindow.answerConfirmation = { .alertFirstButtonReturn }
        let answer1 = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(answer1).outcome, "disconnected")
        XCTAssertEqual(disconnected, [connection])

        ChatConnectWindow.answerConfirmation = { .alertSecondButtonReturn }
        let answer2 = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(answer2).outcome, "cancelled")

        ChatConnectWindow.disconnectCall = { _, _ in .notFinished("Disconnect could not finish: x. Try Disconnect again.") }
        ChatConnectWindow.answerConfirmation = { .alertFirstButtonReturn }
        let unfinished = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(unfinished).outcome, "not_finished")
        XCTAssertEqual(unfinished.error, "Disconnect could not finish: x. Try Disconnect again.")

        let off = ChatService(files: ChatFiles(directory: root.appendingPathComponent("off")), tokens: FakeTokenStore())
        let answer3 = await ChatCLI.logout(off, isCallerWaiting: { true })
        XCTAssertEqual(info(answer3).outcome, "not_connected")
        XCTAssertEqual(disconnected.count, 1)
    }

    /// The press decides: past the deadline, the caller gone or another
    /// connection by then — no Disconnect, whatever the watchman did not
    /// close yet (DESIGN-C7, amendment 1).
    func testThePressChecksDeadlineCallerAndConnection() async throws {
        let (service, _) = try signedIn()
        var calls = 0
        ChatConnectWindow.disconnectCall = { _, _ in calls += 1; return .done }
        let start = Date()
        // Pressed after the deadline.
        ChatConnectWindow.now = { start.addingTimeInterval(46) }
        ChatConnectWindow.answerConfirmation = { .alertFirstButtonReturn }
        let answer4 = await ChatCLI.logout(service, isCallerWaiting: { true }, now: start)
        XCTAssertEqual(info(answer4).outcome, "no_answer")
        ChatConnectWindow.now = { Date() }
        // Pressed once the caller left: nobody to answer, nothing done.
        _ = await ChatCLI.logout(service, isCallerWaiting: { false })
        // Pressed after another sign-in.
        ChatConnectWindow.answerConfirmation = {
            try? service.saveSignIn(ChatConnection(server: self.server, accountId: self.anna, sessionId: "s2", deviceName: "Mac",
                                                   orgId: self.org), token: "aps_u")
            return .alertFirstButtonReturn
        }
        let answer5 = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(answer5).outcome, "stale")
        XCTAssertEqual(calls, 0)
    }

    /// One at a time, held until the core's call ends; an answer due before
    /// the end says `started`, the Disconnect going on.
    func testOneLogoutAtATimeAndStarted() async throws {
        let (service, _) = try signedIn()
        let gate = AsyncGate()
        var ended = false
        ChatConnectWindow.answerConfirmation = { .alertFirstButtonReturn }
        ChatConnectWindow.disconnectCall = { _, _ in await gate.wait(); ended = true; return .done }
        let first = await ChatConnectWindow.confirmAndDisconnect(expecting: connection, service: service, answerBy: Date().addingTimeInterval(0.2))
        XCTAssertEqual(first, .started)
        XCTAssertFalse(ended)
        let answer6 = await ChatCLI.logout(service, isCallerWaiting: { true })
        XCTAssertEqual(info(answer6).outcome, "busy")
        await gate.open()
        let deadline = Date().addingTimeInterval(5)
        while ChatConnectWindow.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(ChatConnectWindow.busy)
        XCTAssertTrue(ended)
    }
}
