// Frozen 1.2.1 initializer and its schema-install dependencies, copied from
// 96dc29b: TelegramChatIndex, TelegramAttentionIndex, TelegramNotificationIndex.
// Kept separate so rollback tests actually execute the released initialization
// path, rather than accidentally exercising the new version dispatcher.
import Foundation
import GRDB
@testable import AgentPadTelegram

final class LegacyTelegramV1Index {
    let db: DatabaseQueue
    let environment: TelegramEnvironment
    let account: Int64
    let initialRetryNotBefore: Int64
    init(directory: URL, environment: TelegramEnvironment, account: Int64) throws {
        self.environment = environment; self.account = account
        let url = directory.appendingPathComponent("chat-index.sqlite")
        // Precreate with the profile's atomic writer: SQLite never creates a
        // world-readable database, including during the first open.
        if !FileManager.default.fileExists(atPath: url.path) { try TelegramProfileStore.write(Data(), to: url) }
        try TelegramProfileStore.validate(url, directory: false)
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try TelegramProfileStore.validate(sidecar, directory: false) }
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE; PRAGMA cache_size = -2048; PRAGMA temp_store = FILE; PRAGMA mmap_size = 0")
        }
        db = try DatabaseQueue(path: url.path, configuration: config)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chats (
                    id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', username TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT 'unknown', userID INTEGER NOT NULL DEFAULT 0, groupID INTEGER NOT NULL DEFAULT 0,
                    mainOrder INTEGER NOT NULL DEFAULT 0, archiveOrder INTEGER NOT NULL DEFAULT 0,
                    lastDate INTEGER NOT NULL DEFAULT 0, recentDate INTEGER NOT NULL DEFAULT 0,
                    candidateDate INTEGER NOT NULL DEFAULT 0, candidateSender INTEGER NOT NULL DEFAULT 0,
                    unread INTEGER NOT NULL DEFAULT 0, mentions INTEGER NOT NULL DEFAULT 0,
                    pinOrder INTEGER, hidden INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS chat_user ON chats(userID);
                CREATE INDEX IF NOT EXISTS chat_group ON chats(groupID);
                CREATE TABLE IF NOT EXISTS entities (id INTEGER, family TEXT, title TEXT, username TEXT, kind TEXT, PRIMARY KEY(id, family));
                CREATE TABLE IF NOT EXISTS checkpoint (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS chat_order (position INTEGER PRIMARY KEY, chat INTEGER UNIQUE);
                CREATE TABLE IF NOT EXISTS recently_opened (chat INTEGER PRIMARY KEY, opened INTEGER);
                DELETE FROM chat_order;
                """)
            // loadChats has no caller offset. Each process must reestablish
            // TDLib's load state, regardless of the previous completion flags.
            try db.execute(sql: "DELETE FROM checkpoint WHERE key IN ('mainDone', 'archiveDone')")
        }
        initialRetryNotBefore = try db.read { try Int64.fetchOne($0, sql: "SELECT value FROM checkpoint WHERE key='retryNotBefore'") ?? 0 }
        try installAttentionSchema()
    }

    func installAttentionSchema() throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tg_state (
                  chat INTEGER PRIMARY KEY, inbox INTEGER NOT NULL DEFAULT 0, lastMessage INTEGER NOT NULL DEFAULT 0,
                  snooze INTEGER NOT NULL DEFAULT 0, previousSnooze INTEGER NOT NULL DEFAULT 0,
                  channelEnabled INTEGER NOT NULL DEFAULT 0, activation INTEGER NOT NULL DEFAULT 0,
                  generation TEXT NOT NULL DEFAULT '', episode TEXT, complete INTEGER NOT NULL DEFAULT 0,
                  signature TEXT NOT NULL DEFAULT '', checked TEXT NOT NULL DEFAULT '', fresh TEXT NOT NULL DEFAULT '', activationRequested INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS tg_messages (
                  chat INTEGER, id INTEGER, topic TEXT NOT NULL, date INTEGER NOT NULL, sender INTEGER NOT NULL,
                  mentioned INTEGER NOT NULL, unreadMention INTEGER NOT NULL, replyChat INTEGER NOT NULL,
                  replyID INTEGER NOT NULL, replyToMe INTEGER, viewed INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_messages_topic ON tg_messages(chat,topic,id);
                CREATE TABLE IF NOT EXISTS tg_receipts (chat INTEGER, id INTEGER, mentionRead INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS tg_scan_seen (chat INTEGER,id INTEGER,version TEXT,PRIMARY KEY(chat,id));
                CREATE TABLE IF NOT EXISTS tg_settings (
                  chat INTEGER, topic TEXT, muteUntil INTEGER, disableMention INTEGER, inbox INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY(chat,topic));
                CREATE TABLE IF NOT EXISTS tg_scopes (scope TEXT PRIMARY KEY, muteUntil INTEGER NOT NULL, disableMention INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS tg_work (
                  key TEXT PRIMARY KEY, method TEXT NOT NULL, chat INTEGER NOT NULL, topic TEXT NOT NULL DEFAULT '',
                  message INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0, pageSize INTEGER NOT NULL DEFAULT 50,
                  lane INTEGER NOT NULL, age INTEGER NOT NULL, retry INTEGER NOT NULL DEFAULT 0, version TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS tg_reason_messages (chat INTEGER, id INTEGER, topic TEXT, date INTEGER, kind TEXT, viewed INTEGER, PRIMARY KEY(chat,id));
                CREATE INDEX IF NOT EXISTS tg_reason_chat ON tg_reason_messages(chat,topic,id);
                CREATE VIEW IF NOT EXISTS tg_channel_pending AS
                  SELECT s.chat FROM tg_state s JOIN chats c ON c.id=s.chat
                  LEFT JOIN tg_settings cs ON cs.chat=s.chat AND cs.topic=''
                  LEFT JOIN tg_scopes sc ON sc.scope='notificationSettingsScopeChannelChats'
                  WHERE s.episode IS NOT NULL AND s.complete=0 AND s.channelEnabled=1 AND c.hidden=0 AND c.pinOrder IS NOT NULL
                    AND coalesce(cs.muteUntil,sc.muteUntil,9223372036854775807) <= coalesce((SELECT value FROM checkpoint WHERE key='attentionNow'),0);
                """)
            if try !db.columns(in: "tg_messages").contains(where: { $0.name == "senderIsChat" }) {
                try db.execute(sql: "ALTER TABLE tg_messages ADD COLUMN senderIsChat INTEGER NOT NULL DEFAULT 0")
                // The old decoder lost chat senders and could not recognize
                // ordinary mentions. Recheck persisted unread messages.
                try db.execute(sql: """
                    UPDATE tg_messages SET mentioned=unreadMention;
                    INSERT OR IGNORE INTO tg_work(key,method,chat,message,lane,age,version)
                      SELECT 'mention:'||chat||':'||id,'getMessage',chat,id,0,0,'' FROM tg_messages WHERE sender=0;
                    """)
            }
        }
        try installNotificationSchema()
    }

    func installNotificationSchema() throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tg_notification_groups (id INTEGER PRIMARY KEY, type TEXT, chat INTEGER, settingsChat INTEGER, sound INTEGER);
                CREATE TABLE IF NOT EXISTS tg_notifications (groupID INTEGER, id INTEGER, chat INTEGER, message INTEGER, date INTEGER, silent INTEGER, fresh INTEGER,
                  PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_seen (groupID INTEGER, id INTEGER, PRIMARY KEY(groupID,id));
                CREATE TABLE IF NOT EXISTS tg_notification_consumed (id TEXT PRIMARY KEY);
                DELETE FROM tg_notification_groups; DELETE FROM tg_notifications;
                DELETE FROM checkpoint WHERE key='notificationRetired';
                """)
            for table in ["tg_notification_seen", "tg_notification_consumed"] {
                if try !db.columns(in: table).contains(where: { $0.name == "date" }) {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN date INTEGER NOT NULL DEFAULT 0")
                }
            }
            if try !db.columns(in: "tg_state").contains(where: { $0.name == "notifiedEpisode" }) {
                try db.execute(sql: "ALTER TABLE tg_state ADD COLUMN notifiedEpisode TEXT")
                try db.execute(sql: """
                    UPDATE tg_state SET notifiedEpisode=episode WHERE episode IS NOT NULL AND
                      EXISTS(SELECT 1 FROM tg_notification_consumed WHERE id=?||chat||':'||generation||':'||episode)
                    """, arguments: ["telegram:\(environment.rawValue):\(account):channel:"])
            }
            try pruneNotificationHistory(db, now: Int64(Date().timeIntervalSince1970))
        }
    }

    func pruneNotificationHistory(_ db: Database, now: Int64) throws {
        // Delivery is ordered only within a notification group. Keep a compact
        // boundary per group so another group's delayed IDs can still be fresh.
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS tg_notification_retired (groupID INTEGER,id INTEGER);
            DELETE FROM tg_notification_retired;
            INSERT INTO tg_notification_retired
              SELECT groupID,id FROM tg_notification_seen WHERE date<=? OR
                groupID NOT IN (SELECT groupID FROM tg_notification_seen GROUP BY groupID ORDER BY max(date) DESC,max(id) DESC LIMIT ?) OR
                (groupID,id) IN (SELECT groupID,id FROM
                  (SELECT groupID,id,row_number() OVER (PARTITION BY groupID ORDER BY date DESC,id DESC) AS position FROM tg_notification_seen)
                  WHERE position>?);
            INSERT INTO checkpoint(key,value) SELECT 'notificationRetired:'||groupID,max(id) FROM tg_notification_retired
              GROUP BY groupID ON CONFLICT(key) DO UPDATE SET value=max(value,excluded.value);
            DELETE FROM tg_notification_seen WHERE (groupID,id) IN (SELECT groupID,id FROM tg_notification_retired);
            DELETE FROM tg_notification_retired;
            DELETE FROM tg_notification_consumed WHERE date<=? OR id NOT IN
              (SELECT id FROM tg_notification_consumed ORDER BY date DESC,rowid DESC LIMIT ?);
            """, arguments: [now - TelegramNotificationLimits.historySeconds, TelegramNotificationLimits.groups,
                               TelegramNotificationLimits.perGroup, now - TelegramNotificationLimits.historySeconds, TelegramNotificationLimits.count])
    }

}
