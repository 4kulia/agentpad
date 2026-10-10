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
    private(set) var dmConversations: [AttentionConversation] = []
    @ObservationIgnored private var observation: ChatSnapshotObservation<[AttentionConversation]>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored var dmSource: (any AttentionDMSource)?

    func update(_ next: Gate?, store: () -> ChatStore?) {
        guard gate != next || (next?.allowed == true && observation == nil) else { dmSource?.refresh(); return }
        epoch = UUID(); observation?.cancel(); observation = nil
        dmSource?.stop(); mentions = []; dms = []; dmConversations = []; gate = next
        guard let next, next.allowed, let store = store() else { return }
        let stamp = epoch
        observation = ChatSnapshotObservation(in: store.queue,
            tracking: ["meta", "messages", "channels", "teams", "members", "read_marks", "notified", "thread_read_marks"], fetch: { db in
            try Self.read(db, scope: next.scope, session: next.session)
        }, onError: { [weak self] _ in
            guard let self, self.epoch == stamp else { return }
            self.mentions = []; self.observation = nil
        }, onChange: { [weak self] value in
            guard let self, self.epoch == stamp else { return }
            if self.mentions != value { self.mentions = value }
        })
        dmSource?.start(scope: next.scope) { [weak self] value in
            guard let self, self.epoch == stamp else { return }
            if self.dms != value { self.dms = value }
            let conversations = self.dmSource?.conversations ?? []
            if self.dmConversations != conversations { self.dmConversations = conversations }
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
        // A catch-up can contain hundreds of mentions. Reuse within this read
        // without introducing a formatter shared across database queues.
        let formatter = ISO8601DateFormatter()
        for row in rows {
            let id: String = row["channel_id"]
            let date = (row["created_at"] as String?).flatMap { ChatStore.date($0, formatter: formatter) } ?? .distantPast
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
    var aggregates: AttentionAggregates { service.attentionAggregates }
    var serverCurrent = AttentionCurrent()
    var dismissalRevision = 0
    struct Projection: Equatable {
        var items: [AttentionItem] = []
        var terminals: [UUID: [AttentionItem]] = [:]
        var profileCounts: [UUID: Int] = [:]
        var terminalIDs: Set<UUID> = []
        var tabs: [UUID: AttentionTabSnapshot] = [:]
        var tabIndicators: [UUID: AttentionIndicator] = [:]
        var workspaceIndicators: [AttentionWorkspaceID: AttentionIndicator] = [:]
        var windowIndicators: [UUID: AttentionIndicator] = [:]
    }
    private struct Input: Equatable {
        var current: AttentionCurrent
        var tabs: [AttentionTabSnapshot]
        var events: [AttentionEvent]
        var mentions: [AttentionConversation]
        var dms: [AttentionConversation]
        var channels: [AttentionConversation]
        var settings: AttentionListSettings
        var dismissed: Set<String>
        var viewed: Set<String>
    }
    /// Prepared membership and gated chat names. Terminal names stay lazy so
    /// only views displaying them observe OSC titles, renames and cwd changes.
    private enum TabName: Equatable {
        case terminal(Session)
        case prepared(String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.terminal(let a), .terminal(let b)): return a === b
            case (.prepared(let a), .prepared(let b)): return a == b
            default: return false
            }
        }
    }
    private var tabNames: [UUID: TabName] = [:]
    private(set) var projection = Projection()
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var observationEpoch = UUID()
    @ObservationIgnored private var channelConversations: [String: AttentionConversation] = [:]
    @ObservationIgnored private var service: ChatService
    @ObservationIgnored private let storesProvider: @MainActor () -> [WorkspaceStore]
    @ObservationIgnored private(set) var projectionBuildCount = 0
    init(ledger: AttentionLedger = .shared, service: ChatService = .shared,
         storesProvider: @escaping @MainActor () -> [WorkspaceStore] = { AgentMonitor.shared.storesProvider() }) {
        self.ledger = ledger; self.service = service
        self.storesProvider = storesProvider
        updateProjection()
    }

    var terminalIDsNeedingAttention: Set<UUID> { projection.terminalIDs }
    var terminalAttention: [UUID: [AttentionItem]] { projection.terminals }
    var profileAttentionCounts: [UUID: Int] { projection.profileCounts }
    var items: [AttentionItem] { projection.items }
    var tabIndicators: [UUID: AttentionIndicator] { projection.tabIndicators }
    var workspaceIndicators: [AttentionWorkspaceID: AttentionIndicator] { projection.workspaceIndicators }
    var windowIndicators: [UUID: AttentionIndicator] { projection.windowIndicators }

    func tabTitle(_ id: UUID) -> String? {
        switch tabNames[id] {
        case .terminal(let session): return session.title
        case .prepared(let title): return title
        case nil: return nil
        }
    }

    func tabTitle(_ session: Session) -> String {
        tabTitle(session.id) ?? (session.hasProcess ? session.title : session.toolRoute?.title ?? session.inbox?.kind.title ?? "Channel")
    }

    func title(for item: AttentionItem) -> String {
        item.titleTabID.flatMap(tabTitle) ?? item.title
    }

    func tooltip(_ indicator: AttentionIndicator) -> String {
        indicator.tooltip(titleForTab: tabTitle)
    }

    /// Source changes coalesce after mutations, before publishing a whole value.
    /// A transfer therefore never publishes a tab with two owners. Getters only read.
    func updateProjection() {
        let epoch = UUID(); observationEpoch = epoch
        let next = withObservationTracking { captureInput() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationEpoch == epoch else { return }
                self.updateProjection()
            }
        }
        if tabNames != next.names { tabNames = next.names }
        guard input != next.input else { return }
        input = next.input
        projectionBuildCount += 1
        let value = Self.build(next.input)
        if projection != value { projection = value }
    }

    private func captureInput() -> (input: Input, names: [UUID: TabName]) {
        var current = serverCurrent
        let model = service.orgCurrent.model
        let allowed = model.map { $0.visible && !$0.inDoubt && !$0.snapshotOwed() && $0.view.pendingGeneration == nil } == true
        let scope = allowed ? model?.key.map {
            AttentionScope(server: $0.server.description, account: $0.accountId, organization: $0.orgId, generation: model?.view.generation ?? "")
        } : nil
        if current.aggregateScope != scope { current.serverEvents = []; current.labels = [:] }
        current.aggregateScope = scope
        let channels: [AttentionConversation] = scope.map { scope in
            guard let model, model.channelsVisible else { return [] }
            return model.view.channels.compactMap { card in
                guard model.visibleChannel(card.channelId) != nil else { return nil }
                let unread = model.unread(card.channelId) ?? .init()
                var row = channelConversations[card.channelId].flatMap { $0.scope == scope ? $0 : nil }
                    ?? AttentionConversation(scope: scope, id: card.channelId, title: "", count: 0, time: .distantPast)
                row.title = "#" + card.name
                row.count = max(unread.count, unread.more || unread.something ? 1 : 0)
                row.unreadLabel = ChatSidebarSnapshot.unreadLabel(unread)
                row.boundary = model.view.unreadBoundaries[card.channelId] ?? 0
                return row
            }
        } ?? []
        let channelMap = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        channelConversations = channelMap
        let scopeKey = scope.flatMap(ChatAttention.key)
        let dmSync = scopeKey.flatMap { service.dmSync($0) }
        let dmReady = dmSync?.enabled == true && dmSync?.ready == true
        let dms = dmReady ? aggregates.dms.filter { $0.scope == scope } : []
        let dmMap = Dictionary(aggregates.dmConversations.filter { dmReady && $0.scope == scope }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let peers = Dictionary((model?.members ?? []).map { ($0.accountId, $0.name) }, uniquingKeysWith: { first, _ in first })
        _ = AgentMonitor.shared.windowGeneration
        var profilesByStore: [ObjectIdentifier: [UUID: AgentProfile]] = [:]
        var tabs: [AttentionTabSnapshot] = []
        var names: [UUID: TabName] = [:]
        for store in storesProvider() where !store.isTerminated {
            let key = ObjectIdentifier(store.agentProfiles)
            if profilesByStore[key] == nil {
                profilesByStore[key] = Dictionary(store.agentProfiles.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            let profiles = profilesByStore[key] ?? [:]
            for workspace in store.workspaces {
                for pane in workspace.root.allPanes {
                    for session in pane.tabs {
                        var title = session.toolRoute?.title ?? session.inbox?.kind.title ?? "Channel"
                        var available = true
                        var destinations: [AttentionTabDestination] = [.tab(session.id)]
                        if let ref = session.channel {
                            let row = scope.flatMap { scope in
                                ChatAttention.key(scope).flatMap { ref.belongs(to: $0) ? channelMap[ref.channel] : nil }
                            }
                            title = row?.title ?? "Channel"; available = row != nil
                            if let row { destinations.append(.channel(row.scope, row.id)) }
                        } else if case .directMessage(let ref) = session.toolRoute {
                            let row = scope.flatMap { scope in
                                ChatAttention.key(scope).flatMap { ref.belongs(to: $0) ? dmMap[ref.dm] : nil }
                            }
                            title = row?.title ?? "Direct message"; available = row != nil
                            if let row { destinations.append(.dm(row.scope, row.id)) }
                        } else if case .directMessageDraft(let draftScope, let peer) = session.toolRoute {
                            available = dmReady && scopeKey.map { draftScope == OrgKey($0) } == true && peers[peer] != nil
                            title = available ? peers[peer] ?? "Direct message" : "Direct message"
                        } else if case .request(let requestScope, let id) = session.toolRoute {
                            available = requestScope == .local || scope.flatMap(ChatAttention.key).map { requestScope == .server(OrgKey($0)) } == true
                            if available { destinations.append(.request(requestScope, id)) }
                        }
                        tabs.append(.init(id: session.id, owner: .init(window: store.windowID, workspace: workspace.id),
                                          pane: pane.id, available: available, destinations: available ? destinations : [], channel: session.channel))
                        names[session.id] = session.hasProcess ? .terminal(session) : .prepared(title)
                        if session.hasProcess {
                            current.terminals[session.id] = .init(episode: session.attentionEpisode,
                                failed: session.hasCurrentAttentionFailure, finished: session.hasCurrentAttentionCompletion,
                                agentID: session.profileID?.uuidString ?? session.id.uuidString,
                                agentName: session.profileID.flatMap { profiles[$0]?.name } ?? session.displayAgent.title, profileID: session.profileID)
                        }
                    }
                }
            }
        }
        let external = Dictionary(ExternalSessionMonitor.shared.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in ledger.events {
            if case .external(let id) = event.destination, let session = external[id] {
                current.labels[event.id] = .init(title: session.displayTitle, subjectID: session.id,
                                                subjectName: "Claude Code", subjectIsAgent: true)
            }
        }
        _ = dismissalRevision
        return (Input(current: current, tabs: tabs, events: ledger.events,
            mentions: aggregates.mentions, dms: dms, channels: channels,
            settings: AgentPadSettingsModel.shared.attentionSettings,
            dismissed: Set(ledger.metadata.markers.filter { $0.value.hidden }.keys), viewed: ledger.viewedAttentionIDs), names)
    }

    private static func build(_ input: Input) -> Projection {
        let items = AttentionList.items(ledger: input.events, current: input.current,
            mentions: input.mentions, dms: input.dms, settings: input.settings,
            dismissed: input.dismissed, viewed: input.viewed)
        var result = Projection(items: items)
        var destinations: [AttentionTabDestination: [UUID]] = [:]
        for tab in input.tabs {
            result.tabs[tab.id] = tab
            for destination in tab.destinations { destinations[destination, default: []].append(tab.id) }
        }
        let events = Dictionary(input.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reasons: [UUID: [AttentionIndicator.Reason]] = [:]
        let dmMarks = Dictionary(input.dms.map { ($0.id, $0.readMarks) }, uniquingKeysWith: { first, _ in first })
        func append(_ reason: AttentionIndicator.Reason, to targets: [AttentionTabDestination]) {
            for target in targets {
                for id in destinations[target] ?? [] { reasons[id, default: []].append(reason) }
            }
        }
        for item in items {
            guard let kind = item.indicatorKind else { continue }
            let targets: [AttentionTabDestination]
            switch item.action {
            case .event(let id):
                guard let event = events[id] else { continue }
                targets = AttentionTabDestination.event(event)
                if case .terminal(let id) = event.destination, result.tabs[id] != nil {
                    result.terminals[id, default: []].append(item)
                }
            case .mention(let scope, let channel, _, _): targets = [.channel(scope, channel)]
            case .dm(let scope, let id): targets = [.dm(scope, id)]
            }
            var reason = AttentionIndicator.Reason(id: item.id, kind: kind,
                summary: item.titleTabID == nil ? item.title + ": " + item.subtitle : item.subtitle, titleTabID: item.titleTabID)
            if kind == .unread { reason.conversation = targets.first }
            if case .dm(_, let id) = item.action { reason.readMarks = dmMarks[id] ?? [:] }
            append(reason, to: targets)
        }
        for row in input.channels where row.count > 0 {
            append(.init(id: row.unreadReasonID, kind: .unread, summary: row.title + ": " + (row.unreadLabel ?? "Unread activity"),
                         conversation: .channel(row.scope, row.id), readMarks: ["": row.boundary]),
                   to: [.channel(row.scope, row.id)])
        }
        var workspaces: [AttentionWorkspaceID: [AttentionIndicator.Reason]] = [:]
        var windows: [UUID: [AttentionIndicator.Reason]] = [:]
        for tab in input.tabs {
            guard let indicator = AttentionIndicator(reasons[tab.id] ?? []) else { continue }
            result.tabIndicators[tab.id] = indicator
            workspaces[tab.owner, default: []] += indicator.reasons
            windows[tab.owner.window, default: []] += indicator.reasons
        }
        result.workspaceIndicators = workspaces.compactMapValues(AttentionIndicator.init)
        result.windowIndicators = windows.compactMapValues(AttentionIndicator.init)
        result.terminalIDs = Set(result.terminals.keys)
        for id in result.terminalIDs {
            if let profileID = input.current.terminals[id]?.profileID { result.profileCounts[profileID, default: 0] += 1 }
        }
        return result
    }

    func refresh(service: ChatService = .shared, ledger: AttentionLedger? = nil) {
        self.service = service
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
        if serverCurrent != current { serverCurrent = current }
        updateProjection()
    }

    func activate(_ item: AttentionItem, from store: WorkspaceStore, router: TabRouter = .shared) {
        guard !item.inFlight else { return }
        switch item.action {
        case .event(let id): AttentionCoordinator.shared.navigation?.activate(id)
        case .mention(let scope, let channel, let message, let sequence):
            guard let key = ChatAttention.key(scope), ChatAttention.sameScope(scope, service),
                  ChatNotifications.allowed(service, key, channel: channel),
                  let tab = router.openChannel(ChannelRef(key, channel: channel), scope: scope, from: store) else { return }
            ChatMessageNavigation.request(ChatMessageLink(key: key, channel: channel, message: message, sequence: sequence),
                                          key: key, destination: tab.engine.view)
        case .dm(let scope, let conversation):
            guard ChatAttention.sameScope(scope, service) else { return }
            aggregates.dmSource?.open(conversation, scope: scope, from: store)
        }
    }

    func secondary(_ item: AttentionItem) {
        switch item.action {
        case .event(let id):
            guard item.secondary == .dismiss else { return }
            ledger.metadata.update(id) { $0.hidden = true }; dismissalRevision += 1
        case .mention(let scope, let channel, _, _):
            guard let key = ChatAttention.key(scope), ChatAttention.sameScope(scope, service),
                  ChatNotifications.allowed(service, key, channel: channel), let store = service.orgSessions[key]?.store else { return }
            try? store.queue.write { db in
                let head = try ChatUnread.boundary(db, channel: channel).through
                try ChatUnread.markRead(db, channel: channel, upTo: head)
                try db.execute(sql: "UPDATE read_marks SET thread_read_seq = MAX(thread_read_seq, ?) WHERE channel_id = ?", arguments: [head, channel])
                try db.execute(sql: "UPDATE notified SET read = 1 WHERE channel_id = ? AND seq <= ? AND kind = 'mention'", arguments: [channel, head])
            }
        case .dm(let scope, let conversation):
            guard ChatAttention.sameScope(scope, service) else { return }
            aggregates.dmSource?.markRead(conversation, scope: scope)
        }
    }
}

extension Session {
    var attentionEpisode: String { "\(notificationIncarnation):\(notificationPhase):\(notificationEpisode)" }
    var hasCurrentAttentionCompletion: Bool {
        notificationPhase == "turn" && activityState == .attention && attentionReason == .completion
    }
    var hasCurrentAttentionFailure: Bool {
        let state = AgentMonitor.state(of: self)
        return state == .failed || (state == .attention && attentionReason == .failure)
    }
}
