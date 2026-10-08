import Foundation

/// One-time recovery of the agent identity lost by 1.1.9's shutdown callbacks.
/// Legacy /exit tabs have the same persisted shape; no exit reason was saved.
@MainActor
enum AgentTabRepair {
    private enum Match {
        case unchanged
        case agent(id: String, conversationId: String)
    }

    @discardableResult
    static func apply(
        to state: inout PersistedState,
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        visibility: ChannelConversationFilter
    ) -> Bool {
        guard state.agentTabRepair119Applied != true else { return false }
        // Cache failures as well as matches: duplicate tabs must not repeat
        // either store's existing by-id file lookup. No transcript scan here.
        var matches: [String: Match] = [:]
        func match(_ id: String) -> Match {
            if let cached = matches[id] { return cached }
            let claudeId = try? ClaudeSessionResume.resolve(id, root: claudeProjectsRoot, visibility: visibility).get()
            let codex = CodexUsageMonitor.resolveRollout(conversationId: id, sessionsRoot: codexSessionsRoot)
            let result: Match
            switch (claudeId, codex) {
            case (.some(let canonicalId), nil):
                result = .agent(id: AgentTemplate.claudeCodeID, conversationId: canonicalId)
            case (nil, .some):
                result = .agent(id: AgentTemplate.codex.id, conversationId: id)
            default:
                // Neither store, or both: there is no unique agent to resume.
                result = .unchanged
            }
            matches[id] = result
            return result
        }
        func repair(_ node: inout PersistedPaneNode, sshRemoteHost: String?) {
            switch node.kind {
            case .pane(var pane):
                for i in pane.tabs.indices {
                    let tab = pane.tabs[i]
                    guard tab.agentId == AgentTemplate.terminal.id,
                          tab.content == nil || tab.content == .terminal,
                          tab.channel == nil, tab.inbox == nil,
                          WorkspaceStore.normalizedSSHHost(tab.sshWorkspaceHost ?? sshRemoteHost) == nil,
                          let id = tab.conversationId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                          visibility.allows(conversationId: id)
                    else { continue }
                    if case let .agent(agentId, conversationId) = match(id) {
                        pane.tabs[i].agentId = agentId
                        pane.tabs[i].conversationId = conversationId
                    }
                }
                node.kind = .pane(pane)
            case let .split(orientation, first, second, fraction):
                var first = first, second = second
                repair(&first, sshRemoteHost: sshRemoteHost)
                repair(&second, sshRemoteHost: sshRemoteHost)
                node.kind = .split(orientation: orientation, first: first, second: second, fraction: fraction)
            }
        }
        for i in state.workspaces.indices {
            let host = state.workspaces[i].sshRemoteHost
            repair(&state.workspaces[i].root, sshRemoteHost: host)
        }
        state.agentTabRepair119Applied = true
        return true
    }
}
