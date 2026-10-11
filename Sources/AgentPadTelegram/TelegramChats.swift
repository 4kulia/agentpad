import Foundation

public struct TelegramChatID: Codable, Hashable, Sendable {
    public let environment: TelegramEnvironment
    public let account: Int64
    public let chat: Int64
    /// Nil is the chat (or forum topic list), never an alias for General.
    public let topic: TelegramMessageTopic?
    public init(environment: TelegramEnvironment, account: Int64, chat: Int64, topic: TelegramMessageTopic? = nil) {
        self.environment = environment; self.account = account; self.chat = chat; self.topic = topic
    }
    public var root: Self { withTopic(nil) }
    public func withTopic(_ topic: TelegramMessageTopic?) -> Self { .init(environment: environment, account: account, chat: chat, topic: topic) }
}

public enum TelegramChatKind: String, Codable, Sendable {
    case person, group, supergroup, channel, forum, bot, savedMessages, secret, channelDirect, unknown
    public var eligible: Bool { self != .secret && self != .channelDirect && self != .unknown }
}
public enum TelegramChatMode: String, Sendable { case auto, pinned, hidden }
public struct TelegramChatRow: Identifiable, Equatable, Sendable {
    public var id: TelegramChatID
    public var title: String
    public var username: String
    public var kind: TelegramChatKind
    public var unreadCount: Int
    public var unreadMentionCount: Int
    public var inMain: Bool
    public var inArchive: Bool
    public var pinned: Bool
    public var hidden: Bool
    public var lastMessageDate: Int64
    public var recentOutgoingDate: Int64
    public var isAutomatic: Bool
    public var attention: TelegramAttentionSummary? = nil
    public var channelNotifications = false
    public var channelNotificationsActivating = false
    public var snoozed = false
}
public enum TelegramChatScanState: Equatable, Sendable {
    case disconnected, scanning, complete, paused(String)
}
public struct TelegramChatSnapshot: Equatable, Sendable {
    public var account: TelegramChatID?
    public var revision: UInt64 = 0
    public var state: TelegramChatScanState = .disconnected
    public var foundCount = 0
    public var automaticCount = 0
    public var visibleCount = 0
    public var expanded = false
    public var firstRows: [TelegramChatRow] = []
    public var automaticRows: [TelegramChatRow] = []
    public var error: String?
    public var attention = TelegramAttentionSnapshot()
    public var overflow: Int { max(0, foundCount - visibleCount) }
    public init() {}
}
public struct TelegramChatPage: Sendable {
    public let revision: UInt64
    public let offset: Int
    public let rows: [TelegramChatRow]
}
public struct TelegramSearchHit: Identifiable, Equatable, Sendable {
    public var row: TelegramChatRow
    /// Contacts retain a user identity until the user actually opens one.
    public var userID: Int64?
    public var id: String { "\(row.id.environment.rawValue):\(row.id.account):\(userID.map { "user:\($0)" } ?? "chat:\(row.id.chat)")" }
    public init(row: TelegramChatRow, userID: Int64? = nil) { self.row = row; self.userID = userID }
}
public struct TelegramSearchSnapshot: Sendable {
    public var query: String
    public var hits: [TelegramSearchHit]
    public var searching: Bool
    public var notice: String?
    public init(query: String, hits: [TelegramSearchHit] = [], searching: Bool = false, notice: String? = nil) {
        self.query = query; self.hits = hits; self.searching = searching; self.notice = notice
    }
}
public protocol TelegramChatProvider: Sendable {
    func chatSnapshots() async -> AsyncStream<TelegramChatSnapshot>
    func chatPage(offset: Int, revision: UInt64) async -> TelegramChatPage
    func expandChats(showLess: Bool) async
    func holdChatOrder(_ held: Bool, owner: UUID) async
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) async
    func searchTelegram(_ query: String) async -> AsyncStream<TelegramSearchSnapshot>
    func resolveChat(_ hit: TelegramSearchHit) async -> TelegramChatRow?
    func didOpenChat(_ id: TelegramChatID) async
    func chat(_ id: TelegramChatID) async -> TelegramChatRow?
    func setChatScanPaused(_ reason: String?) async
    func setAttentionDestinations(_ destinations: Set<TelegramChatID>) async
    func setDirectAttention(_ enabled: Bool) async
    func snoozeAttention(_ id: TelegramChatID, undo: Bool) async
    func setChannelNotifications(_ id: TelegramChatID, enabled: Bool) async
    func consumeNotification(_ id: String) async -> Bool
}

enum TelegramChatLimits {
    static let page = 50
    static let recentSeconds: Int64 = 7 * 24 * 60 * 60
    static let metadataRows = 1000
    static let interactiveCalls = 6
}

/// Explicit allowlist from TDLib 42e6a525 MessageContent. Unknown and service
/// constructors never establish recency. No content text survives reduction.
enum TelegramRecentOutgoing {
    static let userContent: Set<String> = [
        "messageText", "messageRichMessage", "messageAnimation", "messageAudio", "messageDocument",
        "messagePaidMedia", "messagePhoto", "messageSticker", "messageVideo", "messageVideoNote",
        "messageVoiceNote", "messageLiveLocation", "messageLocation", "messageVenue", "messageContact",
        "messageAnimatedEmoji", "messageDice", "messageGame", "messagePoll", "messageStakeDice",
        "messageStory", "messageChecklist", "messageInvoice", "messageGiveaway"
    ]
    static func candidate(_ message: TDLibMessage) -> (date: Int64, sender: Int64)? {
        guard message["is_outgoing"]?.bool == true,
              message["sending_state"] == nil || message["sending_state"] == .null,
              message["scheduling_state"] == nil || message["scheduling_state"] == .null,
              let id = message["id"]?.integer, id > 0, id & ((1 << 20) - 1) == 0,
              userContent.contains(message["content"]?.object?.type ?? ""),
              let date = message["date"]?.integer, date > 0 else { return nil }
        let sender = message["sender_id"]?.object
        return (date, sender?.type == "messageSenderUser" ? sender?["user_id"]?.integer ?? 0 : 0)
    }
}
