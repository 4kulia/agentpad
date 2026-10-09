import Foundation
import GRDB

/// Append-only executor provenance, independent of the resettable journal,
/// organization caches and connection state. No transcript text is stored.
struct ExecutorConversations: Sendable {
    let files: ChatFiles
    var url: URL { files.directory.appendingPathComponent("executor-conversations.sqlite") }

    func ids() throws -> Set<String> {
        try read(Set<String>()) { Set(try String.fetchAll($0, sql: "SELECT id FROM conversations")) }
    }

    func contains(_ id: String) throws -> Bool {
        try read(false) { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                                           arguments: [id.lowercased()])! }
    }

    func record(_ id: String) throws {
        guard !id.isEmpty else { throw ChatError.storage("missing executor conversation") }
        try write { try Self.insert(id, into: $0) }
    }

    /// The checkpoint is committed with the seed. Recording a new run before
    /// migration does not mark the legacy journal as already imported.
    func seedOnce(from journal: DatabaseQueue) throws {
        guard try !read(false, {
            try Self.seedIncompleteBefore($0) != nil || Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM migrations WHERE id = 'runs-v1')")!
        }) else { return }
        // Never hold the marker database's write lock while reading the
        // journal: a run writes its marker inside a journal transaction.
        let ids = try journal.read { try String.fetchAll($0, sql: "SELECT DISTINCT conversation_id FROM runs WHERE conversation_id != ''") }
        try seed(ids)
    }

    /// Read the old journal before reset can replace it. A failed read leaves
    /// a durable cutoff; opening the replacement must not claim a complete seed.
    func seedBeforeReset(journalURL: URL, at: Date) throws {
        let ids: [String]
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let journal = try DatabaseQueue(path: journalURL.path, configuration: configuration)
            defer { try? journal.close() }
            ids = try journal.read { try String.fetchAll($0, sql: "SELECT DISTINCT conversation_id FROM runs WHERE conversation_id != ''") }
        } catch {
            try write {
                try $0.execute(sql: """
                    INSERT INTO seed_state (id, incomplete_before) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET incomplete_before = max(incomplete_before, excluded.incomplete_before)
                    """, arguments: [at.timeIntervalSince1970])
            }
            return
        }
        try seed(ids)
    }

    func seedIncompleteBefore() throws -> Date? {
        try read(nil, Self.seedIncompleteBefore)
    }

    private static func seedIncompleteBefore(_ db: Database) throws -> Date? {
        guard try db.tableExists("seed_state") else { return nil }
        return try Double.fetchOne(db, sql: "SELECT incomplete_before FROM seed_state WHERE id = 1").map(Date.init(timeIntervalSince1970:))
    }

    private func seed(_ ids: [String]) throws {
        try write { db in
            for id in ids { try Self.insert(id, into: db) }
            if try Self.seedIncompleteBefore(db) == nil {
                try db.execute(sql: "INSERT OR IGNORE INTO migrations (id) VALUES ('runs-v1')")
            }
        }
    }

    /// Missing history cannot prove that a conversation began after a lost
    /// seed. Never use its recent activity, file mtime or process launch time.
    static func allowsHistory(_ id: String, incompleteBefore: Date?, startedAt: Date? = nil,
                              root: URL = ClaudeSessionResume.projectsRoot()) -> Bool {
        guard let incompleteBefore else { return true }
        let start = startedAt ?? AgentSessionScanner.claudeTranscript(conversationId: id, root: root).flatMap {
            AgentSessionScanner.claudeRecord(file: $0, mtime: .distantPast)?.startedAt
        }
        return start.map { $0 >= incompleteBefore } ?? false
    }

    private static func insert(_ id: String, into db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO conversations (id) VALUES (?)", arguments: [id.lowercased()])
    }

    private func exists() throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw ChatError.storage("cannot read executor conversations")
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ChatError.storage("invalid executor conversations file") }
        return true
    }

    private func read<T>(_ missing: T, _ body: (Database) throws -> T) throws -> T {
        guard try exists() else { return missing }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    private func write(_ body: (Database) throws -> Void) throws {
        _ = try exists()
        try files.prepareDirectory()
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS migrations (id TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS seed_state (id INTEGER PRIMARY KEY CHECK (id = 1), incomplete_before REAL NOT NULL)")
            try body(db)
        }
    }
}
