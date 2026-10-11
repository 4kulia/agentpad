import Foundation
import GRDB

extension TelegramChatIndex {
    var attentionMembership: String {
        "id IN (SELECT chat FROM tg_reason_messages UNION SELECT chat FROM tg_channel_pending)"
    }
    func attentionSummary(_ db: Database, chat: Int64, topic: TelegramMessageTopic? = nil, exactTopic: String? = nil,
                          excludingTopics: [String] = []) throws -> TelegramAttentionSummary? {
        let key = exactTopic ?? topic?.attentionKey
        let exclusion = excludingTopics.isEmpty ? "" : " AND topic NOT IN (\(excludingTopics.map { _ in "?" }.joined(separator: ",")))"
        let filter = (key == nil ? "" : " AND topic=?") + exclusion
        let args = StatementArguments([chat.databaseValue] + (key.map { [$0.databaseValue] } ?? []) + excludingTopics.map(\.databaseValue))
        guard let first = try Row.fetchOne(db, sql: "SELECT * FROM tg_reason_messages WHERE chat=?\(filter) ORDER BY id LIMIT 1", arguments: args) else {
            guard key == nil, let state = try Row.fetchOne(db, sql: "SELECT * FROM tg_state WHERE chat=? AND chat IN (SELECT chat FROM tg_channel_pending)", arguments: [chat]) else { return nil }
            return .init(destination: .init(environment: environment, account: account, chat: chat), count: 1, firstMessage: 0, lastDate: 0,
                         kind: .channelPost, identity: "\(environment.rawValue):\(account):\(chat):remaining:\(state["generation"] as String):\(state["episode"] as String)")
        }
        let kind = TelegramAttentionKind(rawValue: first["kind"]) ?? .direct
        let aggregate = try Row.fetchOne(db, sql: "SELECT count(*) AS n,max(date) AS date FROM tg_reason_messages WHERE chat=?\(filter)", arguments: args)!
        let target = TelegramChatID(environment: environment, account: account, chat: chat,
            topic: (topic ?? TelegramMessageTopic.attentionTopic(first["topic"]))?.attentionDestination)
        var identity = "\(environment.rawValue):\(account):\(chat):\(key ?? "remaining")"
        if kind == .channelPost, let state = try Row.fetchOne(db, sql: "SELECT generation,episode FROM tg_state WHERE chat=?", arguments: [chat]) {
            identity += ":\(state["generation"] as String):\(state["episode"] as String? ?? "")"
        }
        return .init(destination: target, count: kind == .channelPost ? 1 : aggregate["n"], firstMessage: first["id"], lastDate: aggregate["date"], kind: kind, identity: identity)
    }
    func attentionProjection(visibleCount: Int) throws -> TelegramAttentionSnapshot {
        try db.read { db in
            var result = TelegramAttentionSnapshot()
            result.directEnabled = try Int.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key='directAttention'") != 0
            result.totalCount = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM tg_reason_messages WHERE kind!='channelPost') +
                  (SELECT count(*) FROM (SELECT DISTINCT chat FROM tg_reason_messages WHERE kind='channelPost' UNION SELECT chat FROM tg_channel_pending))
                """) ?? 0
            result.chatCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM chats WHERE hidden=0 AND (\(attentionMembership))") ?? 0
            result.overflowChatCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM chat_order WHERE position>=? AND chat IN (SELECT id FROM chats WHERE \(attentionMembership))", arguments: [visibleCount]) ?? 0
            let destinations = attentionDestinations.filter { $0.account == account && $0.environment == environment }
            for id in destinations {
                let topics = destinations.filter { $0.chat == id.chat }.compactMap { $0.topic?.attentionKey }.sorted()
                var values: [TelegramAttentionSummary] = []
                if let topic = id.topic {
                    if let value = try attentionSummary(db, chat: id.chat, topic: topic) { values = [value] }
                } else {
                    // Explicitly open topics get shared reason identities. All
                    // remaining topics form one SQL aggregate: a forum with a
                    // million unread topics cannot grow the UI metadata page.
                    values = try topics.compactMap { try attentionSummary(db, chat: id.chat, exactTopic: $0) }
                    if let remainder = try attentionSummary(db, chat: id.chat, excludingTopics: topics) { values.append(remainder) }
                }
                if !values.isEmpty { result.destinations[id] = values }
                if id.topic == nil, let count = try Int.fetchOne(db, sql: "SELECT unread FROM chats WHERE id=? AND kind='channel' AND hidden=0 AND unread>0", arguments: [id.chat]) {
                    result.channelUnread[id] = count
                }
            }
            result.notifications = try notificationProjection(db)
            return result
        }
    }
}

extension TDLibValue {
    /// Conservative payload estimate without encoding/copying the JSON tree.
    var estimatedBytes: Int {
        switch self {
        case .string(let value): value.utf8.count + 2
        case .array(let values): values.reduce(2) { $0 + $1.estimatedBytes + 1 }
        case .object(let values): values.reduce(2) { $0 + $1.key.utf8.count + $1.value.estimatedBytes + 4 }
        default: 24
        }
    }
}
