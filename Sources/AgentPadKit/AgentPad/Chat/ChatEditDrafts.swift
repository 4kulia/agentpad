import Foundation
import GRDB

/// User-authored work, independent of message/channel cache eviction and generation.
/// Access loss is decided from team membership, never absence from a rolling window.
enum ChatEditDrafts {
    @discardableResult
    static func save(_ db: Database, draft: ChatChannelModel.Editing, channel: String) throws -> ChatChannelModel.Editing? {
        let current = try Row.fetchOne(db, sql: "SELECT data, version FROM edit_drafts WHERE message_id = ?", arguments: [draft.messageId]).map(decode)
        // Opening another editor joins the same work. A later keystroke can
        // start new work after cancellation, but never after a tombstone.
        if draft.version == nil, let current { return current }
        guard try String.fetchOne(db, sql: "SELECT deleted_at FROM messages WHERE message_id = ?", arguments: [draft.messageId]) == nil else { return nil }
        if let current, current.text == draft.text { return current }
        let team = try String.fetchOne(db, sql: "SELECT team_id FROM channels WHERE channel_id = ?", arguments: [channel])
            ?? String.fetchOne(db, sql: "SELECT team_id FROM edit_drafts WHERE message_id = ?", arguments: [draft.messageId])
        guard let team else { return nil }
        var saved = current ?? draft
        saved.text = draft.text
        saved.version = UUID().uuidString
        let data = try JSONEncoder().encode(saved)
        try db.execute(sql: """
            INSERT INTO edit_drafts (message_id, channel_id, team_id, data, updated_at, version) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at, version = excluded.version
            """, arguments: [draft.messageId, channel, team, data, Date().timeIntervalSince1970, saved.version])
        return saved
    }
    private static func decode(_ row: Row) throws -> ChatChannelModel.Editing {
        var draft = try JSONDecoder().decode(ChatChannelModel.Editing.self, from: row["data"])
        draft.version = row["version"]
        return draft
    }
    static func read(_ db: Database, channel: String) throws -> [ChatChannelModel.Editing] {
        try Row.fetchAll(db, sql: "SELECT data, version FROM edit_drafts WHERE channel_id = ? ORDER BY updated_at", arguments: [channel]).map(decode)
    }
    static func remove(_ db: Database, message: String, version: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM edit_drafts WHERE message_id = ? AND version = ?", arguments: [message, version])
        return db.changesCount > 0
    }
    static func removeRevoked(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM edit_drafts WHERE team_id NOT IN (SELECT team_id FROM teams WHERE mine = 1)")
    }
}
