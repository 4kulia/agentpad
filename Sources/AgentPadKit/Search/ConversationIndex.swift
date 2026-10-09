import Foundation
import GRDB

struct SearchIndexState: Codable, Equatable, Sendable {
    var enabled = false
    var cleared = false
    var clearing = false
    var paused = false
    var epoch = UUID().uuidString
}

struct SearchIndexStatus: Equatable, Sendable {
    var state = SearchIndexState()
    var scanning = false
    var processed = 0
    var discovered = 0
    var skipped = 0
    var bytes: Int64 = 0
    var partial = false
    var error: String?
    var revision = 0
    var label: String {
        if let error { return error }
        if state.clearing { return "Clearing index…" }
        if state.cleared { return "Index cleared" }
        if !state.enabled { return "Indexing off" }
        if state.paused { return "Indexing paused · Partial results" }
        if scanning { return "Building index… · Partial results" }
        return partial ? "Partial results" : "Index up to date"
    }
}

/// One process-wide owner, independent of windows and team connections.
/// The consent file lives outside the disposable directory; startup completes
/// an interrupted Clear before any reader or writer can reopen the database.
actor ConversationIndex {
    static let shared = ConversationIndex(directory: directory, roots: Dictionary(uniqueKeysWithValues:
        AgentSessionScanner.stores.filter { ConversationSource.agents.contains($0.agentId) }.map { ($0.agentId, $0.defaultRoot()) }))
    static var directory: URL { SessionCatalogFiles.directory.appendingPathComponent("search", isDirectory: true) }
    let directory: URL
    let consentURL: URL
    let roots: [String: URL]
    let visibility: @Sendable () -> ChannelConversationFilter
    let throttled: Bool
    private var loaded = false
    private var queue: DatabaseQueue?
    private var status = SearchIndexStatus()
    private var worker: Task<ConversationSource.Snapshot?, Error>?
    private var contextReader: Task<ConversationSource.Snapshot?, Error>?
    private var contextID: UUID?
    private var scanID: UUID?
    private var lastScan = Date.distantPast
    private var lastFullScan = Date.distantPast
    private let budget: Int64
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    init(directory: URL, roots: [String: URL], consentURL: URL? = nil, budget: Int64 = 1_073_741_824,
         throttled: Bool = true, configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() },
         visibility: @escaping @Sendable () -> ChannelConversationFilter = { .current() }) {
        self.directory = directory; self.roots = roots; self.consentURL = consentURL ?? directory.deletingLastPathComponent().appendingPathComponent("search-consent.json")
        self.budget = budget; self.throttled = throttled; self.visibility = visibility
        self.configuration = configuration; self.now = now
    }
    func snapshot() -> SearchIndexStatus {
        do { try load() } catch { status.error = "Search index unavailable. Rebuild index to retry." }
        status.bytes = diskBytes()
        return status
    }
    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: consentURL.path) {
            status.state = try JSONDecoder().decode(SearchIndexState.self, from: Data(contentsOf: consentURL))
        }
        if status.state.clearing { try erase() }
        loaded = true; status.bytes = diskBytes()
    }
    private func save(_ state: SearchIndexState) throws {
        try FileManager.default.createDirectory(at: consentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: consentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: consentURL.path)
        status.state = state
    }
    func enable(rebuild: Bool = false) throws {
        try load()
        if status.state.cleared && !rebuild { throw SearchProblem.rebuildRequired }
        if rebuild { try clear() }
        var state = status.state
        state.enabled = true; state.cleared = false; state.paused = false
        try save(state); status.error = nil; status.partial = true; status.revision += 1
    }
    func disable() throws {
        try load(); var state = status.state; state.enabled = false
        try save(state); stop(); status.revision += 1; try queue?.close(); queue = nil
    }
    func pause(_ value: Bool) throws {
        try load(); var state = status.state; state.paused = value; try save(state)
        if value { stop() }; status.revision += 1
    }
    private func stop() { scanID = nil; worker?.cancel(); worker = nil; contextReader?.cancel(); contextReader = nil; contextID = nil; status.scanning = false }
    func clear() throws {
        try load()
        // Persist first. No late callback can commit under the previous epoch.
        try save(SearchIndexState(enabled: false, cleared: true, clearing: true, paused: false))
        stop(); status.revision += 1
        do { try queue?.close(); queue = nil; try erase() }
        catch { status.error = "Index removal failed. Retry Clear index."; status.bytes = diskBytes(); throw error }
    }
    private func erase() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        var state = status.state; state.clearing = false; try save(state)
        status.bytes = 0; status.processed = 0; status.discovered = 0; status.skipped = 0; status.partial = false; status.error = nil
    }
    private func readDB<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try db.read(body) }
    private func writeDB<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try db.write(body) }
    private func openDatabase() throws -> DatabaseQueue {
        guard status.state.enabled, !status.state.clearing else { throw SearchProblem.unavailable }
        if let queue { return queue }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var url = directory, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        var config = configuration; config.busyMode = .timeout(0.15)
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path, configuration: config)
        try writeDB(db) { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY; PRAGMA cache_size = -4096;")
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version == 0 || version == 2 || version == 3 else { throw SearchProblem.rebuildRequired }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sources (path TEXT PRIMARY KEY, agent TEXT NOT NULL, conversation TEXT NOT NULL,
                    generation TEXT NOT NULL, digest TEXT NOT NULL, record BLOB NOT NULL, stamp TEXT NOT NULL,
                    checkpoint INTEGER NOT NULL, available INTEGER NOT NULL DEFAULT 1, partial INTEGER NOT NULL DEFAULT 0, skipped INTEGER NOT NULL DEFAULT 0);
                CREATE UNIQUE INDEX IF NOT EXISTS sources_identity ON sources(agent, conversation);
                CREATE TABLE IF NOT EXISTS turns (rowid INTEGER PRIMARY KEY, path TEXT NOT NULL, generation TEXT NOT NULL,
                    agent TEXT NOT NULL, conversation TEXT NOT NULL, turn TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
                    time REAL NOT NULL, ordinal INTEGER NOT NULL, offset INTEGER NOT NULL, truncated INTEGER NOT NULL,
                    folder TEXT NOT NULL, UNIQUE(path, generation, turn));
                CREATE INDEX IF NOT EXISTS turns_order ON turns(time DESC, agent DESC, conversation DESC, turn DESC);
                CREATE INDEX IF NOT EXISTS turns_source ON turns(path, generation);
                CREATE VIRTUAL TABLE IF NOT EXISTS turns_fts USING fts5(text, content=turns, content_rowid=rowid, tokenize='unicode61');
                CREATE TRIGGER IF NOT EXISTS turns_insert AFTER INSERT ON turns BEGIN
                    INSERT INTO turns_fts(rowid,text) VALUES(new.rowid,new.text); END;
                CREATE TRIGGER IF NOT EXISTS turns_delete AFTER DELETE ON turns BEGIN
                    INSERT INTO turns_fts(turns_fts,rowid,text) VALUES('delete',old.rowid,old.text); END;
                PRAGMA user_version = 3;
                """)
            if try !db.columns(in: "sources").contains(where: { $0.name == "parser" }) {
                try db.execute(sql: "ALTER TABLE sources ADD COLUMN parser BLOB")
            }
            if try !db.columns(in: "turns").contains(where: { $0.name == "prefix" }) {
                try db.execute(sql: "ALTER TABLE turns ADD COLUMN prefix TEXT NOT NULL DEFAULT ''")
            }
        }
        try cleanup(db)
        try protectFiles(); queue = db; return db
    }
    /// Recovery must be able to write FTS delete records even when an old
    /// interrupted generation exhausted our page cap. Restore the cap only
    /// after cleanup commits; SQLite can then reuse the released pages.
    private func cleanup(_ queue: DatabaseQueue) throws {
        try queue.writeWithoutTransaction { db in
            _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = 4294967294")
        }
        defer {
            try? queue.writeWithoutTransaction { db in
                _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = \(max(128, budget / 3 / 4096))")
            }
        }
        try writeDB(queue) { db in
            try db.execute(sql: "DELETE FROM turns WHERE NOT EXISTS (SELECT 1 FROM sources s WHERE s.path=turns.path AND s.generation=turns.generation)")
        }
    }
    private func cachedSource(_ db: DatabaseQueue, path: String) throws -> ConversationSource.Snapshot? {
        try readDB(db) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE path=?", arguments: [path]) else { return nil }
            let record = try JSONDecoder().decode(AgentSessionRecord.self, from: row["record"])
            let turns = try Row.fetchAll(db, sql: "SELECT * FROM turns WHERE path=? AND generation=? ORDER BY ordinal", arguments: [path, row["generation"] as String]).map(Self.turn)
            return ConversationSource.Snapshot(record: record, turns: turns, digest: row["digest"], checkpoint: UInt64(row["checkpoint"] as Int64),
                skipped: row["skipped"], partial: row["partial"], stamp: row["stamp"], parserState: row["parser"])
        }
    }
    private static func turn(_ row: Row) -> ConversationTurn {
        let time: Double = row["time"]
        return ConversationTurn(id: row["turn"], role: row["role"], text: row["text"], date: time == -62_135_596_800 ? nil : Date(timeIntervalSince1970: time),
            ordinal: row["ordinal"], offset: UInt64(row["offset"] as Int64), truncated: row["truncated"], prefixDigest: row["prefix"])
    }
    private func protectFiles() throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private func diskBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private static func stamp(_ url: URL) -> String? {
        var s = stat(); guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { return nil }
        return ConversationSource.stamp(s)
    }
    func refresh(force: Bool = false) async {
        do {
            try load()
            guard status.state.enabled, !status.state.paused, scanID == nil, contextReader == nil, force || now().timeIntervalSince(lastScan) >= 30 else { return }
            let db = try openDatabase(), id = UUID(), epoch = status.state.epoch, roots = roots
            let verifyContent = force || now().timeIntervalSince(lastFullScan) > 1800
            scanID = id; status.scanning = true; status.error = nil; status.partial = false; status.skipped = 0; status.processed = 0
            defer { if scanID == id { scanID = nil; status.scanning = false; lastScan = now(); status.bytes = diskBytes() } }
            let files = try await Task.detached(priority: .utility) { try ConversationSource.enumerate(roots) }.value
            guard scanID == id else { return }
            status.discovered = files.count
            // Successful enumeration alone permits pruning missing sources.
            try cleanup(db)
            let existing = Set(files.map { $0.url.path })
            var identities = Set<String>()
            try writeDB(db) { db in
                for row in try Row.fetchAll(db, sql: "SELECT path,agent FROM sources") {
                    let path: String = row["path"]
                    if existing.contains(path) { continue }
                    if let root = roots[row["agent"] as String], !FileManager.default.fileExists(atPath: root.path) {
                        try db.execute(sql: "UPDATE sources SET available=0 WHERE path=? AND available=1", arguments: [path])
                        if db.changesCount > 0 { status.revision += 1 }
                        status.partial = true; continue
                    }
                    try db.execute(sql: "DELETE FROM turns WHERE path=?; DELETE FROM sources WHERE path=?", arguments: [path, path])
                    if db.changesCount > 0 { status.revision += 1 }
                }
            }
            for file in files {
                // Even metadata-only skips must let search, Pause and Clear run.
                await Task.yield()
                guard scanID == id, status.state.epoch == epoch, !Task.isCancelled else { return }
                let path = file.url.path, policy = visibility(), throttled = throttled
                let cached = try readDB(db) { try Row.fetchOne($0, sql: "SELECT stamp,record,partial,skipped,available FROM sources WHERE path=?", arguments: [path]) }
                let previous: String? = cached?["stamp"]
                if !verifyContent, previous == Self.stamp(file.url), let cached, cached["available"] as Bool {
                    let record = try JSONDecoder().decode(AgentSessionRecord.self, from: cached["record"])
                    if policy.allows(agentId: record.agentId, conversationId: record.conversationId, startedAt: record.startedAt, root: file.root),
                       identities.insert(record.id).inserted {
                        status.partial = status.partial || (cached["partial"] as Bool) || (cached["skipped"] as Int) > 0
                        status.skipped += cached["skipped"] as Int
                        status.processed += 1
                        continue
                    }
                }
                let saved = try cachedSource(db, path: path)
                let task = Task.detached(priority: .utility) { try await ConversationSource.read(file, visibility: policy, throttled: throttled, previous: saved) }
                worker = task
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                    guard scanID == id, status.state.epoch == epoch else { return }
                    if let value, visibility().allows(agentId: value.record.agentId, conversationId: value.record.conversationId,
                                                      startedAt: value.record.startedAt, root: file.root) {
                        if identities.insert(value.record.id).inserted { try replace(value, previous: saved, file: file, db: db) }
                        status.skipped += value.skipped; status.partial = status.partial || value.partial || value.skipped > 0
                    } else {
                        try writeDB(db) { try $0.execute(sql: "DELETE FROM turns WHERE path=?; DELETE FROM sources WHERE path=?", arguments: [path, path]) }
                        if cached != nil { status.revision += 1 }
                        status.skipped += 1
                    }
                } catch is CancellationError { return }
                catch {
                    guard scanID == id else { return }
                    // The last committed source remains visible until its
                    // replacement commits, including cancellation or SQLITE_FULL.
                    status.skipped += 1; status.partial = true
                    if error as? SearchProblem == .sizeLimit || (error as? DatabaseError)?.resultCode == .SQLITE_FULL { throw SearchProblem.sizeLimit }
                }
                status.processed += 1
            }
            if verifyContent { lastFullScan = now() }
            try protectFiles()
        } catch {
            status.partial = true; status.error = error as? SearchProblem == .sizeLimit ? SearchProblem.sizeLimit.localizedDescription
                : "Indexing could not finish. Partial results. Retry or Rebuild index."
        }
    }
    private func replace(_ value: ConversationSource.Snapshot, previous: ConversationSource.Snapshot?, file: ConversationSource.File, db: DatabaseQueue) throws {
        let path = file.url.path
        let published = try readDB(db) { try Row.fetchOne($0, sql: "SELECT generation,available FROM sources WHERE path=?", arguments: [path]) }
        let append = value.resumedFrom > 0 && published != nil && previous?.record.id == value.record.id
        let oldTurns = append ? Dictionary(uniqueKeysWithValues: (previous?.turns ?? []).map { ($0.id, $0) }) : [:]
        let changed = value.turns.filter { oldTurns[$0.id] != $0 }
        let unchanged = previous?.digest == value.digest && previous?.turns == value.turns
        if !unchanged {
            guard diskBytes() + Int64(changed.reduce(0) { $0 + $1.text.utf8.count }) * 4 + 8_388_608 < budget else { throw SearchProblem.sizeLimit }
        }
        let generation: String = append ? published!["generation"] : UUID().uuidString
        let folder = value.record.cwd.standardizedFileURL.resolvingSymlinksInPath().path
        // One source, one transaction. No committed staging generations and no
        // suspension between the turns, source metadata and checkpoint writes.
        try writeDB(db) { db in
            if append {
                let kept = Set(value.turns.map(\.id))
                for id in oldTurns.keys where !kept.contains(id) {
                    try db.execute(sql: "DELETE FROM turns WHERE path=? AND turn=?", arguments: [path, id])
                }
                if previous?.record.cwdPath != value.record.cwdPath {
                    try db.execute(sql: "UPDATE turns SET folder=? WHERE path=?", arguments: [folder, path])
                }
            } else {
                try db.execute(sql: "DELETE FROM turns WHERE path=? OR (agent=? AND conversation=?)", arguments: [path, value.record.agentId, value.record.conversationId])
            }
            for turn in changed {
                try Task.checkCancellation()
                try db.execute(sql: "DELETE FROM turns WHERE path=? AND turn=?", arguments: [path, turn.id])
                try db.execute(sql: "INSERT INTO turns(path,generation,agent,conversation,turn,role,text,time,ordinal,offset,truncated,folder,prefix) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    arguments: [path, generation, value.record.agentId, value.record.conversationId, turn.id, turn.role, turn.text,
                        turn.date?.timeIntervalSince1970 ?? -62_135_596_800, turn.ordinal, Int64(turn.offset), turn.truncated, folder, turn.prefixDigest])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO sources(path,agent,conversation,generation,digest,record,stamp,checkpoint,available,partial,skipped,parser) VALUES(?,?,?,?,?,?,?,?,1,?,?,?)",
                arguments: [path, value.record.agentId, value.record.conversationId, generation, value.digest,
                    try JSONEncoder().encode(value.record), value.stamp, Int64(value.checkpoint), value.partial, value.skipped, value.parserState])
        }
        if !unchanged || published?["available"] as Bool? != true { status.revision += 1 }
    }

    func search(_ query: SearchQuery, filter: LocalSearchFilter = .init(), cursor: LocalSearchCursor? = nil, limit: Int = 20) async throws -> LocalSearchPage {
        try load(); guard status.state.enabled, !status.state.clearing else { return .init() }
        let db = try openDatabase()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try performSearch(query, filter: filter, cursor: cursor, limit: limit)
        }, onCancel: { db.interrupt() })
    }
    private func performSearch(_ query: SearchQuery, filter: LocalSearchFilter, cursor: LocalSearchCursor?, limit: Int) throws -> LocalSearchPage {
        try load(); guard status.state.enabled, !status.state.clearing else { return .init() }
        let db = try openDatabase(), epoch = status.state.epoch
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = SearchQuery.digest(query.match + String(decoding: try encoder.encode(filter), as: UTF8.self))
        if let cursor, cursor.epoch != epoch || cursor.fingerprint != fingerprint { throw SearchProblem.invalidCursor }
        var condition = "turns_fts MATCH ? AND s.available=1 AND t.generation=s.generation"
        var args: [DatabaseValue] = [query.match.databaseValue]
        if let agent = filter.agent { condition += " AND t.agent=?"; args.append(agent.databaseValue) }
        if let folder = filter.normalizedFolder { condition += " AND t.folder=?"; args.append(folder.databaseValue) }
        if let from = filter.from { condition += " AND t.time>=? AND t.time<>-62135596800"; args.append(from.timeIntervalSince1970.databaseValue) }
        if let to = filter.to { condition += " AND t.time<? AND t.time<>-62135596800"; args.append(to.timeIntervalSince1970.databaseValue) }
        var after = cursor, hits: [LocalSearchHit] = [], positions: [LocalSearchCursor] = []
        let pageSize = min(50, max(1, limit)), policy = visibility()
        repeat {
            var predicate = condition, values = args
            if let after {
                predicate += " AND (t.time,t.agent,t.conversation,t.turn)<(?,?,?,?)"
                values += [after.time.databaseValue, after.agent.databaseValue, after.conversation.databaseValue, after.turn.databaseValue]
            }
            let rows = try readDB(db) { try Row.fetchAll($0, sql: """
                SELECT t.*,s.record,s.digest,s.stamp FROM turns_fts JOIN turns t ON t.rowid=turns_fts.rowid JOIN sources s ON s.path=t.path
                WHERE \(predicate) ORDER BY t.time DESC,t.agent COLLATE BINARY DESC,t.conversation COLLATE BINARY DESC,t.turn COLLATE BINARY DESC LIMIT 50
                """, arguments: StatementArguments(values)) }
            if rows.isEmpty { break }
            for row in rows {
                let position = LocalSearchCursor(epoch: epoch, fingerprint: fingerprint, time: row["time"], agent: row["agent"], conversation: row["conversation"], turn: row["turn"])
                after = position
                let record = try JSONDecoder().decode(AgentSessionRecord.self, from: row["record"])
                guard let file = record.fileURL, let root = roots[record.agentId], ConversationSource.safe(file, under: root),
                      Self.stamp(file) != nil,
                      policy.allows(agentId: record.agentId, conversationId: record.conversationId, startedAt: record.startedAt, root: root) else { continue }
                var turn = Self.turn(row)
                let turnDigest = turn.digest
                turn.text = SearchSnippet.text(turn.text, words: query.words)
                hits.append(LocalSearchHit(record: record, turn: turn, sourceDigest: row["digest"], epoch: epoch, turnDigest: turnDigest)); positions.append(position)
                if hits.count > pageSize { break }
            }
            if rows.count < 50 || hits.count > pageSize { break }
        } while !Task.isCancelled
        return LocalSearchPage(hits: Array(hits.prefix(pageSize)), next: hits.count > pageSize ? positions[pageSize - 1] : nil)
    }
    func contains(_ hit: LocalSearchHit) throws -> Bool {
        try load()
        guard status.state.enabled, hit.epoch == status.state.epoch, let file = hit.record.fileURL,
              let root = roots[hit.record.agentId], ConversationSource.safe(file, under: root), Self.stamp(file) != nil,
              visibility().allows(agentId: hit.record.agentId, conversationId: hit.record.conversationId, startedAt: hit.record.startedAt, root: root) else { return false }
        return try readDB(openDatabase()) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT t.* FROM turns t JOIN sources s ON s.path=t.path AND s.generation=t.generation WHERE s.available=1 AND t.agent=? AND t.conversation=? AND t.turn=?",
                arguments: [hit.record.agentId, hit.record.conversationId, hit.turn.id]) else { return false }
            let turn = Self.turn(row)
            return turn.digest == hit.turnDigest && (!turn.id.hasPrefix("position:") || turn.prefixDigest == hit.turn.prefixDigest)
        }
    }
    func context(_ hit: LocalSearchHit) async throws -> [ConversationTurn] {
        try load()
        guard status.state.enabled, hit.epoch == status.state.epoch, let file = hit.record.fileURL, let root = roots[hit.record.agentId] else { throw SearchProblem.changed }
        let policy = visibility(), throttled = throttled
        // Interactive context wins over background indexing; a second window
        // replaces this bounded reader instead of spawning another parser.
        if scanID != nil { worker?.cancel(); scanID = nil; status.scanning = false; status.partial = true }
        contextReader?.cancel()
        let readID = UUID(); contextID = readID
        let reader = Task.detached(priority: .utility) {
            try await ConversationSource.read(.init(agent: hit.record.agentId, url: file, root: root), visibility: policy, throttled: throttled)
        }
        contextReader = reader
        defer { if contextID == readID { contextReader = nil; contextID = nil } }
        let value = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
        try Task.checkCancellation()
        guard contextID == readID else { throw CancellationError() }
        guard status.state.enabled, hit.epoch == status.state.epoch,
              visibility().allows(agentId: hit.record.agentId, conversationId: hit.record.conversationId, startedAt: hit.record.startedAt, root: root),
              let value, value.record.conversationId == hit.record.conversationId,
              let index = value.turns.firstIndex(where: { $0.id == hit.turn.id && $0.digest == hit.turnDigest }),
              !hit.turn.id.hasPrefix("position:") || value.turns[index].prefixDigest == hit.turn.prefixDigest else { throw SearchProblem.changed }
        return Array(value.turns[max(0, index - 2)..<min(value.turns.count, index + 3)])
    }
}
