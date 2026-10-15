import Foundation
import GRDB

extension TelegramChatIndex {
    func customSummaries(binding: TelegramProfileBinding, now: Int64) throws -> [TelegramFolderSummary] {
        try validate(binding)
        try flushAttention(now: now)
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id,c.title,c.lastDate,c.hidden,c.kind,(c.unread>0 OR c.markedUnread) AS unread,
                       (\(Self.chatMuteSQL)>?) AS muted, (c.\(attentionMembership)) AS attention
                FROM chats c \(Self.chatMuteJoins)
                WHERE c.id IN (SELECT chat FROM tg_custom_member)
                """, arguments: [now]).map { row in
                TelegramFolderSummary(chat: row["id"], title: row["title"], date: row["lastDate"],
                    unread: row["unread"], muted: row["muted"], attention: row["attention"], hidden: row["hidden"],
                    available: TelegramChatKind(rawValue: row["kind"])?.eligible == true)
            }
        }
    }
    func validate(_ binding: TelegramProfileBinding) throws {
        guard self.binding == binding else { throw TelegramFolderError.staleBinding }
    }
    func customMembers(binding: TelegramProfileBinding) throws -> [UUID:Set<Int64>] {
        try validate(binding)
        return try db.read { db in
            var result: [UUID:Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT folder,chat FROM tg_custom_member") {
                guard let id = UUID(uuidString: row["folder"]) else { throw TelegramFolderError.storage }
                result[id, default: []].insert(row["chat"])
            }
            return result
        }
    }
    func setCustomMember(folder: UUID, chat: Int64, member: Bool, binding: TelegramProfileBinding) throws {
        try validate(binding)
        try db.write { db in
            if member {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chats WHERE id=? AND kind NOT IN ('unknown','secret','channelDirect'))", arguments: [chat]) == true else { throw TelegramFolderError.invalidTarget }
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_custom_member WHERE folder=? AND chat=?)", arguments: [folder.uuidString,chat]) ?? false
                if !exists {
                    guard try Int.fetchOne(db, sql: "SELECT count(*) FROM tg_custom_member WHERE folder=?", arguments: [folder.uuidString]) ?? 0 < 20_000,
                          try Int.fetchOne(db, sql: "SELECT count(*) FROM tg_custom_member") ?? 0 < 100_000 else { throw TelegramFolderError.tooLarge }
                }
                try db.execute(sql: "INSERT OR IGNORE INTO tg_custom_member VALUES (?,?)", arguments: [folder.uuidString,chat])
            } else { try db.execute(sql: "DELETE FROM tg_custom_member WHERE folder=? AND chat=?", arguments: [folder.uuidString,chat]) }
        }
        dirty = true
    }
    func applyTombstones(_ tombstones: Set<UUID>, binding: TelegramProfileBinding) throws {
        try validate(binding)
        try db.write { db in
            for id in tombstones { try db.execute(sql: "DELETE FROM tg_custom_member WHERE folder=?", arguments: [id.uuidString]) }
        }
        dirty = true
    }
    func setListCollapsed(window: UUID, list: TelegramListKey, collapsed: Bool, binding: TelegramProfileBinding) throws {
        try validate(binding)
        guard listStates[list] != nil else { throw TelegramFolderError.invalidTarget }
        try db.write { db in
            if collapsed { try db.execute(sql: "INSERT OR IGNORE INTO tg_collapse VALUES (?,?)", arguments: [window.uuidString,list.rawValue]) }
            else { try db.execute(sql: "DELETE FROM tg_collapse WHERE window=? AND list=?", arguments: [window.uuidString,list.rawValue]) }
        }
        dirty = true
    }
    func retainWindows(_ windows: Set<UUID>, binding: TelegramProfileBinding) throws {
        try validate(binding)
        try db.write { db in
            for value in try String.fetchAll(db, sql: "SELECT DISTINCT window FROM tg_collapse") where !windows.contains(where: { $0.uuidString == value }) {
                try db.execute(sql: "DELETE FROM tg_collapse WHERE window=?", arguments: [value])
            }
        }
        dirty = true
    }

    func markReadPlan(chat: Int64, only: Set<TelegramMarkReadStep>? = nil) throws -> ([(TelegramMarkReadStep,TDLibMessage)],Bool) {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT c.*,s.lastMessage FROM chats c LEFT JOIN tg_state s ON s.chat=c.id WHERE c.id=?", arguments: [chat]),
                  let kind = TelegramChatKind(rawValue: row["kind"]), kind.eligible, kind != .forum else { throw TelegramFolderError.invalidTarget }
            var steps: [(TelegramMarkReadStep,TDLibMessage)] = [], open = false
            func includes(_ step: TelegramMarkReadStep) -> Bool { only?.contains(step) ?? true }
            if row["unread"] as Int > 0, includes(.messages) {
                let target: Int64 = row["lastMessage"] ?? 0
                if target <= 0 { open = true }
                else { steps.append((.messages,TDLibMessage("viewMessages", ["chat_id": .integer(chat),"message_ids": .array([.integer(target)]),"source": .typed("messageSourceChatList"),"force_read": .bool(true)]))) }
            }
            if row["markedUnread"] as Bool, includes(.markedUnread) {
                steps.append((.markedUnread,TDLibMessage("toggleChatIsMarkedAsUnread", ["chat_id": .integer(chat),"is_marked_as_unread": .bool(false)])))
            }
            if row["mentions"] as Int > 0, includes(.mentions) { steps.append((.mentions,TDLibMessage("readAllChatMentions", ["chat_id": .integer(chat)]))) }
            return (steps,open)
        }
    }
}
