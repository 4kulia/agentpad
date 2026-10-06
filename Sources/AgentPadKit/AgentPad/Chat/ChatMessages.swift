import Foundation
import GRDB

/// A message as the server gives it (F-API "Message").
struct ChatMessageWire: Codable, Equatable, Sendable {
    struct Mention: Codable, Equatable, Sendable {
        let accountId: String
        enum CodingKeys: String, CodingKey { case accountId = "account_id" }
    }
    let messageId: String
    let channelId: String
    let threadRootId: String?
    let authorAccountId: String
    let text: String
    let mentions: [Mention]
    let revision: Int
    let seq: Int
    let createdAt: String
    let editedAt: String?
    let deletedAt: String?
    /// F8: an agent's message — its agent and the run it answers.
    let authorAgentId: String?
    let runId: String?
    let authorAgentName: String?
    let authorSessionName: String?
    let inReplyToMessageId: String?

    enum CodingKeys: String, CodingKey {
        case text, mentions, revision, seq
        case messageId = "message_id", channelId = "channel_id", threadRootId = "thread_root_id",
             authorAccountId = "author_account_id", createdAt = "created_at", editedAt = "edited_at", deletedAt = "deleted_at",
             authorAgentId = "author_agent_id", runId = "run_id", authorAgentName = "author_agent_name",
             authorSessionName = "author_session_name", inReplyToMessageId = "in_reply_to_message_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        channelId = try c.decode(String.self, forKey: .channelId)
        threadRootId = try c.decodeIfPresent(String.self, forKey: .threadRootId)
        authorAccountId = try c.decode(String.self, forKey: .authorAccountId)
        text = try c.decode(String.self, forKey: .text)
        mentions = try c.decodeIfPresent([Mention].self, forKey: .mentions) ?? []
        revision = try c.decode(Int.self, forKey: .revision)
        seq = try c.decode(Int.self, forKey: .seq)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        editedAt = try c.decodeIfPresent(String.self, forKey: .editedAt)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        authorAgentId = try c.decodeIfPresent(String.self, forKey: .authorAgentId)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        authorAgentName = try c.decodeIfPresent(String.self, forKey: .authorAgentName)
        authorSessionName = try c.decodeIfPresent(String.self, forKey: .authorSessionName)
        inReplyToMessageId = try c.decodeIfPresent(String.self, forKey: .inReplyToMessageId)
    }
}

/// `GET …/messages?before=` and `GET …/threads/{root}?before=`.
struct ChatMessagesPage: Codable, Equatable, Sendable {
    let messages: [ChatMessageWire]
    let next: Int?
    let head: Int?
}

/// A message as the cache has it: the server's parts, and what only this
/// Mac knows of one it sends (`localState`).
struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    enum LocalState: String, Codable, Sendable { case sending, failed }
    var messageId: String
    var channelId: String
    var threadRootId: String?
    var authorAccountId: String
    var seq: Int?
    var createdAt: String
    var hasFixed: Bool
    var hasMutable: Bool
    var text: String
    var mentions: [String]
    var revision: Int
    var editedAt: String?
    var deletedAt: String?
    /// F8: an agent's message (edited by nobody).
    var authorAgentId: String?
    var authorAgentName: String?
    var authorSessionName: String?
    var inReplyToMessageId: String?
    /// A greater revision is known (a frame without the message): what shows is not current.
    var stale: Int?
    var localState: LocalState?
    var localError: String?
    /// The user's edit or deletion of it not settled (`local_edits`): `saving`
    /// while its command is alive in the queue, else `failed` with why.
    struct LocalEdit: Codable, Equatable, Sendable {
        var kind: String
        var text: String?
        var state: String
        var error: String?
    }
    var localEdit: LocalEdit?
    var id: String { messageId }
    var deleted: Bool { deletedAt != nil }
    /// An edit or deletion of it is on its way: no other until its answer (review F3b-2).
    var changing: Bool { localEdit?.state == "saving" }
    /// To be read alone: incomplete, a newer revision known, or a post of
    /// this Mac whose place a frame told (review F3c-2).
    var needsRead: Bool { loading || localState == .sending && seq != nil }
    /// What shows is not the message as it is: a placeholder, or a newer revision known.
    var loading: Bool { !hasFixed && localState == nil || !hasMutable && localState == nil || stale != nil }

    init(row: Row) {
        messageId = row["message_id"]
        channelId = row["channel_id"]
        threadRootId = row["thread_root_id"]
        authorAccountId = row["author_account_id"] ?? ""
        seq = row["seq"]
        createdAt = row["created_at"] ?? ""
        hasFixed = row["has_fixed"]
        hasMutable = row["has_mutable"]
        text = row["text"] ?? ""
        mentions = (try? JSONDecoder().decode([String].self, from: Data(((row["mentions"] as String?) ?? "[]").utf8))) ?? []
        revision = row["revision"] ?? 0
        editedAt = row["edited_at"]
        deletedAt = row["deleted_at"]
        authorAgentId = row["author_agent_id"]
        authorAgentName = row["author_agent_name"]
        authorSessionName = row["author_session_name"]
        inReplyToMessageId = row["in_reply_to_message_id"]
        stale = row["stale"]
        localState = (row["local_state"] as String?).flatMap(LocalState.init)
        localError = row["local_error"]
        if let kind = row["le_kind"] as String? {
            localEdit = LocalEdit(kind: kind, text: row["le_text"], state: row["le_state"] ?? "failed", error: row["le_error"])
        }
    }
}

/// The cache's messages (DESIGN-F3): one rule of writing for every source
/// — event, window, history, thread, a single read — and the window of a
/// channel's history with its epoch.
enum ChatMessages {
    static let eventTypes: Set<String> = ["message.post", "message.edit", "message.delete"]

    /// Messages with the user's unsettled edit beside each: `saving` only
    /// while its command is pending in the queue — a command the queue
    /// dropped, holds for the user or failed shows as `failed` (review F3c-1).
    static let select = """
        SELECT m.*, le.kind AS le_kind, le.text AS le_text, le.error AS le_error,
            CASE WHEN le.state = 'saving' AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.command_id = le.command_id AND o.state = 'pending')
                 THEN 'failed' ELSE le.state END AS le_state
        FROM messages m LEFT JOIN local_edits le ON le.message_id = m.message_id
        """

    // MARK: Writing

    /// The fixed part when it is missing; the changing part when it is
    /// missing or of a greater revision. A message with its fixed part is
    /// no longer one this Mac is sending (review F3-2). True when the row changed.
    @discardableResult
    static func write(_ db: Database, _ m: ChatMessageWire) throws -> Bool {
        // A deletion takes the user's unsettled edit first, whatever else
        // follows — a row pushed out by a window, a tombstone again (review F3d-1).
        if m.deletedAt != nil {
            try ChatB1.deleted(db, id: m.messageId)
            try ChatChannelContent.forgetMessage(db, m.messageId)
            try db.execute(sql: "DELETE FROM local_edits WHERE message_id = ?", arguments: [m.messageId])
            // F4: a deleted message's notice is read — out of the Dock's count (review F4-C).
            try db.execute(sql: "UPDATE notified SET read = 1 WHERE object_id = ?", arguments: [m.messageId])
        }
        let row = try Row.fetchOne(db, sql: "SELECT has_fixed, has_mutable, revision FROM messages WHERE message_id = ?", arguments: [m.messageId])
        var changed = false
        // UX1 attribution and source are immutable, including text edits/deletions.
        if row == nil {
            // (A tombstone's text is "" already.)
            try db.execute(sql: """
                INSERT INTO messages (message_id, channel_id, thread_root_id, author_account_id, seq, created_at, has_fixed,
                    has_mutable, text, mentions, revision, edited_at, deleted_at, author_agent_id, run_id)
                VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [m.messageId, m.channelId, m.threadRootId, m.authorAccountId, m.seq, m.createdAt,
                                 m.text, mentionsJSON(m), m.revision, m.editedAt, m.deletedAt, m.authorAgentId, m.runId])
            try writeAttribution(db, m)
            try ChatUnread.sent(db, channel: m.channelId, thread: m.threadRootId, author: m.authorAccountId, through: m.seq)
            return true
        }
        if let row, !(row["has_fixed"] as Bool) {
            try writeAttribution(db, m)
            try db.execute(sql: """
                UPDATE messages SET channel_id = ?, thread_root_id = ?, author_account_id = ?, seq = ?, created_at = ?, has_fixed = 1,
                    author_agent_id = ?, run_id = ?, local_state = NULL, local_error = NULL
                WHERE message_id = ?
                """, arguments: [m.channelId, m.threadRootId, m.authorAccountId, m.seq, m.createdAt, m.authorAgentId, m.runId,
                                 m.messageId])
            changed = true
        }
        if let row, !(row["has_mutable"] as Bool) || m.revision > (row["revision"] as Int? ?? 0) {
            try db.execute(sql: """
                UPDATE messages SET has_mutable = 1, text = ?, mentions = ?, revision = ?, edited_at = ?, deleted_at = ?,
                    stale = CASE WHEN stale IS NOT NULL AND stale > ? THEN stale ELSE NULL END
                WHERE message_id = ?
                """, arguments: [m.text, mentionsJSON(m), m.revision, m.editedAt, m.deletedAt, m.revision, m.messageId])
            // Deleted: no copy of its text stays here — an edit asked or in
            // conflict goes with it (review F3-p1-2).
            changed = true
        }
        try ChatUnread.sent(db, channel: m.channelId, thread: m.threadRootId, author: m.authorAccountId, through: m.seq)
        return changed
    }

    private static func writeAttribution(_ db: Database, _ m: ChatMessageWire) throws {
        try db.execute(sql: "UPDATE messages SET author_agent_name = ?, author_session_name = ?, in_reply_to_message_id = ? WHERE message_id = ?",
                       arguments: [m.authorAgentName, m.authorSessionName, m.inReplyToMessageId, m.messageId])
    }

    private static func mentionsJSON(_ m: ChatMessageWire) -> String {
        String(decoding: (try? JSONEncoder().encode(m.mentions.map(\.accountId))) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// An event of a message (F-API "Events"): its `message` when the frame
    /// has it; else what its body tells — a post's place as a placeholder
    /// with no changing part, a newer revision as `stale` (DESIGN-F3,
    /// review F3b-2). True: wholly applied.
    static func apply(_ db: Database, _ event: ChatEvent) throws -> Bool {
        if let message = event.message {
            guard let data = try? JSONEncoder().encode(message),
                  let wire = try? JSONDecoder().decode(ChatMessageWire.self, from: data) else { return false }
            try write(db, wire)
            return true
        }
        guard let id = event.body["message_id"]?.string, let revision = event.body["revision"]?.int else { return false }
        // A deletion takes the user's unsettled edit now, not after the read (review F3e).
        if event.type == "message.delete" {
            try ChatChannelContent.forgetMessage(db, id)
            try db.execute(sql: "DELETE FROM local_edits WHERE message_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE notified SET read = 1 WHERE object_id = ?", arguments: [id])
            // Deleted, though its tombstone is still to be read: no text, no notice (review F4c-3).
            try db.execute(sql: "UPDATE messages SET deleted_at = IFNULL(deleted_at, ?), text = '', mentions = '[]' WHERE message_id = ?",
                           arguments: [event.at, id])
        }
        let channel = String(event.stream.dropFirst("channel:".count))
        let place = event.body["message_seq"]?.int ?? (event.type == "message.post" ? event.seq : nil)
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE message_id = ?)", arguments: [id]) == true {
            // A post of this Mac learns its place, so its single read can be asked (review F3c-2).
            try db.execute(sql: """
                UPDATE messages SET stale = MAX(IFNULL(stale, 0), ?), seq = IFNULL(seq, ?)
                WHERE message_id = ? AND (has_mutable = 0 OR revision < ?)
                """, arguments: [revision, place, id, revision])
            // A local post already knows its account and conversation. Its
            // sequence ACK can advance reading before the full message arrives.
            if let row = try Row.fetchOne(db, sql: "SELECT channel_id, thread_root_id, author_account_id, seq FROM messages WHERE message_id = ?", arguments: [id]),
               let author: String = row["author_account_id"], let seq: Int = row["seq"] {
                try ChatUnread.sent(db, channel: row["channel_id"], thread: row["thread_root_id"], author: author, through: seq)
            }
        } else if event.type == "message.post", let place {
            try db.execute(sql: """
                INSERT INTO messages (message_id, channel_id, seq, has_fixed, has_mutable, revision, stale)
                VALUES (?, ?, ?, 0, 0, 0, ?)
                """, arguments: [id, channel, place, revision])
        }
        return true
    }

    // MARK: The window

    /// A channel's window from the snapshot or a channels page (F-API "A
    /// channel's window"): a new epoch; its messages written; older ones go
    /// (history pages bring them again); the stream's cursor at its head.
    static func applyWindow(_ db: Database, channel: String, head: Int, messages: [ChatMessageWire], before: Int?) throws {
        try ChatB1.reset(db, channel: channel)
        for m in messages { try write(db, m) }
        let bottom = messages.map(\.seq).min()
        if let bottom {
            try db.execute(sql: "DELETE FROM messages WHERE channel_id = ? AND seq < ? AND local_state IS NULL",
                           arguments: [channel, bottom])
        }
        try db.execute(sql: """
            INSERT INTO channel_windows (channel_id, epoch, bottom_seq, history_next) VALUES (?, 1, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET epoch = epoch + 1, bottom_seq = excluded.bottom_seq, history_next = excluded.history_next
            """, arguments: [channel, bottom ?? head + 1, before])
        try db.execute(sql: "DELETE FROM thread_cursors WHERE channel_id = ?", arguments: [channel])
        try ChatStore.setCursorValue(db, "channel:\(channel)", head)
        // F4: a channel seen first — or anew after a new generation — is read up to its head.
        try db.execute(sql: """
            INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET last_read_seq = excluded.last_read_seq WHERE last_read_seq < 0
            """, arguments: [channel, head])
    }

    static func epoch(_ db: Database, _ channel: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT epoch FROM channel_windows WHERE channel_id = ?", arguments: [channel]) ?? 0
    }

    /// A read may be applied: its channel's window is the one it was asked
    /// in, and the channel's card is kept.
    static func current(_ db: Database, _ channel: String, epoch: Int) throws -> Bool {
        try epoch == self.epoch(db, channel)
            && Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = ?)", arguments: [channel]) == true
    }

    /// A history page asked from `history_next`: the continuous history grows down.
    static func applyHistory(_ db: Database, channel: String, page: ChatMessagesPage) throws {
        for m in page.messages where m.channelId == channel { try write(db, m) }
        let lowest = page.messages.map(\.seq).min()
        try db.execute(sql: """
            UPDATE channel_windows SET bottom_seq = MIN(bottom_seq, IFNULL(?, bottom_seq)), history_next = ? WHERE channel_id = ?
            """, arguments: [lowest, page.next, channel])
    }

    /// A thread page: its messages, and the thread's own way on (review F3-4).
    static func applyThread(_ db: Database, channel: String, root: String, epoch: Int, page: ChatMessagesPage) throws {
        for m in page.messages where m.channelId == channel { try write(db, m) }
        let lowest = page.messages.filter { $0.messageId != root }.map(\.seq).min()
        try db.execute(sql: """
            INSERT INTO thread_cursors (channel_id, root_id, epoch, next, shown_from) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(channel_id, root_id) DO UPDATE SET epoch = excluded.epoch, next = excluded.next,
                shown_from = MIN(IFNULL(shown_from, excluded.shown_from), IFNULL(excluded.shown_from, shown_from))
            """, arguments: [channel, root, epoch, page.next, lowest])
    }

    /// A single message read (a frame without it, a revision conflict, an
    /// answer with no event): only that message; the window stays (review F3-3).
    static func applyOne(_ db: Database, id: String, page: ChatMessagesPage) throws {
        for m in page.messages where m.messageId == id { try write(db, m) }
    }

    // MARK: Visibility

    /// What a channel no longer kept stood for goes with it: its messages,
    /// window, thread cursors, drafts and stream cursor (DESIGN-F3).
    static func dropOrphans(_ db: Database) throws {
        try ChatB1.dropOrphans(db)
        let kept = "SELECT channel_id FROM channels"
        // All of them, those being sent too: their text is a channel's the user may no longer see;
        // their commands stay in the queue (C6) (review F3b-p1-3).
        try db.execute(sql: "DELETE FROM messages WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM channel_windows WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM thread_cursors WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM drafts WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM local_edits WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM read_marks WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM thread_read_marks WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM my_threads WHERE channel_id NOT IN (\(kept))")
        try db.execute(sql: "DELETE FROM notified WHERE channel_id IS NOT NULL AND channel_id NOT IN (\(kept))")
        // The snapshot's list holds the channels of pages still to come: kept until the read ends (F5).
        try db.execute(sql: """
            DELETE FROM agent_channels WHERE channel_id NOT IN (\(kept))
                AND NOT coalesce((SELECT channels_read_open FROM meta WHERE id = 1), 0)
            """)
        // A channel's request keeps no text of a channel no longer seen — but
        // on the Mac that executes it, whose run and facts still go (F5).
        try db.execute(sql: """
            UPDATE requests SET text = '' WHERE kind = 'channel' AND channel_id NOT IN (\(kept)) AND NOT on_this_device AND text != ''
                AND NOT coalesce((SELECT channels_read_open FROM meta WHERE id = 1), 0)
            """)
        try db.execute(sql: "DELETE FROM cursors WHERE stream LIKE 'channel:%' AND substr(stream, 9) NOT IN (\(kept))")
    }

    // MARK: Sending

    /// The local row of a post being sent, in the transaction that queues it.
    static func insertSending(_ db: Database, id: String, channel: String, root: String?, author: String, text: String,
                              mentions: [String], at: String) throws {
        let json = String(decoding: (try? JSONEncoder().encode(mentions)) ?? Data("[]".utf8), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO messages (message_id, channel_id, thread_root_id, author_account_id, created_at, has_fixed, has_mutable,
                text, mentions, revision, local_state)
            VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, 0, 'sending')
            """, arguments: [id, channel, root, author, at, text, json])
        let last = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM messages WHERE channel_id = ? AND thread_root_id IS ?",
                                   arguments: [channel, root]) ?? 0
        try ChatUnread.sent(db, channel: channel, thread: root, author: author, through: last)
    }
}

extension ChatStore {
    static func setCursorValue(_ db: Database, _ stream: String, _ seq: Int) throws {
        try db.execute(sql: """
            INSERT INTO cursors (stream, seq) VALUES (?, ?) ON CONFLICT(stream) DO UPDATE SET seq = excluded.seq
            """, arguments: [stream, seq])
    }
}
