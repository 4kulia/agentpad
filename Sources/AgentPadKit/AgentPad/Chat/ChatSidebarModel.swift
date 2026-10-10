import Foundation
import Observation

/// Only IDs and layout preferences go into window persistence. Names and
/// search results are always projected again through the F2 gate.
struct ChatSidebarPreferences: Codable, Equatable {
    struct Section: Codable, Equatable, Hashable {
        var server, account, org: String
        var team: String?

        init(_ key: ChatOrgKey, team: String?) {
            server = key.server.description; account = key.accountId; org = key.orgId; self.team = team
        }
    }

    var attentionCollapsed: Bool?
    var width: Double = 248
    var collapsed: [Section] = []

    static func clampWidth(_ width: Double) -> Double {
        width.isFinite ? min(320, max(220, width)).rounded() : 248
    }

    mutating func setCollapsed(_ section: Section, _ value: Bool) {
        collapsed.removeAll { $0 == section }
        if value { collapsed.append(section) }
    }
}

enum ChatSidebarFilter: String, CaseIterable {
    case all, unread, mentions
}

enum ChatSidebarRowID: Equatable, Hashable {
    case team(String), channel(String), agents, agent(String)
    case profile(UUID), history(UUID, String), more(UUID), allSessions
}

/// Pure keyboard routing: arrows move focus, Return activates; no opening a
/// channel (and therefore no read mark) merely by moving past its row.
enum ChatSidebarKeyboard {
    struct Row: Equatable {
        var id: ChatSidebarRowID
        var parent: ChatSidebarRowID?
        var expanded: Bool? = nil
    }
    enum Key { case up, down, left, right, enter }
    enum Effect: Equatable {
        case select(ChatSidebarRowID), expand(ChatSidebarRowID, Bool), activate(ChatSidebarRowID), none
    }

    static func route(_ key: Key, selection: ChatSidebarRowID?, rows: [Row]) -> Effect {
        guard !rows.isEmpty else { return .none }
        guard let index = rows.firstIndex(where: { $0.id == selection }) else {
            return .select(key == .up ? rows.last!.id : rows[0].id)
        }
        let row = rows[index]
        switch key {
        case .up: return .select(rows[max(0, index - 1)].id)
        case .down: return .select(rows[min(rows.count - 1, index + 1)].id)
        case .left:
            if row.expanded == true { return .expand(row.id, false) }
            return row.parent.map(Effect.select) ?? .none
        case .right:
            if row.expanded == false { return .expand(row.id, true) }
            if row.expanded == true, index + 1 < rows.count, rows[index + 1].parent == row.id {
                return .select(rows[index + 1].id)
            }
            return .none
        case .enter:
            if case .profile = row.id { return .activate(row.id) }
            if let expanded = row.expanded { return .expand(row.id, !expanded) }
            return .activate(row.id)
        }
    }
}

@MainActor
@Observable
final class ChatSidebarNavigation {
    var focusRequested = false
    var query = ""
    var filter = ChatSidebarFilter.all
    var selection: ChatSidebarRowID?
    var agentID: String?
    var filterCollapsed: Set<ChatSidebarRowID> = []
    var toOpen: Set<ChannelRef> = []
    private var identity: String?

    func adopt(_ identity: String?) {
        guard self.identity != identity else { return }
        self.identity = identity
        query = ""; filter = .all; selection = nil; agentID = nil; toOpen = []; filterCollapsed = []
    }

    func hideRestrictedContent() {
        query = ""; selection = nil; agentID = nil
    }
}

/// One ephemeral, gated projection for the sidebar, its search and agent
/// popovers. Never retained in @State or in a window's saved state.
struct ChatSidebarSnapshot {
    enum State: Equatable { case notConnected, checking, noChannels, ready(offline: Bool) }
    struct Channel: Identifiable {
        var card: ChatChannelCard
        var unread: ChatUnread.Count
        var mentions: Int
        /// Included in the inbox's missing-history count, never the channel badge.
        var unreadReplies = 0
        var id: String { card.channelId }
        var isUnread: Bool { unread.count > 0 || unread.more || unread.something }
        var unreadLabel: String? { ChatSidebarSnapshot.unreadLabel(unread) }
        var mentionLabel: String? { mentions > 0 ? "@\(mentions)" + (unread.more || unread.something ? "+" : "") : nil }
    }
    struct Team: Identifiable {
        var card: ChatOrgView.Team
        var channels: [Channel]
        var creating: [String]
        var id: String { card.teamId }
    }
    struct Agent: Identifiable {
        var id, name, owner, description, access: String
        var mine: Bool
        var channels: [String]
        var inCurrentChannel: Bool
        var device: String?
        var executorSessionID: String?
        var available = true
        var enabled = true
    }

    var state: State = .notConnected
    var teams: [Team] = []
    var agents: [Agent] = []
    var agentsServed = false
    var incomplete = false
    var unread = ChatUnread.Count()
    var mentions = 0

    static func unreadLabel(_ count: ChatUnread.Count) -> String? {
        if count.count > 0 { return "\(count.count)" + (count.more || count.something ? "+" : "") }
        return count.more || count.something ? "•" : nil
    }

    @MainActor
    init(model: ChatOrgModel?, active: ChannelRef?) {
        guard let model, model.isCurrent() else { return }
        guard model.visible, !model.inDoubt, !model.snapshotOwed() else { state = .checking; return }
        guard model.view.channelsServed else { state = .noChannels; return }
        state = .ready(offline: model.showsOffline())
        let currentChannel = model.key.flatMap { key in active?.belongs(to: key) == true ? active?.channel : nil }
        teams = model.channelTeams.map { team in
            Team(card: team, channels: model.channels(of: team).compactMap { card in
                guard model.visibleChannel(card.channelId) != nil else { return nil }
                return Channel(card: card, unread: model.unread(card.channelId) ?? .init(),
                               mentions: model.unreadMentions(card.channelId),
                               unreadReplies: model.view.unreadRepliesByChannel[card.channelId, default: 0])
            }, creating: model.creatingChannels(in: team))
        }
        for channel in teams.flatMap(\.channels) {
            // The Unread navigation badge is the sum of channel badges; its list also contains replies.
            unread.count += channel.unread.count
            unread.more = unread.more || channel.unread.more
            unread.something = unread.something || channel.unread.something
            mentions += channel.mentions
        }
        incomplete = model.view.channelsReadOpen || unread.more || unread.something
        agentsServed = model.agentsVisible
        guard agentsServed else { return }
        let channelAgents = teams.flatMap(\.channels).flatMap { model.agents(in: $0.id) }
        let byID = Dictionary(grouping: channelAgents, by: \.agentId)
        let own = Dictionary(model.view.myAgents.filter { $0.ownerAccountId == model.me }.map { ($0.agentId, $0) }, uniquingKeysWith: { first, _ in first })
        agents = Set(byID.keys).union(own.keys).compactMap { id in
            let memberships = byID[id] ?? []
            let member = memberships.first { $0.channelId == currentChannel } ?? memberships.first
            guard let name = member?.name ?? own[id]?.name,
                  let ownerID = member?.ownerAccountId ?? own[id]?.ownerAccountId else { return nil }
            let owner = model.members.first { $0.accountId == ownerID }
            return Agent(id: id, name: name, owner: owner?.name ?? member?.ownerHandle ?? "Unknown owner",
                         description: member?.description ?? own[id]?.description ?? "",
                         access: member?.access ?? own[id]?.access ?? "", mine: ownerID == model.me,
                         channels: memberships.map(\.channelId).sorted(),
                         inCurrentChannel: memberships.contains { $0.channelId == currentChannel },
                         device: member?.executorDeviceName ?? own[id]?.executorDeviceName,
                         executorSessionID: member?.executorSessionId ?? own[id]?.executorSessionId,
                         available: member?.available ?? own[id]?.available ?? false,
                         enabled: member?.enabled ?? own[id]?.enabled ?? false)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            let owner = $0.owner.localizedStandardCompare($1.owner)
            return owner == .orderedSame ? $0.id < $1.id : owner == .orderedAscending
        }
    }

    func filteredTeams(query: String, filter: ChatSidebarFilter) -> [Team] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return teams.compactMap { team in
            var result = team
            result.channels = team.channels.filter { channel in
                let matches = query.isEmpty || channel.card.name.localizedCaseInsensitiveContains(query)
                    || team.card.name.localizedCaseInsensitiveContains(query)
                return matches && (filter == .all || filter == .unread && channel.isUnread || filter == .mentions && channel.mentions > 0)
            }
            result.creating = filter == .all ? team.creating.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } : []
            return !result.channels.isEmpty || !result.creating.isEmpty || (filter == .all && query.isEmpty) ? result : nil
        }
    }

    func filteredAgents(query: String, filter: ChatSidebarFilter) -> [Agent] {
        guard filter == .all else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
}
