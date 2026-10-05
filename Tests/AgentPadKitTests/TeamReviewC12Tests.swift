import GRDB
import XCTest
@testable import AgentPadKit

/// Twelfth client review (review-client-c12.md).
@MainActor
final class TeamReviewC12Tests: XCTestCase {
    private var root: URL!

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c12-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChatStubProtocol.reset()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        TeamRunAdmission.journalBlocks = { _ in false }
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("svc").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// C12-1: a journal whose folder cannot be looked into blocks every run.
    func testJournalThatCannotBeLookedAtBlocks() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("svc").appendingPathComponent("chat"))
        try files.prepareDirectory()
        let service = ChatService(files: files, tokens: FakeTokenStore())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("svc").path)
        await service.recoverRunsAtLaunch()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("svc").path)
        XCTAssertNotNil(service.journalProblem)
        XCTAssertTrue(TeamRunAdmission.journalBlocks("any"))
        // No journal for sure: agents may start.
        let empty = ChatService(files: ChatFiles(directory: root.appendingPathComponent("none")), tokens: FakeTokenStore())
        await empty.recoverRunsAtLaunch()
        XCTAssertFalse(TeamRunAdmission.journalBlocks("any"))
    }

    /// C12-4: an unknown newer file with an unfinished transaction beside it
    /// is refused and left exactly as it was.
    func testNewerFileWithAHotJournalIsNotTouched() throws {
        let files = ChatFiles(directory: root.appendingPathComponent("hot"))
        try files.prepareDirectory()
        let url = files.journalURL
        let made = try DatabaseQueue(path: url.path)
        try made.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('release-1'), ('release-99')")
        }
        try made.close()
        let committed = try Data(contentsOf: url)
        // A crash in the middle of a transaction: the files copied while it is open.
        let crashed = root.appendingPathComponent("crashed.db")
        let writer = try DatabaseQueue(path: url.path)
        try writer.inDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = 1")
            try db.execute(sql: "PRAGMA cache_spill = 1")
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "CREATE TABLE junk (b BLOB)")
            for _ in 0..<60 { try db.execute(sql: "INSERT INTO junk VALUES (zeroblob(200000))") }
            XCTAssertNotEqual(try Data(contentsOf: url), committed, "pages of the transaction are in the file: its journal is hot")
            try FileManager.default.copyItem(atPath: url.path, toPath: crashed.path)
            try FileManager.default.copyItem(atPath: url.path + "-journal", toPath: crashed.path + "-journal")
            try db.execute(sql: "ROLLBACK")
        }
        try writer.close()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: crashed, to: url)
        try FileManager.default.copyItem(atPath: crashed.path + "-journal", toPath: url.path + "-journal")
        let before = (try Data(contentsOf: url), try Data(contentsOf: URL(fileURLWithPath: url.path + "-journal")))
        XCTAssertThrowsError(try ChatJournal.open(files: files)) { XCTAssertEqual($0 as? ChatStoreError, .tooNew) }
        XCTAssertEqual(try Data(contentsOf: url), before.0, "the file is as it was")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + "-journal")), before.1, "and its journal too")
    }

    /// C12-5: the connection's state and an organization's cache problem are
    /// lines of the Team window, with or without a queue.
    func testConnectionAndCacheProblemsAreShown() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("p"))
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        let server = try ChatServerAddress(parsing: "https://chat.example.com")
        try service.saveSignIn(ChatConnection(server: server, accountId: "acc", sessionId: "s", deviceName: "Mac", orgId: "org"),
                               token: "aps_t")
        tokens.failure = .keychain("locked")
        try await service.start(mode: .server)
        guard case .needsSignIn = service.state else { return XCTFail("\(service.state)") }
        XCTAssertFalse(service.problems.isEmpty, "the token that cannot be read is said")

        // A damaged cache made anew: the lost commands are said, and dismissed.
        let key = ChatOrgKey(server: server, accountId: "acc", orgId: "org")
        try files.prepareDirectory()
        try Data("not a database".utf8).write(to: files.cacheURL(key))
        let session = service.session(for: key)
        XCTAssertNotNil(session.problem)
        XCTAssertTrue(service.problems.contains(try XCTUnwrap(session.problem)))
        XCTAssertTrue(service.hasRefused)
        service.dismissRefused()
        XCTAssertNil(session.problem)
    }

    /// C12-6: the list of left-overs follows the registry.
    func testLeftOverListFollowsTheRegistry() async throws {
        let leader = TeamProcessStart(pid: 999_950, pgid: 999_950, startTime: 1)
        TeamProcesses.shared.add(leader, agentId: "agent-q")
        defer { TeamProcesses.shared.remove(leader) }
        TeamProcesses.shared.markLeftOver(leader)
        try await waitUntil { TeamLeftOversModel.shared.items.map(\.leader).contains(leader) }
        XCTAssertNil(TeamProcesses.shared.confirmGone(leader))
        try await waitUntil { !TeamLeftOversModel.shared.items.map(\.leader).contains(leader) }
    }
}
