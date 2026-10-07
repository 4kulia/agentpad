import SwiftUI

struct ChatMissingAgentMention: Identifiable {
    var agent: ChatAgentCard
    var address: String
    var canAdd: Bool
    var guidance: String
    var id: String { agent.agentId }
}

extension ChatOrgModel {
    func missingAgentMentions(in text: String, channel: String, catalog: [ChatAgentCard]) -> [ChatMissingAgentMention] {
        guard agentsVisible, let card = visibleChannel(channel) else { return [] }
        let present = Set(agents(in: channel).map(\.agentId))
        let addable = Set(addableAgents(card).map(\.agentId))
        var seen = Set<String>()
        return catalog.compactMap { agent in
            guard !present.contains(agent.agentId), seen.insert(agent.agentId).inserted,
                  let owner = view.members.first(where: { $0.accountId == agent.ownerAccountId }) else { return nil }
            let address = "\(agent.name)@\(owner.handle)"
            guard ChatMentions.contains(address, in: text) else { return nil }
            let guidance: String
            if card.archived { guidance = "This channel is archived." }
            else if agent.ownerAccountId != me { guidance = "Ask its owner to add it before requesting an answer." }
            else if !agent.enabled { guidance = "Enable the agent, then add it to request an answer." }
            else { guidance = "Add it to request an answer." }
            return ChatMissingAgentMention(agent: agent, address: address, canAdd: addable.contains(agent.agentId), guidance: guidance)
        }
    }
}

/// Shared by a posted message and its draft; adding only changes membership.
struct ChatAgentMembershipHint: View {
    let model: ChatChannelModel
    let text: String

    private var org: ChatOrgModel? {
        guard let org = ChatOrgCurrent.shared.model, org.key == model.key else { return nil }
        return org
    }
    private var mentions: [ChatMissingAgentMention] {
        guard text.contains("@"), let org, let store = model.service.orgSessions[model.key]?.store else { return [] }
        return org.missingAgentMentions(in: text, channel: model.channel, catalog: (try? store.calls.catalog()) ?? [])
    }

    var body: some View {
        ForEach(mentions) { mention in
            VStack(alignment: .leading, spacing: 4) {
                Label("@\(mention.address) isn't in this channel.", systemImage: "person.crop.circle.badge.exclamationmark")
                Text(mention.guidance)
                if mention.canAdd {
                    Button("Add to channel") { Self.add(mention.id, model: model) }
                        .buttonStyle(.link).foregroundStyle(ChatAppearance.accent)
                        .accessibilityLabel("Add @\(mention.address) to channel")
                }
            }
            .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
    }

    static func add(_ id: String, model: ChatChannelModel) {
        guard let org = ChatOrgCurrent.shared.model, org.key == model.key,
              let card = org.visibleChannel(model.channel),
              let agent = org.addableAgents(card).first(where: { $0.agentId == id }) else { return }
        ChatSidebarActions.addAgent(agent, to: card, org)
    }
}
