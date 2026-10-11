import Foundation
import GRDB

/// This is Telegram source state, not a UI mark ledger. Only compact IDs,
/// settings, boundaries and checkpoints go to this private local database.
extension TelegramChatIndex {
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

    func attentionSettings(_ settings: TDLibMessage?, chat: Int64, topic: String = "", inbox: Int64? = nil,
                           db: Database, now: Int64) throws {
        guard let settings else { return }
        let mute: Int64? = settings["use_default_mute_for"]?.bool == false ? now + max(0, settings["mute_for"]?.integer ?? 0) : nil
        let disable: Bool? = settings["use_default_disable_mention_notifications"]?.bool == false ? settings["disable_mention_notifications"]?.bool ?? false : nil
        try db.execute(sql: """
            INSERT INTO tg_settings(chat,topic,muteUntil,disableMention,inbox) VALUES (?,?,?,?,?)
            ON CONFLICT(chat,topic) DO UPDATE SET muteUntil=excluded.muteUntil, disableMention=excluded.disableMention,
              inbox=max(inbox,excluded.inbox)
            """, arguments: [chat, topic, mute, disable, inbox ?? 0])
    }

    @discardableResult func applyAttention(_ update: TDLibMessage, now: Int64) throws -> Bool {
        let types: Set<String> = ["updateNewChat", "updateChatLastMessage", "updateNewMessage", "updateChatReadInbox",
            "updateChatUnreadMentionCount", "updateMessageMentionRead", "updateDeleteMessages", "updateChatNotificationSettings",
            "updateScopeNotificationSettings", "updateForumTopic", "updateUser", "updateSupergroup", "message", "forumTopic"]
        guard types.contains(update.type) else { return try applyNotifications(update, now: now) }
        try db.write { db in
            let chat = update["chat_id"]?.integer ?? 0
            switch update.type {
            case "updateNewChat":
                guard let value = update["chat"]?.object, let id = value["id"]?.integer else { return }
                try db.execute(sql: "INSERT OR IGNORE INTO tg_state(chat) VALUES (?)", arguments: [id])
                try db.execute(sql: "UPDATE tg_state SET inbox=max(inbox,?), lastMessage=?,fresh=? WHERE chat=?",
                               arguments: [value["last_read_inbox_message_id"]?.integer ?? 0, value["last_message"]?.object?["id"]?.integer ?? 0, attentionEpoch,id])
                try attentionSettings(value["notification_settings"]?.object, chat: id, db: db, now: now)
                if let raw = value["last_message"]?.object { try attentionMessage(raw, chat: id, db: db, now: now) }
                try scheduleAttentionScan(id, lane: 0, db: db, now: now)
            case "updateChatLastMessage":
                let raw = update["last_message"]?.object
                try db.execute(sql: "UPDATE tg_state SET lastMessage=? WHERE chat=?", arguments: [raw?["id"]?.integer ?? 0, chat])
                if let raw { try attentionMessage(raw, chat: chat, db: db, now: now) }
                try scheduleAttentionScan(chat, lane: 1, db: db, now: now)
            case "updateNewMessage", "message":
                if let raw = update.type == "message" ? update : update["message"]?.object,
                   let id = raw["chat_id"]?.integer { try attentionMessage(raw, chat: id, db: db, now: now) }
            case "updateChatReadInbox":
                try db.execute(sql: "UPDATE tg_state SET inbox=max(inbox,?) WHERE chat=?", arguments: [update["last_read_inbox_message_id"]?.integer ?? 0, chat])
                try scheduleAttentionScan(chat, lane: 1, db: db, now: now)
            case "updateChatUnreadMentionCount":
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tg_work(key,method,chat,message,lane,age,version)
                    SELECT 'mention:'||chat||':'||id,'getMessage',chat,id,0,?,'' FROM tg_messages WHERE chat=? AND unreadMention=1
                    """, arguments: [now,chat])
                try scheduleAttentionScan(chat, lane: 0, db: db, now: now)
            case "updateMessageMentionRead":
                try db.execute(sql: "INSERT INTO tg_receipts(chat,id,mentionRead) VALUES (?,?,1) ON CONFLICT(chat,id) DO UPDATE SET mentionRead=1", arguments: [chat,update["message_id"]?.integer ?? 0])
                try db.execute(sql: "UPDATE tg_messages SET unreadMention=0 WHERE chat=? AND id=?", arguments: [chat, update["message_id"]?.integer ?? 0])
            case "updateDeleteMessages":
                guard update["is_permanent"]?.bool == true, update["from_cache"]?.bool != true else { return }
                for value in update["message_ids"]?.array ?? [] {
                    if let id = value.integer {
                        try db.execute(sql: "INSERT INTO tg_receipts(chat,id,deleted) VALUES (?,?,1) ON CONFLICT(chat,id) DO UPDATE SET deleted=1", arguments: [chat,id])
                        try db.execute(sql: "DELETE FROM tg_messages WHERE chat=? AND id=?", arguments: [chat, id])
                    }
                }
                // A complete local channel index proves emptiness; otherwise
                // keep its stable episode and reconcile before closing it.
                try scheduleAttentionScan(chat, lane: 0, force: true, db: db, now: now)
            case "updateChatNotificationSettings":
                try attentionSettings(update["notification_settings"]?.object, chat: chat, db: db, now: now)
                try scheduleAttentionScan(chat, lane: 1, force: true, db: db, now: now)
            case "updateScopeNotificationSettings":
                if let scope = update["scope"]?.object?.type, let settings = update["notification_settings"]?.object {
                    try storeAttentionScope(scope, settings, db: db, now: now)
                }
            case "updateForumTopic", "forumTopic":
                let topic = update["forum_topic_id"]?.integer ?? update["info"]?.object?["forum_topic_id"]?.integer ?? 0
                let owner = chat != 0 ? chat : update["info"]?.object?["chat_id"]?.integer ?? 0
                if topic > 0 {
                    try attentionSettings(update["notification_settings"]?.object, chat: owner, topic: "forum:\(topic)",
                        inbox: update["last_read_inbox_message_id"]?.integer, db: db, now: now)
                }
            case "updateUser", "updateSupergroup":
                // Classification can arrive after updateNewChat. Queue via SQL
                // so a large account never becomes an in-memory work list.
                try db.execute(sql: "UPDATE tg_state SET signature='' WHERE chat IN (SELECT id FROM chats WHERE \(update.type == "updateUser" ? "userID" : "groupID")=?)",
                               arguments: [update[update.type == "updateUser" ? "user" : "supergroup"]?.object?["id"]?.integer ?? 0])
            default: break
            }
        }
        try refreshAttention(now: now)
        return true
    }

    func storeAttentionScope(_ scope: String, _ settings: TDLibMessage, db: Database, now: Int64) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO tg_scopes VALUES (?,?,?)", arguments: [scope,
            now + max(0, settings["mute_for"]?.integer ?? 0), settings["disable_mention_notifications"]?.bool ?? false])
    }

    func attentionMessage(_ raw: TDLibMessage, chat: Int64, db: Database, now: Int64) throws {
        guard let id = raw["id"]?.integer, id > 0 else { return }
        let receipt = try Row.fetchOne(db, sql: "SELECT * FROM tg_receipts WHERE chat=? AND id=?", arguments: [chat,id])
        guard receipt?["deleted"] as Bool? != true else { return }
        // Reply verification never treats an unavailable/foreign target as ours.
        let ours = raw["is_outgoing"]?.bool == true && raw["sender_id"]?.object?["user_id"]?.integer == account
        try db.execute(sql: "UPDATE tg_messages SET replyToMe=? WHERE replyChat=? AND replyID=?", arguments: [ours, chat, id])
        guard raw["is_outgoing"]?.bool == false,
              raw["scheduling_state"] == nil || raw["scheduling_state"] == .null,
              TelegramRecentOutgoing.userContent.contains(raw["content"]?.object?.type ?? "") else { return }
        guard let row = try Row.fetchOne(db, sql: "SELECT c.kind,s.inbox,s.channelEnabled,s.activation FROM chats c JOIN tg_state s ON s.chat=c.id WHERE c.id=?", arguments: [chat]) else { return }
        let topic = TelegramMessageTopic.decode(raw["topic_id"])
        if case .unsupported = topic { return }
        let inbox = try topic?.forumID != nil
            ? Int64.fetchOne(db, sql: "SELECT inbox FROM tg_settings WHERE chat=? AND topic=?", arguments: [chat,topic!.attentionKey]) ?? 0
            : row["inbox"] as Int64
        let kind: String = row["kind"], unread = raw["contains_unread_mention"]?.bool == true && receipt?["mentionRead"] as Bool? != true
        if !unread {
            try db.execute(sql: "UPDATE tg_messages SET unreadMention=0 WHERE chat=? AND id=? AND unreadMention=1", arguments: [chat,id])
            if db.changesCount > 0 {
                try db.execute(sql: "INSERT INTO tg_receipts(chat,id,mentionRead) VALUES (?,?,1) ON CONFLICT(chat,id) DO UPDATE SET mentionRead=1", arguments: [chat,id])
            }
        }
        guard !["savedMessages", "secret", "channelDirect"].contains(kind) else { return }
        if ["group", "supergroup", "forum"].contains(kind) && !unread { return }
        if ["person", "bot"].contains(kind) && id <= inbox && !unread { return }
        if kind == "channel" && (!(row["channelEnabled"] as Bool) || id <= max(row["activation"] as Int64, row["inbox"] as Int64)) { return }
        let reply = raw["reply_to"]?.object
        let replyID = reply?.type == "messageReplyToMessage" ? reply?["message_id"]?.integer ?? 0 : 0
        let replyChat = reply?["chat_id"]?.integer ?? chat
        // TDLib exposes unread mentions, including replies, through this flag.
        // Verify reply targets separately so confirmed replies keep their kind.
        let mentioned = unread
        let sender = raw["sender_id"]?.object
        let senderIsChat = sender?.type == "messageSenderChat"
        let senderID = sender?[senderIsChat ? "chat_id" : "user_id"]?.integer ?? 0
        try db.execute(sql: """
            INSERT INTO tg_messages(chat,id,topic,date,sender,senderIsChat,mentioned,unreadMention,replyChat,replyID,replyToMe)
            VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(chat,id) DO UPDATE SET
              unreadMention=excluded.unreadMention, mentioned=excluded.mentioned, topic=excluded.topic,
              sender=excluded.sender,senderIsChat=excluded.senderIsChat,
              replyToMe=CASE WHEN replyID=excluded.replyID AND replyChat=excluded.replyChat THEN replyToMe ELSE excluded.replyToMe END,
              replyChat=excluded.replyChat,replyID=excluded.replyID
            """, arguments: [chat, id, topic?.attentionKey ?? "", raw["date"]?.integer ?? now,
                senderID, senderIsChat, mentioned, unread, replyChat == 0 ? chat : replyChat, replyID,
                replyID == 0 ? false : nil as Bool?])
        if senderIsChat, try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chats WHERE id=?)", arguments: [senderID])! {
            try enqueueAttentionWork(key: "sender:\(senderID)", method: "getChat", chat: senderID, lane: 0, db: db, now: now)
        }
        if replyID > 0,
           try Bool.fetchOne(db, sql: "SELECT replyToMe IS NULL FROM tg_messages WHERE chat=? AND id=?", arguments: [chat,id]) == true {
            try enqueueAttentionWork(key: "reply:\(chat):\(id)", method: "getMessage", chat: replyChat == 0 ? chat : replyChat,
                                     message: replyID, lane: 0, db: db, now: now)
        }
        if let topicID = topic?.forumID,
           try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_settings WHERE chat=? AND topic=?)", arguments: [chat, "forum:\(topicID)"])! {
            try enqueueAttentionWork(key: "topic:\(chat):\(topicID)", method: "getForumTopic", chat: chat, topic: "forum:\(topicID)", lane: 0, db: db, now: now)
        }
    }

    /// Effective settings inherit topic -> chat -> scope. Mentions/replies use
    /// the sender's settings unless disable_mention_notifications routes them
    /// back through ordinary chat settings. Unknown settings fail closed.
    func refreshAttention(now: Int64) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO checkpoint VALUES ('attentionNow',?)", arguments: [now])
            try db.execute(sql: "DELETE FROM tg_reason_messages")
            try db.execute(sql: """
                INSERT INTO tg_reason_messages
                SELECT m.chat,m.id,m.topic,m.date,
                  CASE c.kind WHEN 'person' THEN 'direct' WHEN 'bot' THEN 'botReply' WHEN 'channel' THEN 'channelPost'
                    ELSE CASE WHEN m.replyToMe=1 THEN 'reply' ELSE 'mention' END END,m.viewed
                FROM tg_messages m JOIN chats c ON c.id=m.chat JOIN tg_state s ON s.chat=m.chat
                LEFT JOIN tg_settings cs ON cs.chat=m.chat AND cs.topic=''
                LEFT JOIN tg_settings ts ON ts.chat=m.chat AND ts.topic=m.topic AND m.topic!=''
                LEFT JOIN tg_scopes sc ON sc.scope=CASE WHEN c.kind='channel' THEN 'notificationSettingsScopeChannelChats'
                  WHEN c.kind IN ('person','bot') THEN 'notificationSettingsScopePrivateChats' ELSE 'notificationSettingsScopeGroupChats' END
                LEFT JOIN tg_settings sender ON sender.chat=m.sender AND sender.topic=''
                LEFT JOIN chats senderChat ON m.senderIsChat=1 AND senderChat.id=m.sender
                LEFT JOIN tg_scopes ps ON ps.scope=CASE
                  WHEN m.senderIsChat=0 AND m.sender!=0 THEN 'notificationSettingsScopePrivateChats'
                  WHEN senderChat.kind='channel' THEN 'notificationSettingsScopeChannelChats'
                  WHEN senderChat.kind IN ('group','supergroup','forum') THEN 'notificationSettingsScopeGroupChats' END
                WHERE c.hidden=0 AND m.id>s.snooze
                  AND (m.topic NOT LIKE 'forum:%' OR ts.chat IS NOT NULL)
                  AND CASE WHEN c.kind IN ('group','supergroup','forum') AND coalesce(ts.disableMention,cs.disableMention,sc.disableMention,1)=0
                    THEN coalesce(sender.muteUntil,ps.muteUntil,9223372036854775807)
                    ELSE coalesce(ts.muteUntil,cs.muteUntil,sc.muteUntil,9223372036854775807) END <= ?
                  AND (
                    (c.kind='person' AND EXISTS(SELECT 1 FROM entities e WHERE e.family='user' AND e.id=c.userID AND e.kind='person')
                      AND coalesce((SELECT value FROM checkpoint WHERE key='directAttention'),1)=1 AND (m.id>s.inbox OR m.unreadMention=1))
                    OR (c.kind='bot' AND m.replyToMe=1 AND (m.id>CASE WHEN m.topic LIKE 'forum:%' THEN ts.inbox ELSE s.inbox END OR m.unreadMention=1))
                    OR (c.kind IN ('group','supergroup','forum') AND m.unreadMention=1 AND (m.mentioned=1 OR m.replyToMe=1))
                    OR (c.kind='channel' AND s.channelEnabled=1 AND c.pinOrder IS NOT NULL AND m.id>max(s.activation,s.inbox))
                  )
                """, arguments: [now])
            // Allocate once per unread channel episode; anchors are projections,
            // not identity. Cache eviction/errors never prove an episode empty.
            try db.execute(sql: """
                UPDATE tg_state SET episode=lower(hex(randomblob(16))) WHERE episode IS NULL AND channelEnabled=1
                  AND EXISTS(SELECT 1 FROM tg_reason_messages r WHERE r.chat=tg_state.chat AND r.kind='channelPost');
                UPDATE tg_state SET episode=NULL WHERE channelEnabled=0 OR
                  (complete=1 AND NOT EXISTS(SELECT 1 FROM tg_messages m WHERE m.chat=tg_state.chat AND m.id>max(activation,inbox,snooze)));
                DELETE FROM tg_messages WHERE unreadMention=0 AND id <= CASE WHEN topic LIKE 'forum:%'
                  THEN coalesce((SELECT inbox FROM tg_settings WHERE chat=tg_messages.chat AND topic=tg_messages.topic),0)
                  ELSE coalesce((SELECT inbox FROM tg_state WHERE chat=tg_messages.chat),0) END;
                """)
        }
        attentionExpiry = try db.read {
            try Int64.fetchOne($0, sql: "SELECT min(muteUntil) FROM (SELECT muteUntil FROM tg_settings UNION ALL SELECT muteUntil FROM tg_scopes) WHERE muteUntil>?", arguments: [now]) ?? .max
        }
    }

    func setDirectAttention(_ enabled: Bool, now: Int64) throws {
        try checkpoint("directAttention", value: enabled ? 1 : 0)
        if !enabled { try db.write { try $0.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE chat IN (SELECT id FROM chats WHERE kind='person')") } }
        try refreshAttention(now: now); changed()
    }
    func snooze(_ chat: Int64, undo: Bool, now: Int64) throws {
        try db.write { db in
            if undo { try db.execute(sql: "UPDATE tg_state SET snooze=previousSnooze WHERE chat=?", arguments: [chat]) }
            else {
                try db.execute(sql: "UPDATE tg_state SET previousSnooze=snooze,snooze=max(lastMessage,coalesce((SELECT max(id) FROM tg_messages WHERE chat=?),0)),episode=NULL WHERE chat=?", arguments: [chat,chat])
                try db.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE chat=?", arguments: [chat])
            }
        }
        try refreshAttention(now: now); changed()
    }
    func channelNotifications(_ chat: Int64, enabled: Bool, now: Int64) throws {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM chats WHERE id=? AND kind='channel' AND pinOrder IS NOT NULL AND hidden=0", arguments: [chat]) else { return }
            _ = row
            // updateNewChat has established the current head. If it has not,
            // activation waits for a fresh getChat snapshot rather than using 0.
            if enabled, try String.fetchOne(db, sql: "SELECT fresh FROM tg_state WHERE chat=?", arguments: [chat]) != attentionEpoch {
                try db.execute(sql: "UPDATE tg_state SET activationRequested=1 WHERE chat=?", arguments: [chat])
                try enqueueAttentionWork(key: "activate:\(chat)", method: "getChat", chat: chat, lane: 0, db: db, now: now); return
            }
            try db.execute(sql: "UPDATE tg_state SET channelEnabled=?,activation=lastMessage,generation=?,episode=NULL,complete=1,activationRequested=0 WHERE chat=?",
                           arguments: [enabled, UUID().uuidString, chat])
        }
        try refreshAttention(now: now); changed()
    }
    func viewedMessages(chat: Int64, ids: Set<Int64>, now: Int64) throws {
        guard !ids.isEmpty else { return }
        let affected = try db.write { db in
            var affected = false
            for id in ids {
                try db.execute(sql: "UPDATE tg_messages SET viewed=1 WHERE chat=? AND id=? AND viewed=0", arguments: [chat,id])
                guard db.changesCount > 0 else { continue }
                try db.execute(sql: "UPDATE tg_reason_messages SET viewed=1 WHERE chat=? AND id=? AND viewed=0", arguments: [chat,id])
                affected = affected || db.changesCount > 0
            }
            return affected
        }
        // Viewing changes delivery eligibility only, never membership or order.
        if affected { dirty = true }
    }
}
