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
public enum TelegramChatMode: String, Sendable { case auto, hidden }
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
    public var knownRelevant: Bool
    public var markedUnread = false
    public var muted = true
    public var lastOutgoing = false
    public var attentionOrderKey: TelegramAttentionOrderKey? = nil
    public var attention: TelegramAttentionSummary? = nil
    public var followEnabled = false
    public var followActivating = false
    public var snoozed = false
    public var lists: Set<TelegramListKey> = []
    public var listPosition: Int? = nil
}
public enum TelegramChatScanState: Equatable, Sendable {
    case disconnected, scanning, complete, paused(String)
}

/// Built on the provider actor once per frozen revision. Consumers share the
/// immutable buffers and compare versions, never traverse the order to adopt it.
public struct TelegramAttentionOrder: Equatable, Sendable {
    public let binding: TelegramProfileBinding
    public let revision: UInt64
    public let keys: [TelegramAttentionOrderKey]
    public let positions: [Int64:Int]
    public init(binding: TelegramProfileBinding, revision: UInt64, keys: [TelegramAttentionOrderKey]) {
        self.binding = binding; self.revision = revision; self.keys = keys
        positions = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element.chat,$0.offset) })
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.binding == rhs.binding && lhs.revision == rhs.revision
    }
}

/// Live marks have their own version because read state changes during a hold.
/// Keep them immutable: a view's page corrections must not copy this full set.
public struct TelegramAttentionState: Equatable, Sendable {
    public let order: TelegramAttentionOrder
    public let liveChats: Set<Int64>
    public let inactive: Set<Int64>
    public let version = UUID()
    public init(order: TelegramAttentionOrder, liveChats: Set<Int64>) {
        self.order = order; self.liveChats = liveChats
        inactive = Set(order.positions.keys).subtracting(liveChats)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }
}

public struct TelegramChatSnapshot: Equatable, Sendable {
    public var binding: TelegramProfileBinding?
    public var lists: [TelegramListSnapshot] = []
    public var attentionRows: [TelegramChatRow] = []
    public var attentionTotal = 0
    public var attentionRevision: UInt64 = 0
    public var attentionNext: Int?
    public var attentionFrontier: TelegramAttentionOrderKey?
    /// Ready-made frozen geometry, position index and live eligibility markers.
    public var attentionState: TelegramAttentionState?
    public var attentionKeys: [TelegramAttentionOrderKey]? { attentionState?.order.keys }
    public var attentionLiveChats: Set<Int64>? { attentionState?.liveChats }
    public var attentionNewCount = 0
    /// Live membership counts for frozen windows, without retaining their rows.
    public var attentionWindowCounts: [Int:Int] = [:]
    public var suggestionRows: [TelegramChatRow] = []
    public var account: TelegramChatID?
    public var state: TelegramChatScanState = .disconnected
    public var error: String?
    public var attention = TelegramAttentionSnapshot()
    public init() {}
}
public struct TelegramChatPage: Equatable, Sendable {
    public let revision: UInt64
    public let offset: Int
    public let rows: [TelegramChatRow]
    public let next: Int?
    public let attentionFrontier: TelegramAttentionOrderKey?
    public let attentionKeys: [TelegramAttentionOrderKey]?
    public init(revision: UInt64, offset: Int, rows: [TelegramChatRow], next: Int? = nil, attentionFrontier: TelegramAttentionOrderKey? = nil,
                attentionKeys: [TelegramAttentionOrderKey]? = nil) {
        self.revision = revision; self.offset = offset; self.rows = rows; self.next = next
        self.attentionFrontier = attentionFrontier
        self.attentionKeys = attentionKeys
    }
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
    func chatPage(list: TelegramListKey, from: Int, revision: UInt64, binding: TelegramProfileBinding) async -> TelegramChatPage
    func expandChats(list: TelegramListKey, showLess: Bool, binding: TelegramProfileBinding) async throws
    func holdChatOrder(list: TelegramListKey, held: Bool, owner: UUID, binding: TelegramProfileBinding) async throws
    func attentionPage(start: Int, revision: UInt64, binding: TelegramProfileBinding) async -> TelegramChatPage
    func holdAttentionOrder(_ held: Bool, owner: UUID, binding: TelegramProfileBinding) async throws
    func setViewport(list: TelegramListKey, windows: Set<Int>, binding: TelegramProfileBinding) async throws
    func setListVisible(_ list: TelegramListKey, visible: Bool, binding: TelegramProfileBinding) async throws
    func setListCollapsed(window: UUID, list: TelegramListKey, collapsed: Bool, binding: TelegramProfileBinding) async throws
    func retainFolderWindows(_ windows: Set<UUID>, binding: TelegramProfileBinding) async throws
    func customMembers(binding: TelegramProfileBinding) async throws -> [UUID:Set<Int64>]
    func customSummaries(binding: TelegramProfileBinding) async throws -> [TelegramFolderSummary]
    func setCustomMember(folder: UUID, chat: Int64, member: Bool, binding: TelegramProfileBinding) async throws
    func applyTombstones(_ tombstones: Set<UUID>, binding: TelegramProfileBinding) async throws
    func markAsRead(_ chat: Int64, retry: Set<TelegramMarkReadStep>?, binding: TelegramProfileBinding) async -> TelegramMarkReadResult
    func setFollow(_ chat: Int64, enabled: Bool, binding: TelegramProfileBinding) async throws
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) async
    func searchTelegram(_ query: String) async -> AsyncStream<TelegramSearchSnapshot>
    func resolveChat(_ hit: TelegramSearchHit) async -> TelegramChatRow?
    func didOpenChat(_ id: TelegramChatID) async
    func chat(_ id: TelegramChatID) async -> TelegramChatRow?
    func setChatScanPaused(_ reason: String?) async
    func setAttentionDestinations(_ destinations: Set<TelegramChatID>) async
    func setDirectAttention(_ enabled: Bool) async
    func snoozeAttention(_ id: TelegramChatID, undo: Bool) async
    func consumeNotification(_ id: String) async -> Bool
}

public enum TelegramChatLimits {
    static let page = 50
    public static let metadataRows = 1000
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
}
