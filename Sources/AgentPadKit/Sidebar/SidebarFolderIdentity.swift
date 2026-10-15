import AgentPadTelegram
import Foundation

/// The only Telegram entry allowed in app-wide persistence is the block token.
enum SidebarEntryIdentity {
    static func scope(server: String, account: String, org: String) -> String { "\(server)|\(account)|\(org)" }
    static func team(_ key: ChatOrgKey, team: String) -> String { "team:\(scope(server: key.server.description, account: key.accountId, org: key.orgId))|\(team)" }
    static func people(_ key: ChatOrgKey) -> String { "people:\(scope(server: key.server.description, account: key.accountId, org: key.orgId))" }
    static func teamAgents(_ key: ChatOrgKey) -> String { "teamAgents:\(scope(server: key.server.description, account: key.accountId, org: key.orgId))" }
    static func custom(_ id: UUID) -> String { "custom:\(id.uuidString)" }
    static func persistable(_ id: String, allowTelegramBlock: Bool = true) -> Bool {
        if id == "myAgents" || (allowTelegramBlock && id == "telegram") { return true }
        if id.hasPrefix("custom:") { return UUID(uuidString: String(id.dropFirst(7))) != nil }
        for (prefix, count) in [("team:",4),("people:",3),("teamAgents:",3)] where id.hasPrefix(prefix) {
            let parts = id.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
            return parts.count == count && parts.allSatisfy { !$0.isEmpty }
        }
        return false
    }
}

/// Encoding has no case for Telegram; profile memberships use a separate API.
enum SidebarAgentPadReference: Hashable, Sendable, Codable {
    struct Channel: Hashable, Sendable, Codable { var server, account, org, channel: String }
    struct Person: Hashable, Sendable, Codable { var server, account, org, peer: String }
    struct TeamAgent: Hashable, Sendable, Codable { var server, account, org, agent: String }
    case channel(Channel), person(Person), myAgent(UUID), teamAgent(TeamAgent)
    private enum CodingKeys: String, CodingKey { case channel, person, myAgent, teamAgent }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else { throw SidebarFolderFailure.invalid }
        switch values.allKeys[0] {
        case .channel: self = .channel(try values.decode(Channel.self, forKey: .channel))
        case .person: self = .person(try values.decode(Person.self, forKey: .person))
        case .myAgent: self = .myAgent(try values.decode(UUID.self, forKey: .myAgent))
        case .teamAgent: self = .teamAgent(try values.decode(TeamAgent.self, forKey: .teamAgent))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .channel(let value): try values.encode(value, forKey: .channel)
        case .person(let value): try values.encode(value, forKey: .person)
        case .myAgent(let value): try values.encode(value, forKey: .myAgent)
        case .teamAgent(let value): try values.encode(value, forKey: .teamAgent)
        }
    }
    var stableID: String {
        switch self {
        case .channel(let v): "channel:\(v.server)|\(v.account)|\(v.org)|\(v.channel)"
        case .person(let v): "person:\(v.server)|\(v.account)|\(v.org)|\(v.peer)"
        case .myAgent(let v): "myAgent:\(v.uuidString)"
        case .teamAgent(let v): "teamAgent:\(v.server)|\(v.account)|\(v.org)|\(v.agent)"
        }
    }
    var scope: String? {
        switch self {
        case .channel(let v): SidebarEntryIdentity.scope(server: v.server, account: v.account, org: v.org)
        case .person(let v): SidebarEntryIdentity.scope(server: v.server, account: v.account, org: v.org)
        case .teamAgent(let v): SidebarEntryIdentity.scope(server: v.server, account: v.account, org: v.org)
        case .myAgent: nil
        }
    }
}

enum SidebarItemReference: Hashable, Sendable {
    case agentpad(SidebarAgentPadReference), telegram(Int64)
    var stableID: String {
        switch self { case .agentpad(let reference): reference.stableID; case .telegram(let chat): "telegram:\(chat)" }
    }
}

struct SidebarCustomFolder: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var symbol = "folder"
    var items: [SidebarAgentPadReference] = []
}

struct SidebarFolderCatalog: Codable, Equatable, Sendable {
    var schema = 1
    var order: [String] = ["telegram", "myAgents"]
    var hidden: Set<String> = []
    var custom: [SidebarCustomFolder] = []
    var tombstones: Set<UUID> = []

    mutating func addDefaults(_ entries: [String]) {
        for folder in custom where !order.contains(SidebarEntryIdentity.custom(folder.id)) { order.insert(SidebarEntryIdentity.custom(folder.id),at: 0) }
        for entry in entries + ["telegram","myAgents"] where !order.contains(entry) {
            if entry.hasPrefix("team:") {
                let index = order.lastIndex(where: { $0.hasPrefix("team:") }).map { $0 + 1 } ?? 0
                order.insert(entry, at: index)
            } else if entry.hasPrefix("people:") {
                order.insert(entry, at: order.firstIndex(of: "telegram") ?? order.count)
            } else { order.append(entry) }
        }
    }
    func validate() throws {
        guard schema == 1, Set(order).count == order.count, order.allSatisfy({ SidebarEntryIdentity.persistable($0) }),
              hidden.allSatisfy({ SidebarEntryIdentity.persistable($0, allowTelegramBlock: false) }),
              Set(custom.map(\.id)).count == custom.count,
              custom.allSatisfy({ !tombstones.contains($0.id) && Set($0.items).count == $0.items.count }) else { throw SidebarFolderFailure.invalid }
        guard custom.count <= 10_000, tombstones.count <= 100_000, custom.reduce(0, { $0 + $1.items.count }) <= 100_000 else { throw SidebarFolderFailure.tooLarge }
        for folder in custom {
            guard folder.name.utf8.count <= 1_024, folder.items.count <= 20_000 else { throw SidebarFolderFailure.tooLarge }
            guard ["folder","star","briefcase","house","person.2","bolt","flag","bookmark"].contains(folder.symbol) else { throw SidebarFolderFailure.invalid }
        }
    }
}

enum SidebarFolderFailure: String, Error, Equatable, Sendable {
    case unavailable, staleBinding, timeout, invalid, storage, deleted, tooLarge
    var message: String {
        switch self {
        case .tooLarge: "This folder is too large"
        case .timeout: "The folder operation timed out"
        case .unavailable, .staleBinding: "Telegram is unavailable"
        case .invalid, .deleted: "This folder is unavailable"
        case .storage: "The folder could not be saved on this Mac"
        }
    }
}
enum SidebarFolderResult: Equatable, Sendable { case success, failure(SidebarFolderFailure) }

struct SidebarItemSummary: Equatable, Sendable {
    var reference: SidebarItemReference
    var title: String
    var activity: Date?
    var unread = false
    var muted = false
    var attention = false
    var available = true
    var hidden = false
    static func precedes(_ a: Self, _ b: Self) -> Bool {
        if a.activity != b.activity {
            if let a = a.activity, let b = b.activity { return a > b }
            return a.activity != nil
        }
        let title = a.title.localizedStandardCompare(b.title)
        if title != .orderedSame { return title == .orderedAscending }
        return a.reference.stableID < b.reference.stableID
    }
    static func telegram(_ row: TelegramChatRow) -> Self {
        .init(reference: .telegram(row.id.chat), title: row.title,
              activity: row.lastMessageDate > 0 ? Date(timeIntervalSince1970: Double(row.lastMessageDate)) : nil,
              unread: row.unreadCount > 0 || row.markedUnread, muted: row.muted, attention: row.attention != nil,
              available: row.kind.eligible, hidden: row.hidden)
    }
}

struct SidebarFoldersSnapshot: Equatable, Sendable {
    var catalog = SidebarFolderCatalog()
    var binding: TelegramProfileBinding?
    var members: [UUID:Set<SidebarItemReference>] = [:]
    var rows: [UUID:[SidebarItemSummary]] = [:]
    // Metadata outside a materialised viewport still changes order and badges.
    var metadataRevision: UInt64 = 0
    var revision: UInt64 = 0
}

struct SidebarCustomProjection: Equatable, Sendable {
    var items: [SidebarItemReference] = []
    var rows: [SidebarItemReference:SidebarItemSummary] = [:]
    var unread = 0
    var unmuted = 0
    var attention = false
    var foreign = 0
    var waitingForTelegram = false
}
