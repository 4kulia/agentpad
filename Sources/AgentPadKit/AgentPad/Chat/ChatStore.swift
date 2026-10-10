import Foundation
import GRDB

enum ChatStoreError: Error, Equatable, LocalizedError {
    /// Written by a newer AgentPad: not opened, not changed.
    case tooNew
    /// Not a database, or a damaged one.
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .tooNew: "This data was written by a newer AgentPad. Update AgentPad to open it."
        case .corrupt(let detail): "The local data is damaged: \(detail)"
        }
    }
}

/// Opening the cache and the journal: migrate a known file, refuse a newer one.
enum ChatDatabase {
    static func open(_ url: URL, migrator: DatabaseMigrator) throws -> DatabaseQueue {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                // Looked at read-only first: a newer file must not change. A
                // transaction a crash left unfinished (a `-journal` or `-wal`
                // beside it) needs a writable connection to be rolled back
                // first: SQLite's own recovery, which changes nothing that was
                // committed (review C11-5).
                let (development, superseded) = try schemaOf(url, migrator: migrator)
                if development {
                    // A development build's file (review C10-3): kept aside, made anew.
                    try setAside(url, suffix: ".dev-backup")
                } else if superseded {
                    throw ChatStoreError.tooNew
                }
            }
            let queue = try DatabaseQueue(path: url.path)
            try migrator.migrate(queue)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return queue
        } catch let error as DatabaseError
            where [.SQLITE_NOTADB, .SQLITE_CORRUPT].contains(error.resultCode) {
            throw ChatStoreError.corrupt(error.message ?? "\(error.resultCode)")
        }
    }

    /// What `url` holds, read without changing it: whether a development
    /// build wrote it, and whether a newer AgentPad did. A transaction a crash
    /// left unfinished (a `-journal` or `-wal` beside it) must be rolled back
    /// before reading, which writes: it is read from a copy, and the file
    /// itself is opened for writing only once its schema is known (review
    /// C11-5, C12-4).
    private static func schemaOf(_ url: URL, migrator: DatabaseMigrator) throws -> (development: Bool, superseded: Bool) {
        let sidecars = ["-journal", "-wal", "-shm"].filter { FileManager.default.fileExists(atPath: url.path + $0) }
        var source = url
        var scratch: URL?
        if !sidecars.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-schema-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scratch = dir
            source = dir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: source)
            for suffix in sidecars { try FileManager.default.copyItem(atPath: url.path + suffix, toPath: source.path + suffix) }
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        var configuration = Configuration()
        configuration.readonly = scratch == nil
        let peek = try DatabaseQueue(path: source.path, configuration: configuration)
        defer { try? peek.close() }
        return try peek.read { db in
            let applied = try db.tableExists("grdb_migrations")
                ? try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") : []
            return (applied.contains { !$0.hasPrefix(ChatStoreMigrations.releasePrefix) }, try migrator.hasBeenSuperseded(db))
        }
    }

    /// The damaged file is kept beside as `<name>.corrupt`.
    static func setAside(_ url: URL, suffix: String = ".corrupt") throws {
        let aside = URL(fileURLWithPath: url.path + suffix)
        try? FileManager.default.removeItem(at: aside)
        try FileManager.default.moveItem(at: url, to: aside)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}

/// One command in a send queue (`outbox` of the cache, `run_commands` of the
/// journal): created once, sent and repeated as the same bytes.
struct ChatCommandRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    enum State: String, Codable, Sendable {
        case pending
        case sent
        case failed
        /// Its session ended and it has no business key to carry it over (6.4).
        case dropped
        /// Unsent when the server's generation changed: sent again only by hand.
        case unconfirmed
    }

    var commandId: String
    var sessionId: String
    var type: String
    var bodyBytes: Data
    var orderKey: String
    var dependsOn: String?
    var createdAt: Date
    var state: State
    var error: String?
    var attempts = 0
    var nextAttemptAt: Date?
    /// Place in the queue, given when stored; increases strictly, unlike
    /// times or ids (review C-7).
    var seq: Int64 = 0
    /// The server generation that accepted it.
    var sentGeneration: String?

    static let databaseTableName = "outbox"

    enum CodingKeys: String, CodingKey {
        case commandId = "command_id", sessionId = "session_id", type, bodyBytes = "body_bytes"
        case orderKey = "order_key", dependsOn = "depends_on", createdAt = "created_at", state, error
        case attempts, nextAttemptAt = "next_attempt_at", seq, sentGeneration = "sent_generation"
    }
}

/// One send queue's table (`outbox` of a cache, `run_commands` of the
/// journal for one organization). Every change that decides a command's
/// fate is one transaction and, where it races with a send, conditional on
/// the state it was decided from.
final class ChatCommandTable: Sendable {
    let queue: DatabaseQueue
    let table: String
    /// The journal's rows carry their (server, account, organization).
    let scope: ChatOrgKey?

    init(queue: DatabaseQueue, table: String, scope: ChatOrgKey? = nil) {
        self.queue = queue
        self.table = table
        self.scope = scope
    }

    private var scopeSQL: String { scope == nil ? "1" : "server = ? AND account_id = ? AND org_id = ?" }
    private var scopeArgs: StatementArguments {
        guard let scope else { return [] }
        return [scope.server.description, scope.accountId, scope.orgId]
    }

    /// Stores a new command at the end of the queue; returns it with its place.
    /// `seq`: the place given by the queue's common counter; nil takes
    /// this table's next (callers outside a queue).
    @discardableResult
    func enqueue(_ record: ChatCommandRecord, seq: Int64? = nil, resultText: String? = nil) throws -> ChatCommandRecord {
        try queue.write { db in try insert(db, record, resultText: resultText, seq: seq) }
    }

    /// Refused commands the user has not dismissed.
    func refusedShown() throws -> [ChatCommandRecord] {
        try queue.read { db in
            try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM \(table) WHERE state = 'failed' AND dismissed = 0 AND error IS NOT 'dismissed' AND \(scopeSQL) ORDER BY seq, rowid
                """, arguments: scopeArgs)
        }
    }

    /// The user has seen these refusals (all, when nil). Only the mark:
    /// the refusal's code — and what a handler owes by it — stays.
    func dismiss(_ commandIds: Set<String>?) throws {
        try queue.write { db in
            let rows = try String.fetchAll(db, sql: "SELECT command_id FROM \(table) WHERE state = 'failed' AND dismissed = 0 AND \(scopeSQL)",
                                           arguments: scopeArgs)
            for id in rows where commandIds?.contains(id) ?? true {
                try db.execute(sql: "UPDATE \(table) SET dismissed = 1 WHERE command_id = ? AND \(scopeSQL)", arguments: [id] + scopeArgs)
            }
        }
    }

    /// Stores `record` after the `request.create` of `requestId` while that
    /// one is on its way, read in the same transaction — the command now
    /// there, whatever a new session made of the earlier one (review D4b2-p1-5).
    func enqueue(_ record: ChatCommandRecord, afterCreateOf requestId: String, seq: Int64) throws -> ChatCommandRecord {
        try queue.write { db in
            let creates = try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM \(table) WHERE type = 'request.create' AND state IN ('pending', 'unconfirmed') AND \(scopeSQL) ORDER BY seq
                """, arguments: scopeArgs)
            let own = creates.last {
                (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.bodyBytes))?.args["request_id"]?.string == requestId
            }
            var record = record
            record.dependsOn = own?.commandId
            return try insert(db, record, seq: seq)
        }
    }

    func contains(_ commandId: String) throws -> Bool {
        try queue.read { db in
            // Within this queue's (server, account, organization) only (review C3-7).
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE command_id = ? AND \(scopeSQL))",
                              arguments: [commandId] + scopeArgs) ?? false
        }
    }

    /// The highest place in any of `tables`.
    static func maxSeq(_ tables: [ChatCommandTable]) throws -> Int64 {
        try tables.map { table in
            try table.queue.read { db in try Int64.fetchOne(db, sql: "SELECT max(seq) FROM \(table.table)") ?? 0 }
        }.max() ?? 0
    }

    func insert(_ db: Database, _ record: ChatCommandRecord, resultText: String? = nil, seq given: Int64? = nil) throws -> ChatCommandRecord {
        var record = record
        record.seq = try given ?? ((Int64.fetchOne(db, sql: "SELECT max(seq) FROM \(table)") ?? 0) + 1)
        var columns = ["command_id", "session_id", "type", "body_bytes", "order_key", "depends_on", "created_at", "state", "error",
                       "attempts", "next_attempt_at", "seq", "sent_generation"]
        var values: [(any DatabaseValueConvertible)?] = [
            record.commandId, record.sessionId, record.type, record.bodyBytes, record.orderKey, record.dependsOn, record.createdAt,
            record.state.rawValue, record.error, record.attempts, record.nextAttemptAt, record.seq, record.sentGeneration,
        ]
        if let scope {
            columns += ["server", "account_id", "org_id", "result_text"]
            values += [scope.server.description, scope.accountId, scope.orgId, resultText]
        }
        try db.execute(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(values)
        )
        return record
    }

    func commands() throws -> [ChatCommandRecord] {
        try queue.read { db in
            try ChatCommandRecord.fetchAll(db, sql: "SELECT * FROM \(table) WHERE \(scopeSQL) ORDER BY seq, rowid", arguments: scopeArgs)
        }
    }

    /// Takes the send and records its start in the same transaction as the
    /// intent/access check. A publication with an unknown answer cannot be replaced.
    struct SendStart { var repeatsUnanswered: Bool }
    func beginSending(_ record: ChatCommandRecord) throws -> SendStart? {
        try queue.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM \(table) WHERE command_id = ? AND \(scopeSQL)",
                                      arguments: [record.commandId] + scopeArgs) == "pending" else { return nil }
            if ["request.create_in_channel_v2", "request.create_in_channel_with_attachments"].contains(record.type) {
                guard try Bool.fetchOne(db, sql: "SELECT cancelled FROM channel_call_intents WHERE command_id = ?", arguments: [record.commandId]) == false else { return nil }
                try db.execute(sql: "UPDATE channel_call_intents SET send_started_at = coalesce(send_started_at, CURRENT_TIMESTAMP) WHERE command_id = ?", arguments: [record.commandId])
            }
            guard ChatPublication.isDecision(record.type) else { return SendStart(repeatsUnanswered: false) }
            let current = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM publication_intents WHERE command_id = ?)",
                                            arguments: [record.commandId]) == true
            if !current { try db.execute(sql: "DELETE FROM \(table) WHERE command_id = ?", arguments: [record.commandId]) }
            guard current, let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
                  let request = envelope.args["request_id"]?.string else { return nil }
            // The observation that erases a revoked result may still be
            // queued on the main actor. Sending already obeys the stored gate.
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM requests r JOIN channels c ON c.channel_id = r.channel_id
                    JOIN teams t ON t.team_id = c.team_id JOIN meta m ON m.id = 1
                    WHERE r.request_id = ? AND r.kind = 'channel' AND t.mine = 1
                        AND r.state NOT IN ('cancelled', 'stop_requested', 'stopped', 'stop_failed')
                        AND m.rights_in_doubt = 0 AND m.rights_session = ? AND m.pending_generation IS NULL)
                """, arguments: [request, record.sessionId]) == true else { return nil }
            let repeats = try Bool.fetchOne(db, sql: "SELECT send_started_at IS NOT NULL FROM publication_intents WHERE command_id = ?",
                                           arguments: [record.commandId]) == true
            try db.execute(sql: "UPDATE publication_intents SET send_started_at = coalesce(send_started_at, ?) WHERE command_id = ?",
                           arguments: [Date(), record.commandId])
            return SendStart(repeatsUnanswered: repeats)
        }
    }

    /// Writes `record` only if the stored one is still in `expected`; false otherwise.
    @discardableResult
    func update(_ record: ChatCommandRecord, ifState expected: ChatCommandRecord.State, notAccepted: Bool = false) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE \(table) SET session_id = ?, state = ?, error = ?, attempts = ?, next_attempt_at = ?, depends_on = ?,
                    sent_generation = ?
                WHERE command_id = ? AND state = ?
                """, arguments: [record.sessionId, record.state.rawValue, record.error, record.attempts, record.nextAttemptAt,
                                 record.dependsOn, record.sentGeneration, record.commandId, expected.rawValue])
            let stored = db.changesCount == 1
            if stored, notAccepted, ChatPublication.isDecision(record.type) {
                try db.execute(sql: "UPDATE publication_intents SET send_started_at = NULL WHERE command_id = ?", arguments: [record.commandId])
            }
            return stored
        }
    }

    /// Signed in again (6.4), in one transaction: pending commands of other
    /// sessions with a business key get a new id and bytes under `session`
    /// (same place in the queue), the rest are dropped, and pending commands
    /// that depended on a carried one now depend on its successor.
    func carryOver(to session: String, carried: Set<String>, newId: () -> String,
                   rebuild: (Data, String) -> Data?) throws -> (carried: Int, dropped: [ChatCommandRecord]) {
        try queue.write { db in
            let old = try ChatCommandRecord.fetchAll(
                db, sql: "SELECT * FROM \(table) WHERE \(scopeSQL) AND state = 'pending' AND session_id != ? ORDER BY seq, rowid",
                arguments: scopeArgs + [session]
            )
            var renamed: [String: String] = [:]
            var dropped: [ChatCommandRecord] = []
            for record in old {
                let id = newId()
                if carried.contains(record.type), let bytes = rebuild(record.bodyBytes, id) {
                    try db.execute(sql: "UPDATE \(table) SET state = 'dropped', error = 'carried over to a new session' WHERE command_id = ?",
                                   arguments: [record.commandId])
                    var next = record
                    next.commandId = id
                    next.sessionId = session
                    next.bodyBytes = bytes
                    next.attempts = 0
                    next.nextAttemptAt = nil
                    _ = try insert(db, next, seq: record.seq)
                    renamed[record.commandId] = id
                } else {
                    try db.execute(sql: "UPDATE \(table) SET state = 'dropped', error = 'dropped: its session ended' WHERE command_id = ?",
                                   arguments: [record.commandId])
                    dropped.append(record)
                }
            }
            for (from, to) in renamed {
                try db.execute(sql: "UPDATE \(table) SET depends_on = ? WHERE depends_on = ? AND state = 'pending'", arguments: [to, from])
            }
            return (renamed.count, dropped)
        }
    }

    /// The user sends `records` (unconfirmed) again, in one transaction: each
    /// gets a new id and bytes under `session`, and the originals are dropped
    /// with a note of their successor. Dependencies follow to the successors
    /// (review C4-8, C5-9). The successors take their originals' places in
    /// the order: they, every waiting command after them in the same order
    /// key, and every waiting command depending on any of these (with its own
    /// order key's tail) get new places from `firstSeq` on, in the order they
    /// had — so nothing of one order key overtakes another (review C6-8).
    func resend(_ records: [ChatCommandRecord], session: String, firstSeq: Int64, now: Date, newId: () -> String,
                rebuild: (Data, String) -> Data?) throws -> [ChatCommandRecord] {
        try queue.write { db in
            var renamed: [String: String] = [:]
            var successors: [ChatCommandRecord] = []
            for record in records.sorted(by: { $0.seq < $1.seq }) {
                let id = newId()
                guard let bytes = rebuild(record.bodyBytes, id) else { continue }
                var next = record
                next.commandId = id
                next.sessionId = session
                next.bodyBytes = bytes
                next.createdAt = now
                next.state = .pending
                next.attempts = 0
                next.nextAttemptAt = nil
                next.error = nil
                next.sentGeneration = nil
                renamed[record.commandId] = id
                successors.append(next)
            }
            func orderKey(_ record: ChatCommandRecord) -> String { record.orderKey ?? "#" + record.commandId }
            // From which place on each order key moves.
            var from: [String: Int64] = [:]
            for record in successors { from[orderKey(record)] = min(from[orderKey(record)] ?? .max, record.seq) }
            let waiting = try ChatCommandRecord.fetchAll(
                db, sql: "SELECT * FROM \(table) WHERE \(scopeSQL) AND state = 'pending' ORDER BY seq, rowid", arguments: scopeArgs)
            var moving: [String: ChatCommandRecord] = [:]
            var movingIds = Set(renamed.keys)
            var changed = true
            while changed {
                changed = false
                for record in waiting where moving[record.commandId] == nil {
                    let inTail = from[orderKey(record)].map { record.seq > $0 } ?? false
                    let dependent = record.dependsOn.map(movingIds.contains) ?? false
                    guard inTail || dependent else { continue }
                    moving[record.commandId] = record
                    movingIds.insert(record.commandId)
                    from[orderKey(record)] = min(from[orderKey(record)] ?? .max, record.seq)
                    changed = true
                }
            }
            // One order: by the places they had (a successor at its original's).
            let all = (successors + moving.values).sorted { $0.seq < $1.seq }
            var seq = firstSeq
            var made: [ChatCommandRecord] = []
            for var record in all {
                if let parent = record.dependsOn, let successor = renamed[parent] { record.dependsOn = successor }
                if record.state == .pending, moving[record.commandId] != nil {
                    try db.execute(sql: "UPDATE \(table) SET depends_on = ?, seq = ? WHERE command_id = ?",
                                   arguments: [record.dependsOn, seq, record.commandId])
                } else {
                    made.append(try insert(db, record, seq: seq))
                }
                seq += 1
            }
            for (old, new) in renamed {
                try db.execute(sql: "UPDATE \(table) SET state = 'dropped', error = ? WHERE command_id = ? AND state = 'unconfirmed'",
                               arguments: ["sent again as \(new)", old])
            }
            return made
        }
    }

    /// A new server generation: every pending command waits for the user.
    func markUnconfirmed() throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE \(table) SET state = 'unconfirmed' WHERE \(scopeSQL) AND state = 'pending'", arguments: scopeArgs)
        }
    }
}

/// What a snapshot of an organization replaces (B2): the server's rows of
/// the tables it carries and the cursors of its streams. The wire format is
/// mapped to this by the sync (C8).
struct ChatSnapshot: Equatable, Sendable {
    struct Member: Equatable, Sendable { var accountId, handle, name, role: String }
    struct Team: Equatable, Sendable {
        var teamId, name: String
        var isGeneral = false
        var archivedAt: String?
        /// The signed-in member is in it.
        var mine = true
    }
    struct TeamMember: Equatable, Hashable, Sendable { var teamId, accountId: String }
    struct Invitation: Equatable, Sendable { var invitationId, email, role, state: String; var expiresAt: String? }

    var cursors: [String: Int]
    var orgName: String?
    var members: [Member]?
    var teams: [Team]?
    var teamMembers: [TeamMember]?
    var invitations: [Invitation]?
    /// Stage D: the catalog (each card with the caller's teams of its audience).
    var agents: [ChatAgentCard]? = nil
    /// Stage D: requests of the caller, the newest first; the rest by pages.
    var requests: [ChatRequestWire]? = nil
    /// F2: the cards; nil from a server without channels.
    var channels: [ChatChannelCard]? = nil
    /// No channels page is left to read.
    var channelsComplete = true
    /// F8: the agents of the channels of the user's teams, whole; nil from a server without them.
    var agentChannels: [ChatChannelAgentWire]? = nil
    var threadParticipationReload = false
}

/// The cache of one (server, account, organization): `chat/<hash>.sqlite`
/// (6.11). Events and snapshots are applied with their cursors in one
/// transaction; the send queue lives here too.
final class ChatStore: Sendable {
    enum Applied: Equatable {
        case applied
        /// Its number taken, its effect not (wholly): a type this build does
        /// not know, or a body it could not read. Kept in `skipped_events`;
        /// a snapshot brings the effect (review D8f-p3-1, D8g-p3-3).
        case passedOver
        /// At or below the stream's cursor: seen already.
        case duplicate
        /// Past the next number: events are missing; nothing applied.
        case gap(expected: Int)
    }

    let url: URL
    let queue: DatabaseQueue
    /// The signed-in account the cache is of: what it may hold follows its rights.
    let accountId: String
    let avatarAccess: ChatAvatarAccessEpoch

    private init(url: URL, queue: DatabaseQueue, accountId: String) {
        self.url = url
        self.queue = queue
        self.accountId = accountId
        self.avatarAccess = ChatAvatarAccessEpoch(queue: queue)
        // F4: the cache knows whose it is, for what its triggers keep (`my_threads`).
        try? queue.write { db in
            try db.execute(sql: "UPDATE meta SET me = ? WHERE id = 1 AND IFNULL(me, '') != ?", arguments: [accountId, accountId])
            // Known now for the first time (a cache from before F4): the threads the
            // user wrote in so far, from the messages kept (review F4-C). The
            // migration cannot: whose cache it is, it does not know.
            if db.changesCount > 0 {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO my_threads (channel_id, root_id)
                    SELECT channel_id, IFNULL(thread_root_id, message_id) FROM messages WHERE author_account_id = ? AND (SELECT b1_participation FROM meta WHERE id = 1) = 0
                    """, arguments: [accountId])
            }
        }
    }

    /// Opens or creates the cache. A damaged file is set aside and a new one
    /// made — `recovered` is then true: the queue is lost and a full snapshot
    /// is due. A newer file throws `tooNew`.
    static func open(files: ChatFiles, key: ChatOrgKey) throws -> (store: ChatStore, recovered: Bool) {
        try files.prepareDirectory()
        let url = files.cacheURL(key)
        func opened(_ recovered: Bool) throws -> (ChatStore, Bool) {
            let queue = try ChatDatabase.open(url, migrator: ChatStoreMigrations.cache)
            try queue.write { try $0.execute(sql: "INSERT OR REPLACE INTO attachment_scope (id, body) VALUES (1, ?)", arguments: [try JSONEncoder().encode(ChatDMRef(key, dm: ""))]) }
            return (ChatStore(url: url, queue: queue, accountId: key.accountId), recovered)
        }
        do {
            return try opened(false)
        } catch ChatStoreError.corrupt {
            try ChatDatabase.setAside(url)
            return try opened(true)
        }
    }

    // MARK: Cursors

    func cursor(_ stream: String) throws -> Int {
        try queue.read { db in try Self.cursor(db, stream) }
    }

    func cursors() throws -> [String: Int] {
        try queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT stream, seq FROM cursors").map { ($0["stream"], $0["seq"]) })
        }
    }

    private static func cursor(_ db: Database, _ stream: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT seq FROM cursors WHERE stream = ?", arguments: [stream]) ?? 0
    }

    private static func setCursor(_ db: Database, _ stream: String, _ seq: Int) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO cursors (stream, seq) VALUES (?, ?)", arguments: [stream, seq])
    }

    var generation: String? {
        get throws { try queue.read { db in try String.fetchOne(db, sql: "SELECT generation FROM meta WHERE id = 1") } }
    }

    var orgName: String? {
        get throws { try queue.read { db in try String.fetchOne(db, sql: "SELECT org_name FROM meta WHERE id = 1") } }
    }

    /// Open invitations as the server's snapshot counts them: not accepted,
    /// not revoked, not expired (`expires_at > now`) — the same set whether
    /// it came by snapshot or by events (review C19-1).
    func openInvitations(now: Date = Date()) throws -> [ChatSnapshot.Invitation] {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT invitation_id, email, role, state, expires_at FROM invitations WHERE state = 'open' ORDER BY invitation_id")
        }
        return rows.map { ChatSnapshot.Invitation(invitationId: $0["invitation_id"], email: $0["email"], role: $0["role"],
                                                  state: $0["state"], expiresAt: $0["expires_at"]) }
            .filter { Self.isOpen($0, now: now) }
    }

    /// The one rule of an open invitation, the snapshot's: not expired.
    static func isOpen(_ invitation: ChatSnapshot.Invitation, now: Date) -> Bool {
        guard let text = invitation.expiresAt, let expires = date(text) else { return true }
        return expires > now
    }

    /// An RFC 3339 time, its fraction of seconds of any length — the
    /// server's have six digits, the formatter reads three (review D8h-p3-6).
    static func date(_ text: String) -> Date? {
        date(text, formatter: ISO8601DateFormatter())
    }

    static func date(_ text: String, formatter: ISO8601DateFormatter) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return formatter.date(from: text) }
        let end = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
        guard let fraction = Double("0" + text[dot..<end]) else { return nil }
        return formatter.date(from: String(text[..<dot] + text[end...]))?.addingTimeInterval(fraction)
    }

    /// A new generation whose handling has begun and not finished.
    var pendingGeneration: String? {
        get throws { try queue.read { db in try String.fetchOne(db, sql: "SELECT pending_generation FROM meta WHERE id = 1") } }
    }

    func setPendingGeneration(_ generation: String?) throws {
        try queue.write { db in try db.execute(sql: "UPDATE meta SET pending_generation = ? WHERE id = 1", arguments: [generation]) }
    }

    /// A new server generation begins (a server restored from a backup — an
    /// accident): written as pending, and the organization's server cache
    /// goes with it, in one transaction — it is read anew, as on a first
    /// connection (lead's decision after review D8h). The run journal is the
    /// facts of this Mac: `reconcile` makes from it what the new server is
    /// owed. Kept are the send queue, the local columns of the organization's
    /// own tables (C6) the snapshot replaces, and this Mac's calls (review D8i):
    /// - asked here and over for this side (final; finished with its result):
    ///   as they are, with their result and their notification (shown, or
    ///   still owed) — history, which the new generation's word replaces if
    ///   it has one (a notification of an outcome it undoes is voided);
    /// - asked here and not sent yet (`creating`): as they are;
    /// - asked here and open, or run here without an outcome (`running`, from
    ///   the journal): `resyncing` — no server field of the earlier generation
    ///   but the fixed part, to show them; the new server's fixed part and
    ///   executor are taken anew. After the whole read, one the new server
    ///   does not list is `lost` (`endResync`).
    func beginGeneration(_ generation: String, keeping running: Set<String> = []) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE meta SET pending_generation = ? WHERE id = 1", arguments: [generation])
            let over = ChatCallStore.overSQL(incoming: false)
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS kept_history (request_id TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM kept_history")
            try db.execute(sql: "INSERT INTO kept_history SELECT request_id FROM requests WHERE asked_here AND (\(over))",
                           arguments: ChatCallStore.overArguments)
            try db.execute(sql: """
                DELETE FROM actions WHERE NOT (kind = 'notify_outcome' AND request_id IN (SELECT request_id FROM kept_history))
                """)
            try db.execute(sql: "DELETE FROM results WHERE request_id NOT IN (SELECT request_id FROM kept_history)")
            // The rights are read anew with the new generation: nothing is
            // told as "gone" before its snapshot (F2).
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 1 WHERE id = 1")
            try ChatB1.reset(db)
            try ChatDMStore.clear(db, preservingAttachments: true)
            // A restore must never replay an unsent private message implicitly.
            try db.execute(sql: "UPDATE outbox SET state = 'unconfirmed' WHERE type LIKE 'dm.%' AND state = 'pending'")
            try db.execute(sql: "DELETE FROM my_threads")
            try ChatB1.cancelIntents(db, condition: "1")
            // Messages of the server go; one this Mac is sending stays with its command (F3).
            try db.execute(sql: "DELETE FROM attachment_deleted_sources")
            try db.execute(sql: "DELETE FROM messages WHERE local_state IS NULL")
            // Unsettled edits of the old generation's messages go too (review F3d-1).
            try db.execute(sql: "DELETE FROM local_edits")
            // F4: the old generation's numbers say nothing now — read up to the
            // first window of the new one; notices of messages go (review F4-5).
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = -1")
            try db.execute(sql: "DELETE FROM thread_read_marks")
            try db.execute(sql: "DELETE FROM notified WHERE kind != 'decision'")
            for table in ["agents_catalog", "agent_teams", "threads", "skipped_events", "cursors", "channels", "channel_windows",
                          "thread_cursors"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for id in running {
                try db.execute(sql: "INSERT OR IGNORE INTO requests (request_id, state, version) VALUES (?, ?, 0)",
                               arguments: [id, TeamRequestState.resyncing.rawValue])
            }
            let marks = running.map { _ in "?" }.joined(separator: ", ")
            let ran = running.isEmpty ? "0" : "request_id IN (\(marks))"
            try db.execute(sql: """
                DELETE FROM requests WHERE NOT asked_here AND NOT \(ran)
                """, arguments: StatementArguments(Array(running)))
            try db.execute(sql: "UPDATE requests SET generation = NULL WHERE request_id IN (SELECT request_id FROM kept_history)")
            try db.execute(sql: """
                UPDATE requests SET state = ?, version = 0, run_id = NULL, decline_reason = NULL, failure_reason = NULL,
                    cause = NULL, updated_at = NULL, generation = NULL, has_fixed = 0, on_this_device = 0
                WHERE state != ? AND request_id NOT IN (SELECT request_id FROM kept_history)
                """, arguments: [TeamRequestState.resyncing.rawValue, TeamRequestState.creating.rawValue])
            try db.execute(sql: "DELETE FROM kept_history")
        }
    }

    /// The new generation's whole read is in: a call of this Mac it did not
    /// list is `lost` now, with what it owes (review D8i).
    func endResync(facts: [String: ChatLocalFacts]?) throws {
        try queue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE state = ?",
                                          arguments: [TeamRequestState.resyncing.rawValue])
            try db.execute(sql: "UPDATE requests SET state = ?, updated_at = ? WHERE state = ?",
                           arguments: [TeamRequestState.lost.rawValue, ChatCallStore.timestamp(Date()), TeamRequestState.resyncing.rawValue])
            try ChatReconcile.reconcile(db, ids, facts: facts)
        }
    }

    /// The generation is handled: stored, and nothing pending.
    func finishGeneration(_ generation: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE meta SET generation = ?, pending_generation = NULL WHERE id = 1", arguments: [generation])
        }
    }

    func setGeneration(_ generation: String) throws {
        try queue.write { db in try db.execute(sql: "UPDATE meta SET generation = ? WHERE id = 1", arguments: [generation]) }
    }

    // MARK: Events

    var calls: ChatCallStore { ChatCallStore(queue: queue) }

    /// Applies `event` to the tables and moves its stream's cursor — one
    /// transaction. A request's event writes its state by version and the
    /// actions `reconcile` finds missing, from `facts` (the run journal's,
    /// read before; nil when it is not known) (D8). `also` runs inside it
    /// too. Unknown types change nothing but the cursor.
    @discardableResult
    func apply(_ event: ChatEvent, facts: [String: ChatLocalFacts]? = nil,
               also: ((Database, ChatEvent) throws -> Void)? = nil) throws -> Applied {
        try queue.write { db in
            let at = try Self.cursor(db, event.stream)
            if event.seq <= at { return .duplicate }
            if event.seq != at + 1 { return .gap(expected: at + 1) }
            try ChatB1.invalidate(db, event: event)
            let whole = try Self.applyBody(db, event, facts: facts)
            try also?(db, event)
            try Self.setCursor(db, event.stream, event.seq)
            try Self.leftOwn(db, event, me: accountId)
            try Self.narrow(db, me: accountId)
            return whole ? .applied : .passedOver
        }
    }

    /// True when the event's effect is wholly in the cache. Known types are
    /// applied; of a later type the known part (a request's changing part, a
    /// card) is applied, but it is not taken for the whole — nor is a body
    /// that could not be read: those are kept, and the sync takes a snapshot.
    private static func applyBody(_ db: Database, _ event: ChatEvent, facts: [String: ChatLocalFacts]?) throws -> Bool {
        var whole = false
        // An agent's card in a channel's stream is the channel's (F5), not the catalog's.
        if !ChatChannelAgents.reads(event), ChatCallStore.reads(event) {
            let done = try ChatCallStore.apply(db, event)
            if let id = done.request { try ChatReconcile.reconcile(db, [id], facts: facts) }
            whole = done.read && ChatCallStore.eventTypes.contains(event.type)
        } else {
            whole = try ChatEvents.apply(db, event)
        }
        if !whole {
            try db.execute(sql: "INSERT OR IGNORE INTO skipped_events (stream, seq, type, at, event_json) VALUES (?, ?, ?, ?, ?)",
                           arguments: [event.stream, event.seq, event.type, event.at, String(decoding: try JSONEncoder().encode(event), as: UTF8.self)])
            let recovery = event.type.hasPrefix("thread.participation") && event.stream.hasPrefix("member:")
                ? "a participation read" : (ChatEvents.channelPointer(event) == nil ? "an organization snapshot" : "a channel read")
            NSLog("agentpad: chat event \(event.type) (\(event.stream) #\(event.seq)) is not wholly known to this AgentPad; \(recovery) brings its effect")
        }
        return whole
    }

    /// Requests of a page (`GET /v1/orgs/{org}/requests`), by the same rule
    /// as events, with the actions they owe — one transaction.
    func apply(requests: [ChatRequestWire], facts: [String: ChatLocalFacts]?) throws {
        try queue.write { db in
            for wire in requests { try ChatCallStore.apply(db, wire, onThisDevice: wire.onThisDevice) }
            try ChatReconcile.reconcile(db, requests.map(\.requestId), facts: facts)
        }
    }

    /// At launch (and when the journal comes back): every request of the
    /// cache, with the journal's facts now (6.12).
    func reconcileAll(facts: [String: ChatLocalFacts]?) throws {
        try queue.write { db in
            try ChatReconcile.reconcile(db, try String.fetchAll(db, sql: "SELECT request_id FROM requests"), facts: facts)
        }
    }

    /// A stream that stopped being readable (`unsubscribed`): its cursor and
    /// the rows only it stands for go.
    func drop(stream: String) throws {
        try queue.write { db in
            try Self.drop(db, stream: stream)
            try Self.narrow(db, me: accountId)
        }
    }

    /// A stream no longer followed: its cursor and the rows only it brings.
    /// A team stays while the organization's admin stream is followed — the
    /// admin's snapshot carries every team; it is just no longer the user's
    /// (review C9-7).
    private static func drop(_ db: Database, stream: String) throws {
        try db.execute(sql: "DELETE FROM skipped_events WHERE stream = ?", arguments: [stream])
        try db.execute(sql: "DELETE FROM cursors WHERE stream = ?", arguments: [stream])
        if stream.hasPrefix("team:") {
            try leftTeam(db, String(stream.dropFirst("team:".count)))
        } else if stream.hasPrefix("org-admin:") {
            // No longer a manager: teams it is not in go with their members,
            // names included — a member sees nothing of other teams (C6).
            try db.execute(sql: "DELETE FROM invitations")
            for team in try String.fetchAll(db, sql: "SELECT team_id FROM teams WHERE mine = 0") {
                try forgetTeam(db, team)
            }
        }
    }

    /// Command types only owners and admins may send: what their bodies name
    /// (teams, addresses) is a manager's to see.
    static let managerCommandTypes: Set<String> = [
        "team.create", "team.rename", "team.archive", "team.add_member", "team.remove_member", "team.join",
        "member.set_role", "member.remove", "invitation.create", "invitation.revoke",
    ]

    /// Narrows the cache to the user's rights now, inside every transaction
    /// that may change them — an event, a snapshot, a stream dropped (C6,
    /// review C6 group A). Not a manager — by its role in the cache, or
    /// without the admin stream — it keeps nothing a manager sees: teams it
    /// is not in with their members, invitations, the admin stream's cursor
    /// (the snapshot owed brings it back if the role is). The send queue is
    /// left as it is: it holds the user's own actions, and the server refuses
    /// those no longer allowed (decision "Сужение видимости не трогает очередь
    /// отправки"); a window names from it only what the user may see now.
    static func narrow(_ db: Database, me: String) throws {
        try ChatChannels.narrow(db)
        let role = try String.fetchOne(db, sql: "SELECT role FROM members WHERE account_id = ?", arguments: [me])
        let followed = try followsAdmin(db)
        let manages = (role == "owner" || role == "admin") && followed
        guard !manages else { return }
        try db.execute(sql: "DELETE FROM cursors WHERE stream LIKE 'org-admin:%'")
        try db.execute(sql: "DELETE FROM invitations")
        for team in try String.fetchAll(db, sql: "SELECT team_id FROM teams WHERE mine = 0") {
            try forgetTeam(db, team)
        }
    }

    /// A sign the user's rights may have changed (C6): kept until a snapshot
    /// read after it is applied, across launches.
    func putRightsInDoubt() throws {
        try queue.write { db in try db.execute(sql: "UPDATE meta SET rights_in_doubt = 1 WHERE id = 1") }
    }

    /// The user's own `team.leave` or `team.remove_member`, by whatever
    /// stream it comes: the team is left now — its rows, and its stream's
    /// cursor with them; what that stream still brings is no longer applied
    /// (`ChatSync` unsubscribes it) (review C6c p1-2).
    static func leftOwn(_ db: Database, _ event: ChatEvent, me: String) throws {
        guard ["team.leave", "team.remove_member"].contains(event.type), event.body["account_id"]?.string == me,
              let team = event.body["team_id"]?.string else { return }
        try db.execute(sql: "DELETE FROM team_members WHERE team_id = ? AND account_id = ?", arguments: [team, me])
        try leftTeam(db, team)
        try db.execute(sql: "DELETE FROM cursors WHERE stream = ?", arguments: ["team:\(team)"])
    }

    /// The user is out of `team`: a manager keeps it, no longer the user's;
    /// anyone else keeps nothing of it.
    static func leftTeam(_ db: Database, _ team: String) throws {
        try db.execute(sql: "DELETE FROM edit_drafts WHERE team_id = ?", arguments: [team])
        if try followsAdmin(db) {
            try db.execute(sql: "UPDATE teams SET mine = 0 WHERE team_id = ?", arguments: [team])
        } else {
            try forgetTeam(db, team)
        }
        try ChatCallStore.dropTeam(db, team)
        try ChatChannels.narrow(db)
    }

    /// The organization's admin stream is followed: the user manages it.
    static func followsAdmin(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cursors WHERE stream LIKE 'org-admin:%')") ?? false
    }

    private static func forgetTeam(_ db: Database, _ team: String) throws {
        try db.execute(sql: "DELETE FROM team_members WHERE team_id = ?", arguments: [team])
        try db.execute(sql: "DELETE FROM teams WHERE team_id = ?", arguments: [team])
    }

    // MARK: Snapshot

    /// Replaces the server's rows of the tables `snapshot` carries and sets
    /// its cursors, in one transaction. Local columns of rows that stay and
    /// the send queue are kept. Requests follow the rule of versions, and
    /// every request of the cache gets the actions it owes, from `facts`.
    /// `confirmsRights`: the session of a snapshot read after the last sign
    /// of changed rights — it ends their doubt for that session, in this
    /// transaction (C6).
    func apply(_ snapshot: ChatSnapshot, following streams: Set<String>? = nil, facts: [String: ChatLocalFacts]? = nil,
               confirmsRights session: String? = nil) throws {
        try queue.write { db in
            if let session {
                try db.execute(sql: "UPDATE meta SET rights_in_doubt = 0, rights_session = ? WHERE id = 1", arguments: [session])
            }
            // Streams the snapshot no longer has go first, in the same
            // transaction, so nothing it brings is removed after it (review C9-5, C9-7).
            if let streams {
                // Channel streams are not the snapshot's: their cursors go with their cards (F3).
                let kept = Set(try String.fetchAll(db, sql: "SELECT stream FROM cursors WHERE stream NOT LIKE 'channel:%' AND stream NOT LIKE 'dm:%'"))
                for gone in kept.subtracting(streams) { try Self.drop(db, stream: gone) }
            }
            if let members = snapshot.members {
                try Self.keepOnly(db, "members", key: "account_id", members.map(\.accountId))
                for m in members {
                    try db.execute(sql: """
                        INSERT INTO members (account_id, handle, name, role) VALUES (?, ?, ?, ?)
                        ON CONFLICT(account_id) DO UPDATE SET handle = excluded.handle, name = excluded.name, role = excluded.role
                        """, arguments: [m.accountId, m.handle, m.name, m.role])
                }
            }
            if let teams = snapshot.teams {
                try Self.keepOnly(db, "teams", key: "team_id", teams.map(\.teamId))
                for t in teams {
                    try db.execute(sql: """
                        INSERT INTO teams (team_id, name, is_general, archived_at, mine) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(team_id) DO UPDATE SET name = excluded.name, is_general = excluded.is_general,
                            archived_at = excluded.archived_at, mine = excluded.mine
                        """, arguments: [t.teamId, t.name, t.isGeneral, t.archivedAt, t.mine])
                }
            }
            if let name = snapshot.orgName {
                try db.execute(sql: "UPDATE meta SET org_name = ? WHERE id = 1", arguments: [name])
            }
            if let pairs = snapshot.teamMembers {
                try db.execute(sql: "DELETE FROM team_members")
                for p in Set(pairs) {
                    try db.execute(sql: "INSERT INTO team_members (team_id, account_id) VALUES (?, ?)", arguments: [p.teamId, p.accountId])
                }
            }
            if let invitations = snapshot.invitations {
                try db.execute(sql: "DELETE FROM invitations")
                for i in invitations {
                    try db.execute(
                        sql: "INSERT INTO invitations (invitation_id, email, role, state, expires_at) VALUES (?, ?, ?, ?, ?)",
                        arguments: [i.invitationId, i.email, i.role, i.state, i.expiresAt]
                    )
                }
            }
            if let agents = snapshot.agents { try ChatCallStore.replaceCatalog(db, agents) }
            for wire in snapshot.requests ?? [] { try ChatCallStore.apply(db, wire, onThisDevice: wire.onThisDevice) }
            try ChatReconcile.reconcile(db, try String.fetchAll(db, sql: "SELECT request_id FROM requests"), facts: facts)
            if snapshot.threadParticipationReload { try ChatB1.reset(db) }
            if snapshot.teams != nil { try ChatEditDrafts.removeRevoked(db) }
            for (stream, seq) in snapshot.cursors { try Self.setCursor(db, stream, seq) }
            // Calls asked here the server never took (D5), with the read that says so.
            try ChatCallStore.settleCreates(db)
            try Self.narrow(db, me: accountId)
            // After the teams: a card is kept only in a team of the user's (F2).
            // The read goes on with pages, if any, and ends with `endChannelsRead`.
            try db.execute(sql: "UPDATE meta SET channels_served = ?, channels_read_open = ? WHERE id = 1",
                           arguments: [snapshot.channels != nil, snapshot.channels != nil])
            for card in snapshot.channels ?? [] { try ChatChannels.write(db, card) }
            try ChatChannels.applyWindows(db, snapshot.channels ?? [])
            try db.execute(sql: "UPDATE meta SET agents_served = ? WHERE id = 1", arguments: [snapshot.agentChannels != nil])
            try ChatChannelAgents.replace(db, snapshot.agentChannels ?? [])
        }
    }

    private static func keepOnly(_ db: Database, _ table: String, key: String, _ ids: [String]) throws {
        let kept = Set(ids)
        let existing = try String.fetchAll(db, sql: "SELECT \(key) FROM \(table)")
        for id in existing where !kept.contains(id) {
            try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [id])
        }
    }

    // MARK: Send queue

    var outbox: ChatCommandTable { ChatCommandTable(queue: queue, table: "outbox") }

    @discardableResult
    func enqueue(_ record: ChatCommandRecord) throws -> ChatCommandRecord { try outbox.enqueue(record) }
    func commands() throws -> [ChatCommandRecord] { try outbox.commands() }
}
