import Foundation
import GRDB

/// What one role may do in an organization (docs/agentpad/CHAT-PLAN.md C6,
/// the table of A5): the window shows only these. The server decides; this
/// keeps a member from seeing buttons it could only be refused.
enum ChatOrgAction: String, CaseIterable, Sendable {
    // Everyone.
    case seeMembers, seeOwnTeams, seeDevices, closeSession, leaveTeam, setOwnName
    // Owners and admins.
    case seeAllTeams, invite, revokeInvitation, createTeam, renameTeam, archiveTeam
    case addTeamMember, removeTeamMember, joinTeam, setRole, removeMember, seeAudit

    static let everyone: Set<ChatOrgAction> = [.seeMembers, .seeOwnTeams, .seeDevices, .closeSession, .leaveTeam, .setOwnName]

    static func allowed(for role: String) -> Set<ChatOrgAction> {
        ChatOrgView.manages(role) ? Set(allCases) : everyone
    }
}

/// The organization as the cache has it, read in one transaction.
struct ChatOrgView: Equatable, Sendable {
    struct Member: Equatable, Sendable, Identifiable {
        var accountId, handle, name, role: String
        var id: String { accountId }
    }

    struct Team: Equatable, Sendable, Identifiable {
        var teamId, name: String
        var isGeneral: Bool
        var archived: Bool
        /// The signed-in member is in it.
        var mine: Bool
        var members: [String]
        var id: String { teamId }
    }

    /// A command of the window the server refused, as the send queue keeps
    /// it — across restarts and sends again (review C6 p2-4).
    struct Refusal: Equatable, Sendable, Identifiable {
        var commandId, type: String
        var args: [String: ChatJSON]
        var code: String
        var id: String { commandId }
    }

    var orgName: String?
    var members: [Member] = []
    var teams: [Team] = []
    /// Not accepted or revoked; the model leaves out the expired ones.
    var invitations: [ChatSnapshot.Invitation] = []
    /// The admin stream is followed: with a manager's role, the user manages.
    var followsAdmin = false
    /// A sign said the rights may have changed; no snapshot since (C6f).
    var rightsInDoubt = false
    /// The session whose snapshot confirmed the rights (C6i).
    var rightsSession: String?
    var refusals: [Refusal] = []
    /// F2: the channel cards kept (of the user's teams only).
    var channels: [ChatChannelCard] = []
    /// The last snapshot carried channels: the server has them.
    var channelsServed = false
    /// A read of the channels is under way or was cut off: a card missing
    /// now is not known to be gone.
    var channelsReadOpen = false
    /// `channel.create` commands not sent yet: (team, name).
    var creating: [(teamId: String, name: String)] = []
    /// F4: unread of each channel kept, and mentions not read.
    var unread: [String: ChatUnread.Count] = [:]
    var mentionsUnread = 0
    var mentionsByChannel: [String: Int] = [:]
    var unreadRepliesByChannel: [String: Int] = [:]
    /// F5: the agents of the channels kept; the user's own agents of the
    /// catalog (those it may add); the last snapshot carried them.
    var channelAgents: [ChatChannelAgent] = []
    var myAgents: [ChatAgentCard] = []
    var agentsServed = false

    static func == (a: ChatOrgView, b: ChatOrgView) -> Bool {
        guard a.unreadRepliesByChannel == b.unreadRepliesByChannel else { return false }
        return a.orgName == b.orgName && a.members == b.members && a.teams == b.teams && a.invitations == b.invitations
            && a.followsAdmin == b.followsAdmin && a.rightsInDoubt == b.rightsInDoubt && a.rightsSession == b.rightsSession
            && a.refusals == b.refusals && a.channels == b.channels && a.channelsServed == b.channelsServed
            && a.channelsReadOpen == b.channelsReadOpen && a.creating.elementsEqual(b.creating) { $0 == $1 }
            && a.unread == b.unread && a.mentionsUnread == b.mentionsUnread && a.mentionsByChannel == b.mentionsByChannel
            && a.channelAgents == b.channelAgents && a.myAgents == b.myAgents && a.agentsServed == b.agentsServed
    }

    static func manages(_ role: String) -> Bool { role == "owner" || role == "admin" }

    /// The window's command types: what its refusals are about.
    static let commandTypes = ChatStore.managerCommandTypes.union(["team.leave", "member.set_name"]).union(ChatChannels.eventTypes)
        .union(ChatChannelAgents.eventTypes)

    static func unread(_ db: Database) throws -> [String: ChatUnread.Count] {
        let me = try String.fetchOne(db, sql: "SELECT me FROM meta WHERE id = 1") ?? ""
        var all: [String: ChatUnread.Count] = [:]
        for channel in try String.fetchAll(db, sql: "SELECT channel_id FROM channels") {
            all[channel] = try ChatUnread.count(db, channel: channel, me: me)
        }
        return all
    }

    static func read(_ db: Database) throws -> ChatOrgView {
        let pairs = try Row.fetchAll(db, sql: "SELECT team_id, account_id FROM team_members")
        var inTeam: [String: [String]] = [:]
        for pair in pairs { inTeam[pair["team_id"], default: []].append(pair["account_id"]) }
        let types = commandTypes.map { "'\($0)'" }.joined(separator: ", ")
        let refused = try ChatCommandRecord.fetchAll(db, sql: """
            SELECT * FROM outbox WHERE state = 'failed' AND dismissed = 0 AND IFNULL(error, '') != 'dismissed' AND type IN (\(types)) ORDER BY seq
            """)
        let creating = try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM outbox WHERE state = 'pending' AND type = 'channel.create' ORDER BY seq")
            .compactMap { record -> (teamId: String, name: String)? in
                guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
                      let team = envelope.args["team_id"]?.string, let name = envelope.args["name"]?.string else { return nil }
                return (team, name)
            }
        let meta = try Row.fetchOne(db, sql: "SELECT channels_served, channels_read_open, agents_served, me FROM meta WHERE id = 1")
        let mentions = try ChatUnread.unreadMentionsByChannel(db)
        return ChatOrgView(
            orgName: try String.fetchOne(db, sql: "SELECT org_name FROM meta WHERE id = 1"),
            members: try Row.fetchAll(db, sql: "SELECT account_id, handle, name, role FROM members ORDER BY name COLLATE NOCASE, handle").map {
                Member(accountId: $0["account_id"], handle: $0["handle"], name: $0["name"], role: $0["role"])
            },
            teams: try Row.fetchAll(db, sql: "SELECT team_id, name, is_general, archived_at, mine FROM teams ORDER BY is_general DESC, name COLLATE NOCASE").map {
                let id: String = $0["team_id"]
                return Team(teamId: id, name: $0["name"], isGeneral: $0["is_general"], archived: ($0["archived_at"] as String?) != nil,
                            mine: $0["mine"], members: (inTeam[id] ?? []).sorted())
            },
            invitations: try Row.fetchAll(db, sql: "SELECT invitation_id, email, role, state, expires_at FROM invitations WHERE state = 'open' ORDER BY email").map {
                ChatSnapshot.Invitation(invitationId: $0["invitation_id"], email: $0["email"], role: $0["role"], state: $0["state"], expiresAt: $0["expires_at"])
            },
            followsAdmin: try ChatStore.followsAdmin(db),
            rightsInDoubt: try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") ?? false,
            rightsSession: try String.fetchOne(db, sql: "SELECT rights_session FROM meta WHERE id = 1"),
            refusals: refused.compactMap { record in
                guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
                      case .object(let args) = envelope.args else { return nil }
                return Refusal(commandId: record.commandId, type: record.type, args: args, code: record.error ?? "refused")
            },
            channels: try ChatChannels.read(db),
            channelsServed: meta?["channels_served"] ?? false,
            channelsReadOpen: meta?["channels_read_open"] ?? false,
            creating: creating,
            unread: try unread(db),
            mentionsUnread: mentions.values.reduce(0, +),
            mentionsByChannel: mentions,
            unreadRepliesByChannel: try ChatUnread.unreadRepliesByChannel(db),
            channelAgents: try String.fetchAll(db, sql: "SELECT channel_id FROM channels ORDER BY channel_id")
                .flatMap { try ChatChannelAgents.read(db, channel: $0) },
            myAgents: try ChatCallStore.catalog(db).filter { $0.ownerAccountId == (meta?["me"] as String?) },
            agentsServed: meta?["agents_served"] ?? false
        )
    }
}

/// The organization for the left panel and the Organization window (C6):
/// read from the cache whenever the feed changes it, never by polling;
/// changes go as commands through the send queue. It stands for one
/// (server, account, organization, session) and one cache: once any of them
/// changes it is no longer current, shows nothing and sends nothing
/// (review C6 group C).
@MainActor
@Observable
final class ChatOrgModel {
    let me: String
    private(set) var view = ChatOrgView()
    /// The log as read; shown only while the user may read it now.
    private var auditRead: [ChatAuditPage.Record]?
    var audit: [ChatAuditPage.Record]? { actions.contains(.seeAudit) ? auditRead : nil }
    private(set) var auditNext: Int?
    /// The last failure of reading the log.
    private(set) var problem: String?
    /// Now, as far as the open invitations go: moved on at the next expiry.
    private(set) var now = Date()

    /// Whether the model still stands for the connection and cache now.
    var isCurrent: @MainActor () -> Bool = { true }
    /// Queues a command of the organization; its id.
    var enqueue: @MainActor (String, ChatJSON) throws -> String
    var readAudit: @MainActor (Int?) async throws -> ChatAuditPage = { _ in ChatAuditPage(records: [], next: nil) }
    /// The user has read these refusals — those shown, no others.
    var dismissRefusals: @MainActor (Set<String>) -> Void = { _ in }
    /// A sign the user's rights may have changed — the log refused
    /// (`forbidden`) or not found (`not_found`): the organization's rights go
    /// in doubt (`ChatSync.rightsInDoubt`); for `not_found` `/v1/me` is read
    /// again (review C6e). Refused commands are signs taken by the send
    /// queue itself (`ChatFeed`), shown or not.
    var onRightsSign: @MainActor (String) -> Void = { _ in }
    /// The doubt could not be written to the cache yet: nothing of the
    /// organization is shown (review C6g p1-2).
    var storageProblem: @MainActor () -> Bool = { false }
    /// Failed writes of the doubt so far (`ChatOrgSession.doubtWriteFailures`).
    var problemEpoch: @MainActor () -> Int = { 0 }
    /// The session the model stands for: rights confirmed for another
    /// session do not count (review C6i p1-1). Nil in tests without one.
    var session: String?
    /// Delay before following the cache again after a failed read.
    var observationRetryDelay: (Int) -> TimeInterval = { n in min(30, pow(2, Double(n))) }
    var newTeamId: () -> String = { UUID().uuidString.lowercased() }
    /// The (server, account, organization) the model stands for; nil in tests without one.
    var key: ChatOrgKey?
    /// A snapshot is owed or under way: no channel is shown meanwhile (review F2-p1-4).
    var snapshotOwed: @MainActor () -> Bool = { false }
    /// Presentation only, with a short grace period across reconnects.
    var showsOffline: @MainActor () -> Bool = { false }

    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Reads of the log: an answer counts only for the latest (review C6 p2-5).
    @ObservationIgnored private var auditGeneration = 0
    @ObservationIgnored private var auditLoading = false
    @ObservationIgnored private weak var followed: ChatStore?
    @ObservationIgnored private var observationFailures = 0
    @ObservationIgnored private var observationRetry: Task<Void, Never>?
    /// The count of failed doubt writes when the current observation began:
    /// its views were read after them. One more failure, and no view of it
    /// is shown until it begins anew (review C6i p1-2).
    private var observedAtFailures = 0
    /// The last read of the cache failed: nothing is shown or done until one
    /// succeeds — no empty view stands for "allowed" (review C6i p1-3).
    private var readFailed = false

    init(me: String, enqueue: @escaping @MainActor (String, ChatJSON) throws -> String) {
        self.me = me
        self.enqueue = enqueue
    }

    /// Follows the cache: the view is read again after every change of it.
    /// A failed read stops GRDB's observation: the model shows nothing of
    /// the organization until it follows again, after a pause (review C6e p2-3).
    /// `.immediate`: the first view is read before this returns.
    func follow(_ store: ChatStore) {
        observationRetry?.cancel()
        followed = store
        observedAtFailures = problemEpoch()
        watchFailures()
        observation = ValueObservation.tracking(ChatOrgView.read)
            .start(in: store.queue, scheduling: .immediate, onError: { [weak self, weak store] error in
                guard let self else { return }
                self.observation = nil
                self.readFailed = true
                self.problem = "The organization could not be read here: \(error.localizedDescription)"
                self.observationFailures += 1
                let wait = self.observationRetryDelay(self.observationFailures)
                self.observationRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, !Task.isCancelled, let store else { return }
                    self.follow(store)
                }
            }, onChange: { [weak self] view in
                guard let self else { return }
                if self.observationFailures > 0 {
                    self.observationFailures = 0
                    self.problem = nil
                }
                self.readFailed = false
                self.set(view)
            })
    }

    /// A new view of the organization: what the user may no longer see goes
    /// with it (review C6 group A).
    func set(_ view: ChatOrgView) {
        // F4: notices are taken back by the service's reconcile, not here (review F4-A).
        let mentions = mentionsForBadge
        self.view = view
        if mentionsForBadge != mentions { ChatNotifications.badgeChanged() }
        narrow()
        scheduleExpiry()
    }

    /// A new failure of the doubt's write: the observation begins anew, so
    /// what is shown again was read after it.
    private func watchFailures() {
        withObservationTracking { _ = problemEpoch() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let store = self.followed, self.problemEpoch() != self.observedAtFailures else { return }
                self.follow(store)
            }
        }
    }

    /// Drops what the rights now do not allow, of what was read outside the
    /// cache: the security log, and any read of it on its way.
    private func narrow() {
        if actions.contains(.seeAudit) { return }
        auditRead = nil
        auditNext = nil
        auditGeneration += 1
        auditLoading = false
    }

    // MARK: What the user may see and do

    var myRole: String { view.members.first { $0.accountId == me }?.role ?? "member" }
    /// The cache may be shown: current, and no storage problem.
    var visible: Bool { isCurrent() && !readFailed && !storageProblem() && problemEpoch() == observedAtFailures }
    /// Rights are in doubt: a sign said they may have changed, and no
    /// snapshot read since was applied. Shown then: the organization's name,
    /// the user's own name, and that rights are being checked — no team,
    /// mine included (it may be out of date), and no action (review C6g p1-1).
    var inDoubt: Bool { view.rightsInDoubt || (session != nil && view.rightsSession != session) }
    /// A manager's role and the admin stream: without the stream, the user
    /// has not, or no longer, the data a manager acts on (review C6 p1-3).
    var manages: Bool { visible && !inDoubt && ChatOrgView.manages(myRole) && view.followsAdmin }
    var actions: Set<ChatOrgAction> {
        guard visible, !inDoubt else { return [] }
        return manages ? Set(ChatOrgAction.allCases) : ChatOrgAction.everyone
    }

    /// Teams shown: a manager sees all, anyone else only its own — also when
    /// the cache still holds others for a moment (the cache drops them, C6).
    var teams: [ChatOrgView.Team] { guard visible, !inDoubt else { return [] }; return manages ? view.teams : view.teams.filter(\.mine) }
    /// The left panel: the user's own teams in use.
    var myTeams: [ChatOrgView.Team] { visible && !inDoubt ? view.teams.filter { $0.mine && !$0.archived } : [] }
    var members: [ChatOrgView.Member] {
        guard visible else { return [] }
        return inDoubt ? view.members.filter { $0.accountId == me } : view.members
    }
    var orgName: String? { visible ? view.orgName : nil }
    /// Why less is shown than usual, if it is.
    var notice: String? {
        guard isCurrent() else { return nil }
        if readFailed { return problem }
        if storageProblem() || problemEpoch() != observedAtFailures { return "This Mac cannot save the organization's state right now; nothing of it is shown until it can." }
        return inDoubt ? "Your rights in the organization are being checked with the server." : nil
    }
    /// Open invitations: not expired (`ChatStore.isOpen`, the snapshot's rule).
    var invitations: [ChatSnapshot.Invitation] { manages ? view.invitations.filter { ChatStore.isOpen($0, now: now) } : [] }

    func member(_ id: String) -> ChatOrgView.Member? { members.first { $0.accountId == id } }
    private var owners: Int { view.members.filter { $0.role == "owner" }.count }

    // The rules below are the server's (teams.rs, member_set_role and
    // member_remove in migration 0023), one per command (review C6 group B).

    /// `team.leave`: a team the user is in, not General — archived or not.
    func canLeave(_ team: ChatOrgView.Team) -> Bool { actions.contains(.leaveTeam) && team.mine && !team.isGeneral }
    /// `team.join`: a manager, into a team it is not in, not archived.
    func canJoin(_ team: ChatOrgView.Team) -> Bool { manages && !team.mine && !team.archived }
    /// `team.rename`, `team.archive`: a manager; not General, not archived.
    func canChange(_ team: ChatOrgView.Team) -> Bool { manages && !team.isGeneral && !team.archived }
    /// `team.add_member`: a manager; not archived; a member not in it. The
    /// user itself joins (`team.join`), with its warning (review C6 p1-8).
    func candidates(for team: ChatOrgView.Team) -> [ChatOrgView.Member] {
        guard manages, !team.archived else { return [] }
        return view.members.filter { $0.accountId != me && !team.members.contains($0.accountId) }
    }
    /// `team.remove_member`: a manager; not General; the account in the
    /// team — archived or not — and still a member of the organization.
    func canRemoveMember(_ account: String, from team: ChatOrgView.Team) -> Bool {
        manages && !team.isGeneral && team.members.contains(account) && member(account) != nil
    }

    /// `member.set_role`: owners give any role, admins member ↔ admin and
    /// never an owner's; the last owner keeps its role.
    func roles(for target: ChatOrgView.Member) -> [String] {
        guard manages, !(target.role == "owner" && owners <= 1) else { return [] }
        switch myRole {
        case "owner": return ["owner", "admin", "member"].filter { $0 != target.role }
        case "admin" where target.role != "owner": return ["admin", "member"].filter { $0 != target.role }
        default: return []
        }
    }

    /// `member.remove`: owners anyone, admins not an owner; never the last owner.
    func canRemove(_ target: ChatOrgView.Member) -> Bool {
        guard manages, !(target.role == "owner" && owners <= 1) else { return false }
        return myRole == "owner" || target.role != "owner"
    }

    // MARK: Commands

    // Each command takes its target anew from the view now, by id: a
    // dialog's object may be out of date by the time it is confirmed
    // (review C6b p1-5); gone or no longer visible, it is refused here.

    private func team(_ team: ChatOrgView.Team) throws -> ChatOrgView.Team {
        guard let now = teams.first(where: { $0.teamId == team.teamId }) else { throw ChatOrgError.notAllowed }
        return now
    }

    private func member(_ target: ChatOrgView.Member) throws -> ChatOrgView.Member {
        guard let now = member(target.accountId) else { throw ChatOrgError.notAllowed }
        return now
    }

    func setName(_ name: String) throws {
        try require(actions.contains(.setOwnName))
        try send("member.set_name", ["name": .string(name)])
    }

    // MARK: Channels (F2)

    /// Channels may be shown: current, rights confirmed, no snapshot owed,
    /// the server has them. The one gate of every channel's name and id the
    /// UI shows (review F2-p1 group: names left in UI state).
    var channelsVisible: Bool { visible && !inDoubt && !snapshotOwed() && view.channelsServed }
    /// The user's teams whose channels may be listed, archived ones too:
    /// their channels stay readable (review F2-p2-5).
    var channelTeams: [ChatOrgView.Team] { channelsVisible ? view.teams.filter(\.mine) : [] }
    /// A team's name, only while the user is in it and channels may be shown.
    func teamName(_ teamId: String) -> String? { channelTeams.first { $0.teamId == teamId }?.name }
    /// A channel's name, only while its card may be seen.
    func channelName(_ id: String) -> String? { visibleChannel(id)?.name }

    /// F4: a channel's unread, while it may be seen.
    func unread(_ channel: String) -> ChatUnread.Count? {
        guard visibleChannel(channel) != nil, var count = view.unread[channel] else { return nil }
        count.count += view.unreadRepliesByChannel[channel, default: 0]
        // "•" says "not counted": only for a channel not followed (review F4-C).
        if isFollowed(channel) { count.something = false }
        return count
    }
    /// The channel's stream is followed now (its events count it).
    var isFollowed: @MainActor (String) -> Bool = { _ in false }
    /// "Mute Channel": its thread replies notify no more (mentions still do).
    func setMuted(_ channel: String, _ muted: Bool) {
        guard visibleChannel(channel) != nil else { return }
        try? followed?.queue.write { db in try ChatUnread.setMuted(db, channel: channel, muted) }
    }

    /// Mentions not read, for the Dock: none while channels may not be shown.
    var mentionsForBadge: Int { channelsVisible ? view.mentionsUnread : 0 }

    func unreadMentions(_ channel: String) -> Int {
        visibleChannel(channel) != nil ? view.mentionsByChannel[channel, default: 0] : 0
    }

    /// Channels of the user's teams; none while the rights are in doubt (C6).
    func channels(of team: ChatOrgView.Team) -> [ChatChannelCard] {
        guard channelsVisible else { return [] }
        return view.channels.filter { $0.teamId == team.teamId }
    }
    /// Channels being created in `team`, by name, until sent.
    func creatingChannels(in team: ChatOrgView.Team) -> [String] {
        guard channelsVisible, teamName(team.teamId) != nil else { return [] }
        return view.creating.filter { $0.teamId == team.teamId }.map(\.name)
    }
    /// A card the user may see now: current, rights not in doubt, the
    /// server has channels, and the card is kept (DESIGN-F2).
    func visibleChannel(_ id: String) -> ChatChannelCard? {
        guard channelsVisible else { return nil }
        return view.channels.first { $0.channelId == id && teamName($0.teamId) != nil }
    }
    func channelTeam(_ card: ChatChannelCard) -> ChatOrgView.Team? { channelTeams.first { $0.teamId == card.teamId } }

    // The server's rules (F-API "Commands"): the user in the team; rename by
    // its creator or an owner or admin; archive by an owner or admin.
    func canCreateChannel(in team: ChatOrgView.Team) -> Bool {
        channelsVisible && team.mine && !team.archived && teamName(team.teamId) != nil
    }
    func canRenameChannel(_ card: ChatChannelCard) -> Bool {
        visibleChannel(card.channelId) != nil && !card.archived && (card.createdBy == me || ChatOrgView.manages(myRole))
    }
    func canArchiveChannel(_ card: ChatChannelCard) -> Bool {
        visibleChannel(card.channelId) != nil && !card.archived && ChatOrgView.manages(myRole)
    }
    /// 1–64 characters, as the server counts them; nil when it fits.
    static func channelNameProblem(_ name: String) -> String? {
        let count = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        if count == 0 { return "Give the channel a name." }
        return count > 64 ? "A channel name is at most 64 characters." : nil
    }

    /// Queues `channel.create`; the new channel's id.
    @discardableResult
    func createChannel(_ name: String, in team: ChatOrgView.Team, channelID: String? = nil) throws -> String {
        let team = try self.team(team)
        try require(canCreateChannel(in: team) && Self.channelNameProblem(name) == nil)
        let id = channelID ?? newTeamId()
        try send("channel.create", ["channel_id": .string(id), "team_id": .string(team.teamId),
                                    "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))])
        return id
    }

    func renameChannel(_ card: ChatChannelCard, to name: String) throws {
        guard let card = visibleChannel(card.channelId) else { throw ChatOrgError.notAllowed }
        try require(canRenameChannel(card) && Self.channelNameProblem(name) == nil)
        try send("channel.rename", ["channel_id": .string(card.channelId), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    func archiveChannel(_ card: ChatChannelCard) throws {
        guard let card = visibleChannel(card.channelId) else { throw ChatOrgError.notAllowed }
        try require(canArchiveChannel(card))
        try send("channel.archive", ["channel_id": .string(card.channelId)])
    }

    // MARK: Agents of a channel (F5)

    /// The server has agents in channels, and channels may be shown.
    var agentsVisible: Bool { channelsVisible && view.agentsServed }

    /// The agents of a channel seen now.
    func agents(in channel: String) -> [ChatChannelAgent] {
        guard agentsVisible, visibleChannel(channel) != nil else { return [] }
        return view.channelAgents.filter { $0.channelId == channel }
    }

    /// The user's own enabled agents not in the channel yet (F-API: the
    /// agent's owner, in the channel's team; a channel not archived).
    func addableAgents(_ card: ChatChannelCard) -> [ChatAgentCard] {
        guard agentsVisible, let card = visibleChannel(card.channelId), !card.archived,
              channelTeam(card)?.mine == true else { return [] }
        let there = Set(agents(in: card.channelId).map(\.agentId))
        return view.myAgents.filter { $0.enabled && !there.contains($0.agentId) }
    }

    /// Its owner, or an owner or admin of the organization in the channel's team.
    func canRemoveAgent(_ agent: ChatChannelAgent) -> Bool {
        guard let card = visibleChannel(agent.channelId), channelTeam(card)?.mine == true,
              agents(in: agent.channelId).contains(agent) else { return false }
        return agent.ownerAccountId == me || ChatOrgView.manages(myRole)
    }

    func addAgent(_ agentId: String, to card: ChatChannelCard) throws {
        guard let card = visibleChannel(card.channelId) else { throw ChatOrgError.notAllowed }
        try require(addableAgents(card).contains { $0.agentId == agentId })
        try send("agent.add_to_channel", ["agent_id": .string(agentId), "channel_id": .string(card.channelId)])
    }

    func removeAgent(_ agent: ChatChannelAgent) throws {
        try require(canRemoveAgent(agent))
        try send("agent.remove_from_channel", ["agent_id": .string(agent.agentId), "channel_id": .string(agent.channelId)])
    }

    /// Refusals of channel commands, for the left panel.
    var channelRefusals: [(id: String, title: String, reason: String)] {
        guard isCurrent() else { return [] }
        return view.refusals.filter { ChatChannels.eventTypes.contains($0.type) || ChatChannelAgents.eventTypes.contains($0.type) }
            .map { refusal in
                // For an agent, `invalid_state` is "already in it" (F-API "An agent in a channel").
                let already = refusal.type == "agent.add_to_channel" && refusal.code == "invalid_state"
                return (refusal.commandId, describe(refusal), already ? "The agent is in the channel already" : Self.reason(refusal.code))
            }
    }

    /// A refusal's code in words.
    static func reason(_ code: String) -> String {
        switch code {
        case "name_taken": return "That name is taken in this team"
        case "channel_archived": return "The channel is archived"
        case "invalid_state": return "The team is archived"
        case "forbidden": return "Your role does not allow this"
        case "not_found": return "It is not available to you"
        case "agent_unavailable": return "The agent is disabled"
        default: return "Refused by the server (\(code))"
        }
    }

    func createTeam(_ name: String) throws {
        try require(manages)
        try send("team.create", ["team_id": .string(newTeamId()), "name": .string(name)])
    }

    func renameTeam(_ team: ChatOrgView.Team, to name: String) throws {
        let team = try self.team(team)
        try require(canChange(team))
        try send("team.rename", ["team_id": .string(team.teamId), "name": .string(name)])
    }

    func archiveTeam(_ team: ChatOrgView.Team) throws {
        let team = try self.team(team)
        try require(canChange(team))
        try send("team.archive", ["team_id": .string(team.teamId)])
    }

    func addMember(_ account: String, to team: ChatOrgView.Team) throws {
        let team = try self.team(team)
        try require(candidates(for: team).contains { $0.accountId == account })
        try send("team.add_member", ["team_id": .string(team.teamId), "account_id": .string(account)])
    }

    func removeMember(_ account: String, from team: ChatOrgView.Team) throws {
        let team = try self.team(team)
        try require(canRemoveMember(account, from: team))
        try send("team.remove_member", ["team_id": .string(team.teamId), "account_id": .string(account)])
    }

    func leave(_ team: ChatOrgView.Team) throws {
        let team = try self.team(team)
        try require(canLeave(team))
        try send("team.leave", ["team_id": .string(team.teamId)])
    }

    func join(_ team: ChatOrgView.Team) throws {
        let team = try self.team(team)
        try require(canJoin(team))
        try send("team.join", ["team_id": .string(team.teamId)])
    }

    func setRole(_ target: ChatOrgView.Member, to role: String) throws {
        let target = try member(target)
        try require(roles(for: target).contains(role))
        try send("member.set_role", ["account_id": .string(target.accountId), "role": .string(role)])
    }

    func remove(_ target: ChatOrgView.Member) throws {
        let target = try member(target)
        try require(canRemove(target))
        try send("member.remove", ["account_id": .string(target.accountId)])
    }

    /// `invitation.create`: a manager; `member` or `admin`; teams of the
    /// organization, not archived — of this organization's view only.
    func invite(email: String, role: String, teams ids: [String]) throws {
        try require(manages && (role == "member" || role == "admin"))
        let open = Set(teams.filter { !$0.archived }.map(\.teamId))
        try require(ids.allSatisfy(open.contains))
        try send("invitation.create", ["email": .string(email), "role": .string(role), "team_ids": .array(ids.map { .string($0) })])
    }

    /// Teams an invitation may name besides General (always in it): not archived.
    var invitable: [ChatOrgView.Team] { manages ? teams.filter { !$0.isGeneral && !$0.archived } : [] }

    func revoke(_ invitation: ChatSnapshot.Invitation) throws {
        try require(invitations.contains { $0.invitationId == invitation.invitationId })
        try send("invitation.revoke", ["invitation_id": .string(invitation.invitationId)])
    }

    /// Refusals as they may be shown now: what each was for, in names the
    /// user may see today. The send queue keeps the commands as made; what
    /// they name is shown only while the user may see it (decision
    /// "Сужение видимости не трогает очередь отправки").
    var refused: [(id: String, title: String, code: String)] {
        guard isCurrent() else { return [] }
        return view.refusals.map { ($0.commandId, describe($0), $0.code) }
    }

    func describe(_ refusal: ChatOrgView.Refusal) -> String {
        let team = refusal.args["team_id"]?.string.flatMap { id in teams.first { $0.teamId == id }?.name } ?? "a team no longer available"
        let who = refusal.args["account_id"]?.string.flatMap { self.member($0)?.name } ?? "a member"
        switch refusal.type {
        case "member.set_name": return "Change your name"
        case "team.create": return manages ? "Create team \(refusal.args["name"]?.string ?? "")" : "Create a team"
        case "team.rename": return "Rename \(team)"
        case "team.archive": return "Archive \(team)"
        case "team.add_member": return "Add \(who) to \(team)"
        case "team.remove_member": return "Remove \(who) from \(team)"
        case "team.leave": return "Leave \(team)"
        case "team.join": return "Join \(team)"
        case "member.set_role": return "Make \(who) \(refusal.args["role"]?.string ?? "")"
        case "member.remove": return "Remove \(who)"
        case "invitation.create": return manages ? "Invite \(refusal.args["email"]?.string ?? "")" : "Invite someone"
        case "invitation.revoke": return "Revoke an invitation"
        case "channel.create":
            // The name the user typed, shown only while its team may be (review F2-p1-1).
            guard let name = refusal.args["team_id"]?.string.flatMap(teamName) else {
                return "Create a channel in a team no longer available"
            }
            return "Create channel #\(refusal.args["name"]?.string ?? "") in \(name)"
        case "channel.rename", "channel.archive":
            // Named only while the user may see the channel (DESIGN-F2).
            let what = refusal.args["channel_id"]?.string.flatMap(channelName).map { "#\($0)" } ?? "a channel"
            return refusal.type == "channel.rename" ? "Rename \(what)" : "Archive \(what)"
        case "agent.add_to_channel", "agent.remove_from_channel":
            // The channel named only while the user may see it; the agent the user's own or of that channel.
            let channel = refusal.args["channel_id"]?.string
            let what = channel.flatMap(channelName).map { "#\($0)" } ?? "a channel"
            let id = refusal.args["agent_id"]?.string
            let name = id.flatMap { id in
                view.myAgents.first { $0.agentId == id }?.name
                    ?? channel.flatMap { c in agents(in: c).first { $0.agentId == id }?.name }
            } ?? "an agent"
            return refusal.type == "agent.add_to_channel" ? "Add \(name) to \(what)" : "Remove \(name) from \(what)"
        default: return refusal.type
        }
    }

    private func send(_ type: String, _ args: [String: ChatJSON]) throws {
        try require(visible && !inDoubt)
        _ = try enqueue(type, .object(args))
    }

    private func require(_ allowed: Bool) throws {
        if !allowed { throw ChatOrgError.notAllowed }
    }

    // MARK: The security log

    /// The first page of the log, or the next after what is shown. One read
    /// at a time; a new first read voids any on its way.
    func loadAudit(more: Bool = false) async {
        guard actions.contains(.seeAudit) else { return }
        if more, auditLoading || auditNext == nil { return }
        auditGeneration += 1
        let generation = auditGeneration
        let before = more ? auditNext : nil
        auditLoading = true
        do {
            let page = try await readAudit(before)
            guard generation == auditGeneration, actions.contains(.seeAudit) else { return }
            auditRead = (more ? auditRead ?? [] : []) + page.records
            auditNext = page.next
            problem = nil
        } catch let error as ChatAPIError where ["forbidden", "not_found"].contains(error.code ?? "") {
            // A sign, if this is still the latest read (review C6e p2-1).
            guard generation == auditGeneration else { return }
            auditRead = nil
            auditNext = nil
            auditGeneration += 1
            auditLoading = false
            problem = "The security log could not be read: your rights are being checked."
            onRightsSign(error.code ?? "forbidden")
            return
        } catch {
            guard generation == auditGeneration else { return }
            problem = error.localizedDescription
        }
        auditLoading = false
    }

    // MARK: Expiry

    /// The view is redrawn when the next open invitation expires: time is
    /// not something the cache tells (review C6 p2-6).
    private func scheduleExpiry() {
        expiry?.cancel()
        now = Date()
        let next = view.invitations.compactMap { $0.expiresAt.flatMap(ChatStore.date) }.filter { $0 > now }.min()
        guard let next else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled, let self else { return }
            self.scheduleExpiry()
        }
    }
}

/// The account's devices on its server (C6): of the session, not of an
/// organization — there while the session is, in or out of one (review C6
/// p1-9). It stands for one (server, account, session).
@MainActor
@Observable
final class ChatDevicesModel {
    private(set) var devices: [ChatDeviceSession]?
    private(set) var problem: String?
    var isCurrent: @MainActor () -> Bool = { true }
    var listSessions: @MainActor () async throws -> [ChatDeviceSession] = { [] }
    var closeSessionCall: @MainActor (String) async throws -> Void = { _ in }
    /// This Mac's own session is closed the core's way, Disconnect —
    /// runs stopped as D11 wants, then the session (review C6e p1-5).
    var disconnect: @MainActor () async -> Void = {}
    /// Reads of the list count only when nothing changed it meanwhile: no
    /// later read, no close begun or finished (review C6 p2-5, C6b p1-8).
    @ObservationIgnored private var generation = 0

    func load() async {
        generation += 1
        let mine = generation
        do {
            let list = try await listSessions()
            guard mine == generation, isCurrent() else { return }
            devices = list
            problem = nil
        } catch {
            guard mine == generation else { return }
            problem = "The devices could not be read: \(error.localizedDescription)"
        }
    }

    /// Closes a session on the whole server, then reads the list again. A
    /// session the server no longer has is gone from the list too (review C6
    /// p2-10); this Mac's own ends the connection at once (review C6b p1-6).
    func close(_ session: ChatDeviceSession) async {
        guard isCurrent() else { return }
        if session.current { return await disconnect() }
        generation += 1
        do {
            try await closeSessionCall(session.sessionId)
        } catch let error as ChatAPIError where error.code == "not_found" {
            // Closed already: as good as done.
        } catch {
            generation += 1
            guard isCurrent() else { return }
            problem = "\(session.deviceName) was not signed out: \(error.localizedDescription)"
            return
        }
        generation += 1
        // Answered for a session no longer this model's: nothing of it changes now.
        guard isCurrent() else { return }
        devices?.removeAll { $0.sessionId == session.sessionId }
        problem = nil
        await load()
    }
}

enum ChatOrgError: LocalizedError, Equatable {
    case notAllowed

    var errorDescription: String? { "Your role does not allow this." }
}

extension ChatOrgModel {
    /// The model of the connection's organization, following its cache; nil
    /// while there is none. Never makes a session: one the account lost
    /// stays gone (review C6 p1-4, p2-2).
    static func current(_ service: ChatService = .shared) -> ChatOrgModel? {
        guard let connection = service.connection, let key = connection.orgKey,
              let store = service.orgSessions[key]?.store else { return nil }
        let session = connection.sessionId
        let isCurrent: @MainActor () -> Bool = { [weak service, weak store] in
            guard let service, let store else { return false }
            // A session the server ended is not current, though nothing else changed.
            return service.state == .signedIn && service.connection?.orgKey == key && service.connection?.sessionId == session
                && service.orgSessions[key]?.store === store
        }
        let model = ChatOrgModel(me: key.accountId) { [weak service] type, args in
            guard let service, isCurrent() else { throw ChatError.notConnected }
            return try service.enqueue(key, type: type, args: args).commandId
        }
        model.isCurrent = isCurrent
        model.key = key
        model.showsOffline = { [weak service] in service?.socket?.showsOffline ?? true }
        model.snapshotOwed = { [weak service] in service?.orgSessions[key]?.snapshotOwed ?? true }
        model.isFollowed = { [weak service] channel in service?.orgSessions[key]?.followedChannels.contains(channel) ?? false }
        model.dismissRefusals = { [weak service] ids in
            guard let service, isCurrent() else { return }
            if let outbox = service.orgSessions[key]?.outbox {
                outbox.dismissRefused(ids)
            } else {
                // The queue does not run yet: its table, as the queue would.
                try? store.outbox.dismiss(ids)
            }
        }
        model.storageProblem = { [weak service] in service?.orgSessions[key]?.doubtNotWritten ?? false }
        model.problemEpoch = { [weak service] in service?.orgSessions[key]?.doubtWriteFailures ?? 0 }
        model.session = session
        model.onRightsSign = { [weak service] code in
            guard let service, isCurrent(), let session = service.orgSessions[key] else { return }
            if let sync = session.sync {
                sync.rightsInDoubt()
            } else if (try? store.putRightsInDoubt()) == nil {
                // No synchronizer to try again: nothing is shown until one runs.
                session.doubtNotWritten = true
                session.doubtWriteFailures += 1
            }
            // Perhaps out of the organization: `/v1/me` decides, the core's way.
            if code == "not_found" { service.accountFeed?.readMeAgain() }
        }
        let api = service.makeAPI(connection.server)
        model.readAudit = { [weak service] before in
            guard let service, let token = service.token, isCurrent() else { throw ChatError.notConnected }
            return try await ChatService.endingOn401(service, session: session, server: key.server) {
                try await api.audit(key.orgId, before: before, token: token)
            }
        }
        model.follow(store)
        return model
    }
}

extension ChatDevicesModel {
    /// The devices of the connection's session; nil without one.
    static func current(_ service: ChatService = .shared) -> ChatDevicesModel? {
        guard let connection = service.connection else { return nil }
        let isCurrent: @MainActor () -> Bool = { [weak service] in
            guard let service, service.connection?.sessionId == connection.sessionId,
                  service.connection?.server == connection.server else { return false }
            if case .needsSignIn = service.state { return false }
            return service.state != .off
        }
        let model = ChatDevicesModel()
        model.isCurrent = isCurrent
        let api = service.makeAPI(connection.server)
        func token() throws -> String {
            guard let token = service.token, isCurrent() else { throw ChatError.notConnected }
            return token
        }
        let session = connection.sessionId, server = connection.server
        model.listSessions = {
            let token = try token()
            return try await ChatService.endingOn401(service, session: session, server: server) { try await api.sessions(token: token) }
        }
        model.closeSessionCall = { id in
            let token = try token()
            try await ChatService.endingOn401(service, session: session, server: server) { try await api.closeSession(id, token: token) }
        }
        model.disconnect = { ConnectionTabs.shared.disconnect() }
        return model
    }
}

extension ChatService {
    /// The reason the core gives when the server refuses a session (401).
    static let sessionClosedReason = "The server closed this session. Sign in again."

    /// Ends the connection's session with `reason` — only if it still is
    /// the session named, on that server: an answer about an earlier one
    /// changes nothing of a newer connection (review C6c p1-4).
    func endSession(_ session: String, server: ChatServerAddress, reason: String = ChatService.sessionClosedReason) {
        guard connection?.sessionId == session, connection?.server == server else { return }
        sessionEnded(reason)
    }

    /// Runs a request of `session`; a 401 ends that session as the core's
    /// send queue does (`sessionEnded`), then is thrown on (review C6c p1-3).
    static func endingOn401<T>(_ service: ChatService, session: String, server: ChatServerAddress,
                               _ request: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch let error as ChatAPIError where error.code == "unauthorized" {
            service.endSession(session, server: server)
            throw error
        }
    }
}
