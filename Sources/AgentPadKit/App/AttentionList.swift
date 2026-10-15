import Foundation
import AgentPadTelegram

/// Sidebar preferences are independent of banner delivery and decision ownership.
struct AttentionListSettings: Equatable, Sendable {
    var approvals = true
    var finished = true
    var mentions = true
    var dm = true
    static func read(_ values: [String: Any]) -> Self {
        Self(approvals: values["approvals"] as? Bool ?? true,
             finished: values["finished"] as? Bool ?? true,
             mentions: values["mentions"] as? Bool ?? true, dm: values["dm"] as? Bool ?? true)
    }
    func persisted(over values: [String: Any] = [:]) -> [String: Any] {
        var result = values
        result["approvals"] = approvals ? nil : false
        result["finished"] = finished ? nil : false
        result["mentions"] = mentions ? nil : false
        result["dm"] = dm ? nil : false
        return result
    }
}

struct AttentionItem: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case event(String)
        case mention(AttentionScope, channel: String, message: String, sequence: Int)
        case dm(AttentionScope, conversation: String)
        case telegram(TelegramAttentionSummary)
    }
    enum Secondary: String, Sendable { case dismiss = "Dismiss", markRead = "Mark read", snooze = "Hide until next message" }
    var id: String
    var tier: Int
    var time: Date
    var title: String
    var titleTabID: UUID?
    var subtitle: String
    var action: Action
    var secondary: Secondary?
    var inFlight = false
    var subjectID: String?
    var subjectName: String?
    var subjectIsAgent = false
    var localProfileID: UUID?
    var avatarScope: AttentionScope?
    var indicatorKind: AttentionIndicator.Kind?
    var telegramChat: Int64?
    enum TelegramPlaceholder: Sendable { case loading, inactive }
    var telegramPlaceholder: TelegramPlaceholder?
}

/// No message bodies. The future DM client supplies these through the same gate.
struct AttentionConversation: Equatable, Sendable {
    var scope: AttentionScope { didSet { prepareIDs() } }
    var id: String { didSet { prepareIDs() } }
    var title: String
    var count: Int
    var time: Date
    var firstMessage: String = ""
    var firstSequence: Int = 0
    var unreadLabel: String?
    var muted = false
    var subjectID: String?
    var subjectName: String?
    var subjectIsAgent = false
    private(set) var mentionReasonID = ""
    private(set) var dmReasonID = ""
    private(set) var unreadReasonID = ""
    var boundary: Int = 0
    var readMarks: [String: Int] = [:]

    init(scope: AttentionScope, id: String, title: String, count: Int, time: Date,
         firstMessage: String = "", firstSequence: Int = 0, unreadLabel: String? = nil,
         muted: Bool = false, subjectID: String? = nil, subjectName: String? = nil, subjectIsAgent: Bool = false) {
        self.scope = scope; self.id = id; self.title = title; self.count = count; self.time = time
        self.firstMessage = firstMessage; self.firstSequence = firstSequence; self.unreadLabel = unreadLabel
        self.muted = muted; self.subjectID = subjectID; self.subjectName = subjectName; self.subjectIsAgent = subjectIsAgent
        prepareIDs()
    }

    private mutating func prepareIDs() {
        let scope = [scope.server, scope.account, scope.organization, scope.generation]
        mentionReasonID = AttentionEvent.identifier(scope + ["mention", id])
        dmReasonID = AttentionEvent.identifier(scope + ["dm", id])
        unreadReasonID = AttentionEvent.identifier(scope + ["channel-unread", id])
    }
}

@MainActor
protocol AttentionDMSource: AnyObject {
    var conversations: [AttentionConversation] { get }
    /// Called only inside the open personal gate; stop must discard all metadata.
    func start(scope: AttentionScope, changed: @escaping ([AttentionConversation]) -> Void)
    func stop()
    func refresh()
    func open(_ conversation: String, scope: AttentionScope, from store: WorkspaceStore?)
    func markRead(_ conversation: String, scope: AttentionScope)
}

extension AttentionDMSource {
    var conversations: [AttentionConversation] { [] }
    func refresh() {}
}

struct AttentionCurrent: Equatable, Sendable {
    struct Label: Equatable, Sendable {
        var title: String
        var subjectID: String?
        var subjectName: String?
        var subjectIsAgent = false
    }
    struct Terminal: Equatable, Sendable {
        var episode: String
        var failed: Bool
        var finished = false
        var agentID: String = ""
        var agentName: String = ""
        var profileID: UUID?
    }
    var terminals: [UUID: Terminal] = [:]
    /// IDs validated by the existing source gates. Closed gate = empty set.
    var serverEvents: Set<String> = []
    /// Current request and journal run must both match the event's stable ID.
    var currentRunEvents: Set<String> = []
    var aggregateScope: AttentionScope?
    var labels: [String: Label] = [:]
}

enum AttentionList {
    static func currentRunEventIDs(_ ledger: [AttentionEvent], latestApprovals: [String: String], scope: AttentionScope) -> Set<String> {
        Set(ledger.filter { event in
            guard event.source == "run-outcome" || event.source == "launch-help" else { return false }
            return latestApprovals.contains { request, run in
                AttentionEvent(source: event.source, object: request, episode: run, kind: event.kind,
                               destination: event.destination, scope: scope).id == event.id
            }
        }.map(\.id))
    }
    static func items(ledger: [AttentionEvent], current: AttentionCurrent,
                      mentions: [AttentionConversation] = [], dms: [AttentionConversation] = [],
                      settings: AttentionListSettings = .init(), dismissed: Set<String> = [],
                      viewed: Set<String> = []) -> [AttentionItem] {
        var result: [AttentionItem] = ledger.compactMap { event in
            if event.scope != nil && !current.serverEvents.contains(event.id) { return nil }
            if event.clearsAttentionOnView && viewed.contains(event.id) { return nil }
            let tier: Int
            switch event.kind {
            case .decision, .folder, .publicationReview:
                guard settings.approvals else { return nil }; tier = 0
            case .confirmation, .version, .signIn: tier = 0
            case .input: tier = 1
            case .completion:
                guard settings.finished, event.source == "terminal" else { return nil }; tier = 1
            case .failure, .recovery: tier = 2
            default: return nil
            }
            guard !["link-failure", "post-outcome"].contains(event.source) else { return nil }
            if event.source == "terminal", event.kind == .failure || event.kind == .completion {
                guard case .terminal(let id) = event.destination, let tab = current.terminals[id],
                      event.kind == .failure ? tab.failed : tab.finished,
                      event.episode == tab.episode else { return nil }
            }
            if event.source == "run-outcome" || event.source == "launch-help" {
                guard current.currentRunEvents.contains(event.id) else { return nil }
            }
            let dismissible = event.kind == .failure || event.kind == .recovery || event.source == "launch-help"
            if dismissible && dismissed.contains(event.id) { return nil }
            var item = AttentionItem(id: event.id, tier: tier, time: event.timestamp, title: event.title,
                subtitle: event.actionInFlight ? "Decision is being sent" : event.body,
                action: .event(event.id), secondary: dismissible ? .dismiss : nil, inFlight: event.actionInFlight)
            if case .terminal(let id) = event.destination, let tab = current.terminals[id] {
                item.titleTabID = id
                item.subtitle = event.kind == .completion ? "Finished · waiting for you" : event.kind.title
                item.subjectID = tab.agentID; item.subjectName = tab.agentName; item.subjectIsAgent = true
                item.localProfileID = tab.profileID
            }
            if let label = current.labels[event.id] {
                item.title = label.title
                item.subtitle = event.actionInFlight ? "Decision is being sent" : event.kind.title
                item.subjectID = label.subjectID; item.subjectName = label.subjectName; item.subjectIsAgent = label.subjectIsAgent
            }
            item.avatarScope = event.scope
            item.indicatorKind = AttentionIndicator.Kind(event.kind)
            return item
        }
        func append(_ conversations: [AttentionConversation], dm: Bool) {
            for row in conversations where row.count > 0 && row.scope == current.aggregateScope && (!dm || !row.muted) {
                result.append(AttentionItem(
                    id: dm ? row.dmReasonID : row.mentionReasonID,
                    tier: 3, time: row.time, title: row.title,
                    subtitle: dm ? "Direct message · \(row.unreadLabel ?? "\(row.count) new")" : "Mentioned you · \(row.count) new",
                    action: dm ? .dm(row.scope, conversation: row.id)
                        : .mention(row.scope, channel: row.id, message: row.firstMessage, sequence: row.firstSequence),
                    secondary: .markRead, subjectID: row.subjectID, subjectName: row.subjectName,
                    subjectIsAgent: row.subjectIsAgent, avatarScope: row.scope, indicatorKind: .unread))
            }
        }
        if settings.mentions { append(mentions, dm: false) }
        if settings.dm { append(dms, dm: true) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    static func precedes(_ a: AttentionItem, _ b: AttentionItem) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        if a.time != b.time { return a.tier >= 3 ? a.time > b.time : a.time < b.time }
        if let x = a.telegramChat, let y = b.telegramChat { return x < y }
        return a.id < b.id
    }

    static func merged(_ items: [AttentionItem], telegram: [TelegramChatRow], frontier: TelegramAttentionOrderKey?,
                       keys: [TelegramAttentionOrderKey]? = nil, inactive: Set<Int64> = [],
                       state: TelegramAttentionState? = nil) -> [AttentionItem] {
        let metadata = Dictionary(telegram.map { ($0.id.chat,$0) }, uniquingKeysWith: { _, row in row })
        let order = keys ?? telegram.compactMap { row in
            row.attentionOrderKey ?? row.attention.map { .init(chat: row.id.chat,tier: $0.kind.tier,rankingTime: $0.lastDate) }
        }
        let rows: [AttentionItem] = order.map { key in
            var item = AttentionItem(id: "telegram-row:\(key.chat)", tier: key.tier,
                time: Date(timeIntervalSince1970: Double(key.rankingTime)), title: "", subtitle: "",
                action: .event(""), telegramChat: key.chat)
            if inactive.contains(key.chat) || state?.inactive.contains(key.chat) == true {
                item.telegramPlaceholder = .inactive
            } else if let row = metadata[key.chat], !row.hidden, row.kind.eligible, let summary = row.attention {
                item.title = row.title; item.subtitle = summary.caption; item.action = .telegram(summary)
                item.secondary = .snooze; item.indicatorKind = .unread
            } else {
                item.telegramPlaceholder = .loading
            }
            return item
        }
        var result = (items + rows).sorted(by: precedes)
        if let frontier {
            result = result.filter { item in
                if item.tier != frontier.tier { return item.tier < frontier.tier }
                let time = Date(timeIntervalSince1970: Double(frontier.rankingTime))
                if item.time != time { return item.time > time }
                if let chat = item.telegramChat { return chat <= frontier.chat }
                return item.id <= "telegram-row:\(frontier.chat)"
            }
        }
        return result
    }

    static func visible(_ items: [AttentionItem], expanded: Bool, collapsed: Bool = false) -> [AttentionItem] {
        if expanded && !collapsed { return items }
        var ordinaryIndex = 0
        return items.compactMap { item in
            if item.tier <= 1 { return item }
            defer { ordinaryIndex += 1 }
            return !collapsed && ordinaryIndex < 5 ? item : nil
        }
    }
}
