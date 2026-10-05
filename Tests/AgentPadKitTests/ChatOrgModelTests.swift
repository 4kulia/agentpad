import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// The organization window and panel (docs/agentpad/CHAT-PLAN.md C6): what
/// each role may do — as the server decides it —, what the cache keeps of
/// teams, the commands the window sends, and the model's life.
@MainActor
final class ChatOrgModelTests: XCTestCase {
    private var root: URL!
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let anna = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    private let boris = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private let vera = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
    private var sent: [(type: String, args: ChatJSON)] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-org-\(UUID().uuidString)")
        sent = []
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var key: ChatOrgKey {
        ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: anna, orgId: org)
    }

    private func open(_ name: String = "c") throws -> ChatStore {
        try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent(name)), key: key).store
    }

    private func event(_ stream: String, _ seq: Int, _ type: String, _ body: [String: String]) -> ChatEvent {
        ChatEvent(stream: stream, seq: seq, id: UUID().uuidString, type: type, actor: nil,
                  body: .object(body.mapValues { .string($0) }), commandId: nil, at: "2026-10-04T18:20:00Z")
    }

    private func member(_ id: String, _ role: String) -> ChatOrgView.Member {
        .init(accountId: id, handle: id.prefix(4).description, name: id.prefix(4).description, role: role)
    }

    private func team(_ id: String, mine: Bool, general: Bool = false, archived: Bool = false, members: [String] = []) -> ChatOrgView.Team {
        .init(teamId: id, name: id, isGeneral: general, archived: archived, mine: mine, members: members)
    }

    /// A model of anna with `role` (boris an owner, vera a member, unless
    /// `members` says otherwise), whose commands are recorded. A manager
    /// follows the admin stream, as after its snapshot.
    private func model(role: String, members: [ChatOrgView.Member]? = nil, teams: [ChatOrgView.Team] = [],
                       invitations: [ChatSnapshot.Invitation] = []) -> ChatOrgModel {
        let model = ChatOrgModel(me: anna) { [unowned self] type, args in
            sent.append((type, args))
            return "c\(sent.count)"
        }
        model.set(ChatOrgView(orgName: "Rabbitshat",
                              members: members ?? [member(anna, role), member(boris, "owner"), member(vera, "member")],
                              teams: teams, invitations: invitations, followsAdmin: ChatOrgView.manages(role)))
        return model
    }

    private func teams(_ store: ChatStore) throws -> [String: Bool] {
        try store.queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT team_id, mine FROM teams").map { ($0["team_id"], $0["mine"]) })
        }
    }

    private func count(_ store: ChatStore, _ sql: String) throws -> Int {
        try store.queue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    // MARK: Rights, as the server has them (review C6 group B)

    func testActionsOfEachRoleAreTheA5Table() {
        let managing: Set<ChatOrgAction> = [.seeAllTeams, .invite, .revokeInvitation, .createTeam, .renameTeam, .archiveTeam,
                                            .addTeamMember, .removeTeamMember, .joinTeam, .setRole, .removeMember, .seeAudit]
        let everyone: Set<ChatOrgAction> = [.seeMembers, .seeOwnTeams, .seeDevices, .closeSession, .leaveTeam, .setOwnName]
        XCTAssertEqual(ChatOrgAction.allowed(for: "owner"), everyone.union(managing))
        XCTAssertEqual(ChatOrgAction.allowed(for: "admin"), everyone.union(managing))
        XCTAssertEqual(ChatOrgAction.allowed(for: "member"), everyone)
        XCTAssertEqual(model(role: "owner").actions, everyone.union(managing))
        XCTAssertEqual(model(role: "member").actions, everyone)
    }

    /// Each row: the caller's role, the case, and what the server answers —
    /// read off its code, not the client's: `teams.rs` (team.*) and
    /// `member_set_role`, `member_remove` in migration 0023; invitations by
    /// `api.md`. Allowed means the server would run it.
    func testEveryCommandIsAllowedExactlyWhenTheServerRunsIt() throws {
        let g = team("g", mine: true, general: true, members: [anna, boris, vera])
        let ops = team("ops", mine: true, members: [anna, vera])
        let x = team("x", mine: false, members: [boris])
        let old = team("old", mine: true, archived: true, members: [anna, vera])
        let gone = team("gone", mine: false, archived: true, members: [boris])
        let all = [g, ops, x, old, gone]
        let invitation = ChatSnapshot.Invitation(invitationId: "i1", email: "a@example.com", role: "member", state: "open")
        func m(_ role: String, _ members: [ChatOrgView.Member]? = nil) -> ChatOrgModel {
            model(role: role, members: members, teams: all, invitations: [invitation])
        }
        let soleOwner = [member(anna, "owner"), member(boris, "admin"), member(vera, "member")]
        let twoOwners = [member(anna, "owner"), member(boris, "owner"), member(vera, "member")]
        typealias Row = (String, String, ChatOrgModel, Bool, (ChatOrgModel) throws -> Void)
        let rows: [Row] = [
            // team.create: managers.
            ("owner", "create", m("owner"), true, { try $0.createTeam("N") }),
            ("admin", "create", m("admin"), true, { try $0.createTeam("N") }),
            ("member", "create", m("member"), false, { try $0.createTeam("N") }),
            // team.rename / team.archive: managers; not General, not archived.
            ("admin", "rename ops", m("admin"), true, { try $0.renameTeam(ops, to: "N") }),
            ("admin", "rename x (not in it)", m("admin"), true, { try $0.renameTeam(x, to: "N") }),
            ("member", "rename ops", m("member"), false, { try $0.renameTeam(ops, to: "N") }),
            ("owner", "rename General", m("owner"), false, { try $0.renameTeam(g, to: "N") }),
            ("owner", "rename archived", m("owner"), false, { try $0.renameTeam(old, to: "N") }),
            ("admin", "archive ops", m("admin"), true, { try $0.archiveTeam(ops) }),
            ("owner", "archive General", m("owner"), false, { try $0.archiveTeam(g) }),
            ("owner", "archive archived", m("owner"), false, { try $0.archiveTeam(old) }),
            // team.add_member: managers; not archived; not in it already; General too.
            ("admin", "add boris to ops", m("admin"), true, { try $0.addMember(self.boris, to: ops) }),
            ("member", "add boris to ops", m("member"), false, { try $0.addMember(self.boris, to: ops) }),
            ("admin", "add vera to ops (in it)", m("admin"), false, { try $0.addMember(self.vera, to: ops) }),
            ("admin", "add boris to archived", m("admin"), false, { try $0.addMember(self.boris, to: old) }),
            // ... and never the user itself: that is team.join, with its warning (p1-8).
            ("admin", "add self to x", m("admin"), false, { try $0.addMember(self.anna, to: x) }),
            // team.remove_member: managers; not General; in it — archived or not.
            ("admin", "remove vera from ops", m("admin"), true, { try $0.removeMember(self.vera, from: ops) }),
            ("member", "remove vera from ops", m("member"), false, { try $0.removeMember(self.vera, from: ops) }),
            ("owner", "remove vera from General", m("owner"), false, { try $0.removeMember(self.vera, from: g) }),
            ("admin", "remove vera from archived", m("admin"), true, { try $0.removeMember(self.vera, from: old) }),
            ("admin", "remove boris from ops (not in it)", m("admin"), false, { try $0.removeMember(self.boris, from: ops) }),
            // ... and still a member of the organization (C6c p1-5).
            ("admin", "remove a removed member from ops", m("admin", [member(anna, "admin"), member(boris, "owner")]), false,
             { try $0.removeMember(self.vera, from: ops) }),
            // team.leave: in it; not General — archived or not; any role.
            ("member", "leave ops", m("member"), true, { try $0.leave(ops) }),
            ("member", "leave archived", m("member"), true, { try $0.leave(old) }),
            ("owner", "leave General", m("owner"), false, { try $0.leave(g) }),
            ("admin", "leave x (not in it)", m("admin"), false, { try $0.leave(x) }),
            // team.join: managers; not in it; not archived.
            ("admin", "join x", m("admin"), true, { try $0.join(x) }),
            ("member", "join x", m("member"), false, { try $0.join(x) }),
            ("admin", "join ops (in it)", m("admin"), false, { try $0.join(ops) }),
            ("owner", "join archived", m("owner"), false, { try $0.join(gone) }),
            // member.set_role: owners any; admins member ↔ admin, never an
            // owner's, never to owner; not the same role; the last owner keeps it.
            ("owner", "vera → admin", m("owner"), true, { try $0.setRole(self.member(self.vera, "member"), to: "admin") }),
            ("owner", "vera → owner", m("owner"), true, { try $0.setRole(self.member(self.vera, "member"), to: "owner") }),
            ("owner", "vera → member (same)", m("owner"), false, { try $0.setRole(self.member(self.vera, "member"), to: "member") }),
            ("owner", "other owner → admin", m("owner", twoOwners), true, { try $0.setRole(self.member(self.boris, "owner"), to: "admin") }),
            ("owner", "self → admin, two owners", m("owner", twoOwners), true, { try $0.setRole(self.member(self.anna, "owner"), to: "admin") }),
            ("owner", "self → admin, last owner", m("owner", soleOwner), false, { try $0.setRole(self.member(self.anna, "owner"), to: "admin") }),
            ("admin", "vera → admin", m("admin"), true, { try $0.setRole(self.member(self.vera, "member"), to: "admin") }),
            ("admin", "vera → owner", m("admin"), false, { try $0.setRole(self.member(self.vera, "member"), to: "owner") }),
            ("admin", "owner → member", m("admin"), false, { try $0.setRole(self.member(self.boris, "owner"), to: "member") }),
            ("admin", "self → member", m("admin"), true, { try $0.setRole(self.member(self.anna, "admin"), to: "member") }),
            ("member", "vera → admin", m("member"), false, { try $0.setRole(self.member(self.vera, "member"), to: "admin") }),
            // member.remove: owners anyone, admins not an owner; never the last owner.
            ("owner", "remove vera", m("owner", soleOwner), true, { try $0.remove(self.member(self.vera, "member")) }),
            ("owner", "remove self, last owner", m("owner", soleOwner), false, { try $0.remove(self.member(self.anna, "owner")) }),
            ("owner", "remove other owner", m("owner", twoOwners), true, { try $0.remove(self.member(self.boris, "owner")) }),
            ("admin", "remove owner", m("admin"), false, { try $0.remove(self.member(self.boris, "owner")) }),
            ("admin", "remove vera", m("admin"), true, { try $0.remove(self.member(self.vera, "member")) }),
            ("admin", "remove self", m("admin"), true, { try $0.remove(self.member(self.anna, "admin")) }),
            ("member", "remove vera", m("member"), false, { try $0.remove(self.member(self.vera, "member")) }),
            // invitation.create: managers; member or admin; teams not archived.
            ("admin", "invite member", m("admin"), true, { try $0.invite(email: "n@example.com", role: "member", teams: ["ops", "x"]) }),
            ("owner", "invite admin", m("owner"), true, { try $0.invite(email: "n@example.com", role: "admin", teams: []) }),
            ("owner", "invite owner", m("owner"), false, { try $0.invite(email: "n@example.com", role: "owner", teams: []) }),
            ("admin", "invite into archived", m("admin"), false, { try $0.invite(email: "n@example.com", role: "member", teams: ["old"]) }),
            ("admin", "invite into unknown", m("admin"), false, { try $0.invite(email: "n@example.com", role: "member", teams: ["zz"]) }),
            ("member", "invite", m("member"), false, { try $0.invite(email: "n@example.com", role: "member", teams: []) }),
            // invitation.revoke: managers; an open invitation.
            ("admin", "revoke", m("admin"), true, { try $0.revoke(invitation) }),
            ("member", "revoke", m("member"), false, { try $0.revoke(invitation) }),
            // member.set_name: anyone.
            ("member", "set name", m("member"), true, { try $0.setName("A") }),
        ]
        for (role, what, model, allowed, run) in rows {
            let before = sent.count
            do {
                try run(model)
                XCTAssertTrue(allowed, "\(role): \(what) is refused by the server, yet sent")
            } catch {
                XCTAssertFalse(allowed, "\(role): \(what) is run by the server, yet refused here")
            }
            XCTAssertEqual(sent.count - before, allowed ? 1 : 0, "\(role): \(what)")
        }
        // What the window offers is what is allowed.
        let owner = m("owner", soleOwner)
        XCTAssertEqual(owner.roles(for: member(anna, "owner")), [], "the last owner is offered no role")
        XCTAssertFalse(owner.canRemove(member(anna, "owner")))
        XCTAssertEqual(m("admin").candidates(for: x).map(\.accountId), [vera], "not the admin itself, not those in it")
        XCTAssertEqual(m("admin").candidates(for: old), [])
        XCTAssertTrue(m("member").canLeave(old))
    }

    func testAMemberIsGivenOnlyItsOwnTeams() {
        let all = [team("g", mine: true, general: true), team("ops", mine: true), team("x", mine: false)]
        XCTAssertEqual(model(role: "member", teams: all).teams.map(\.teamId), ["g", "ops"])
        XCTAssertEqual(model(role: "admin", teams: all).teams.map(\.teamId), ["g", "ops", "x"])
        // An admin's role without the admin stream (it went away first): not a manager.
        let unfollowed = model(role: "admin", teams: all)
        unfollowed.set(ChatOrgView(members: [member(anna, "admin")], teams: all, followsAdmin: false))
        XCTAssertEqual(unfollowed.teams.map(\.teamId), ["g", "ops"])
        XCTAssertFalse(unfollowed.actions.contains(.seeAudit))
        // The left panel: the user's own teams in use, for any role.
        let panel = all + [team("old", mine: true, archived: true)]
        XCTAssertEqual(model(role: "owner", teams: panel).myTeams.map(\.teamId), ["g", "ops"])
    }

    // MARK: Commands

    func testCommandsCarryTheServersArguments() throws {
        let ops = team("ops", mine: false, members: [vera])
        let admin = model(role: "admin", teams: [team("g", mine: true, general: true), ops],
                          invitations: [.init(invitationId: "i1", email: "x@example.com", role: "member", state: "open")])
        admin.newTeamId = { "t-new" }
        try admin.createTeam("Design")
        try admin.renameTeam(ops, to: "Ops 2")
        try admin.addMember(boris, to: ops)
        try admin.removeMember(vera, from: ops)
        try admin.join(ops)
        try admin.setRole(member(vera, "member"), to: "admin")
        try admin.remove(member(vera, "member"))
        try admin.invite(email: "new@example.com", role: "admin", teams: ["ops"])
        try admin.revoke(admin.invitations[0])
        try admin.archiveTeam(ops)
        try admin.setName("Anna")
        XCTAssertEqual(sent.map(\.type), ["team.create", "team.rename", "team.add_member", "team.remove_member", "team.join",
                                          "member.set_role", "member.remove", "invitation.create", "invitation.revoke",
                                          "team.archive", "member.set_name"])
        XCTAssertEqual(sent[0].args, .object(["team_id": .string("t-new"), "name": .string("Design")]))
        XCTAssertEqual(sent[2].args, .object(["team_id": .string("ops"), "account_id": .string(boris)]))
        XCTAssertEqual(sent[4].args, .object(["team_id": .string("ops")]))
        XCTAssertEqual(sent[5].args, .object(["account_id": .string(vera), "role": .string("admin")]))
        XCTAssertEqual(sent[7].args, .object(["email": .string("new@example.com"), "role": .string("admin"),
                                              "team_ids": .array([.string("ops")])]))
        XCTAssertEqual(sent[8].args, .object(["invitation_id": .string("i1")]))
    }

    /// A dialog's object may be old by the time it is confirmed: each
    /// command takes its target anew, by id, from the view now (review C6b p1-5).
    func testCommandsJudgeTheirTargetAsItIsNow() {
        let x = team("x", mine: false, members: [boris])
        let admin = model(role: "admin", teams: [team("g", mine: true, general: true), x])
        let vera0 = member(vera, "member")
        // Meanwhile: vera became an owner, the admin joined x, x … is still there.
        admin.set(ChatOrgView(members: [member(anna, "admin"), member(boris, "owner"), member(vera, "owner")],
                              teams: [team("g", mine: true, general: true), team("x", mine: true, members: [anna, boris])],
                              followsAdmin: true))
        XCTAssertThrowsError(try admin.remove(vera0), "vera is an owner now")
        XCTAssertThrowsError(try admin.setRole(vera0, to: "admin"))
        XCTAssertThrowsError(try admin.join(x), "in it already")
        // Archived, then gone.
        admin.set(ChatOrgView(members: [member(anna, "admin")], teams: [team("x", mine: true, archived: true)], followsAdmin: true))
        XCTAssertThrowsError(try admin.renameTeam(x, to: "N"))
        XCTAssertEqual(admin.invitable, [], "an archived team is no longer offered to an invitation")
        admin.set(ChatOrgView(members: [member(anna, "admin")], teams: [], followsAdmin: true))
        XCTAssertThrowsError(try admin.archiveTeam(x))
        XCTAssertThrowsError(try admin.leave(x))
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: Refusals (review C6 p1-1, p2-3, p2-4)

    /// A refusal is read from the send queue itself: it outlives a restart
    /// and a sending again under a new id; it is named with what the user
    /// may see now — a manager's command, once no longer one, names nothing.
    func testRefusalsComeFromTheQueueAndNameOnlyWhatIsSeen() async throws {
        let store = try open()
        let orgStream = "org:\(org)", admin = "org-admin:\(org)"
        try store.apply(ChatSnapshot(cursors: [orgStream: 1, admin: 1], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")],
                                     teams: [.init(teamId: "x", name: "Secret", mine: false)], teamMembers: []))
        let queue = ChatOutbox(queues: [store.outbox], api: ChatAPI(server: key.server), token: "t", sessionId: "s1", held: true)
        let rename = try queue.enqueue(org: org, type: "team.rename", args: .object(["team_id": .string("x"), "name": .string("Secret 2")]))
        // The server's generation changed before it went: sent again by hand, under a new id.
        try store.outbox.markUnconfirmed()
        let again = try XCTUnwrap(try queue.resendUnconfirmed().first)
        XCTAssertNotEqual(again.commandId, rename.commandId)
        var failed = again
        failed.state = .failed
        failed.error = "forbidden"
        XCTAssertTrue(try store.outbox.update(failed, ifState: .pending))

        let model = ChatOrgModel(me: anna) { _, _ in "c" }
        model.follow(store)
        XCTAssertEqual(model.refused.map(\.title), ["Rename Secret"])
        XCTAssertEqual(model.refused.map(\.code), ["forbidden"])
        // A new model on the same cache — after a restart — names it the same.
        let restarted = ChatOrgModel(me: anna) { _, _ in "c" }
        restarted.follow(try open())
        XCTAssertEqual(restarted.refused.map(\.title), ["Rename Secret"])

        // Demoted: the team leaves the cache; the queue keeps the user's own
        // command as made (decision "Сужение видимости не трогает очередь
        // отправки"), and the refusal stays unread — named without the team.
        try store.apply(event(orgStream, 2, "member.set_role", ["account_id": anna, "role": "member"]))
        let deadline = Date().addingTimeInterval(5)
        while model.myRole != "member", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.refused.map(\.title), ["Rename a team no longer available"])
        XCTAssertEqual(model.refused.map(\.code), ["forbidden"])
        let kept = try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE state = 'failed'") }
        XCTAssertEqual(kept, 1, "the send queue is not narrowed")
    }

    /// Dismiss marks read the refusals the window showed, in its own
    /// organization's queue — no other (review C6b p2-4).
    func testDismissMarksOnlyWhatWasShown() async throws {
        let store = try open()
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")]))
        let queue = ChatOutbox(queues: [store.outbox], api: ChatAPI(server: key.server), token: "t", sessionId: "s1", held: true)
        for (type, args) in [("member.set_name", ChatJSON.object(["name": .string("A")])),
                             ("request.create", ChatJSON.object(["agent_id": .string("a1"), "text": .string("hi")]))] {
            var record = try queue.enqueue(org: org, type: type, args: args)
            record.state = .failed
            record.error = "forbidden"
            XCTAssertTrue(try store.outbox.update(record, ifState: .pending))
        }
        let model = ChatOrgModel(me: anna) { _, _ in "c" }
        model.follow(store)
        model.dismissRefusals = { queue.dismissRefused($0) }
        XCTAssertEqual(model.refused.map(\.title), ["Change your name"])
        model.dismissRefusals(Set(model.refused.map(\.id)))
        XCTAssertEqual(queue.refused.map(\.type), ["request.create"], "what the window did not show stays unread")
        // The queue's own Dismiss is as before: everything.
        queue.dismissRefused()
        XCTAssertEqual(queue.refused, [])
    }

    // MARK: Devices and the log (review C6 p1-9, p2-5, p2-10)

    func testDevicesFollowTheServerAndOnlyTheLatestRead() async {
        let devices = ChatDevicesModel()
        let mini = ChatDeviceSession(sessionId: "s1", deviceName: "Mini", createdAt: "t", lastSeenAt: nil, current: false)
        let pro = ChatDeviceSession(sessionId: "s2", deviceName: "Pro", createdAt: "t", lastSeenAt: nil, current: true)
        var server = [mini, pro]
        var closed: [String] = []
        devices.listSessions = { server }
        devices.closeSessionCall = { id in
            guard server.contains(where: { $0.sessionId == id }) else {
                throw ChatAPIError.server(status: 404, code: "not_found", retryAfter: nil)
            }
            closed.append(id)
            server.removeAll { $0.sessionId == id }
        }
        await devices.load()
        await devices.close(mini)
        XCTAssertEqual(closed, ["s1"])
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s2"])

        // Closed from elsewhere meanwhile: 404 takes it off and reads again.
        server = [mini, pro]
        await devices.load()
        server = [pro]
        await devices.close(mini)
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s2"])
        XCTAssertNil(devices.problem)

        // A read begun before a close does not bring the closed one back.
        server = [mini, pro]
        await devices.load()
        let slow = AsyncGate()
        devices.listSessions = {
            let seen = server
            await slow.wait()
            return seen
        }
        let reading = Task { await devices.load() }
        try? await Task.sleep(for: .milliseconds(50))
        devices.closeSessionCall = { _ in server.removeAll { $0.sessionId == "s1" } }
        let closingFirst = Task { await devices.close(mini) }
        try? await Task.sleep(for: .milliseconds(50))
        await slow.open()
        await reading.value
        await closingFirst.value
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s2"])

        // A Refresh during a close reads before the DELETE ends: its answer
        // does not bring the closed one back (review C6b p1-8, p2-2).
        server = [mini, pro]
        devices.listSessions = { server }
        await devices.load()
        let deleting = AsyncGate(), reading2 = AsyncGate()
        devices.listSessions = {
            let seen = server
            await reading2.wait()
            return seen
        }
        devices.closeSessionCall = { _ in
            await deleting.wait()
            server.removeAll { $0.sessionId == "s1" }
        }
        let closing = Task { await devices.close(mini) }
        try? await Task.sleep(for: .milliseconds(30))
        let refreshing = Task { await devices.load() }
        try? await Task.sleep(for: .milliseconds(30))
        await deleting.open()
        try? await Task.sleep(for: .milliseconds(30))
        devices.listSessions = { server }
        await reading2.open()
        await refreshing.value
        await closing.value
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s2"])

        // A close that fails says so, and the device stays.
        server = [mini, pro]
        await devices.load()
        devices.closeSessionCall = { _ in throw ChatAPIError.server(status: 500, code: "internal", retryAfter: nil) }
        await devices.close(mini)
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s1", "s2"])
        XCTAssertNotNil(devices.problem)

        // This Mac's own: the core's Disconnect, not a DELETE (review C6e p1-5).
        var disconnects = 0, deletes = 0
        devices.disconnect = { disconnects += 1 }
        devices.closeSessionCall = { _ in deletes += 1 }
        await devices.close(pro)
        XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(deletes, 0)

        // Not current any more: nothing is read into it.
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s1", "s2"])
        devices.isCurrent = { false }
        devices.listSessions = { [mini] }
        await devices.load()
        XCTAssertEqual(devices.devices?.map(\.sessionId), ["s1", "s2"])
    }

    func testTheSecurityLogIsAManagersOnlyAndOneReadAtATime() async throws {
        let record = { (id: Int) in ChatAuditPage.Record(id: id, at: "t", actorAccountId: nil, action: "team.join", object: "team:x", result: "ok") }
        var reads: [Int?] = []
        let plain = model(role: "member")
        plain.readAudit = { reads.append($0); return ChatAuditPage(records: [], next: nil) }
        await plain.loadAudit()
        XCTAssertEqual(reads, [], "a member does not read it")

        let admin = model(role: "admin")
        let gate = AsyncGate()
        admin.readAudit = { before in
            reads.append(before)
            if before != nil { await gate.wait() }
            return ChatAuditPage(records: [record(before.map { $0 - 1 } ?? 10)], next: before == nil ? 10 : nil)
        }
        await admin.loadAudit()
        // Two Older at once: one read; a Refresh meanwhile voids it.
        let older = Task { await admin.loadAudit(more: true) }
        try await Task.sleep(for: .milliseconds(50))
        await admin.loadAudit(more: true)
        XCTAssertEqual(reads, [nil, 10], "the second Older waits for none")
        await admin.loadAudit()
        await gate.open()
        await older.value
        XCTAssertEqual(admin.audit?.map(\.id), [10], "the Older begun before the Refresh is not added")

        // Demoted: the log goes, and a read on its way brings nothing back.
        let closed = AsyncGate()
        admin.readAudit = { _ in await closed.wait(); return ChatAuditPage(records: [record(99)], next: nil) }
        let late = Task { await admin.loadAudit() }
        try await Task.sleep(for: .milliseconds(50))
        admin.set(ChatOrgView(members: [member(anna, "member")], followsAdmin: false))
        XCTAssertNil(admin.audit)
        await closed.open()
        await late.value
        XCTAssertNil(admin.audit)

        // The server refuses the log (the feed has not told yet): a sign. The
        // log goes, rights are in doubt — only a member's view — until a
        // snapshot read after it; nothing else gives them back (review C6e).
        let refused = model(role: "admin")
        refused.readAudit = { _ in ChatAuditPage(records: [record(5)], next: nil) }
        await refused.loadAudit()
        XCTAssertEqual(refused.audit?.count, 1)
        var signs: [String] = []
        // The sign's write, as the cache would show it.
        refused.onRightsSign = { [unowned refused] in
            signs.append($0)
            refused.set(ChatOrgView(members: [self.member(self.anna, "admin")], teams: [self.team("x", mine: false)],
                                    followsAdmin: true, rightsInDoubt: true))
        }
        refused.readAudit = { _ in throw ChatAPIError.server(status: 403, code: "forbidden", retryAfter: nil) }
        await refused.loadAudit()
        XCTAssertNil(refused.audit)
        XCTAssertEqual(signs, ["forbidden"])
        XCTAssertFalse(refused.manages)
        XCTAssertEqual(refused.teams, [])
        // A snapshot read after the sign was applied: its view ends the doubt.
        refused.set(ChatOrgView(members: [member(anna, "admin")], teams: [team("x", mine: false)], followsAdmin: true))
        XCTAssertTrue(refused.manages)

        // A 404 answered after a newer read is no sign (review C6e p2-1).
        let held = AsyncGate()
        signs = []
        refused.readAudit = { _ in await held.wait(); throw ChatAPIError.server(status: 404, code: "not_found", retryAfter: nil) }
        let stale = Task { await refused.loadAudit() }
        try await Task.sleep(for: .milliseconds(30))
        refused.readAudit = { _ in ChatAuditPage(records: [record(6)], next: nil) }
        await refused.loadAudit()
        await held.open()
        await stale.value
        XCTAssertEqual(signs, [])
        XCTAssertEqual(refused.audit?.map(\.id), [6])
    }

    /// C6g p1-1: in doubt, nothing but the organization's name and the
    /// user's own — no team, its own included, and no action.
    func testInDoubtNothingButNames() {
        let doubting = model(role: "member", teams: [team("g", mine: true, general: true), team("ops", mine: true)])
        doubting.set(ChatOrgView(orgName: "Rabbitshat", members: [member(anna, "member"), member(vera, "member")],
                                 teams: [team("g", mine: true, general: true), team("ops", mine: true)], rightsInDoubt: true))
        XCTAssertEqual(doubting.orgName, "Rabbitshat")
        XCTAssertEqual(doubting.members.map(\.accountId), [anna])
        XCTAssertEqual(doubting.teams, [])
        XCTAssertEqual(doubting.myTeams, [])
        XCTAssertEqual(doubting.actions, [])
        XCTAssertNotNil(doubting.notice)
        XCTAssertThrowsError(try doubting.setName("A"))
        XCTAssertThrowsError(try doubting.leave(team("ops", mine: true)))
        XCTAssertTrue(sent.isEmpty)
    }

    /// C6g p1-2, p1-3: the doubt could not be written: nothing is shown —
    /// and not the old view either once the write works, only one read after.
    func testAStorageProblemShowsNothingUntilANewView() async throws {
        let admin = model(role: "admin", teams: [team("x", mine: false)])
        var problem = false
        admin.storageProblem = { problem }
        XCTAssertTrue(admin.manages)
        problem = true
        XCTAssertFalse(admin.manages)
        XCTAssertEqual(admin.teams, [])
        XCTAssertNotNil(admin.notice)
        // Observed: the view is held back until one read after the problem.
        let store = try open("probe")
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1, "org-admin:\(org)": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")], teams: []))
        let probe = ChatOrgModel(me: anna) { _, _ in "c" }
        let flag = ProblemFlag()
        probe.storageProblem = { flag.on }
        probe.problemEpoch = { flag.failures }
        probe.follow(store)
        XCTAssertTrue(probe.manages)
        // A failure and its end in one turn, no pause: the old view never
        // shows again — only a view read after the failure (review C6i p1-2).
        flag.on = true
        flag.failures += 1
        try store.putRightsInDoubt()
        flag.on = false
        XCTAssertFalse(probe.manages, "the view from before the failure")
        XCTAssertNotNil(probe.notice)
        let deadline = Date().addingTimeInterval(5)
        while probe.notice?.contains("save") == true, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(probe.visible)
        XCTAssertTrue(probe.inDoubt, "read after the failure")
        XCTAssertFalse(probe.manages)
    }

    // MARK: The model's life (review C6 group C)

    /// A model stands for one connection's organization and cache: once the
    /// account is no longer in it, it shows and sends nothing — and never
    /// makes the organization's cache again.
    func testAModelOfAnOrganizationLostSendsNothing() async throws {
        let service = ChatService(files: ChatFiles(directory: root.appendingPathComponent("svc")), tokens: FakeTokenStore())
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        // Every organization starts in doubt; its first snapshot ends it (C6h).
        let started = try XCTUnwrap(service.session(for: key).store)
        let startedView = try await started.queue.read(ChatOrgView.read)
        XCTAssertTrue(startedView.rightsInDoubt)
        try started.apply(ChatSnapshot(cursors: ["org:\(org)": 1], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")]),
                          confirmsRights: "s1")
        let model = try XCTUnwrap(ChatOrgModel.current(service))
        try model.setName("Anna")
        XCTAssertTrue(model.isCurrent())
        // The server ended the session (4401): nothing goes on it any more.
        service.sessionEnded("closed")
        XCTAssertFalse(model.isCurrent())
        XCTAssertThrowsError(try model.setName("Anna 2"))
        XCTAssertNil(ChatDevicesModel.current(service).flatMap { $0.isCurrent() ? $0 : nil })
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        XCTAssertTrue(model.isCurrent())
        // A 401 of a read ends that session, as the core's queue does; one
        // about an earlier session ends nothing (review C6c p1-3, p1-4).
        do {
            _ = try await ChatService.endingOn401(service, session: "s0", server: key.server) { () async throws -> Int in
                throw ChatAPIError.server(status: 401, code: "unauthorized", retryAfter: nil)
            }
        } catch {}
        XCTAssertEqual(service.state, .signedIn, "an earlier session's 401 ends nothing")
        do {
            _ = try await ChatService.endingOn401(service, session: "s1", server: key.server) { () async throws -> Int in
                throw ChatAPIError.server(status: 401, code: "unauthorized", retryAfter: nil)
            }
        } catch {}
        XCTAssertEqual(service.state, .needsSignIn(ChatService.sessionClosedReason))
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        service.membershipLost(key)
        XCTAssertFalse(model.isCurrent())
        XCTAssertThrowsError(try model.setName("Anna 2"))
        XCTAssertNil(service.orgSessions[key], "the organization's cache is not made again")
        XCTAssertEqual(model.teams, [])
        XCTAssertNil(ChatOrgModel.current(service))
        // The account's devices stay: they are the session's.
        XCTAssertNotNil(ChatDevicesModel.current(service))
    }

    /// C6e: a sign with no synchronizer running puts the organization's
    /// rights in doubt all the same; a 404 asks `/v1/me`, it does not end
    /// the membership by itself.
    func testASignWithoutAFeedPutsRightsInDoubt() async throws {
        let service = ChatService(files: ChatFiles(directory: root.appendingPathComponent("svc404")), tokens: FakeTokenStore())
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        let store = try XCTUnwrap(service.session(for: key).store)
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1, "org-admin:\(org)": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")], teams: []),
                        confirmsRights: "s1")
        let model = try XCTUnwrap(ChatOrgModel.current(service))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.manages)
        model.readAudit = { _ in throw ChatAPIError.server(status: 404, code: "not_found", retryAfter: nil) }
        await model.loadAudit()
        XCTAssertEqual(service.state, .signedIn, "out of the organization only if /v1/me says so")
        let deadline = Date().addingTimeInterval(5)
        while model.manages, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.view.rightsInDoubt, "kept in the cache")
        XCTAssertFalse(model.manages)
    }

    /// C6f p1-1: the doubt outlives a restart — a model of the same cache
    /// made anew manages nothing until a snapshot read after the sign; and
    /// the snapshot's rights and the end of the doubt come in one view (p2-5).
    func testTheDoubtOutlivesARestartAndEndsWithTheSnapshot() async throws {
        let store = try open()
        let admin: ChatSnapshot.Member = .init(accountId: anna, handle: "anna", name: "Anna", role: "admin")
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1, "org-admin:\(org)": 1], members: [admin],
                                     teams: [.init(teamId: "x", name: "Secret", mine: false)], teamMembers: []))
        try store.putRightsInDoubt()
        let restarted = ChatOrgModel(me: anna) { _, _ in "c" }
        var views: [ChatOrgView] = []
        restarted.follow(try open())
        XCTAssertFalse(restarted.manages)
        XCTAssertEqual(restarted.teams, [], "only a member's view")
        let watcher = ChatOrgModel(me: anna) { _, _ in "c" }
        watcher.follow(store)
        // The snapshot: a member now. Its data and the doubt's end in one view.
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 2], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")],
                                     teams: []), following: ["org:\(org)"], confirmsRights: "s1")
        views.append(try await store.queue.read(ChatOrgView.read))
        XCTAssertFalse(views[0].rightsInDoubt)
        XCTAssertFalse(views[0].followsAdmin)
        let deadline = Date().addingTimeInterval(5)
        while watcher.view.rightsInDoubt, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(watcher.manages)
        XCTAssertEqual(watcher.view.teams, [])
    }

    /// C6e p2-3: a failed read of the cache stops GRDB's observation: the
    /// model shows nothing meanwhile, and follows again after a pause.
    func testAFailedReadOfTheCacheIsFollowedAgain() async throws {
        let store = try open()
        try store.apply(ChatSnapshot(cursors: ["team:g": 0], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")],
                                     teams: [.init(teamId: "g", name: "General", isGeneral: true)], teamMembers: []))
        let model = ChatOrgModel(me: anna) { _, _ in "c" }
        model.observationRetryDelay = { _ in 0.2 }
        model.follow(store)
        XCTAssertEqual(model.myTeams.map(\.name), ["General"])
        // The table goes for a moment: the read fails.
        try await store.queue.write { db in
            try db.execute(sql: "ALTER TABLE invitations RENAME TO invitations_away")
            try db.execute(sql: "UPDATE members SET name = 'Anna 2'")
        }
        let deadline = Date().addingTimeInterval(5)
        while model.problem == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.problem)
        XCTAssertEqual(model.members, [], "nothing of the organization while it cannot be read")
        XCTAssertEqual(model.actions, [], "and nothing done (review C6i p1-3)")
        try await store.queue.write { db in try db.execute(sql: "ALTER TABLE invitations_away RENAME TO invitations") }
        while model.problem != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.myTeams.map(\.name), ["General"])
    }

    /// C6i p1-1: rights count for the session whose snapshot confirmed them:
    /// a new sign-in in the same run, the organization's session reused,
    /// starts in doubt until a snapshot of its own.
    func testANewSignInStartsInDoubtInTheSameRun() async throws {
        let service = ChatService(files: ChatFiles(directory: root.appendingPathComponent("relogin")), tokens: FakeTokenStore())
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s1", deviceName: "Mac", orgId: org),
                               token: "aps_t")
        let session = service.session(for: key)
        let store = try XCTUnwrap(session.store)
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1, "org-admin:\(org)": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")]), confirmsRights: "s1")
        let first = try XCTUnwrap(ChatOrgModel.current(service))
        XCTAssertTrue(first.manages)
        // Signed in again, the same run: the same organization session.
        try service.saveSignIn(ChatConnection(server: key.server, accountId: anna, sessionId: "s2", deviceName: "Mac", orgId: org),
                               token: "aps_u")
        XCTAssertTrue(service.orgSessions[key] === session)
        let second = try XCTUnwrap(ChatOrgModel.current(service))
        XCTAssertTrue(second.inDoubt)
        XCTAssertFalse(second.manages)
        try store.apply(ChatSnapshot(cursors: [:]), confirmsRights: "s2")
        let deadline = Date().addingTimeInterval(5)
        while second.inDoubt, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(second.manages)
    }

    /// C6h p1-1: a launch never trusts the rights it finds: each
    /// organization starts in doubt, whatever the cache said before.
    func testEveryLaunchStartsInDoubt() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("launch"))
        let first = ChatService(files: files, tokens: FakeTokenStore())
        let store = try XCTUnwrap(first.session(for: key).store)
        try store.apply(ChatSnapshot(cursors: ["org:\(org)": 1, "org-admin:\(org)": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")]), confirmsRights: "s1")
        let confirmed = try await store.queue.read(ChatOrgView.read)
        XCTAssertFalse(confirmed.rightsInDoubt)
        // A new launch on the same cache.
        let second = ChatService(files: files, tokens: FakeTokenStore())
        let again = try XCTUnwrap(second.session(for: key).store)
        let relaunched = try await again.queue.read(ChatOrgView.read)
        XCTAssertTrue(relaunched.rightsInDoubt)
    }

    // MARK: The cache

    /// Each event of A5 changes the cache as the server's snapshot would
    /// have it; a team is the user's when seen in its own stream.
    func testEventsOfA5ChangeTheCache() throws {
        let store = try open()
        let orgStream = "org:\(org)", admin = "org-admin:\(org)", mine = "member:\(org):\(anna)"
        try store.apply(ChatSnapshot(cursors: [orgStream: 0, admin: 0, mine: 0],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "owner"),
                                               .init(accountId: boris, handle: "boris", name: "Boris", role: "member")],
                                     teams: [], teamMembers: []))
        try store.apply(event(admin, 1, "team.create", ["team_id": "t1", "name": "Ops"]))
        XCTAssertEqual(try teams(store), ["t1": false], "created by a manager who is not in it")
        // A manager takes teams from the admin stream alone (review C6c p2-1).
        try store.apply(event("team:t2", 1, "team.create", ["team_id": "t2", "name": "Design"]))
        XCTAssertNil(try teams(store)["t2"])
        try store.apply(event(admin, 2, "team.rename", ["team_id": "t1", "name": "Ops 2"]))
        try store.apply(event(admin, 3, "team.archive", ["team_id": "t1", "archived_at": "2026-10-04T18:21:00Z"]))
        let view = try store.queue.read(ChatOrgView.read)
        XCTAssertEqual(view.teams.map(\.name), ["Ops 2"])
        XCTAssertEqual(view.teams.first?.archived, true)
        // A member's teams come from their own streams: one seen there is its own.
        let member = try open("member")
        try member.apply(ChatSnapshot(cursors: [orgStream: 0, "team:t2": 0],
                                      members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")]))
        try member.apply(event("team:t2", 1, "team.create", ["team_id": "t2", "name": "Design"]))
        try member.apply(event("team:t2", 2, "team.rename", ["team_id": "t2", "name": "Design 2"]))
        XCTAssertEqual(try member.queue.read(ChatOrgView.read).teams.map { "\($0.name):\($0.mine)" }, ["Design 2:true"])

        try store.apply(event(admin, 4, "team.add_member", ["team_id": "t1", "account_id": boris]))
        // The user's own join, in its own stream: written by the snapshot it
        // asks for, not by the event — it may be older than a removal (C6d p1-2).
        try store.apply(event(mine, 1, "team.join", ["team_id": "t1", "account_id": anna]))
        XCTAssertEqual(try teams(store)["t1"], false)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members WHERE team_id = 't1'"), 1)
        try store.apply(event(admin, 5, "team.join", ["team_id": "t1", "account_id": anna]))
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members WHERE team_id = 't1'"), 2)

        try store.apply(event(orgStream, 1, "member.set_role", ["account_id": boris, "role": "admin"]))
        XCTAssertEqual(try store.queue.read(ChatOrgView.read).members.first { $0.accountId == boris }?.role, "admin")

        // A manager who leaves keeps the team, no longer its own.
        try store.apply(event(mine, 2, "team.leave", ["team_id": "t1", "account_id": anna]))
        XCTAssertEqual(try teams(store)["t1"], false)

        try store.apply(event(orgStream, 2, "member.remove", ["account_id": boris]))
        try store.apply(event(admin, 6, "member.remove", ["account_id": boris]))
        XCTAssertEqual(try store.queue.read(ChatOrgView.read).members.map(\.accountId), [anna])
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members WHERE account_id = '\(boris)'"), 0)
    }

    /// The owner's decision: a member sees nothing of teams it is not in,
    /// names included — in the cache too, not only on screen. Every way of
    /// losing a right narrows the cache in the same transaction
    /// (`ChatStore.narrow`, review C6 group A).
    func testEveryWayOfLosingRightsNarrowsTheCache() throws {
        let orgStream = "org:\(org)", admin = "org-admin:\(org)", mine = "member:\(org):\(anna)"
        /// An admin in General, seeing Secret and an invitation, with a
        /// refused rename of Secret in its queue.
        func managing(_ name: String) throws -> ChatStore {
            let store = try open(name)
            try store.apply(ChatSnapshot(cursors: [orgStream: 1, mine: 1, "team:g": 1, admin: 1],
                                         members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")],
                                         teams: [.init(teamId: "g", name: "General", isGeneral: true), .init(teamId: "x", name: "Secret", mine: false)],
                                         teamMembers: [.init(teamId: "g", accountId: anna), .init(teamId: "x", accountId: boris)],
                                         invitations: [.init(invitationId: "i1", email: "a@example.com", role: "member", state: "open")]))
            let body = try ChatCommandEnvelope(commandId: "c1", org: org, type: "team.rename",
                                               args: .object(["team_id": .string("x"), "name": .string("Secret 2")])).encoded()
            _ = try store.outbox.enqueue(ChatCommandRecord(commandId: "c1", sessionId: "s1", type: "team.rename", bodyBytes: body,
                                                           orderKey: org, dependsOn: nil, createdAt: Date(), state: .failed, error: "forbidden"))
            return store
        }
        func assertNarrowed(_ store: ChatStore, _ how: String) throws {
            XCTAssertEqual(try teams(store), ["g": true], how)
            XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members WHERE team_id = 'x'"), 0, how)
            XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM invitations"), 0, how)
            XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM outbox"), 1, "\(how): the send queue is not narrowed")
            XCTAssertNil(try store.cursors()[admin], how)
        }
        // 1. The user's own demotion, by its event alone.
        let demoted = try managing("demoted")
        try demoted.apply(event(orgStream, 2, "member.set_role", ["account_id": anna, "role": "member"]))
        try assertNarrowed(demoted, "demoted by event")
        // 2. A snapshot without the admin stream.
        let snapshotted = try managing("snapshot")
        try snapshotted.apply(ChatSnapshot(cursors: [orgStream: 2, mine: 1, "team:g": 1],
                                           members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")],
                                           teams: [.init(teamId: "g", name: "General", isGeneral: true)],
                                           teamMembers: [.init(teamId: "g", accountId: anna)]),
                              following: [orgStream, mine, "team:g"])
        try assertNarrowed(snapshotted, "snapshot without the admin stream")
        // 3. The admin stream dropped by the socket, the role not yet known.
        let unsubscribed = try managing("unsubscribed")
        try unsubscribed.drop(stream: admin)
        try assertNarrowed(unsubscribed, "admin stream dropped")
        // 4. A snapshot whose role is a member's though it still lists the admin stream.
        let stale = try managing("stale")
        try stale.apply(ChatSnapshot(cursors: [orgStream: 2], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")]))
        try assertNarrowed(stale, "a member's role in a snapshot")

        // 5. Out of a team, not a manager: nothing of it stays.
        let store = try open("member")
        try store.apply(ChatSnapshot(cursors: [orgStream: 1, mine: 1, "team:g": 1, "team:ops": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "member")],
                                     teams: [.init(teamId: "g", name: "General", isGeneral: true), .init(teamId: "ops", name: "Ops"),
                                             .init(teamId: "qa", name: "QA")],
                                     teamMembers: [.init(teamId: "g", accountId: anna), .init(teamId: "ops", accountId: anna),
                                                   .init(teamId: "ops", accountId: boris), .init(teamId: "qa", accountId: anna)]))
        try store.apply(event(mine, 2, "team.remove_member", ["team_id": "ops", "account_id": anna]))
        try store.apply(event(mine, 3, "team.leave", ["team_id": "qa", "account_id": anna]))
        XCTAssertEqual(try teams(store), ["g": true], "removed from Ops, left QA: nothing of them, not even names")
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members WHERE team_id IN ('ops', 'qa')"), 0)
    }

    /// Events of one change come in several streams, one id in all, in any
    /// order between streams; the cache ends as the server's snapshot of the
    /// end state, whatever the order, and a snapshot of that state taken in
    /// the middle changes nothing (review C6 p2-1, p2-7, C6b p2-7). Boris is
    /// removed — and invited back into General and Ops, or not — as seen
    /// by an owner (the admin stream) and by a member (team streams only).
    func testEveryOrderOfStreamsEndsAsTheSnapshot() throws {
        let orgStream = "org:\(org)", admin = "org-admin:\(org)"
        func copy(_ id: String, _ stream: String, _ seq: Int, _ type: String, _ body: [String: String]) -> ChatEvent {
            ChatEvent(stream: stream, seq: seq, id: id, type: type, actor: nil,
                      body: .object(body.mapValues { .string($0) }), commandId: nil, at: "2026-10-04T18:20:00Z")
        }
        let removed = UUID().uuidString, joined = UUID().uuidString, toG = UUID().uuidString, toOps = UUID().uuidString
        let boris0 = ChatSnapshot.Member(accountId: boris, handle: "boris", name: "Boris", role: "member")
        let teams: [ChatSnapshot.Team] = [.init(teamId: "g", name: "General", isGeneral: true), .init(teamId: "ops", name: "Ops")]
        func pairs(_ withBoris: Bool) -> [ChatSnapshot.TeamMember] {
            [.init(teamId: "g", accountId: anna), .init(teamId: "ops", accountId: anna)]
                + (withBoris ? [.init(teamId: "g", accountId: boris), .init(teamId: "ops", accountId: boris)] : [])
        }
        func projection(_ store: ChatStore) throws -> [String] {
            try store.queue.read { db in
                try String.fetchAll(db, sql: "SELECT 'm:' || account_id || ':' || role FROM members ORDER BY 1")
                    + String.fetchAll(db, sql: "SELECT 't:' || team_id || ':' || account_id FROM team_members ORDER BY 1")
                    + String.fetchAll(db, sql: "SELECT 'team:' || team_id || ':' || mine FROM teams ORDER BY 1")
            }
        }
        var runs = 0
        for owner in [true, false] {
            for back in [true, false] {
                let role = owner ? "owner" : "member"
                let me = ChatSnapshot.Member(accountId: anna, handle: "anna", name: "Anna", role: role)
                // Per stream, in its own order; the team streams of a member are General's and Ops'.
                var streams: [[ChatEvent]] = [
                    [copy(removed, orgStream, 2, "member.remove", ["account_id": boris])]
                        + (back ? [copy(joined, orgStream, 3, "member.joined", ["account_id": boris, "handle": "boris", "name": "Boris", "role": "member"])] : []),
                    [copy(removed, "team:ops", 2, "member.remove", ["account_id": boris])]
                        + (back ? [copy(toOps, "team:ops", 3, "team.add_member", ["team_id": "ops", "account_id": boris])] : []),
                ]
                if owner {
                    streams.append([copy(removed, admin, 2, "member.remove", ["account_id": boris])]
                        + (back ? [copy(toG, admin, 3, "team.add_member", ["team_id": "g", "account_id": boris]),
                                   copy(toOps, admin, 4, "team.add_member", ["team_id": "ops", "account_id": boris])] : []))
                } else {
                    streams.append([copy(removed, "team:g", 2, "member.remove", ["account_id": boris])]
                        + (back ? [copy(toG, "team:g", 3, "team.add_member", ["team_id": "g", "account_id": boris])] : []))
                }
                var cursors = [orgStream: 1, "team:ops": 1, "team:g": 1]
                if owner { cursors[admin] = 1 }
                let start = ChatSnapshot(cursors: cursors, members: [me, boris0], teams: teams, teamMembers: pairs(true))
                var heads = cursors
                for stream in streams { if let last = stream.last { heads[last.stream] = last.seq } }
                let end = ChatSnapshot(cursors: heads, members: back ? [me, boris0] : [me], teams: teams, teamMembers: pairs(back))
                let expected = try open("expected-\(owner)-\(back)")
                try expected.apply(end)
                let want = try projection(expected)

                var orders: [[Int]] = []
                func interleave(_ left: [Int], _ order: [Int]) {
                    if left.allSatisfy({ $0 == 0 }) { return orders.append(order) }
                    for (i, n) in left.enumerated() where n > 0 {
                        var rest = left
                        rest[i] -= 1
                        interleave(rest, order + [i])
                    }
                }
                interleave(streams.map(\.count), [])
                for (n, order) in orders.enumerated() {
                    let store = try open("order-\(runs)")
                    runs += 1
                    try store.apply(start)
                    // Every third order takes the end's snapshot somewhere in the middle.
                    let snapshotAt = n % 3 == 0 ? n % (order.count + 1) : nil
                    var next = Array(repeating: 0, count: streams.count)
                    for (k, i) in order.enumerated() {
                        if k == snapshotAt { try store.apply(end) }
                        try store.apply(streams[i][next[i]])
                        next[i] += 1
                    }
                    XCTAssertEqual(try projection(store), want, "\(role), back \(back), order \(order)")
                }
            }
        }
        XCTAssertGreaterThan(runs, 300)
    }

    /// An admin added to T and removed again (both by the admin stream);
    /// the add's late copy in its own stream, then a demotion: T is not the
    /// user's, and the member's cache keeps nothing of it (review C6d p1-2).
    func testALateOwnAddDoesNotUndoAKnownRemoval() throws {
        let store = try open()
        let orgStream = "org:\(org)", admin = "org-admin:\(org)", mine = "member:\(org):\(anna)"
        try store.apply(ChatSnapshot(cursors: [orgStream: 1, admin: 1, mine: 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")],
                                     teams: [.init(teamId: "t", name: "Secret", mine: false)], teamMembers: []))
        try store.apply(event(admin, 2, "team.add_member", ["team_id": "t", "account_id": anna]))
        try store.apply(event(admin, 3, "team.remove_member", ["team_id": "t", "account_id": anna]))
        try store.apply(event(mine, 2, "team.add_member", ["team_id": "t", "account_id": anna]))
        try store.apply(event(orgStream, 2, "member.set_role", ["account_id": anna, "role": "member"]))
        XCTAssertEqual(try teams(store), [:])
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM team_members"), 0)
    }

    /// A manager's teams come from the admin stream alone: a team's own
    /// stream stops once the manager leaves it, and what it still owed must
    /// not matter (review C6c p2-1). Renamed A then B; the admin stream has
    /// both, the team stream only a late A, then the manager leaves.
    func testAManagersTeamsFollowTheAdminStreamAlone() throws {
        let store = try open()
        let orgStream = "org:\(org)", admin = "org-admin:\(org)", mine = "member:\(org):\(anna)"
        try store.apply(ChatSnapshot(cursors: [orgStream: 1, admin: 1, mine: 1, "team:t": 1],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "owner")],
                                     teams: [.init(teamId: "t", name: "T")], teamMembers: [.init(teamId: "t", accountId: anna)]))
        try store.apply(event(admin, 2, "team.rename", ["team_id": "t", "name": "A"]))
        try store.apply(event(admin, 3, "team.rename", ["team_id": "t", "name": "B"]))
        try store.apply(event("team:t", 2, "team.rename", ["team_id": "t", "name": "A"]))
        try store.apply(event(mine, 2, "team.leave", ["team_id": "t", "account_id": anna]))
        let view = try store.queue.read(ChatOrgView.read)
        XCTAssertEqual(view.teams.map(\.name), ["B"])
        XCTAssertEqual(view.teams.map(\.mine), [false])
        XCTAssertNil(try store.cursors()["team:t"], "the team's stream is no longer followed")
    }

    /// The model follows the cache as the feed writes it — no polling; an
    /// invitation that expires leaves it on time, without an event.
    func testTheModelFollowsTheCacheAndTheClock() async throws {
        let store = try open()
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1.2))
        try store.apply(ChatSnapshot(cursors: ["team:g": 0, "org-admin:\(org)": 0],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "owner")],
                                     teams: [.init(teamId: "g", name: "General", isGeneral: true)], teamMembers: [],
                                     invitations: [.init(invitationId: "i1", email: "a@example.com", role: "member", state: "open", expiresAt: soon)]))
        let model = ChatOrgModel(me: anna) { _, _ in "c" }
        model.follow(store)
        XCTAssertEqual(model.myTeams.map(\.name), ["General"])
        XCTAssertEqual(model.invitations.map(\.invitationId), ["i1"])
        try store.apply(event("org-admin:\(org)", 1, "team.rename", ["team_id": "g", "name": "Everyone"]))
        let deadline = Date().addingTimeInterval(5)
        while model.myTeams.first?.name != "Everyone", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.myTeams.map(\.name), ["Everyone"])
        while !model.invitations.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.invitations.map(\.invitationId), [], "expired: gone as the snapshot would have it")
    }
}

/// Lets an async step wait until the test opens it.
actor AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// An observable flag for a model's storage problem in tests.
@MainActor
@Observable
final class ProblemFlag {
    var on = false
    var failures = 0
}
