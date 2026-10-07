import Foundation

/// Recomputed through the sidebar gate, including when a button is invoked.
@MainActor
struct ChatSidebarAgentActions {
    let key: ChatOrgKey
    let agent: ChatSidebarSnapshot.Agent
    let channels: [ChatChannelCard]
    let mentionChannel: ChatChannelCard?
    let address: String?

    var accessLabel: String { "Access: \(TeamAccessProfile(rawValue: agent.access)?.title ?? agent.access)" }

    init?(agentID: String, active: ChannelRef?, model: ChatOrgModel) {
        let snapshot = ChatSidebarSnapshot(model: model, active: active)
        guard let key = model.key, let agent = snapshot.agents.first(where: { $0.id == agentID }) else { return nil }
        self.key = key; self.agent = agent
        let currentChannel = active?.belongs(to: key) == true ? active?.channel : nil
        channels = agent.channels.compactMap(model.visibleChannel).sorted {
            if $0.channelId == currentChannel { return true }
            if $1.channelId == currentChannel { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let member = channels.compactMap { channel in model.agents(in: channel.channelId).first { $0.agentId == agentID } }.first
        if let member {
            address = member.enabled ? member.address : nil
        } else if let own = model.view.myAgents.first(where: { $0.agentId == agentID && $0.ownerAccountId == model.me && $0.enabled }),
                  let owner = model.members.first(where: { $0.accountId == own.ownerAccountId }) {
            address = "\(own.name)@\(owner.handle)"
        } else { address = nil }
        if let active, active.belongs(to: key), let card = model.visibleChannel(active.channel), !card.archived, address != nil {
            mentionChannel = card
        } else { mentionChannel = nil }
    }

    @discardableResult
    static func open(agentID: String, channel: String, model: ChatOrgModel, show: (ChannelRef) -> Void) -> Bool {
        guard let current = Self(agentID: agentID, active: nil, model: model),
              current.channels.contains(where: { $0.channelId == channel }) else { return false }
        show(ChannelRef(current.key, channel: channel))
        return true
    }

    /// Capturing the whole organization and address prevents a dialog opened for
    /// one colleague from silently targeting another after a connection change.
    func canAsk(in model: ChatOrgModel) -> Bool {
        guard !agent.mine, let address,
              let current = Self(agentID: agent.id, active: nil, model: model) else { return false }
        return current.key == key && current.address == address && !current.agent.mine
    }

    func submitAsk(in model: ChatOrgModel, resolve: (String) throws -> String, send: (String) throws -> Void) throws {
        guard canAsk(in: model), let address, try resolve(address) == agent.id else {
            throw TeamError.storage("The agent changed while the request was being written. Open its card and try again.")
        }
        try send(address)
    }
}
