import Foundation
import GRDB
import XCTest
@testable import AgentPadTelegram

enum LegacyFolderFixture {
    static func makeVersionOne(_ db: Database) throws {
        try db.execute(sql: """
            DROP VIEW tg_follow_pending;
            ALTER TABLE tg_state RENAME COLUMN followEnabled TO channelEnabled;
            ALTER TABLE tg_state RENAME COLUMN activating TO activationRequested;
            ALTER TABLE chats DROP COLUMN markedUnread; ALTER TABLE chats DROP COLUMN lastOutgoing;
            ALTER TABLE chats ADD COLUMN pinOrder INTEGER;
            ALTER TABLE chats ADD COLUMN mainOrder INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE chats ADD COLUMN archiveOrder INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE chats ADD COLUMN recentDate INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE chats ADD COLUMN candidateDate INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE chats ADD COLUMN candidateSender INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE chat_order(position INTEGER PRIMARY KEY,chat INTEGER UNIQUE);
            DROP TABLE tg_position; DROP TABLE tg_list_order; DROP TABLE tg_list_counts;
            DROP TABLE tg_folder; DROP TABLE tg_slot; DROP TABLE tg_collapse; DROP TABLE tg_custom_member; DROP TABLE tg_meta;
            DELETE FROM checkpoint WHERE key='schemaVersion';
            """)
    }
    static func install(in directory: URL, connection: UUID, pins: Int = 205) throws {
        var manifest = TelegramProfileManifest(connectionID: connection,environment: .test)
        manifest.schemaVersion = 1
        try TelegramProfileStore.write(JSONEncoder().encode(manifest),to: directory.appendingPathComponent("profile.json"))
        let url = directory.appendingPathComponent("chat-index.sqlite")
        try TelegramProfileStore.write(Data(),to: url)
        let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat-index-v1.sql")
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: String(contentsOf: schema,encoding: .utf8))
            for id in 1...pins {
                try db.execute(sql: "INSERT INTO chats(id,title,kind,pinOrder,mainOrder,archiveOrder,recentDate) VALUES (?,?,'channel',?,?,0,123)",arguments: [id,"Legacy \(id)",id,id == pins ? 0 : id])
                try db.execute(sql: "INSERT INTO tg_state(chat) VALUES (?)",arguments: [id])
            }
            try db.execute(sql: "UPDATE tg_state SET channelEnabled=1,activation=100,lastMessage=200,generation='kept-generation',episode='kept-episode' WHERE chat=1")
            try db.execute(sql: "UPDATE chats SET unread=1 WHERE id=1")
            try db.execute(sql: "INSERT INTO tg_scopes VALUES ('notificationSettingsScopeChannelChats',0,0)")
        }
    }
    /// Frozen 1.2.1 gate/schema path, independent of the v2 implementation.
    static func oldOpen(_ directory: URL) throws {
        let manifest = try JSONDecoder().decode(TelegramProfileManifest.self,from: TelegramProfileStore.read(directory.appendingPathComponent("profile.json")))
        guard manifest.schemaVersion == 1 else { throw TelegramStorageError.corruptProfile }
        _ = try LegacyTelegramV1Index(directory: directory,environment: .test,account: ChatFixture.me)
    }
    static func rollback(_ directory: URL) throws {
        for (backup,destination) in [("chat-index.v1.sqlite","chat-index.sqlite"),("profile.v1.json","profile.json")] {
            try TelegramProfileStore.write(Data(contentsOf: directory.appendingPathComponent(backup)),to: directory.appendingPathComponent(destination))
        }
    }
}

final class TelegramFolderMigrationTests: XCTestCase {
    /// Copy the real on-disk database and rollback journal while a writer has
    /// spilled uncommitted pages. Restoring those bytes after closing the writer
    /// simulates its abrupt death: no SQLite connection can roll this copy back.
    private func leaveHotJournal(in directory: URL) throws {
        let url = directory.appendingPathComponent("chat-index.sqlite")
        let journalURL = URL(fileURLWithPath: url.path + "-journal")
        let writer = try DatabaseQueue(path: url.path)
        var database = Data(), journal = Data()
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE; PRAGMA cache_size=1; PRAGMA cache_spill=ON")
            try db.inTransaction {
                try db.execute(sql: """
                    UPDATE chats SET title='Uncommitted';
                    INSERT OR REPLACE INTO checkpoint VALUES ('schemaVersion',99);
                    CREATE TABLE unfinished(payload BLOB);
                    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<256)
                      INSERT INTO unfinished SELECT zeroblob(8192) FROM n;
                    """)
                database = try Data(contentsOf: url)
                journal = try Data(contentsOf: journalURL)
                return .rollback
            }
        }
        try writer.close()
        XCTAssertGreaterThan(journal.count, 512)
        XCTAssertEqual(Array(journal.prefix(8)), [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
        try TelegramProfileStore.write(database, to: url)
        try TelegramProfileStore.write(journal, to: journalURL)
        // Prove this is a hot journal, not the normal rollback used by the
        // throwing migration-checkpoint tests.
        func readOnlyOpen() throws {
            var config = Configuration(); config.readonly = true
            let reader = try DatabaseQueue(path: url.path, configuration: config)
            _ = try reader.read { try $0.tableExists("chats") }
        }
        XCTAssertThrowsError(try readOnlyOpen()) {
            XCTAssertEqual(($0 as? DatabaseError)?.extendedResultCode, .SQLITE_READONLY_ROLLBACK)
        }
    }

    func testHotJournalRecoversSupportedVersionsBeforeMigrationBackup() throws {
        for version in [1, 2] {
            let fixture = try TelegramFixture(), connection = UUID()
            try LegacyFolderFixture.install(in: fixture.directory, connection: connection)
            if version == 2 {
                let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
                try index.finishMigrationScan()
            }
            let url = fixture.directory.appendingPathComponent("chat-index.sqlite")
            let committed = try Data(contentsOf: url)
            try leaveHotJournal(in: fixture.directory)
            let interrupted = try Data(contentsOf: url)
            XCTAssertNotEqual(interrupted, committed)
            XCTAssertEqual(try TelegramChatIndex.storedVersion(at: url), version)
            // Version inspection must not mutate the original, even to recover it.
            XCTAssertEqual(try Data(contentsOf: url), interrupted)
            let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
            try index.db.read { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM chats WHERE id=1"), "Legacy 1")
                XCTAssertFalse(try db.tableExists("unfinished"))
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key='schemaVersion'"), 2)
            }
            XCTAssertEqual(try index.customMembers(binding: index.binding)[index.binding.migratedPinsID]?.count, 205)
            if version == 1 {
                XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.v1.sqlite")), committed)
                let backup = try DatabaseQueue(path: fixture.directory.appendingPathComponent("chat-index.v1.sqlite").path)
                XCTAssertEqual(try backup.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM chats WHERE pinOrder IS NOT NULL") }, 205)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-journal"))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".schema-probe-") })
        }
    }

    func testHotJournalOnNewerManifestOrDatabaseIsByteForByteUntouched() throws {
        for newerManifest in [true, false] {
            let fixture = try TelegramFixture(), connection = UUID()
            try LegacyFolderFixture.install(in: fixture.directory, connection: connection)
            if newerManifest {
                var manifest = TelegramProfileManifest(connectionID: connection, environment: .test)
                manifest.schemaVersion = 3
                try TelegramProfileStore.write(JSONEncoder().encode(manifest), to: fixture.directory.appendingPathComponent("profile.json"))
            } else {
                let db = try DatabaseQueue(path: fixture.directory.appendingPathComponent("chat-index.sqlite").path)
                try db.write { try $0.execute(sql: "INSERT INTO checkpoint VALUES ('schemaVersion',3)") }
            }
            try leaveHotJournal(in: fixture.directory)
            let paths = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
            let before = try paths.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) }
            XCTAssertThrowsError(try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)) {
                XCTAssertEqual($0 as? TelegramStorageError, .corruptProfile)
            }
            XCTAssertEqual(try paths.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) }, before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(), paths)
        }
    }

    func testV1MigrationPreservesAllPinsBoundaryEpisodeAndUnreadHistory() throws {
        // RFC 4122 UUIDv5 vector computed independently of the migration helper.
        XCTAssertEqual(TelegramProfileBinding.migratedPinsID(connectionID: UUID(uuidString: "12345678-1234-5678-1234-567812345678")!),
                       UUID(uuidString: "b48cbf2a-f5c1-5497-ba8f-67ea5649c5d0"))
        let fixture = try TelegramFixture(), connection = UUID()
        try LegacyFolderFixture.install(in: fixture.directory,connection: connection)
        let original = try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.sqlite"))
        let index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me,migrationCheckpoint: { phase in
            if phase == "manifest" {
                let manifest = try JSONDecoder().decode(TelegramProfileManifest.self,from: TelegramProfileStore.read(fixture.directory.appendingPathComponent("profile.json")))
                XCTAssertEqual(manifest.schemaVersion,2)
                XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.v1.sqlite")),original)
            }
        })
        let binding = index.binding
        XCTAssertEqual(binding.connectionID,connection)
        XCTAssertEqual(try index.customMembers(binding: binding)[binding.migratedPinsID]?.count,205)
        for name in ["chat-index.v1.sqlite","profile.v1.json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue,0o600)
        }
        try index.db.read { db in
            let columns = try db.columns(in: "chats").map(\.name)
            XCTAssertTrue(Set(columns).isDisjoint(with: ["pinOrder","recentDate","mainOrder","archiveOrder","candidateDate","candidateSender"]))
            XCTAssertFalse(try db.tableExists("chat_order"))
            XCTAssertEqual(try Int.fetchOne(db,sql: "SELECT count(*) FROM tg_position WHERE ord=0"),0)
            let state = try XCTUnwrap(Row.fetchOne(db,sql: "SELECT * FROM tg_state WHERE chat=1"))
            XCTAssertTrue(state["followEnabled"] as Bool); XCTAssertEqual(state["activation"] as Int64,100)
            XCTAssertEqual(state["generation"] as String,"kept-generation"); XCTAssertEqual(state["episode"] as String,"kept-episode")
            XCTAssertEqual(try Int.fetchOne(db,sql: "SELECT value FROM checkpoint WHERE key='schemaVersion'"),2)
        }
        XCTAssertThrowsError(try LegacyFolderFixture.oldOpen(fixture.directory))
        try index.prepareAttentionScan(now: ChatFixture.now)
        let work = try XCTUnwrap(index.nextAttentionWork(lane: 1,now: ChatFixture.now))
        XCTAssertEqual(work.method,"getChatHistory")
        var message = try XCTUnwrap(ChatFixture.message(outgoing: false,id: 150).object); message["chat_id"] = .integer(1)
        let response = TDLibMessage("messages",["total_count": .integer(1),"messages": .array([.object(message.fields)])])
        TelegramFixtureSchema.check(response)
        try index.finishAttentionWork(work,response: response,now: ChatFixture.now)
        XCTAssertEqual(try index.get(1,now: ChatFixture.now)?.attention?.kind,.channelPost)
    }

    func testCrashAfterManifestAndInsideTransactionResumesWithoutOverwritingBackups() throws {
        enum Crash: Error { case interrupted }
        for phase in ["manifest","transaction"] {
            let fixture = try TelegramFixture(), connection = UUID()
            try LegacyFolderFixture.install(in: fixture.directory,connection: connection)
            let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.sqlite"))
            XCTAssertThrowsError(try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me,migrationCheckpoint: { if $0 == phase { throw Crash.interrupted } }))
            XCTAssertEqual(try TelegramChatIndex.storedVersion(at: fixture.directory.appendingPathComponent("chat-index.sqlite")),1)
            XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.v1.sqlite")),bytes)
            let resumed = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
            XCTAssertEqual(try resumed.customMembers(binding: resumed.binding)[resumed.binding.migratedPinsID]?.count,205)
            XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.v1.sqlite")),bytes)
        }
    }

    func testNewerManifestAndDatabaseAreByteForByteUntouched() throws {
        for newerManifest in [true,false] {
            let fixture = try TelegramFixture(), connection = UUID()
            try LegacyFolderFixture.install(in: fixture.directory,connection: connection)
            if newerManifest {
                var manifest = TelegramProfileManifest(connectionID: connection,environment: .test); manifest.schemaVersion = 3
                try TelegramProfileStore.write(JSONEncoder().encode(manifest),to: fixture.directory.appendingPathComponent("profile.json"))
            } else {
                let db = try DatabaseQueue(path: fixture.directory.appendingPathComponent("chat-index.sqlite").path)
                try db.write { try $0.execute(sql: "INSERT INTO checkpoint VALUES ('schemaVersion',3)") }
            }
            let paths = ["profile.json","chat-index.sqlite"]
            let before = try paths.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) }
            XCTAssertThrowsError(try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)) { XCTAssertEqual($0 as? TelegramStorageError,.corruptProfile) }
            XCTAssertEqual(try paths.map { try Data(contentsOf: fixture.directory.appendingPathComponent($0)) },before)
        }
    }

    func testRollbackOpensV1AndReupgradeKeepsTheSameUUID() throws {
        let fixture = try TelegramFixture(), connection = UUID()
        try LegacyFolderFixture.install(in: fixture.directory,connection: connection)
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        let id = index!.binding.migratedPinsID
        index = nil
        try LegacyFolderFixture.rollback(fixture.directory); try LegacyFolderFixture.oldOpen(fixture.directory)
        index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        XCTAssertEqual(index!.binding.migratedPinsID,id)
        XCTAssertEqual(try index!.customMembers(binding: index!.binding)[id]?.count,205)
        try index!.finishMigrationScan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("chat-index.v1.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("profile.v1.json").path))
    }
}
