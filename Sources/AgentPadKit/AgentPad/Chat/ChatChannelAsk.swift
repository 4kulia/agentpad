import Foundation
import GRDB

/// Asking an agent of a channel from a message (DESIGN-F5 §2): the user's
/// own message that names `@name@handle` of an agent of the channel offers
/// "Ask"; the request goes with the text and the context the user chose —
/// references only, the server takes the text from its own messages.
enum ChatChannelAsk {
    /// F-API "An agent in a channel": the context's limits, the request's text.
    static let commandType = "request.create_in_channel"
    static let maxContext = 20
    static let maxContextBytes = 48 * 1024
    static let maxTextBytes = 32 * 1024

    /// An offer to ask, after the user's own message named the agent.
    struct Offer: Codable, Equatable, Identifiable {
        /// The message that asked.
        var messageId: String
        var agentId: String
        var address: String
        var text: String
        /// The thread the agent answers in: the message's own, or the
        /// message itself when it is a root.
        var root: String
        var ux1 = false
        var id: String { "\(messageId)|\(agentId)" }
    }

    /// A request asked from here not answered yet, or refused: what the
    /// queue holds of it (the request itself comes in the channel's stream).
    struct Asked: Equatable, Identifiable {
        var commandId: String
        var agentId: String
        var root: String?
        var text: String
        var failed: Bool
        var error: String?
        var source: String? = nil
        var id: String { commandId }
    }

    /// The agents `text` asks: `@name@handle` of an agent of the channel.
    /// Only the user's own message is looked at — an agent's message never
    /// asks (AG-10).
    static func asked(in text: String, agents: [ChatChannelAgent]) -> [ChatChannelAgent] {
        ChatMentions.agents(in: text, agents: agents)
    }

    /// A message that may be given as context: as the server has it now.
    static func eligible(_ m: ChatMessage) -> Bool {
        m.hasFixed && m.hasMutable && !m.deleted && m.localState == nil && m.stale == nil && m.seq != nil && !m.text.isEmpty
    }

    /// What of `chosen` goes, the root first and then in the feed's order,
    /// and what is cut by the limits — shown before it is sent.
    static func fit(_ chosen: [ChatMessage], root: String) -> (taken: [ChatMessage], cut: [ChatMessage]) {
        let ordered = chosen.filter(eligible).sorted { a, b in
            if (a.messageId == root) != (b.messageId == root) { return a.messageId == root }
            return (a.seq ?? 0) < (b.seq ?? 0)
        }
        var taken: [ChatMessage] = [], cut: [ChatMessage] = [], bytes = 0
        for m in ordered {
            let size = m.text.utf8.count
            if taken.count < maxContext, bytes + size <= maxContextBytes {
                taken.append(m)
                bytes += size
            } else {
                cut.append(m)
            }
        }
        return (taken, cut)
    }

    /// Nil when the request's text may be sent: 1 byte to 32 KiB.
    static func textProblem(_ text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write what to ask." }
        return text.utf8.count > maxTextBytes ? "The request is too long: at most 32 KiB." : nil
    }

    static func args(requestId: String, agentId: String, channel: String, root: String, text: String,
                     context: [ChatMessage]) -> ChatJSON {
        .object([
            "request_id": .string(requestId), "agent_id": .string(agentId), "channel_id": .string(channel),
            "thread_root_id": .string(root), "text": .string(text), "conditions_version": .number(1),
            "context": .array(context.map { .object(["message_id": .string($0.messageId), "revision": .number(Double($0.revision))]) }),
        ])
    }

    /// The asks of `channel` the queue holds: living, or refused and not
    /// dismissed — only while the channel's card is kept.
    static func asks(_ db: Database, channel: String) throws -> [Asked] {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true
        else { return [] }
        return try ChatCommandRecord.fetchAll(db, sql: """
            SELECT * FROM outbox WHERE type IN (?, 'request.create_in_channel_v2', 'request.create_in_channel_with_attachments') AND dismissed = 0 AND IFNULL(error, '') != 'dismissed'
                AND state IN ('pending', 'sent', 'unconfirmed', 'failed') ORDER BY seq
            """, arguments: [commandType]).compactMap { record in
            guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
                  case .object(let args) = envelope.args, args["channel_id"]?.string == channel,
                  let agent = args["agent_id"]?.string else { return nil }
            if let id = args["request_id"]?.string, try Bool.fetchOne(db, sql: "SELECT has_fixed FROM requests WHERE request_id = ?", arguments: [id]) == true { return nil }
            return Asked(commandId: record.commandId, agentId: agent, root: args["thread_root_id"]?.string ?? args["source_message_id"]?.string,
                         text: args["text"]?.string ?? "", failed: record.state == .failed, error: record.error, source: args["source_message_id"]?.string)
        }
    }

    /// A refusal in words (F-API errors of `request.create` in a channel).
    static func reason(_ code: String?) -> String {
        switch code {
        case "unsupported_conditions": return "Update AgentPad on the executor Mac to use selected files"
        case "context_changed": return "A message of the context was changed or deleted: choose the context again"
        case "too_large": return "The context is too large"
        case "agent_unavailable": return "The agent is not available now"
        case "channel_archived": return "The channel is archived"
        case "rate_limited": return "Too many requests: try again later"
        case "forbidden", "not_found": return "You can't ask it here any more"
        default: return "Not asked" + (code.map { " (\($0))" } ?? "")
        }
    }
}

extension ChatService {
    /// Queues a channel's `request.create`. The request shows once the
    /// server's events bring it; until then the queue's row stands for it.
    @discardableResult
    func askInChannel(_ key: ChatOrgKey, channel: String, agentId: String, root: String, text: String,
                      context: [ChatMessage], requestID: String? = nil) throws -> String {
        guard let store = orgSessions[key]?.store else { throw ChatError.notConnected }
        let id = requestID ?? UUID().uuidString.lowercased()
        let prepared = try prepareCommand(key, type: ChatChannelAsk.commandType, args: ChatChannelAsk.args(
            requestId: id, agentId: agentId, channel: channel, root: root, text: text, context: context))
        try store.queue.write { db in _ = try prepared.table.insert(db, prepared.record, seq: prepared.record.seq) }
        prepared.sent()
        return id
    }

    func dismissAsk(_ key: ChatOrgKey, commandId: String) {
        try? orgSessions[key]?.store?.outbox.dismiss([commandId])
    }
}
