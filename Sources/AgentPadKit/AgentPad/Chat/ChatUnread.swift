import Foundation
import GRDB

/// Unread and the notices owed (DESIGN-F4), from the cache alone: counts
/// are worked out of `messages` and `read_marks`, never kept — a repeat,
/// a catch-up or a snapshot can neither count twice nor lose a message.
enum ChatUnread {
    // Shared by F4 and the inbox. Aliases are always m/r/n/seen.
    static let readJoins = """
        LEFT JOIN read_marks r ON r.channel_id = m.channel_id
        LEFT JOIN notified n ON n.object_id = m.message_id
        LEFT JOIN thread_read_marks seen ON seen.channel_id = m.channel_id AND seen.root_id = m.thread_root_id
        """
    static let readSequenceSQL = """
        CASE WHEN m.thread_root_id IS NULL THEN MAX(IFNULL(r.last_read_seq, 0), 0)
        ELSE MAX(IFNULL(r.thread_read_seq, 0), IFNULL(seen.last_read_seq, 0), 0) END
        """
    static let unreadSQL = "m.seq > (\(readSequenceSQL)) AND (m.thread_root_id IS NULL OR IFNULL(n.read, 0) = 0)"
    static let unreadMentionSQL = "m.seq > (\(readSequenceSQL)) AND IFNULL(n.read, 0) = 0"
    static let mentionSQL = """
        m.has_fixed = 1 AND m.has_mutable = 1 AND m.deleted_at IS NULL
        AND m.author_account_id != (SELECT me FROM meta WHERE id = 1)
        AND EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(m.mentions) THEN m.mentions ELSE '[]' END)
            WHERE type = 'text' AND value = (SELECT me FROM meta WHERE id = 1))
        """

    static func unreadRepliesByChannel(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.channel_id, COUNT(*) AS count FROM messages m
            JOIN channels c ON c.channel_id = m.channel_id JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
            \(readJoins)
            WHERE m.thread_root_id IS NOT NULL
                AND (m.author_account_id IS NULL OR m.author_account_id != (SELECT me FROM meta WHERE id = 1))
                AND \(unreadSQL) GROUP BY m.channel_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["channel_id"] as String, $0["count"] as Int) })
    }

    /// A visit's range is frozen before geometry can advance the persisted mark.
    struct Boundary: Equatable, Sendable {
        var after: Int
        var through: Int
        var pending: Set<String> = []
        var readIDs: Set<String> = []
    }

    static func readSequence(_ db: Database, channel: String, thread root: String? = nil) throws -> Int {
        let field = root == nil ? "last_read_seq" : "thread_read_seq"
        let baseline = try Int.fetchOne(db, sql: "SELECT \(field) FROM read_marks WHERE channel_id = ?", arguments: [channel]) ?? 0
        guard let root else { return max(0, baseline) }
        let read = try Int.fetchOne(db, sql: "SELECT last_read_seq FROM thread_read_marks WHERE channel_id = ? AND root_id = ?",
                                   arguments: [channel, root]) ?? 0
        return max(0, baseline, read)
    }

    static func boundary(_ db: Database, channel: String, thread root: String? = nil) throws -> Boundary {
        // A thread's history can arrive after opening. Bound it by what the
        // channel already knew, including posts whose conversation is not loaded.
        let last = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM messages WHERE channel_id = ?", arguments: [channel]) ?? 0
        let head = try Int.fetchOne(db, sql: "SELECT seq FROM cursors WHERE stream = ?", arguments: ["channel:\(channel)"]) ?? 0
        let read = try String.fetchAll(db, sql: "SELECT object_id FROM notified WHERE channel_id = ? AND thread_root_id = ? AND read = 1",
                                      arguments: [channel, root])
        return try Boundary(after: readSequence(db, channel: channel, thread: root), through: max(last, head),
                            pending: pendingPosts(db, channel: channel, thread: root), readIDs: Set(read))
    }

    private static func pendingPosts(_ db: Database, channel: String, thread root: String?) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT message_id FROM messages WHERE channel_id = ? AND thread_root_id IS ?
                AND author_account_id = (SELECT me FROM meta WHERE id = 1) AND local_state IS NOT NULL
            """, arguments: [channel, root]))
    }

    static func didSend(_ db: Database, channel: String, thread root: String? = nil, since boundary: Boundary) throws -> Bool {
        // A send from any window dismisses this visit's line even before its ACK.
        if try !pendingPosts(db, channel: channel, thread: root).isSubset(of: boundary.pending) { return true }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM messages WHERE channel_id = ? AND thread_root_id IS ?
                AND author_account_id = (SELECT me FROM meta WHERE id = 1) AND seq > ?)
            """, arguments: [channel, root, boundary.through]) == true
    }

    static func firstUnread(_ db: Database, channel: String, thread root: String? = nil, boundary: Boundary) throws -> String? {
        guard try !didSend(db, channel: channel, thread: root, since: boundary) else { return nil }
        let readIDs = boundary.readIDs.sorted()
        let readFilter = readIDs.isEmpty ? "" : "AND message_id NOT IN (\(readIDs.map { _ in "?" }.joined(separator: ",")))"
        var arguments: StatementArguments = [channel, root, boundary.after, channel, root, boundary.through]
        arguments += StatementArguments(readIDs)
        return try String.fetchOne(db, sql: """
            SELECT message_id FROM messages WHERE channel_id = ? AND thread_root_id IS ?
                AND has_fixed = 1 AND author_account_id != (SELECT me FROM meta WHERE id = 1)
                AND seq > MAX(?, IFNULL((SELECT MAX(seq) FROM messages WHERE channel_id = ? AND thread_root_id IS ?
                    AND author_account_id = (SELECT me FROM meta WHERE id = 1)), 0))
                AND seq <= ? \(readFilter) ORDER BY seq LIMIT 1
            """, arguments: arguments)
    }

    /// Called in the message transaction, for every delivery path and device.
    static func sent(_ db: Database, channel: String, thread root: String?, author: String, through seq: Int) throws {
        guard try String.fetchOne(db, sql: "SELECT me FROM meta WHERE id = 1") == author,
              // The first window / new generation owns the initial baseline.
              let mark = try Int.fetchOne(db, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", arguments: [channel]),
              mark >= 0 else { return }
        try markRead(db, channel: channel, upTo: seq, thread: root)
    }

    struct Count: Equatable, Sendable {
        var count = 0
        /// More is unread than the cache holds (the window starts above the mark).
        var more = false
        /// Events after the mark on a channel not followed: something new, not counted.
        var something = false
        var muted = false
    }

    /// Root messages of others above the channel's mark.
    static func count(_ db: Database, channel: String, me: String) throws -> Count {
        let mark = try Row.fetchOne(db, sql: "SELECT last_read_seq, muted FROM read_marks WHERE channel_id = ?", arguments: [channel])
        let last = max(0, (mark?["last_read_seq"] as Int?) ?? 0)
        // A placeholder (a post without its message) counts as another's root
        // until its read shows otherwise (review F4b-2).
        let n = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages WHERE channel_id = ? AND thread_root_id IS NULL AND seq > ?
                AND (author_account_id IS NULL OR author_account_id != ?)
            """, arguments: [channel, last, me]) ?? 0
        let bottom = try Int.fetchOne(db, sql: "SELECT bottom_seq FROM channel_windows WHERE channel_id = ?", arguments: [channel]) ?? 0
        let head = try Int.fetchOne(db, sql: "SELECT seq FROM cursors WHERE stream = ?", arguments: ["channel:\(channel)"]) ?? 0
        // The window starts above the mark: unread may lie below it, counted or
        // not — "N+", or at least "•" (review F4b-3).
        return Count(count: n, more: bottom > last + 1, something: n == 0 && head > last, muted: mark?["muted"] ?? false)
    }

    /// Read up to `seq`: the mark moves on (never back); notices of messages
    /// up to it are read. Their ids, for taking the notices back.
    @discardableResult
    static func markRead(_ db: Database, channel: String, upTo seq: Int, thread root: String? = nil) throws -> [String] {
        if root == nil {
            try db.execute(sql: """
                INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET last_read_seq = MAX(last_read_seq, excluded.last_read_seq)
                WHERE excluded.last_read_seq > read_marks.last_read_seq
                """, arguments: [channel, seq])
        } else if let root {
            try db.execute(sql: """
                INSERT INTO thread_read_marks (channel_id, root_id, last_read_seq) VALUES (?, ?, ?)
                ON CONFLICT(channel_id, root_id) DO UPDATE SET last_read_seq = excluded.last_read_seq
                WHERE excluded.last_read_seq > thread_read_marks.last_read_seq
                """, arguments: [channel, root, seq])
        }
        let filter = root == nil
            ? "seq <= ? AND thread_root_id IS NULL AND object_id NOT IN (SELECT message_id FROM messages WHERE thread_root_id IS NOT NULL)"
            : "seq <= ? AND (thread_root_id = ? OR object_id = ? OR object_id IN (SELECT message_id FROM messages WHERE thread_root_id = ?))"
        let args: StatementArguments = root.map { [channel, seq, $0, $0, $0] } ?? [channel, seq]
        let ids = try String.fetchAll(db, sql: "SELECT object_id FROM notified WHERE channel_id = ? AND read = 0 AND \(filter)", arguments: args)
        try db.execute(sql: "UPDATE notified SET read = 1 WHERE channel_id = ? AND read = 0 AND \(filter)", arguments: args)
        if let root {
            // A snapshot/catch-up may have brought a mention without a banner.
            // Record that it was actually viewed without inventing a notification.
            try db.execute(sql: """
                INSERT OR IGNORE INTO notified (object_id, kind, channel_id, seq, read, thread_root_id)
                SELECT message_id, 'reply', channel_id, seq, 1, thread_root_id FROM messages
                WHERE channel_id = ? AND (thread_root_id = ? OR message_id = ?) AND seq <= ? AND has_fixed = 1
                """, arguments: [channel, root, root, seq])
        }
        return ids
    }

    static func setMuted(_ db: Database, channel: String, _ muted: Bool) throws {
        try db.execute(sql: """
            INSERT INTO read_marks (channel_id, last_read_seq, muted) VALUES (?, 0, ?)
            ON CONFLICT(channel_id) DO UPDATE SET muted = excluded.muted
            WHERE read_marks.muted != excluded.muted
            """, arguments: [channel, muted])
    }

    /// Mentions not read yet, of channels kept: the Dock's share.
    /// Counted from the messages themselves — a catch-up's or a snapshot's
    /// too — not from the notices shown (review F4c-2): mentions of me by
    /// others, not deleted, above the channel's mark, in my teams' channels,
    /// not read in their thread. `notified` only keeps banners from repeating.
    static func unreadMentions(_ db: Database) throws -> Int {
        try unreadMentionsByChannel(db).values.reduce(0, +)
    }

    /// Shared by the sidebar, saved mention view and Dock, including thread reads.
    static func unreadMentionsByChannel(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.channel_id, COUNT(*) AS count FROM messages m
                JOIN channels c ON c.channel_id = m.channel_id
                JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
                \(readJoins)
            WHERE \(mentionSQL) AND \(unreadMentionSQL)
            GROUP BY m.channel_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["channel_id"] as String, $0["count"] as Int) })
    }

    /// Whether a message owes a notice, and of which kind — one per message
    /// (a mention above a reply, review F4-4); its marker is set here, in the
    /// transaction that decides. Nil: none owed (mine, already told, not for
    /// me, a reply in a muted channel).
    static func owe(_ db: Database, messageId: String, me: String, eligibleReply: Bool? = nil) throws -> String? {
        guard let m = try Row.fetchOne(db, sql: """
                SELECT m.*, (\(mentionSQL)) AS is_mention
                FROM messages m WHERE message_id = ?
                """, arguments: [messageId]),
              m["has_fixed"] as Bool, m["has_mutable"] as Bool, (m["deleted_at"] as String?) == nil,
              (m["author_account_id"] as String?) != me else { return nil }
        let channel: String = m["channel_id"]
        var kind: String?
        if m["is_mention"] as Bool {
            kind = "mention"
        } else if let root = m["thread_root_id"] as String?,
                  try (eligibleReply == true || (eligibleReply == nil
                    && (try Bool.fetchOne(db, sql: "SELECT b1_participation FROM meta WHERE id = 1")) != true
                    && (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM my_threads WHERE channel_id = ? AND root_id = ?)", arguments: [channel, root])) == true)),
                  try Bool.fetchOne(db, sql: "SELECT muted FROM read_marks WHERE channel_id = ?", arguments: [channel]) != true {
            kind = "reply"
        }
        guard let kind else { return nil }
        // Read already (its place under the mark — a placeholder read in an open
        // feed): marked, read, no notice (review F4b-4).
        let mark = try readSequence(db, channel: channel, thread: m["thread_root_id"])
        let read = (m["seq"] as Int?).map { $0 <= mark } ?? false
        try db.execute(sql: "INSERT OR IGNORE INTO notified (object_id, kind, channel_id, seq, read, thread_root_id) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [messageId, kind, channel, m["seq"] as Int?, read, m["thread_root_id"] as String?])
        return db.changesCount > 0 && !read ? kind : nil
    }
}
