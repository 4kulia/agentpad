import Foundation
import GRDB
import Observation

struct ChatDMContent: Equatable {
    struct Draft: Equatable { var text: String; var version: String }
    var card: ChatDMCard?
    var messages: [ChatMessage] = []
    var historyNext: Int?
    var window = 0
    var accessEpoch = 0
    var drafts: [String: Draft] = [:]
    var edits: [ChatChannelModel.Editing] = []
    var marks: [String: Int] = [:]
    var muted = false
    static func read(_ db: Database, dm: String) throws -> Self {
        let row = try Row.fetchOne(db, sql: "SELECT history_next, epoch FROM dm_cards WHERE dm_id = ?", arguments: [dm])
        return Self(card: try ChatDMStore.card(db, dm), messages: try ChatDMStore.messages(db, dm), historyNext: row?["history_next"],
            window: row?["epoch"] ?? 0, accessEpoch: try Int.fetchOne(db, sql: "SELECT epoch FROM dm_meta") ?? 0,
            drafts: Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM dm_drafts WHERE dm_id = ?", arguments: [dm]).map { ($0["root"] as String, Draft(text: $0["text"], version: $0["version"])) }),
            edits: try Data.fetchAll(db, sql: "SELECT body FROM dm_edits WHERE dm_id = ?", arguments: [dm]).map { try JSONDecoder().decode(ChatChannelModel.Editing.self, from: $0) },
            marks: Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT root, seq FROM dm_marks WHERE dm_id = ?", arguments: [dm]).map { ($0["root"] as String, $0["seq"] as Int) }),
            muted: try Bool.fetchOne(db, sql: "SELECT muted FROM dm_preferences WHERE dm_id = ?", arguments: [dm]) ?? false)
    }
}

@MainActor @Observable
final class ChatDMModel: ChatConversationPresentation {
    let key: ChatOrgKey
    let ref: ChatDMRef
    let service: ChatService
    weak var state: TabState?
    var tabID: UUID?
    var isPopup = false {
        didSet { if isPopup { preparePopupOpeningPosition() } }
    }
    var confirmation: ConfirmationCoordinator? { state?.confirmation }
    var deletionRoot: String?
    private var stopped = false
    private var content = ChatDMContent()
    private var activeEdit: ChatChannelModel.Editing?
    private var boundaries: [String: Int] = [:]
    private let subscription = UUID()
    private var shown = 50
    private var reading = Set<String>()
    private var threadNext: Int?
    private var threadLoaded = false
    private var pendingThreadPage: (messages: [ChatMessage], next: Int?)?
    private var popupOpeningThreads = Set<String>()
    private var requestID: UUID?
    private(set) var threadRoot: String?
    private(set) var problem: String?
    private(set) var draftSaveProblem: String?
    private var pendingDrafts: [String: ChatDMContent.Draft] = [:]
    private var pendingEditDrafts: [String: ChatChannelModel.Editing] = [:]
    var positions: [String: ChatScrollPosition] = [:]
    var focusedMessageID: String?
    var revealMessageID: String? { didSet { revealRequest += 1 } }
    private(set) var revealRequest: UInt64 = 0
    var focusRequest: ChatFocusRequest?
    var readingPositionRestored = 0
    let isDM = true
    func destination(root: String?) -> ConversationDestination { .directMessage(ref, thread: root) }
    var searching: Bool { false }
    var hasNavigationReturn: Bool { false }
    var b1: ChatB1Channel? { nil }
    var sourceStatuses: [ChatSourceStatus] { [] }
    var threadRequests: [ChatChannelRequests.Card] { [] }
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var threadLoad: Task<Void, Never>?
    private var store: ChatStore? { service.orgSessions[key]?.store }
    private var sync: ChatDMSync? { service.dmSync(key) }
    var readable: Bool {
        guard !stopped, state?.isClosed != true, service.dmAllowed(key, ref.dm), let store else { return false }
        return (try? store.dmRead { try Int.fetchOne($0, sql: "SELECT epoch FROM dm_meta") }) == content.accessEpoch
    }
    var card: ChatDMCard? { readable ? content.card : nil }
    var writable: Bool { card?.writable == true }
    var muted: Bool { readable && content.muted }
    var threadHasEarlier: Bool { readable && (!threadLoaded || threadNext != nil) }
    var editing: ChatChannelModel.Editing? {
        get { readable ? activeEdit : nil }
        set {
            guard let value = newValue else { activeEdit = nil; return }
            guard readable, let store else { return }
            var next = value
            if next.version == nil || content.edits.first(where: { $0.messageId == next.messageId })?.text != next.text { next.version = UUID().uuidString }
            do {
                let data = try JSONEncoder().encode(next)
                try store.dmWrite { try $0.execute(sql: "INSERT OR REPLACE INTO dm_edits (dm_id, message_id, body) VALUES (?, ?, ?)", arguments: [ref.dm, next.messageId, data]) }
                activeEdit = next
                pendingEditDrafts[next.messageId] = nil
                if pendingDrafts.isEmpty && pendingEditDrafts.isEmpty { draftSaveProblem = nil }
            } catch {
                draftSaveProblem = "The draft could not be saved on this Mac. Retry before closing."
                next.problem = draftSaveProblem
                pendingEditDrafts[next.messageId] = next
                activeEdit = next
            }
        }
    }
    var feed: ChatChannelModel.Feed {
        guard readable else { return .init() }
        let rootIDs = Set(content.messages.filter { $0.threadRootId == nil }.map(\.id))
        let roots = content.messages.filter { $0.threadRootId == nil || ($0.localState != nil && !rootIDs.contains($0.threadRootId ?? "")) }
        let visible = Array(roots.suffix(shown)), replies = Dictionary(grouping: content.messages.filter { $0.threadRootId != nil }, by: { $0.threadRootId! })
        var feed = ChatChannelModel.Feed(messages: visible, replies: replies.mapValues(\.count),
            replySummaries: replies.mapValues { ChatReplySummary(messages: $0, complete: content.historyNext == nil) },
            unreadID: firstUnread(visible, root: nil), earlierUnread: content.historyNext != nil && mark(nil) < (visible.first?.seq ?? 0),
            hasOlder: roots.count > shown || content.historyNext != nil, historyNext: content.historyNext, archived: !writable)
        feed.unreadReplyCounts = replies.mapValues { $0.filter { unread($0) }.count }
        return feed
    }
    var threadUnreadID: String? { firstUnread(conversationMessages(root: threadRoot).filter { $0.threadRootId != nil }, root: threadRoot) }
    init(key: ChatOrgKey, dm: String, state: TabState? = nil, service: ChatService = .shared,
         scheduling scheduler: some ValueObservationMainActorScheduler = .immediate) {
        self.key = key; ref = ChatDMRef(key, dm: dm); self.state = state; self.service = service
        guard let store = service.orgSessions[key]?.store else { return }
        service.dmTab(ref, owner: subscription, open: true)
        observation = ValueObservation.tracking { try ChatDMContent.read($0, dm: dm) }.removeDuplicates()
            .start(in: store.queue, scheduling: scheduler, onError: { [weak self] _ in self?.content = .init() }) { [weak self] value in self?.accept(value) }
    }
    private func accept(_ value: ChatDMContent) {
        let replaced = value.window != content.window
        content = value
        if let activeEdit {
            if let pending = pendingEditDrafts[activeEdit.messageId] { self.activeEdit = pending }
            else if let saved = value.edits.first(where: { $0.messageId == activeEdit.messageId }) { self.activeEdit = saved }
            else { self.activeEdit = nil }
        } else { activeEdit = value.edits.first { $0.root == threadRoot } }
        if replaced {
            threadLoad?.cancel(); requestID = nil; threadLoaded = false; threadNext = nil; pendingThreadPage = nil
            if threadRoot != nil { readThread() }
        }
        completeThreadPage()
        preparePopupOpeningPosition()
    }
    func stop() { stopped = true; service.dmTab(ref, owner: subscription, open: false); observation = nil; load?.cancel(); threadLoad?.cancel(); content = .init(); activeEdit = nil; confirmation?.invalidate() }
    func notificationPlace(root: String?) -> String { ref.place + (root.map { ":thread:\($0)" } ?? "") }
    func message(_ id: String) -> ChatMessage? { readable ? content.messages.first { $0.id == id } : nil }
    func conversationMessages(root: String?) -> [ChatMessage] {
        guard readable else { return [] }
        var messages = root.map { root in content.messages.filter { $0.id == root || $0.threadRootId == root } } ?? feed.messages
        if let editing, editing.root == root, !messages.contains(where: { $0.id == editing.messageId }) { messages.append(editing.message) }
        return messages.sorted { ($0.seq ?? Int.max) < ($1.seq ?? Int.max) }
    }
    func loadOlder() {
        guard load == nil, let sync, readable else { return }
        let before = content.historyNext
        shown += 50
        guard let before else { return }
        load = Task { [weak self] in
            defer { self?.load = nil }
            do { _ = try await sync.page(self?.ref.dm ?? "", before: before) }
            catch is CancellationError {}
            catch { self?.problem = "Earlier messages could not be loaded. Try again." }
        }
    }
    func openThread(_ id: String?) {
        guard readable, id != threadRoot else { return }
        if isPopup {
            do { try flushConversationDrafts() } catch { return }
            if id == nil, let target = revealMessageID.flatMap(message), target.threadRootId != nil { revealMessageID = nil }
        }
        confirmation?.invalidate(); threadLoad?.cancel(); requestID = nil
        threadRoot = id; threadNext = nil; threadLoaded = false; pendingThreadPage = nil; activeEdit = nil
        if let id { boundaries[id] = mark(id); readThread() }
        restoreEditing(root: id)
        preparePopupOpeningPosition()
        if isPopup, id == nil { readingPositionRestored += 1 }
        focusRequest = ChatFocusRequest(area: isPopup ? (writable ? .composer : (id == nil ? .feed : .thread)) : (id == nil ? .feed : .composer))
    }

    func preparePopupOpeningPosition() {
        guard isPopup else { return }
        let slot = threadRoot ?? ""
        if revealMessageID != nil { popupOpeningThreads.remove(slot); return }
        guard positions[slot]?.initialized != true || popupOpeningThreads.contains(slot) else { return }
        let messages = conversationMessages(root: threadRoot)
        let unread = threadRoot == nil ? feed.unreadID : threadUnreadID
        if let root = threadRoot, !threadLoaded, unread == nil {
            popupOpeningThreads.insert(root)
            return
        }
        let mounted = positions[slot]?.initialized == true
        popupOpeningThreads.remove(slot)
        guard let unread,
              let index = messages.firstIndex(where: { $0.id == unread }) else { return }
        var position = ChatScrollPosition()
        _ = position.update(messages, me: key.accountId)
        position.measured(bottom: false, anchor: messages[max(0, index - 1)].id)
        positions[slot] = position
        if mounted { readingPositionRestored += 1 }
    }
    func earlierReplies() { readThread() }
    private func completeThreadPage() {
        guard let page = pendingThreadPage else { return }
        let observed = Dictionary(uniqueKeysWithValues: content.messages.map { ($0.id, $0) })
        guard page.messages.allSatisfy({ expected in
            guard let message = observed[expected.id] else { return false }
            return message.revision >= expected.revision && (expected.loading || !message.loading)
        }) else { return }
        pendingThreadPage = nil
        threadLoaded = true; threadNext = page.next
    }
    private func readThread() {
        guard let root = threadRoot, let sync, let store, readable, requestID == nil, pendingThreadPage == nil else { return }
        let request = UUID(), before = threadLoaded ? threadNext : nil, dm = ref.dm
        if threadLoaded && before == nil { return }
        requestID = request
        threadLoad = Task { [weak self] in
            defer { if self?.requestID == request { self?.requestID = nil; self?.threadLoad = nil } }
            do {
                let page = try await sync.page(dm, root: root, before: before)
                guard let self, !Task.isCancelled, readable, requestID == request, threadRoot == root else { return }
                // page() commits before GRDB delivers its snapshot. Keep the
                // opening and read gate pending until that content is observed.
                // Use persisted messages: revision/tombstone guards may reject a
                // wire message. Existing IDs also need their hydrated revisions;
                // an empty or already observed page needs no callback.
                let messages = try store.dmRead { db in
                    try ChatDMStore.messages(db, dm).filter { $0.id == root || $0.threadRootId == root }
                }
                pendingThreadPage = (messages, page.next)
                completeThreadPage()
                preparePopupOpeningPosition()
            } catch is CancellationError {}
            catch { if self?.readable == true { self?.problem = "The thread could not be loaded. Try again." } }
        }
    }
    private func mark(_ root: String?) -> Int { max(content.marks[root ?? "", default: 0], root == nil ? 0 : content.marks["*", default: 0]) }
    private func unread(_ message: ChatMessage) -> Bool {
        message.authorAccountId != key.accountId && !message.deleted && !message.loading && (message.seq ?? 0) > mark(message.threadRootId)
    }
    private func firstUnread(_ messages: [ChatMessage], root: String?) -> String? {
        let after = boundaries[root ?? ""] ?? mark(root)
        return messages.first { $0.authorAccountId != key.accountId && !$0.deleted && !$0.loading && ($0.seq ?? 0) > after }?.id
    }
    func beginReading(root: String?) { if readable { if boundaries[root ?? ""] == nil { boundaries[root ?? ""] = mark(root) }; reading.insert(root ?? "") } }
    func endReading(root: String?) { reading.remove(root ?? "") }
    func readIfLooking(root: String?, appActive: Bool, shown: Bool, atBottom: Bool) {
        if isPopup, popupOpeningThreads.contains(root ?? "") || positions[root ?? ""]?.atBottom == false { return }
        guard appActive, shown, atBottom, reading.contains(root ?? ""), root == nil || threadLoaded else { return }
        markConversationRead(root: root, clearingBoundary: false)
    }
    func markConversationRead(root: String?, clearingBoundary: Bool = true) {
        guard readable, let store else { return }
        let seq = conversationMessages(root: root).filter { !$0.loading && (root == nil || $0.threadRootId == root) }.compactMap(\.seq).max() ?? 0
        try? store.dmWrite { try ChatDMStore.markRead($0, ref.dm, root: root, through: seq) }
        if clearingBoundary { boundaries[root ?? ""] = seq }
    }
    func revealSearchMessage(_ message: ChatMessage, in messages: [ChatMessage]) {
        guard readable else { return }
        if isPopup { do { try flushConversationDrafts() } catch { return } }
        if let store { content = (try? store.dmRead { try ChatDMContent.read($0, dm: ref.dm) }) ?? content }
        shown = max(shown, messages.filter { $0.threadRootId == nil && ($0.seq ?? 0) >= (message.seq ?? 0) }.count)
        openThread(message.threadRootId)
        revealMessageID = message.id
    }
    func finishNavigation() {}
    @discardableResult func dismissTransient() -> Bool {
        guard !isPopup else { return false }
        if editing != nil { cancelEditing() }
        else if threadRoot != nil { openThread(nil) }
        else { return false }
        return true
    }
    func draft(root: String?) -> ChatDMContent.Draft? { readable ? pendingDrafts[root ?? ""] ?? content.drafts[root ?? ""] : nil }
    @discardableResult func saveDraft(_ text: String, root: String?) -> String? {
        guard writable, let store else { return nil }
        let slot = root ?? ""
        pendingDrafts[slot] = .init(text: text, version: UUID().uuidString)
        do {
            let version = try store.dmWrite { try ChatDMStore.saveDraft($0, ref.dm, root: root, text: text) }
            content.drafts[slot] = .init(text: text, version: version)
            pendingDrafts[slot] = nil
            if pendingDrafts.isEmpty && pendingEditDrafts.isEmpty { draftSaveProblem = nil }
            return version
        } catch { draftSaveProblem = "The draft could not be saved on this Mac. Retry before closing."; return nil }
    }

    func flushConversationDrafts() throws {
        guard !pendingDrafts.isEmpty || !pendingEditDrafts.isEmpty else { draftSaveProblem = nil; return }
        do {
            guard readable, let store else { throw ChatError.storage("The conversation is unavailable on this Mac.") }
            for slot in pendingDrafts.keys.sorted() {
                guard let draft = pendingDrafts[slot] else { continue }
                let version = try store.dmWrite { try ChatDMStore.saveDraft($0, ref.dm, root: slot.isEmpty ? nil : slot, text: draft.text) }
                content.drafts[slot] = .init(text: draft.text, version: version)
                pendingDrafts[slot] = nil
            }
            for id in pendingEditDrafts.keys.sorted() {
                guard var draft = pendingEditDrafts[id] else { continue }
                draft.problem = nil
                let data = try JSONEncoder().encode(draft)
                try store.dmWrite { try $0.execute(sql: "INSERT OR REPLACE INTO dm_edits (dm_id, message_id, body) VALUES (?, ?, ?)", arguments: [ref.dm, id, data]) }
                pendingEditDrafts[id] = nil
                if activeEdit?.messageId == id { activeEdit = draft }
            }
            draftSaveProblem = nil
        } catch {
            draftSaveProblem = "The draft could not be saved on this Mac. Retry before closing."
            throw error
        }
    }

    func retryDraftSave() { try? flushConversationDrafts() }

    var hasConversationDraft: Bool {
        content.drafts.values.contains { !$0.text.isEmpty } || pendingDrafts.values.contains { !$0.text.isEmpty }
            || !content.edits.isEmpty || !pendingEditDrafts.isEmpty
            || service.attachments(key)?.drafts.contains { $0.owner == .dm(ref.dm) } == true
    }
    var orphanedFileDraftRoots: [String] {
        guard readable, let manager = service.attachments(key) else { return [] }
        return Set(manager.drafts.filter { $0.owner == .dm(ref.dm) && !$0.root.isEmpty && message($0.root) == nil }.map(\.root)).sorted()
    }
    func attachmentProblem(_ error: Error) { problem = ChatAttachments.reason(error, owner: .dm(ref.dm)) }
    func deleteDraft(root: String?) {
        guard readable else { return }
        if let manager = service.attachments(key) {
            for file in manager.files(owner: .dm(ref.dm), root: root) { manager.remove(file) }
        }
        try? store?.dmWrite { try $0.execute(sql: "DELETE FROM dm_drafts WHERE dm_id = ? AND root = ?", arguments: [ref.dm, root ?? ""]) }
        pendingDrafts[root ?? ""] = nil
    }
    @discardableResult func send(_ text: String, root: String?, members: [(account: String, handle: String)], version: String?) -> Bool {
        guard writable, pendingDrafts[root ?? ""] == nil, let version else { return false }
        do {
            let id = try service.postDM(key, dm: ref.dm, root: root, text: text, mentions: ChatChannelModel.mentions(in: text, members: members), draftVersion: version)
            problem = nil; focusedMessageID = id; return true
        } catch { problem = error.localizedDescription; return false }
    }
    func canEdit(_ message: ChatMessage) -> Bool {
        canDelete(message) && (message.authorSessionName == nil || service.supports("chat.dm.session_signature", key: key))
    }
    func canDelete(_ message: ChatMessage) -> Bool {
        writable && message.authorAccountId == key.accountId && message.hasFixed && !message.deleted && !message.loading && !message.changing && message.localState == nil
    }
    func canRetry(_ message: ChatMessage) -> Bool { writable && message.localState == .failed && message.authorSessionName == nil }
    @discardableResult func beginEditing(_ message: ChatMessage, root: String?, recovering: Bool = false) -> Bool {
        guard readable, recovering || canEdit(message), let current = self.message(message.id), !current.deleted else { return false }
        editing = .init(messageId: current.id, root: root, text: recovering ? current.localEdit?.text ?? current.text : current.text,
                        revision: current.revision, message: current)
        return true
    }
    private func restoreEditing(root: String?) { activeEdit = pendingEditDrafts.values.first { $0.root == root } ?? content.edits.first { $0.root == root } }
    func cancelEditing(messageID: String? = nil, all: Bool = false) {
        guard readable, let store else { return }
        let id = messageID ?? activeEdit?.messageId
        try? store.dmWrite { db in
            if all { try db.execute(sql: "DELETE FROM dm_edits WHERE dm_id = ?", arguments: [ref.dm]) }
            else if let id { try db.execute(sql: "DELETE FROM dm_edits WHERE dm_id = ? AND message_id = ?", arguments: [ref.dm, id]) }
        }
        activeEdit = nil
        if all { pendingEditDrafts = [:] }
        else if let id { pendingEditDrafts[id] = nil }
    }
    @discardableResult func saveEditing(members: [(account: String, handle: String)]) -> Bool {
        guard let edit = editing, let current = message(edit.messageId), canEdit(current), let store else { return false }
        do {
            let saved = try store.dmRead { try Data.fetchOne($0, sql: "SELECT body FROM dm_edits WHERE dm_id = ? AND message_id = ?", arguments: [ref.dm, edit.messageId]) }
            guard let saved, try JSONDecoder().decode(ChatChannelModel.Editing.self, from: saved).version == edit.version else { throw ChatError.storage("The edit changed in another window. Review it before saving.") }
            try service.changeDM(key, dm: ref.dm, message: edit.messageId, text: edit.text, mentions: ChatChannelModel.mentions(in: edit.text, members: members), revision: edit.revision)
            cancelEditing(); return true
        } catch { activeEdit?.problem = error.localizedDescription; return false }
    }
    @discardableResult func requestDelete(_ message: ChatMessage, root: String? = nil) -> Bool {
        guard canDelete(message), let confirmation, let tabID else { return false }
        deletionRoot = root
        let epoch = sync?.epoch
        return confirmation.request(.init(tabID: tabID, targetID: "message:\(message.id)", scope: OrgKey(key),
            generation: service.consentIdentity(key)?.generation, revision: String(message.revision), deadline: Date().addingTimeInterval(120)),
            title: "Delete this message?", consequences: "Its text will be removed. Replies stay in the thread.", verb: "Delete", destructive: true,
            stillValid: { [weak self] in
                guard let self, sync?.epoch == epoch, let current = self.message(message.id) else { return false }
                return canDelete(current) && current.revision == message.revision
            }) { [weak self] in
                guard let self, readable else { throw ChatError.notConnected }
                try service.changeDM(key, dm: ref.dm, message: message.id, text: nil, revision: message.revision)
            }
    }
    func setMuted(_ value: Bool) {
        guard readable else { return }
        try? store?.dmWrite { try $0.execute(sql: "INSERT INTO dm_preferences (dm_id, muted) VALUES (?, ?) ON CONFLICT(dm_id) DO UPDATE SET muted = excluded.muted", arguments: [ref.dm, value]) }
    }
    func retry(_ message: ChatMessage) { do { try service.retryDM(key, dm: ref.dm, message: message.id) } catch { problem = error.localizedDescription } }
    func discard(_ message: ChatMessage) { do { try service.discardDM(key, dm: ref.dm, message: message.id) } catch { problem = error.localizedDescription } }
    func discardEdit(_ message: ChatMessage) {
        guard readable, !message.changing else { return }
        try? store?.dmWrite { try $0.execute(sql: "DELETE FROM dm_changes WHERE dm_id = ? AND message_id = ?", arguments: [ref.dm, message.id]) }
    }
}
