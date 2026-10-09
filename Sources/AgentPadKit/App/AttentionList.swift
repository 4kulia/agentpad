import Foundation

/// Sidebar preferences are independent of banner delivery and decision ownership.
struct AttentionListSettings: Equatable, Sendable {
    var approvals = true
    var mentions = true
    var dm = true
    static func read(_ values: [String: Any]) -> Self {
        Self(approvals: values["approvals"] as? Bool ?? true,
             mentions: values["mentions"] as? Bool ?? true, dm: values["dm"] as? Bool ?? true)
    }
    func persisted(over values: [String: Any] = [:]) -> [String: Any] {
        var result = values
        result["approvals"] = approvals ? nil : false
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
    }
    enum Secondary: String, Sendable { case dismiss = "Dismiss", markRead = "Mark read" }
    var id: String
    var tier: Int
    var time: Date
    var title: String
    var subtitle: String
    var action: Action
    var secondary: Secondary?
    var inFlight = false
    var subjectID: String?
    var subjectName: String?
    var subjectIsAgent = false
}

/// No message bodies. The future DM client supplies these through the same gate.
struct AttentionConversation: Equatable, Sendable {
    var scope: AttentionScope
    var id: String
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
}

@MainActor
protocol AttentionDMSource: AnyObject {
    /// Called only inside the open personal gate; stop must discard all metadata.
    func start(scope: AttentionScope, changed: @escaping ([AttentionConversation]) -> Void)
    func stop()
    func refresh()
    func open(_ conversation: String, scope: AttentionScope)
    func markRead(_ conversation: String, scope: AttentionScope)
}

extension AttentionDMSource { func refresh() {} }

struct AttentionCurrent: Sendable {
    struct Label: Sendable {
        var title: String
        var subjectID: String?
        var subjectName: String?
        var subjectIsAgent = false
    }
    struct Terminal: Sendable {
        var episode: String
        var failed: Bool
        var title: String = ""
        var agentID: String = ""
        var agentName: String = ""
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
                      settings: AttentionListSettings = .init(), dismissed: Set<String> = []) -> [AttentionItem] {
        var result: [AttentionItem] = ledger.compactMap { event in
            if event.scope != nil && !current.serverEvents.contains(event.id) { return nil }
            let tier: Int
            switch event.kind {
            case .decision, .folder, .publicationReview:
                guard settings.approvals else { return nil }; tier = 0
            case .confirmation, .version, .signIn: tier = 0
            case .input: tier = 1
            case .failure, .recovery: tier = 2
            default: return nil
            }
            guard !["link-failure", "post-outcome"].contains(event.source) else { return nil }
            if event.source == "terminal", event.kind == .failure {
                guard case .terminal(let id) = event.destination, let tab = current.terminals[id], tab.failed,
                      AttentionEvent(source: event.source, object: id.uuidString, episode: tab.episode,
                                     kind: event.kind, destination: event.destination).id == event.id else { return nil }
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
                item.title = tab.title.isEmpty ? event.title : tab.title
                item.subtitle = event.kind.title
                item.subjectID = tab.agentID; item.subjectName = tab.agentName; item.subjectIsAgent = true
            }
            if let label = current.labels[event.id] {
                item.title = label.title
                item.subtitle = event.actionInFlight ? "Decision is being sent" : event.kind.title
                item.subjectID = label.subjectID; item.subjectName = label.subjectName; item.subjectIsAgent = label.subjectIsAgent
            }
            return item
        }
        func append(_ conversations: [AttentionConversation], dm: Bool) {
            for row in conversations where row.count > 0 && row.scope == current.aggregateScope && (!dm || !row.muted) {
                result.append(AttentionItem(
                    id: AttentionEvent.identifier([row.scope.server, row.scope.account, row.scope.organization,
                                                  row.scope.generation, dm ? "dm" : "mention", row.id]),
                    tier: 3, time: row.time, title: row.title,
                    subtitle: dm ? "Direct message · \(row.unreadLabel ?? "\(row.count) new")" : "Mentioned you · \(row.count) new",
                    action: dm ? .dm(row.scope, conversation: row.id)
                        : .mention(row.scope, channel: row.id, message: row.firstMessage, sequence: row.firstSequence),
                    secondary: .markRead, subjectID: row.subjectID, subjectName: row.subjectName,
                    subjectIsAgent: row.subjectIsAgent))
            }
        }
        if settings.mentions { append(mentions, dm: false) }
        if settings.dm { append(dms, dm: true) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.time != $1.time { return $0.tier == 3 ? $0.time > $1.time : $0.time < $1.time }
            return $0.id < $1.id
        }
    }

    static func visible(_ items: [AttentionItem], expanded: Bool, collapsed: Bool = false) -> [AttentionItem] {
        if expanded && !collapsed { return items }
        return items.enumerated().compactMap { index, item in
            item.tier <= 1 || (!collapsed && index < 5) ? item : nil
        }
    }
}
