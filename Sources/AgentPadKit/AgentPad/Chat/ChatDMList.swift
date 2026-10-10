import Foundation
import GRDB
import Observation

struct ChatDMEntry: Equatable, Identifiable {
    var card: ChatDMCard
    var lastUsed: Date
    var roots: ChatUnread.Count
    var replies: Int
    var hasMessages: Bool
    var readMarks: [String: Int] = [:]
    var id: String { card.dmId }
    var unread: Bool { roots.count > 0 || roots.more || roots.something || replies > 0 }
    var badge: String? {
        if roots.something && roots.count == 0 && replies == 0 { return "•" }
        if roots.count > 0 || roots.more { return "\(roots.count)\(roots.more ? "+" : "")" }
        return replies > 0 ? "↳ \(replies)" : nil
    }
    static func read(_ db: Database, me: String) throws -> [Self] {
        try ChatDMStore.cards(db).map { card in
            let marks = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT root, seq FROM dm_marks WHERE dm_id = ?", arguments: [card.dmId])
                .map { ($0["root"] as String, $0["seq"] as Int) })
            let mark = marks["", default: 0]
            let all = try ChatDMStore.messages(db, card.dmId), live = all.filter { !$0.deleted && !$0.loading && $0.authorAccountId != me }
            let roots = live.filter { $0.threadRootId == nil && ($0.seq ?? 0) > mark }.count
            let replies = live.filter { m in
                guard let root = m.threadRootId else { return false }
                return (m.seq ?? 0) > max(marks[root, default: 0], marks["*", default: 0])
            }.count
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_pending WHERE dm_id = ? AND seq > ?)", arguments: [card.dmId, mark]) ?? false
            let oldest = all.compactMap(\.seq).min() ?? 0
            let summary = try Row.fetchOne(db, sql: "SELECT last_activity, history_next FROM dm_cards WHERE dm_id = ?", arguments: [card.dmId])
            let last = (summary?["last_activity"] as String?).flatMap(ChatFeedLayout.date) ?? .distantPast
            let hasEarlier = (summary?["history_next"] as Int?) != nil
            let muted = try Bool.fetchOne(db, sql: "SELECT muted FROM dm_preferences WHERE dm_id = ?", arguments: [card.dmId]) ?? false
            return Self(card: card, lastUsed: last,
                roots: .init(count: roots, more: hasEarlier && mark < oldest, something: pending, muted: muted),
                replies: replies, hasMessages: !all.isEmpty || hasEarlier, readMarks: marks)
        }.sorted { $0.lastUsed == $1.lastUsed ? $0.id < $1.id : $0.lastUsed > $1.lastUsed }
    }
}

/// Sidebar identity is the person, whether or not a server conversation exists.
struct ChatDMPerson: Equatable, Identifiable {
    var peer: ChatDMCard.Peer
    var conversation: ChatDMEntry?
    var id: String { peer.accountId }
    var unread: Bool { conversation?.unread == true }
    var hasMessages: Bool { conversation?.hasMessages == true }
    var writable: Bool { conversation?.card.writable ?? peer.active }
    var roots: ChatUnread.Count { conversation?.roots ?? .init() }
    var replies: Int { conversation?.replies ?? 0 }
    var badge: String? { conversation?.badge }
    func route(_ key: ChatOrgKey) -> ToolRoute {
        conversation.map { .directMessage(ChatDMRef(key, dm: $0.id)) } ?? .directMessageDraft(OrgKey(key), peer: id)
    }
    static func merge(_ entries: [ChatDMEntry], members: [ChatOrgView.Member], me: String) -> [Self] {
        var people = Dictionary(uniqueKeysWithValues: members.filter { $0.accountId != me }.map {
            ($0.accountId, Self(peer: .init(accountId: $0.accountId, name: $0.name, handle: $0.handle, active: true)))
        })
        for entry in entries.reversed() where entry.card.peer.accountId != me {
            let peer = people[entry.card.peer.accountId]?.peer ?? entry.card.peer
            people[peer.accountId] = Self(peer: peer, conversation: entry)
        }
        return people.values.sorted {
            if $0.hasMessages != $1.hasMessages { return $0.hasMessages }
            if $0.hasMessages, let first = $0.conversation, let second = $1.conversation, first.lastUsed != second.lastUsed {
                return first.lastUsed > second.lastUsed
            }
            let order = $0.peer.name.localizedCaseInsensitiveCompare($1.peer.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    static func visible(_ people: [Self], limit: Int, expanded: Bool = true) -> [Self] {
        people.enumerated().filter { (expanded && $0.offset < max(0, limit)) || $0.element.unread }.map(\.element)
    }
}

@MainActor @Observable
final class ChatDMListModel {
    let key: ChatOrgKey
    private weak var service: ChatService?
    private var kept: [ChatDMEntry] = []
    private var members: [ChatOrgView.Member] = []
    private var accessEpoch = -1
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    private var readable: Bool {
        guard let service, service.dmAllowed(key), let store = service.orgSessions[key]?.store,
              (try? store.dmRead { try Int.fetchOne($0, sql: "SELECT epoch FROM dm_meta") }) == accessEpoch else { return false }
        return true
    }
    var entries: [ChatDMEntry] { readable ? kept : [] }
    var people: [ChatDMPerson] {
        readable ? ChatDMPerson.merge(kept, members: members, me: key.accountId) : []
    }
    init(key: ChatOrgKey, store: ChatStore, service: ChatService) {
        self.key = key; self.service = service
        observation = ValueObservation.tracking { db in
            (try ChatDMEntry.read(db, me: key.accountId), try ChatOrgView.Member.read(db), try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") ?? 0)
        }.start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in self?.kept = []; self?.members = [] }) { [weak self] rows, members, epoch in
            self?.kept = rows; self?.members = members; self?.accessEpoch = epoch
        }
    }
    func stop() { observation = nil; kept = []; members = []; accessEpoch = -1 }
}

extension ChatService {
    func dmList(_ key: ChatOrgKey) -> ChatDMListModel? {
        guard state == .signedIn, connection?.orgKey == key, supports("chat.dm", key: key),
              let session = orgSessions[key], let store = session.store else { return nil }
        if session.dmList == nil { session.dmList = ChatDMListModel(key: key, store: store, service: self) }
        return session.dmList
    }
}
