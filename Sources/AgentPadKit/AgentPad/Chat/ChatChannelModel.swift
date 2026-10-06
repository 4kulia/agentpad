import Foundation
import GRDB
import Observation

/// One channel tab's feed, thread and composer (DESIGN-F3), read from the
/// cache whenever it changes — never by polling. Changes go as commands
/// through the queue (`ChatConversation`). Shown only while the tab's
/// state is "ready" (F2): the view asks nothing of it otherwise.
@MainActor
@Observable
final class ChatChannelModel {
    struct Feed: Equatable {
        var messages: [ChatMessage] = []
        var replies: [String: Int] = [:]
        /// F5: requests to agents each root's thread has.
        var requests: [String: Int] = [:]
        /// More is kept in the cache below what shows, or the server has more.
        var hasOlder = false
        var historyNext: Int?
        var archived = true
    }

    let key: ChatOrgKey
    let channel: String
    private(set) var feed = Feed()
    private(set) var thread: [ChatMessage] = []
    private(set) var threadRoot: String?
    private(set) var threadHasEarlier = false
    /// Shared by the feed and thread, including a root visible in both.
    struct Editing: Equatable {
        let messageId: String
        let root: String?
        var text: String
        let revision: Int
        var problem: String?
    }
    var editing: Editing?
    @ObservationIgnored private var editingObservation: AnyDatabaseCancellable?
    /// F5: the requests to agents in the thread open.
    private(set) var threadRequests: [ChatChannelRequests.Card] = []
    /// The last problem of an action, in words.
    private(set) var problem: String?
    /// F5: "Ask" offered after the user's own messages named an agent of
    /// the channel; and the asks the queue holds (living or refused).
    private(set) var offers: [ChatChannelAsk.Offer] = []
    private(set) var asks: [ChatChannelAsk.Asked] = []
    private(set) var sourceStatuses: [ChatSourceStatus] = []
    private var sourceStatusRevision = 0
    @ObservationIgnored private var statusObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var statusDetailsWatch: AnyDatabaseCancellable?
    @ObservationIgnored private var statusJournalWatch: AnyDatabaseCancellable?

    /// How many root messages show; grows by `page` as the user scrolls up.
    private(set) var shown = 50
    static let page = 50
    /// The server's limit of a message's text (F-API).
    static let maxBytes = 16 * 1024

    @ObservationIgnored var service: ChatService = .shared
    @ObservationIgnored private var store: ChatStore?
    @ObservationIgnored private var feedObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var threadObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var asksObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var threadRequestsObservation: AnyDatabaseCancellable?
    /// The revision each message was last asked to be read for: asked again
    /// for a newer one. The asking itself — one at a time, retried — is
    /// `ChatSync.readOne`, the one way of single reads (review F3c-2).
    @ObservationIgnored private var readFor: [String: Int] = [:]

    init(key: ChatOrgKey, channel: String) {
        self.key = key
        self.channel = channel
    }

    // MARK: Following the cache

    func follow(_ store: ChatStore) {
        self.store = store
        observeFeed()
        let channel = channel
        asksObservation = ValueObservation.tracking { db in try ChatChannelAsk.asks(db, channel: channel) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] asks in self?.asks = asks }
        statusObservation = ValueObservation.tracking { db in try ChatSourceStatus.read(db, channel: channel) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] statuses in self?.sourceStatuses = statuses }
        // The progress row used to poll these details every second, including
        // finished runs. Follow publication/cancellation changes instead.
        let details = CoalescedMainActorAction { [weak self] in self?.sourceStatusRevision += 1 }
        statusDetailsWatch = DatabaseRegionObservation(tracking: Table("outbox"), Table("publication_intents"))
            .start(in: store.queue, onError: { _ in }) { _ in details.schedule() }
        statusJournalWatch = nil
        if let journal = service.journal {
            statusJournalWatch = DatabaseRegionObservation(tracking: Table("runs"), Table("approvals"), Table("automatic_request_blocks"))
                .start(in: journal.queue, onError: { _ in }) { _ in details.schedule() }
        }
    }

    func sourceStatusWord(_ status: ChatSourceStatus) -> String {
        _ = sourceStatusRevision
        return service.sourceStatusWord(status, key: key)
    }

    private func observeFeed() {
        guard let store else { return }
        let channel = channel, shown = shown
        feedObservation = ValueObservation.tracking { db in try Self.readFeed(db, channel: channel, shown: shown) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] feed in
                self?.feed = feed
                self?.completeShown(feed.messages)
            }
    }

    nonisolated static func readFeed(_ db: Database, channel: String, shown: Int) throws -> Feed {
        let window = try Row.fetchOne(db, sql: "SELECT bottom_seq, history_next FROM channel_windows WHERE channel_id = ?", arguments: [channel])
        let bottom: Int = window?["bottom_seq"] ?? 0
        var rows = try Row.fetchAll(db, sql: """
            \(ChatMessages.select) WHERE m.channel_id = ? AND m.thread_root_id IS NULL AND m.seq >= ? ORDER BY m.seq DESC LIMIT ?
            """, arguments: [channel, bottom, shown + 1]).map(ChatMessage.init(row:))
        let older = rows.count > shown
        if older { rows.removeLast() }
        rows.reverse()
        let local = try Row.fetchAll(db, sql: """
            \(ChatMessages.select) WHERE m.channel_id = ? AND m.thread_root_id IS NULL AND m.local_state IS NOT NULL
                AND (m.seq IS NULL OR m.seq < ?) ORDER BY m.created_at
            """, arguments: [channel, bottom]).map(ChatMessage.init(row:))
        var replies: [String: Int] = [:]
        let ids = rows.map(\.messageId)
        if !ids.isEmpty {
            let marks = ids.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT thread_root_id, COUNT(*) AS n FROM messages WHERE channel_id = ? AND thread_root_id IN (\(marks)) GROUP BY thread_root_id
                """, arguments: StatementArguments([channel] + ids)) {
                replies[row["thread_root_id"]] = row["n"]
            }
        }
        let next: Int? = window?["history_next"]
        return Feed(messages: rows + local, replies: replies, requests: try ChatChannelRequests.counts(db, channel: channel, roots: ids),
                    hasOlder: older || next != nil, historyNext: next,
                    archived: try Bool.fetchOne(db, sql: "SELECT archived FROM channels WHERE channel_id = ?", arguments: [channel]) ?? true)
    }

    /// A message that shows as a placeholder or with a newer revision known
    /// is read once, alone (DESIGN-F3, "Кадр без message").
    private func completeShown(_ messages: [ChatMessage]) {
        guard let sync = service.orgSessions[key]?.sync else { return }
        for m in messages where m.needsRead {
            let known = m.stale ?? m.revision
            guard let seq = m.seq, readFor[m.messageId] != known else { continue }
            readFor[m.messageId] = known
            sync.readOne(channel, id: m.messageId, seq: seq, atLeast: known)
        }
    }

    func discardEdit(_ message: ChatMessage) { service.discardEdit(key, messageId: message.messageId) }

    // MARK: History and threads

    /// Up: more of the cache first, then a page of the server's.
    func loadOlder() {
        if feed.messages.filter({ $0.seq != nil }).count >= shown {
            shown += Self.page
            observeFeed()
        } else if feed.historyNext != nil, let sync = service.orgSessions[key]?.sync {
            shown += Self.page
            observeFeed()
            let channel = channel
            Task { await sync.readChannel(channel, .history) }
        }
    }

    func openThread(_ root: String?) {
        if let editing, editing.root != nil, editing.root != root { cancelEditing() }
        threadRoot = root
        threadObservation = nil
        threadRequestsObservation = nil
        thread = []
        threadRequests = []
        guard let root, let store else { return }
        let channel = channel
        threadRequestsObservation = ValueObservation.tracking { db in try ChatChannelRequests.read(db, channel: channel, root: root) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] cards in
                guard let self, self.threadRoot == root else { return }
                self.threadRequests = cards
            }
        let observation = ValueObservation.tracking { db -> ([ChatMessage], Bool, Bool) in
            let cursor = try Row.fetchOne(db, sql: "SELECT next, shown_from FROM thread_cursors WHERE channel_id = ? AND root_id = ?",
                                          arguments: [channel, root])
            let from: Int = cursor?["shown_from"] ?? Int.max
            let bottom = try Int.fetchOne(db, sql: "SELECT bottom_seq FROM channel_windows WHERE channel_id = ?", arguments: [channel]) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                \(ChatMessages.select) WHERE m.message_id = ? OR (m.thread_root_id = ? AND (m.seq IS NULL OR m.seq >= ?))
                ORDER BY m.seq IS NULL, m.seq, m.created_at
                """, arguments: [root, root, min(from, bottom)]).map(ChatMessage.init(row:))
            return (rows, cursor != nil, (cursor?["next"] as Int?) != nil)
        }
        threadObservation = observation.removeDuplicates(by: { lhs, rhs in
            lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
        })
        .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] value in
            guard let self, self.threadRoot == root else { return }
            self.thread = value.0
            self.threadHasEarlier = value.2
            self.completeShown(value.0)
        }
        // Its first page, once: the thread's own way on starts there (review F3-4).
        if let sync = service.orgSessions[key]?.sync,
           (try? store.queue.read({ db in
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM thread_cursors WHERE channel_id = ? AND root_id = ?)",
                                 arguments: [channel, root])
           })) != true {
            Task { await sync.readChannel(channel, .thread(root: root, more: false)) }
        }
    }

    func earlierReplies() {
        guard let root = threadRoot, let sync = service.orgSessions[key]?.sync else { return }
        let channel = channel
        Task { await sync.readChannel(channel, .thread(root: root, more: true)) }
    }

    // MARK: Writing

    /// Nil when `text` may be sent: 1 byte to 16 KiB of UTF-8 (F-API).
    static func textProblem(_ text: String) -> String? {
        let bytes = text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
        if bytes == 0 { return "Write something first." }
        return text.utf8.count > maxBytes ? "The message is too long: at most 16 KiB." : nil
    }

    /// `@handle` of a member of the channel's team, as `mentions` (at most 50).
    static func mentions(in text: String, members: [(account: String, handle: String)]) -> [String] {
        var found: [String] = []
        for member in members where !member.handle.isEmpty {
            let pattern = "(?<![\\w@])@" + NSRegularExpression.escapedPattern(for: member.handle) + "(?![\\w-])"
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil, !found.contains(member.account) {
                found.append(member.account)
            }
        }
        return Array(found.prefix(50))
    }

    /// Who may be mentioned: the members of the channel's team only (review F3-p2-4).
    static func mentionable(_ members: [ChatOrgView.Member], team: [String]) -> [(account: String, handle: String)] {
        members.filter { team.contains($0.accountId) }.map { ($0.accountId, $0.handle) }
    }

    /// `agents`: the channel's agents seen now — those `text` names are offered to ask (F5).
    func send(_ text: String, root: String?, members: [(account: String, handle: String)], agents: [ChatChannelAgent] = [],
              draftVersion: String? = nil, mentionOnly: Bool = false, context: [ChatMessage] = []) -> Bool {
        if let problem = Self.textProblem(text) { self.problem = problem; return false }
        do {
            if service.supports("chat.channel_ux1", key: key) {
                if draftVersion == nil { saveDraft(text, root: root) }
                guard let version = draftVersion ?? self.draftVersion(root: root) else { return false }
                _ = try service.sendChannel(key, channel: channel, root: root, text: text,
                    mentions: Self.mentions(in: text, members: members), agents: agents, draftVersion: version,
                    mentionOnly: mentionOnly, additionalContext: context)
                problem = nil
                return true
            }
            let id = try service.post(key, channel: channel, root: root, text: text, mentions: Self.mentions(in: text, members: members))
            problem = nil
            saveDraft("", root: root)
            for agent in mentionOnly ? [] : ChatChannelAsk.asked(in: text, agents: agents) {
                offers.append(.init(messageId: id, agentId: agent.agentId, address: agent.address ?? agent.name, text: text, root: root ?? id))
            }
            return true
        } catch {
            problem = "Not sent: \(error.localizedDescription)"
            return false
        }
    }

    func canEdit(_ message: ChatMessage) -> Bool {
        !feed.archived && message.channelId == channel && message.authorAccountId == key.accountId
            && message.authorAgentId == nil && message.authorSessionName == nil && message.seq != nil && message.hasFixed && message.hasMutable
            && !message.deleted && !message.loading && !message.changing && message.localState == nil
    }

    /// Only messages in the visible conversation, ordered by server sequence.
    /// Whitespace is a draft too: the shortcut requires a literally empty field.
    func lastEditableMessage(root: String?) -> ChatMessage? {
        guard editing == nil, root == nil || root == threadRoot else { return nil }
        return (root == nil ? feed.messages : thread).filter { message in
            canEdit(message) && (root.map { message.threadRootId == $0 || message.messageId == $0 }
                ?? (message.threadRootId == nil))
        }.max { ($0.seq ?? 0) < ($1.seq ?? 0) }
    }

    @discardableResult
    func editLastMessage(root: String?, composerText: String) -> Bool {
        guard composerText.isEmpty, let message = lastEditableMessage(root: root) else { return false }
        return beginEditing(message, root: root)
    }

    @discardableResult
    func beginEditing(_ shown: ChatMessage, root: String?, recovering: Bool = false) -> Bool {
        guard editing == nil, let current = message(shown.messageId) else { return false }
        // Failed edits remain available to read/copy after archival (F3d-3).
        let recoverable = recovering && current.localEdit?.kind == "edit" && current.localEdit?.state == "failed"
            && current.authorAccountId == key.accountId && current.authorAgentId == nil && current.authorSessionName == nil && !current.deleted
        guard canEdit(current) || recoverable else { return false }
        editing = Editing(messageId: current.messageId, root: root,
                          text: recoverable ? current.localEdit?.text ?? current.text : current.text,
                          revision: current.revision)
        if let store {
            let id = current.messageId
            editingObservation = ValueObservation.tracking { db in
                try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ?", arguments: [id]).map(ChatMessage.init(row:))
            }.start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] message in
                // A new revision does not replace the editor's original revision or draft.
                if message == nil || message?.deleted == true { self?.cancelEditing() }
            }
        }
        return true
    }

    func cancelEditing() {
        editing = nil
        editingObservation = nil
    }

    /// Nil when the edit went to the queue; else why not — the editor then
    /// stays open with the user's text (review F3-p2-2).
    /// `revision`: the one the editor was opened on (review F3-p1-1).
    func edit(_ message: ChatMessage, to text: String, revision: Int, members: [(account: String, handle: String)]) -> String? {
        if let problem = Self.textProblem(text) { return problem }
        if message.changing { return ChatChangeError.busy.localizedDescription }
        do {
            try service.change(key, messageId: message.messageId, text: text, mentions: Self.mentions(in: text, members: members),
                               expectedRevision: revision)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `revision`: the one shown when the confirmation opened.
    func delete(_ message: ChatMessage, revision: Int) {
        do { try service.change(key, messageId: message.messageId, text: nil, expectedRevision: revision) }
        catch { problem = error.localizedDescription }
    }

    func retry(_ message: ChatMessage) {
        do { try service.retry(key, messageId: message.messageId) } catch { problem = error.localizedDescription }
    }

    func discard(_ message: ChatMessage) {
        do { try service.discard(key, messageId: message.messageId) } catch { problem = error.localizedDescription }
    }

    // MARK: Asking an agent (F5)

    func dismissOffer(_ offer: ChatChannelAsk.Offer) { offers.removeAll { $0.id == offer.id } }

    /// The message that asked, as the cache has it now.
    func message(_ id: String) -> ChatMessage? {
        (try? store?.queue.read { db in
            try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ?", arguments: [id]).map(ChatMessage.init(row:))
        }) ?? nil
    }

    /// What may be given as context: the thread the agent answers in, and
    /// the channel's last root messages — only what the feed holds (F2 gate).
    func contextCandidates(root: String) -> [ChatMessage] {
        let channel = channel
        let rows = (try? store?.queue.read { db -> [ChatMessage] in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true
            else { return [] }
            let thread = try Row.fetchAll(db, sql: """
                \(ChatMessages.select) WHERE m.channel_id = ? AND (m.message_id = ? OR m.thread_root_id = ?) ORDER BY m.seq
                """, arguments: [channel, root, root]).map(ChatMessage.init(row:))
            let roots = try Row.fetchAll(db, sql: """
                \(ChatMessages.select) WHERE m.channel_id = ? AND m.thread_root_id IS NULL AND m.seq IS NOT NULL ORDER BY m.seq DESC LIMIT 30
                """, arguments: [channel]).map(ChatMessage.init(row:)).reversed()
            return thread + roots.filter { r in !thread.contains { $0.messageId == r.messageId } }
        }) ?? nil ?? []
        return rows.filter(ChatChannelAsk.eligible)
    }

    /// Nil when the request went to the queue; else why not. Only once the
    /// message that asked is the server's: the answer's thread must be a
    /// root it has.
    func ask(_ offer: ChatChannelAsk.Offer, text: String, context: [ChatMessage], agents: [ChatChannelAgent]) -> String? {
        if let problem = ChatChannelAsk.textProblem(text) { return problem }
        guard agents.contains(where: { $0.agentId == offer.agentId && $0.enabled }) else { return "The agent is no longer in the channel." }
        guard let root = message(offer.root), ChatChannelAsk.eligible(root) else { return "The message is not sent yet." }
        let taken = ChatChannelAsk.fit(context, root: offer.root).taken
        do {
            if offer.ux1 {
                guard let source = message(offer.messageId), source.text == text,
                      let agent = agents.first(where: { $0.agentId == offer.agentId }) else { return "The question changed. Review it and choose the context again." }
                try service.retryChannelCall(key, source: source, agent: agent, context: taken)
            } else {
                try service.askInChannel(key, channel: channel, agentId: offer.agentId, root: offer.root, text: text, context: taken)
            }
            dismissOffer(offer)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func dismissAsk(_ asked: ChatChannelAsk.Asked) { service.dismissAsk(key, commandId: asked.commandId) }

    // MARK: Reading (F4)

    /// The feed shows at its end in front of the user: read up to its last
    /// root; notices of what is read go.
    func markRead() {
        MainThreadWatchdog.shared.checkpoint()
        // Up to the last message wholly known, never past a placeholder (review F4c-1).
        let known = feed.messages.filter { $0.seq != nil }
        let firstUnknown = known.filter { !$0.hasFixed }.compactMap(\.seq).min()
        let wholly = known.filter { m in m.hasFixed && (firstUnknown.map { (m.seq ?? 0) < $0 } ?? true) }
        guard let last = wholly.compactMap(\.seq).max(), let store else { return }
        let channel = channel
        let ids = (try? store.queue.write { db in try ChatUnread.markRead(db, channel: channel, upTo: last) }) ?? []
        if !ids.isEmpty { ChatNotifications.reconcile(service) }
    }

    /// The thread's panel is open: its notices are read.
    func markThreadRead(_ root: String) {
        guard let store else { return }
        let channel = channel
        let ids = (try? store.queue.write { db in try ChatUnread.markRead(db, channel: channel, upTo: 0, thread: root) }) ?? []
        if !ids.isEmpty { ChatNotifications.reconcile(service) }
    }

    // MARK: Drafts

    func draft(root: String?) -> String {
        (try? store?.queue.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""])
        }) ?? nil ?? ""
    }

    func draftVersion(root: String?) -> String? {
        try? store?.queue.read { try String.fetchOne($0, sql: "SELECT version FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""]) }
    }

    /// Kept only while the channel's card is and the rights are not in doubt:
    /// a save made late — after the user left the team — writes nothing
    /// (review F3-p1-3).
    func saveDraft(_ text: String, root: String?) {
        let channel = channel
        try? store?.queue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true,
                  try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") != true else { return }
            if text.isEmpty {
                try db.execute(sql: "DELETE FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""])
            } else {
                try db.execute(sql: """
                    INSERT INTO drafts (channel_id, thread_root_id, text, updated_at, version) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(channel_id, thread_root_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at,
                        version = CASE WHEN text = excluded.text THEN version ELSE excluded.version END
                    """, arguments: [channel, root ?? "", text, Date().timeIntervalSince1970, UUID().uuidString.lowercased()])
            }
        }
    }

    // MARK: Words

    /// Why a post was not sent, from the queue's code.
    static func reason(_ code: String?) -> String {
        switch code {
        case "forbidden", "not_found": return "You can't post here any more"
        case "channel_archived": return "The channel is archived"
        case "too_large": return "The message is too long"
        case "invalid_request": return "The server did not take it"
        default: return "Not sent" + (code.map { " (\($0))" } ?? "")
        }
    }
}
