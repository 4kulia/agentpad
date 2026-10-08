import Foundation
import GRDB

/// B1 projections have their own read versions. None of these heads is an event cursor.
enum ChatB1 {
    static let capabilities: Set<String> = ["chat.reactions", "chat.pins", "chat.thread_summary", "chat.thread_participation"]
    static let events: Set<String> = ["reaction.changed", "pin.changed", "thread.participation_changed"]
    static let commands: Set<String> = ["message.reaction.set", "message.pin.set"]
    static func capability(for type: String) -> String { type == "message.pin.set" ? "chat.pins" : "chat.reactions" }

    struct Reaction: Codable, Equatable, Sendable, Identifiable {
        var emoji: String
        var count: Int
        var mine: Bool
        var id: String { emoji }
    }
    struct Pin: Codable, Equatable, Sendable {
        var pinnedBy: String
        var pinnedAt: String
        enum CodingKeys: String, CodingKey { case pinnedBy = "pinned_by", pinnedAt = "pinned_at" }
    }
    struct Participant: Codable, Equatable, Sendable, Identifiable {
        var authorAccountId: String
        var authorAgentId: String?
        var authorAgentName: String?
        var authorSessionName: String?
        var id: String { [authorAccountId, authorAgentId ?? "", authorAgentId == nil ? authorSessionName ?? "" : ""].joined(separator: ":") }
        var identity: ChatAuthorIdentity { .init(account: authorAccountId, agent: authorAgentId, session: authorAgentId == nil ? authorSessionName : nil) }
        enum CodingKeys: String, CodingKey {
            case authorAccountId = "author_account_id", authorAgentId = "author_agent_id"
            case authorAgentName = "author_agent_name", authorSessionName = "author_session_name"
        }
    }
    struct Summary: Codable, Equatable, Sendable {
        var rootId: String
        var replyCount: Int
        var lastReplyAt: String?
        var lastReplySeq: Int?
        var lastParticipants: [Participant]
        var label: String { "\(replyCount) \(replyCount == 1 ? "reply" : "replies")" }
        enum CodingKeys: String, CodingKey {
            case rootId = "root_id", replyCount = "reply_count", lastReplyAt = "last_reply_at"
            case lastReplySeq = "last_reply_seq", lastParticipants = "last_participants"
        }
    }
    struct Metadata: Codable, Equatable, Sendable {
        var messageId: String
        var deleted: Bool
        var reactions: [Reaction]
        var pin: Pin?
        var threadSummary: Summary?
        enum CodingKeys: String, CodingKey {
            case messageId = "message_id", deleted, reactions, pin, threadSummary = "thread_summary"
        }
    }
    struct MetadataPage: Codable, Equatable, Sendable {
        var asOfSeq: Int
        var items: [Metadata]
        enum CodingKeys: String, CodingKey { case asOfSeq = "as_of_seq", items }
    }
    struct PinnedMessage: Codable, Equatable, Sendable, Identifiable {
        var messageId: String
        var seq: Int
        var threadRootId: String?
        var authorAccountId: String
        var authorAgentId: String?
        var authorAgentName: String?
        var authorSessionName: String?
        var excerpt: String
        var pinnedBy: String
        var pinnedAt: String
        var id: String { messageId }
        enum CodingKeys: String, CodingKey {
            case messageId = "message_id", seq, threadRootId = "thread_root_id", excerpt
            case authorAccountId = "author_account_id", authorAgentId = "author_agent_id", authorAgentName = "author_agent_name"
            case authorSessionName = "author_session_name", pinnedBy = "pinned_by", pinnedAt = "pinned_at"
        }
    }
    struct PinsPage: Codable, Equatable, Sendable {
        var asOfSeq: Int
        var pins: [PinnedMessage]
        enum CodingKeys: String, CodingKey { case asOfSeq = "as_of_seq", pins }
    }
    struct ReactorsPage: Codable, Equatable, Sendable {
        var asOfSeq: Int
        var accountIds: [String]
        var next: String?
        enum CodingKeys: String, CodingKey { case asOfSeq = "as_of_seq", accountIds = "account_ids", next }
    }
    struct Participation: Codable, Equatable, Sendable {
        var channelId: String
        var rootId: String
        var firstMessageSeq: Int
        enum CodingKeys: String, CodingKey { case channelId = "channel_id", rootId = "root_id", firstMessageSeq = "first_message_seq" }
    }
    struct ThreadsPage: Codable, Equatable, Sendable {
        var memberHead: Int
        var items: [Participation]
        var next: String?
        enum CodingKeys: String, CodingKey { case memberHead = "member_head", items, next }
    }
    struct Eligibility: Codable, Equatable, Sendable {
        var asOfSeq: Int
        var participating: Bool
        var eligibleForReply: Bool
        enum CodingKeys: String, CodingKey { case asOfSeq = "as_of_seq", participating, eligibleForReply = "eligible_for_reply" }
    }
    struct Limits: Codable, Equatable, Sendable {
        var emojiVersion = "16.0"
        var emojiBytes = 128
        var metadataIds = 100
        var reactionAccountsMax = 100
        var myThreadsMax = 200
        enum CodingKeys: String, CodingKey {
            case emojiVersion = "emoji_version", emojiBytes = "emoji_bytes", metadataIds = "metadata_ids"
            case reactionAccountsMax = "reaction_accounts_max", myThreadsMax = "my_threads_max"
        }
    }

    static func migrate(_ db: Database) throws {
        try db.alter(table: "meta") { t in t.add(column: "b1_participation", .boolean).notNull().defaults(to: false); t.add(column: "b1_epoch", .integer).notNull().defaults(to: 0) }
        try db.alter(table: "my_threads") { t in t.add(column: "first_message_seq", .integer) }
        try db.alter(table: "skipped_events") { t in t.add(column: "event_json", .text) }
        for table in ["b1_metadata", "b1_pins"] {
            try db.create(table: table) { t in
                t.column("channel_id", .text).notNull()
                if table == "b1_metadata" { t.column("message_id", .text).primaryKey() }
                else { t.primaryKey(["channel_id"]) }
                t.column("error", .text)
                t.column("data", .blob)
                t.column("as_of_seq", .integer).notNull().defaults(to: -1)
                t.column("invalidated", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: true)
                t.column("ticket", .integer).notNull().defaults(to: 0)
            }
        }
        try db.execute(sql: """
            CREATE TABLE b1_participation (id INTEGER PRIMARY KEY CHECK(id = 1), head INTEGER NOT NULL DEFAULT -1,
                invalidated INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1, ticket INTEGER NOT NULL DEFAULT 0);
            INSERT INTO b1_participation (id) VALUES (1);
            CREATE TABLE b1_intents (command_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, message_id TEXT NOT NULL,
                choice TEXT NOT NULL, present BOOLEAN NOT NULL, UNIQUE(message_id, choice));
            CREATE TABLE edit_drafts (message_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, team_id TEXT NOT NULL,
                data BLOB NOT NULL, updated_at REAL NOT NULL);
            """)
        for (name, when) in [("my_threads_insert", "AFTER INSERT ON messages"),
                             ("my_threads_update", "AFTER UPDATE OF author_account_id, thread_root_id, channel_id ON messages")] {
            try db.execute(sql: "DROP TRIGGER \(name)")
            try db.execute(sql: """
                CREATE TRIGGER \(name) \(when)
                WHEN (SELECT b1_participation FROM meta WHERE id = 1) = 0 AND NEW.deleted_at IS NULL
                    AND NEW.author_account_id = (SELECT me FROM meta WHERE id = 1)
                BEGIN
                    INSERT OR IGNORE INTO my_threads (channel_id, root_id) VALUES (NEW.channel_id, IFNULL(NEW.thread_root_id, NEW.message_id));
                END
                """)
        }
    }

    /// Includes the durable rights epoch, even for revoke then rejoin of the same channel.
    struct ReadToken: Equatable, Sendable {
        var generation: String?
        var pending: String?
        var session: String?
        var projection: Int
        var rights: Int
        var window: Int
    }
    static func readToken(_ db: Database, channel: String? = nil) throws -> ReadToken? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM meta WHERE id = 1"), !(row["rights_in_doubt"] as Bool) else { return nil }
        if let channel, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) != true { return nil }
        return ReadToken(generation: row["generation"], pending: row["pending_generation"], session: row["rights_session"],
                         projection: row["b1_epoch"], rights: row["channel_access_epoch"], window: try channel.map { try ChatMessages.epoch(db, $0) } ?? 0)
    }
    static func encode(_ value: some Encodable) throws -> Data { try JSONEncoder().encode(value) }
    static func metadata(_ db: Database, id: String) throws -> Metadata? {
        guard let data = try Data.fetchOne(db, sql: "SELECT data FROM b1_metadata WHERE message_id = ?", arguments: [id]) else { return nil }
        return try JSONDecoder().decode(Metadata.self, from: data)
    }
    static func watch(_ db: Database, channel: String, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "INSERT OR IGNORE INTO b1_metadata (channel_id, message_id) VALUES (?, ?)", arguments: [channel, id])
        }
    }
    static func invalidate(_ db: Database, event: ChatEvent) throws {
        if event.type.hasPrefix("thread.participation"), event.stream.hasPrefix("member:") {
            try db.execute(sql: "UPDATE b1_participation SET invalidated = MAX(invalidated, ?), dirty = 1, ticket = ticket + 1 WHERE head < ?",
                           arguments: [event.seq, event.seq])
            return
        }
        guard event.stream.hasPrefix("channel:") else { return }
        let channel = String(event.stream.dropFirst(8))
        // Participation checks must observe posts/deletions even when metadata
        // was already fetched at this head and needs no invalidation.
        if ["message.post", "message.delete"].contains(event.type) {
            try db.execute(sql: """
                INSERT INTO b1_reply_heads (channel_id, seq) VALUES (?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET seq = MAX(seq, excluded.seq)
                """, arguments: [channel, event.seq])
        }
        let id = event.body["message_id"]?.string
        if let id { try watch(db, channel: channel, ids: [id]) }
        // post/delete may lack hydration and the root. All watched roots are then stale.
        if ["message.post", "message.delete"].contains(event.type) || id == nil {
            try db.execute(sql: "UPDATE b1_metadata SET invalidated = MAX(invalidated, ?), dirty = 1, ticket = ticket + 1 WHERE channel_id = ? AND as_of_seq < ?",
                           arguments: [event.seq, channel, event.seq])
        } else if let id {
            try db.execute(sql: "UPDATE b1_metadata SET invalidated = MAX(invalidated, ?), dirty = 1, ticket = ticket + 1 WHERE message_id = ? AND as_of_seq < ?",
                           arguments: [event.seq, id, event.seq])
        }
        if ["pin.changed", "message.edit", "message.delete"].contains(event.type) {
            try db.execute(sql: "INSERT OR IGNORE INTO b1_pins (channel_id) VALUES (?)", arguments: [channel])
            try db.execute(sql: "UPDATE b1_pins SET invalidated = MAX(invalidated, ?), dirty = 1, ticket = ticket + 1 WHERE channel_id = ? AND as_of_seq < ?",
                           arguments: [event.seq, channel, event.seq])
        }
        if event.type == "message.delete", let id { try deleted(db, id: id) }
    }
    /// The same confirmed context after reconnect: refresh without removing
    /// displayed data or lowering the heads that reject stale HTTP responses.
    static func refresh(_ db: Database) throws {
        for table in ["b1_metadata", "b1_pins", "b1_participation"] {
            try db.execute(sql: "UPDATE \(table) SET dirty = 1, ticket = ticket + 1")
        }
        for table in ["b1_metadata", "b1_pins"] {
            try db.execute(sql: "UPDATE \(table) SET error = NULL")
        }
        try db.execute(sql: "UPDATE meta SET b1_epoch = b1_epoch + 1 WHERE id = 1")
    }

    static func reset(_ db: Database, channel: String? = nil) throws {
        for table in ["b1_metadata", "b1_pins"] {
            try db.execute(sql: "UPDATE \(table) SET error = NULL, data = NULL, as_of_seq = -1, invalidated = 0, dirty = 1, ticket = ticket + 1"
                           + (channel == nil ? "" : " WHERE channel_id = ?"), arguments: StatementArguments(channel.map { [$0] } ?? []))
        }
        if channel == nil {
            try db.execute(sql: "UPDATE meta SET b1_epoch = b1_epoch + 1 WHERE id = 1")
            try db.execute(sql: "DELETE FROM b1_reply_heads")
            try db.execute(sql: "DELETE FROM my_threads WHERE (SELECT b1_participation FROM meta WHERE id = 1) = 1")
            try db.execute(sql: "UPDATE b1_participation SET head = -1, invalidated = 0, dirty = 1, ticket = ticket + 1")
        }
    }
    static func setParticipation(_ db: Database, enabled: Bool) throws {
        let before = try Bool.fetchOne(db, sql: "SELECT b1_participation FROM meta WHERE id = 1") ?? false
        guard before != enabled else { return }
        try db.execute(sql: "UPDATE meta SET b1_participation = ? WHERE id = 1", arguments: [enabled])
        try db.execute(sql: "DELETE FROM my_threads")
        try db.execute(sql: "UPDATE b1_participation SET head = -1, invalidated = 0, dirty = 1, ticket = ticket + 1")
        if !enabled {
            try db.execute(sql: """
                INSERT OR IGNORE INTO my_threads (channel_id, root_id)
                SELECT channel_id, IFNULL(thread_root_id, message_id) FROM messages
                WHERE author_account_id = (SELECT me FROM meta WHERE id = 1) AND deleted_at IS NULL
                """)
        }
    }
    @discardableResult
    static func apply(_ db: Database, page: MetadataPage, channel: String, token: ReadToken, tickets: [String: Int]) throws -> Bool {
        guard try readToken(db, channel: channel) == token else { return false }
        var applied = false
        for var item in page.items {
            guard let ticket = tickets[item.messageId],
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM b1_metadata WHERE message_id = ? AND channel_id = ?", arguments: [item.messageId, channel]),
                  page.asOfSeq >= (row["invalidated"] as Int), page.asOfSeq >= (row["as_of_seq"] as Int) else { continue }
            let tombstone = try String.fetchOne(db, sql: "SELECT deleted_at FROM messages WHERE message_id = ?", arguments: [item.messageId])
            if item.deleted || tombstone != nil {
                item.deleted = true; item.reactions = []; item.pin = nil
                try deleted(db, id: item.messageId)
            }
            try db.execute(sql: "UPDATE b1_metadata SET error = NULL, data = ?, as_of_seq = ?, dirty = (ticket != ?) WHERE message_id = ?",
                           arguments: [try encode(item), page.asOfSeq, ticket, item.messageId])
            applied = true
        }
        return applied
    }
    @discardableResult
    static func apply(_ db: Database, page: PinsPage, channel: String, token: ReadToken, ticket: Int) throws -> Bool {
        guard try readToken(db, channel: channel) == token,
              let row = try Row.fetchOne(db, sql: "SELECT * FROM b1_pins WHERE channel_id = ?", arguments: [channel]),
              page.asOfSeq >= (row["invalidated"] as Int), page.asOfSeq >= (row["as_of_seq"] as Int) else { return false }
        let pins = try page.pins.filter { try String.fetchOne(db, sql: "SELECT deleted_at FROM messages WHERE message_id = ?", arguments: [$0.messageId]) == nil }
        try db.execute(sql: "UPDATE b1_pins SET error = NULL, data = ?, as_of_seq = ?, dirty = (ticket != ?) WHERE channel_id = ?",
                       arguments: [try encode(pins), page.asOfSeq, ticket, channel])
        return true
    }
    @discardableResult
    static func applyThreads(_ db: Database, items: [Participation], head: Int, token: ReadToken, ticket: Int) throws -> Bool {
        guard try readToken(db) == token, try Bool.fetchOne(db, sql: "SELECT b1_participation FROM meta WHERE id = 1") == true,
              let row = try Row.fetchOne(db, sql: "SELECT * FROM b1_participation WHERE id = 1"),
              head >= (row["invalidated"] as Int), head >= (row["head"] as Int) else { return false }
        try db.execute(sql: "DELETE FROM my_threads")
        for item in items {
            try db.execute(sql: "INSERT OR REPLACE INTO my_threads (channel_id, root_id, first_message_seq) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM channels WHERE channel_id = ?)",
                           arguments: [item.channelId, item.rootId, item.firstMessageSeq, item.channelId])
        }
        try db.execute(sql: "UPDATE b1_participation SET head = ?, dirty = (ticket != ?) WHERE id = 1", arguments: [head, ticket])
        try db.execute(sql: """
            UPDATE notified SET withdrawn = 1 WHERE kind = 'reply' AND withdrawn = 0 AND NOT EXISTS (
                SELECT 1 FROM my_threads t WHERE t.channel_id = notified.channel_id AND t.root_id = notified.thread_root_id)
            """)
        return true
    }
    static func deleted(_ db: Database, id: String) throws {
        try db.execute(sql: "DELETE FROM edit_drafts WHERE message_id = ?", arguments: [id])
        if var item = try metadata(db, id: id) {
            item.deleted = true; item.reactions = []; item.pin = nil
            try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = ?", arguments: [try encode(item), id])
        }
        try cancelIntents(db, condition: "message_id = ?", arguments: [id])
        // Purge the excerpt immediately, even before the replacement pins read.
        for row in try Row.fetchAll(db, sql: "SELECT channel_id, data FROM b1_pins WHERE data IS NOT NULL") {
            let pins = try JSONDecoder().decode([PinnedMessage].self, from: row["data"])
            if pins.contains(where: { $0.messageId == id }) {
                try db.execute(sql: "UPDATE b1_pins SET data = ?, dirty = 1, ticket = ticket + 1 WHERE channel_id = ?",
                               arguments: [try encode(pins.filter { $0.messageId != id }), row["channel_id"] as String])
            }
        }
    }
    static func cancelIntents(_ db: Database, condition: String, arguments: StatementArguments = []) throws {
        try db.execute(sql: "UPDATE outbox SET state = 'dropped', error = 'no_longer_available' WHERE state = 'pending' AND command_id IN (SELECT command_id FROM b1_intents WHERE \(condition))", arguments: arguments)
        try db.execute(sql: "DELETE FROM b1_intents WHERE \(condition)", arguments: arguments)
    }
    static func dropOrphans(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM skipped_events WHERE stream LIKE 'channel:%' AND substr(stream, 9) NOT IN (SELECT channel_id FROM channels)")
        try cancelIntents(db, condition: "channel_id NOT IN (SELECT channel_id FROM channels)")
        for table in ["b1_metadata", "b1_pins", "b1_reply_heads"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE channel_id NOT IN (SELECT channel_id FROM channels)")
        }
    }
}

extension ChatB1.Metadata {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try values.decode(String.self, forKey: .messageId)
        deleted = try values.decode(Bool.self, forKey: .deleted)
        pin = try values.decodeIfPresent(ChatB1.Pin.self, forKey: .pin)
        threadSummary = try values.decodeIfPresent(ChatB1.Summary.self, forKey: .threadSummary)
        if var summary = threadSummary {
            var seen = Set<String>()
            summary.lastParticipants = summary.lastParticipants.filter { seen.insert($0.id).inserted }
            threadSummary = summary
        }

        // Both HTTP payloads and caches from older clients reach ForEach here.
        // An alias and its fully qualified emoji are the same reaction. Keep
        // the first position and the last snapshot; counts are not additive.
        var order: [String] = []
        var byEmoji: [String: ChatB1.Reaction] = [:]
        for var reaction in try values.decode([ChatB1.Reaction].self, forKey: .reactions) {
            reaction.emoji = ChatEmoji.canonical(reaction.emoji) ?? reaction.emoji
            if byEmoji[reaction.emoji] == nil { order.append(reaction.emoji) }
            byEmoji[reaction.emoji] = reaction
        }
        reactions = order.compactMap { byEmoji[$0] }
    }
}

extension ChatAPI {
    private func b1Query(_ values: [(String, String?)]) -> String {
        var parts = URLComponents()
        parts.queryItems = values.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        return parts.percentEncodedQuery ?? ""
    }
    func messageMetadata(_ org: String, channel: String, ids: [String], token: String) async throws -> ChatB1.MetadataPage {
        try await call(ChatB1.MetadataPage.self, "GET", "/v1/orgs/\(org)/channels/\(channel)/message-metadata", token: token,
                       query: b1Query([("ids", ids.joined(separator: ","))]))
    }
    func pins(_ org: String, channel: String, token: String) async throws -> ChatB1.PinsPage {
        try await call(ChatB1.PinsPage.self, "GET", "/v1/orgs/\(org)/channels/\(channel)/pins", token: token)
    }
    func reactors(_ org: String, channel: String, message: String, emoji: String, after: String? = nil, at: Int? = nil,
                  limit: Int = 100, token: String) async throws -> ChatB1.ReactorsPage {
        try await call(ChatB1.ReactorsPage.self, "GET", "/v1/orgs/\(org)/channels/\(channel)/messages/\(message)/reactions", token: token,
                       query: b1Query([("emoji", emoji), ("after", after), ("at", at.map(String.init)), ("limit", String(limit))]))
    }
    func myThreads(_ org: String, after: String? = nil, at: Int? = nil, limit: Int = 200, token: String) async throws -> ChatB1.ThreadsPage {
        try await call(ChatB1.ThreadsPage.self, "GET", "/v1/orgs/\(org)/my-threads", token: token,
                       query: b1Query([("after", after), ("at", at.map(String.init)), ("limit", String(limit))]))
    }
    func participation(_ org: String, channel: String, root: String, reply: String, token: String) async throws -> ChatB1.Eligibility {
        try await call(ChatB1.Eligibility.self, "GET", "/v1/orgs/\(org)/channels/\(channel)/threads/\(root)/participation", token: token,
                       query: b1Query([("reply_id", reply)]))
    }
}
