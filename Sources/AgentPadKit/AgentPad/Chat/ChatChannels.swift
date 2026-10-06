import Foundation
import GRDB

/// A channel's card (F-API "Channel card"): in the snapshot, a channels
/// page and the body of `channel.*` events. The snapshot's and a page's
/// `head` and messages are F3's; only the card is read here.
struct ChatChannelCard: Codable, Equatable, Sendable {
    var channelId: String
    var teamId: String
    var name: String
    var createdBy: String?
    var createdAt: String?
    var archived: Bool
    var archivedAt: String?
    var version: Int
    /// The snapshot's and a channels page's window of the channel (F3); not in events.
    var head: Int? = nil
    var messages: [ChatMessageWire]? = nil
    var messagesBefore: Int? = nil
    var chatMetadataReload: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case chatMetadataReload = "chat_metadata_reload"
        case name, archived, version, head, messages
        case messagesBefore = "messages_before"
        case channelId = "channel_id", teamId = "team_id", createdBy = "created_by", createdAt = "created_at",
             archivedAt = "archived_at"
    }
}

/// `GET /v1/orgs/{org}/channels?after=`: the channels the snapshot left out.
struct ChatChannelsPage: Codable, Equatable, Sendable {
    let channels: [ChatChannelCard]
    let next: String?
}

/// The cache's channel cards (DESIGN-F2): written only from events, the
/// snapshot and its pages — never from a command's answer (review F2b-1) —
/// each by the rule of versions, each write with a new `stamp`. A read of
/// the snapshot and its pages ends by dropping the cards of its starting
/// slice (`stamp ≤` the one taken when the snapshot was asked for) that it
/// did not read (review F2-5, F2b-2).
enum ChatChannels {
    static let eventTypes: Set<String> = ["channel.create", "channel.rename", "channel.archive"]

    static func card(_ body: ChatJSON) -> ChatChannelCard? {
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        return try? JSONDecoder().decode(ChatChannelCard.self, from: data)
    }

    static func stamp(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT channel_stamp FROM meta WHERE id = 1") ?? 0
    }

    /// Writes `card` when it is newer than the one kept, or new, and the
    /// user is in its team now (a page read before the user left it brings
    /// it still). True when written.
    @discardableResult
    static func write(_ db: Database, _ card: ChatChannelCard) throws -> Bool {
        let mine = try Bool.fetchOne(db, sql: "SELECT mine FROM teams WHERE team_id = ?", arguments: [card.teamId]) ?? false
        guard mine else { return false }
        let kept = try Int.fetchOne(db, sql: "SELECT version FROM channels WHERE channel_id = ?", arguments: [card.channelId])
        if let kept, kept >= card.version { return false }
        let stamp = try stamp(db) + 1
        try db.execute(sql: "UPDATE meta SET channel_stamp = ? WHERE id = 1", arguments: [stamp])
        try db.execute(sql: """
            INSERT INTO channels (channel_id, team_id, name, created_by, created_at, archived, archived_at, version, stamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET team_id = excluded.team_id, name = excluded.name,
                created_by = excluded.created_by, created_at = excluded.created_at, archived = excluded.archived,
                archived_at = excluded.archived_at, version = excluded.version, stamp = excluded.stamp
            """, arguments: [card.channelId, card.teamId, card.name, card.createdBy, card.createdAt, card.archived,
                             card.archivedAt, card.version, stamp])
        return true
    }

    /// An event's card. False — not wholly applied, a snapshot brings it —
    /// when its body is not a card.
    static func apply(_ db: Database, _ event: ChatEvent) throws -> Bool {
        guard let card = card(event.body) else { return false }
        try write(db, card)
        // A channel made now: its stream from its start, its history whole
        // from there (F3) — unless a page brought it already.
        if event.type == "channel.create",
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [card.channelId]) == true {
            try db.execute(sql: "INSERT OR IGNORE INTO cursors (stream, seq) VALUES (?, 0)", arguments: ["channel:\(card.channelId)"])
            try db.execute(sql: "INSERT OR IGNORE INTO channel_windows (channel_id, epoch, bottom_seq, history_next) VALUES (?, 1, 0, NULL)",
                           arguments: [card.channelId])
            // F4: a new channel has nothing unread.
            try db.execute(sql: "INSERT OR IGNORE INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [card.channelId])
        }
        return true
    }

    /// The end of a whole read: the cards of its starting slice it did not read go.
    static func endRead(_ db: Database, since stamp: Int, seen: Set<String>) throws {
        for id in try String.fetchAll(db, sql: "SELECT channel_id FROM channels WHERE stamp <= ?", arguments: [stamp])
            where !seen.contains(id) {
            try db.execute(sql: "DELETE FROM channels WHERE channel_id = ?", arguments: [id])
        }
        // Closed first: the agents of channels the read did not bring go too (F5).
        try db.execute(sql: "UPDATE meta SET channels_read_open = 0 WHERE id = 1")
        try ChatMessages.dropOrphans(db)
    }

    /// Cards of teams the user is not in go: nobody outside a team sees its
    /// channels, an owner or admin included (F-API "Who sees what").
    static func narrow(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM channels WHERE team_id NOT IN (SELECT team_id FROM teams WHERE mine = 1)")
        // Run after every event: the orphans' sweep only when a card went.
        if db.changesCount > 0 { try ChatMessages.dropOrphans(db) }
    }

    /// The windows of the channels a snapshot or page brought, of channels kept (F3).
    static func applyWindows(_ db: Database, _ cards: [ChatChannelCard]) throws {
        for card in cards {
            if card.chatMetadataReload == true, card.head == nil { try ChatB1.reset(db, channel: card.channelId) }
            guard let head = card.head,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [card.channelId]) == true
            else { continue }
            try ChatMessages.applyWindow(db, channel: card.channelId, head: head, messages: card.messages ?? [], before: card.messagesBefore)
        }
    }

    static func read(_ db: Database) throws -> [ChatChannelCard] {
        try Row.fetchAll(db, sql: "SELECT * FROM channels ORDER BY archived, name COLLATE NOCASE").map {
            ChatChannelCard(channelId: $0["channel_id"], teamId: $0["team_id"], name: $0["name"], createdBy: $0["created_by"],
                            createdAt: $0["created_at"], archived: $0["archived"], archivedAt: $0["archived_at"], version: $0["version"])
        }
    }
}

extension ChatStore {
    /// The stamp before a snapshot is asked for: where its read's slice ends.
    func channelStamp() throws -> Int { try queue.read { try ChatChannels.stamp($0) } }

    /// A channels page of the read; the ids it carried, written or not.
    func apply(channels page: [ChatChannelCard]) throws -> Set<String> {
        try queue.write { db in
            for card in page { try ChatChannels.write(db, card) }
            try ChatChannels.applyWindows(db, page)
            return Set(page.map(\.channelId))
        }
    }

    func endChannelsRead(since stamp: Int, seen: Set<String>) throws {
        try queue.write { try ChatChannels.endRead($0, since: stamp, seen: seen) }
    }

    func channels() throws -> [ChatChannelCard] { try queue.read { try ChatChannels.read($0) } }
}
