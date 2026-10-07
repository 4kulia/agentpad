import AppKit

@MainActor
enum ChatSidebarActions {
    // Each dialog stays open only while what it names may be seen: once
    // the team, the channel or the rights are gone it closes as cancelled
    // and keeps nothing it showed (review F2-p1-2; `ChatOrgWindow.ask`).

    static func askAgent(_ target: ChatSidebarAgentActions, _ model: ChatOrgModel) {
        let valid: @MainActor () -> Bool = {
            target.canAsk(in: model) && TeamService.shared.calls.serverKey == target.key
        }
        Task { @MainActor in
            guard valid() else {
                await TeamUI.showError("This agent is no longer available", nil); return
            }
            guard let prompt = await ChatOrgWindow.ask("Ask \(target.agent.name)",
                "A personal request to this agent. Its owner may need to allow it; the answer appears in Team calls.",
                "Send request", field: "", while: valid), valid() else { return }
            do {
                try target.submitAsk(in: model, resolve: { address in
                    guard let catalog = ChatService.shared.orgSessions[target.key]?.store?.calls else { throw TeamError.notConnected }
                    return try catalog.queue.read { try ChatCallStore.resolve($0, address: address).agentId }
                }, send: { address in
                    _ = try TeamService.shared.calls.ask(address, prompt: prompt, threadId: nil, origin: nil, area: .some(target.key))
                })
                TeamWindows.showCalls()
            } catch { await TeamUI.showError("The request was not sent", error) }
        }
    }

    static func newChannel(in team: ChatOrgView.Team, _ model: ChatOrgModel, navigation: ChatSidebarNavigation) {
        let id = team.teamId
        let valid: @MainActor () -> Bool = { model.isCurrent() && model.channelTeams.contains { $0.teamId == id && model.canCreateChannel(in: $0) } }
        Task { @MainActor in
            guard let name = await ChatOrgWindow.ask("New channel in \(team.name)", "A channel of the team: its members read and write in it.",
                                                     "Create", field: "", while: valid) else { return }
            if let problem = ChatOrgModel.channelNameProblem(name) { return ChannelPrompt.fail(problem) }
            guard let now = model.channelTeams.first(where: { $0.teamId == id }) else { return }
            guard let key = model.key else { return }
            do { navigation.toOpen.insert(ChannelRef(key, channel: try model.createChannel(name, in: now))) } catch { ChannelPrompt.fail(error) }
        }
    }

    static func renameChannel(_ card: ChatChannelCard, _ model: ChatOrgModel) {
        let id = card.channelId
        let valid: @MainActor () -> Bool = { model.isCurrent() && model.visibleChannel(id).map(model.canRenameChannel) == true }
        Task { @MainActor in
            guard let name = await ChatOrgWindow.ask("Rename #\(card.name)", "Every member of the team sees the new name.", "Rename",
                                                     field: card.name, while: valid) else { return }
            if let problem = ChatOrgModel.channelNameProblem(name) { return ChannelPrompt.fail(problem) }
            guard let now = model.visibleChannel(id) else { return }
            do { try model.renameChannel(now, to: name) } catch { ChannelPrompt.fail(error) }
        }
    }

    static func archiveChannel(_ card: ChatChannelCard, _ model: ChatOrgModel) {
        let id = card.channelId
        let valid: @MainActor () -> Bool = { model.isCurrent() && model.visibleChannel(id).map(model.canArchiveChannel) == true }
        Task { @MainActor in
            guard await ChatOrgWindow.confirm("Archive #\(card.name)?", "It stays readable; nobody can post in it.", "Archive",
                                              while: valid),
                  let now = model.visibleChannel(id) else { return }
            do { try model.archiveChannel(now) } catch { ChannelPrompt.fail(error) }
        }
    }

    static func addAgent(_ agent: ChatAgentCard, to card: ChatChannelCard, _ model: ChatOrgModel) {
        let id = card.channelId, agentId = agent.agentId
        let valid: @MainActor () -> Bool = {
            model.isCurrent() && model.visibleChannel(id).map { model.addableAgents($0).contains { $0.agentId == agentId } } == true
        }
        let fromSession = TeamService.shared.calls.agents.first { $0.id.uuidString.lowercased() == agentId }?.isSession == true
        let text = ChatOrgSidebarSection.addAgentText(agent, team: model.channelTeam(card)?.name ?? "of the channel", fromSession: fromSession)
        Task { @MainActor in
            guard await ChatOrgWindow.confirm("Add \(agent.name) to #\(card.name)?", text, "Add", while: valid),
                  let now = model.visibleChannel(id) else { return }
            do { try model.addAgent(agentId, to: now) } catch { ChannelPrompt.fail(error) }
        }
    }

    static func removeAgent(_ agent: ChatChannelAgent, from card: ChatChannelCard, _ model: ChatOrgModel) {
        let valid: @MainActor () -> Bool = { model.isCurrent() && model.canRemoveAgent(agent) }
        Task { @MainActor in
            guard await ChatOrgWindow.confirm("Remove \(agent.name) from #\(card.name)?",
                                              "Its requests in the channel end; it can be added again.", "Remove", while: valid)
            else { return }
            do { try model.removeAgent(agent) } catch { ChannelPrompt.fail(error) }
        }
    }

}
