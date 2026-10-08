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
    typealias ReadPage = @MainActor (ChatInboxLoading.Key, Int?) async throws -> ChatMessagesPage
    let ref: ChatInboxRef
    private var cached: [ChatInbox.Entry] = []
    private var localProblem: String?
    private var failed: Set<ChatInboxLoading.HistoryKey> = []
    private var deferred: Set<ChatInboxLoading.HistoryKey> = []
    var problem: String? {
        localProblem ?? (failed.isEmpty ? nil : "Some messages could not be loaded. Check your connection and try again, or open the channel.")
    }
    private(set) var loading = false
    var limited: Bool { !deferred.isEmpty }
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var store: ChatStore?
    @ObservationIgnored private weak var followedOrg: ChatOrgModel?
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var readPage: ReadPage?
    @ObservationIgnored private var targets: [ChatInboxLoading.Key] = []
    @ObservationIgnored private var attempted: Set<ChatInboxLoading.Key> = []
    @ObservationIgnored private var progress: [ChatInboxLoading.HistoryKey: ChatInboxLoading.Progress] = [:]
    @ObservationIgnored private var remainingPages = ChatInboxLoading.pagesPerPass
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(ref: ChatInboxRef) { self.ref = ref }

    func follow(_ store: ChatStore, org: ChatOrgModel, readPage: ReadPage? = nil) {
        self.readPage = readPage
        guard self.store !== store || followedOrg !== org || session != org.session || observation == nil else {
            loadIfNeeded(); return
        }
        stop()
        self.store = store; followedOrg = org; self.session = org.session; self.readPage = readPage
        let ref = ref, session = org.session, generation = generation
        observation = ValueObservation.tracking { db in
            try ChatInboxLoading.snapshot(db, ref: ref, session: session)
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.cached = []; self.localProblem = "Could not load messages. Try again."
            self.observation = nil
        }) { [weak self] snapshot in
            guard let self, self.generation == generation else { return }
            self.cached = snapshot.entries; self.targets = snapshot.targets
            self.discardOldTargets()
            self.loadIfNeeded()
        }
    }

    func stop() {
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        observation = nil; store = nil; followedOrg = nil; readPage = nil
        cached = []; targets = []; attempted = []; progress = [:]
        remainingPages = ChatInboxLoading.pagesPerPass
        loading = false; deferred = []; failed = []; localProblem = nil
    }

    func retry() {
        guard !loading, let store, let org = followedOrg else { return }
        localProblem = nil; deferred = []; failed = []; attempted = []
        remainingPages = ChatInboxLoading.pagesPerPass
        for key in progress.keys { progress[key]?.pages = 0 }
        follow(store, org: org, readPage: readPage)
    }

    private var currentTargets: [ChatInboxLoading.Key] {
        // Match ChatOrgModel.unread(): a followed stream counts messages, so
        // reactions/edits above the mark alone cannot imply unread history.
        targets.filter { !$0.unfollowedOnly || followedOrg?.isFollowed($0.channel) == false }
    }

    private func discardOldTargets() {
        let current = Set(currentTargets)
        let histories = Set(current.map(\.history))
        attempted.formIntersection(current)
        failed.formIntersection(histories); deferred.formIntersection(histories)
        progress = progress.filter { histories.contains($0.key) }
    }

    private func loadIfNeeded() {
        discardOldTargets()
        guard loadTask == nil, let store, let org = followedOrg, let readPage,
              case .ready = ref.state(org) else { return }
        let pending = currentTargets.filter { target in
            guard !attempted.contains(target), !failed.contains(target.history), !deferred.contains(target.history),
                  org.visibleChannel(target.channel) != nil else { return false }
            guard let saved = progress[target.history] else { return true }
            return !saved.complete || target.head > saved.through
        }
        guard !pending.isEmpty else { return }
        let generation = generation
        loading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            for target in pending {
                guard self.isCurrent(generation, store: store, org: org) else { break }
                self.attempted.insert(target)
                let history = target.history
                var saved = self.progress[history] ?? ChatInboxLoading.Progress(after: target.after, through: target.head)
                if saved.complete {
                    // Catch up above the covered range only after its history
                    // is complete. A newer head never replaces an older cursor.
                    saved = ChatInboxLoading.Progress(after: max(target.after, saved.through), through: target.head, pages: saved.pages)
                }
                guard self.remainingPages > 0, saved.pages < ChatInboxLoading.pagesPerChannel else {
                    self.deferred.insert(history); continue
                }
                do {
                    while self.remainingPages > 0 && saved.pages < ChatInboxLoading.pagesPerChannel {
                        guard self.isCurrent(generation, store: store, org: org),
                              org.visibleChannel(target.channel) != nil,
                              try self.canRead(store, target) else { break }
                        self.remainingPages -= 1; saved.pages += 1
                        self.progress[history] = saved
                        let page = try await readPage(target, saved.before)
                        guard self.isCurrent(generation, store: store, org: org),
                              org.visibleChannel(target.channel) != nil else { break }
                        guard try self.apply(page, target: target, store: store) else { break }
                        guard let next = page.next, next > saved.after else {
                            saved.before = nil; saved.complete = true
                            self.progress[history] = saved
                            if target.head > saved.through { self.attempted.remove(target) }
                            break
                        }
                        // A repeated/nondecreasing cursor cannot make progress.
                        guard saved.before.map({ next < $0 }) ?? true else { throw ChatInboxLoadError.pagination }
                        saved.before = next; self.progress[history] = saved
                        if self.remainingPages == 0 || saved.pages == ChatInboxLoading.pagesPerChannel {
                            self.deferred.insert(history); break
                        }
                    }
                } catch {
                    guard self.isCurrent(generation, store: store, org: org) else { break }
                    self.failed.insert(history)
                }
            }
            guard self.generation == generation else { return }
            self.loading = false; self.loadTask = nil
            self.discardOldTargets()
            // Observations received during an await may carry a newer head or
            // window. Our own merges keep those keys and cannot cause a loop.
            self.loadIfNeeded()
        }
    }

    private func isCurrent(_ generation: UUID, store: ChatStore, org: ChatOrgModel) -> Bool {
        guard !Task.isCancelled, self.generation == generation, self.store === store, followedOrg === org,
              session == org.session, case .ready = ref.state(org) else { return false }
        return true
    }

    private func canRead(_ store: ChatStore, _ target: ChatInboxLoading.Key) throws -> Bool {
        try store.queue.read { try ChatInboxLoading.allowed($0, target: target, account: ref.account, session: session) }
    }

    private func apply(_ page: ChatMessagesPage, target: ChatInboxLoading.Key, store: ChatStore) throws -> Bool {
        try store.queue.write { db in
            guard try ChatInboxLoading.allowed(db, target: target, account: ref.account, session: session) else { return false }
            // This may be a disjoint inbox page. Never advance event cursors or
            // claim that the channel/thread reading window is continuous.
            for message in page.messages where message.channelId == target.channel {
                try ChatMessages.write(db, message)
            }
            return true
        }
    }

    func entries(_ org: ChatOrgModel?) -> [ChatInbox.Entry] {
        guard let org, org === followedOrg, case .ready = ref.state(org) else { return [] }
        return cached.filter { org.visibleChannel($0.message.channelId) != nil }
    }

    func markAllRead(_ org: ChatOrgModel?, service: ChatService = .shared) {
        guard let org, org === followedOrg, case .ready = ref.state(org), let store else { return }
        do {
            let channels = try store.queue.write { try ChatInbox.markAllRead($0, account: ref.account, session: org.session) }
            localProblem = nil
            // Synchronous on the main actor, after commit; no newer event can
            // slip between the read transaction and dismissal of visit lines.
            NotificationCenter.default.post(name: .chatInboxMarkedRead, object: store, userInfo: ["channels": channels])
            ChatNotifications.reconcile(service)
        } catch {
            localProblem = "Could not mark messages as read. Try again."
        }
    }
}

enum ChatInboxLoadError: Error { case unavailable, pagination }
