import Foundation

/// The only retained reduction state: keyed source items and their profile
/// activity contributions. Whole-value sources are diffed here, off MainActor.
actor SidebarFolderSummaryWorker {
    struct ChatInput: Equatable, Sendable {
        var key: ChatOrgKey?
        var view = ChatOrgView()
        var me = ""
    }
    struct Live: Equatable, Sendable {
        var key: SessionNameKey?
        var profileID: UUID?
        var templateID: String?
        var eligible: Bool
        var hookStateAt: Date
        var startedAt: Date
        @MainActor init(session: Session) {
            key = (session.conversationId ?? session.resumedConversationId).map { SessionNameKey(session.agent.rosterId, $0) }
            profileID = session.profileID; templateID = session.launchOrigin?.templateID
            eligible = session.hasProcess && session.sshWorkspaceHost == nil
            hookStateAt = session.hookStateAt; startedAt = session.catalogStartedAt
        }
    }
    enum Change: Sendable {
        case members(Set<SidebarAgentPadReference>)
        case profiles([AgentProfile], [String: AgentProfileBinding])
        case catalog([SessionNameKey: AgentSessionRecord])
        case visibility(ChannelConversationFilter)
        case sessions(Set<UUID>)
        case session(UUID, Live)
        case chat(ChatInput)
        case people(ChatDMPeopleInput)
        case followed(String, Bool)
        case attention([AttentionItem], [UUID: Int])
    }
    private enum Contribution: Hashable { case binding(SessionNameKey), session(UUID) }
    private enum ChatRow: Equatable {
        case channel(String, Date?, Bool, Bool)
        case person(ChatDMPerson)
        case agent(String, Bool)
    }
    private var members: Set<SidebarAgentPadReference> = []
    private var profiles: [UUID: AgentProfile] = [:]
    private var bindings: [SessionNameKey: AgentProfileBinding] = [:]
    private var catalog: [SessionNameKey: AgentSessionRecord] = [:]
    private var visibility = ChannelConversationFilter(channelIds: nil)
    private var sessions: [UUID: Live] = [:]
    private var sessionsByKey: [SessionNameKey: Set<UUID>] = [:]
    private var owners: [Contribution: UUID] = [:]
    private var activity: [UUID: [Contribution: Date]] = [:]
    private var chat = ChatInput()
    private var people = ChatDMPeopleInput()
    private var followed: [String: Bool] = [:]
    private var chatRows: [SidebarAgentPadReference: ChatRow] = [:]
    private var attention: Set<SidebarAgentPadReference> = []
    private var attentionItems: [AttentionItem] = []
    private var profileCounts: [UUID: Int] = [:]
    private var summaries: [SidebarAgentPadReference: SidebarItemSummary] = [:]
    private var dirty: Set<SidebarAgentPadReference> = []

    func apply(_ change: Change) -> [SidebarItemSummary] {
        switch change {
        case .members(let next):
            dirty.formUnion(next.subtracting(members)); members = next
            summaries = summaries.filter { next.contains($0.key) }
            chatRows = chatRows.filter { next.contains($0.key) }
            // A membership edit can add/remove whole profiles; rebuild their
            // contribution index here, never by reading live objects again.
            for key in bindings.keys { updateBinding(key) }
            for id in sessions.keys { updateSession(id) }
            updateChatRows(); updateAttention()
        case .profiles(let values, let saved):
            let next = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            let changedProfiles = changedKeys(profiles, next)
            dirty.formUnion(changedProfiles.map(SidebarAgentPadReference.myAgent))
            let identityChanged = changedProfiles.filter { profiles[$0]?.templateID != next[$0]?.templateID || profiles[$0]?.rosterID != next[$0]?.rosterID }
            profiles = next
            let nextBindings = Dictionary(saved.values.map { ($0.record.nameKey, $0) }, uniquingKeysWith: { first, _ in first })
            let keys = changedKeys(bindings, nextBindings)
            bindings = nextBindings
            for key in keys { updateBinding(key); updateSessions(for: key) }
            if !identityChanged.isEmpty {
                for key in bindings.keys where identityChanged.contains(bindings[key]!.profileID) { updateBinding(key) }
                for id in sessions.keys { updateSession(id) }
            }
        case .catalog(let next):
            let keys = changedKeys(catalog, next); catalog = next
            for key in keys { updateBinding(key); updateSessions(for: key) }
        case .visibility(let next):
            guard visibility != next else { break }
            visibility = next
            for key in bindings.keys { updateBinding(key) }
            for id in sessions.keys { updateSession(id) }
        case .sessions(let ids):
            for id in Set(sessions.keys).subtracting(ids) {
                removeSessionKey(id)
                sessions[id] = nil
                contribute(.session(id), to: nil, date: nil)
            }
        case .session(let id, let value):
            guard sessions[id] != value else { break }
            removeSessionKey(id)
            sessions[id] = value
            if let key = value.key { sessionsByKey[key, default: []].insert(id) }
            updateSession(id)
        case .chat(let next):
            guard chat != next else { break }
            let previous = chat; chat = next
            updateChatRows(previous: previous)
            if previous.key != next.key { updateAttention() }
        case .people(let next):
            guard people != next else { break }
            people = next; updatePeople()
        case .followed(let id, let value):
            guard followed[id, default: false] != value else { break }
            followed[id] = value; updateChannels([id])
        case .attention(let items, let counts):
            attentionItems = items; profileCounts = counts; updateAttention()
        }
        var result: [SidebarItemSummary] = []
        for ref in dirty where members.contains(ref) {
            let value = summary(ref)
            if summaries[ref] != value { summaries[ref] = value; result.append(value) }
        }
        dirty = []
        return result
    }
    private func changedKeys<Key: Hashable, Value: Equatable>(_ old: [Key: Value], _ next: [Key: Value]) -> Set<Key> {
        Set(old.keys).union(next.keys).filter { old[$0] != next[$0] }
    }
    private func contribute(_ key: Contribution, to profile: UUID?, date: Date?) {
        let old = owners[key]
        guard old != profile || old.flatMap({ activity[$0]?[key] }) != date else { return }
        if let old {
            activity[old]?[key] = nil
            if activity[old]?.isEmpty == true { activity[old] = nil }
            dirty.insert(.myAgent(old))
        }
        owners[key] = profile
        if let profile, let date { activity[profile, default: [:]][key] = date; dirty.insert(.myAgent(profile)) }
    }
    private func updateBinding(_ key: SessionNameKey) {
        guard let binding = bindings[key], profiles[binding.profileID] != nil, members.contains(.myAgent(binding.profileID)),
              visibility.allows(agentId: key.agentID, conversationId: key.conversationID, startedAt: binding.record.startedAt) else {
            contribute(.binding(key), to: nil, date: nil); return
        }
        contribute(.binding(key), to: binding.profileID,
                   date: SessionDisplayMetadata.activity(catalog: catalog[key], binding: binding.record))
    }
    private func updateSessions(for key: SessionNameKey) {
        for id in sessionsByKey[key] ?? [] { updateSession(id) }
    }
    private func removeSessionKey(_ id: UUID) {
        guard let key = sessions[id]?.key else { return }
        sessionsByKey[key]?.remove(id)
        if sessionsByKey[key]?.isEmpty == true { sessionsByKey[key] = nil }
    }
    private func updateSession(_ id: UUID) {
        guard let session = sessions[id], session.eligible else { contribute(.session(id), to: nil, date: nil); return }
        let bound = session.key.flatMap { bindings[$0] }.flatMap { binding in
            visibility.allows(agentId: binding.record.agentId, conversationId: binding.record.conversationId,
                              startedAt: binding.record.startedAt) ? binding : nil
        }
        let owner = session.profileID ?? bound.flatMap { binding in
            profiles[binding.profileID]?.templateID == session.templateID ? binding.profileID : nil
        }
        guard let owner, let profile = profiles[owner], members.contains(.myAgent(owner)),
              visibility.allows(agentId: profile.rosterID, conversationId: session.key?.conversationID) else {
            contribute(.session(id), to: nil, date: nil); return
        }
        contribute(.session(id), to: owner, date: SessionDisplayMetadata.activity(
            catalog: session.key.flatMap { catalog[$0] }, binding: bound?.record,
            hookStateAt: session.hookStateAt, startedAt: session.startedAt))
    }
    private func setRow(_ row: ChatRow?, for ref: SidebarAgentPadReference) {
        guard chatRows[ref] != row else { return }
        chatRows[ref] = row; dirty.insert(ref)
    }
    private func updateChatRows(previous: ChatInput? = nil) {
        // Bulk snapshots are diffed on this actor. Only affected keys rebuild
        // summaries; a channel unread/activity delta never rebuilds people or agents.
        let scopeChanged = previous?.key != chat.key || previous == nil
        if scopeChanged || previous?.view.teams != chat.view.teams {
            updateChannels()
        } else if let previous {
            var ids = changedKeys(previous.view.channelActivity, chat.view.channelActivity)
                .union(changedKeys(previous.view.unread, chat.view.unread))
                .union(changedKeys(previous.view.mentionsByChannel, chat.view.mentionsByChannel))
            if previous.view.channels != chat.view.channels {
                ids.formUnion(changedKeys(Dictionary(uniqueKeysWithValues: previous.view.channels.map { ($0.channelId, $0) }),
                                          Dictionary(uniqueKeysWithValues: chat.view.channels.map { ($0.channelId, $0) })))
            }
            updateChannels(ids)
        }
        if scopeChanged || previous?.view.teams != chat.view.teams || previous?.view.channels != chat.view.channels
            || previous?.view.channelAgents != chat.view.channelAgents || previous?.view.myAgents != chat.view.myAgents
            || previous?.view.agentsServed != chat.view.agentsServed || previous?.me != chat.me {
            updateAgents()
        }
        if scopeChanged { updatePeople() }
    }
    private func updateChannels(_ ids: Set<String>? = nil) {
        if ids?.isEmpty == true { return }
        let teams = Set(chat.view.teams.filter(\.mine).map(\.id))
        let cards = Dictionary(chat.view.channels.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
        let refs = ids.flatMap { ids in chat.key.map { key in Set(ids.map {
            SidebarAgentPadReference.channel(.init(server: key.server.description, account: key.accountId, org: key.orgId, channel: $0))
        }) } } ?? members
        for ref in refs where members.contains(ref) {
            guard case .channel(let id) = ref else { continue }
            guard matchesScope(ref), let card = cards[id.channel], teams.contains(card.teamId) else { setRow(nil, for: ref); continue }
            var unread = chat.view.unread[id.channel] ?? .init()
            if followed[id.channel] == true { unread.something = false }
            setRow(.channel(card.name, chat.view.channelActivity[id.channel], unread.count > 0 || unread.more || unread.something,
                            chat.view.mentionsByChannel[id.channel, default: 0] > 0), for: ref)
        }
    }
    private func updatePeople() {
        let persons = Dictionary(people.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for ref in members {
            guard case .person(let id) = ref else { continue }
            setRow(matchesScope(ref) ? persons[id.peer].map(ChatRow.person) : nil, for: ref)
        }
    }
    private func updateAgents() {
        var agents: [String: ChatRow] = [:]
        if chat.view.agentsServed {
            let byChannel = Dictionary(grouping: chat.view.channelAgents, by: \.channelId)
            let byTeam = Dictionary(grouping: chat.view.channels, by: \.teamId)
            for team in chat.view.teams where team.mine {
                for channel in byTeam[team.id] ?? [] {
                    for agent in byChannel[channel.channelId] ?? [] where agents[agent.agentId] == nil {
                        agents[agent.agentId] = .agent(agent.name, agent.available)
                    }
                }
            }
            for agent in chat.view.myAgents where agent.ownerAccountId == chat.me && agents[agent.agentId] == nil {
                agents[agent.agentId] = .agent(agent.name, agent.available)
            }
        }
        for ref in members {
            guard case .teamAgent(let id) = ref else { continue }
            setRow(matchesScope(ref) ? agents[id.agent] : nil, for: ref)
        }
    }
    private func matchesScope(_ ref: SidebarAgentPadReference) -> Bool {
        guard let key = chat.key else { return false }
        return ref.scope == SidebarEntryIdentity.scope(server: key.server.description, account: key.accountId, org: key.orgId)
    }
    private func updateAttention() {
        var next = Set(profileCounts.filter { $0.value > 0 }.map { SidebarAgentPadReference.myAgent($0.key) })
        if let key = chat.key {
            for item in attentionItems {
                guard let id = item.subjectID else { continue }
                next.insert(item.subjectIsAgent
                    ? .teamAgent(.init(server: key.server.description, account: key.accountId, org: key.orgId, agent: id))
                    : .person(.init(server: key.server.description, account: key.accountId, org: key.orgId, peer: id)))
            }
        }
        dirty.formUnion(attention.symmetricDifference(next)); attention = next
    }
    private func summary(_ ref: SidebarAgentPadReference) -> SidebarItemSummary {
        var value = SidebarItemSummary(reference: .agentpad(ref), title: "Unavailable", activity: nil, available: false)
        if case .myAgent(let id) = ref, let profile = profiles[id] {
            value = .init(reference: .agentpad(ref), title: profile.name, activity: activity[id]?.values.max() ?? profile.createdAt)
        } else if let row = chatRows[ref] {
            switch row {
            case .channel(let name, let date, let unread, let mentions):
                return .init(reference: .agentpad(ref), title: name, activity: date, unread: unread, attention: mentions)
            case .person(let person):
                if let key = chat.key { value = .person(person, scope: key) }
            case .agent(let name, let available):
                value = .init(reference: .agentpad(ref), title: name, activity: nil,
                              attention: attention.contains(ref), available: available)
            }
        }
        if value.available { value.attention = attention.contains(ref) }
        return value
    }
}
