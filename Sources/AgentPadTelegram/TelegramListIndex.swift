import Foundation
import GRDB

extension TelegramChatIndex {
    static let eligibility = "c.hidden=0 AND c.kind NOT IN ('unknown','secret','channelDirect')"
    static let chatMuteSQL = "coalesce(cs.muteUntil,sc.muteUntil,9223372036854775807)"
    static let chatMuteJoins = """
        LEFT JOIN tg_settings cs ON cs.chat=c.id AND cs.topic=''
        LEFT JOIN tg_scopes sc ON sc.scope=CASE WHEN c.kind='channel' THEN 'notificationSettingsScopeChannelChats'
          WHEN c.kind IN ('person','bot','savedMessages') THEN 'notificationSettingsScopePrivateChats' ELSE 'notificationSettingsScopeGroupChats' END
        """
    static let windowSQL = """
        SELECT o.position,c.* FROM tg_list_order o JOIN chats c ON c.id=o.chat
        WHERE o.list=? AND o.position>=? AND o.position<? AND \(eligibility) ORDER BY o.position
        """

    func listKeys() throws -> [TelegramListKey] {
        try db.read { db in
            var keys = try Int64.fetchAll(db, sql: "SELECT id FROM tg_folder ORDER BY telegramIndex").map(TelegramListKey.folder)
            let position = try Int.fetchOne(db, sql: "SELECT value FROM tg_meta WHERE key='mainPosition'") ?? 0
            keys.insert(.main, at: min(keys.count, max(0,position))); keys.append(.archive)
            return keys
        }
    }
    func requiredLists() throws -> [TelegramListKey] {
        let visible = try db.read { try Set(String.fetchAll($0, sql: "SELECT list FROM tg_slot WHERE visible=1")) }
        return [.main] + (try listKeys()).filter { if case .folder = $0 { visible.contains($0.rawValue) } else { false } } + [.archive]
    }

    func folders(_ update: TDLibMessage, db: Database) throws {
        let values = (update["chat_folders"]?.array ?? []).compactMap(\.object)
        let old = Set(try Int64.fetchAll(db, sql: "SELECT id FROM tg_folder"))
        let new = Set(values.compactMap { $0["id"]?.integer })
        for id in old.subtracting(new) {
            let key = TelegramListKey.folder(id)
            for table in ["tg_slot", "tg_position", "tg_list_order", "tg_list_counts", "tg_collapse"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE list=?", arguments: [key.rawValue])
            }
            listStates.removeValue(forKey: key); dirtyLists.remove(key); countDirtyLists.remove(key)
        }
        try db.execute(sql: "DELETE FROM tg_folder")
        for (index, value) in values.enumerated() {
            guard let id = value["id"]?.integer, id > 0 else { continue }
            let key = TelegramListKey.folder(id)
            try db.execute(sql: "INSERT INTO tg_folder VALUES (?,?,?,?)", arguments: [id,
                compact(value["name"]?.object?["text"]?.object?["text"]?.string ?? ""),
                compact(value["icon"]?.object?["name"]?.string ?? ""),index])
            try db.execute(sql: "INSERT OR IGNORE INTO tg_slot VALUES (?,1)", arguments: [key.rawValue])
            if listStates[key] == nil {
                nextGeneration &+= 1; listStates[key] = ListState(generation: nextGeneration)
                dirtyLists.insert(key); countDirtyLists.insert(key)
            }
        }
        try db.execute(sql: "INSERT OR REPLACE INTO tg_meta VALUES ('mainPosition',?)", arguments: [update["main_chat_list_position"]?.integer ?? 0])
    }

    func setListVisible(_ key: TelegramListKey, visible: Bool) throws {
        guard listStates[key] != nil else { throw TelegramFolderError.invalidTarget }
        let changed = try db.write { db in
            try db.execute(sql: "UPDATE tg_slot SET visible=? WHERE list=? AND visible!=?", arguments: [visible,key.rawValue,visible])
            return db.changesCount > 0
        }
        guard changed else { return }
        nextGeneration &+= 1
        listStates[key]!.generation = nextGeneration
        // Main and Archive always reload too: their previous in-flight answer is obsolete.
        listStates[key]!.complete = false
        if !visible { listStates[key]!.windows = []; listStates[key]!.holds = [] }
        dirtyLists.insert(key); countDirtyLists.insert(key); dirty = true
    }
    func completeList(_ key: TelegramListKey, generation: UInt64) throws {
        guard listStates[key]?.generation == generation else { return }
        try db.write { try $0.execute(sql: "DELETE FROM tg_position WHERE list=? AND epoch!=?", arguments: [key.rawValue,attentionEpoch]) }
        listStates[key]!.complete = true
        dirtyLists.insert(key); countDirtyLists.insert(key); dirty = true
    }
    func hold(_ key: TelegramListKey, held: Bool, owner: UUID) {
        guard listStates[key] != nil else { return }
        if held { listStates[key]!.holds.insert(owner) } else { listStates[key]!.holds.remove(owner) }
        dirty = true
    }
    func setViewport(_ key: TelegramListKey, windows: Set<Int>) throws {
        guard listStates[key] != nil else { throw TelegramFolderError.invalidTarget }
        guard windows.allSatisfy({ $0 >= 0 && $0 <= Int.max - 50 && $0 % 50 == 0 }),
              windows.count + listStates.filter({ $0.key != key }).values.reduce(0, { $0 + $1.windows.count }) <= 5 else { throw TelegramFolderError.tooLarge }
        listStates[key]!.windows = windows; dirty = true
    }

    func rebuildList(_ key: TelegramListKey) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM tg_list_order WHERE list=?", arguments: [key.rawValue])
            try db.execute(sql: """
                INSERT INTO tg_list_order(list,position,chat)
                SELECT ?,row_number() OVER (ORDER BY p.ord DESC,p.chat DESC)-1,p.chat
                FROM tg_position p JOIN chats c ON c.id=p.chat WHERE p.list=? AND \(Self.eligibility)
                """, arguments: [key.rawValue,key.rawValue])
        }
        listStates[key]!.revision &+= 1; dirtyLists.remove(key)
    }
    func counts(_ key: TelegramListKey, now: Int64) throws -> TelegramListCounts {
        try db.write { db in
            if countDirtyLists.contains(key) {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO tg_list_counts
                    SELECT ?,count(*),coalesce(sum(c.unread>0 OR c.markedUnread),0),
                      coalesce(sum((c.unread>0 OR c.markedUnread) AND \(Self.chatMuteSQL)<=?),0),
                      coalesce(sum(c.\(attentionMembership)),0)
                    FROM tg_position p JOIN chats c ON c.id=p.chat \(Self.chatMuteJoins)
                    WHERE p.list=? AND \(Self.eligibility)
                    """, arguments: [key.rawValue,now,key.rawValue])
                countDirtyLists.remove(key)
            }
            var counts = TelegramListCounts()
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM tg_list_counts WHERE list=?", arguments: [key.rawValue]) {
                counts.rows = row["rows"]; counts.unreadItems = row["unreadItems"]
                counts.unmutedUnreadItems = row["unmutedUnreadItems"]; counts.attentionItems = row["attentionItems"]
            }
            return counts
        }
    }

    func listPage(_ key: TelegramListKey, from start: Int, revision: UInt64, now: Int64) throws -> TelegramChatPage {
        try flushAttention(now: now)
        guard start >= 0, start % 50 == 0, start <= Int.max - 50, listStates[key]?.revision == revision else { return .init(revision: revision, offset: start, rows: []) }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: Self.windowSQL, arguments: [key.rawValue,start,start + 50]).map { value in
                var result = try row(value, list: key, now: now, db: db)
                result.listPosition = value["position"]; return result
            }
            let more = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_list_order WHERE list=? AND position>=?)", arguments: [key.rawValue,start + 50]) ?? false
            return .init(revision: revision, offset: start, rows: rows, next: more ? start + 50 : nil)
        }
    }
    func page(offset: Int, limit: Int = 50, now: Int64) throws -> [TelegramChatRow] {
        Array(try listPage(.main, from: offset, revision: listStates[.main]?.revision ?? 0, now: now).rows.prefix(max(0,min(50,limit))))
    }

    func refreshAttentionOrder() throws {
        guard attentionOrderDirty, attentionHolds.isEmpty else { return }
        // Freeze ranking keys independently of live summaries and read state.
        attentionOrder = try db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM chats WHERE hidden=0 AND (\(attentionMembership))").compactMap { id -> (Int64,TelegramAttentionSummary)? in
                try attentionSummary(db, chat: id).map { (id,$0) }
            }.sorted {
                let a = $0.1.kind.tier, b = $1.1.kind.tier
                if a != b { return a < b }
                if $0.1.lastDate != $1.1.lastDate { return $0.1.lastDate > $1.1.lastDate }
                return $0.0 < $1.0
            }.map { TelegramAttentionOrderKey(chat: $0.0,tier: $0.1.kind.tier,rankingTime: $0.1.lastDate) }
        }
        attentionRevision &+= 1; attentionOrderDirty = false
    }
    func attentionPage(start: Int, revision: UInt64, now: Int64) throws -> TelegramChatPage {
        try flushAttention(now: now)
        guard revision == attentionRevision, start >= 0, start % 50 == 0, start < attentionOrder.count else { return .init(revision: revision, offset: start, rows: []) }
        let end = start + min(50,attentionOrder.count - start)
        let rows = try attentionOrder[start..<end].compactMap { key -> TelegramChatRow? in
            guard var row = try get(key.chat, now: now), !row.hidden, row.kind.eligible, row.attention != nil else { return nil }
            row.attentionOrderKey = key; return row
        }
        return .init(revision: revision, offset: start, rows: rows, next: end < attentionOrder.count ? start + 50 : nil,
            attentionFrontier: attentionOrder[end - 1], attentionKeys: Array(attentionOrder[start..<end]))
    }
    func suggestions(now: Int64) throws -> [TelegramChatRow] {
        let attention = try attentionPage(start: 0, revision: attentionRevision, now: now).rows
        let ids = Set(attention.map(\.id))
        let main = try page(offset: 0, now: now).filter { !ids.contains($0.id) }
        return Array((attention + main).prefix(50))
    }

    func project(now: Int64, force: Bool = false) throws -> TelegramChatSnapshot {
        try flushAttention(now: now)
        var result = TelegramChatSnapshot()
        result.binding = binding; result.account = .init(environment: environment, account: account, chat: 0)
        result.state = state; result.error = error
        for key in try listKeys() {
            let visible = try db.read { try Bool.fetchOne($0, sql: "SELECT visible FROM tg_slot WHERE list=?", arguments: [key.rawValue]) ?? false }
            if visible || key == .main, dirtyLists.contains(key), listStates[key]?.holds.isEmpty == true { try rebuildList(key) }
            let runtime = listStates[key]!
            let metadata = try db.read { db -> (String,String,Int,Set<UUID>) in
                var name = key == .main ? "All chats" : "Archive", icon = key == .main ? "All" : "Archive"
                if case .folder(let id) = key, let row = try Row.fetchOne(db, sql: "SELECT name,icon FROM tg_folder WHERE id=?", arguments: [id]) { name = row["name"]; icon = row["icon"] }
                let size = try Int.fetchOne(db, sql: "SELECT coalesce(max(position)+1,0) FROM tg_list_order WHERE list=?", arguments: [key.rawValue]) ?? 0
                let collapsed = Set(try String.fetchAll(db, sql: "SELECT window FROM tg_collapse WHERE list=?", arguments: [key.rawValue]).compactMap(UUID.init(uuidString:)))
                return (name,icon,size,collapsed)
            }
            var windows: [Int:TelegramChatPage] = [:]
            if visible { for start in runtime.windows { windows[start] = try listPage(key, from: start, revision: runtime.revision, now: now) } }
            result.lists.append(.init(key: key, name: metadata.0, icon: metadata.1, visible: visible, complete: runtime.complete,
                generation: runtime.generation, revision: runtime.revision, counts: try counts(key, now: now),
                capacity: min(metadata.2,runtime.capacity ?? 8), expanded: runtime.capacity != nil, windows: windows, collapsedWindows: metadata.3))
        }
        try refreshAttentionOrder()
        result.attentionRevision = attentionRevision
        let attentionPage = try attentionPage(start: 0, revision: attentionRevision, now: now)
        result.attentionRows = attentionPage.rows; result.attentionNext = attentionPage.next; result.attentionFrontier = attentionPage.attentionFrontier
        if attentionPositionIndex?.revision != attentionRevision || attentionPositionIndex?.binding != binding {
            attentionPositionIndex = TelegramAttentionOrder(binding: binding,revision: attentionRevision,keys: attentionOrder)
        }
        result.attention = try attentionProjection()
        result.attentionTotal = result.attention.chatCount
        let current = try db.read { try Set(Int64.fetchAll($0, sql: "SELECT id FROM chats WHERE hidden=0 AND (\(attentionMembership))")) }
        // Unchanged publications retain their version and the derived inactive
        // set so the sidebar can reuse its expanded attention projection.
        if attentionState?.order != attentionPositionIndex || attentionState?.liveChats != current {
            attentionState = TelegramAttentionState(order: attentionPositionIndex!,liveChats: current)
        }
        result.attentionState = attentionState
        for start in stride(from: 0, to: attentionOrder.count, by: 50) {
            result.attentionWindowCounts[start] = attentionOrder[start..<min(start + 50,attentionOrder.count)].filter { current.contains($0.chat) }.count
        }
        if !attentionHolds.isEmpty {
            result.attentionNewCount = current.subtracting(attentionOrder.map(\.chat)).count
        }
        result.suggestionRows = try suggestions(now: now)
        dirty = false
        return result
    }
}
