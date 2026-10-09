import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

final class ConversationIndexTests: XCTestCase {
    private final class ScanProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var clock = Date()
        private var sql: [String] = []
        private var sourceRead: (@Sendable () -> Void)?
        var now: Date { lock.withLock { clock } }
        var statements: [String] { lock.withLock { sql } }
        var cleanupPasses: Int { statements.filter { $0.hasPrefix("DELETE FROM turns WHERE NOT EXISTS") }.count }
        var configuration: Configuration {
            var config = Configuration()
            config.prepareDatabase { [self] db in db.trace { self.record("\($0)") } }
            return config
        }
        func nextPass(onSourceRead: (@Sendable () -> Void)? = nil) {
            lock.withLock { clock += 31; sql = []; sourceRead = onSourceRead }
        }
        private func record(_ statement: String) {
            let callback = lock.withLock {
                sql.append(statement)
                return statement.hasPrefix("SELECT stamp,record,partial,skipped,available FROM sources") ? sourceRead : nil
            }
            callback?()
        }
    }
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private var claude: URL { root.appendingPathComponent("claude") }
    private var codex: URL { root.appendingPathComponent("codex") }
    private var directory: URL { root.appendingPathComponent("support/search") }
    private func index(denied: Set<String> = [], budget: Int64 = 1_073_741_824, probe: ScanProbe? = nil) -> ConversationIndex {
        ConversationIndex(directory: directory, roots: ["claude-code": claude, "codex": codex], budget: budget, throttled: false,
                          configuration: probe?.configuration ?? Configuration(), now: { probe?.now ?? Date() },
                          visibility: { .init(channelIds: denied) })
    }
    private func line(_ id: String, _ text: String, role: String = "user", date: String? = "2026-10-09T12:00:00Z", extra: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = ["type": role, "uuid": id, "cwd": "/tmp/project", "message": ["content": text]]
        if let date { value["timestamp"] = date }
        value.merge(extra) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func file(_ lines: [String], id: String = UUID().uuidString.lowercased()) throws -> URL {
        try SessionStoreFixtures.writeFile(id + ".jsonl", in: claude.appendingPathComponent("project"), lines: lines)
    }
    private func hits(_ index: ConversationIndex, _ query: String) async throws -> [LocalSearchHit] {
        try await index.search(SearchQuery(query)).hits
    }
    func testOptInOffClearRebuildAndRestart() async throws {
        let source = try file([line("one", "private release checklist")]), index = index()
        await index.refresh(force: true)
        let before = try await hits(index, "release"); XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let enumerated = try ConversationSource.enumerate(["claude-code": claude])
        XCTAssertEqual(enumerated.count, 1, "source enumeration")
        let parsed = try await ConversationSource.read(.init(agent: "claude-code", url: source, root: claude), visibility: .init(channelIds: []), throttled: false)
        XCTAssertEqual(parsed?.turns.count, 1, "parsed source")
        try await index.enable(); await index.refresh(force: true)
        let state = await index.snapshot(); XCTAssertNil(state.error); XCTAssertEqual(state.processed, 1); XCTAssertEqual(state.skipped, 0)
        let found = try await hits(index, "release"); XCTAssertEqual(found.count, 1)
        try await index.disable()
        let off = try await hits(index, "release"); XCTAssertTrue(off.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try await index.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        do { try await index.enable(); XCTFail("Clear requires Rebuild") } catch { XCTAssertEqual(error as? SearchProblem, .rebuildRequired) }
        let restarted = self.index(); await restarted.refresh(force: true)
        let status = await restarted.snapshot(); XCTAssertTrue(status.state.cleared)
        try await restarted.enable(rebuild: true); await restarted.refresh(force: true)
        let rebuilt = try await hits(restarted, "release"); XCTAssertEqual(rebuilt.count, 1)
    }
    func testFullTextBeyondHeadAndANDWithinTurnAndExcludedBlocks() async throws {
        let noise = try line("noise", String(repeating: "x", count: 300_000), role: "tool")
        _ = try file([line("first", "first prompt"), noise, line("a", "Привет release"), line("b", "checklist alone"),
            line("c", "ПРИВЕТ release checklist", role: "assistant"),
            line("tool", "", role: "assistant", extra: ["message": ["content": [["type": "tool_use", "input": "secrettool"], ["type": "thinking", "thinking": "secretthought"], ["type": "text", "text": "visible code"]]]]),
            line("summary", "secretsummary", extra: ["isCompactSummary": true])])
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let match = try await hits(index, "привет checklist"); XCTAssertEqual(match.map(\.turn.id), ["c"])
        for text in ["secrettool", "secretthought", "secretsummary", "check"] { let result = try await hits(index, text); XCTAssertTrue(result.isEmpty) }
        let context = try await index.context(try XCTUnwrap(match.first)); XCTAssertTrue(context.contains { $0.id == "c" })
    }
    func testAppendIncompleteTailRewriteSameSizeTimestampAndDeletion() async throws {
        let source = try file([line("one", "oldword")]), index = index()
        try await index.enable(); await index.refresh(force: true)
        let initial = try await hits(index, "oldword"); let old = try XCTUnwrap(initial.first)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        var contents = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "oldword", with: "newword")
        try contents.write(to: source, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: source.path)
        await index.refresh(force: true)
        let oldHits = try await hits(index, "oldword"); XCTAssertTrue(oldHits.isEmpty)
        do { _ = try await index.context(old); XCTFail("Stale turn must not open") } catch {}
        contents += "\n" + (try line("two", "tailword")) + "\n{\"type\":\"user\",\"message\":"
        try contents.write(to: source, atomically: false, encoding: .utf8); await index.refresh(force: true)
        let tail = try await hits(index, "tailword"); XCTAssertEqual(tail.count, 1)
        let partial = await index.snapshot(); XCTAssertTrue(partial.partial)
        try FileManager.default.removeItem(at: source); await index.refresh(force: true)
        let deleted = try await hits(index, "newword"); XCTAssertTrue(deleted.isEmpty)
    }
    func testCodexDeduplicatesEventsAndResponsesWithoutMergingRepeatedTurns() async throws {
        _ = try SessionStoreFixtures.writeFile("rollout-test.jsonl", in: codex, lines: [
            #"{"type":"session_meta","payload":{"id":"codex-one","cwd":"/tmp/project"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"secretdev"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"repeatword"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"repeatword"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"repeatword"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"repeatword"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answerword"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"answerword"}}"#])
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let repeated = try await hits(index, "repeatword"), answer = try await hits(index, "answerword"), dev = try await hits(index, "secretdev")
        XCTAssertEqual(repeated.count, 2); XCTAssertEqual(answer.count, 1); XCTAssertTrue(dev.isEmpty)
    }
    func testAllSourcesBeyond150AndStableKeyset() async throws {
        for i in 0..<152 { _ = try file([line("turn", "commonword \(i)")]) }
        let index = index(); try await index.enable(); await index.refresh(force: true)
        var ids = Set<String>(), cursor: LocalSearchCursor?
        repeat {
            let page = try await index.search(SearchQuery("commonword"), cursor: cursor, limit: 20)
            for hit in page.hits { XCTAssertTrue(ids.insert(hit.id).inserted) }
            cursor = page.next
        } while cursor != nil
        XCTAssertEqual(ids.count, 152)
        let first = try await index.search(SearchQuery("commonword"))
        do { _ = try await index.search(SearchQuery("different"), cursor: first.next); XCTFail() } catch { XCTAssertEqual(error as? SearchProblem, .invalidCursor) }
        try await index.clear(); try await index.enable(rebuild: true)
        do { _ = try await index.search(SearchQuery("commonword"), cursor: first.next); XCTFail() } catch { XCTAssertEqual(error as? SearchProblem, .invalidCursor) }
    }
    func testVisibilitySidechainsAndSymlinksAreExcluded() async throws {
        let denied = UUID().uuidString.lowercased()
        _ = try file([line("hidden", "hiddenword")], id: denied)
        _ = try file([line("side", "hiddenword", extra: ["isSidechain": true])])
        let visible = try file([line("ordinary", "visibleword")])
        try FileManager.default.createSymbolicLink(at: visible.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jsonl"), withDestinationURL: visible)
        let index = index(denied: [denied]); try await index.enable(); await index.refresh(force: true)
        let hidden = try await hits(index, "hiddenword"), found = try await hits(index, "visibleword")
        XCTAssertTrue(hidden.isEmpty); XCTAssertEqual(found.count, 1)
    }
    func testDateFolderUnknownTimeAndDST() async throws {
        _ = try file([line("dated", "calendarword"), line("undated", "calendarword", date: nil)])
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let page = try await index.search(SearchQuery("calendarword"), filter: .init(folder: "/tmp/project", from: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(page.hits.map(\.turn.id), ["dated"])
        let other = try await index.search(SearchQuery("calendarword"), filter: .init(folder: "/different/project")); XCTAssertTrue(other.hits.isEmpty)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        let range = LocalSearchFilter.dayRange(day, day, calendar: calendar)
        XCTAssertEqual(range.1.timeIntervalSince(range.0), 23 * 3600)
    }
    func testPauseAndClearDuringWorkCannotResurrectIndex() async throws {
        for _ in 0..<10 { _ = try file([line("turn", String(repeating: "word ", count: 15_000))]) }
        let index = index(); try await index.enable()
        let work = Task { await index.refresh(force: true) }
        await Task.yield(); try await index.clear(); await work.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let status = await index.snapshot(); XCTAssertFalse(status.state.enabled)
        try await index.enable(rebuild: true); try await index.pause(true); await index.refresh(force: true)
        let paused = await index.snapshot(); XCTAssertTrue(paused.state.paused); XCTAssertEqual(paused.processed, 0)
    }
    func testPauseSurvivesRestartAndKeepsExistingTextSearchable() async throws {
        _ = try file([line("saved", "pauseword")])
        let index = index(); try await index.enable(); await index.refresh(force: true); try await index.pause(true)
        let restarted = self.index()
        let paused = await restarted.snapshot()
        XCTAssertTrue(paused.state.paused); XCTAssertTrue(paused.label.contains("Partial results"))
        let found = try await hits(restarted, "pauseword"); XCTAssertEqual(found.count, 1)
        try await restarted.clear()
    }
    func testPermissionsAndExecutorFolderProtectionBeforeCreation() async throws {
        let home = root.appendingPathComponent("home"), search = home.appendingPathComponent("Library/Application Support/agentpad/search")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: search)
        for path in [search, search.deletingLastPathComponent(), search.appendingPathComponent("child"), alias] {
            XCTAssertThrowsError(try ChatAttachmentStorage.checkFolders([path.path], data: root.appendingPathComponent("chat"), temporary: root.appendingPathComponent("tmp"), home: home))
        }
        _ = try file([line("one", "permissions")]); let index = index(); try await index.enable(); await index.refresh(force: true)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        }
    }
    func testLiteralQueryLimits() throws {
        XCTAssertEqual(try SearchQuery("hello OR world").match, "\"hello\" AND \"OR\" AND \"world\"")
        for query in ["", "***", String(repeating: "Ж", count: 257), Array(repeating: "word", count: 33).joined(separator: " ")] {
            XCTAssertThrowsError(try SearchQuery(query))
        }
    }
    func testFailedSourceTransactionLeavesNoOrphansAndCleansPreviousLeftovers() async throws {
        let probe = ScanProbe(), index = index(probe: probe); try await index.enable()
        _ = try await hits(index, "word") // Create schema before installing a deterministic write failure.
        XCTAssertEqual(probe.cleanupPasses, 1, "Opening the database cleans interrupted generations")
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path)
        defer { try? db.close() }
        try SearchCache.write(db) { db in
            try db.execute(sql: """
                INSERT INTO turns(path,generation,agent,conversation,turn,role,text,time,ordinal,offset,truncated,folder)
                VALUES('leftover','interrupted','claude-code','old','old','user','orphanword',0,1,0,0,'/tmp');
                CREATE TRIGGER fail_source BEFORE INSERT ON turns WHEN new.turn='turn-250'
                BEGIN SELECT RAISE(ABORT, 'interrupted source'); END;
                """)
        }
        _ = try file((0..<400).map { try line("turn-\($0)", "word \($0)") })
        probe.nextPass()
        await index.refresh(force: true)
        XCTAssertEqual(probe.cleanupPasses, 1, "A failed atomic replacement needs no extra cleanup")
        let orphans = try SearchCache.read(db) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM turns WHERE NOT EXISTS (SELECT 1 FROM sources s WHERE s.path=turns.path AND s.generation=turns.generation)") }
        XCTAssertEqual(orphans, 0, "Cleanup must run before the pass, and failed source writes must roll back together")
        try SearchCache.write(db) { try $0.execute(sql: "DROP TRIGGER fail_source") }
        await index.refresh(force: true)
        let found = try await hits(index, "word"); XCTAssertEqual(found.count, 20)
    }
    func testAppendDuringReadPublishesCapturedPrefix() async throws {
        let source = try file([line("one", "oldword"), line("noise", String(repeating: "x", count: 200_000), role: "tool")])
        let sourceRoot = claude
        let task = Task { try await ConversationSource.read(.init(agent: "claude-code", url: source, root: sourceRoot), visibility: .init(channelIds: []), throttled: true) }
        try await Task.sleep(for: .milliseconds(30))
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + (try line("two", "newword")) + "\n").utf8)); try handle.close()
        let snapshot = try await task.value
        XCTAssertEqual(snapshot?.turns.map(\.id), ["one"], "An append must not discard the captured prefix")
    }
    func testFullDuringReplacementKeepsPreviousSourceAndRollsBackEveryTurn() async throws {
        let source = try file([line("saved", "savedword")]), index = index(budget: 16 * 1_024 * 1_024)
        try await index.enable(); await index.refresh(force: true)
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path)
        defer { try? db.close() }
        try SearchCache.write(db) { db in
            try db.execute(sql: """
                CREATE TABLE scratch(bytes BLOB);
                CREATE TRIGGER fill_source BEFORE INSERT ON turns WHEN new.turn='turn-250'
                BEGIN INSERT INTO scratch VALUES(zeroblob(6000000)); END;
                """)
        }
        try (0..<400).map { try line("turn-\($0)", "newword") }.joined(separator: "\n").write(to: source, atomically: false, encoding: .utf8)
        await index.refresh(force: true)
        let status = await index.snapshot(); XCTAssertEqual(status.error, SearchProblem.sizeLimit.localizedDescription)
        let saved = try await hits(index, "savedword"); XCTAssertEqual(saved.count, 1)
        let count = try SearchCache.read(db) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM turns") }
        XCTAssertEqual(count, 1)
        try SearchCache.write(db) { try $0.execute(sql: "DROP TRIGGER fill_source") }
        await index.refresh(force: true)
        let recovered = await index.snapshot(); XCTAssertNil(recovered.error)
        let replaced = try await hits(index, "newword"); XCTAssertEqual(replaced.count, 20)
    }
    func testStartupCleanupCanAllocatePastTheIndexPageCap() async throws {
        let first = index(); try await first.enable(); _ = try await hits(first, "word"); try await first.disable()
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path)
        defer { try? db.close() }
        try SearchCache.write(db) { db in
            try db.execute(sql: """
                INSERT INTO turns(path,generation,agent,conversation,turn,role,text,time,ordinal,offset,truncated,folder)
                VALUES('leftover','interrupted','claude-code','old','old','user','orphanword',0,1,0,0,'/tmp');
                CREATE TABLE cleanup_scratch(bytes BLOB);
                CREATE TRIGGER cleanup_space AFTER DELETE ON turns
                BEGIN INSERT INTO cleanup_scratch VALUES(zeroblob(2000000)); DELETE FROM cleanup_scratch; END;
                """)
        }
        // FTS deletion can allocate pages before old pages become reusable.
        // This trigger makes that requirement deterministic at a small cap.
        let restarted = index(budget: 1_048_576); try await restarted.enable()
        _ = try await hits(restarted, "word")
        let count = try SearchCache.read(db) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM turns") }
        XCTAssertEqual(count, 0)
    }
    func testStoredCheckpointSurvivesRestartAndDeduplicatesSplitCodexPair() async throws {
        let source = try SessionStoreFixtures.writeFile("rollout-checkpoint.jsonl", in: codex, lines: [
            #"{"type":"session_meta","payload":{"id":"checkpoint","cwd":"/project"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"pairedword"}}"#])
        let first = index(); try await first.enable(); await first.refresh(force: true)
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path)
        defer { try? db.close() }
        let generation = try SearchCache.read(db) { try String.fetchOne($0, sql: "SELECT generation FROM sources") }
        try await first.disable()
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"pairedword"}]}}"# + "\n").utf8)); try handle.close()
        let restarted = index(); try await restarted.enable(); await restarted.refresh(force: true)
        let current = try SearchCache.read(db) { try String.fetchOne($0, sql: "SELECT generation FROM sources") }
        XCTAssertEqual(current, generation, "Append must use the persisted parser checkpoint, including its pending Codex pair")
        let paired = try await hits(restarted, "pairedword"); XCTAssertEqual(paired.count, 1)
    }
    func testAppendResumesAtCheckpointAndReparsesOnlyOnNonAppendChange() async throws {
        let source = try file([line("one", "firstword")])
        let file = ConversationSource.File(agent: "claude-code", url: source, root: claude)
        let firstValue = try await ConversationSource.read(file, visibility: .init(channelIds: []), throttled: false)
        let first = try XCTUnwrap(firstValue)
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + (try line("two", "secondword")) + "\n{\"unfinished\":").utf8)); try handle.close()
        let appendedValue = try await ConversationSource.read(file, visibility: .init(channelIds: []), throttled: false, previous: first)
        let appended = try XCTUnwrap(appendedValue)
        XCTAssertEqual(appended.resumedFrom, first.checkpoint)
        XCTAssertEqual(appended.turns.map(\.id), ["one", "two"])
        XCTAssertTrue(appended.partial)
        let contents = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "firstword", with: "otherword")
        try contents.write(to: source, atomically: false, encoding: .utf8)
        let rewrittenValue = try await ConversationSource.read(file, visibility: .init(channelIds: []), throttled: false, previous: appended)
        let rewritten = try XCTUnwrap(rewrittenValue)
        XCTAssertEqual(rewritten.resumedFrom, 0); XCTAssertEqual(rewritten.turns.first?.text, "otherword")
        try Data(contents.utf8).write(to: source, options: .atomic)
        let rotatedValue = try await ConversationSource.read(file, visibility: .init(channelIds: []), throttled: false, previous: rewritten)
        let rotated = try XCTUnwrap(rotatedValue)
        XCTAssertEqual(rotated.resumedFrom, 0)
        try (try line("one", "shortword")).write(to: source, atomically: false, encoding: .utf8)
        let truncatedValue = try await ConversationSource.read(file, visibility: .init(channelIds: []), throttled: false, previous: rotated)
        let truncated = try XCTUnwrap(truncatedValue)
        XCTAssertEqual(truncated.resumedFrom, 0); XCTAssertEqual(truncated.turns.map(\.text), ["shortword"])
    }
    func testOffsetTurnNavigationSurvivesAppendButRejectsChangedPrefix() async throws {
        let meta = #"{"type":"session_meta","payload":{"id":"codex-one","cwd":"/tmp/project"}}"#
        let event = #"{"type":"event_msg","payload":{"type":"user_message","message":"offsetword"}}"#
        let source = try SessionStoreFixtures.writeFile("rollout-offset.jsonl", in: codex, lines: [meta, event])
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let found = try await hits(index, "offsetword"), hit = try XCTUnwrap(found.first)
        let original = try Data(contentsOf: source)
        let handle = try FileHandle(forWritingTo: source); try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"service\"}\n".utf8)); try handle.close()
        let visible = try await hits(index, "offsetword")
        XCTAssertEqual(visible.count, 1, "Keep published rows visible until replacement commits")
        let beforeRefresh = try await index.context(hit); XCTAssertEqual(beforeRefresh.first?.id, hit.turn.id)
        await index.refresh(force: true)
        let afterRefresh = try await index.context(hit); XCTAssertEqual(afterRefresh.first?.id, hit.turn.id)
        let changed = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "/tmp/project", with: "/tmp/PROJECT")
        try changed.write(to: source, atomically: false, encoding: .utf8)
        do { _ = try await index.context(hit); XCTFail("Same turn at same offset is invalid after an earlier prefix changes") } catch { XCTAssertEqual(error as? SearchProblem, .changed) }
    }
    func testCopiedConversationUsesNewestFileAndAssistantSnapshotsReplaceText() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try file([line("u", "olderword")], id: id)
        let snapshot1 = try line("stream1", "", role: "assistant", extra: ["message": ["id": "native", "content": [["type": "text", "text": "oldanswer"]]]])
        let snapshot2 = try line("stream2", "", role: "assistant", extra: ["message": ["id": "native", "content": [["type": "text", "text": "newanswer"]]]])
        _ = try SessionStoreFixtures.writeFile(id + ".jsonl", in: claude.appendingPathComponent("newest"), lines: [snapshot1, snapshot2], mtime: Date().addingTimeInterval(100))
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let old = try await hits(index, "olderword"), replaced = try await hits(index, "oldanswer"), current = try await hits(index, "newanswer")
        XCTAssertTrue(old.isEmpty); XCTAssertTrue(replaced.isEmpty); XCTAssertEqual(current.count, 1)
    }
    func testMissingRootHidesButDoesNotDeleteItsSourceAndBudgetStopsWrites() async throws {
        _ = try file([line("one", "retainedword")]); let index = index()
        try await index.enable(); await index.refresh(force: true)
        let initial = await index.snapshot()
        let moved = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: claude, to: moved); await index.refresh(force: true)
        let missing = await index.snapshot(); XCTAssertGreaterThan(missing.revision, initial.revision)
        let unavailable = try await hits(index, "retainedword"); XCTAssertTrue(unavailable.isEmpty)
        var config = Configuration(); config.readonly = true
        let db = try DatabaseQueue(path: directory.appendingPathComponent("conversations.sqlite").path, configuration: config)
        let count = try SearchCache.read(db) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sources") }
        XCTAssertEqual(count, 1); try db.close()
        try FileManager.default.moveItem(at: moved, to: claude); await index.refresh(force: true)
        let restoredStatus = await index.snapshot(); XCTAssertGreaterThan(restoredStatus.revision, missing.revision)
        let restored = try await hits(index, "retainedword"); XCTAssertEqual(restored.count, 1)
        try await index.clear()
        let bounded = self.index(budget: 1_048_576); try await bounded.enable(rebuild: true); await bounded.refresh(force: true)
        let status = await bounded.snapshot(); XCTAssertTrue(status.partial); XCTAssertEqual(status.error, SearchProblem.sizeLimit.localizedDescription)
    }
    func testUnchangedVerificationKeepsResultRevisionAndTruncationPreservesUTF8() async throws {
        _ = try file([line("large", String(repeating: "a", count: 65_533) + "🛠tail")])
        let files = try ConversationSource.enumerate(["claude-code": claude])
        let parsed = try await ConversationSource.read(try XCTUnwrap(files.first), visibility: .init(channelIds: []), throttled: false)
        let turn = try XCTUnwrap(parsed?.turns.first)
        XCTAssertTrue(turn.truncated); XCTAssertEqual(turn.text.utf8.count, 65_533); XCTAssertFalse(turn.text.contains("�"))
        let index = index(); try await index.enable(); await index.refresh(force: true)
        let before = await index.snapshot(); await index.refresh(force: true); let after = await index.snapshot()
        XCTAssertEqual(before.revision, after.revision, "Unchanged verification must preserve loaded pages")
    }
    func testUnchangedScanCleansOnceAndSkipsTurnReads() async throws {
        let count = 24
        for _ in 0..<count { _ = try file([line("turn", "cachedword")]) }
        let probe = ScanProbe(), index = index(probe: probe)
        try await index.enable(); await index.refresh(force: true)
        XCTAssertEqual(probe.cleanupPasses, 2, "One cleanup on open and one for the scan pass")
        let before = await index.snapshot()
        probe.nextPass()
        await index.refresh()
        let after = await index.snapshot()
        XCTAssertNil(after.error); XCTAssertEqual(after.processed, count); XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(probe.cleanupPasses, 1)
        XCTAssertEqual(probe.statements.filter { $0.contains("FROM turns") }.count, 1, "Only the pass cleanup may touch turns for unchanged files")
        XCTAssertEqual(probe.statements.filter { $0.hasPrefix("SELECT stamp,record,partial,skipped,available FROM sources") }.count, count)
        probe.nextPass()
        await index.refresh(force: true)
        XCTAssertEqual(probe.cleanupPasses, 1, "Content verification also cleans only once per pass")
    }
    func testUnchangedScanYieldsToStatusAndPauseBetweenFiles() async throws {
        let count = 128
        for _ in 0..<count { _ = try file([line("turn", "cachedword")]) }
        let probe = ScanProbe(), index = index(probe: probe)
        try await index.enable(); await index.refresh(force: true)
        let (reads, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        probe.nextPass { continuation.yield(()) }
        let pause = Task(priority: .high) { () throws -> SearchIndexStatus? in
            for await _ in reads {
                let during = await index.snapshot()
                try await index.pause(true)
                return during
            }
            return nil
        }
        await index.refresh()
        continuation.finish()
        let observed = try await pause.value
        let during = try XCTUnwrap(observed)
        XCTAssertTrue(during.scanning); XCTAssertLessThan(during.processed, count)
        let after = await index.snapshot()
        XCTAssertTrue(after.state.paused); XCTAssertFalse(after.scanning); XCTAssertLessThan(after.processed, count)
        XCTAssertEqual(probe.cleanupPasses, 1)
    }
}
