import Foundation
import GRDB
import Observation

struct SessionNameKey: Hashable, Sendable {
    var agentID: String
    var conversationID: String
    init(_ agentID: String, _ conversationID: String) { self.agentID = agentID; self.conversationID = conversationID }
}

enum SessionTitle {
    static func resolve(manual: String? = nil, agentName: String? = nil, firstPrompt: String? = nil,
                        summary: String? = nil, folder: URL) -> String {
        for value in [manual, agentName] {
            if let value = nonempty(value) { return singleLine(value) }
        }
        if let prompt = AgentSessionScanner.displayableUserText(firstPrompt), let phrase = nonempty(firstPhrase(prompt)) { return phrase }
        if let summary = nonempty(summary) { return AgentSessionScanner.cleanedTitle(summary) }
        return "Session in \(folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent)"
    }
    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    static func firstPhrase(_ text: String) -> String {
        let phrase = String(text.prefix { !".!?\n\r".contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count > 80 else { return phrase }
        let prefix = String(phrase.prefix(79))
        let boundary = prefix.lastIndex(where: \.isWhitespace)
        return (boundary.map { String(prefix[..<$0]) } ?? prefix) + "…"
    }
    static func boundedPrompt(_ text: String?) -> String? {
        guard var text = text.map({ String($0.prefix(2048)) }) else { return nil }
        while text.utf8.count > 2048 { text.removeLast() }
        return text
    }
}

enum SessionCatalogFiles {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/agentpad")
    }
}

/// The only durable user data in the catalog. All disk operations run on this actor.
actor SessionNamesDatabase {
    struct Snapshot: Sendable { var names: [SessionNameKey: String]; var notice: String? }
    let url: URL
    private var queue: DatabaseQueue?
    private var recoveryNotice: String?
    init(url: URL) { self.url = url }

    private func open() throws -> DatabaseQueue {
        if let queue { return queue }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func make() throws -> DatabaseQueue {
            var configuration = Configuration()
            configuration.busyMode = .timeout(0.15)
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("session-names-v1") { db in
                try db.execute(sql: """
                    CREATE TABLE session_names (
                        agent_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
                        name TEXT NOT NULL, updated_at REAL NOT NULL,
                        PRIMARY KEY (agent_id, conversation_id)
                    )
                    """)
            }
            try migrator.migrate(queue)
            return queue
        }
        do { let opened = try make(); queue = opened; return opened }
        catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            // BUSY, LOCKED, IO and access failures never move the original database.
            let suffix = ".broken-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
            var moved: [(URL, URL)] = []
            do {
                for sidecar in ["", "-wal", "-shm"] {
                    let source = URL(fileURLWithPath: url.path + sidecar)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let target = URL(fileURLWithPath: url.path + suffix + sidecar)
                    try FileManager.default.moveItem(at: source, to: target); moved.append((source, target))
                }
            } catch {
                for (source, target) in moved.reversed() { try? FileManager.default.moveItem(at: target, to: source) }
                throw error
            }
            recoveryNotice = "Session names could not be read. The original database was preserved for recovery."
            let opened = try make(); queue = opened; return opened
        }
    }

    func load() throws -> Snapshot {
        do {
            let names = try open().read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT agent_id, conversation_id, name FROM session_names").map {
                    (SessionNameKey($0["agent_id"], $0["conversation_id"]), $0["name"] as String)
                })
            }
            return Snapshot(names: names, notice: recoveryNotice)
        } catch { queue = nil; throw error } // Retry opening on the next access.
    }

    func set(_ name: String, for key: SessionNameKey) throws {
        do {
            try open().write { db in
                if let name = SessionTitle.nonempty(name) {
                    try db.execute(sql: """
                        INSERT INTO session_names (agent_id, conversation_id, name, updated_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT(agent_id, conversation_id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
                        """, arguments: [key.agentID, key.conversationID, name, Date().timeIntervalSince1970])
                } else {
                    try db.execute(sql: "DELETE FROM session_names WHERE agent_id = ? AND conversation_id = ?", arguments: [key.agentID, key.conversationID])
                }
            }
        } catch { queue = nil; throw error }
    }
}

@MainActor @Observable
final class SessionNames {
    static let shared = SessionNames(url: SessionCatalogFiles.directory.appendingPathComponent("session-names.sqlite"))
    private let database: SessionNamesDatabase
    private(set) var values: [SessionNameKey: String] = [:]
    private(set) var problem: String?
    init(url: URL) { database = SessionNamesDatabase(url: url) }
    func load() async {
        do { let snapshot = try await database.load(); values = snapshot.names; problem = snapshot.notice }
        catch { problem = "Session names could not be read. Try again: \(error.localizedDescription)" }
    }
    func rename(_ name: String, for key: SessionNameKey) async throws {
        do {
            try await database.set(name, for: key)
            values[key] = SessionTitle.nonempty(name) // Publish only after the transaction commits.
            problem = nil
        } catch { problem = "Session name could not be saved: \(error.localizedDescription)"; throw error }
    }
}
