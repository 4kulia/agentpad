import Foundation
import GRDB

/// A channel's requests as the members of its team see them, in the thread
/// the agent answers in (DESIGN-F5 §3): the agent, who asked, its state and
/// its publication — no text of a result (it is published as the agent's
/// message, or nowhere). Read only through a channel card kept (the F2 gate).
enum ChatChannelRequests {
    struct Card: Equatable, Identifiable {
        var requestId: String
        var agentName: String
        var initiatorAccountId: String?
        var ownerAccountId: String?
        var state: TeamRequestState
        var publication: String?
        var publishReason: String?
        var cause: String?
        var id: String { requestId }

        /// The state in a few words (D10's words for the states they share).
        var stateWord: String {
            switch state.rawValue {
            case "submitted": return "sent to the owner's Mac"
            case "awaiting_decision": return "waiting for the owner's decision"
            case "finished":
                switch publication {
                case "awaiting_publish": return "done · waiting for the owner to publish the answer"
                case "published": return "answered"
                case "withheld": return "done · the owner did not publish the answer"
                case "publish_failed": return "done · not published: " + ChatChannelRequests.reason(publishReason)
                default: return "done"
                }
            default: return state.rawValue.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// Why a publication failed (F-API `publish_reason`).
    static func reason(_ code: String?) -> String {
        switch code {
        case "agent_removed": return "the agent left the channel"
        case "agent_disabled": return "the agent was disabled"
        case "owner_left_team": return "its owner left the team"
        case "channel_archived": return "the channel was archived"
        case "initiator_removed": return "the person who asked left the organization"
        case "initiator_left_team": return "the person who asked left the team"
        default: return code.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "the server did not take it"
        }
    }

    static func read(_ db: Database, channel: String, root: String) throws -> [Card] {
        try Row.fetchAll(db, sql: """
            SELECT r.*, (SELECT a.name FROM agent_channels a WHERE a.channel_id = r.channel_id AND a.agent_id = r.agent_id) AS agent_now
            FROM requests r JOIN channels c ON c.channel_id = r.channel_id
            WHERE r.kind = 'channel' AND r.channel_id = ? AND r.thread_root_id = ?
            ORDER BY r.created_at, r.request_id
            """, arguments: [channel, root]).map { row in
            Card(requestId: row["request_id"], agentName: row["agent_now"] ?? row["agent_name"] ?? "an agent",
                 initiatorAccountId: row["initiator_account_id"], ownerAccountId: row["owner_account_id"],
                 state: TeamRequestState(rawValue: row["state"]), publication: row["publication"],
                 publishReason: row["publish_reason"], cause: row["cause"])
        }
    }

    /// How many requests each of `roots` has, for the feed.
    static func counts(_ db: Database, channel: String, roots: [String]) throws -> [String: Int] {
        guard !roots.isEmpty else { return [:] }
        let marks = roots.map { _ in "?" }.joined(separator: ", ")
        var out: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT r.thread_root_id, COUNT(*) AS n FROM requests r JOIN channels c ON c.channel_id = r.channel_id
            WHERE r.kind = 'channel' AND r.channel_id = ? AND r.thread_root_id IN (\(marks)) GROUP BY r.thread_root_id
            """, arguments: StatementArguments([channel] + roots)) {
            out[row["thread_root_id"]] = row["n"]
        }
        return out
    }
}
