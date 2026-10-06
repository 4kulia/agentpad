import GRDB
import SwiftUI

struct ChatChannelTrustView: View {
    let key: ChatOrgKey
    let channel: String
    let agents: [ChatChannelAgent]
    var service = ChatService.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents in this channel").font(.headline)
            if agents.isEmpty { Text("Mention one of your published agents to add it here.").foregroundStyle(.secondary) }
            ForEach(agents) { agent in
                VStack(alignment: .leading, spacing: 4) {
                    Text("@\(agent.address ?? agent.name)").fontWeight(.medium)
                    Text("\(agent.trust?.enabled == true ? "Automatic answers" : "Owner decision required") · \(agent.access) · \(agent.executorDeviceName ?? "executor Mac")")
                        .font(.caption).foregroundStyle(.secondary)
                    if agent.ownerAccountId == key.accountId {
                        Toggle("Answer in this channel without my involvement", isOn: Binding(
                            get: { agent.trust?.enabled == true }, set: { enable in set(agent, enabled: enable) }))
                            .disabled(agent.trust?.enabled != true && (service.localChannelExecutor(key, channel: channel, agent: agent) == nil
                                || TeamAccessProfile(rawValue: agent.access)?.runsShell != false))
                        if pendingDisable(agent) { Text("Disabling waits for the server connection.").font(.caption).foregroundStyle(.orange) }
                        if TeamAccessProfile(rawValue: agent.access)?.runsShell == true {
                            Text("Channel trust requires Read or Edit files (no shell).").font(.caption)
                        }
                    }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(width: 430)
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
        guard let local = service.localChannelExecutor(key, channel: channel, agent: agent) else { return }
        let settings = ChatExecutionSettings(local)
        let text = "Every current and future member of this channel's team can call this agent; its answers publish automatically.\n\n"
            + "Profile: \(local.access.title)\nFolders: \(([local.folder] + (local.extraFolders ?? [])).joined(separator: ", "))\n"
            + "Memory: \(local.isSession ? "a copy of your personal session, whose knowledge may appear in answers" : "this channel's conversations")\n"
            + "Limits: \(local.maxTurns) turns, \(local.timeoutMinutes) minutes\(local.maxBudgetUSD.map { ", $\($0)" } ?? "")\n"
            + "Changing execution settings or the executor requires enabling trust again."
        Task { @MainActor in
            guard await ChatOrgWindow.confirm("Enable automatic answers?", text, "Enable", while: {
                service.localChannelExecutor(key, channel: channel, agent: agent).map(ChatExecutionSettings.init) == settings
            }) else { return }
            do { try service.setChannelTrust(key, channel: channel, agent: agent, enabled: true) }
            catch { problem = error.localizedDescription }
        }
    }
}
