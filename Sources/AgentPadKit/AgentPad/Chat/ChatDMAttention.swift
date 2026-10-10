import Foundation
import GRDB

extension ChatDMStore {
    /// In the same transaction as hydration. A live candidate never survives a
    /// restart, but its deduplication marker does, even when delivery is muted.
    static func owe(_ db: Database, dm: String, message: String, me: String) throws -> Bool {
        guard let m = try messages(db, dm).first(where: { $0.id == message }), m.hasFixed,
              !m.deleted, !m.loading, m.authorAccountId != me, let seq = m.seq,
              seq > (try mark(db, dm, root: m.threadRootId)) else { return false }
        try db.execute(sql: "INSERT OR IGNORE INTO dm_notified (dm_id, message_id, seq, root) VALUES (?, ?, ?, ?)",
                       arguments: [dm, message, seq, m.threadRootId])
        return db.changesCount > 0
    }
    static func markAllRead(_ db: Database, _ dm: String) throws {
        let head = max(try Int.fetchOne(db, sql: "SELECT head FROM dm_cards WHERE dm_id = ?", arguments: [dm]) ?? 0,
                       try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM dm_messages WHERE dm_id = ?", arguments: [dm]) ?? 0,
                       try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM dm_pending WHERE dm_id = ?", arguments: [dm]) ?? 0)
        try markRead(db, dm, through: head); try markRead(db, dm, root: "*", through: head)
        try db.execute(sql: "UPDATE dm_notified SET read = 1 WHERE dm_id = ? AND seq <= ?", arguments: [dm, head])
    }
}

@MainActor
enum ChatDMNotices {
    static func event(_ key: ChatOrgKey, dm: String, message: ChatMessage, service: ChatService) -> AttentionEvent {
        AttentionEvent(source: "dm-message", object: dm, episode: message.id, kind: .dm,
            destination: .directMessage(dm, message: message.id, thread: message.threadRootId, sequence: message.seq ?? 0),
            scope: ChatAttention.scope(key, service), timestamp: ChatStore.date(message.createdAt ?? "") ?? .distantPast)
    }
    static func live(_ service: ChatService, _ key: ChatOrgKey, dm: String, id: String) {
        guard service.dmAllowed(key, dm), let store = service.orgSessions[key]?.store,
              let message = try? store.dmRead({ try ChatDMStore.messages($0, dm).first { $0.id == id } }) else { return }
        var notice = event(key, dm: dm, message: message, service: service)
        guard valid(notice, service: service, requireDelivered: false) else {
            try? store.dmWrite { try $0.execute(sql: "UPDATE dm_notified SET delivered = 1, read = 1 WHERE dm_id = ? AND message_id = ?", arguments: [dm, id]) }
            return
        }
        notice.isRead = ChatNotifications.isLooking(ChatDMRef(key, dm: dm).place + (message.threadRootId.map { ":thread:\($0)" } ?? ""))
        guard (try? store.dmWrite({ db -> Bool in
            try db.execute(sql: "UPDATE dm_notified SET delivered = 1, read = ? WHERE dm_id = ? AND message_id = ? AND delivered = 0 AND read = 0", arguments: [notice.isRead, dm, id])
            return db.changesCount > 0
        })) == true else { return }
        if !notice.isRead { ChatNotifications.emit(notice); ChatNotifications.post(notice.id, notice.title) }
    }
    static func valid(_ event: AttentionEvent, service: ChatService, requireDelivered: Bool = true) -> Bool {
        guard let scope = event.scope, ChatAttention.sameScope(scope, service), let key = ChatAttention.key(scope),
              case .directMessage(let dm, let id, _, _) = event.destination,
              service.dmAllowed(key, dm), let store = service.orgSessions[key]?.store else { return false }
        return (try? store.dmRead { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM dm_notified n JOIN dm_messages m USING (dm_id, message_id)
                LEFT JOIN dm_preferences p USING (dm_id)
                WHERE n.dm_id = ? AND n.message_id = ? AND n.read = 0 AND (? = 0 OR n.delivered = 1)
                AND m.deleted = 0 AND m.stale IS NULL AND COALESCE(p.muted, 0) = 0)
                """, arguments: [dm, id, requireDelivered]) == true
        }) ?? false
    }
    static func events(_ service: ChatService, _ key: ChatOrgKey) -> [AttentionEvent] {
        guard service.dmAllowed(key), let store = service.orgSessions[key]?.store else { return [] }
        let rows = (try? store.dmRead { try Row.fetchAll($0, sql: "SELECT dm_id, message_id FROM dm_notified WHERE delivered = 1 AND read = 0 ORDER BY seq DESC LIMIT 100") }) ?? []
        return rows.compactMap { row in
            let dm: String = row["dm_id"], id: String = row["message_id"]
            guard let message = try? store.dmRead({ try ChatDMStore.messages($0, dm).first { $0.id == id } }) else { return nil }
            let notice = event(key, dm: dm, message: message, service: service)
            return valid(notice, service: service) ? notice : nil
        }
    }
}

/// Implements the sidebar extension independently of window lifetimes.
@MainActor
final class ChatDMAttentionSource: AttentionDMSource {
    private weak var service: ChatService?
    private var scope: AttentionScope?
    private var changed: (([AttentionConversation]) -> Void)?
    private var observation: ChatSnapshotObservation<[ChatDMEntry]>?
    private var epoch = UUID()
    private var rows: [ChatDMEntry] = []
    private(set) var conversations: [AttentionConversation] = []
    private let immediateInitialValue: Bool
    init(service: ChatService = .shared, immediateInitialValue: Bool = true) {
        self.service = service; self.immediateInitialValue = immediateInitialValue
    }
    func start(scope: AttentionScope, changed: @escaping ([AttentionConversation]) -> Void) {
        stop(); self.scope = scope; self.changed = changed
        guard let service, let key = ChatAttention.key(scope), let store = service.orgSessions[key]?.store else { changed([]); return }
        let captured = epoch
        observation = ChatSnapshotObservation(in: store.queue,
            tracking: ["meta", "dm_meta", "members", "dm_cards", "dm_marks", "dm_messages", "dm_changes", "outbox", "dm_pending", "dm_preferences"],
            immediateInitialValue: immediateInitialValue, fetch: { db in
            return try ChatDMEntry.read(db, me: key.accountId)
        }, onError: { [weak self] _ in
            guard let self, epoch == captured else { return }
            rows = []; refresh()
        }, onChange: { [weak self] rows in
            guard let self, epoch == captured else { return }; self.rows = rows; refresh()
        })
    }
    func refresh() {
        // The connection may have no DM capability or synchronizer at all.
        // Reject that in-memory gate before sameScope reads the cache generation.
        guard let service, let scope, let key = ChatAttention.key(scope), service.dmAllowed(key), ChatAttention.sameScope(scope, service) else {
            conversations = []; changed?([]); return
        }
        let previous = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        conversations = rows.map { row in
            var value = previous[row.id] ?? AttentionConversation(scope: scope, id: row.id, title: "", count: 0, time: .distantPast)
            value.title = row.card.peer.name; value.subjectID = row.card.peer.accountId; value.subjectName = row.card.peer.name
            value.count = max(row.unread ? 1 : 0, row.roots.count + row.replies)
            value.time = row.lastUsed; value.muted = row.roots.muted
            value.readMarks = row.readMarks
            value.unreadLabel = row.roots.something ? "Unread activity" : "\(row.roots.count)\(row.roots.more ? "+" : "") roots · \(row.replies) replies"
            return value
        }
        changed?(conversations.filter { $0.count > 0 && !$0.muted })
    }
    func stop() { epoch = UUID(); observation?.cancel(); observation = nil; rows = []; conversations = []; changed?([]); changed = nil; scope = nil }
    func open(_ conversation: String, scope: AttentionScope, from store: WorkspaceStore? = nil) {
        guard let service, ChatAttention.sameScope(scope, service), let key = ChatAttention.key(scope) else { return }
        ChatDMTabs.open(ChatDMRef(key, dm: conversation), from: store, service: service)
    }
    func markRead(_ conversation: String, scope: AttentionScope) {
        guard let service, ChatAttention.sameScope(scope, service), let key = ChatAttention.key(scope), service.dmAllowed(key, conversation) else { return }
        try? service.orgSessions[key]?.store?.dmWrite { try ChatDMStore.markAllRead($0, conversation) }
    }
}
