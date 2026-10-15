import Foundation
import GRDB

/// Actor-owned, paged metadata only. SQL owns the unbounded account directory;
/// callers can materialize at most 50 compact rows at a time. No message bodies,
/// drafts, credentials, photos or notification payloads are stored here.
final class TelegramChatIndex {
    let db: DatabaseQueue
    let environment: TelegramEnvironment
    private(set) var account: Int64
    let directory: URL
    let connectionID: UUID
    var binding: TelegramProfileBinding { .init(environment: environment, account: account, connectionID: connectionID) }
    struct ListState {
        var revision: UInt64 = 0
        var generation: UInt64 = 0
        var complete = false
        var holds = Set<UUID>()
        var capacity: Int?
        var windows = Set<Int>()
    }
    var listStates: [TelegramListKey: ListState] = [.main: ListState(), .archive: ListState()]
    var dirtyLists = Set<TelegramListKey>([.main, .archive])
    var countDirtyLists = Set<TelegramListKey>([.main, .archive])
    var nextGeneration: UInt64 = 0
    var attentionOrder: [TelegramAttentionOrderKey] = []
    var attentionRevision: UInt64 = 0
    var attentionPositionIndex: TelegramAttentionOrder?
    var attentionState: TelegramAttentionState?
    var attentionHolds = Set<UUID>()
    var attentionOrderDirty = true
    var attentionFullRebuild = true
    let initialRetryNotBefore: Int64
    var notificationSnapshotReceived = false
    var notificationHavePending = false
    var notificationLiveAfter: Int64 = .max
    var notificationHistoryExpiry: Int64 = 0
    var attentionExpiry: Int64 = .max
    var attentionAuditDue: Int64 = 0
    var attentionDestinations = Set<TelegramChatID>()
    let attentionEpoch = UUID().uuidString
    var dirty = true
    var state = TelegramChatScanState.scanning
    var error: String?

    init(directory: URL, environment: TelegramEnvironment, account: Int64,
         migrationCheckpoint: ((String) throws -> Void)? = nil) throws {
        self.environment = environment; self.account = account; self.directory = directory
        let url = directory.appendingPathComponent("chat-index.sqlite")
        if FileManager.default.fileExists(atPath: url.path) { try TelegramProfileStore.validate(url, directory: false) }
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try TelegramProfileStore.validate(sidecar, directory: false) }
        }
        let version = try Self.storedVersion(at: url)
        connectionID = try Self.prepareMigration(directory: directory, version: version, environment: environment)
        if !FileManager.default.fileExists(atPath: url.path) { try TelegramProfileStore.write(Data(), to: url) }
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction("tg_lower", argumentCount: 1, pure: true) { arguments in
                String.fromDatabaseValue(arguments[0])?.lowercased()
            })
            // Temporary metadata must not spill Telegram IDs outside this profile.
            try db.execute(sql: "PRAGMA journal_mode = DELETE; PRAGMA cache_size = -2048; PRAGMA temp_store = MEMORY; PRAGMA mmap_size = 0")
        }
        db = try DatabaseQueue(path: url.path, configuration: config)
        initialRetryNotBefore = try db.read { db in
            guard try db.tableExists("checkpoint") else { return 0 }
            return try Int64.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key='retryNotBefore'") ?? 0
        }
        try installSchema(version: version, migrationCheckpoint: migrationCheckpoint)
        for key in try listKeys() { listStates[key] = ListState(); dirtyLists.insert(key); countDirtyLists.insert(key) }
    }

    func bind(_ account: Int64, now: Int64) throws {
        guard self.account == 0 || self.account == account else { throw TelegramStorageError.accountMismatch }
        self.account = account
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET kind = 'savedMessages', title = 'Saved Messages' WHERE userID = ? AND kind != 'secret'", arguments: [account])
            try db.execute(sql: "UPDATE entities SET kind = 'savedMessages', title = 'Saved Messages' WHERE family='user' AND id=?", arguments: [account])
        }
        try refreshAttention(now: now)
        changed()
    }
    func changed() {
        dirty = true; attentionOrderDirty = true
        countDirtyLists.formUnion(listStates.keys)
    }
    func compact(_ value: String) -> String {
        // A grapheme can contain arbitrarily many combining scalars. Bound
        // UTF-8 bytes, not Character count, for the 4 MiB metadata budget.
        String(decoding: value.utf8.prefix(1024), as: UTF8.self)
    }
    private func username(_ value: TDLibMessage) -> String {
        compact(value["usernames"]?.object?["active_usernames"]?.array.first?.string ?? "")
    }

    @discardableResult private func applyDirectory(_ update: TDLibMessage, now: Int64) throws -> Bool {
        let supported: Set<String> = ["updateNewChat", "updateChatTitle", "updateChatPosition", "updateChatLastMessage",
            "updateChatDraftMessage", "updateChatReadInbox", "updateChatUnreadMentionCount", "updateNewMessage",
            "updateMessageSendSucceeded", "updateUser", "updateSupergroup", "updateChatFolders", "updateChatIsMarkedAsUnread"]
        guard supported.contains(update.type) else { return false }
        try db.write { db in
            switch update.type {
            case "updateChatFolders": try folders(update, db: db)
            case "updateUser", "updateSupergroup":
                dirtyLists.formUnion(listStates.keys)
                let family = update.type == "updateUser" ? "user" : "group"
                guard let value = update[family == "user" ? "user" : "supergroup"]?.object,
                      let id = value["id"]?.integer else { return }
                let kind: TelegramChatKind
                if family == "user" { kind = id == account ? .savedMessages : value["type"]?.object?.type == "userTypeBot" ? .bot : .person }
                else if value["is_direct_messages_group"]?.bool == true { kind = .channelDirect }
                else if value["is_channel"]?.bool == true { kind = .channel }
                else { kind = value["is_forum"]?.bool == true ? .forum : .supergroup }
                let title = kind == .savedMessages ? "Saved Messages" : compact([value["first_name"]?.string, value["last_name"]?.string].compactMap { $0 }.map(compact).joined(separator: " "))
                try db.execute(sql: "INSERT OR REPLACE INTO entities VALUES (?, ?, ?, ?, ?)", arguments: [id, family, title, username(value), kind.rawValue])
                try db.execute(sql: "UPDATE chats SET kind = ?, username = ? WHERE \(family == "user" ? "userID" : "groupID") = ? AND kind != 'secret'",
                               arguments: [kind.rawValue, username(value), id])
            case "updateNewChat":
                guard let chat = update["chat"]?.object, let id = chat["id"]?.integer else { return }
                let type = chat["type"]?.object
                let user = ["chatTypePrivate", "chatTypeSecret"].contains(type?.type ?? "") ? type?["user_id"]?.integer ?? 0 : 0
                let group = type?.type == "chatTypeSupergroup" ? type?["supergroup_id"]?.integer ?? 0 : 0
                var kind: TelegramChatKind = switch type?.type {
                case "chatTypePrivate": user == account ? .savedMessages : .person
                case "chatTypeBasicGroup": .group
                case "chatTypeSupergroup": .unknown // classify channel-DM before any supergroup route
                case "chatTypeSecret": .secret
                default: .unknown
                }
                let entity = try Row.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ? AND family = ?", arguments: [group == 0 ? user : group, group == 0 ? "user" : "group"])
                if kind != .secret, let raw: String = entity?["kind"], let known = TelegramChatKind(rawValue: raw) { kind = known }
                let name: String = entity?["username"] ?? ""
                try db.execute(sql: """
                    INSERT INTO chats(id, title, username, kind, userID, groupID, unread, mentions, markedUnread) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, username=excluded.username, kind=excluded.kind,
                    userID=excluded.userID, groupID=excluded.groupID, unread=excluded.unread, mentions=excluded.mentions, markedUnread=excluded.markedUnread
                    """, arguments: [id, kind == .savedMessages ? "Saved Messages" : compact(chat["title"]?.string ?? "Telegram"), name, kind.rawValue, user, group,
                                      chat["unread_count"]?.integer ?? 0, chat["unread_mention_count"]?.integer ?? 0, chat["is_marked_as_unread"]?.bool ?? false])
                try positions(chat["positions"]?.array ?? [], chat: id, replace: true, db: db)
                try lastMessage(chat["last_message"]?.object, chat: id, db: db, now: now)
            case "updateNewMessage", "updateMessageSendSucceeded":
                break // Last activity is the authoritative chat.last_message, never a send candidate.
            default:
                guard let id = update["chat_id"]?.integer else { return }
                switch update.type {
                case "updateChatTitle": try db.execute(sql: "UPDATE chats SET title = ? WHERE id = ? AND kind != 'savedMessages'", arguments: [compact(update["title"]?.string ?? "Telegram"), id])
                case "updateChatPosition": try positions(update["position"].map { [$0] } ?? [], chat: id, replace: false, db: db)
                case "updateChatDraftMessage", "updateChatLastMessage":
                    try positions(update["positions"]?.array ?? [], chat: id, replace: true, db: db)
                    if update.type == "updateChatLastMessage" { try lastMessage(update["last_message"]?.object, chat: id, db: db, now: now) }
                case "updateChatIsMarkedAsUnread": try db.execute(sql: "UPDATE chats SET markedUnread=? WHERE id=?", arguments: [update["is_marked_as_unread"]?.bool ?? false, id])
                case "updateChatReadInbox": try db.execute(sql: "UPDATE chats SET unread = ? WHERE id = ?", arguments: [max(0, update["unread_count"]?.integer ?? 0), id])
                case "updateChatUnreadMentionCount": try db.execute(sql: "UPDATE chats SET mentions = ? WHERE id = ?", arguments: [max(0, update["unread_mention_count"]?.integer ?? 0), id])
                default: break
                }
            }
        }
        dirty = true; return true
    }
    @discardableResult func apply(_ update: TDLibMessage, now: Int64) throws -> Bool {
        let directory = try applyDirectory(update, now: now)
        let attention = try applyAttention(update, now: now)
        if directory || attention {
            let localTypes: Set<String> = ["updateNewChat","updateChatTitle","updateChatPosition","updateChatLastMessage","updateChatDraftMessage",
                "updateChatReadInbox","updateChatUnreadMentionCount","updateChatIsMarkedAsUnread","updateNewMessage","updateMessageSendSucceeded",
                "updateMessageMentionRead","updateDeleteMessages"]
            if localTypes.contains(update.type), let chat = update["chat_id"]?.integer ?? update["chat"]?.object?["id"]?.integer ?? update["message"]?.object?["chat_id"]?.integer {
                dirty = true; attentionOrderDirty = true
                let lists = try db.read { try String.fetchAll($0,sql: "SELECT list FROM tg_position WHERE chat=?",arguments: [chat]) }
                countDirtyLists.formUnion(lists.compactMap(TelegramListKey.init(rawValue:)))
            } else { changed() }
        }
        return directory || attention
    }

    private func positions(_ positions: [TDLibValue], chat: Int64, replace: Bool, db: Database) throws {
        let old = try String.fetchAll(db, sql: "SELECT list FROM tg_position WHERE chat=?", arguments: [chat]).compactMap(TelegramListKey.init(rawValue:))
        dirtyLists.formUnion(old); countDirtyLists.formUnion(old)
        if replace { try db.execute(sql: "DELETE FROM tg_position WHERE chat=?", arguments: [chat]) }
        for value in positions {
            guard let position = value.object, let key = TelegramListKey(position["list"]?.object) else { continue }
            let order = position["order"]?.integer ?? 0
            if order == 0 { try db.execute(sql: "DELETE FROM tg_position WHERE list=? AND chat=?", arguments: [key.rawValue,chat]) }
            else {
                try db.execute(sql: "INSERT OR REPLACE INTO tg_position VALUES (?,?,?,?,?)",
                               arguments: [chat,key.rawValue,order,position["is_pinned"]?.bool ?? false,attentionEpoch])
            }
            dirtyLists.insert(key); countDirtyLists.insert(key)
        }
    }
    private func lastMessage(_ message: TDLibMessage?, chat: Int64, db: Database, now: Int64) throws {
        try db.execute(sql: "UPDATE chats SET lastDate=?,lastOutgoing=? WHERE id=?",
                       arguments: [message?["date"]?.integer ?? 0,message?["is_outgoing"]?.bool ?? false,chat])
    }

    func checkpoint(_ key: String) throws -> Int64 {
        try db.read { try Int64.fetchOne($0, sql: "SELECT value FROM checkpoint WHERE key=?", arguments: [key]) ?? 0 }
    }
    func checkpoint(_ key: String, value: Int64) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO checkpoint VALUES (?,?)", arguments: [key, value]) }
        dirty = true
    }
    func enqueueOpened(_ chat: Int64, now: Int64) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO recently_opened VALUES (?, ?)", arguments: [chat, now]) }
    }
    func nextOpened() throws -> Int64? {
        try db.read { try Int64.fetchOne($0, sql: "SELECT chat FROM recently_opened ORDER BY opened, chat LIMIT 1") }
    }
    func finishOpened(_ chat: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM recently_opened WHERE chat=?", arguments: [chat]) }
    }
    func get(_ id: Int64, now: Int64) throws -> TelegramChatRow? {
        try flushAttention(now: now)
        return try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM chats WHERE id=?", arguments: [id]).map { try row($0, now: now, db: db) } }
    }
    func localMatches(_ query: String, now: Int64) throws -> [TelegramChatRow] {
        guard !query.isEmpty else { return try suggestions(now: now) }
        let normalized = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        let pattern = "%" + normalized.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM chats WHERE tg_lower(title) LIKE ? ESCAPE '\\' OR tg_lower(username) LIKE ? ESCAPE '\\' ORDER BY \(TelegramSearchRank.sql) LIMIT 50",
                             arguments: [pattern,pattern,normalized,normalized]).map { try row($0, now: now, db: db) }
        }
    }
    func privateUser(chat: Int64) throws -> Int64? {
        try db.read { try Int64.fetchOne($0, sql: "SELECT userID FROM chats WHERE id=? AND kind IN ('person','bot','savedMessages')", arguments: [chat]) }
    }
    func userTitle(_ id: Int64) throws -> String? {
        // The saved-chat alias in the directory is not a person's name.
        if id == account { return "You" }
        return try db.read { try String.fetchOne($0, sql: "SELECT title FROM entities WHERE family='user' AND id=?", arguments: [id]) }
    }
    func chatTitle(_ id: Int64) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT title FROM chats WHERE id=?", arguments: [id]) }
    }
    func contact(_ user: Int64, now: Int64) throws -> TelegramSearchHit? {
        try db.read { db in
            if let found = try Row.fetchOne(db, sql: "SELECT * FROM chats WHERE userID=? AND kind != 'secret' LIMIT 1", arguments: [user]) {
                return TelegramSearchHit(row: try row(found, now: now, db: db))
            }
            guard let entity = try Row.fetchOne(db, sql: "SELECT * FROM entities WHERE family='user' AND id=?", arguments: [user]) else { return nil }
            return TelegramSearchHit(row: TelegramChatRow(id: .init(environment: environment, account: account, chat: 0),
                title: user == account ? "Saved Messages" : entity["title"], username: entity["username"],
                kind: user == account ? .savedMessages : TelegramChatKind(rawValue: entity["kind"]) ?? .person,
                unreadCount: 0, unreadMentionCount: 0, inMain: false, inArchive: false, pinned: false, hidden: false,
                lastMessageDate: 0, knownRelevant: false), userID: user)
        }
    }
    func mode(_ id: Int64, _ mode: TelegramChatMode, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET hidden=? WHERE id=? AND kind NOT IN ('unknown','secret','channelDirect')", arguments: [mode == .hidden,id])
            if mode == .hidden {
                try db.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE chat=?", arguments: [id])
                try db.execute(sql: "UPDATE tg_state SET followEnabled=0,episode=NULL,activating=0 WHERE chat=?", arguments: [id])
                try db.execute(sql: "DELETE FROM tg_work WHERE key IN (?,?)", arguments: ["activate:\(id)","history:\(id)"])
            }
            let lists = try String.fetchAll(db, sql: "SELECT list FROM tg_position WHERE chat=?", arguments: [id]).compactMap(TelegramListKey.init(rawValue:))
            dirtyLists.formUnion(lists); countDirtyLists.formUnion(lists)
        }
        attentionFullRebuild = true; dirty = true; attentionOrderDirty = true
    }
    func row(_ row: Row, list: TelegramListKey? = nil, now: Int64, db: Database) throws -> TelegramChatRow {
        let id: Int64 = row["id"]
        let attention = try attentionSummary(db, chat: id)
        let state = try Row.fetchOne(db, sql: "SELECT followEnabled,activating,snooze FROM tg_state WHERE chat=?", arguments: [id])
        let positions = try Row.fetchAll(db, sql: "SELECT list,pinned FROM tg_position WHERE chat=?", arguments: [id])
        let known = try Bool.fetchOne(db, sql: "SELECT \(TelegramSearchRank.relevantSQL) FROM chats WHERE id=?", arguments: [id]) ?? false
        let mute = try Int64.fetchOne(db, sql: "SELECT \(Self.chatMuteSQL) FROM chats c \(Self.chatMuteJoins) WHERE c.id=?", arguments: [id]) ?? .max
        return TelegramChatRow(id: .init(environment: environment, account: account, chat: id), title: row["title"], username: row["username"],
            kind: TelegramChatKind(rawValue: row["kind"]) ?? .unknown, unreadCount: max(0, row["unread"]), unreadMentionCount: max(0, row["mentions"]),
            inMain: positions.contains { $0["list"] as String == "main" }, inArchive: positions.contains { $0["list"] as String == "archive" },
            pinned: list.map { key in positions.contains { $0["list"] as String == key.rawValue && $0["pinned"] as Bool } } ?? false,
            hidden: row["hidden"], lastMessageDate: row["lastDate"], knownRelevant: known,
            markedUnread: row["markedUnread"], muted: mute > now, lastOutgoing: row["lastOutgoing"], attention: attention,
            followEnabled: state?["followEnabled"] ?? false, followActivating: state?["activating"] ?? false,
            snoozed: (state?["snooze"] as Int64? ?? 0) > 0,
            lists: Set(positions.compactMap { TelegramListKey(rawValue: $0["list"]) }))
    }
}
