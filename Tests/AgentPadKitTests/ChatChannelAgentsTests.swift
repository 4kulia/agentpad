import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// F5: the agents of a channel, a channel's request and an agent's message
/// in the cache (DESIGN-F5 §1, §3).
@MainActor
final class ChatChannelAgentsTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let me = CallJSON.anna
    private let team = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private let agent = CallJSON.agent

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-channel-agents-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: me, orgId: org) }

    private func store(agents: [ChatChannelAgentWire]? = nil, channels: [ChatChannelCard] = [], complete: Bool = true) throws -> ChatStore {
        let store = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("chat")), key: key).store
        try store.apply(ChatSnapshot(cursors: ["team:\(team)": 0], orgName: "R",
                                     members: [.init(accountId: me, handle: "anna", name: "Anna", role: "member")],
                                     teams: [.init(teamId: team, name: "Billing", mine: true)],
                                     teamMembers: [.init(teamId: team, accountId: me)], invitations: nil,
                                     channels: channels, channelsComplete: complete, agentChannels: agents))
        // No page left: the read ends, as the sync ends it.
        if complete { try store.endChannelsRead(since: 0, seen: Set(channels.map(\.channelId))) }
        return store
    }

    private func channel(_ id: String) -> ChatChannelCard {
        ChatChannelCard(channelId: id, teamId: team, name: id, archived: false, version: 1)
    }

    private func card(name: String = "billing", available: Bool = true) -> [String: Any] {
        ["agent_id": agent, "owner_account_id": me, "name": name, "description": "Knows billing.", "access": "read-git",
         "enabled": true, "disabled_by": NSNull(), "executor_session_id": "s-anna", "executor_device_name": "Anna's Mac",
         "available": available]
    }

    private func listed(_ channel: String) -> ChatChannelAgentWire {
        let data = try! JSONSerialization.data(withJSONObject: ["agent_id": agent, "channel_id": channel, "added_by": me,
                                                                "added_at": "2026-10-05T09:00:00Z", "agent": card()])
        return try! JSONDecoder().decode(ChatChannelAgentWire.self, from: data)
    }

    private func skipped(_ store: ChatStore) throws -> Int {
        try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM skipped_events") ?? 0 }
    }

    /// The channel's stream adds, renews and removes its agents — each
    /// event wholly applied, none a reason for a snapshot; the card of a
    /// channel is not the personal catalog's.
    func testAgentsFollowTheChannelsStream() throws {
        let store = try store(channels: [channel("c1")])
        let stream = "channel:c1"
        XCTAssertEqual(try store.apply(CallJSON.event(stream, 1, "agent.add_to_channel", [
            "agent_id": agent, "channel_id": "c1", "added_by": me, "consent": "…", "agent": card(),
        ])), .applied)
        XCTAssertEqual(try store.channelAgents("c1").map(\.address), ["billing@anna"])
        XCTAssertEqual(try store.apply(CallJSON.event(stream, 2, "agent.publish", card(name: "money", available: false))), .applied)
        let renewed = try XCTUnwrap(store.channelAgents("c1").first)
        XCTAssertEqual(renewed.name, "money")
        XCTAssertFalse(renewed.available)
        XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agents_catalog") }, 0)
        XCTAssertEqual(try store.apply(CallJSON.event(stream, 3, "agent.remove_from_channel",
                                                      ["agent_id": agent, "channel_id": "c1", "cause": NSNull()])), .applied)
        XCTAssertTrue(try store.channelAgents("c1").isEmpty)
        XCTAssertEqual(try skipped(store), 0)
    }

    /// An add whose card names another agent or channel is not taken.
    func testAnAddForAnotherChannelIsNotTaken() throws {
        let store = try store(channels: [channel("c1")])
        XCTAssertEqual(try store.apply(CallJSON.event("channel:c1", 1, "agent.add_to_channel", [
            "agent_id": agent, "channel_id": "c2", "added_by": me, "consent": "…", "agent": card(),
        ])), .passedOver)
        XCTAssertTrue(try store.channelAgents("c1").isEmpty)
    }

    /// The snapshot's list is whole: an agent of a channel a later page
    /// brings stays until the read ends; then those of channels not brought go.
    func testTheSnapshotsListWaitsForThePages() throws {
        let store = try store(agents: [listed("c1"), listed("c2"), listed("c3")], channels: [channel("c1")], complete: false)
        let stamp = try store.channelStamp()
        XCTAssertEqual(try store.channelAgents("c1").count, 1)
        // A card dropped during the read: the agents of the pages still to come stay.
        try store.queue.write { db in try ChatMessages.dropOrphans(db) }
        let seen = try store.apply(channels: [channel("c2")])
        XCTAssertEqual(try store.channelAgents("c2").count, 1)
        try store.endChannelsRead(since: stamp, seen: seen.union(["c1"]))
        XCTAssertEqual(try store.queue.read { try String.fetchAll($0, sql: "SELECT channel_id FROM agent_channels ORDER BY 1") }, ["c1", "c2"])
    }

    /// The agents go with their channel: out of its team, nothing of them stays.
    func testAgentsGoWithTheirChannel() throws {
        let store = try store(agents: [listed("c1")], channels: [channel("c1")])
        XCTAssertEqual(try store.channelAgents("c1").count, 1)
        _ = try store.apply(CallJSON.event("team:\(team)", 1, "team.remove_member", ["team_id": team, "account_id": me]))
        XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_channels") }, 0)
    }

    /// A channel's request: the signal without text tells its kind and
    /// channel; the whole form from the channel's stream its thread and
    /// text; `result.publish` its publication — none passed over.
    func testAChannelsRequestKeepsItsPlaceAndPublication() throws {
        let store = try store(channels: [channel("c1")])
        var signal = CallJSON.request("r1", state: "submitted", version: 1, fixed: false)
        signal["kind"] = "channel"
        signal["channel_id"] = "c1"
        signal["publication"] = NSNull()
        XCTAssertEqual(try store.apply(CallJSON.event("member:\(org):\(me)", 1, "request.create", signal)), .applied)
        var request = try XCTUnwrap(store.calls.request("r1"))
        XCTAssertEqual(request.kind, "channel")
        XCTAssertEqual(request.channelId, "c1")
        XCTAssertFalse(request.hasFixed)

        var whole = CallJSON.request("r1", state: "submitted", version: 1)
        whole["kind"] = "channel"
        whole["channel_id"] = "c1"
        whole["thread_root_id"] = "m1"
        XCTAssertEqual(try store.apply(CallJSON.event("channel:c1", 1, "request.create", whole)), .applied)
        request = try XCTUnwrap(store.calls.request("r1"))
        XCTAssertTrue(request.hasFixed)
        XCTAssertEqual(request.threadRootId, "m1")
        XCTAssertEqual(request.text, "Why twice?")

        var published = CallJSON.request("r1", state: "finished", version: 7, fixed: false, runId: "run1")
        published["publication"] = "published"
        published["publish_reason"] = NSNull()
        published["message_id"] = "m9"
        XCTAssertEqual(try store.apply(CallJSON.event("channel:c1", 2, "result.publish", published)), .applied)
        request = try XCTUnwrap(store.calls.request("r1"))
        XCTAssertEqual(request.publication, "published")
        var failed = CallJSON.request("r1", state: "finished", version: 8, fixed: false, runId: "run1")
        failed["publication"] = "publish_failed"
        failed["publish_reason"] = "initiator_left_team"
        XCTAssertEqual(try store.apply(CallJSON.event("channel:c1", 3, "result.publish", failed)), .applied)
        request = try XCTUnwrap(store.calls.request("r1"))
        XCTAssertEqual(request.publishReason, "initiator_left_team")
        XCTAssertEqual(try skipped(store), 0)
    }

    // MARK: Adding and removing (the model)

    private func model(role: String = "member", served: Bool = true, archived: Bool = false, doubt: Bool = false,
                       there: [ChatChannelAgent] = [], mine: [ChatAgentCard]) -> ChatOrgModel {
        let model = ChatOrgModel(me: me) { _, _ in "c" }
        model.key = key
        model.snapshotOwed = { false }
        var view = ChatOrgView(orgName: "R", members: [.init(accountId: me, handle: "anna", name: "Anna", role: role)],
                               teams: [.init(teamId: team, name: "Billing", isGeneral: false, archived: false, mine: true, members: [me])],
                               channels: [ChatChannelCard(channelId: "c1", teamId: team, name: "billing", archived: archived, version: 1)],
                               channelsServed: true)
        view.rightsInDoubt = doubt
        view.channelAgents = there
        view.myAgents = mine
        view.agentsServed = served
        model.set(view)
        return model
    }

    private func catalogCard(_ id: String, owner: String? = nil, enabled: Bool = true, access: String = "read") -> ChatAgentCard {
        ChatAgentCard(agentId: id, ownerAccountId: owner ?? me, name: "agent-\(id)", description: "", access: access, enabled: enabled,
                      available: true)
    }

    private func inChannel(_ id: String, owner: String) -> ChatChannelAgent {
        ChatChannelAgent(channelId: "c1", agentId: id, name: "agent-\(id)", ownerAccountId: owner, ownerHandle: "h", description: "",
                         access: "read", enabled: true, available: true)
    }

    /// Only the user's own enabled agents not in the channel are offered; none
    /// without the server's agents, in an archived channel or with rights in doubt.
    func testMissingAgentMentionsUseExistingAddPermissions() throws {
        let agent = catalogCard("a2")
        let member = model(mine: [agent])
        let text = "@agent-a2@anna @AGENT-A2@ANNA"
        let hint = try XCTUnwrap(member.missingAgentMentions(in: text, channel: "c1", catalog: [agent, agent]).first)
        XCTAssertEqual(hint.address, "agent-a2@anna")
        XCTAssertTrue(hint.canAdd)
        XCTAssertEqual(member.missingAgentMentions(in: text, channel: "c1", catalog: [agent, agent]).count, 1)
        for text in ["`@agent-a2@anna`", "> @agent-a2@anna", "@agent-a2@anna-x", "\\@agent-a2@anna"] {
            XCTAssertTrue(member.missingAgentMentions(in: text, channel: "c1", catalog: [agent]).isEmpty)
        }
        let archived = model(archived: true, mine: [agent])
        XCTAssertFalse(try XCTUnwrap(archived.missingAgentMentions(in: text, channel: "c1", catalog: [agent]).first).canAdd)
        let disabled = catalogCard("a2", enabled: false)
        XCTAssertFalse(try XCTUnwrap(model(mine: [disabled]).missingAgentMentions(in: text, channel: "c1", catalog: [disabled]).first).canAdd)
        XCTAssertTrue(model(doubt: true, mine: [agent]).missingAgentMentions(in: text, channel: "c1", catalog: [agent]).isEmpty)
        XCTAssertTrue(model(served: false, mine: [agent]).missingAgentMentions(in: text, channel: "c1", catalog: [agent]).isEmpty)
        XCTAssertTrue(model(there: [inChannel("a2", owner: me)], mine: [agent]).missingAgentMentions(in: text, channel: "c1", catalog: [agent]).isEmpty)
        // Organization admins still cannot add somebody else's agent.
        let admin = model(role: "admin", mine: [])
        var view = admin.view
        view.members.append(.init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member"))
        admin.set(view)
        let other = catalogCard("b2", owner: CallJSON.boris)
        let foreign = try XCTUnwrap(admin.missingAgentMentions(in: "@agent-b2@boris", channel: "c1", catalog: [other]).first)
        XCTAssertFalse(foreign.canAdd)
        XCTAssertEqual(foreign.guidance, "Ask its owner to add it before requesting an answer.")
    }

    func testWhoMayAddAndRemove() throws {
        let card = ChatChannelCard(channelId: "c1", teamId: team, name: "billing", archived: false, version: 1)
        let mineThere = inChannel("a1", owner: me), theirs = inChannel("b1", owner: CallJSON.boris)
        let member = model(there: [mineThere, theirs], mine: [catalogCard("a1"), catalogCard("a2"), catalogCard("a3", enabled: false)])
        XCTAssertEqual(member.addableAgents(card).map(\.agentId), ["a2"])
        XCTAssertTrue(member.canRemoveAgent(mineThere))
        XCTAssertFalse(member.canRemoveAgent(theirs), "a member removes only its own agent")
        XCTAssertThrowsError(try member.addAgent("a1", to: card), "already in it")
        XCTAssertTrue(model(role: "admin", there: [theirs], mine: []).canRemoveAgent(theirs))
        XCTAssertTrue(model(served: false, mine: [catalogCard("a2")]).addableAgents(card).isEmpty)
        XCTAssertTrue(model(served: false, there: [theirs], mine: []).agents(in: "c1").isEmpty)
        XCTAssertTrue(model(archived: true, mine: [catalogCard("a2")]).addableAgents(card).isEmpty)
        let doubting = model(doubt: true, there: [mineThere], mine: [catalogCard("a2")])
        XCTAssertTrue(doubting.addableAgents(card).isEmpty)
        XCTAssertFalse(doubting.canRemoveAgent(mineThere))
    }

    /// The window says who sees the answers and the rights with their warnings.
    func testTheAddWindowSaysWhatTheOwnerAgreesTo() {
        let shell = ChatOrgSidebarSection.addAgentText(catalogCard("a1", access: "read-git"), team: "Billing", fromSession: true)
        XCTAssertTrue(shell.contains("members of team Billing"))
        XCTAssertTrue(shell.contains(TeamAccessProfile.shellWarning))
        XCTAssertTrue(shell.contains(TeamPublishWarnings.session))
        let plain = ChatOrgSidebarSection.addAgentText(catalogCard("a2", access: "read"), team: "Billing", fromSession: false)
        XCTAssertFalse(plain.contains(TeamAccessProfile.shellWarning))
        XCTAssertFalse(plain.contains(TeamPublishWarnings.session))
    }

    /// An agent's message keeps its agent and run.
    func testAnAgentsMessageKeepsItsAgent() throws {
        let store = try store(channels: [channel("c1")])
        let message = #"{"message_id":"m1","channel_id":"c1","thread_root_id":"m0","author_account_id":"\#(me)","author_agent_id":"\#(agent)","run_id":"run1","text":"It was refunded twice.","mentions":[],"revision":1,"seq":1,"created_at":"2026-10-05T09:00:00Z","edited_at":null,"deleted_at":null}"#
        let frame = #"{"stream":"channel:c1","seq":1,"id":"e1","type":"message.post","actor":null,"body":{"message_id":"m1","revision":1,"message_seq":1},"command_id":null,"at":"2026-10-05T09:00:00Z","message":\#(message)}"#
        XCTAssertEqual(try store.apply(JSONDecoder().decode(ChatEvent.self, from: Data(frame.utf8))), .applied)
        let row = try store.queue.read { try Row.fetchOne($0, sql: "SELECT author_agent_id, run_id FROM messages WHERE message_id = 'm1'") }
        XCTAssertEqual(row?["author_agent_id"] as String?, agent)
        XCTAssertEqual(row?["run_id"] as String?, "run1")
    }

    // MARK: Asking (F5 §2)

    private func agentNamed(_ name: String, handle: String, enabled: Bool = true) -> ChatChannelAgent {
        ChatChannelAgent(channelId: "c1", agentId: "id-\(name)", name: name, ownerAccountId: me, ownerHandle: handle, description: "",
                         access: "read", enabled: enabled, available: true)
    }

    private func shown(_ id: String, seq: Int?, text: String = "hi", deleted: Bool = false, sending: Bool = false) -> ChatMessage {
        ChatMessage(row: Row([
            "message_id": id, "channel_id": "c1", "thread_root_id": nil, "author_account_id": me, "seq": seq,
            "created_at": "2026-10-05T09:00:00Z", "has_fixed": !sending, "has_mutable": !sending, "text": deleted ? "" : text,
            "mentions": "[]", "revision": 2, "edited_at": nil, "deleted_at": deleted ? "2026-10-05T10:00:00Z" : nil,
            "stale": nil, "local_state": sending ? "sending" : nil, "local_error": nil, "author_agent_id": nil,
        ]))
    }

    /// `@name@handle` of an enabled agent of the channel, whole — not part
    /// of a longer address or word.
    func testTheAddressAsksTheAgent() {
        let billing = agentNamed("billing", handle: "anna"), ops = agentNamed("ops", handle: "boris", enabled: false)
        XCTAssertEqual(ChatChannelAsk.asked(in: "@billing@anna why twice?", agents: [billing, ops]).map(\.name), ["billing"])
        XCTAssertEqual(ChatChannelAsk.asked(in: "ask @Billing@Anna.", agents: [billing]).map(\.name), ["billing"])
        XCTAssertTrue(ChatChannelAsk.asked(in: "@billing@annabel", agents: [billing]).isEmpty)
        XCTAssertTrue(ChatChannelAsk.asked(in: "x@billing@anna", agents: [billing]).isEmpty)
        XCTAssertTrue(ChatChannelAsk.asked(in: "@billing", agents: [billing]).isEmpty, "the address is name@handle")
        XCTAssertTrue(ChatChannelAsk.asked(in: "@ops@boris", agents: [ops]).isEmpty, "a disabled agent is not offered")
    }

    /// The root first, then in order; at most 20 messages and 48 KiB; what
    /// is not the server's as it is now never goes.
    func testTheContextFitsItsLimits() {
        var chosen = (1...25).map { (i: Int) in shown("m\(i)", seq: i) }
        chosen.append(shown("gone", seq: 30, deleted: true))
        chosen.append(shown("sending", seq: nil, sending: true))
        let fit = ChatChannelAsk.fit(chosen, root: "m7")
        XCTAssertEqual(fit.taken.count, ChatChannelAsk.maxContext)
        XCTAssertEqual(fit.taken.first?.messageId, "m7")
        XCTAssertEqual(fit.taken.dropFirst().first?.messageId, "m1")
        XCTAssertEqual(fit.cut.map(\.messageId), ["m21", "m22", "m23", "m24", "m25"])
        let big = String(repeating: "x", count: 30 * 1024)
        let bytes = ChatChannelAsk.fit([shown("a", seq: 1, text: big), shown("b", seq: 2, text: big), shown("c", seq: 3)], root: "b")
        XCTAssertEqual(bytes.taken.map(\.messageId), ["b", "c"])
        XCTAssertEqual(bytes.cut.map(\.messageId), ["a"])
    }

    /// The command names the channel, the thread the agent answers in, and
    /// only references of the context — never its text.
    func testTheRequestCarriesReferencesOnly() throws {
        let args = ChatChannelAsk.args(requestId: "r1", agentId: agent, channel: "c1", root: "m1", text: "Why twice?",
                                       context: [shown("m1", seq: 1, text: "secret context")])
        let data = try JSONEncoder().encode(args)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["channel_id"] as? String, "c1")
        XCTAssertEqual(json["thread_root_id"] as? String, "m1")
        XCTAssertEqual(json["conditions_version"] as? Int, 1)
        XCTAssertEqual((json["context"] as? [[String: Any]])?.first?["revision"] as? Int, 2)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret context"))
        XCTAssertNotNil(ChatChannelAsk.textProblem(" "))
        XCTAssertNotNil(ChatChannelAsk.textProblem(String(repeating: "x", count: 32 * 1024 + 1)))
    }

    /// The asks of a channel the queue holds: its own only, living or
    /// refused and not dismissed, and only while the channel is kept.
    func testTheAsksOfAChannelFromTheQueue() throws {
        let store = try store(channels: [channel("c1")])
        func queued(_ channel: String, _ state: ChatCommandRecord.State, error: String? = nil) throws -> String {
            let id = ChatUUID.v7()
            let args = ChatChannelAsk.args(requestId: UUID().uuidString, agentId: agent, channel: channel, root: "m1", text: "q", context: [])
            var record = ChatCommandRecord(commandId: id, sessionId: "s1", type: ChatChannelAsk.commandType,
                                           bodyBytes: try ChatCommandEnvelope(commandId: id, org: org, type: ChatChannelAsk.commandType, args: args).encoded(),
                                           orderKey: org, dependsOn: nil, createdAt: Date(), state: state)
            record.error = error
            _ = try store.enqueue(record)
            return id
        }
        let living = try queued("c1", .pending)
        let refused = try queued("c1", .failed, error: "context_changed")
        _ = try queued("c2", .pending)
        _ = try queued("c1", .dropped)
        let asks = try store.queue.read { try ChatChannelAsk.asks($0, channel: "c1") }
        XCTAssertEqual(asks.map(\.commandId), [living, refused])
        XCTAssertEqual(asks.last?.failed, true)
        try store.outbox.dismiss([refused])
        XCTAssertEqual(try store.queue.read { try ChatChannelAsk.asks($0, channel: "c1") }.map(\.commandId), [living])
        _ = try store.apply(CallJSON.event("team:\(team)", 1, "team.remove_member", ["team_id": team, "account_id": me]))
        XCTAssertTrue(try store.queue.read { try ChatChannelAsk.asks($0, channel: "c1") }.isEmpty)
    }

    /// The requests of a thread: the channel's only, with their state in
    /// words; nothing once the channel is no longer kept.
    func testTheThreadsRequestsShowThroughTheChannel() throws {
        let store = try store(agents: [listed("c1")], channels: [channel("c1")])
        var asked = CallJSON.request("r1", state: "finished", version: 6)
        asked["kind"] = "channel"
        asked["channel_id"] = "c1"
        asked["thread_root_id"] = "m1"
        asked["publication"] = "publish_failed"
        asked["publish_reason"] = "initiator_left_team"
        _ = try store.apply(CallJSON.event("channel:c1", 1, "request.create", asked))
        var personal = CallJSON.request("r2", state: "running", version: 3)
        personal["thread_root_id"] = "m1"
        personal["channel_id"] = "c1"
        _ = try store.apply(CallJSON.event("member:\(org):\(me)", 1, "request.create", personal))
        let cards = try store.queue.read { try ChatChannelRequests.read($0, channel: "c1", root: "m1") }
        XCTAssertEqual(cards.map(\.requestId), ["r1"])
        XCTAssertEqual(cards.first?.agentName, "billing")
        XCTAssertEqual(cards.first?.stateWord, "done · not published: the person who asked left the team")
        XCTAssertEqual(try store.queue.read { try ChatChannelRequests.counts($0, channel: "c1", roots: ["m1", "m2"]) }, ["m1": 1])
        _ = try store.apply(CallJSON.event("team:\(team)", 1, "team.remove_member", ["team_id": team, "account_id": me]))
        XCTAssertTrue(try store.queue.read { try ChatChannelRequests.read($0, channel: "c1", root: "m1") }.isEmpty)
        XCTAssertEqual(try store.calls.request("r1")?.text, "", "no text of a channel no longer seen")
        XCTAssertEqual(try store.calls.request("r2")?.text, "Why twice?", "a personal request keeps its text")
    }
}
