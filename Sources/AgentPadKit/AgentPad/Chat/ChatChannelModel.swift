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
        var replySummaries: [String: ChatReplySummary] = [:]
        var unreadID: String?
        var earlierUnread = false
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
    private(set) var entryReadSequence = 0
    var positions: [String: ChatScrollPosition] = [:]
    var revealMessageID: String?
    var focusedMessageID: String?
    var focusRequest: ChatFocusRequest?
    private(set) var readingPositionRestored = 0
    var searching = false
    private(set) var searchMessages: [ChatMessage] = []
    @ObservationIgnored private var searchObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var linkObservation: AnyDatabaseCancellable?
    private var feedRevealSequence: Int?
    private var navigationReturnRoot: String??
    private var navigationReturnPositions: [String: ChatScrollPosition] = [:]
    private var navigationReturnEdit: (id: String, root: String?)?
    /// Shared by the feed and thread, including a root visible in both.
    struct Editing: Equatable {
        let messageId: String
        var root: String?
        var text: String
        let revision: Int
        /// Independent of the cache window: the editor survives its eviction.
        var message: ChatMessage
        var problem: String?
    }
    var editing: Editing? {
        didSet { if let editing { editDrafts[editing.messageId] = editing } }
    }
    /// Navigation changes the active editor, never these per-message drafts.
    private var editDrafts: [String: Editing] = [:]
    private var editOrder: [String] = []
    @ObservationIgnored private var editingObservations: [String: AnyDatabaseCancellable] = [:]
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
    @ObservationIgnored private var threadRead: Task<Void, Never>?
    @ObservationIgnored private var threadReadID: UUID?
    @ObservationIgnored private var threadReadEpoch: Int?
    private var accessConfirmed = true
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
        editingObservations = [:]
        self.store = store
        let channel = channel
        entryReadSequence = (try? store.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", arguments: [channel])
        }) ?? 0
        observeFeed()
        observeThreadRequests()
        for id in editOrder { observeEdit(id) }
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

    func follows(_ candidate: ChatStore) -> Bool { store === candidate }

    func sourceStatusWord(_ status: ChatSourceStatus) -> String {
        _ = sourceStatusRevision
        return service.sourceStatusWord(status, key: key)
    }

    private func observeFeed() {
        guard let store else { return }
        let channel = channel, shown = shown, unreadAfter = entryReadSequence, reveal = feedRevealSequence
        feedObservation = ValueObservation.tracking { db in try Self.readFeed(db, channel: channel, shown: shown, unreadAfter: unreadAfter, revealSequence: reveal) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] feed in
                self?.feed = feed
                self?.completeShown(feed.messages)
            }
    }

    nonisolated static func readFeed(_ db: Database, channel: String, shown: Int, unreadAfter: Int? = nil, revealSequence: Int? = nil) throws -> Feed {
        let window = try Row.fetchOne(db, sql: "SELECT bottom_seq, history_next FROM channel_windows WHERE channel_id = ?", arguments: [channel])
        let windowBottom: Int = window?["bottom_seq"] ?? 0
        let bottom = min(windowBottom, revealSequence ?? windowBottom)
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
        var summaries: [String: ChatReplySummary] = [:]
        let ids = rows.map(\.messageId)
        if !ids.isEmpty {
            let marks = ids.map { _ in "?" }.joined(separator: ", ")
            let loaded = try Row.fetchAll(db, sql: """
                \(ChatMessages.select) WHERE m.channel_id = ? AND m.thread_root_id IN (\(marks)) ORDER BY m.seq
                """, arguments: StatementArguments([channel] + ids)).map(ChatMessage.init(row:))
            let cursors = try Row.fetchAll(db, sql: "SELECT root_id, next FROM thread_cursors WHERE channel_id = ?", arguments: [channel])
            let repliesByRoot = Dictionary(grouping: loaded, by: { $0.threadRootId ?? "" })
            let cursorsByRoot = Dictionary(uniqueKeysWithValues: cursors.map { (($0["root_id"] as String), $0) })
            for root in rows {
                let cursor = cursorsByRoot[root.messageId]
                let complete = cursor.map { ($0["next"] as Int?) == nil } ?? ((root.seq ?? -1) >= windowBottom)
                let summary = ChatReplySummary(messages: repliesByRoot[root.messageId] ?? [], complete: complete)
                summaries[root.messageId] = summary
                replies[root.messageId] = summary.count
            }
        }
        let firstUnread = try unreadAfter.flatMap { mark in
            try String.fetchOne(db, sql: "SELECT message_id FROM messages WHERE channel_id = ? AND thread_root_id IS NULL AND seq > ? ORDER BY seq LIMIT 1",
                                arguments: [channel, mark])
        }
        let earlierUnread = unreadAfter.map { windowBottom > $0 + 1 || (firstUnread != nil && !ids.contains(firstUnread!)) } ?? false

        let next: Int? = window?["history_next"]
        return Feed(messages: rows + local, replies: replies, replySummaries: summaries, unreadID: earlierUnread ? nil : firstUnread, earlierUnread: earlierUnread, requests: try ChatChannelRequests.counts(db, channel: channel, roots: ids),
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
        guard root != threadRoot else { observeThread(); return }
        editing = nil
        restoreEditing(root: root)
        focusedMessageID = root == nil ? threadRoot : nil
        threadRoot = root
        threadObservation = nil
        threadRequestsObservation = nil
        thread = []
        threadRequests = []
        threadHasEarlier = false
        cancelThreadRead()
        observeThreadRequests()
        observeThread()
    }

    private func observeThreadRequests() {
        threadRequestsObservation = nil
        guard let root = threadRoot, let store else { return }
        let channel = channel
        threadRequestsObservation = ValueObservation.tracking { db in try ChatChannelRequests.read(db, channel: channel, root: root) }
            .removeDuplicates()
            .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] cards in
                guard let self, self.threadRoot == root else { return }
                self.threadRequests = cards
            }
    }

    /// F2 checking hides the view but retains its model. Resume the open
    /// conversation only after ready confirms access to this same store.
    func setAccessConfirmed(_ confirmed: Bool) {
        accessConfirmed = confirmed
        if confirmed { observeThread() } else { cancelThreadRead() }
    }

    private struct ThreadSnapshot: Equatable {
        let messages: [ChatMessage]
        let hasCursor: Bool
        let hasEarlier: Bool
        let epoch: Int
        let accessible: Bool
    }

    private func observeThread() {
        guard let root = threadRoot, let store else { return }
        let channel = channel
        let target = revealMessageID.flatMap(message)
        let targetSequence = target?.threadRootId == root ? target?.seq : nil
        let observation = ValueObservation.tracking { db -> ThreadSnapshot in
            let epoch = try ChatMessages.epoch(db, channel)
            let cursor = try Row.fetchOne(db, sql: "SELECT next, shown_from FROM thread_cursors WHERE channel_id = ? AND root_id = ? AND epoch = ?",
                                          arguments: [channel, root, epoch])
            let accessible = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)
                    AND NOT (SELECT rights_in_doubt FROM meta WHERE id = 1)
                """, arguments: [channel]) == true
            let from: Int = cursor?["shown_from"] ?? Int.max
            let bottom = try Int.fetchOne(db, sql: "SELECT bottom_seq FROM channel_windows WHERE channel_id = ?", arguments: [channel]) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                \(ChatMessages.select) WHERE m.channel_id = ? AND (m.message_id = ? OR (m.thread_root_id = ? AND (m.seq IS NULL OR m.seq >= ?)))
                ORDER BY m.seq IS NULL, m.seq, m.created_at
                """, arguments: [channel, root, root, min(from, bottom, targetSequence ?? Int.max)]).map(ChatMessage.init(row:))
            return ThreadSnapshot(messages: rows, hasCursor: cursor != nil,
                                  hasEarlier: (cursor?["next"] as Int?) != nil, epoch: epoch, accessible: accessible)
        }
        threadObservation = observation.removeDuplicates()
        .start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] value in
            guard let self, self.threadRoot == root else { return }
            self.thread = value.messages
            self.threadHasEarlier = value.hasEarlier
            self.completeShown(value.messages)
            if !value.accessible { self.cancelThreadRead() }
            else if !value.hasCursor { self.loadThread(root, epoch: value.epoch) }
        }
    }

    private func cancelThreadRead() {
        threadRead?.cancel()
        threadRead = nil
        threadReadID = nil
        threadReadEpoch = nil
    }

    private func loadThread(_ root: String, epoch: Int) {
        guard accessConfirmed, let sync = service.orgSessions[key]?.sync, !sync.needsSnapshot else { return }
        guard threadRead == nil || threadReadEpoch != epoch else { return }
        cancelThreadRead()
        let id = UUID(), channel = channel
        threadReadID = id
        threadReadEpoch = epoch
        threadRead = Task { [weak self] in
            guard let self, self.threadReadID == id, self.threadRoot == root,
                  self.accessConfirmed, !Task.isCancelled else { return }
            await sync.readChannel(channel, .thread(root: root, more: false))
            guard self.threadReadID == id else { return }
            self.threadRead = nil
            self.threadReadID = nil
            self.threadReadEpoch = nil
        }
    }

    func earlierReplies() {
        guard let root = threadRoot, let sync = service.orgSessions[key]?.sync else { return }
        let channel = channel
        Task { await sync.readChannel(channel, .thread(root: root, more: true)) }
    }

    // MARK: Local search and navigation (no new server API)

    func navigate(to link: ChatMessageLink) {
        guard link.matches(key: key, channel: channel), let store else { return }
        linkObservation = nil
        if let cached = message(link.message), cached.hasFixed { navigate(to: cached); return }
        let id = link.message, channel = channel
        linkObservation = ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ? AND m.channel_id = ?", arguments: [id, channel]).map(ChatMessage.init(row:))
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] value in
            guard let self, let value, value.hasFixed else { return }
            self.navigate(to: value)
            self.linkObservation = nil
        }
        service.orgSessions[key]?.sync?.readOne(channel, id: id, seq: link.sequence, atLeast: 1)
    }

    func setSearching(_ value: Bool) {
        searching = value
        searchObservation = nil
        searchMessages = []
        guard value, let store else { return }
        let channel = channel
        searchObservation = ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
                \(ChatMessages.select) JOIN channels c ON c.channel_id = m.channel_id
                WHERE m.channel_id = ? AND m.has_fixed = 1 AND m.has_mutable = 1 AND m.deleted_at IS NULL ORDER BY m.seq
                """, arguments: [channel]).map(ChatMessage.init(row:))
        }.removeDuplicates().start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] in self?.searchMessages = $0 }
    }

    func navigate(to target: ChatMessage) {
        guard let current = message(target.messageId), current.channelId == channel else { return }
        if navigationReturnRoot == nil {
            navigationReturnRoot = .some(threadRoot)
            navigationReturnPositions = positions
            navigationReturnEdit = editing.map { ($0.messageId, $0.root) }
        }
        revealMessageID = current.messageId
        if let root = current.threadRootId {
            openThread(root)
        } else {
            openThread(nil)
            feedRevealSequence = current.seq
            if let seq = current.seq, let store {
                let channel = channel
                shown = max(shown, (try? store.queue.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE channel_id = ? AND thread_root_id IS NULL AND seq >= ?", arguments: [channel, seq])
                }) ?? shown)
            }
            observeFeed()
        }
        restoreEditing(root: current.threadRootId, messageID: current.messageId)
    }

    var hasNavigationReturn: Bool { navigationReturnRoot != nil }
    func finishNavigation() {
        revealMessageID = nil
        navigationReturnRoot = nil
        navigationReturnPositions = [:]
        navigationReturnEdit = nil
    }
    func returnFromNavigation() {
        guard case .some(let root) = navigationReturnRoot else { return }
        revealMessageID = nil
        positions = navigationReturnPositions
        openThread(root)
        if let edit = navigationReturnEdit { restoreEditing(root: edit.root, messageID: edit.id) }
        focusedMessageID = positions[root ?? ""]?.anchor
        navigationReturnRoot = nil
        navigationReturnPositions = [:]
        navigationReturnEdit = nil
        setSearching(false)
        readingPositionRestored += 1
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
        var draft = editDrafts[current.messageId] ?? Editing(messageId: current.messageId, root: root,
            text: recoverable ? current.localEdit?.text ?? current.text : current.text,
            revision: current.revision, message: current)
        draft.root = root
        editing = draft
        editOrder.removeAll { $0 == current.messageId }
        editOrder.append(current.messageId)
        observeEdit(current.messageId)
        return true
    }

    private func restoreEditing(root: String?, messageID: String? = nil) {
        let id = messageID ?? editOrder.last {
            guard let draft = editDrafts[$0] else { return false }
            return draft.root == root || (root == nil ? draft.message.threadRootId == nil : draft.messageId == root)
        }
        guard let id, var draft = editDrafts[id] else { return }
        draft.root = root
        editing = draft
    }

    private func observeEdit(_ id: String) {
        guard let store else { return }
        let channel = channel
        editingObservations[id] = ValueObservation.tracking { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true
            let message = try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ? AND m.channel_id = ?", arguments: [id, channel]).map(ChatMessage.init(row:))
            return (exists, message)
        }.start(in: store.queue, scheduling: .immediate, onError: { _ in }) { [weak self] exists, message in
            guard let self, var draft = self.editDrafts[id] else { return }
            // A new revision does not replace the editor's original revision or draft.
            guard exists else { self.cancelEditing(all: true); return }
            guard message?.deleted != true else { self.cancelEditing(messageID: id); return }
            if let message { draft.message = message }
            else { draft.message.hasMutable = false }
            self.editDrafts[id] = draft
            if self.editing?.messageId == id { self.editing = draft }
            if message == nil || message?.needsRead == true, let seq = draft.message.seq {
                self.service.orgSessions[self.key]?.sync?.readOne(channel, id: id, seq: seq,
                    atLeast: max(draft.revision, message?.stale ?? 0))
            }
        }
    }

    /// Only explicit cancellation, deletion or loss of access discards drafts.
    func cancelEditing(messageID: String? = nil, all: Bool = false) {
        if let id = messageID ?? editing?.messageId { finishEditing(id) }
        if all {
            editDrafts = [:]
            editOrder = []
            editingObservations = [:]
        }
    }

    private func finishEditing(_ id: String) {
        if let editing, editing.messageId == id {
            focusRequest = ChatFocusRequest(area: editing.root == nil ? .feed : .thread)
            focusedMessageID = id
            self.editing = nil
        }
        editDrafts[id] = nil
        editOrder.removeAll { $0 == id }
        editingObservations[id] = nil
    }

    @discardableResult
    func saveEditing(members: [(account: String, handle: String)]) -> Bool {
        guard let draft = editing, let current = message(draft.messageId), canEdit(current) else { return false }
        if let problem = edit(current, to: draft.text, revision: draft.revision, members: members) {
            editing?.problem = problem
            return false
        }
        finishEditing(draft.messageId)
        return true
    }

    /// The editor is a draft, not part of the rolling cache window. Keep its
    /// row in its own conversation while readOne reloads the current message.
    func conversationMessages(root: String?) -> [ChatMessage] {
        var messages = root == nil ? feed.messages : thread
        if let editing, editing.root == root, !messages.contains(where: { $0.id == editing.messageId }) {
            messages.append(editing.message)
            messages.sort { ($0.seq ?? Int.max) < ($1.seq ?? Int.max) }
        }
        return messages
    }

    @discardableResult
    func dismissTransient() -> Bool {
        if editing != nil { cancelEditing() }
        else if searching { returnFromNavigation(); setSearching(false) }
        else if threadRoot != nil { openThread(nil) }
        else { return false }
        return true
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
            try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.channel_id = ? AND m.message_id = ?", arguments: [channel, id]).map(ChatMessage.init(row:))
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
        guard root == threadRoot else { return }
        let channel = channel
        let known = thread.filter { $0.seq != nil }
        let firstUnknown = known.filter { !$0.hasFixed }.compactMap(\.seq).min() ?? Int.max
        let last = known.filter { $0.hasFixed && ($0.seq ?? 0) < firstUnknown }.compactMap(\.seq).max() ?? 0
        let ids = (try? store.queue.write { db in try ChatUnread.markRead(db, channel: channel, upTo: last, thread: root) }) ?? []
        if !ids.isEmpty { ChatNotifications.reconcile(service) }
    }

    // MARK: Drafts

    struct Draft: Equatable {
        var text = ""
        var version: String?
        var mentionOnly = false
        var contextIds = Set<String>()
    }

    func composerDraft(root: String?) -> Draft {
        (try? store?.queue.read { db -> Draft in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE channel_id = ? AND thread_root_id = ?",
                                             arguments: [channel, root ?? ""]) else { return Draft() }
            return Self.readDraft(row)
        }) ?? Draft()
    }

    nonisolated private static func readDraft(_ row: Row) -> Draft {
        let context: String = row["context_ids"]
        return Draft(text: row["text"], version: row["version"], mentionOnly: row["mention_only"],
                     contextIds: (try? JSONDecoder().decode(Set<String>.self, from: Data(context.utf8))) ?? [])
    }

    func draft(root: String?) -> String {
        composerDraft(root: root).text
    }

    func draftVersion(root: String?) -> String? {
        try? store?.queue.read { try String.fetchOne($0, sql: "SELECT version FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""]) }
    }

    /// Kept only while the channel's card is and the rights are not in doubt:
    /// a save made late — after the user left the team — writes nothing
    /// (review F3-p1-3).
    func saveDraft(_ text: String, root: String?, mentionOnly: Bool? = nil, contextIds: Set<String>? = nil) {
        let channel = channel
        try? store?.queue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true,
                  try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") != true else { return }
            if text.isEmpty {
                try db.execute(sql: "DELETE FROM drafts WHERE channel_id = ? AND thread_root_id = ?", arguments: [channel, root ?? ""])
            } else {
                let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE channel_id = ? AND thread_root_id = ?",
                                           arguments: [channel, root ?? ""])
                let previous = row.map(Self.readDraft) ?? Draft()
                let mentionOnly = mentionOnly ?? previous.mentionOnly
                let contextIds = contextIds ?? previous.contextIds
                let unchanged = previous.text == text && previous.mentionOnly == mentionOnly && previous.contextIds == contextIds
                let version = unchanged ? previous.version ?? UUID().uuidString.lowercased() : UUID().uuidString.lowercased()
                let context = String(decoding: try JSONEncoder().encode(contextIds.sorted()), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO drafts (channel_id, thread_root_id, text, updated_at, version, mention_only, context_ids) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(channel_id, thread_root_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at,
                        version = excluded.version, mention_only = excluded.mention_only, context_ids = excluded.context_ids
                    """, arguments: [channel, root ?? "", text, Date().timeIntervalSince1970, version, mentionOnly, context])
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
