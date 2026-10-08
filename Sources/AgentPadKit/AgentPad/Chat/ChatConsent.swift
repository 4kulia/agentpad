import Foundation
import GRDB

struct ChatConsentIdentity: Equatable {
    var session: String
    var generation: String
    var epoch: Int
}

struct ChatTrustReview: Equatable {
    var identity: ChatConsentIdentity
    var agent: ChatChannelAgent
    var settings: ChatExecutionSettings
    var channelVersion: Int
    var members: [String]

    var consequences: String {
        "Every current and future member of this channel's team can call this agent; its answers publish automatically.\n\n"
        + "Profile: \(settings.inputs.access)\nFolders: \(([settings.inputs.folder] + settings.inputs.extraFolders).joined(separator: ", "))\n"
        + "Changing execution settings or the executor requires enabling trust again."
    }
}

extension ChatService {
    func consentIdentity(_ key: ChatOrgKey) -> ChatConsentIdentity? {
        guard ChatAttention.personalAllowed(key, self), let connection, let store = orgSessions[key]?.store else { return nil }
        return try? store.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT generation, channel_access_epoch FROM meta WHERE id = 1"),
                  let generation: String = row["generation"] else { return nil }
            return ChatConsentIdentity(session: connection.sessionId, generation: generation, epoch: row["channel_access_epoch"])
        }
    }
    func trustReview(_ key: ChatOrgKey, channel: String, agent: String) -> ChatTrustReview? {
        guard let identity = consentIdentity(key), supports("chat.channel_ux1", key: key),
              let store = orgSessions[key]?.store,
              let card = try? store.channelAgents(channel).first(where: { $0.agentId == agent }),
              let local = localChannelExecutor(key, channel: channel, agent: card), !local.access.runsShell else { return nil }
        return try? store.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.version, c.team_id FROM channels c JOIN teams t ON t.team_id = c.team_id
                WHERE c.channel_id = ? AND c.archived = 0 AND t.archived_at IS NULL AND t.mine = 1
                """, arguments: [channel]) else { return nil }
            let members = try String.fetchAll(db, sql: "SELECT account_id FROM team_members WHERE team_id = ? ORDER BY account_id", arguments: [row["team_id"] as String])
            guard members.contains(key.accountId) else { return nil }
            return ChatTrustReview(identity: identity, agent: card, settings: ChatExecutionSettings(local), channelVersion: row["version"], members: members)
        }
    }
    @discardableResult
    func confirmTrust(_ key: ChatOrgKey, channel: String, agent: String, tabID: UUID,
                      coordinator: ConfirmationCoordinator) -> Bool {
        guard let reviewed = trustReview(key, channel: channel, agent: agent), let local = localAgent(agent) else { return false }
        let text = reviewed.consequences
            + "\nMemory: \(local.isSession ? "a copy of your personal session, whose knowledge may appear in answers" : "this channel's conversations")"
            + "\nLimits: \(local.maxTurns) turns, \(local.timeoutMinutes) minutes\(local.maxBudgetUSD.map { ", $\($0)" } ?? "")"
        return coordinator.request(.init(tabID: tabID, targetID: "trust:\(agent)", scope: OrgKey(key), generation: reviewed.identity.generation,
            revision: String(reviewed.channelVersion), deadline: Date().addingTimeInterval(120)),
            title: "Enable automatic answers?", consequences: text, verb: "Enable",
            stillValid: { self.trustReview(key, channel: channel, agent: agent) == reviewed }) {
                try self.setChannelTrust(key, channel: channel, agent: reviewed.agent, enabled: true)
            }
    }
}
