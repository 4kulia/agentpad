import Foundation
import GRDB
import Observation

/// One asynchronous database observation, owned by the gate, not by a sidebar view.
@MainActor @Observable
final class AttentionAggregates {
    struct Gate: Equatable {
        var scope: AttentionScope
        var session: String
        var allowed: Bool
    }
    private(set) var gate: Gate?
    private(set) var mentions: [AttentionConversation] = []
    private(set) var dms: [AttentionConversation] = []
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored var dmSource: (any AttentionDMSource)?

    func update(_ next: Gate?, store: () -> ChatStore?) {
        guard gate != next || (next?.allowed == true && observation == nil) else { dmSource?.refresh(); return }
        epoch = UUID(); observation?.cancel(); observation = nil
        dmSource?.stop(); mentions = []; dms = []; gate = next
        guard let next, next.allowed, let store = store() else { return }
        let stamp = epoch
        observation = ValueObservation.tracking { db in
            try Self.read(db, scope: next.scope, session: next.session)
        }.removeDuplicates().start(in: store.queue, scheduling: .async(onQueue: .main), onError: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == stamp else { return }
                self.mentions = []; self.observation = nil
            }
        }, onChange: { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == stamp else { return }
                self.mentions = value
            }
        })
        dmSource?.start(scope: next.scope) { [weak self] value in
            guard let self, self.epoch == stamp else { return }; self.dms = value
        }
    }

    nonisolated static func read(_ db: Database, scope: AttentionScope, session: String) throws -> [AttentionConversation] {
        guard try ChatInbox.allowed(db, account: scope.account, session: session),
              try String.fetchOne(db, sql: "SELECT pending_generation FROM meta WHERE id = 1") == nil,
              (try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") ?? "") == scope.generation else { return [] }
        // The same predicates as F4; rank by sequence for navigation, creation for age.
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.channel_id, c.name, m.message_id, m.seq, m.created_at,
                   m.author_account_id, m.author_agent_id, m.author_agent_name, m.author_session_name, p.name AS person_name
            FROM messages m JOIN channels c ON c.channel_id = m.channel_id
            JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
            LEFT JOIN members p ON p.account_id = m.author_account_id
            \(ChatUnread.readJoins)
            WHERE \(ChatUnread.mentionSQL) AND \(ChatUnread.unreadMentionSQL)
            ORDER BY m.channel_id, m.seq, m.message_id
            """)
        var result: [String: AttentionConversation] = [:]
        for row in rows {
            let id: String = row["channel_id"]
            let date = (row["created_at"] as String?).flatMap(ChatStore.date) ?? .distantPast
            if var old = result[id] { old.count += 1; old.time = max(old.time, date); result[id] = old }
            else {
                let agent: String? = row["author_agent_id"]
                let sessionName: String? = row["author_session_name"]
                result[id] = AttentionConversation(scope: scope, id: id, title: "#" + (row["name"] as String), count: 1,
                    time: date, firstMessage: row["message_id"], firstSequence: row["seq"],
                    subjectID: agent ?? row["author_account_id"],
                    subjectName: agent != nil ? row["author_agent_name"] : sessionName ?? row["person_name"],
                    subjectIsAgent: agent != nil || sessionName != nil)
            }
        }
        return result.values.sorted { $0.id < $1.id }
    }
}

@MainActor @Observable
final class AttentionSidebarModel {
    static let shared = AttentionSidebarModel()
    private var ledger: AttentionLedger
    let aggregates = AttentionAggregates()
    var serverCurrent = AttentionCurrent()
    var dismissalRevision = 0
    init(ledger: AttentionLedger = .shared) { self.ledger = ledger }

    var items: [AttentionItem] {
        var current = serverCurrent
        // Reading live observable sessions makes a new run remove its old failure immediately.
        for store in AgentMonitor.shared.storesProvider() {
            for session in store.workspaces.flatMap({ $0.root.allPanes.flatMap(\.tabs) }) {
                current.terminals[session.id] = .init(episode: session.attentionEpisode,
                    failed: session.hasCurrentAttentionFailure,
                    title: session.title, agentID: session.displayAgent.id, agentName: session.displayAgent.title)
            }
        }
        for event in ledger.events {
            if case .external(let id) = event.destination,
               let session = ExternalSessionMonitor.shared.sessions.first(where: { $0.id == id }) {
                current.labels[event.id] = .init(title: session.displayTitle, subjectID: AgentTemplate.claudeCodeID,
                                                subjectName: "Claude Code", subjectIsAgent: true)
            }
        }
        _ = dismissalRevision
        return AttentionList.items(ledger: ledger.events, current: current,
            mentions: aggregates.mentions, dms: aggregates.dms, settings: AgentPadSettingsModel.shared.attentionSettings,
            dismissed: Set(ledger.metadata.markers.filter { $0.value.hidden }.keys), viewed: ledger.viewedAttentionIDs)
    }

    func refresh(service: ChatService = .shared, ledger: AttentionLedger? = nil) {
        if let ledger { self.ledger = ledger }
        let ledger = self.ledger
        let key = service.connection?.orgKey
        let allowed = key.map { ChatAttention.personalAllowed($0, service) } ?? false
        let scope = key.map { ChatAttention.scope($0, service) }
        aggregates.update(scope.map { .init(scope: $0, session: service.connection?.sessionId ?? "", allowed: allowed) }) {
            key.flatMap { service.orgSessions[$0]?.store }
        }
        var current = AttentionCurrent()
        current.aggregateScope = allowed ? scope : nil
        current.serverEvents = Set(ledger.events.filter { $0.scope != nil && ChatAttention.valid($0, service: service) }.map(\.id))
        if allowed, let key, let store = service.orgSessions[key]?.store {
            for event in ledger.events where current.serverEvents.contains(event.id) {
                let request: String?
                switch event.destination {
                case .channel(_, let id), .folder(_, let id): request = id
                case .team(let id, _): request = id
                default: request = nil
                }
                if let request, let row = try? store.calls.request(request), let name = row.agentName {
                    current.labels[event.id] = .init(title: name, subjectID: row.agentId, subjectName: name, subjectIsAgent: true)
                }
            }
            let latest = (try? store.queue.read { try ChatAttention.latestLocalRequestIDs($0, account: key.accountId) }) ?? []
            var approvals: [String: String] = [:]
            for request in latest {
                guard let approval = try? service.journal?.approval(key, requestId: request) else { continue }
                approvals[request] = approval.runId
            }
            if let scope { current.currentRunEvents = AttentionList.currentRunEventIDs(ledger.events, latestApprovals: approvals, scope: scope) }
        }
        serverCurrent = current
    }

    func activate(_ item: AttentionItem, from store: WorkspaceStore) {
        guard !item.inFlight else { return }
        switch item.action {
        case .event(let id): AttentionCoordinator.shared.navigation?.activate(id)
        case .mention(let scope, let channel, let message, let sequence):
            guard let key = ChatAttention.key(scope), ChatAttention.sameScope(scope, .shared),
                  ChatNotifications.allowed(.shared, key, channel: channel),
                  let tab = store.showChannel(ChannelRef(key, channel: channel)) else { return }
            ChatMessageNavigation.request(ChatMessageLink(key: key, channel: channel, message: message, sequence: sequence),
                                          key: key, destination: tab.engine.view)
        case .dm(let scope, let conversation):
            guard scope == serverCurrent.aggregateScope else { return }
            aggregates.dmSource?.open(conversation, scope: scope)
        }
    }

    func secondary(_ item: AttentionItem) {
        switch item.action {
        case .event(let id):
            guard item.secondary == .dismiss else { return }
            ledger.metadata.update(id) { $0.hidden = true }; dismissalRevision += 1
        case .mention(let scope, let channel, _, _):
            guard let key = ChatAttention.key(scope), ChatAttention.sameScope(scope, .shared),
                  ChatNotifications.allowed(.shared, key, channel: channel), let store = ChatService.shared.orgSessions[key]?.store else { return }
            try? store.queue.write { db in
                let head = try ChatUnread.boundary(db, channel: channel).through
                try ChatUnread.markRead(db, channel: channel, upTo: head)
                try db.execute(sql: "UPDATE read_marks SET thread_read_seq = MAX(thread_read_seq, ?) WHERE channel_id = ?", arguments: [head, channel])
                try db.execute(sql: "UPDATE notified SET read = 1 WHERE channel_id = ? AND seq <= ? AND kind = 'mention'", arguments: [channel, head])
            }
        case .dm(let scope, let conversation):
            guard scope == serverCurrent.aggregateScope else { return }
            aggregates.dmSource?.markRead(conversation, scope: scope)
        }
    }
}

extension Session {
    var attentionEpisode: String { "\(notificationIncarnation):\(notificationPhase):\(notificationEpisode)" }
    var hasCurrentAttentionFailure: Bool {
        let state = AgentMonitor.state(of: self)
        return state == .failed || (state == .attention && attentionReason == .failure)
    }
}
