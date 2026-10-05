import Foundation
import GRDB

/// One agent of a channel as the snapshot lists it (F-API "An agent in a
/// channel"): `agent` is the agent's card whatever its own audience.
struct ChatChannelAgentWire: Codable, Equatable, Sendable {
    var agentId: String
    var channelId: String
    var addedBy: String?
    var addedAt: String?
    var agent: ChatAgentCard?

    enum CodingKeys: String, CodingKey {
        case agent
        case agentId = "agent_id", channelId = "channel_id", addedBy = "added_by", addedAt = "added_at"
    }
}

/// An agent of a channel kept here, with its owner's handle: the address
/// `@name@handle` members ask it by (DESIGN-F5 §1).
struct ChatChannelAgent: Equatable, Sendable, Identifiable {
    var channelId: String
    var agentId: String
    var name: String
    var ownerAccountId: String
    var ownerHandle: String?
    var description: String
    var access: String
    var enabled: Bool
    var available: Bool
    var executorDeviceName: String?
    var id: String { agentId }
    var address: String? { ownerHandle.map { "\(name)@\($0)" } }
}

extension ChatChannelAgent {
    init(row: Row) {
        channelId = row["channel_id"]
        agentId = row["agent_id"]
        name = row["name"]
        ownerAccountId = row["owner_account_id"]
        ownerHandle = row["handle"]
        description = row["description"] ?? ""
        access = row["access"] ?? ""
        enabled = row["enabled"]
        available = row["available"]
        executorDeviceName = row["executor_device_name"]
    }
}

/// The agents of the channels kept (DESIGN-F5 §1): apart from the personal
/// catalog — only these are asked from a channel. Written from the
/// snapshot's whole list and the channel's stream; read only through a
/// channel card kept (the F2 gate), and gone with it (`dropOrphans`).
enum ChatChannelAgents {
    static let eventTypes: Set<String> = ["agent.add_to_channel", "agent.remove_from_channel"]

    /// Events of a channel's stream this reads: its own, and the card an
    /// agent of the channel publishes anew (`agent.publish` there).
    static func reads(_ event: ChatEvent) -> Bool {
        event.stream.hasPrefix("channel:") && (eventTypes.contains(event.type) || event.type == "agent.publish")
    }

    /// True: wholly applied.
    static func apply(_ db: Database, _ event: ChatEvent) throws -> Bool {
        let channel = String(event.stream.dropFirst("channel:".count))
        switch event.type {
        case "agent.add_to_channel":
            guard let wire = ChatCallStore.decode(ChatChannelAgentWire.self, event.body), wire.channelId == channel,
                  let card = wire.agent, card.agentId == wire.agentId else { return false }
            try write(db, channel: channel, card: card, addedBy: wire.addedBy, addedAt: wire.addedAt ?? event.at)
            return true
        case "agent.remove_from_channel":
            guard let agent = event.body["agent_id"]?.string else { return false }
            try db.execute(sql: "DELETE FROM agent_channels WHERE channel_id = ? AND agent_id = ?", arguments: [channel, agent])
            return true
        default:
            // `agent.publish`: the stream of a channel the agent is in.
            guard let card = ChatCallStore.decode(ChatAgentCard.self, event.body) else { return false }
            try write(db, channel: channel, card: card, addedBy: nil, addedAt: nil)
            return true
        }
    }

    /// The snapshot's list replaces the one held: it is whole, not paged —
    /// the channels of later pages are in it already.
    static func replace(_ db: Database, _ list: [ChatChannelAgentWire]) throws {
        try db.execute(sql: "DELETE FROM agent_channels")
        for wire in list {
            guard let card = wire.agent, card.agentId == wire.agentId else { continue }
            try write(db, channel: wire.channelId, card: card, addedBy: wire.addedBy, addedAt: wire.addedAt)
        }
    }

    private static func write(_ db: Database, channel: String, card: ChatAgentCard, addedBy: String?, addedAt: String?) throws {
        try db.execute(sql: """
            INSERT INTO agent_channels (channel_id, agent_id, added_by, added_at, name, owner_account_id, description, access,
                enabled, available, executor_device_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(channel_id, agent_id) DO UPDATE SET added_by = coalesce(excluded.added_by, added_by),
                added_at = coalesce(excluded.added_at, added_at), name = excluded.name, owner_account_id = excluded.owner_account_id,
                description = excluded.description, access = excluded.access, enabled = excluded.enabled,
                available = excluded.available, executor_device_name = excluded.executor_device_name
            """, arguments: [channel, card.agentId, addedBy, addedAt, card.name, card.ownerAccountId, card.description,
                             card.access, card.enabled, card.available, card.executorDeviceName])
    }

    /// The agents of `channel`, only while its card is kept.
    static func read(_ db: Database, channel: String) throws -> [ChatChannelAgent] {
        try Row.fetchAll(db, sql: """
            SELECT a.*, m.handle FROM agent_channels a
            JOIN channels c ON c.channel_id = a.channel_id
            LEFT JOIN members m ON m.account_id = a.owner_account_id
            WHERE a.channel_id = ?
            ORDER BY a.name, m.handle, a.agent_id
            """, arguments: [channel]).map(ChatChannelAgent.init(row:))
    }
}

extension ChatStore {
    func channelAgents(_ channel: String) throws -> [ChatChannelAgent] {
        try queue.read { try ChatChannelAgents.read($0, channel: channel) }
    }
}
