import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// Answers of the stub server, changeable while a test runs.
final class ChannelRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, Data)] = [:]
    var gate: Gate?
    /// The path (with its query) that passes the gate; others don't wait.
    var gated: String?
    func set(_ path: String, _ body: String, status: Int = 200) { lock.withLock { answers[path] = (status, Data(body.utf8)) } }
    func answer(_ path: String) -> (Int, Data)? { lock.withLock { answers[path] } }
}

/// Channel cards (DESIGN-F2): the cache's rule of versions, the read of
/// the snapshot and its pages, its end, and what may be shown of them.
@MainActor
final class ChatChannelsTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let me = CallJSON.anna
    private let team = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private let other = "7b2d0f3c-8e4a-4b6f-9c2d-3e4f5a6b7c8d"
    private var services: [ChatService] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-channels-\(UUID().uuidString)")
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
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: me, orgId: org) }
    private var teamStream: String { "team:\(team)" }

    private func waitUntil(_ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func card(_ id: String, _ name: String, version: Int = 1, team: String? = nil, archived: Bool = false, by: String? = nil) -> String {
        #"{"channel_id":"\#(id)","team_id":"\#(team ?? self.team)","name":"\#(name)","created_by":"\#(by ?? me)","created_at":"2026-10-05T09:00:00Z","archived":\#(archived),"archived_at":null,"version":\#(version),"head":0,"messages":[],"messages_before":null}"#
    }

    private func state(_ cards: [String], next: String?, teamSeq: Int = 3, mine: Bool = true) -> String {
        #"""
        {"org":{"org_id":"\#(org)","name":"Rabbitshat"},"members":[{"account_id":"\#(me)","handle":"anna","name":"Anna","role":"member"}],
         "teams":[{"team_id":"\#(team)","name":"Billing","is_general":false,"archived_at":null,"members":[\#(mine ? "\"\(me)\"" : "")]}],"my_teams":[\#(mine ? "\"\(team)\"" : "")],
         "admin":null,"agents":[],"requests":[],"requests_next":null,
         "channels":[\#(cards.joined(separator: ","))],"channels_next":\#(next.map { "\"\($0)\"" } ?? "null"),
         "streams":{"org:\#(org)":0,"member:\#(org):\#(me)":4,"\#(teamStream)":\#(teamSeq)}}
        """#
    }

    private func page(_ cards: [String], next: String?) -> String {
        #"{"channels":[\#(cards.joined(separator: ","))],"next":\#(next.map { "\"\($0)\"" } ?? "null")}"#
    }

    private func eventFrame(_ seq: Int, _ type: String, _ body: String) -> String {
        #"{"frame":"event","stream":"\#(teamStream)","seq":\#(seq),"id":"e-\#(seq)","type":"\#(type)","actor":null,"body":\#(body),"command_id":null,"at":"2026-10-05T09:00:00Z","sig":null,"sig_alg":null,"enc":null}"#
    }

    /// Anna's app against the stub server answering `routes`.
    private func started(_ routes: ChannelRoutes) async throws -> (ChatService, Transports) {
        let org = self.org, me = self.me
        let meJSON = #"""
        {"account_id":"\#(me)","session_id":"s-anna","orgs":[{"org_id":"\#(org)","org_name":"Rabbitshat","role":"member","handle":"anna","name":"Anna"}],
         "streams":{"account:\#(me)":0}}
        """#
        routes.set("/v1/me", meJSON)
        routes.set("/v1/server", #"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels"]}"#)
        ChatStubProtocol.reset { request, _ in
            let path = request.url?.path ?? ""
            let full = path + (request.url?.query.map { "?\($0)" } ?? "")
            if full == routes.gated { routes.gate?.pass() }
            if let (status, body) = routes.answer(full) ?? routes.answer(path) {
                return .success(.init(status: status, body: body))
            }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
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
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-anna", deviceName: "Mac", orgId: org), token: "aps_t")
        try await service.start(mode: .server)
        try await waitUntil { !transports.all.isEmpty }
        let transport = transports.all[0]
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil { !transport.subscribes.isEmpty }
        var answered = 0
        for _ in 0..<5 {
            for streams in transport.subscribes.dropFirst(answered) {
                for (stream, head) in streams { transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(head)}"#) }
            }
            answered = transport.subscribes.count
            try await Task.sleep(for: .milliseconds(20))
        }
        return (service, transports)
    }

    private func ids(_ service: ChatService) throws -> Set<String> {
        Set(try XCTUnwrap(service.orgSessions[key]?.store).channels().map(\.channelId))
    }

    private func readOpen(_ service: ChatService) throws -> Bool {
        try XCTUnwrap(service.orgSessions[key]?.store).queue.read { try Bool.fetchOne($0, sql: "SELECT channels_read_open FROM meta") ?? false }
    }

    // MARK: The cache alone

    private func store() throws -> ChatStore {
        let store = try ChatStore.open(files: files, key: key).store
        try store.apply(ChatSnapshot(cursors: [teamStream: 0], orgName: "R", members: [], teams: [.init(teamId: team, name: "Billing", mine: true)],
                                     teamMembers: [], invitations: nil, channels: [], channelsComplete: true))
        return store
    }

    private func event(_ seq: Int, _ type: String, _ json: String, stream: String? = nil) throws -> ChatEvent {
        let frame = #"{"stream":"\#(stream ?? teamStream)","seq":\#(seq),"id":"e\#(seq)","type":"\#(type)","actor":null,"body":\#(json),"command_id":null,"at":"2026-10-05T09:00:00Z"}"#
        return try JSONDecoder().decode(ChatEvent.self, from: Data(frame.utf8))
    }

    /// Events of channels are wholly applied — no snapshot asked for each
    /// (before F2 every one was passed over), by the rule of versions.
    func testChannelEventsAreAppliedByVersion() throws {
        let store = try store()
        XCTAssertEqual(try store.apply(event(1, "channel.create", card("c1", "billing"))), .applied)
        XCTAssertEqual(try store.apply(event(2, "channel.rename", card("c1", "money", version: 3))), .applied)
        XCTAssertEqual(try store.apply(event(3, "channel.rename", card("c1", "old", version: 2))), .applied)
        XCTAssertEqual(try store.channels().map(\.name), ["money"])
        XCTAssertEqual(try store.apply(event(4, "channel.archive", card("c1", "money", version: 4, archived: true))), .applied)
        XCTAssertEqual(try store.channels().first?.archived, true)
        let skipped = try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM skipped_events") }
        XCTAssertEqual(skipped, 0)
    }

    func testTheServerFixturesRead() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat")
        let state = try JSONDecoder().decode(ChatOrgState.self, from: Data(contentsOf: dir.appendingPathComponent("state_response.json")))
        XCTAssertNotNil(state.channels)
        let page = try JSONDecoder().decode(ChatChannelsPage.self, from: Data(contentsOf: dir.appendingPathComponent("channels_page_response.json")))
        XCTAssertEqual(page.channels.first?.name, "billing")
        XCTAssertNil(page.next)
        let event = try JSONDecoder().decode(ChatEvent.self, from: Data(contentsOf: dir.appendingPathComponent("event_channel_create.json")))
        XCTAssertNotNil(ChatChannels.card(event.body))
    }

    /// A card of a team the user is not in is not kept; leaving a team
    /// takes its channels.
    func testOnlyMyTeamsChannels() throws {
        let store = try store()
        XCTAssertEqual(try store.apply(channels: [ChatChannelCard(channelId: "x", teamId: other, name: "x", archived: false, version: 1)]), ["x"])
        XCTAssertTrue(try store.channels().isEmpty)
        _ = try store.apply(event(1, "channel.create", card("c1", "billing")))
        _ = try store.apply(event(2, "team.remove_member", #"{"team_id":"\#(team)","account_id":"\#(me)"}"#))
        XCTAssertTrue(try store.channels().isEmpty)
    }

    /// The read's end drops only cards of its starting slice it did not
    /// read: one an event wrote after the stamp stays; one read unchanged stays.
    func testTheEndOfAReadDropsOnlyItsStartingSlice() throws {
        let store = try store()
        _ = try store.apply(event(1, "channel.create", card("gone", "gone")))
        _ = try store.apply(event(2, "channel.create", card("same", "same")))
        let stamp = try store.channelStamp()
        _ = try store.apply(event(3, "channel.create", card("new", "new")))
        // "same" read again at the version kept: not written, still seen.
        let seen = try store.apply(channels: [ChatChannelCard(channelId: "same", teamId: team, name: "same", archived: false, version: 1)])
        try store.endChannelsRead(since: stamp, seen: seen)
        XCTAssertEqual(Set(try store.channels().map(\.channelId)), ["same", "new"])
    }

    /// A new server generation empties the cards and puts the rights in
    /// doubt: nothing is told "gone" before its snapshot.
    func testANewGenerationEmptiesTheCardsInDoubt() throws {
        let store = try store()
        _ = try store.apply(event(1, "channel.create", card("c1", "billing")))
        try store.beginGeneration("g2", keeping: [])
        XCTAssertTrue(try store.channels().isEmpty)
        XCTAssertEqual(try store.queue.read { try Bool.fetchOne($0, sql: "SELECT rights_in_doubt FROM meta") }, true)
    }

    // MARK: The read of the snapshot and its pages

    func testSnapshotAndTwoPagesAllStay() async throws {
        let routes = ChannelRoutes()
        routes.set("/v1/orgs/\(org)/state", state([card("c1", "one")], next: "p1"))
        routes.set("/v1/orgs/\(org)/channels?after=p1", page([card("c2", "two")], next: "p2"))
        routes.set("/v1/orgs/\(org)/channels?after=p2", page([card("c3", "three")], next: nil))
        let (service, _) = try await started(routes)
        try await waitUntil { (try? self.ids(service)) == ["c1", "c2", "c3"] }
        XCTAssertFalse(try readOpen(service))
    }

    /// A cut-off read drops nothing and stays open: a card it did not reach
    /// is "checking", not "gone".
    func testACutOffReadDropsNothing() async throws {
        let routes = ChannelRoutes()
        routes.set("/v1/orgs/\(org)/state", state([card("c1", "one"), card("old", "old")], next: nil))
        let (service, _) = try await started(routes)
        try await waitUntil { (try? self.ids(service)) == ["c1", "old"] }
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        routes.set("/v1/orgs/\(org)/state", state([card("c1", "one")], next: "p1"))
        routes.set("/v1/orgs/\(org)/channels?after=p1", #"{"error":{"code":"internal"}}"#, status: 500)
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.query == "after=p1" } }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(try ids(service).contains("old"), "nothing dropped before the read's end")
        XCTAssertTrue(try readOpen(service))
        XCTAssertTrue(sync.needsSnapshot)
    }

    /// A page read while the user was taken out of the team: not applied,
    /// and the snapshot is owed again (review F2-3).
    func testAPageReadBeforeARevocationIsNotApplied() async throws {
        let routes = ChannelRoutes()
        routes.set("/v1/orgs/\(org)/state", state([], next: nil))
        let (service, transports) = try await started(routes)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !sync.needsSnapshot }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/channels?after=p1"
        routes.set("/v1/orgs/\(org)/state", state([], next: "p1"))
        routes.set("/v1/orgs/\(org)/channels?after=p1", page([card("late", "late")], next: nil))
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.query == "after=p1" } }
        // Out of the team while the page is out.
        transports.all[0].frame(eventFrame(4, "team.remove_member", #"{"team_id":"\#(team)","account_id":"\#(me)"}"#))
        try await Task.sleep(for: .milliseconds(100))
        // The server's word now: out of the team. The page held still has the channel.
        routes.set("/v1/orgs/\(org)/state", state([], next: "p1", mine: false))
        let asked = ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/state") == true }.count
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(try ids(service).contains("late"))
        XCTAssertGreaterThan(ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/state") == true }.count, asked,
                             "the read is void: the snapshot is asked again")
    }

    /// A channel an event creates while the read is under way — or between
    /// the snapshot's ask and its answer — outlives the read's end
    /// (review F2-5, F2b-2).
    func testAChannelCreatedDuringTheReadStays() async throws {
        let routes = ChannelRoutes()
        routes.set("/v1/orgs/\(org)/state", state([], next: nil))
        let (service, transports) = try await started(routes)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !sync.needsSnapshot }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/state"
        // The answer was read before the channel was made: it has not it.
        routes.set("/v1/orgs/\(org)/state", state([], next: nil, teamSeq: 3))
        sync.requestSnapshot()
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path.hasSuffix("/state") == true }.count >= 2 }
        transports.all[0].frame(eventFrame(4, "channel.create", card("made", "made")))
        try await waitUntil { (try? self.ids(service))?.contains("made") == true }
        gate.open()
        try await waitUntil { !sync.needsSnapshot }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try ids(service).contains("made"))
    }

    // MARK: What may be shown

    private func model(_ view: ChatOrgView, doubt: Bool = false, owed: Bool = false) -> ChatOrgModel {
        let model = ChatOrgModel(me: me) { _, _ in "c" }
        model.key = key
        model.snapshotOwed = { owed }
        var view = view
        view.rightsInDoubt = doubt
        model.set(view)
        return model
    }

    private func view(_ cards: [ChatChannelCard], open: Bool = false, served: Bool = true, role: String = "member",
                      teamArchived: Bool = false, mine: Bool = true) -> ChatOrgView {
        ChatOrgView(orgName: "R", members: [.init(accountId: me, handle: "anna", name: "Anna", role: role)],
                    teams: [.init(teamId: team, name: "Billing", isGeneral: false, archived: teamArchived, mine: mine, members: [me])],
                    channels: cards, channelsServed: served, channelsReadOpen: open)
    }

    private func cardValue(_ id: String, _ name: String, archived: Bool = false, by: String? = nil) -> ChatChannelCard {
        ChatChannelCard(channelId: id, teamId: team, name: name, createdBy: by ?? me, archived: archived, version: 1)
    }

    /// The tab's states, in their order: context, rights, server, card (review F2-2).
    func testTabStates() {
        let ref = ChannelRef(key, channel: "c1")
        let card = cardValue("c1", "billing")
        XCTAssertEqual(ChannelTabState.of(ref, model: nil), .notConnected)
        XCTAssertEqual(ChannelTabState.of(ChannelRef(server: ref.server, account: "someone", org: org, channel: "c1"), model: model(view([card]))),
                       .notConnected, "another account's tab")
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([card]), doubt: true)), .checking, "a card kept, but rights in doubt")
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([card], served: false))), .noChannels)
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([card]))), .ready(card, team: "Billing", offline: false))
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([], open: true))), .checking, "the read is not done")
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([]))), .noAccess)
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([]), doubt: true)), .checking)
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([card]))).title, "#billing")
        XCTAssertEqual(ChannelTabState.of(ref, model: model(view([card]), doubt: true)).title, "Channel")
    }

    /// Who may do what, as the server decides it (F-API "Commands").
    func testChannelRights() throws {
        let mine = cardValue("c1", "mine"), theirs = cardValue("c2", "theirs", by: "someone"),
            archived = cardValue("c3", "old", archived: true)
        let member = model(view([mine, theirs, archived]))
        let team = try XCTUnwrap(member.myTeams.first)
        XCTAssertTrue(member.canCreateChannel(in: team))
        XCTAssertTrue(member.canRenameChannel(mine))
        XCTAssertFalse(member.canRenameChannel(theirs))
        XCTAssertFalse(member.canArchiveChannel(mine))
        XCTAssertFalse(member.canRenameChannel(archived))
        let admin = model(view([mine, theirs], role: "admin"))
        XCTAssertTrue(admin.canRenameChannel(theirs))
        XCTAssertTrue(admin.canArchiveChannel(theirs))
        let doubting = model(view([mine]), doubt: true)
        XCTAssertFalse(doubting.canCreateChannel(in: team))
        XCTAssertFalse(doubting.canRenameChannel(mine))
        XCTAssertTrue(doubting.channels(of: team).isEmpty, "no channel listed in doubt")
        XCTAssertNotNil(ChatOrgModel.channelNameProblem(""))
        XCTAssertNotNil(ChatOrgModel.channelNameProblem(String(repeating: "я", count: 65)))
        XCTAssertNil(ChatOrgModel.channelNameProblem(String(repeating: "я", count: 64)))
        XCTAssertThrowsError(try member.createChannel(" ", in: team))
    }

    func testRefusalsInWords() {
        let card = cardValue("c1", "billing")
        let shown = model(view([card]))
        let refusal = ChatOrgView.Refusal(commandId: "x", type: "channel.rename", args: ["channel_id": .string("c1")], code: "name_taken")
        XCTAssertEqual(shown.describe(refusal), "Rename #billing")
        XCTAssertEqual(ChatOrgModel.reason("name_taken"), "That name is taken in this team")
        XCTAssertEqual(ChatOrgModel.reason("channel_archived"), "The channel is archived")
        XCTAssertEqual(model(view([]), doubt: true).describe(refusal), "Rename a channel", "no name the user may not see")
    }

    /// A command's answer writes no card (review F2b-1): a late answer of a
    /// rename after the user left the team brings nothing back.
    func testALateAnswerWritesNoCard() async throws {
        let routes = ChannelRoutes()
        routes.set("/v1/orgs/\(org)/state", state([card("c1", "billing")], next: nil))
        routes.set("/v1/commands", #"{"result":{"channel":\#(card("c1", "renamed", version: 2))}}"#)
        let (service, transports) = try await started(routes)
        try await waitUntil { (try? self.ids(service)) == ["c1"] }
        transports.all[0].frame(eventFrame(4, "team.remove_member", #"{"team_id":"\#(team)","account_id":"\#(me)"}"#))
        try await waitUntil { (try? self.ids(service))?.isEmpty == true }
        _ = try service.enqueue(key, type: "channel.rename", args: .object(["channel_id": .string("c1"), "name": .string("renamed")]))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try ids(service).isEmpty)
    }

    // MARK: Review F2, round 1: names only from what may be seen now

    /// A snapshot owed or under way — its pages too — shows no channel, even
    /// with its card kept (review F2-p1-4).
    func testNothingShownWhileASnapshotIsOwed() throws {
        let card = cardValue("c1", "billing")
        let owed = model(view([card]), owed: true)
        XCTAssertEqual(ChannelTabState.of(ChannelRef(key, channel: "c1"), model: owed), .checking)
        XCTAssertNil(owed.channelName("c1"))
        XCTAssertTrue(owed.channelTeams.isEmpty)
        XCTAssertEqual(ChannelTabState.of(ChannelRef(key, channel: "c1"), model: model(view([]), owed: true)), .checking, "not \"no access\"")
    }

    /// The name a refused create carries is shown only while its team may be (review F2-p1-1).
    func testARefusedCreateIsNamedOnlyWhileItsTeamIsSeen() {
        let refusal = ChatOrgView.Refusal(commandId: "x", type: "channel.create",
                                          args: ["team_id": .string(team), "name": .string("secret")], code: "name_taken")
        XCTAssertEqual(model(view([])).describe(refusal), "Create channel #secret in Billing")
        for hidden in [model(view([]), doubt: true), model(view([]), owed: true), model(view([], mine: false))] {
            XCTAssertEqual(hidden.describe(refusal), "Create a channel in a team no longer available")
        }
    }

    /// An archived team's channels stay listed, read only (review F2-p2-5).
    func testAnArchivedTeamsChannelsStay() throws {
        let card = cardValue("c1", "billing", archived: true)
        let shown = model(view([card], teamArchived: true))
        let archivedTeam = try XCTUnwrap(shown.channelTeams.first)
        XCTAssertTrue(archivedTeam.archived)
        XCTAssertEqual(shown.channels(of: archivedTeam).map(\.channelId), ["c1"])
        XCTAssertFalse(shown.canCreateChannel(in: archivedTeam))
        XCTAssertEqual(ChannelTabState.of(ChannelRef(key, channel: "c1"), model: shown).title, "#billing")
    }
}
