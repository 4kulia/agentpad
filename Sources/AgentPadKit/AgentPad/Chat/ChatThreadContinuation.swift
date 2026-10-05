import Foundation
import GRDB

extension ChatService {
    /// Display and personal forks enter here, through the channel's current
    /// rights. Never hand a channel conversation to the ordinary Team readers.
    func channelThreadRequest(_ key: ChatOrgKey, requestId: String, channel: String) -> ChatRequest? {
        guard channelAgentAllowed(key, channel: channel), let store = orgSessions[key]?.store,
              let request = try? store.calls.request(requestId), request.kind == "channel", request.hasFixed,
              request.channelId == channel, request.ownerAccountId == key.accountId,
              let generation = try? journal?.generation(key), generation.pending == nil, generation.generation != nil,
              generation.generation == (try? store.generation) else { return nil }
        let allowed = try? store.queue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channels c JOIN teams t ON t.team_id = c.team_id
                    JOIN agent_channels a ON a.channel_id = c.channel_id
                    WHERE c.channel_id = ? AND c.archived = 0 AND t.archived_at IS NULL
                        AND a.agent_id = ? AND a.owner_account_id = ? AND a.enabled = 1
                        AND EXISTS(SELECT 1 FROM team_members tm JOIN members m ON m.account_id = tm.account_id
                                   WHERE tm.team_id = c.team_id AND tm.account_id = ?)
                        AND EXISTS(SELECT 1 FROM team_members tm JOIN members m ON m.account_id = tm.account_id
                                   WHERE tm.team_id = c.team_id AND tm.account_id = ?))
                """, arguments: [channel, request.agentId, key.accountId, key.accountId, request.initiatorAccountId])
        }
        return allowed == true ? request : nil
    }

    func channelThreadMemory(_ key: ChatOrgKey, requestId: String, channel: String) -> String? {
        guard let request = channelThreadRequest(key, requestId: requestId, channel: channel),
              let store = orgSessions[key]?.store, let agent = request.agentId else { return nil }
        let qualifier = "may grow before the run starts"
        guard let root = request.threadRootId,
              case .known(let id?) = threadLookup(request, store: store, key: key) else {
            return "Memory: 0 earlier requests of this thread; a new conversation (\(qualifier))."
        }
        guard (try? ClaudeSessionResume.resolve(id, root: claudeProjectsRoot, visibility: .init(channelIds: [])).get()) != nil else {
            return "The earlier conversation was not found; the agent starts anew (\(qualifier))."
        }
        let entries = threadEntries(nil, key: key, agentId: agent, scope: .channel(channelId: channel, rootId: root))
            .filter { $0.finished && $0.conversation == id && $0.requestId != requestId }
        // Names are the ones recorded at each Allow, not a caller inferred
        // from today's cache. Count requests, not folder-grant segments.
        let names = Set(entries.map { $0.params.inputs.callerName }).sorted().joined(separator: ", ")
        let noun = entries.count == 1 ? "request" : "requests"
        return "Memory: remembers \(entries.count) earlier \(noun) of this thread" +
            (names.isEmpty ? "" : " by \(names)") + " (\(qualifier))."
    }

    func channelThreadSession(_ key: ChatOrgKey, requestId: String, channel: String) -> (id: String, folder: String)? {
        guard let request = channelThreadRequest(key, requestId: requestId, channel: channel),
              let store = orgSessions[key]?.store, let agentId = request.agentId, let agent = localAgent(agentId),
              case .known(let conversation?) = threadLookup(request, store: store, key: key, includingItself: true),
              let id = try? ClaudeSessionResume.resolve(conversation, root: claudeProjectsRoot, visibility: .init(channelIds: [])).get()
        else { return nil }
        return (id, agent.folder)
    }
}
