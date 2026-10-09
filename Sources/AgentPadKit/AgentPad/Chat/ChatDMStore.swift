import Foundation
import GRDB

/// Separate tables and composite message keys keep all channel/agent readers out.
/// Only the presentation value ChatMessage is shared with F3.
enum ChatDMStore {
    static let events: Set<String> = ["dm.created", "dm.closed", "dm.reopened", "dm.message.post", "dm.message.edit", "dm.message.delete"]
    static let commands: Set<String> = ["dm.open", "dm.message.post", "dm.message.edit", "dm.message.delete"]
    static let privateTables = ["dm_cards", "dm_states", "dm_messages", "dm_revisions", "dm_pending", "dm_marks", "dm_drafts", "dm_edits", "dm_changes", "dm_notified", "dm_preferences", "dm_open_results", "dm_sends"]

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dm_meta (id INTEGER PRIMARY KEY CHECK (id = 1), stamp INTEGER NOT NULL DEFAULT 0, epoch INTEGER NOT NULL DEFAULT 0, ready BOOLEAN NOT NULL DEFAULT 0);
            INSERT INTO dm_meta (id) VALUES (1);
            CREATE TABLE dm_cards (dm_id TEXT PRIMARY KEY, body BLOB NOT NULL, version INTEGER NOT NULL, stamp INTEGER NOT NULL,
                head INTEGER NOT NULL DEFAULT 0, history_next INTEGER, epoch INTEGER NOT NULL DEFAULT 0, last_activity TEXT NOT NULL);
            CREATE TABLE dm_states (dm_id TEXT PRIMARY KEY, version INTEGER NOT NULL, state TEXT, closed_at TEXT);
            CREATE TABLE dm_messages (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, body BLOB NOT NULL, seq INTEGER NOT NULL,
                root TEXT, revision INTEGER NOT NULL, deleted BOOLEAN NOT NULL, stale INTEGER, local_state TEXT, local_error TEXT, command_id TEXT,
                PRIMARY KEY (dm_id, message_id));
            CREATE INDEX dm_message_order ON dm_messages (dm_id, seq);
            CREATE TABLE dm_revisions (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, revision INTEGER NOT NULL, deleted BOOLEAN NOT NULL DEFAULT 0,
                PRIMARY KEY (dm_id, message_id));
            CREATE TABLE dm_pending (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, seq INTEGER NOT NULL, revision INTEGER NOT NULL,
                PRIMARY KEY (dm_id, message_id));
            CREATE TABLE dm_marks (dm_id TEXT NOT NULL, root TEXT NOT NULL DEFAULT '', seq INTEGER NOT NULL, PRIMARY KEY (dm_id, root));
            CREATE TABLE dm_preferences (dm_id TEXT PRIMARY KEY, muted BOOLEAN NOT NULL DEFAULT 0, opened TEXT);
            CREATE TABLE dm_drafts (dm_id TEXT NOT NULL, root TEXT NOT NULL DEFAULT '', text TEXT NOT NULL, version TEXT NOT NULL, PRIMARY KEY (dm_id, root));
            CREATE TABLE dm_edits (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY (dm_id, message_id));
            CREATE TABLE dm_changes (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, kind TEXT NOT NULL, text TEXT, command_id TEXT NOT NULL,
                state TEXT NOT NULL, error TEXT, PRIMARY KEY (dm_id, message_id));
            CREATE TABLE dm_open_results (command_id TEXT PRIMARY KEY, dm_id TEXT NOT NULL);
            CREATE TABLE dm_sends (draft_version TEXT PRIMARY KEY, dm_id TEXT NOT NULL, message_id TEXT NOT NULL);
            CREATE TABLE dm_notified (dm_id TEXT NOT NULL, message_id TEXT NOT NULL, seq INTEGER NOT NULL, root TEXT, read BOOLEAN NOT NULL DEFAULT 0,
                delivered BOOLEAN NOT NULL DEFAULT 0, PRIMARY KEY (dm_id, message_id));
            """)
    }
    static func stamp(_ db: Database) throws -> Int { try Int.fetchOne(db, sql: "SELECT stamp FROM dm_meta") ?? 0 }
    static func advance(_ db: Database) throws -> Int {
        try db.execute(sql: "UPDATE dm_meta SET stamp = stamp + 1"); return try stamp(db)
    }
    static func invalidate(_ db: Database) throws { try db.execute(sql: "UPDATE dm_meta SET ready = 0, epoch = epoch + 1") }
    static func clear(_ db: Database) throws {
        for table in privateTables { try db.execute(sql: "DELETE FROM \(table)") }
        try db.execute(sql: "DELETE FROM cursors WHERE stream LIKE 'dm:%'")
        try invalidate(db)
    }
    static func remove(_ db: Database, _ id: String) throws {
        for table in privateTables { try db.execute(sql: "DELETE FROM \(table) WHERE dm_id = ?", arguments: [id]) }
        try db.execute(sql: "DELETE FROM cursors WHERE stream = ?", arguments: ["dm:\(id)"])
    }
    static func card(_ db: Database, _ id: String) throws -> ChatDMCard? {
        guard let data = try Data.fetchOne(db, sql: "SELECT body FROM dm_cards WHERE dm_id = ?", arguments: [id]) else { return nil }
        var card = try JSONDecoder().decode(ChatDMCard.self, from: data)
        if let member = try Row.fetchOne(db, sql: "SELECT name, handle FROM members WHERE account_id = ?", arguments: [card.peer.accountId]) {
            card.peer.name = member["name"]; card.peer.handle = member["handle"]
        }
        return card
    }
    static func cards(_ db: Database) throws -> [ChatDMCard] {
        try String.fetchAll(db, sql: "SELECT dm_id FROM dm_cards ORDER BY last_activity DESC, dm_id").compactMap { try card(db, $0) }
    }
    static func windowEpoch(_ db: Database, _ id: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT epoch FROM dm_cards WHERE dm_id = ?", arguments: [id])
    }

    /// Versions fence state; heads fence windows. New windows discard the old
    /// interval, keeping revision/tombstone guards but never an unknown gap.
    static func writeCard(_ db: Database, _ incoming: ChatDMCard, window: Bool = true) throws {
        let old = try card(db, incoming.dmId)
        var card = incoming
        if let state = try Row.fetchOne(db, sql: "SELECT * FROM dm_states WHERE dm_id = ?", arguments: [card.dmId]),
           (state["version"] as Int) > card.version {
            guard let known: String = state["state"] else { return }
            card.version = state["version"]; card.state = known; card.closedAt = state["closed_at"]; card.peer.active = known == "active"
        }
        if let old, old.version > card.version { card = old }
        card.head = nil; card.messages = nil; card.messagesBefore = nil
        let stamp = try advance(db)
        try db.execute(sql: """
            INSERT INTO dm_cards (dm_id, body, version, stamp, last_activity) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(dm_id) DO UPDATE SET body = excluded.body, version = excluded.version, stamp = excluded.stamp
            """, arguments: [card.dmId, try JSONEncoder().encode(card), card.version, stamp, card.createdAt])
        guard window, let head = incoming.head else { return }
        let keptHead = try Int.fetchOne(db, sql: "SELECT head FROM dm_cards WHERE dm_id = ?", arguments: [card.dmId]) ?? 0
        let cursor = try Int.fetchOne(db, sql: "SELECT seq FROM cursors WHERE stream = ?", arguments: ["dm:\(card.dmId)"]) ?? 0
        guard head >= max(keptHead, cursor) else { return }
        try db.execute(sql: "DELETE FROM dm_messages WHERE dm_id = ? AND local_state IS NULL", arguments: [card.dmId])
        try db.execute(sql: "UPDATE dm_cards SET head = ?, history_next = ?, epoch = epoch + 1 WHERE dm_id = ?",
                       arguments: [head, incoming.messagesBefore, card.dmId])
        try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES (?, ?) ON CONFLICT(stream) DO UPDATE SET seq = MAX(seq, excluded.seq)", arguments: ["dm:\(card.dmId)", head])
        try db.execute(sql: "INSERT OR IGNORE INTO dm_marks (dm_id, root, seq) VALUES (?, '', ?), (?, '*', ?)", arguments: [card.dmId, head, card.dmId, head])
        for message in incoming.messages ?? [] where message.dmId == card.dmId { try write(db, message) }
    }
    static func endRead(_ db: Database, since stamp: Int, seen: Set<String>) throws {
        for id in try String.fetchAll(db, sql: "SELECT dm_id FROM dm_cards WHERE stamp <= ?", arguments: [stamp]) where !seen.contains(id) { try remove(db, id) }
        try db.execute(sql: "UPDATE dm_meta SET ready = 1")
    }
    static func liveBaseline(_ db: Database, _ id: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO dm_marks (dm_id, root, seq) VALUES (?, '', 0), (?, '*', 0)", arguments: [id, id])
    }

    static func write(_ db: Database, _ incoming: ChatDMMessageWire) throws {
        guard try card(db, incoming.dmId) != nil else { return }
        let guardRow = try Row.fetchOne(db, sql: "SELECT revision, deleted FROM dm_revisions WHERE dm_id = ? AND message_id = ?", arguments: [incoming.dmId, incoming.messageId])
        if let guardRow, (guardRow["revision"] as Int) > incoming.revision || ((guardRow["deleted"] as Bool) && incoming.deletedAt == nil) { return }
        var m = incoming
        if m.deletedAt != nil { m.text = ""; m.mentions = [] }
        try db.execute(sql: """
            INSERT INTO dm_revisions (dm_id, message_id, revision, deleted) VALUES (?, ?, ?, ?)
            ON CONFLICT(dm_id, message_id) DO UPDATE SET revision = MAX(revision, excluded.revision), deleted = MAX(deleted, excluded.deleted)
            """, arguments: [m.dmId, m.messageId, m.revision, m.deletedAt != nil])
        try db.execute(sql: """
            INSERT INTO dm_messages (dm_id, message_id, body, seq, root, revision, deleted) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dm_id, message_id) DO UPDATE SET body = excluded.body, seq = excluded.seq, root = excluded.root,
                revision = excluded.revision, deleted = excluded.deleted, stale = NULL, local_state = NULL, local_error = NULL
            """, arguments: [m.dmId, m.messageId, try JSONEncoder().encode(m), m.seq, m.threadRootId, m.revision, m.deletedAt != nil])
        try db.execute(sql: "DELETE FROM dm_pending WHERE dm_id = ? AND message_id = ? AND revision <= ?", arguments: [m.dmId, m.messageId, m.revision])
        try db.execute(sql: "UPDATE dm_cards SET last_activity = MAX(last_activity, ?) WHERE dm_id = ?", arguments: [m.createdAt, m.dmId])
        if m.deletedAt != nil {
            try db.execute(sql: "DELETE FROM dm_edits WHERE dm_id = ? AND message_id = ?", arguments: [m.dmId, m.messageId])
            try db.execute(sql: "DELETE FROM dm_changes WHERE dm_id = ? AND message_id = ?", arguments: [m.dmId, m.messageId])
            try db.execute(sql: "UPDATE dm_notified SET read = 1 WHERE dm_id = ? AND message_id = ?", arguments: [m.dmId, m.messageId])
        }
    }

    static func apply(_ db: Database, _ event: ChatEvent) throws -> Bool {
        guard let id = event.body["dm_id"]?.string else { return false }
        if let version = event.body["version"]?.int {
            try db.execute(sql: "INSERT INTO dm_states (dm_id, version, state, closed_at) VALUES (?, ?, ?, ?) ON CONFLICT(dm_id) DO UPDATE SET version = excluded.version, state = excluded.state, closed_at = excluded.closed_at WHERE excluded.version > version",
                           arguments: [id, version, event.body["state"]?.string, event.body["closed_at"]?.string])
        }
        if ["dm.closed", "dm.reopened"].contains(event.type), var card = try card(db, id),
           let version = event.body["version"]?.int, version > card.version {
            card.version = version; card.state = event.type == "dm.closed" ? "read_only" : "active"
            card.closedAt = event.body["closed_at"]?.string; card.peer.active = event.type == "dm.reopened"
            try writeCard(db, card, window: false)
        }
        guard event.type.hasPrefix("dm.message."), let message = event.body["message_id"]?.string,
              let seq = event.body["message_seq"]?.int, let revision = event.body["revision"]?.int else { return true }
        try db.execute(sql: "INSERT INTO dm_revisions (dm_id, message_id, revision, deleted) VALUES (?, ?, ?, ?) ON CONFLICT(dm_id, message_id) DO UPDATE SET revision = MAX(revision, excluded.revision), deleted = MAX(deleted, excluded.deleted)",
                       arguments: [id, message, revision, event.type == "dm.message.delete"])
        if event.type == "dm.message.delete" {
            try db.execute(sql: "DELETE FROM dm_edits WHERE dm_id = ? AND message_id = ?", arguments: [id, message])
            try db.execute(sql: "DELETE FROM dm_changes WHERE dm_id = ? AND message_id = ?", arguments: [id, message])
            try db.execute(sql: "UPDATE dm_notified SET read = 1 WHERE dm_id = ? AND message_id = ?", arguments: [id, message])
        }
        if let value = event.message, event.stream == "dm:\(id)",
           let m = try? JSONDecoder().decode(ChatDMMessageWire.self, from: JSONEncoder().encode(value)),
           m.dmId == id, m.messageId == message, m.revision >= revision {
            try write(db, m)
        } else {
            let row = try Row.fetchOne(db, sql: "SELECT revision, local_state FROM dm_messages WHERE dm_id = ? AND message_id = ?", arguments: [id, message])
            if row == nil || (row?["revision"] as Int? ?? 0) < revision || (row?["local_state"] as String?) != nil {
                try db.execute(sql: """
                    INSERT INTO dm_pending (dm_id, message_id, seq, revision) VALUES (?, ?, ?, ?)
                    ON CONFLICT(dm_id, message_id) DO UPDATE SET revision = MAX(revision, excluded.revision)
                    """, arguments: [id, message, seq, revision])
                try db.execute(sql: "UPDATE dm_messages SET stale = MAX(IFNULL(stale, 0), ?) WHERE dm_id = ? AND message_id = ?", arguments: [revision, id, message])
                if event.type == "dm.message.delete" {
                    // Clear deleted text before any async hydration, including edit drafts.
                    if let data = try Data.fetchOne(db, sql: "SELECT body FROM dm_messages WHERE dm_id = ? AND message_id = ?", arguments: [id, message]) {
                        var m = try JSONDecoder().decode(ChatDMMessageWire.self, from: data)
                        m.revision = revision; m.deletedAt = event.at; m.text = ""; m.mentions = []
                        try write(db, m)
                    }
                }
            }
        }
        let stamp = try advance(db)
        try db.execute(sql: "UPDATE dm_cards SET stamp = ? WHERE dm_id = ?", arguments: [stamp, id])
        return true
    }

    static func messages(_ db: Database, _ id: String) throws -> [ChatMessage] {
        try Row.fetchAll(db, sql: """
            SELECT m.*, c.kind AS edit_kind, c.text AS edit_text, c.error AS edit_error,
                CASE WHEN c.state = 'saving' AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.command_id = c.command_id AND o.state = 'pending')
                    THEN 'failed' ELSE c.state END AS edit_state,
                o.state AS command_state, o.error AS command_error
            FROM dm_messages m LEFT JOIN dm_changes c ON c.dm_id = m.dm_id AND c.message_id = m.message_id
                LEFT JOIN outbox o ON o.command_id = m.command_id
            WHERE m.dm_id = ? ORDER BY CASE WHEN m.seq = 0 THEN 1 ELSE 0 END, m.seq, m.message_id
            """, arguments: [id]).map { row in
                var m = ChatMessage(dm: try JSONDecoder().decode(ChatDMMessageWire.self, from: row["body"]))
                m.stale = row["stale"]; m.localState = (row["local_state"] as String?).flatMap(ChatMessage.LocalState.init)
                m.localError = row["local_error"]
                if m.localState != nil, let state: String = row["command_state"], ["failed", "dropped", "unconfirmed"].contains(state) {
                    m.localState = .failed; m.localError = row["command_error"] ?? state
                }
                if let kind: String = row["edit_kind"] {
                    m.localEdit = .init(kind: kind, text: row["edit_text"], state: row["edit_state"] ?? "failed", error: row["edit_error"])
                }
                if m.stale != nil { m.text = ""; m.mentions = [] }
                return m
            }
    }
    static func mark(_ db: Database, _ id: String, root: String? = nil) throws -> Int {
        let own = try Int.fetchOne(db, sql: "SELECT seq FROM dm_marks WHERE dm_id = ? AND root = ?", arguments: [id, root ?? ""]) ?? 0
        let baseline = root == nil ? 0 : try Int.fetchOne(db, sql: "SELECT seq FROM dm_marks WHERE dm_id = ? AND root = '*'", arguments: [id]) ?? 0
        return max(own, baseline)
    }
    static func markRead(_ db: Database, _ id: String, root: String? = nil, through seq: Int) throws {
        try db.execute(sql: "INSERT INTO dm_marks (dm_id, root, seq) VALUES (?, ?, ?) ON CONFLICT(dm_id, root) DO UPDATE SET seq = MAX(seq, excluded.seq)", arguments: [id, root ?? "", seq])
        try db.execute(sql: "UPDATE dm_notified SET read = 1 WHERE dm_id = ? AND root IS ? AND seq <= ?", arguments: [id, root, seq])
    }
    static func draft(_ db: Database, _ id: String, root: String?) throws -> (text: String, version: String)? {
        try Row.fetchOne(db, sql: "SELECT text, version FROM dm_drafts WHERE dm_id = ? AND root = ?", arguments: [id, root ?? ""]).map { ($0["text"], $0["version"]) }
    }
    @discardableResult static func saveDraft(_ db: Database, _ id: String, root: String?, text: String) throws -> String {
        if let old = try draft(db, id, root: root), old.text == text { return old.version }
        let version = UUID().uuidString
        try db.execute(sql: "INSERT INTO dm_drafts (dm_id, root, text, version) VALUES (?, ?, ?, ?) ON CONFLICT(dm_id, root) DO UPDATE SET text = excluded.text, version = excluded.version",
                       arguments: [id, root ?? "", text, version])
        return version
    }
}

extension ChatStore {
    // Explicit synchronous transactions: every gate check and application stays
    // on the caller's actor with no suspension between them.
    func dmRead<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func dmWrite<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }
}
