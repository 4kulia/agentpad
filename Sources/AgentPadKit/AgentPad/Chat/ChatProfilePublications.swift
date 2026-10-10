import Foundation
import GRDB

struct LocalProfilePublications {
    var profiles: Set<UUID> = []
    var agents: Set<String> = []

    mutating func include(agent: ChatSidebarSnapshot.Agent, profileID: UUID?, confirmed: Bool) {
        guard agent.mine, confirmed, let profileID else { return }
        profiles.insert(profileID); agents.insert(agent.id)
    }
}

extension ChatService {
    /// Retain the journal's accepted, scoped links for local mode. They are
    /// evidence of a past confirmation, never inferred from enabled or a name.
    func rememberProfilePublications(_ profiles: AgentProfileStore) throws {
        guard let journal else { return }
        let assignments = try journal.queue.read { try ChatAssignment.fetchAll($0, sql: "SELECT * FROM assignments ORDER BY server, account_id, org_id, agent_id") }
        let links = assignments.compactMap { row -> AgentProfileDetailsStore.PublicationLink? in
            guard let id = UUID(uuidString: row.agentId),
                  let profileID = profiles.details.archive.publications[id.uuidString], profiles.profile(profileID) != nil,
                  let session = row.publishedSession, row.state == .active || row.state == .removing,
                  let scope = try? OrgKey(server: row.server, accountID: row.accountId, orgID: row.orgId) else { return nil }
            return .init(scope: scope, agentID: row.agentId, profileID: profileID, acceptedSessionID: session)
        }
        var next = profiles.details.archive
        next.confirmedPublications = links
        try profiles.details.commit(next)
    }

    /// Reads the existing journal only. No probes, publication commands or
    /// assumptions based on matching names/account ownership.
    func localProfilePublications(_ profiles: AgentProfileStore, key: ChatOrgKey,
                                  agents: [ChatSidebarSnapshot.Agent]) -> LocalProfilePublications {
        guard currentKey == key else { return .init() }
        return LocalProfilePublications.current(profiles, key: key, agents: agents)
    }
}

extension LocalProfilePublications {
    @MainActor static func current(_ profiles: AgentProfileStore, key: ChatOrgKey,
                                   agents: [ChatSidebarSnapshot.Agent]) -> Self {
        var result = Self()
        let links = (profiles.details.archive.confirmedPublications ?? []).filter { $0.scope == OrgKey(key) }
        for agent in agents {
            guard let link = links.first(where: { $0.agentID == agent.id }), profiles.profile(link.profileID) != nil else { continue }
            let sameExecutor = agent.executorSessionID == nil || agent.executorSessionID == link.acceptedSessionID
            result.include(agent: agent, profileID: link.profileID, confirmed: sameExecutor)
        }
        return result
    }
}
