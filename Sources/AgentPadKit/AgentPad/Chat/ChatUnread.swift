import Foundation
import GRDB

/// Unread and the notices owed (DESIGN-F4), from the cache alone: counts
/// are worked out of `messages` and `read_marks`, never kept — a repeat,
/// a catch-up or a snapshot can neither count twice nor lose a message.
enum ChatUnread {
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
                AND (has_fixed = 0 OR author_account_id != ?)
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
        }
        let filter = root == nil ? "seq <= ?" : "object_id IN (SELECT message_id FROM messages WHERE thread_root_id = ? OR message_id = ?)"
        let args: StatementArguments = root.map { [channel, $0, $0] } ?? [channel, seq]
        let ids = try String.fetchAll(db, sql: "SELECT object_id FROM notified WHERE channel_id = ? AND read = 0 AND \(filter)", arguments: args)
        try db.execute(sql: "UPDATE notified SET read = 1 WHERE channel_id = ? AND read = 0 AND \(filter)", arguments: args)
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
        let me = try String.fetchOne(db, sql: "SELECT me FROM meta WHERE id = 1") ?? ""
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM messages m
                JOIN channels c ON c.channel_id = m.channel_id
                JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
                LEFT JOIN read_marks r ON r.channel_id = m.channel_id
                LEFT JOIN notified n ON n.object_id = m.message_id
            WHERE m.has_fixed = 1 AND m.deleted_at IS NULL AND m.author_account_id != ?
                AND m.mentions LIKE '%"' || ? || '"%' AND m.seq > IFNULL(r.last_read_seq, 0) AND IFNULL(n.read, 0) = 0
            """, arguments: [me, me]) ?? 0
    }

    /// Whether a message owes a notice, and of which kind — one per message
    /// (a mention above a reply, review F4-4); its marker is set here, in the
    /// transaction that decides. Nil: none owed (mine, already told, not for
    /// me, a reply in a muted channel).
    static func owe(_ db: Database, messageId: String, me: String) throws -> String? {
        guard let m = try Row.fetchOne(db, sql: """
                SELECT channel_id, thread_root_id, author_account_id, mentions, seq, has_fixed, has_mutable, deleted_at
                FROM messages WHERE message_id = ?
                """, arguments: [messageId]),
              m["has_fixed"] as Bool, m["has_mutable"] as Bool, (m["deleted_at"] as String?) == nil,
              (m["author_account_id"] as String?) != me else { return nil }
        let channel: String = m["channel_id"]
        let mentions = (try? JSONDecoder().decode([String].self, from: Data(((m["mentions"] as String?) ?? "[]").utf8))) ?? []
        var kind: String?
        if mentions.contains(me) {
            kind = "mention"
        } else if let root = m["thread_root_id"] as String?,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM my_threads WHERE channel_id = ? AND root_id = ?)", arguments: [channel, root]) == true,
                  try Bool.fetchOne(db, sql: "SELECT muted FROM read_marks WHERE channel_id = ?", arguments: [channel]) != true {
            kind = "reply"
        }
        guard let kind else { return nil }
        // Read already (its place under the mark — a placeholder read in an open
        // feed): marked, read, no notice (review F4b-4).
        let mark = try Int.fetchOne(db, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", arguments: [channel]) ?? -1
        let read = (m["seq"] as Int?).map { $0 <= mark } ?? false
        try db.execute(sql: "INSERT OR IGNORE INTO notified (object_id, kind, channel_id, seq, read) VALUES (?, ?, ?, ?, ?)",
                       arguments: [messageId, kind, channel, m["seq"] as Int?, read])
        return db.changesCount > 0 && !read ? kind : nil
    }
}
