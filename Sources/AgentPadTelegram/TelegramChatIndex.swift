import Foundation
import GRDB

/// Actor-owned, paged metadata only. SQL owns the unbounded account directory;
/// callers can materialize at most 50 compact rows at a time. No message bodies,
/// drafts, credentials, photos or notification payloads are stored here.
final class TelegramChatIndex {
    let db: DatabaseQueue
    let environment: TelegramEnvironment
    private(set) var account: Int64
    private(set) var revision: UInt64 = 0
    var expandedCapacity: Int?
    var orderHeld = false
    var heldVisibleCount: Int?
    private var orderDirty = true
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

    func bind(_ account: Int64, now: Int64) throws {
        guard self.account == 0 || self.account == account else { throw TelegramStorageError.accountMismatch }
        self.account = account
        try db.write { db in
            try db.execute(sql: "UPDATE chats SET kind = 'savedMessages', title = 'Saved Messages' WHERE userID = ? AND kind != 'secret'", arguments: [account])
            try db.execute(sql: "UPDATE entities SET kind = 'savedMessages', title = 'Saved Messages' WHERE family='user' AND id=?", arguments: [account])
            try observeCandidates(db, now: now)
        }
        try refreshAttention(now: now)
        changed()
    }
    func changed() { dirty = true; orderDirty = true }
    private func compact(_ value: String) -> String {
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
            "updateMessageSendSucceeded", "updateUser", "updateSupergroup"]
        guard supported.contains(update.type) else { return false }
        try db.write { db in
            switch update.type {
            case "updateUser", "updateSupergroup":
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
                try observeCandidates(db, now: now)
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
                    INSERT INTO chats(id, title, username, kind, userID, groupID, unread, mentions) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, username=excluded.username, kind=excluded.kind,
                    userID=excluded.userID, groupID=excluded.groupID, unread=excluded.unread, mentions=excluded.mentions
                    """, arguments: [id, kind == .savedMessages ? "Saved Messages" : compact(chat["title"]?.string ?? "Telegram"), name, kind.rawValue, user, group,
                                      chat["unread_count"]?.integer ?? 0, chat["unread_mention_count"]?.integer ?? 0])
                try positions(chat["positions"]?.array ?? [], chat: id, replace: true, db: db)
                try lastMessage(chat["last_message"]?.object, chat: id, db: db, now: now)
            case "updateNewMessage", "updateMessageSendSucceeded":
                if let message = update["message"]?.object, let id = message["chat_id"]?.integer { try outgoing(message, chat: id, db: db, now: now) }
            default:
                guard let id = update["chat_id"]?.integer else { return }
                switch update.type {
                case "updateChatTitle": try db.execute(sql: "UPDATE chats SET title = ? WHERE id = ? AND kind != 'savedMessages'", arguments: [compact(update["title"]?.string ?? "Telegram"), id])
                case "updateChatPosition": try positions(update["position"].map { [$0] } ?? [], chat: id, replace: false, db: db)
                case "updateChatDraftMessage", "updateChatLastMessage":
                    try positions(update["positions"]?.array ?? [], chat: id, replace: true, db: db)
                    if update.type == "updateChatLastMessage" { try lastMessage(update["last_message"]?.object, chat: id, db: db, now: now) }
                case "updateChatReadInbox": try db.execute(sql: "UPDATE chats SET unread = ? WHERE id = ?", arguments: [max(0, update["unread_count"]?.integer ?? 0), id])
                case "updateChatUnreadMentionCount": try db.execute(sql: "UPDATE chats SET mentions = ? WHERE id = ?", arguments: [max(0, update["unread_mention_count"]?.integer ?? 0), id])
                default: break
                }
            }
        }
        changed(); return true
    }
    @discardableResult func apply(_ update: TDLibMessage, now: Int64) throws -> Bool {
        let directory = try applyDirectory(update, now: now)
        let attention = try applyAttention(update, now: now)
        if attention { changed() }
        return directory || attention
    }

    private func positions(_ positions: [TDLibValue], chat: Int64, replace: Bool, db: Database) throws {
        if replace { try db.execute(sql: "UPDATE chats SET mainOrder=0, archiveOrder=0 WHERE id=?", arguments: [chat]) }
        for value in positions {
            guard let position = value.object else { continue }
            let column: String
            switch position["list"]?.object?.type {
            case "chatListMain": column = "mainOrder"
            case "chatListArchive": column = "archiveOrder"
            default: continue // Telegram folders/pins never establish local P.
            }
            try db.execute(sql: "UPDATE chats SET \(column)=? WHERE id=?", arguments: [position["order"]?.integer ?? 0, chat])
        }
    }
    private func lastMessage(_ message: TDLibMessage?, chat: Int64, db: Database, now: Int64) throws {
        try db.execute(sql: "UPDATE chats SET lastDate=? WHERE id=?", arguments: [message?["date"]?.integer ?? 0, chat])
        if let message { try outgoing(message, chat: chat, db: db, now: now) }
    }
    private func outgoing(_ message: TDLibMessage, chat: Int64, db: Database, now: Int64) throws {
        guard let candidate = TelegramRecentOutgoing.candidate(message), candidate.date > now - TelegramChatLimits.recentSeconds else { return }
        // max(date) is idempotent for duplicate final IDs and send-succeeded /
        // last-message overlap. Edits, reads and deletions never extend it.
        try db.execute(sql: """
            UPDATE chats SET candidateDate = max(candidateDate, ?),
              candidateSender = CASE WHEN ? >= candidateDate THEN ? ELSE candidateSender END WHERE id = ?
            """, arguments: [candidate.date, candidate.date, candidate.sender, chat])
        try observeCandidates(db, now: now, chat: chat)
    }
    private func observeCandidates(_ db: Database, now: Int64, chat: Int64? = nil) throws {
        guard account != 0 else { return }
        try db.execute(sql: """
            UPDATE chats SET recentDate=max(recentDate, candidateDate)
            WHERE kind NOT IN ('unknown','secret','channelDirect') AND candidateDate > ?
              AND candidateSender = ? \(chat == nil ? "" : "AND id = ?")
            """, arguments: StatementArguments([now - TelegramChatLimits.recentSeconds, account] + (chat.map { [$0] } ?? [])))
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
    private let eligible = "hidden=0 AND kind NOT IN ('unknown','secret','channelDirect')"
    private var ordering: String {
        """
        CASE WHEN \(attentionMembership) THEN 0 WHEN pinOrder IS NOT NULL THEN 1 WHEN recentDate > ? THEN 2 ELSE 3 END,
        CASE WHEN \(attentionMembership) THEN coalesce((SELECT max(date) FROM tg_reason_messages WHERE chat=chats.id),0) END DESC,
        CASE WHEN \(attentionMembership) THEN id END ASC,
        CASE WHEN pinOrder IS NOT NULL THEN pinOrder END ASC,
        CASE WHEN pinOrder IS NULL AND recentDate > ? THEN recentDate END DESC,
        CASE WHEN pinOrder IS NULL AND recentDate <= ? THEN lastDate END DESC, id ASC
        """
    }
    func project(now: Int64, force: Bool = false) throws -> TelegramChatSnapshot {
        let cutoff = now - TelegramChatLimits.recentSeconds
        if orderDirty && (!orderHeld || force) {
            try db.write { db in
                try db.execute(sql: "DELETE FROM chat_order")
                try db.execute(sql: """
                    INSERT INTO chat_order(position, chat)
                    SELECT row_number() OVER (ORDER BY \(ordering))-1, id
                    FROM chats WHERE \(eligible)
                    """, arguments: [cutoff, cutoff, cutoff])
            }
            orderDirty = false
        }
        revision &+= 1
        var result = TelegramChatSnapshot()
        result.account = .init(environment: environment, account: account, chat: 0)
        result.revision = revision; result.state = state; result.error = error
        try db.read { db in
            result.foundCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM chat_order") ?? 0
            result.automaticCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM chats WHERE \(eligible) AND (\(attentionMembership) OR pinOrder IS NOT NULL OR recentDate > ?)", arguments: [cutoff]) ?? 0
        }
        let capacity = (!force && orderHeld ? heldVisibleCount : nil) ?? expandedCapacity ?? min(result.automaticCount, result.foundCount > 8 ? 7 : 8)
        result.visibleCount = min(result.foundCount, capacity)
        result.expanded = expandedCapacity != nil
        result.firstRows = try page(offset: 0, limit: min(50, result.visibleCount), now: now)
        result.automaticRows = try automatic(now: now)
        result.attention = try attentionProjection(visibleCount: result.visibleCount)
        if force && orderHeld { heldVisibleCount = result.visibleCount }
        dirty = false
        return result
    }
    func page(offset: Int, limit: Int = 50, now: Int64) throws -> [TelegramChatRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT c.* FROM chat_order o JOIN chats c ON c.id=o.chat ORDER BY o.position LIMIT ? OFFSET ?",
                             arguments: [min(50, max(0, limit)), max(0, offset)]).map { try row($0, now: now, db: db) }
        }
    }
    func automatic(now: Int64) throws -> [TelegramChatRow] {
        let cutoff = now - TelegramChatLimits.recentSeconds
        return try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM chats WHERE \(eligible) AND (\(attentionMembership) OR pinOrder IS NOT NULL OR recentDate > ?) ORDER BY \(ordering) LIMIT 50",
                             arguments: [cutoff, cutoff, cutoff, cutoff]).map { try row($0, now: now, db: db) }
        }
    }
    func get(_ id: Int64, now: Int64) throws -> TelegramChatRow? {
        try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM chats WHERE id=?", arguments: [id]).map { try row($0, now: now, db: db) } }
    }
    func localMatches(_ query: String, now: Int64) throws -> [TelegramChatRow] {
        guard !query.isEmpty else { return try automatic(now: now) }
        // TDLib supplies its richer offline username/title matcher too. This
        // immediate cache pass includes Hidden and Archive, independent of R.
        let pattern = "%" + query.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM chats WHERE title LIKE ? ESCAPE '\\' OR username LIKE ? ESCAPE '\\'
                ORDER BY CASE WHEN lower(title)=lower(?) OR lower(username)=lower(?) THEN 0 ELSE 1 END,
                    CASE WHEN hidden=0 AND (\(attentionMembership) OR pinOrder IS NOT NULL OR recentDate > ?) THEN 0 ELSE 1 END, lastDate DESC, id LIMIT 50
                """, arguments: [pattern, pattern, query, query.trimmingCharacters(in: CharacterSet(charactersIn: "@")), now - TelegramChatLimits.recentSeconds]).map { try row($0, now: now, db: db) }
        }
    }
    func privateUser(chat: Int64) throws -> Int64? {
        try db.read { try Int64.fetchOne($0, sql: "SELECT userID FROM chats WHERE id=? AND kind IN ('person','bot','savedMessages')", arguments: [chat]) }
    }
    func userTitle(_ id: Int64) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT title FROM entities WHERE family='user' AND id=?", arguments: [id]) }
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
                lastMessageDate: 0, recentOutgoingDate: 0, isAutomatic: false), userID: user)
        }
    }
    func mode(_ id: Int64, _ mode: TelegramChatMode, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE chats SET hidden=?, pinOrder=CASE WHEN ? THEN coalesce(pinOrder, (SELECT coalesce(max(pinOrder),0)+1 FROM chats)) ELSE NULL END
                WHERE id=? AND kind NOT IN ('unknown','secret','channelDirect')
                """, arguments: [mode == .hidden, mode == .pinned, id])
            if mode == .hidden {
                try db.execute(sql: "UPDATE tg_notifications SET fresh=0 WHERE chat=?", arguments: [id])
            }
            if mode != .pinned {
                try db.execute(sql: "UPDATE tg_state SET channelEnabled=0,episode=NULL,activationRequested=0 WHERE chat=?", arguments: [id])
            }
        }
        try refreshAttention(now: now)
        changed()
    }
    func expire(now: Int64) throws -> Int64? {
        let expired = try db.write { db in
            try db.execute(sql: "UPDATE chats SET recentDate=0, candidateDate=0 WHERE recentDate > 0 AND recentDate <= ?", arguments: [now - TelegramChatLimits.recentSeconds])
            return db.changesCount
        }
        if expired > 0 { changed() }
        return try db.read { try Int64.fetchOne($0, sql: "SELECT min(recentDate)+? FROM chats WHERE recentDate > ?", arguments: [TelegramChatLimits.recentSeconds, now - TelegramChatLimits.recentSeconds]) }
    }
    private func row(_ row: Row, now: Int64, db: Database) throws -> TelegramChatRow {
        let pin: Int64? = row["pinOrder"], recent: Int64 = row["recentDate"]
        let attention = try attentionSummary(db, chat: row["id"])
        let state = try Row.fetchOne(db, sql: "SELECT channelEnabled,activationRequested,snooze FROM tg_state WHERE chat=?", arguments: [row["id"] as Int64])
        return TelegramChatRow(id: .init(environment: environment, account: account, chat: row["id"]), title: row["title"], username: row["username"],
            kind: TelegramChatKind(rawValue: row["kind"]) ?? .unknown, unreadCount: max(0, row["unread"]), unreadMentionCount: max(0, row["mentions"]),
            inMain: (row["mainOrder"] as Int64) != 0, inArchive: (row["archiveOrder"] as Int64) != 0,
            pinned: pin != nil, hidden: row["hidden"], lastMessageDate: row["lastDate"], recentOutgoingDate: recent,
            isAutomatic: attention != nil || pin != nil || recent > now - TelegramChatLimits.recentSeconds,
            attention: attention, channelNotifications: state?["channelEnabled"] ?? false,
            channelNotificationsActivating: state?["activationRequested"] ?? false, snoozed: (state?["snooze"] as Int64? ?? 0) > 0)
    }
}
