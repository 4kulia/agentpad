import AppKit
import SwiftUI

/// Team → Published Agents…: what this Mac lets colleagues call, and with
/// which rights (docs/agentpad/TEAM.md 6.2).
struct TeamAgentsView: View {
    @Bindable var state: TabState
    let scope: TeamScope
    let tabs: TeamTabs
    private var service: TeamService { tabs.service }
    private var calls: TeamCalls { service.calls }
    private var key: ChatOrgKey? { if case .server(let key) = scope { key.chatKey } else { nil } }
    private var agents: [TeamPublishedAgent] { tabs.agents(scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Published agents")
                .font(Theme.display(14, weight: .semibold))
            Text("Colleagues' agents can call these. Personal calls wait for your Allow. Channel calls can run and publish automatically with your consent or channel trust, using the rights you chose.")
                .font(Theme.display(11))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = state.message { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            if key != nil, let problem = ChatService.shared.publishProblem {
                // Tried again by itself (review D3-p2-5).
                Text(problem).font(Theme.display(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if agents.isEmpty {
                Text("Nothing published yet.")
                    .font(Theme.display(12))
                    .foregroundStyle(Theme.chromeMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        row(agent)
                    }
                }
            }
            HStack {
                Button("Publish Agent…") {
                    tabs.publish(from: tabs.owner(state)?.store)
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .attentionPlace([.recovery("publications")])

    }

    private func status(_ agent: TeamPublishedAgent) -> (text: String, note: String?, unconfirmed: Bool)? {
        guard let key else { return nil }
        // Read again whenever the cache is (its catalog) — review D3c-p2-4.
        _ = calls.loads
        let (status, note) = ChatService.shared.publishStatus(agent, key: key)
        switch status {
        case .local: return ("Only on this Mac: not published.", note, false)
        case .publishing: return ("Publishing…", note, false)
        case .unconfirmed: return ("Not confirmed: the server was restored from a backup.", note, true)
        case .published(let teams):
            let names = ChatService.shared.myTeams(key).filter { teams.contains($0.teamId) }.map(\.name)
            return ("Published to \(names.isEmpty ? "\(teams.count) team(s)" : names.joined(separator: ", ")).", note, false)
        case .changesNotPublished(let error):
            return ("Changes not published\(error.map { " (the server refused: \($0))" } ?? ""); calls are refused until you publish them.", note, false)
        case .unpublishing:
            return ("Unpublishing…: calls are refused; it leaves this Mac once the server confirms.", note, false)
        case .unpublishUnconfirmed:
            return ("Unpublishing not confirmed: the connection or the server changed before it was taken.", note, true)
        }
    }

    private func row(_ agent: TeamPublishedAgent) -> some View {
        let published = key != nil && ChatService.shared.isAssigned(agent.id)
        return HStack(alignment: .top, spacing: 8) {
            ContactAvatar(stableID: agent.id.uuidString.lowercased(), name: agent.name, kind: .agent, size: 28)
            Circle()
                .fill(agent.enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent.name) · \(agent.isSession ? "session · " : "")\(agent.access.title)")
                    .font(Theme.display(13, weight: .medium))
                Text(agent.description)
                    .font(Theme.display(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(2)
                if let source = agent.sessionId,
                   ChatDMHistory(files: ChatService.shared.files).needsFreshSession(source) {
                    Text(ChatDMHistory.publicationNote).font(.caption).foregroundStyle(.secondary)
                }
                Text(agent.folder)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = status(agent) {
                    Text(status.text).font(Theme.display(10.5)).foregroundStyle(Theme.chromeMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = status.note {
                        Text(note).font(Theme.display(10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if status.unconfirmed, let key {
                        // The same choice for a publication and an unpublishing waiting for the owner.
                        let unpublishing = ChatService.shared.publishStatus(agent, key: key).status == .unpublishUnconfirmed
                        HStack {
                            Button(unpublishing ? "Unpublish Again" : "Send Again") { act { try ChatService.shared.resendPublication(agent.id, key: key) } }
                            Button(unpublishing ? "Keep Published" : "Withdraw") { act { try ChatService.shared.withdrawPublication(agent.id, key: key) } }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Spacer()
            // Pausing and removing an agent published to a server come in D3b.
            Button(agent.enabled ? "Pause" : "Resume") {
                var next = agent
                next.enabled.toggle()
                Task { await save(next, previous: agent) }
            }
            .buttonStyle(.borderless)
            .disabled(published)
            .help(published ? TeamServerCore.pauseNotYet : "")
            Button("Edit…") { tabs.showPublication(TeamAgentEditing(agent: agent, key: key), from: tabs.owner(state)?.store) }.buttonStyle(.borderless)
            // Published: unpublished through the server first (D3b).
            Button(published ? "Unpublish…" : "Remove…") { tabs.requestUnpublish([agent], state: state) }.buttonStyle(.borderless)
                .disabled(published && ChatService.shared.publishStatus(agent, key: key!).status == .unpublishing)
        }
    }

    private func act(_ body: () throws -> Void) {
        guard tabs.canRead(scope) else { return }
        do { try body(); state.message = nil } catch { state.message = error.localizedDescription }
    }

    private func save(_ agent: TeamPublishedAgent, previous: TeamPublishedAgent) async {
        let identity = tabs.connectionIdentity()
        do {
            try await calls.save([agent], validate: {
                guard tabs.canRead(scope), tabs.connectionIdentity() == identity, tabs.agents(scope).contains(previous) else {
                    throw TeamError.notYet(TeamServerCore.changedMeanwhile)
                }
            })
            state.message = nil
        } catch { state.message = error.localizedDescription }
    }
}

/// An editor opened: the agent, and the organization it publishes to (nil:
/// team work off).
struct TeamAgentEditing: Identifiable {
    var agent: TeamPublishedAgent
    let key: ChatOrgKey?
    var id: UUID { agent.id }

    static func resolve(agentID: String, key: ChatOrgKey, currentKey: ChatOrgKey?, agents: [TeamPublishedAgent]) -> Self? {
        guard key == currentKey, let id = UUID(uuidString: agentID), let agent = agents.first(where: { $0.id == id }) else { return nil }
        return Self(agent: agent, key: key)
    }
}
