import Foundation

/// Persisted navigation carries identity only. A DM can never be a ChannelRef.
struct ChatDMRef: Codable, Equatable, Hashable, Sendable {
    var server: String
    var account: String
    var org: String
    var dm: String
    init(_ key: ChatOrgKey, dm: String) {
        server = key.server.description; account = key.accountId; org = key.orgId; self.dm = dm
    }
    func belongs(to key: ChatOrgKey) -> Bool {
        server == key.server.description && account == key.accountId && org == key.orgId
    }
    var key: ChatOrgKey? {
        guard let address = try? ChatServerAddress(parsing: server) else { return nil }
        return ChatOrgKey(server: address, accountId: account, orgId: org)
    }
    var place: String { "dm:\(server):\(account):\(org):\(dm)" }
}

struct ChatDMCard: Codable, Equatable, Sendable, Identifiable {
    struct Peer: Codable, Equatable, Sendable {
        var accountId: String
        var name: String
        var handle: String
        var active: Bool
        enum CodingKeys: String, CodingKey { case accountId = "account_id", name, handle, active }
    }
    var dmId: String
    var peer: Peer
    var state: String
    var closedAt: String?
    var version: Int
    var createdAt: String
    var head: Int?
    var messages: [ChatDMMessageWire]?
    var messagesBefore: Int?
    var id: String { dmId }
    var writable: Bool { state == "active" && peer.active && closedAt == nil }
    enum CodingKeys: String, CodingKey {
        case dmId = "dm_id", peer, state, closedAt = "closed_at", version, createdAt = "created_at", head, messages
        case messagesBefore = "messages_before"
    }
}
struct ChatDMPage: Codable, Equatable, Sendable { var dms: [ChatDMCard]; var next: String? }
struct ChatDMMessagesPage: Codable, Equatable, Sendable { var messages: [ChatDMMessageWire]; var next: Int?; var head: Int? }

/// Deliberately distinct from channel wire decoding: no agent or file attribution.
struct ChatDMMessageWire: Codable, Equatable, Sendable {
    var messageId: String
    var dmId: String
    var threadRootId: String?
    var authorAccountId: String
    var text: String
    var mentions: [ChatMessageWire.Mention]
    var revision: Int
    var seq: Int
    var createdAt: String
    var editedAt: String?
    var deletedAt: String?
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id", dmId = "dm_id", threadRootId = "thread_root_id", authorAccountId = "author_account_id"
        case text, mentions, revision, seq, createdAt = "created_at", editedAt = "edited_at", deletedAt = "deleted_at"
    }
}

extension ChatMessage {
    init(dm m: ChatDMMessageWire) {
        messageId = m.messageId; channelId = ""; dmId = m.dmId; threadRootId = m.threadRootId
        authorAccountId = m.authorAccountId; seq = m.seq > 0 ? m.seq : nil; createdAt = m.createdAt
        hasFixed = m.seq > 0; hasMutable = true; text = m.deletedAt == nil ? m.text : ""
        mentions = m.deletedAt == nil ? m.mentions.map(\.accountId) : []
        revision = m.revision; editedAt = m.editedAt; deletedAt = m.deletedAt
    }
}

extension ChatAPI {
    func dmPage(_ org: String, after: String?, token: String) async throws -> ChatDMPage {
        var query = URLComponents(); query.queryItems = after.map { [.init(name: "after", value: $0)] }
        return try await call(ChatDMPage.self, "GET", "/v1/orgs/\(org)/dms", token: token, query: query.percentEncodedQuery)
    }
    func dm(_ org: String, id: String, token: String) async throws -> ChatDMCard {
        try await call(ChatDMCard.self, "GET", "/v1/orgs/\(org)/dms/\(id)", token: token)
    }
    func dmMessages(_ org: String, id: String, root: String? = nil, before: Int?, token: String) async throws -> ChatDMMessagesPage {
        var query = URLComponents(); query.queryItems = before.map { [.init(name: "before", value: String($0))] }
        let tail = root.map { "threads/\($0)" } ?? "messages"
        return try await call(ChatDMMessagesPage.self, "GET", "/v1/orgs/\(org)/dms/\(id)/\(tail)", token: token, query: query.percentEncodedQuery)
    }
}
