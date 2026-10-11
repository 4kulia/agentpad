import Foundation
import GRDB

struct TelegramAttentionWork {
    var key: String
    var method: String
    var chat: Int64
    var topic: String
    var message: Int64
    var cursor: Int64
    var pageSize: Int
    var version: String
    var fields: [String: TDLibValue] {
        if method == "getScopeNotificationSettings" { return ["scope": .typed(topic)] }
        var result: [String: TDLibValue] = ["chat_id": .integer(chat)]
        if method == "getMessage" { result["message_id"] = .integer(message) }
        if method == "getForumTopic", let id = TelegramMessageTopic.attentionTopic(topic)?.forumID { result["forum_topic_id"] = .integer(id) }
        if method == "getChatHistory" || method == "searchChatMessages" {
            result["from_message_id"] = .integer(cursor); result["offset"] = .integer(0); result["limit"] = .integer(Int64(pageSize))
            if method == "getChatHistory" { result["only_local"] = .bool(false) }
            else {
                result["topic_id"] = .null; result["query"] = .string(""); result["sender_id"] = .null
                result["filter"] = .typed("searchMessagesFilterUnreadMention")
            }
        }
        return result
    }
}

extension TelegramChatIndex {
    func enqueueAttentionWork(key: String, method: String, chat: Int64, topic: String = "", message: Int64 = 0,
                              lane: Int, version: String = "", db: Database, now: Int64) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO tg_work(key,method,chat,topic,message,lane,age,version)
            VALUES (?,?,?,?,?,?,coalesce((SELECT max(age)+1 FROM tg_work),?),?)
            """, arguments: [key,method,chat,topic,message,lane,now,version])
    }
    func scheduleAttentionScan(_ chat: Int64, lane: Int, force: Bool = false, db: Database, now: Int64) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT c.*,s.* FROM chats c JOIN tg_state s ON s.chat=c.id WHERE c.id=?", arguments: [chat]) else { return }
        let kind: String = row["kind"]
        let history = ["person", "bot", "channel"].contains(kind)
        let eligible = history || ["group", "supergroup", "forum"].contains(kind)
        let signature = "\(kind):\(row["lastMessage"] as Int64):\(row["inbox"] as Int64):\(row["unread"] as Int):\(row["mentions"] as Int):\(row["generation"] as String)"
        try db.execute(sql: "UPDATE tg_state SET signature=? WHERE chat=?", arguments: [signature,chat])
        guard eligible, kind != "channel" || row["channelEnabled"] as Bool else { return }
        guard force || (row["checked"] as String) != signature else { return }
        guard (history ? row["unread"] as Int : row["mentions"] as Int) > 0 || force || (kind == "channel" && row["episode"] as String? != nil) else {
            try db.execute(sql: "UPDATE tg_state SET checked=?,complete=1 WHERE chat=?", arguments: [signature,chat]); return
        }
        let version = force ? signature + ":" + UUID().uuidString : signature
        try enqueueAttentionWork(key: "scan:\(chat)", method: history ? "getChatHistory" : "searchChatMessages", chat: chat, message: row["lastMessage"],
                                 lane: lane, version: version, db: db, now: now)
        // Preserve queue age across changes, but do not let an old in-flight
        // page advance the checkpoint for a newer head.
        try db.execute(sql: "UPDATE tg_work SET cursor=0,version=?,retry=0,lane=min(lane,?),message=? WHERE key=? AND version!=?",
                       arguments: [version,lane,row["lastMessage"] as Int64,"scan:\(chat)",version])
        try db.execute(sql: "UPDATE tg_state SET complete=0 WHERE chat=?", arguments: [chat])
    }
    func prepareAttentionScan(now: Int64) throws {
        try db.write { db in
            if attentionAuditDue == 0 {
                attentionAuditDue = (try Int64.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key='attentionAudit'") ?? 0) + 86400
            }
            if now >= attentionAuditDue {
                try db.execute(sql: "UPDATE tg_state SET signature='',checked=''")
                try db.execute(sql: "INSERT OR REPLACE INTO checkpoint VALUES ('attentionAudit',?)", arguments: [now])
                attentionAuditDue = now + 86400
            }
            for scope in ["notificationSettingsScopePrivateChats", "notificationSettingsScopeGroupChats", "notificationSettingsScopeChannelChats"] {
                if try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_scopes WHERE scope=?)", arguments: [scope])! {
                    try enqueueAttentionWork(key: scope, method: "getScopeNotificationSettings", chat: 0, topic: scope, lane: 0, db: db, now: now)
                }
            }
            let ids = try Int64.fetchAll(db, sql: "SELECT chat FROM tg_state WHERE signature='' ORDER BY chat LIMIT 20")
            for id in ids { try scheduleAttentionScan(id, lane: 1, db: db, now: now) }
        }
    }
    func nextAttentionWork(lane: Int, now: Int64) throws -> TelegramAttentionWork? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tg_work WHERE lane=? AND retry<=? ORDER BY age,key LIMIT 1", arguments: [lane,now]) else { return nil }
            return TelegramAttentionWork(key: row["key"], method: row["method"], chat: row["chat"], topic: row["topic"], message: row["message"],
                                         cursor: row["cursor"], pageSize: row["pageSize"], version: row["version"])
        }
    }
    func hasAttentionWork() throws -> Bool { try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM tg_work)") ?? false } }

    func finishAttentionWork(_ work: TelegramAttentionWork, response: TDLibMessage, now: Int64) throws {
        if work.method == "getChat", response.type == "chat", response["id"]?.integer == work.chat {
            try apply(TDLibMessage("updateNewChat", ["chat": .object(response.fields)]), now: now)
            let requested = try db.read { try Bool.fetchOne($0, sql: "SELECT activationRequested FROM tg_state WHERE chat=?", arguments: [work.chat]) == true }
            if requested { try channelNotifications(work.chat, enabled: true, now: now) }
        }
        try db.write { db in
            guard try String.fetchOne(db, sql: "SELECT version FROM tg_work WHERE key=?", arguments: [work.key]) == work.version else { return }
            func finish() throws { try db.execute(sql: "DELETE FROM tg_work WHERE key=?", arguments: [work.key]) }
            func pause(_ seconds: Int64) throws { try db.execute(sql: "UPDATE tg_work SET retry=? WHERE key=?", arguments: [now + seconds,work.key]) }
            if response.type == "error" {
                if response["message"]?.string == "page_too_large" {
                    if work.pageSize > 1 { try db.execute(sql: "UPDATE tg_work SET pageSize=max(1,pageSize/2) WHERE key=?", arguments: [work.key]) }
                    else { try pause(Int64.max - now); error = "A Telegram message is too large to check. Attention scan is incomplete." }
                } else {
                    // An RPC miss is not a read/deletion receipt, even for the
                    // last channel anchor. Keep the checkpoint and episode.
                    try pause(response["code"]?.integer == 429 ? 60 : 30)
                }
                return
            }
            switch work.method {
            case "getScopeNotificationSettings":
                guard response.type == "scopeNotificationSettings" else { try pause(30); return }
                try storeAttentionScope(work.topic, response, db: db, now: now); try finish()
            case "getForumTopic":
                guard response.type == "forumTopic" else { try pause(30); return }
                try attentionSettings(response["notification_settings"]?.object, chat: work.chat, topic: work.topic,
                                      inbox: response["last_read_inbox_message_id"]?.integer, db: db, now: now)
                try finish()
            case "getMessage":
                guard response.type == "message", response["id"]?.integer == work.message,
                      response["chat_id"]?.integer == work.chat else { try pause(30); return }
                try attentionMessage(response, chat: work.chat, db: db, now: now); try finish()
            case "getChat":
                guard response.type == "chat" else { try pause(30); return }
                try finish()
            default:
                guard ["messages", "foundChatMessages"].contains(response.type) else { try pause(30); return }
                let values = response["messages"]?.array ?? []
                for value in values.prefix(100) {
                    if let raw = value.object, raw["chat_id"]?.integer == work.chat {
                        try attentionMessage(raw, chat: work.chat, db: db, now: now)
                        if let id = raw["id"]?.integer { try db.execute(sql: "INSERT OR REPLACE INTO tg_scan_seen VALUES (?,?,?)", arguments: [work.chat,id,work.version]) }
                    }
                }
                let boundary = try Int64.fetchOne(db, sql: "SELECT max(inbox,activation,snooze) FROM tg_state WHERE chat=?", arguments: [work.chat]) ?? 0
                let minimum = values.compactMap { $0.object?["id"]?.integer }.min()
                let cursor = work.method == "searchChatMessages" ? response["next_from_message_id"]?.integer ?? 0 : minimum ?? 0
                let complete = work.method == "searchChatMessages" ? cursor == 0 : values.isEmpty || (minimum.map { $0 <= boundary } ?? false)
                if complete {
                    if try String.fetchOne(db, sql: "SELECT kind FROM chats WHERE id=?", arguments: [work.chat]) == "channel" {
                        try db.execute(sql: "DELETE FROM tg_messages WHERE chat=? AND id>? AND id<=? AND id NOT IN (SELECT id FROM tg_scan_seen WHERE chat=? AND version=?)",
                                       arguments: [work.chat,boundary,work.message,work.chat,work.version])
                    }
                    try db.execute(sql: "DELETE FROM tg_scan_seen WHERE chat=?", arguments: [work.chat])
                    try db.execute(sql: "UPDATE tg_state SET checked=signature,complete=1 WHERE chat=?", arguments: [work.chat]); try finish()
                } else if cursor == work.cursor {
                    try pause(30); error = "Telegram history did not advance. Attention scan will retry."
                } else {
                    let bytes = values.reduce(0) { $0 + $1.estimatedBytes }
                    try db.execute(sql: "UPDATE tg_work SET cursor=?,pageSize=? WHERE key=?", arguments: [cursor, bytes > 2 * 1024 * 1024 ? max(1,work.pageSize/2) : work.pageSize,work.key])
                }
            }
        }
        try refreshAttention(now: now); changed()
    }
}
