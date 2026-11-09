import GRDB
import SwiftUI

struct ChatChannelTrustView: View {
    let key: ChatOrgKey
    let channel: String
    let agents: [ChatChannelAgent]
    let conversation: ChatChannelSession
    var service = ChatService.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents in this channel").font(.headline)
                #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                .chatReviewParity("caller/agents/title", text: "Agents in this channel", colors: ["foreground": Theme.chromeForeground], font: .headline)
                #endif
            if agents.isEmpty { Text("Mention one of your published agents to add it here.").foregroundStyle(.secondary)
                    #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                    .chatReviewParity("caller/agents/empty", text: "Mention one of your published agents to add it here.")
                    #endif
                    }
            ForEach(agents) { agent in
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(agent.address ?? agent.name)").fontWeight(.medium)
                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                        .chatReviewParity("caller/agents/" + agent.id + "/name", text: "@\(agent.address ?? agent.name)", colors: ["foreground": Theme.chromeForeground], font: .body.weight(.medium))
                        #endif
                    Text("\(agent.trust?.enabled == true ? "Automatic answers" : "Owner decision required") · \(agent.access) · \(agent.executorDeviceName ?? "executor Mac")")
                        .font(.caption).foregroundStyle(.secondary)
                        #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                        .chatReviewParity("caller/agents/" + agent.id + "/status", text: "\(agent.trust?.enabled == true ? "Automatic answers" : "Owner decision required") · \(agent.access) · \(agent.executorDeviceName ?? "executor Mac")", font: .caption)
                        #endif
                    if agent.ownerAccountId == key.accountId {
                        Toggle("Answer in this channel without my involvement", isOn: Binding(
                            get: { agent.trust?.enabled == true }, set: { enable in set(agent, enabled: enable) }))
                            .disabled(agent.trust?.enabled != true && (service.localChannelExecutor(key, channel: channel, agent: agent) == nil
                                || TeamAccessProfile(rawValue: agent.access)?.runsShell != false))
                            #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                            .chatReviewParity("caller/agents/" + agent.id + "/trust", text: "Answer in this channel without my involvement", font: .body)
                            #endif
                        if pendingDisable(agent) { Text("Disabling waits for the server connection.").font(.caption).foregroundStyle(.orange) }
                        if TeamAccessProfile(rawValue: agent.access)?.runsShell == true {
                            Text("Channel trust requires Read or Edit files (no shell).").font(.caption)
                        }
                    }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            if conversation.confirmation.context?.targetID.hasPrefix("trust:") == true {
                InlineConfirmation(coordinator: conversation.confirmation)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingDisable(_ agent: ChatChannelAgent) -> Bool {
        ((try? service.orgSessions[key]?.store?.outbox.commands()) ?? []).contains {
            $0.type == "agent.channel_trust.set" && $0.state == .pending
                && ChatService.args($0)["channel_id"]?.string == channel && ChatService.args($0)["agent_id"]?.string == agent.agentId
                && ChatService.args($0)["enabled"] == .bool(false)
        }
    }
    private func set(_ agent: ChatChannelAgent, enabled: Bool) {
        if !enabled {
            do { try service.setChannelTrust(key, channel: channel, agent: agent, enabled: false) }
            catch { problem = error.localizedDescription }
            return
        }
        guard let tabID = conversation.tabID else { return }
        service.confirmTrust(key, channel: channel, agent: agent.agentId, tabID: tabID, coordinator: conversation.confirmation)
    }
}
