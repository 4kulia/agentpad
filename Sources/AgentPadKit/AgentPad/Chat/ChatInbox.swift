import Foundation
import GRDB
import Observation

enum ChatInboxKind: String, Codable, CaseIterable, Sendable {
    case unread, mentions
    var title: String { self == .unread ? "Unread" : "Mentions" }
    var symbol: String { self == .unread ? "tray" : "at" }
}

/// Only a destination is persisted, never channel names or message content.
struct ChatInboxRef: Codable, Equatable, Hashable, Sendable {
    var server, account, org: String
    var kind: ChatInboxKind

    init(_ key: ChatOrgKey, kind: ChatInboxKind) {
        server = key.server.description; account = key.accountId; org = key.orgId; self.kind = kind
    }

    func belongs(to key: ChatOrgKey) -> Bool {
        server == key.server.description && account == key.accountId && org == key.orgId
    }

    @MainActor
    func state(_ model: ChatOrgModel?) -> ChatSidebarSnapshot.State {
        guard let model, let key = model.key, belongs(to: key) else { return .notConnected }
        return ChatSidebarSnapshot(model: model, active: nil).state
    }
}

enum ChatInbox {
    struct Entry: Identifiable, Equatable, Sendable {
        var message: ChatMessage
        var unread: Bool
        var id: String { message.messageId }
    }

    static func allowed(_ db: Database, account: String, session: String?) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT me, rights_in_doubt, rights_session, channels_served FROM meta WHERE id = 1") else { return false }
        return row["me"] as String? == account && !(row["rights_in_doubt"] as Bool) && row["channels_served"] as Bool
            && (session == nil || row["rights_session"] as String? == session)
    }

    static func read(_ db: Database, kind: ChatInboxKind, account: String, session: String?) throws -> [Entry] {
        guard try allowed(db, account: account, session: session) else { return [] }
        let unread = kind == .mentions ? ChatUnread.unreadMentionSQL : ChatUnread.unreadSQL
        let filter = kind == .mentions ? ChatUnread.mentionSQL : """
            (m.author_account_id IS NULL OR m.author_account_id != (SELECT me FROM meta WHERE id = 1))
            AND \(unread)
            """
        let order = kind == .mentions ? "julianday(m.created_at) DESC, m.seq DESC, m.message_id" : "c.name COLLATE NOCASE, c.channel_id, m.seq, m.message_id"
        return try Row.fetchAll(db, sql: """
            SELECT m.*, (\(unread)) AS inbox_unread FROM messages m
            JOIN channels c ON c.channel_id = m.channel_id JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
            \(ChatUnread.readJoins)
            WHERE \(filter) ORDER BY \(order)
            """).map { Entry(message: ChatMessage(row: $0), unread: $0["inbox_unread"] ?? false) }
    }

    /// One transaction fixes each head, including threads not loaded yet. A
    /// late history page below it stays read; later posts above it stay unread.
    static func markAllRead(_ db: Database, account: String, session: String?) throws -> Set<String> {
        guard try allowed(db, account: account, session: session) else { return [] }
        let channels = try String.fetchAll(db, sql: """
            SELECT c.channel_id FROM channels c JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
            """)
        for channel in channels {
            let head = try ChatUnread.boundary(db, channel: channel).through
            try ChatUnread.markRead(db, channel: channel, upTo: head)
            try db.execute(sql: "UPDATE read_marks SET thread_read_seq = MAX(thread_read_seq, ?) WHERE channel_id = ?", arguments: [head, channel])
            try db.execute(sql: "UPDATE notified SET read = 1 WHERE channel_id = ? AND seq <= ? AND kind IN ('mention', 'reply')", arguments: [channel, head])
        }
        return Set(channels)
    }
}

extension Notification.Name { static let chatInboxMarkedRead = Notification.Name("AgentPad.chatInboxMarkedRead") }

@MainActor
@Observable
final class ChatInboxModel {
    let ref: ChatInboxRef
    private var cached: [ChatInbox.Entry] = []
    private(set) var problem: String?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var store: ChatStore?
    @ObservationIgnored private weak var followedOrg: ChatOrgModel?

    init(ref: ChatInboxRef) { self.ref = ref }

    func follow(_ store: ChatStore, org: ChatOrgModel) {
        guard self.store !== store || followedOrg !== org else { return }
        self.store = store; followedOrg = org; cached = []; problem = nil
        let ref = ref, session = org.session
        observation = ValueObservation.tracking { db in
            try ChatInbox.read(db, kind: ref.kind, account: ref.account, session: session)
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in
            self?.cached = []; self?.problem = "Could not load messages. Reopen this tab to try again."
            self?.store = nil
        }) { [weak self] in self?.cached = $0; self?.problem = nil }
    }

    func entries(_ org: ChatOrgModel?) -> [ChatInbox.Entry] {
        guard let org, org === followedOrg, case .ready = ref.state(org) else { return [] }
        return cached.filter { org.visibleChannel($0.message.channelId) != nil }
    }

    func markAllRead(_ org: ChatOrgModel?, service: ChatService = .shared) {
        guard let org, org === followedOrg, case .ready = ref.state(org), let store else { return }
        do {
            let channels = try store.queue.write { try ChatInbox.markAllRead($0, account: ref.account, session: org.session) }
            problem = nil
            // Synchronous on the main actor, after commit; no newer event can
            // slip between the read transaction and dismissal of visit lines.
            NotificationCenter.default.post(name: .chatInboxMarkedRead, object: store, userInfo: ["channels": channels])
            ChatNotifications.reconcile(service)
        } catch {
            problem = "Could not mark messages as read. Try again."
        }
    }
}
