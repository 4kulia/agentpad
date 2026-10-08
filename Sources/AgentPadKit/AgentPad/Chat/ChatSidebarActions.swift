import AppKit

@MainActor
enum ChatSidebarActions {
    static func askAgent(_ target: ChatSidebarAgentActions, _ model: ChatOrgModel, from store: WorkspaceStore? = nil) {
        guard target.canAsk(in: model) else { return }
        CompositionTabs.shared.open(.ask(OrgKey(target.key), agentID: target.agent.id), from: store)
    }

    static func newChannel(in team: ChatOrgView.Team, _ model: ChatOrgModel, from store: WorkspaceStore? = nil) {
        guard model.isCurrent(), model.canCreateChannel(in: team), let key = model.key else { return }
        CompositionTabs.shared.newChannel(key: key, teamID: team.teamId, from: store)
    }

    static func archiveChannel(_ card: ChatChannelCard, _ model: ChatOrgModel, from store: WorkspaceStore? = nil) {
        guard model.isCurrent(), model.canArchiveChannel(card), let key = model.key,
              let store = store ?? TabRouter.shared.ensureHost(),
              let session = store.showChannel(ChannelRef(key, channel: card.channelId)),
              let engine = session.engine as? ChannelTabEngine else { return }
        let identity = TeamTabs.shared.connectionIdentity()
        engine.conversation.confirmation.request(.init(tabID: session.id, targetID: card.channelId,
            scope: OrgKey(key), generation: identity, revision: String(card.version), deadline: Date().addingTimeInterval(120)),
            title: "Archive #\(card.name)?", consequences: "It stays readable; nobody can post in it.",
            verb: "Archive", destructive: true, stillValid: { [weak engine] in
                engine?.terminations == 0 && model.isCurrent() && model.key == key
                    && TeamTabs.shared.connectionIdentity() == identity
                    && model.visibleChannel(card.channelId) == card && model.canArchiveChannel(card)
            }) {
                try model.archiveChannel(card)
        }
    }

    static func addAgent(_ agent: ChatAgentCard, to card: ChatChannelCard, _ model: ChatOrgModel, from store: WorkspaceStore? = nil) {
        guard model.isCurrent(), model.addableAgents(card).contains(agent), let key = model.key,
              let store = store ?? TabRouter.shared.ensureHost(),
              let session = store.showChannel(ChannelRef(key, channel: card.channelId)),
              let engine = session.engine as? ChannelTabEngine else { return }
        engine.conversation.showingAgents = true
        let identity = TeamTabs.shared.connectionIdentity(), team = model.channelTeam(card)
        let local = TeamService.shared.calls.agents.first { $0.id.uuidString.lowercased() == agent.agentId }
        let text = ChatOrgSidebarSection.addAgentText(agent, team: team?.name ?? "of the channel", fromSession: local?.isSession == true)
        engine.conversation.confirmation.request(.init(tabID: session.id, targetID: "agent:\(agent.agentId)",
            scope: OrgKey(key), generation: identity, revision: String(card.version), deadline: Date().addingTimeInterval(120)),
            title: "Add \(agent.name) to #\(card.name)?", consequences: text, verb: "Add", stillValid: { [weak engine] in
                engine?.terminations == 0 && model.isCurrent() && model.key == key
                    && TeamTabs.shared.connectionIdentity() == identity && model.visibleChannel(card.channelId) == card
                    && model.channelTeam(card) == team && model.addableAgents(card).contains(agent)
                    && TeamService.shared.calls.agents.first { $0.id.uuidString.lowercased() == agent.agentId } == local
            }) {
                try model.addAgent(agent.agentId, to: card)
        }
    }

    static func removeAgent(_ agent: ChatChannelAgent, from card: ChatChannelCard, _ model: ChatOrgModel, from store: WorkspaceStore? = nil) {
        guard model.isCurrent(), agent.channelId == card.channelId, model.canRemoveAgent(agent), let key = model.key,
              let store = store ?? TabRouter.shared.ensureHost(),
              let session = store.showChannel(ChannelRef(key, channel: card.channelId)),
              let engine = session.engine as? ChannelTabEngine else { return }
        engine.conversation.showingAgents = true
        let identity = TeamTabs.shared.connectionIdentity()
        engine.conversation.confirmation.request(.init(tabID: session.id, targetID: "agent:\(agent.agentId)",
            scope: OrgKey(key), generation: identity, revision: String(card.version), deadline: Date().addingTimeInterval(120)),
            title: "Remove \(agent.name) from #\(card.name)?", consequences: "Its requests in the channel end; it can be added again.",
            verb: "Remove", destructive: true, stillValid: { [weak engine] in
                engine?.terminations == 0 && model.isCurrent() && model.key == key
                    && TeamTabs.shared.connectionIdentity() == identity && model.visibleChannel(card.channelId) == card
                    && model.canRemoveAgent(agent)
            }) {
                try model.removeAgent(agent)
        }
    }

}
