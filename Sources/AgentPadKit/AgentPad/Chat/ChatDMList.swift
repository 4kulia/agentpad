import Foundation
import GRDB
import Observation

struct ChatDMEntry: Equatable, Identifiable {
    var card: ChatDMCard
    var lastUsed: Date
    var roots: ChatUnread.Count
    var replies: Int
    var hasMessages: Bool
    var id: String { card.dmId }
    var unread: Bool { roots.count > 0 || roots.more || roots.something || replies > 0 }
    var badge: String? {
        if roots.something && roots.count == 0 && replies == 0 { return "•" }
        if roots.count > 0 || roots.more { return "\(roots.count)\(roots.more ? "+" : "")" }
        return replies > 0 ? "↳ \(replies)" : nil
    }
    static func visible(_ entries: [Self], limit: Int) -> [Self] {
        entries.enumerated().filter { $0.offset < max(0, limit) || $0.element.unread }.map(\.element)
    }
    static func read(_ db: Database, me: String) throws -> [Self] {
        try ChatDMStore.cards(db).map { card in
            let content = try ChatDMContent.read(db, dm: card.dmId), mark = content.marks["", default: 0]
            let all = content.messages, live = all.filter { !$0.deleted && !$0.loading && $0.authorAccountId != me }
            let roots = live.filter { $0.threadRootId == nil && ($0.seq ?? 0) > mark }.count
            let replies = live.filter { m in
                guard let root = m.threadRootId else { return false }
                return (m.seq ?? 0) > max(content.marks[root, default: 0], content.marks["*", default: 0])
            }.count
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_pending WHERE dm_id = ? AND seq > ?)", arguments: [card.dmId, mark]) ?? false
            let oldest = all.compactMap(\.seq).min() ?? 0
            let activity = try String.fetchOne(db, sql: "SELECT last_activity FROM dm_cards WHERE dm_id = ?", arguments: [card.dmId])
            let opened = try String.fetchOne(db, sql: "SELECT opened FROM dm_preferences WHERE dm_id = ?", arguments: [card.dmId])
            let last = max(activity.flatMap(ChatFeedLayout.date) ?? .distantPast, opened.flatMap(ChatFeedLayout.date) ?? .distantPast)
            return Self(card: card, lastUsed: last,
                roots: .init(count: roots, more: content.historyNext != nil && mark < oldest, something: pending, muted: content.muted),
                replies: replies, hasMessages: !all.isEmpty || content.historyNext != nil)
        }.sorted { $0.lastUsed == $1.lastUsed ? $0.id < $1.id : $0.lastUsed > $1.lastUsed }
    }
}

@MainActor @Observable
final class ChatDMListModel {
    let key: ChatOrgKey
    private weak var service: ChatService?
    private var kept: [ChatDMEntry] = []
    private var accessEpoch = -1
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    var entries: [ChatDMEntry] {
        guard let service, service.dmAllowed(key), let store = service.orgSessions[key]?.store,
              (try? store.dmRead { try Int.fetchOne($0, sql: "SELECT epoch FROM dm_meta") }) == accessEpoch else { return [] }
        return kept
    }
    init(key: ChatOrgKey, store: ChatStore, service: ChatService) {
        self.key = key; self.service = service
        observation = ValueObservation.tracking { db in
            (try ChatDMEntry.read(db, me: key.accountId), try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") ?? 0)
        }.start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in self?.kept = [] }) { [weak self] rows, epoch in
            self?.kept = rows; self?.accessEpoch = epoch
        }
    }
    func stop() { observation = nil; kept = []; accessEpoch = -1 }
}

extension ChatService {
    func dmList(_ key: ChatOrgKey) -> ChatDMListModel? {
        guard state == .signedIn, connection?.orgKey == key, supports("chat.dm", key: key),
              let session = orgSessions[key], let store = session.store else { return nil }
        if session.dmList == nil { session.dmList = ChatDMListModel(key: key, store: store, service: self) }
        return session.dmList
    }
}
