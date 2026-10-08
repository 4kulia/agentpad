import Foundation
import GRDB

/// A bounded read of roots and replies together. The API paginates backwards,
/// so stop at the older of the channel mark and the baseline for unseen threads.
enum ChatInboxLoading {
    static let pagesPerChannel = 5
    static let pagesPerPass = 20

    struct Key: Hashable, Sendable {
        var channel: String
        var epoch, head, channelRead, threadRead: Int
        /// Event-only uncertainty is meaningful only outside a live subscription.
        var unfollowedOnly = false
        var after: Int { min(channelRead, threadRead) }
        var history: HistoryKey { HistoryKey(channel: channel, epoch: epoch, channelRead: channelRead, threadRead: threadRead) }
    }

    struct HistoryKey: Hashable {
        var channel: String
        var epoch, channelRead, threadRead: Int
    }

    struct Progress {
        var after, through: Int
        var before: Int?
        var complete = false
        var pages = 0
    }

    struct Snapshot: Equatable, Sendable {
        var entries: [ChatInbox.Entry]
        var targets: [Key]
    }

    static func snapshot(_ db: Database, ref: ChatInboxRef, session: String?) throws -> Snapshot {
        let entries = try ChatInbox.read(db, kind: ref.kind, account: ref.account, session: session)
        guard try ChatInbox.allowed(db, account: ref.account, session: session) else {
            return Snapshot(entries: [], targets: [])
        }
        let replies = try ChatUnread.unreadRepliesByChannel(db)
        let mentions = try ChatUnread.unreadMentionsByChannel(db)
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.channel_id, IFNULL(w.epoch, 0) AS epoch, IFNULL(h.seq, 0) AS head,
                MAX(IFNULL(r.last_read_seq, 0), 0) AS channel_read,
                MAX(IFNULL(r.thread_read_seq, 0), 0) AS thread_read
            FROM channels c JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
            LEFT JOIN read_marks r ON r.channel_id = c.channel_id
            LEFT JOIN channel_windows w ON w.channel_id = c.channel_id
            LEFT JOIN cursors h ON h.stream = 'channel:' || c.channel_id
            ORDER BY c.channel_id
            """)
        let targets = try rows.compactMap { row -> Key? in
            let channel: String = row["channel_id"]
            let count = try ChatUnread.count(db, channel: channel, me: ref.account)
            // A missing page may contain mentions too; an absent mention badge
            // is not proof that unread history has no mentions.
            guard count.count + replies[channel, default: 0] > 0 || mentions[channel, default: 0] > 0
                    || count.more || count.something else { return nil }
            return Key(channel: channel, epoch: row["epoch"], head: row["head"],
                       channelRead: row["channel_read"], threadRead: row["thread_read"],
                       unfollowedOnly: count.count + replies[channel, default: 0] == 0
                           && mentions[channel, default: 0] == 0 && !count.more)
        }
        return Snapshot(entries: entries, targets: targets)
    }

    static func allowed(_ db: Database, target: Key, account: String, session: String?) throws -> Bool {
        try ChatInbox.allowed(db, account: account, session: session)
            && ChatMessages.current(db, target.channel, epoch: target.epoch)
            && Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channels c JOIN teams t ON t.team_id = c.team_id AND t.mine = 1
                    WHERE c.channel_id = ?)
                """, arguments: [target.channel]) == true
    }
}
