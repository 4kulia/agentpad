import SwiftUI

/// Attention summaries lead to the one Request tab; permissions live there.
struct TeamPanelSection: View {
    var service = TeamService.shared
    var showsCalls = true
    private var calls: TeamCalls { service.calls }
    static func activeIncoming(_ calls: TeamCalls) -> [TeamCalls.Incoming] {
        calls.incoming.filter { !$0.state.isFinal && $0.state != .awaitingApproval }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCalls {
                ForEach(calls.awaitingDecision) { call in
                    Button("\(call.peerName) → \(call.agentName) · Review request…") { RequestTabs.shared.open(call.id, callScope: call.scope) }
                }
            }
            ForEach(calls.pendingAccess) { folder in
                Button("Folder requested · \(folder.path)") { RequestTabs.shared.open(folder.callId, scope: folder.scope.map { .server(OrgKey($0.key)) } ?? .local) }
            }
            ForEach(ClaudeVersionApprovals.shared.pending) { item in
                if let id = item.callId {
                    Button("\(item.agentName) · Review Claude Code \(item.grant.version)…") { RequestTabs.shared.open(id) }
                }
            }
        }.buttonStyle(.plain).font(Theme.display(11)).padding(.horizontal, 14)
    }

    static func details(_ call: TeamCalls.Incoming, agent: TeamPublishedAgent?) -> String {
        var parts: [String] = []
        if let detail = call.detail, !detail.isEmpty { parts.append(detail) }
        if let agent {
            parts.append("Runs Claude Code in \(agent.folder) with “\(agent.access.title)” rights: \(agent.access.summary)")
            // What a shell may do, said where the owner decides (AG-3, track Y).
            if agent.access.runsShell { parts.append(TeamAccessProfile.shellWarning) }
            parts.append("Up to \(agent.maxTurns) steps and \(agent.timeoutMinutes) minutes.")
        }
        if let project = call.origin?.project { parts.append("Sent from project \(project).") }
        if call.resume { parts.append("Continues an earlier conversation.") }
        return parts.joined(separator: " ")
    }

    static func outgoingDetails(_ call: TeamCalls.Outgoing) -> [String] {
        [call.note, call.report.detail].compactMap { $0 }.filter { !$0.isEmpty }
    }

}
