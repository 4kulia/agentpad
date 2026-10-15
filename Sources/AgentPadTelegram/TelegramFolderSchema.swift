import Foundation
import GRDB

extension TelegramChatIndex {
    /// Inspect without mutating the source. SQLite needs a writer to recover a
    /// hot journal, so inspect a private recovered copy in that case. The profile
    /// lease excludes live writers while the database and its journal are copied.
    static func storedVersion(at url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.fileSizeKey]).fileSize != 0 else { return nil }
        do { return try inspectVersion(at: url, readonly: true) }
        catch let error as DatabaseError where error.extendedResultCode == .SQLITE_READONLY_ROLLBACK {
            let probe = url.deletingLastPathComponent().appendingPathComponent(".schema-probe-\(UUID().uuidString)", isDirectory: true)
            try TelegramProfileStore.createDirectory(probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            let copy = probe.appendingPathComponent(url.lastPathComponent)
            for suffix in ["", "-journal"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                try TelegramProfileStore.validate(source, directory: false)
                try TelegramProfileStore.write(Data(contentsOf: source), to: URL(fileURLWithPath: copy.path + suffix))
            }
            return try inspectVersion(at: copy, readonly: false)
        }
    }

    private static func inspectVersion(at url: URL, readonly: Bool) throws -> Int? {
        var configuration = Configuration(); configuration.readonly = readonly
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? database.close() }
        return try database.read { db in
            if try db.tableExists("checkpoint"), let version = try Int.fetchOne(db,sql: "SELECT value FROM checkpoint WHERE key='schemaVersion'") {
                guard (1...2).contains(version), try db.tableExists("chats") else { throw TelegramStorageError.corruptProfile }
                return version
            }
            return try db.tableExists("chats") ? 1 : nil
        }
    }

    /// Called only after both version gates pass, and before the v1 backup:
    /// backing up the interrupted database alone would preserve uncommitted pages.
    private static func recoverJournal(directory: URL, version: Int?) throws {
        let url = directory.appendingPathComponent("chat-index.sqlite")
        guard FileManager.default.fileExists(atPath: url.path + "-journal") else { return }
        guard try inspectVersion(at: url, readonly: false) == version else { throw TelegramStorageError.corruptProfile }
    }

    static func prepareMigration(directory: URL, version: Int?, environment: TelegramEnvironment) throws -> UUID {
        let manifestURL = directory.appendingPathComponent("profile.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            // Standalone indexes are used by the offline fixture harness.
            guard let id = UUID(uuidString: String(directory.lastPathComponent.suffix(36))) else { throw TelegramStorageError.corruptProfile }
            try recoverJournal(directory: directory, version: version)
            return id
        }
        let bytes = try TelegramProfileStore.read(manifestURL)
        var manifest = try JSONDecoder().decode(TelegramProfileManifest.self, from: bytes)
        guard (1...2).contains(manifest.schemaVersion), manifest.environment == environment else { throw TelegramStorageError.corruptProfile }
        try recoverJournal(directory: directory, version: version)
        if version == 1 {
            for (source, backup) in [("chat-index.sqlite", "chat-index.v1.sqlite"), ("profile.json", "profile.v1.json")] {
                let destination = directory.appendingPathComponent(backup)
                if FileManager.default.fileExists(atPath: destination.path) { try TelegramProfileStore.validate(destination, directory: false) }
                else {
                    let sourceURL = directory.appendingPathComponent(source)
                    try TelegramProfileStore.validate(sourceURL, directory: false)
                    try TelegramProfileStore.write(Data(contentsOf: sourceURL), to: destination)
                }
            }
        }
        if manifest.schemaVersion == 1 {
            manifest.schemaVersion = 2
            try TelegramProfileStore.write(JSONEncoder().encode(manifest), to: manifestURL)
        }
        return manifest.connectionID
    }

    static let freshAttentionSchema = """
                CREATE TABLE IF NOT EXISTS tg_state (
                  chat INTEGER PRIMARY KEY, inbox INTEGER NOT NULL DEFAULT 0, lastMessage INTEGER NOT NULL DEFAULT 0,
                  snooze INTEGER NOT NULL DEFAULT 0, previousSnooze INTEGER NOT NULL DEFAULT 0,
                  followEnabled INTEGER NOT NULL DEFAULT 0, activation INTEGER NOT NULL DEFAULT 0,
                  generation TEXT NOT NULL DEFAULT '', episode TEXT, complete INTEGER NOT NULL DEFAULT 0,
                  notifiedEpisode TEXT, signature TEXT NOT NULL DEFAULT '', checked TEXT NOT NULL DEFAULT '', fresh TEXT NOT NULL DEFAULT '', activating INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS tg_messages (
                  chat INTEGER, id INTEGER, topic TEXT NOT NULL, date INTEGER NOT NULL, sender INTEGER NOT NULL, senderIsChat INTEGER NOT NULL DEFAULT 0,
                  mentioned INTEGER NOT NULL, unreadMention INTEGER NOT NULL, replyChat INTEGER NOT NULL,
                  replyID INTEGER NOT NULL, replyToMe INTEGER, viewed INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_messages_topic ON tg_messages(chat,topic,id);
                CREATE TABLE IF NOT EXISTS tg_receipts (chat INTEGER, id INTEGER, mentionRead INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS tg_scan_seen (chat INTEGER,id INTEGER,version TEXT,PRIMARY KEY(chat,version,id));
                CREATE TABLE IF NOT EXISTS tg_settings (
                  chat INTEGER, topic TEXT, muteUntil INTEGER, disableMention INTEGER, inbox INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,topic));
                CREATE TABLE IF NOT EXISTS tg_scopes (scope TEXT PRIMARY KEY, muteUntil INTEGER NOT NULL, disableMention INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS tg_work (
                  key TEXT PRIMARY KEY, method TEXT NOT NULL, chat INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '',
                  message INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0, pageSize INTEGER NOT NULL DEFAULT 50,
                  lane INTEGER NOT NULL, age INTEGER NOT NULL, retry INTEGER NOT NULL DEFAULT 0, version TEXT NOT NULL, pages INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS tg_reason_messages (chat INTEGER, id INTEGER, topic TEXT, date INTEGER, kind TEXT, viewed INTEGER, PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_reason_chat ON tg_reason_messages(chat,topic,id);
                CREATE VIEW IF NOT EXISTS tg_follow_pending AS
                  SELECT s.chat FROM tg_state s JOIN chats c ON c.id=s.chat
                  LEFT JOIN tg_settings cs ON cs.chat=s.chat AND cs.topic=''
                  LEFT JOIN tg_scopes sc ON sc.scope=CASE WHEN c.kind='channel' THEN 'notificationSettingsScopeChannelChats' ELSE 'notificationSettingsScopeGroupChats' END
                  WHERE s.activating=0 AND s.episode IS NOT NULL AND s.complete=0 AND s.followEnabled=1 AND c.hidden=0 AND c.kind IN ('channel','group','supergroup','forum')
                    AND coalesce(cs.muteUntil,sc.muteUntil,9223372036854775807) <= coalesce((SELECT value FROM checkpoint WHERE key='attentionNow'),0);

                CREATE TABLE IF NOT EXISTS tg_notification_groups (id INTEGER PRIMARY KEY, type TEXT, chat INTEGER, settingsChat INTEGER, sound INTEGER);
                CREATE TABLE IF NOT EXISTS tg_notifications (groupID INTEGER, id INTEGER, chat INTEGER, message INTEGER, date INTEGER, silent INTEGER, fresh INTEGER,
                  PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_seen (groupID INTEGER, id INTEGER, date INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_consumed (id TEXT PRIMARY KEY, date INTEGER NOT NULL DEFAULT 0);
        """

    static let folderSchema = """
        CREATE TABLE tg_position (chat INTEGER NOT NULL, list TEXT NOT NULL, ord INTEGER NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0, epoch TEXT NOT NULL, PRIMARY KEY(list,chat));
        CREATE INDEX tg_position_order ON tg_position(list,ord DESC,chat DESC);
        CREATE INDEX tg_position_chat ON tg_position(chat);
        CREATE TABLE tg_list_order (list TEXT NOT NULL,position INTEGER NOT NULL,chat INTEGER NOT NULL,PRIMARY KEY(list,position));
        CREATE INDEX tg_list_order_chat ON tg_list_order(list,chat);
        CREATE TABLE tg_list_counts (list TEXT PRIMARY KEY,rows INTEGER NOT NULL,unreadItems INTEGER NOT NULL,
          unmutedUnreadItems INTEGER NOT NULL,attentionItems INTEGER NOT NULL);
        CREATE TABLE tg_folder (id INTEGER PRIMARY KEY,name TEXT NOT NULL,icon TEXT NOT NULL DEFAULT '',telegramIndex INTEGER NOT NULL);
        CREATE TABLE tg_slot (list TEXT PRIMARY KEY,visible INTEGER NOT NULL);
        INSERT INTO tg_slot VALUES ('main',1),('archive',0);
        CREATE TABLE tg_collapse (window TEXT NOT NULL,list TEXT NOT NULL,PRIMARY KEY(window,list));
        CREATE TABLE tg_custom_member (folder TEXT NOT NULL,chat INTEGER NOT NULL,PRIMARY KEY(folder,chat));
        CREATE TABLE tg_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);
        """

    static let followPendingSchema = """
        CREATE VIEW tg_follow_pending AS
        SELECT s.chat FROM tg_state s JOIN chats c ON c.id=s.chat
        LEFT JOIN tg_settings cs ON cs.chat=s.chat AND cs.topic=''
        LEFT JOIN tg_scopes sc ON sc.scope=CASE WHEN c.kind='channel' THEN 'notificationSettingsScopeChannelChats' ELSE 'notificationSettingsScopeGroupChats' END
        WHERE s.episode IS NOT NULL AND s.complete=0 AND s.followEnabled=1 AND s.activating=0 AND c.hidden=0 AND c.kind IN ('channel','group','supergroup','forum')
          AND coalesce(cs.muteUntil,sc.muteUntil,9223372036854775807) <= coalesce((SELECT value FROM checkpoint WHERE key='attentionNow'),0);
        """

    func installSchema(version: Int?, migrationCheckpoint: ((String) throws -> Void)? = nil) throws {
        try db.write { db in
            if version == nil {
                try db.execute(sql: """
                    CREATE TABLE chats (
                      id INTEGER PRIMARY KEY,title TEXT NOT NULL DEFAULT '',username TEXT NOT NULL DEFAULT '',kind TEXT NOT NULL DEFAULT 'unknown',
                      userID INTEGER NOT NULL DEFAULT 0,groupID INTEGER NOT NULL DEFAULT 0,lastDate INTEGER NOT NULL DEFAULT 0,
                      lastOutgoing INTEGER NOT NULL DEFAULT 0,unread INTEGER NOT NULL DEFAULT 0,mentions INTEGER NOT NULL DEFAULT 0,
                      markedUnread INTEGER NOT NULL DEFAULT 0,hidden INTEGER NOT NULL DEFAULT 0);
                    CREATE INDEX chat_user ON chats(userID);
                    CREATE INDEX chat_group ON chats(groupID);
                    CREATE TABLE entities (id INTEGER,family TEXT,title TEXT,username TEXT,kind TEXT,PRIMARY KEY(id,family));
                    CREATE TABLE checkpoint (key TEXT PRIMARY KEY,value INTEGER NOT NULL);
                    CREATE TABLE recently_opened (chat INTEGER PRIMARY KEY,opened INTEGER);
                    """)
                try db.execute(sql: Self.folderSchema)
                try db.execute(sql: Self.freshAttentionSchema)
            } else if version == 1 {
                try migrationCheckpoint?("manifest")
                try db.execute(sql: "DROP VIEW IF EXISTS tg_channel_pending")
                if try !db.columns(in: "tg_messages").contains(where: { $0.name == "senderIsChat" }) {
                    try db.execute(sql: """
                        ALTER TABLE tg_messages ADD COLUMN senderIsChat INTEGER NOT NULL DEFAULT 0;
                        UPDATE tg_messages SET mentioned=unreadMention;
                        INSERT OR IGNORE INTO tg_work(key,method,chat,message,lane,age,version)
                        SELECT 'mention:'||chat||':'||id,'getMessage',chat,id,0,0,'' FROM tg_messages WHERE sender=0;
                        """)
                }
                for table in ["tg_notification_seen","tg_notification_consumed"] {
                    if try !db.columns(in: table).contains(where: { $0.name == "date" }) {
                        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN date INTEGER NOT NULL DEFAULT 0")
                    }
                }
                if try !db.columns(in: "tg_state").contains(where: { $0.name == "notifiedEpisode" }) {
                    try db.execute(sql: "ALTER TABLE tg_state ADD COLUMN notifiedEpisode TEXT")
                    try db.execute(sql: """
                        UPDATE tg_state SET notifiedEpisode=episode WHERE episode IS NOT NULL AND
                          EXISTS(SELECT 1 FROM tg_notification_consumed WHERE id=?||chat||':'||generation||':'||episode)
                        """,arguments: ["telegram:\(environment.rawValue):\(account):channel:"])
                }
                try db.execute(sql: Self.folderSchema)
                try db.execute(sql: "ALTER TABLE chats ADD COLUMN markedUnread INTEGER NOT NULL DEFAULT 0; ALTER TABLE chats ADD COLUMN lastOutgoing INTEGER NOT NULL DEFAULT 0")
                try db.execute(sql: "INSERT OR IGNORE INTO tg_custom_member SELECT ?,id FROM chats WHERE pinOrder IS NOT NULL", arguments: [binding.migratedPinsID.uuidString])
                try db.execute(sql: "ALTER TABLE tg_state RENAME COLUMN channelEnabled TO followEnabled; ALTER TABLE tg_state RENAME COLUMN activationRequested TO activating")
                for (column, list) in [("mainOrder", "main"), ("archiveOrder", "archive")] {
                    try db.execute(sql: "INSERT INTO tg_position SELECT id,?,\(column),0,'migrated' FROM chats WHERE \(column)!=0", arguments: [list])
                }
                for column in ["mainOrder", "archiveOrder", "recentDate", "candidateDate", "candidateSender", "pinOrder"] {
                    try db.execute(sql: "ALTER TABLE chats DROP COLUMN \(column)")
                }
                try db.execute(sql: "DROP TABLE chat_order")
                try db.execute(sql: Self.followPendingSchema)
                try migrationCheckpoint?("transaction")
            }
            try db.execute(sql: "DROP VIEW IF EXISTS tg_follow_pending")
            try db.execute(sql: Self.followPendingSchema)
            // Part A profiles have one seen set per chat; independent mention
            // and history scans need a seen set per scan version.
            if try db.primaryKey("tg_scan_seen").columns != ["chat","version","id"] {
                try db.execute(sql: """
                    ALTER TABLE tg_scan_seen RENAME TO tg_scan_seen_old;
                    CREATE TABLE tg_scan_seen (chat INTEGER,id INTEGER,version TEXT,PRIMARY KEY(chat,version,id));
                    INSERT INTO tg_scan_seen SELECT * FROM tg_scan_seen_old;
                    DROP TABLE tg_scan_seen_old;
                    """)
            }
            if try !db.columns(in: "tg_work").contains(where: { $0.name == "pages" }) {
                try db.execute(sql: "ALTER TABLE tg_work ADD COLUMN pages INTEGER NOT NULL DEFAULT 0")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS tg_message_reply_target ON tg_messages(replyChat,replyID)")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tg_attention_summary (
                  chat INTEGER PRIMARY KEY,id INTEGER,topic TEXT,date INTEGER,kind TEXT,n INTEGER,classCount INTEGER);
                """)
            // Resume an unfinished legacy activation online. Completed opt-ins
            // retain their message-ID boundary and episode byte for byte.
            try db.execute(sql: """
                UPDATE tg_state SET followEnabled=1 WHERE activating=1;
                UPDATE tg_work SET method='getChatHistory',pageSize=1,cursor=0,
                  version=coalesce((SELECT generation FROM tg_state WHERE chat=tg_work.chat),'') WHERE key LIKE 'activate:%';
                INSERT OR IGNORE INTO tg_work(key,method,chat,lane,age,version,pageSize)
                  SELECT 'activate:'||chat,'getChatHistory',chat,0,0,generation,1 FROM tg_state WHERE activating=1;
                INSERT OR REPLACE INTO checkpoint VALUES ('schemaVersion',2);
                """)
            try db.execute(sql: "DELETE FROM checkpoint WHERE key IN ('mainDone','archiveDone'); UPDATE tg_state SET signature='',checked='' ")
        }
        try resetNotificationSession()
    }

    func finishMigrationScan() throws {
        for name in ["chat-index.v1.sqlite", "profile.v1.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try TelegramProfileStore.validate(url, directory: false)
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
