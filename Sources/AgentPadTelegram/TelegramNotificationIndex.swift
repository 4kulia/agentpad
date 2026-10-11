import Foundation
import GRDB

enum TelegramNotificationProtocolError: Error { case limits }

enum TelegramNotificationLimits {
    static let groups = 25
    static let perGroup = 10
    static let count = groups * perGroup
    static let historySeconds: Int64 = 7 * 86400
}

extension TelegramChatIndex {
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

    func expireNotificationHistory(now: Int64) throws {
        guard now >= notificationHistoryExpiry else { return }
        try db.write { try pruneNotificationHistory($0, now: now) }
        notificationHistoryExpiry = now + 3600
    }

    func clearNotifications() throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM tg_notifications; DELETE FROM tg_notification_groups;
                DELETE FROM tg_notification_seen; DELETE FROM tg_notification_consumed;
                DELETE FROM checkpoint WHERE key='notificationRetired' OR key LIKE 'notificationRetired:%';
                UPDATE tg_state SET notifiedEpisode=NULL;
                """)
        }
        notificationSnapshotReceived = false; notificationHavePending = false; notificationLiveAfter = .max; notificationHistoryExpiry = 0
        dirty = true
    }

    @discardableResult func applyNotifications(_ update: TDLibMessage, now: Int64) throws -> Bool {
        guard ["updateActiveNotifications", "updateNotificationGroup", "updateNotification", "updateHavePendingNotifications"].contains(update.type) else { return false }
        try db.write { db in
            try pruneNotificationHistory(db, now: now)
            func add(_ raw: TDLibMessage, group: Int64, chat: Int64, fresh: Bool) throws {
                guard let id = raw["id"]?.integer, id > 0 else { return }
                let retired = try Int64.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key=?", arguments: ["notificationRetired:\(group)"]) ?? 0
                let seen = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_notification_seen WHERE groupID=? AND id=?)", arguments: [group,id]) == true
                let type = raw["type"]?.object
                var messageID: Int64 = 0
                if type?.type == "notificationTypeNewMessage", let message = type?["message"]?.object,
                   message["chat_id"]?.integer == chat {
                    messageID = message["id"]?.integer ?? 0
                    try attentionMessage(message, chat: chat, db: db, now: now)
                }
                // Push/secret/call notifications do not prove an addressed
                // ordinary message. Never decode or retain their preview text.
                try db.execute(sql: """
                    INSERT INTO tg_notifications VALUES (?,?,?,?,?,?,?) ON CONFLICT(groupID,id) DO UPDATE SET
                      chat=excluded.chat,message=excluded.message,date=excluded.date,silent=excluded.silent
                    """, arguments: [group,id,chat,messageID,raw["date"]?.integer ?? now,raw["is_silent"]?.bool ?? true,
                        fresh && !seen && id > retired && (raw["date"]?.integer ?? 0) >= max(notificationLiveAfter, now - TelegramNotificationLimits.historySeconds)])
                try db.execute(sql: "INSERT OR IGNORE INTO tg_notification_seen(groupID,id,date) VALUES (?,?,?)", arguments: [group,id,now])
            }
            switch update.type {
            case "updateActiveNotifications":
                let groups = update["groups"]?.array ?? []
                guard groups.count <= TelegramNotificationLimits.groups else { throw TelegramNotificationProtocolError.limits }
                try db.execute(sql: "DELETE FROM tg_notifications; DELETE FROM tg_notification_groups")
                for value in groups {
                    guard let group = value.object, let id = group["id"]?.integer, let chat = group["chat_id"]?.integer else { continue }
                    let values = group["notifications"]?.array ?? []
                    guard values.count <= TelegramNotificationLimits.perGroup else { throw TelegramNotificationProtocolError.limits }
                    try db.execute(sql: "INSERT OR REPLACE INTO tg_notification_groups VALUES (?,?,?,?,0)", arguments: [id,group["type"]?.object?.type ?? "",chat,chat])
                    for value in values { if let raw = value.object { try add(raw, group: id, chat: chat, fresh: false) } }
                }
            case "updateNotificationGroup":
                guard let id = update["notification_group_id"]?.integer, let chat = update["chat_id"]?.integer else { return }
                let type = update["type"]?.object?.type ?? ""
                if let old = try Row.fetchOne(db, sql: "SELECT chat,type FROM tg_notification_groups WHERE id=?", arguments: [id]),
                   (old["chat"] as Int64 != chat || old["type"] as String != type) {
                    try db.execute(sql: "DELETE FROM tg_notifications WHERE groupID=?", arguments: [id])
                }
                try db.execute(sql: "INSERT OR REPLACE INTO tg_notification_groups VALUES (?,?,?,?,?)", arguments: [id,type,chat,
                    update["notification_settings_chat_id"]?.integer ?? chat,update["notification_sound_id"]?.integer ?? 0])
                for value in update["removed_notification_ids"]?.array ?? [] {
                    if let notification = value.integer { try db.execute(sql: "DELETE FROM tg_notifications WHERE groupID=? AND id=?", arguments: [id,notification]) }
                }
                for value in update["added_notifications"]?.array ?? [] {
                    if let raw = value.object { try add(raw, group: id, chat: chat, fresh: notificationSnapshotReceived) }
                }
                if update["total_count"]?.integer == 0 {
                    try db.execute(sql: "DELETE FROM tg_notifications WHERE groupID=?; DELETE FROM tg_notification_groups WHERE id=?", arguments: [id,id])
                }
            case "updateNotification":
                if let group = update["notification_group_id"]?.integer,
                   let chat = try Int64.fetchOne(db, sql: "SELECT chat FROM tg_notification_groups WHERE id=?", arguments: [group]),
                   let raw = update["notification"]?.object { try add(raw, group: group, chat: chat, fresh: false) }
            default:
                notificationHavePending = update["have_delayed_notifications"]?.bool == true || update["have_unreceived_notifications"]?.bool == true
            }
            try db.execute(sql: "DELETE FROM tg_notification_groups WHERE id NOT IN (SELECT DISTINCT groupID FROM tg_notifications)")
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM tg_notifications")! <= TelegramNotificationLimits.count,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM tg_notification_groups")! <= TelegramNotificationLimits.groups,
                  try Int.fetchOne(db, sql: "SELECT coalesce(max(n),0) FROM (SELECT count(*) n FROM tg_notifications GROUP BY groupID)")! <= TelegramNotificationLimits.perGroup else {
                throw TelegramNotificationProtocolError.limits
            }
            try pruneNotificationHistory(db, now: now)
        }
        if update.type == "updateActiveNotifications" {
            notificationSnapshotReceived = true; notificationLiveAfter = now
        }
        try refreshAttention(now: now); changed(); return true
    }

    func notificationProjection(_ db: Database) throws -> TelegramNotificationSnapshot {
        var result = TelegramNotificationSnapshot()
        result.initialized = notificationSnapshotReceived; result.havePending = notificationHavePending
        guard notificationSnapshotReceived, account != 0 else { return result }
        let rows = try Row.fetchAll(db, sql: """
            SELECT n.*,r.kind,r.topic,r.viewed,g.sound,s.generation,s.episode,s.notifiedEpisode,m.replyToMe,
              (SELECT count(*) FROM tg_reason_messages r2 WHERE r2.chat=r.chat) AS reasons
            FROM tg_notifications n JOIN tg_notification_groups g ON g.id=n.groupID
            JOIN tg_reason_messages r ON r.chat=n.chat AND r.id=n.message JOIN tg_state s ON s.chat=n.chat
            JOIN tg_messages m ON m.chat=n.chat AND m.id=n.message
            WHERE g.type IN ('notificationGroupTypeMessages','notificationGroupTypeMentions') ORDER BY n.date,n.id LIMIT \(TelegramNotificationLimits.count)
            """)
        var identities = Set<String>()
        for row in rows {
            let chat: Int64 = row["chat"], kind = TelegramAttentionKind(rawValue: row["kind"]) ?? .direct
            let channel = kind == .channelPost
            let identity = channel ? "channel:\(chat):\(row["generation"] as String):\(row["episode"] as String? ?? "")"
                : "notification:\(row["groupID"] as Int64):\(row["id"] as Int64)"
            let id = "telegram:\(environment.rawValue):\(account):\(identity)"
            guard identities.insert(id).inserted else { continue }
            let consumed = try (channel && (row["episode"] as String?) == (row["notifiedEpisode"] as String?)) ||
                (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_notification_consumed WHERE id=?)", arguments: [id]) == true)
            let first = try Row.fetchOne(db, sql: "SELECT id,topic FROM tg_reason_messages WHERE chat=? ORDER BY id LIMIT 1", arguments: [chat])
            result.items.append(.init(id: id,
                destination: .init(environment: environment, account: account, chat: chat, topic: TelegramMessageTopic.attentionTopic(first?["topic"] ?? "")?.attentionDestination),
                message: first?["id"] ?? 0, kind: kind, count: channel ? 1 : row["reasons"], date: row["date"],
                sound: (row["sound"] as Int64) != 0 && !(row["silent"] as Bool),
                mayDeliver: (row["fresh"] as Bool) && !(row["viewed"] as Bool) && !consumed, viewed: row["viewed"],
                categoryPending: kind == .mention && (row["replyToMe"] as Bool?) == nil))
        }
        return result
    }
    func consumeNotification(_ id: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let prefix = "telegram:\(environment.rawValue):\(account):"
        guard id.hasPrefix(prefix) else { return }
        let parts = id.dropFirst(prefix.count).split(separator: ":")
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO tg_notification_consumed(id,date) VALUES (?,?)", arguments: [id,now])
            if parts.count == 3, parts[0] == "notification", let group = Int64(parts[1]), let notification = Int64(parts[2]) {
                try db.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE groupID=? AND id=?", arguments: [group,notification])
            } else if parts.count == 4, parts[0] == "channel", let chat = Int64(parts[1]) {
                try db.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE chat=?", arguments: [chat])
                try db.execute(sql: "UPDATE tg_state SET notifiedEpisode=episode WHERE chat=? AND generation=? AND episode=?", arguments: [chat,String(parts[2]),String(parts[3])])
            }
            try pruneNotificationHistory(db, now: now)
        }
        dirty = true
    }
}
