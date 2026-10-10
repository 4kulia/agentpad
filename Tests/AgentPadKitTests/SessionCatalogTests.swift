import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

final class CatalogCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    var count: Int { lock.withLock { storage } }
}

final class SessionCatalogTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private var cache: URL { root.appendingPathComponent("session-headers.json") }
    private var claude: URL { root.appendingPathComponent("claude") }
    private var codex: URL { root.appendingPathComponent("codex") }
    private func identifier(_ label: String) -> String {
        let hash = label.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "a0000000-0000-4000-8000-" + String(format: "%012llx", hash & 0xffffffffffff)
    }
    private func file(_ id: String, entrypoint: String = "cli", sidechain: Bool = false) throws -> URL {
        try SessionStoreFixtures.writeFile("\(identifier(id)).jsonl", in: claude.appendingPathComponent("project"), lines: [
            "{\"type\":\"user\",\"entrypoint\":\"\(entrypoint)\",\"cwd\":\"/tmp/project\",\"isSidechain\":\(sidechain),\"message\":{\"content\":\"First prompt. Another sentence\"}}"
        ])
    }
    private func scan(_ reads: CatalogCounter = CatalogCounter(), channels: Set<String> = []) -> SessionCatalogScanner.Progress {
        SessionCatalogScanner.scan(roots: ["claude-code": claude, "codex": codex], cacheURL: cache,
            visibility: .init(channelIds: Set(channels.map(identifier))), onRead: { _ in reads.increment() })
    }
    func testHeadersOnlyReadChangedFilesIncludingInodeAndSizeChanges() throws {
        let first = try file("first"), second = try file("second")
        let reads = CatalogCounter()
        XCTAssertEqual(scan(reads).records.count, 2); XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(scan(reads).records.count, 2); XCTAssertEqual(reads.count, 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: first.path)
        let data = try Data(contentsOf: first)
        try data.write(to: first, options: .atomic) // same size and mtime, new inode
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: first.path)
        _ = scan(reads); XCTAssertEqual(reads.count, 3)
        let handle = try FileHandle(forWritingTo: second); try handle.seekToEnd(); try handle.write(contentsOf: Data("\n{}".utf8)); try handle.close()
        _ = scan(reads); XCTAssertEqual(reads.count, 4)
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(scan(reads).records.count, 1); XCTAssertEqual(reads.count, 4)
    }

    func testUnreadableClaudeAndCodexFilesAreRetriedWithUnchangedFingerprints() throws {
        let claudeFile = try file("unreadable")
        let codexFile = try SessionStoreFixtures.writeFile("rollout-unreadable.jsonl", in: codex, lines: [
            #"{"type":"session_meta","payload":{"id":"unreadable-codex","cwd":"/tmp"}}"#
        ])
        let files = [claudeFile, codexFile]
        let fingerprints = files.map { SessionHeaderCache.Fingerprint(file: $0) }
        defer {
            for file in files { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        }
        for file in files {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            XCTAssertThrowsError(try FileHandle(forReadingFrom: file), "Fixture must actually be unreadable")
        }
        let reads = CatalogCounter(), failed = scan(reads)
        XCTAssertEqual(failed.records.count, 0)
        XCTAssertEqual(failed.skipped, 2)
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(SessionHeaderCache.load(cache).headers.isEmpty, "Read failures must not persist fingerprints")
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertEqual(files.map { SessionHeaderCache.Fingerprint(file: $0) }, fingerprints)
        let retried = scan(reads)
        XCTAssertEqual(Set(retried.records.map(\.conversationId)), [identifier("unreadable"), "unreadable-codex"])
        XCTAssertEqual(retried.skipped, 0)
        XCTAssertEqual(reads.count, 4)
        XCTAssertEqual(scan(reads).records.count, 2)
        XCTAssertEqual(reads.count, 4, "Successful reads should be cached normally")
    }

    func testReadableNonSessionsStillCacheNegativeResults() throws {
        _ = try file("sidechain", sidechain: true)
        _ = try SessionStoreFixtures.writeFile("\(identifier("empty")).jsonl", in: claude.appendingPathComponent("project"), lines: [])
        _ = try SessionStoreFixtures.writeFile("rollout-corrupt.jsonl", in: codex, lines: ["not JSON"])
        let reads = CatalogCounter()
        XCTAssertEqual(scan(reads).skipped, 3)
        XCTAssertEqual(reads.count, 3)
        let headers = SessionHeaderCache.load(cache).headers
        XCTAssertEqual(headers.count, 3)
        XCTAssertTrue(headers.values.allSatisfy { $0.record == nil })
        XCTAssertEqual(scan(reads).skipped, 3)
        XCTAssertEqual(reads.count, 3)
    }
    func testAutomaticEntrypointsAndSubagentsChannelsAreExcluded() throws {
        for entry in ["cli", "sdk-cli", "claude-desktop"] { _ = try file(entry, entrypoint: entry) }
        _ = try file("sidechain", sidechain: true); _ = try file("channel")
        for origin in ["codex-tui", "codex_exec", "source-exec"] {
            _ = try SessionStoreFixtures.writeFile("rollout-\(origin).jsonl", in: codex, lines: [
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(origin)\",\"cwd\":\"/tmp/project\",\"originator\":\"\(origin)\",\"source\":\"\(origin == "source-exec" ? "exec" : "cli")\"}}"
            ])
        }
        let result = scan(channels: ["channel"])
        XCTAssertEqual(result.records.count, 6)
        XCTAssertEqual(Set(result.records.filter(\.automatic).map(\.conversationId)), [identifier("sdk-cli"), "codex_exec", "source-exec"])
        XCTAssertFalse(result.records.contains { [identifier("channel"), identifier("sidechain")].contains($0.conversationId) })
        XCTAssertEqual(result.records.first { $0.conversationId == identifier("cli") }?.title, "First prompt")
    }
    func testCorruptOrOldCacheRebuildsWithoutTouchingNames() async throws {
        _ = try file("one")
        let namesURL = root.appendingPathComponent("session-names.sqlite"), names = SessionNamesDatabase(url: root.appendingPathComponent("session-names.sqlite"))
        try await names.set("Keep this", for: .init("claude-code", identifier("one")))
        let before = try Data(contentsOf: namesURL)
        try Data("broken json".utf8).write(to: cache)
        let reads = CatalogCounter(); XCTAssertEqual(scan(reads).records.count, 1); XCTAssertEqual(reads.count, 1)
        var old = SessionHeaderCache.load(cache); old.parseVersion = 1
        for path in old.headers.keys { old.headers[path]?.record = nil }
        try JSONEncoder().encode(old).write(to: cache)
        _ = scan(reads); XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(try Data(contentsOf: namesURL), before)
        let loaded = try await names.load(); XCTAssertEqual(loaded.names[.init("claude-code", identifier("one"))], "Keep this")
    }
    func testVersionThreeCachedFolderTitleIsReparsedFromClaudeTailTitle() throws {
        let file = try SessionStoreFixtures.writeFile("\(identifier("ai-title")).jsonl", in: claude.appendingPathComponent("project"), lines: [
            #"{"type":"user","cwd":"/tmp/project","message":{"content":"<pasted_content>Review the customer follow-up</pasted_content>"}}"#,
            "{\"type\":\"assistant\",\"message\":{\"content\":\"" + String(repeating: "x", count: 300_000) + "\"}}",
            #"{"type":"ai-title","aiTitle":"Customer follow-up"}"#
        ])
        _ = scan()
        var old = SessionHeaderCache.load(cache)
        old.parseVersion = 3
        old.headers[file.path]?.record?.title = "Session in project"
        old.headers[file.path]?.record?.agentTitle = nil
        old.headers[file.path]?.record?.aiTitle = nil
        try JSONEncoder().encode(old).write(to: cache)
        let reads = CatalogCounter(), result = scan(reads)
        XCTAssertEqual(reads.count, 1, "Unchanged transcripts must be reparsed after upgrading the title reader")
        XCTAssertEqual(result.records.first?.title, "Customer follow-up")
        XCTAssertEqual(result.records.first?.agentTitle, "Customer follow-up")
    }

    func testSQLiteStoresReadWALAndAreQueriedOnEveryScan() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let open = root.appendingPathComponent("opencode.db"), kiro = root.appendingPathComponent("kiro.sqlite")
        let queue = try DatabaseQueue(path: open.path), kqueue = try DatabaseQueue(path: kiro.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
            try db.execute(sql: "CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER)")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try kqueue.write { db in try db.execute(sql: "CREATE TABLE conversations_v2 (key TEXT, conversation_id TEXT, value TEXT, created_at INTEGER, updated_at INTEGER)") }
        let roots = [AgentTemplate.opencode.id: open, AgentTemplate.kiro.id: kiro], reads = CatalogCounter()
        func read() -> [AgentSessionRecord] {
            SessionCatalogScanner.scan(roots: roots, cacheURL: cache, visibility: .init(channelIds: []), collect: { store, root in
                reads.increment(); return store.collect(root)
            }).records
        }
        XCTAssertTrue(read().isEmpty)
        let before = try FileManager.default.attributesOfItem(atPath: open.path)[.modificationDate] as? Date
        try queue.write { db in try db.execute(sql: "INSERT INTO session VALUES ('wal-session', '/tmp', 'WAL title', 2000, NULL, NULL)") }
        try kqueue.write { db in try db.execute(sql: "INSERT INTO conversations_v2 VALUES ('/tmp', 'kiro-session', '{\"latest_summary\":\"Kiro title\"}', 1, 2)") }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: open.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(Set(read().map(\.conversationId)), ["wal-session", "kiro-session"])
        XCTAssertEqual(reads.count, 4)
    }
    func testCatalogIsUncappedAndProgressPublishesBeforeCompletion() throws {
        for index in 0..<175 { _ = try file("session-\(index)") }
        let callbacks = CatalogCounter()
        let discovered = CatalogCounter()
        let result = SessionCatalogScanner.scan(roots: ["claude-code": claude], cacheURL: cache, visibility: .init(channelIds: []), progress: { snapshot in
            if snapshot.scanned > 0 && snapshot.scanned < snapshot.total { callbacks.increment() }
            for _ in snapshot.discoveredRecords ?? [] { discovered.increment() }
        })
        XCTAssertEqual(result.records.count, 175); XCTAssertGreaterThan(callbacks.count, 0)
        XCTAssertEqual(discovered.count + (result.discoveredRecords?.count ?? 0), 175,
            "Profile discovery receives each record once across all progress increments")
    }
    func testPreviewReadsOnlyLastThreeMessagesAndNeverIndexesTheirText() throws {
        let file = try file("preview")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let longReply = "private-tail-4 " + String(repeating: "Long response. ", count: 1000)
        for index in 0..<5 {
            let text = index == 4 ? longReply : "private-tail-\(index)"
            try handle.write(contentsOf: Data("\n{\"type\":\"assistant\",\"message\":{\"content\":\"\(text)\"}}".utf8))
        }
        try handle.close()
        let record = try XCTUnwrap(scan().records.first)
        XCTAssertEqual(SessionPreview.read(record).map(\.text), ["private-tail-2", "private-tail-3", longReply.trimmingCharacters(in: .whitespacesAndNewlines)])
        XCTAssertFalse(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains("private-tail"))
        XCTAssertEqual(AllSessionsList.filter(records: [record], live: [], names: [:], query: "private-tail", filters: .init()).shown, 0)
    }
}
