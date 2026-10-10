import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatStoreTests: XCTestCase {
    private var root: URL!
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let anna = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root) }

    private func key(server: String = "https://chat.example.com", account: String? = nil) throws -> ChatOrgKey {
        ChatOrgKey(server: try ChatServerAddress(parsing: server), accountId: account ?? anna, orgId: org)
    }

    private func open() throws -> ChatStore {
        try ChatStore.open(files: files, key: try key()).store
    }

    func testDMAttachmentUpgradeRetainsLegacyChannelDraftAndRequiresOneOwner() throws {
        let cache = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(cache, upTo: "release-26-dm-peer-lookup")
        let channel = UUID().uuidString.lowercased()
        let file = ChatAttachment(attachmentId: UUID().uuidString.lowercased(), position: 0,
                                  name: "saved.txt", mime: "text/plain", size: 5, hasPreview: false)
        var draft = ChatAttachmentDraft(file: file, messageId: UUID().uuidString.lowercased(), channel: channel,
            root: "", session: "old-session", generation: "g1", sha256: ChatAttachments.digest(Data("saved".utf8)),
            createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), state: .ready)
        draft.queued = true
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        legacy["owner"] = nil; legacy["channel"] = channel
        let json = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
        try cache.write {
            try $0.execute(sql: "INSERT INTO attachment_drafts (attachment_id, channel_id, thread_root_id, body) VALUES (?, ?, '', ?)", arguments: [file.id, channel, json])
        }
        try ChatStoreMigrations.cache.migrate(cache)
        try cache.read { db in
            XCTAssertEqual(try ChatAttachments.drafts(db, includingQueued: true), [draft])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT channel_id FROM attachment_drafts"), channel)
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT dm_id FROM attachment_drafts"))
        }
        try cache.write { db in
            XCTAssertThrowsError(try db.execute(sql: "UPDATE attachment_drafts SET dm_id = ?", arguments: [channel]))
            XCTAssertThrowsError(try db.execute(sql: "UPDATE attachment_drafts SET channel_id = NULL"))
        }
    }

    func testMergedSchemasMigrateCleanDatabasesAndReopen() throws {
        let cache = try DatabaseQueue()
        let journal = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(cache)
        try ChatStoreMigrations.journal.migrate(journal)
        try ChatStoreMigrations.cache.migrate(cache)
        try ChatStoreMigrations.journal.migrate(journal)
        try cache.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                           (1...11).map { "release-\($0)" } + ["release-12-ux1", "release-13-ux1-review", "release-14-ux2-thread-read-floor", "release-15-ux2-draft-options", "release-16-conversation-read-marks", "release-17-b1", "release-18-b1-review", "release-19-chat-reply-heads", "release-20-pin-preferences", "release-21-attachments", "release-22-attachment-access", "release-23-attachment-retention", "release-24-composition-drafts", "release-25-direct-messages", "release-26-dm-peer-lookup", "release-27-dm-attachments"])
            for table in ["requests", "agent_channels", "request_contents", "publication_intents", "my_threads", "channel_sends", "channel_call_intents", "session_posts", "thread_read_marks", "attachment_access_versions", "composition_drafts"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
        }
        try journal.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                           (1...9).map { "release-\($0)" } + ["release-10-ux1", "release-11-notification-diagnostics"])
            for table in ["channel_authorities", "publication_surfaces", "automatic_request_blocks"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
            let columns = Set(try db.columns(in: "runs").map(\.name))
            for column in ["stop_confirmed_at", "preflight_pid", "preflight_pgid", "preflight_started_at",
                           "kind", "org", "channel_id", "thread_root_id", "result_erased", "channel_revoked"] {
                XCTAssertTrue(columns.contains(column), column)
            }
        }
    }

    private var stream: String { "org:\(org)" }

    private func event(_ seq: Int, _ type: String, _ body: [String: ChatJSON]) -> ChatEvent {
        ChatEvent(stream: stream, seq: seq, id: UUID().uuidString, type: type, actor: nil, body: .object(body),
                  commandId: nil, at: "2026-10-03T18:20:00Z")
    }

    private func joined(_ seq: Int, name: String = "anna") -> ChatEvent {
        event(seq, "member.joined", ["account_id": .string(anna), "handle": .string("anna"), "name": .string(name), "role": .string("owner")])
    }

    private func names(_ store: ChatStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM members ORDER BY account_id") }
    }

    /// Anna manages the organization and follows its admin stream: only a
    /// manager's cache holds what that stream brings (`ChatStore.narrow`).
    private func managing(_ store: ChatStore) throws {
        try store.apply(ChatSnapshot(cursors: ["org-admin:\(org)": 0],
                                     members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")]))
    }

    private func command(_ id: String = UUID().uuidString, body: String = #"{"type":"member.set_name"}"#) -> ChatCommandRecord {
        ChatCommandRecord(commandId: id, sessionId: "s1", type: "member.set_name", bodyBytes: Data(body.utf8),
                          orderKey: org, dependsOn: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000), state: .pending)
    }

    /// The admin stream's invitation events keep the cache's open
    /// invitations as the snapshot has them: made or replaced, then gone once
    /// accepted or revoked (docs/api.md, stage A events).
    func testInvitationEventsKeepTheOpenInvitations() throws {
        let store = try open()
        try managing(store)
        let admin = "org-admin:\(org)"
        func adminEvent(_ seq: Int, _ type: String, _ body: [String: ChatJSON]) -> ChatEvent {
            ChatEvent(stream: admin, seq: seq, id: UUID().uuidString, type: type, actor: nil, body: .object(body),
                      commandId: nil, at: "2026-10-03T18:20:00Z")
        }
        func openInvitations() throws -> [String: String] {
            try store.queue.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT invitation_id, role FROM invitations WHERE state = 'open'")
                    .map { ($0["invitation_id"], $0["role"]) })
            }
        }
        let made: [String: ChatJSON] = ["invitation_id": .string("i1"), "email": .string("b@example.com"), "role": .string("member"),
                                        "expires_at": .string("2026-10-11T00:00:00Z")]
        XCTAssertEqual(try store.apply(adminEvent(1, "invitation.create", made)), .applied)
        var replaced = made
        replaced["role"] = .string("admin")
        XCTAssertEqual(try store.apply(adminEvent(2, "invitation.create", replaced)), .applied)
        XCTAssertEqual(try store.apply(adminEvent(3, "invitation.create", ["invitation_id": .string("i2"), "email": .string("c@example.com"),
                                                                           "role": .string("member")])), .applied)
        XCTAssertEqual(try openInvitations(), ["i1": "admin", "i2": "member"])
        XCTAssertEqual(try store.apply(adminEvent(4, "invitation.accept", ["invitation_id": .string("i1"), "account_id": .string(anna)])), .applied)
        XCTAssertEqual(try store.apply(adminEvent(5, "invitation.revoke", ["invitation_id": .string("i2")])), .applied)
        XCTAssertEqual(try openInvitations(), [:])
        XCTAssertEqual(try store.cursor(admin), 5)
    }

    /// C19-1: past its term an invitation is not open, by snapshot or by
    /// events alike; inviting the address again (same id, new term) opens it
    /// again on both ways.
    func testSnapshotAndEventsAgreeOnExpiredInvitations() throws {
        let admin = "org-admin:\(org)"
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let past = "2026-09-01T00:00:00.123456Z", future = "2026-10-20T00:00:00Z"
        func created(_ seq: Int, _ id: String, expires: String) -> ChatEvent {
            ChatEvent(stream: admin, seq: seq, id: UUID().uuidString, type: "invitation.create", actor: nil,
                      body: .object(["invitation_id": .string(id), "email": .string("\(id)@example.com"), "role": .string("member"),
                                     "expires_at": .string(expires)]),
                      commandId: nil, at: "2026-10-03T18:20:00Z")
        }
        let byEvents = try open()
        let bySnapshot = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("snap")), key: try key()).store
        try managing(byEvents)
        try managing(bySnapshot)
        func snapshot(_ items: [(String, String)]) throws {
            try bySnapshot.apply(ChatSnapshot(cursors: [:], invitations: items.map {
                .init(invitationId: $0.0, email: "\($0.0)@example.com", role: "member", state: "open", expiresAt: $0.1)
            }))
        }
        XCTAssertEqual(try byEvents.apply(created(1, "i1", expires: past)), .applied)
        XCTAssertEqual(try byEvents.apply(created(2, "i2", expires: future)), .applied)
        // The server's snapshot leaves the expired one out.
        try snapshot([("i2", future)])
        XCTAssertEqual(try byEvents.openInvitations(now: now).map(\.invitationId), ["i2"])
        XCTAssertEqual(try byEvents.openInvitations(now: now), try bySnapshot.openInvitations(now: now))
        // Invited again: the same id with a new term is open again.
        XCTAssertEqual(try byEvents.apply(created(3, "i1", expires: future)), .applied)
        try snapshot([("i1", future), ("i2", future)])
        XCTAssertEqual(try byEvents.openInvitations(now: now).map(\.invitationId), ["i1", "i2"])
        XCTAssertEqual(try byEvents.openInvitations(now: now), try bySnapshot.openInvitations(now: now))
    }

    // (1)
    func testAFailureInsideTheTransactionLeavesNeitherChangeNorCursor() throws {
        let store = try open()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.apply(joined(1)) { _, _ in throw Boom() })
        XCTAssertEqual(try names(store), [])
        XCTAssertEqual(try store.cursor(stream), 0)
    }

    // (2) and (3)
    func testCursorSurvivesReopeningAndOldEventsAreSkipped() throws {
        do {
            let store = try open()
            XCTAssertEqual(try store.apply(joined(1)), .applied)
            XCTAssertEqual(try store.apply(event(2, "member.set_name", ["account_id": .string(anna), "name": .string("Anna")])), .applied)
        }
        let again = try open()
        XCTAssertEqual(try again.cursor(stream), 2)
        XCTAssertEqual(try again.apply(joined(2, name: "old")), .duplicate)
        XCTAssertEqual(try again.apply(joined(1, name: "older")), .duplicate)
        XCTAssertEqual(try names(again), ["Anna"])
        XCTAssertEqual(try again.apply(joined(5, name: "later")), .gap(expected: 3))
        XCTAssertEqual(try again.cursor(stream), 2)
        XCTAssertEqual(try again.apply(event(3, "something.new", [:])), .passedOver, "unknown types move the cursor; a snapshot brings their effect")
    }

    // (4)
    func testSnapshotKeepsTheQueueAndLocalColumns() throws {
        let store = try open()
        let queued = try store.enqueue(command())
        try store.apply(ChatSnapshot(cursors: [stream: 4], members: [.init(accountId: anna, handle: "anna", name: "Anna", role: "owner")],
                                     teams: [.init(teamId: "t1", name: "General"), .init(teamId: "t2", name: "Ops")]))
        try store.queue.write { db in try db.execute(sql: "UPDATE teams SET collapsed = 1 WHERE team_id = 't1'") }
        try store.apply(ChatSnapshot(cursors: [stream: 9], members: [], teams: [.init(teamId: "t1", name: "Everyone")],
                                     teamMembers: [.init(teamId: "t1", accountId: anna)]))
        let teams = try store.queue.read { db in try Row.fetchAll(db, sql: "SELECT team_id, name, collapsed FROM teams") }
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams.first?["name"], "Everyone")
        XCTAssertEqual(teams.first?["collapsed"], true)
        XCTAssertEqual(try names(store), [])
        XCTAssertEqual(try store.cursor(stream), 9)
        XCTAssertEqual(try store.commands(), [queued])
    }

    /// C9-7: an admin's snapshot that no longer follows a team's stream but
    /// still carries the team keeps it: streams gone are dropped first, in
    /// the same transaction, then the snapshot is written.
    func testAdminSnapshotKeepsATeamWhoseStreamWentAway() throws {
        let store = try open()
        let admin: [ChatSnapshot.Member] = [.init(accountId: anna, handle: "anna", name: "Anna", role: "admin")]
        try store.apply(ChatSnapshot(cursors: [stream: 4, "team:t": 3, "org-admin:o": 2], members: admin,
                                     teams: [.init(teamId: "t", name: "Ops")], teamMembers: [.init(teamId: "t", accountId: anna)]))
        // The user left team t; as an admin it still sees it.
        try store.apply(ChatSnapshot(cursors: [stream: 5, "org-admin:o": 3], members: admin,
                                     teams: [.init(teamId: "t", name: "Ops", mine: false)],
                                     teamMembers: [.init(teamId: "t", accountId: anna)]),
                        following: [stream, "org-admin:o"])
        let teams = try store.queue.read { db in try Row.fetchAll(db, sql: "SELECT team_id, mine FROM teams") }
        XCTAssertEqual(teams.map { $0["team_id"] as String }, ["t"], "the team the snapshot brings is kept")
        XCTAssertEqual(teams.first?["mine"], false)
        XCTAssertNil(try store.cursors()["team:t"], "its stream's cursor is gone")
        let members = try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM team_members WHERE team_id = 't'") }
        XCTAssertEqual(members, 1)

        // Unsubscribed on its own while the admin stream is followed: kept, not the user's.
        try store.apply(ChatSnapshot(cursors: ["team:t": 3], teams: [.init(teamId: "t", name: "Ops")]))
        try store.drop(stream: "team:t")
        let left = try store.queue.read { db in try Row.fetchAll(db, sql: "SELECT team_id, mine FROM teams") }
        XCTAssertEqual(left.map { $0["mine"] as Bool }, [false])
    }

    // (5)
    func testCacheFilesDifferByAccountAndPort() throws {
        let a = try key(account: anna), b = try key(account: UUID().uuidString.lowercased())
        let p1 = try key(server: "https://chat.example.com"), p2 = try key(server: "https://chat.example.com:8443")
        XCTAssertNotEqual(a.cacheFileName, b.cacheFileName)
        XCTAssertNotEqual(p1.cacheFileName, p2.cacheFileName)
        XCTAssertEqual(try key(server: "HTTPS://Chat.Example.com:443/").cacheFileName, p1.cacheFileName)
        XCTAssertEqual(a.cacheFileName.count, 16 + ".sqlite".count)
    }

    // (6)
    func testDamagedCacheIsSetAsideAndMadeAnew() throws {
        let url = files.cacheURL(try key())
        try files.prepareDirectory()
        var noise = Data(count: 8192)
        for i in noise.indices { noise[i] = UInt8.random(in: 0...255) }
        try noise.write(to: url)
        let (store, recovered) = try ChatStore.open(files: files, key: try key())
        XCTAssertTrue(recovered)
        XCTAssertEqual(try store.cursors(), [:])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt")), noise)

        // The app's path: the organization's session says so.
        try FileManager.default.removeItem(at: url)
        try noise.write(to: url)
        let session = ChatOrgSession(key: try key(), files: files)
        XCTAssertTrue(session.needsFullSnapshot)
        XCTAssertNotNil(session.problem)
        XCTAssertNotNil(session.store)
    }

    // (7)
    func testNewerSchemaIsNeitherOpenedNorChanged() throws {
        let url = files.cacheURL(try key())
        _ = try open()
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('release-99')")
        }
        try queue.close()
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ChatStore.open(files: files, key: try key())) { XCTAssertEqual($0 as? ChatStoreError, .tooNew) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    /// C10-3: a file of a development build (migrations named otherwise
    /// than `release-N`) is set aside as `.dev-backup` and made anew.
    func testDevelopmentFilesAreSetAside() throws {
        try files.prepareDirectory()
        for url in [files.cacheURL(try key()), files.journalURL] {
            let old = try DatabaseQueue(path: url.path)
            try old.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1'), ('v9')")
                try db.execute(sql: "CREATE TABLE left_overs (leader_pid INTEGER)")
            }
            try old.close()
        }
        _ = try open()
        let journal = try ChatJournal.open(files: files)
        XCTAssertTrue(try journal.runs().isEmpty)
        for url in [files.cacheURL(try key()), files.journalURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".dev-backup"))
        }
        let tables = try journal.queue.read { db in try db.tableExists("left_overs") }
        XCTAssertFalse(tables)
    }

    /// C11-5: a transaction a crash left unfinished (a hot rollback journal)
    /// is rolled back by SQLite on opening; what was committed stays.
    func testCrashMidTransactionIsRolledBackOnOpening() throws {
        let crashed = ChatFiles(directory: root.appendingPathComponent("crashed"))
        try crashed.prepareDirectory()
        let journal = try ChatJournal.open(files: files)
        try journal.finish(try key(), "g1")
        let url = files.journalURL
        let committed = try Data(contentsOf: url)
        // A writer that crashes in the middle of a transaction: its files are
        // copied while it is open.
        let writer = try DatabaseQueue(path: url.path)
        try writer.inDatabase { db in
            // Pages spill to the file before the end of the transaction: the
            // journal beside it is hot.
            try db.execute(sql: "PRAGMA cache_size = 1")
            try db.execute(sql: "PRAGMA cache_spill = 1")
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "INSERT INTO org_generations (server, account_id, org_id, generation) VALUES ('s', 'a', 'o', 'x')")
            // More than the page cache holds.
            try db.execute(sql: "CREATE TABLE junk (b BLOB)")
            for _ in 0..<60 { try db.execute(sql: "INSERT INTO junk VALUES (zeroblob(200000))") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-journal"))
            XCTAssertNotEqual(try Data(contentsOf: url), committed, "the file holds pages of the unfinished transaction")
            try FileManager.default.copyItem(atPath: url.path, toPath: crashed.journalURL.path)
            try FileManager.default.copyItem(atPath: url.path + "-journal", toPath: crashed.journalURL.path + "-journal")
            try db.execute(sql: "ROLLBACK")
        }
        let reopened = try ChatJournal.open(files: crashed)
        XCTAssertEqual(try reopened.generation(try key()).generation, "g1", "committed data stays")
        let state = try reopened.queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM org_generations"), try db.tableExists("junk"))
        }
        XCTAssertEqual(state.0, 1, "the unfinished transaction is gone")
        XCTAssertFalse(state.1)
    }

    // (8)
    func testDeletingTheCacheKeepsTheJournal() async throws {
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        let conn = ChatConnection(server: try key().server, accountId: anna, sessionId: "s", deviceName: "Mac", orgId: org)
        try service.saveSignIn(conn, token: "aps_x")
        try await service.start(mode: .server)
        let session = service.session(for: try key())
        XCTAssertNotNil(session.store)
        let journal = try XCTUnwrap(service.journal)
        try journal.enqueue(command(), key: try key(), resultText: "the answer")
        await service.disconnect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.cacheURL(try key()).path))
        XCTAssertEqual(try ChatJournal.open(files: files).commands(for: try key()).count, 1)
    }

    // (9)
    func testQueuedBytesComeBackAsWritten() throws {
        let body = #"{"command_id":"x","args":{"name":"Анна ✓"},"type":"member.set_name"}"#
        let record = try open().enqueue(command(body: body))
        let read = try XCTUnwrap(try open().commands().first)
        XCTAssertEqual(read.bodyBytes, Data(body.utf8))
        XCTAssertEqual(read, record)
    }

    func testJournalRowsCarryTheirTriple() throws {
        let journal = try ChatJournal.open(files: files)
        let mine = try journal.enqueue(command(), key: try key(), resultText: "full text")
        try journal.enqueue(command(), key: try key(account: UUID().uuidString.lowercased()))
        XCTAssertEqual(try journal.commands(for: try key()), [mine])
        var sent = mine
        sent.state = .sent
        XCTAssertTrue(try journal.runCommands(try key()).update(sent, ifState: .pending))
        XCTAssertEqual(try journal.commands(for: try key()).first?.state, .sent)
        XCTAssertEqual(try journal.resultText(of: mine.commandId), "full text")
    }

    func testDamagedJournalBlocksUntilReset() async throws {
        try files.prepareDirectory()
        try Data(repeating: 7, count: 4096).write(to: files.journalURL)
        XCTAssertThrowsError(try ChatJournal.open(files: files)) {
            guard case .corrupt = $0 as? ChatStoreError else { return XCTFail("\($0)") }
        }
        let journal = try ChatJournal.reset(files: files)
        XCTAssertEqual(try journal.commands(for: try key()), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.journalURL.path + ".corrupt"))
    }
}
