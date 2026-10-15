import Foundation
import GRDB

extension TelegramChatIndex {
    static let attentionMembershipSQL = "id IN (SELECT chat FROM tg_reason_messages UNION SELECT chat FROM tg_follow_pending)"
    var attentionMembership: String { Self.attentionMembershipSQL }
    static let reasonStrengthSQL = "CASE kind WHEN 'direct' THEN 0 WHEN 'reply' THEN 1 WHEN 'mention' THEN 2 WHEN 'botReply' THEN 3 WHEN 'groupMessage' THEN 4 ELSE 5 END"
    func attentionSummary(_ db: Database, chat: Int64, topic: TelegramMessageTopic? = nil, exactTopic: String? = nil,
                          excludingTopics: [String] = []) throws -> TelegramAttentionSummary? {
        let key = exactTopic ?? topic?.attentionKey
        let exclusion = excludingTopics.isEmpty ? "" : " AND topic NOT IN (\(excludingTopics.map { _ in "?" }.joined(separator: ",")))"
        let filter = (key == nil ? "" : " AND topic=?") + exclusion
        let args = StatementArguments([chat.databaseValue] + (key.map { [$0.databaseValue] } ?? []) + excludingTopics.map(\.databaseValue))
        let state = try Row.fetchOne(db, sql: "SELECT s.*,c.kind FROM tg_state s JOIN chats c ON c.id=s.chat WHERE chat=?", arguments: [chat])
        let wholeChat = key == nil && excludingTopics.isEmpty
        let firstRow = try wholeChat
            ? Row.fetchOne(db, sql: "SELECT * FROM tg_attention_summary WHERE chat=?", arguments: [chat])
            : Row.fetchOne(db, sql: "SELECT * FROM tg_reason_messages WHERE chat=?\(filter) ORDER BY \(Self.reasonStrengthSQL),id LIMIT 1", arguments: args)
        guard let first = firstRow else {
            guard key == nil, let state, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tg_follow_pending WHERE chat=?)", arguments: [chat]) == true else { return nil }
            return .init(destination: .init(environment: environment, account: account, chat: chat), count: 1, firstMessage: 0, lastDate: 0,
                         kind: state["kind"] as String == "channel" ? .channelPost : .groupMessage,
                         identity: "\(environment.rawValue):\(account):\(chat):remaining:\(state["generation"] as String):\(state["episode"] as String)", incomplete: true)
        }
        let kind = TelegramAttentionKind(rawValue: first["kind"]) ?? .direct
        var aggregateArgs = StatementArguments([kind.rawValue, kind.rawValue]); aggregateArgs += args
        let aggregate = try wholeChat ? first : Row.fetchOne(db, sql: "SELECT count(*) AS n,sum(kind=?) AS classCount,max(CASE WHEN kind=? THEN date END) AS date FROM tg_reason_messages WHERE chat=?\(filter)", arguments: aggregateArgs)!
        let target = TelegramChatID(environment: environment, account: account, chat: chat,
            topic: (topic ?? TelegramMessageTopic.attentionTopic(first["topic"]))?.attentionDestination)
        var identity = "\(environment.rawValue):\(account):\(chat):\(key ?? "remaining")"
        if kind.episode, let state {
            identity += ":\(state["generation"] as String):\(state["episode"] as String? ?? "")"
        }
        return .init(destination: target, count: kind == .channelPost ? 1 : aggregate["n"], firstMessage: first["id"], lastDate: aggregate["date"], kind: kind, identity: identity,
                     classCount: kind == .channelPost ? 1 : aggregate["classCount"], incomplete: state?["complete"] as Bool? == false)
    }
    func attentionProjection() throws -> TelegramAttentionSnapshot {
        try db.read { db in
            var result = TelegramAttentionSnapshot()
            result.directEnabled = try Int.fetchOne(db, sql: "SELECT value FROM checkpoint WHERE key='directAttention'") != 0
            result.totalCount = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM tg_reason_messages WHERE kind!='channelPost') +
                  (SELECT count(DISTINCT chat) FROM tg_reason_messages WHERE kind='channelPost') +
                  (SELECT count(*) FROM tg_follow_pending p WHERE NOT EXISTS(SELECT 1 FROM tg_reason_messages r WHERE r.chat=p.chat))
                """) ?? 0
            result.chatCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM chats WHERE hidden=0 AND (\(attentionMembership))") ?? 0
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
