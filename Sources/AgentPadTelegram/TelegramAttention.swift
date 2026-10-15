import Foundation

public enum TelegramAttentionKind: String, Codable, Sendable {
    case direct, mention, reply, botReply, groupMessage, channelPost
    public var tier: Int { self == .groupMessage || self == .channelPost ? 4 : 3 }
    var episode: Bool { self == .groupMessage || self == .channelPost }
}

/// Compact source metadata. The app's AttentionSidebarModel alone projects
/// these into marks. Counts include the disk-backed overflow, never message text.
public struct TelegramAttentionSummary: Equatable, Sendable {
    public var destination: TelegramChatID
    public var count: Int
    public var firstMessage: Int64
    public var lastDate: Int64
    public var kind: TelegramAttentionKind
    public var identity: String
    public var classCount: Int
    public var incomplete: Bool
    public init(destination: TelegramChatID, count: Int, firstMessage: Int64, lastDate: Int64,
                kind: TelegramAttentionKind, identity: String, classCount: Int? = nil, incomplete: Bool = false) {
        self.destination = destination; self.count = count; self.firstMessage = firstMessage
        self.lastDate = lastDate; self.kind = kind; self.identity = identity
        self.classCount = classCount ?? count; self.incomplete = incomplete
    }
}

public struct TelegramAttentionSnapshot: Equatable, Sendable {
    public var totalCount = 0
    public var chatCount = 0
    public var directEnabled = true
    /// Only open destinations; sidebar rows carry their own summaries.
    public var destinations: [TelegramChatID: [TelegramAttentionSummary]] = [:]
    public var channelUnread: [TelegramChatID: Int] = [:]
    public var notifications = TelegramNotificationSnapshot()
    public init() {}
}

public struct TelegramNotification: Equatable, Sendable, Identifiable {
    public var id: String
    public var destination: TelegramChatID
    public var message: Int64
    public var kind: TelegramAttentionKind
    public var count: Int
    public var date: Int64
    public var sound: Bool
    /// Restored/updated/previously seen notifications can reconcile but cannot
    /// banner. This flag is consumed durably before handing delivery to the OS.
    public var mayDeliver: Bool
    public var viewed = false
    /// A group mention may still resolve to a reply after getMessage completes.
    public var categoryPending = false
}

public struct TelegramNotificationSnapshot: Equatable, Sendable {
    public var initialized = false
    public var items: [TelegramNotification] = []
    public var havePending = false
    public init() {}
}

public extension TelegramChatProvider {
    func setAttentionDestinations(_ destinations: Set<TelegramChatID>) async {}
    func setDirectAttention(_ enabled: Bool) async {}
    func snoozeAttention(_ id: TelegramChatID, undo: Bool) async {}
    func consumeNotification(_ id: String) async -> Bool { false }
}

extension TelegramMessageTopic {
    /// Addressed discussion messages belong to their group. Only forum topics
    /// have a separate readable Attention route in this release.
    var attentionDestination: Self? { if case .forum = self { self } else { nil } }
    var attentionKey: String {
        switch self {
        case .forum(let id): "forum:\(id)"
        case .thread(let id): "thread:\(id)"
        case .directMessages(let id): "direct:\(id)"
        case .savedMessages(let id): "saved:\(id)"
        case .unsupported: "unsupported"
        }
    }
    static func attentionTopic(_ key: String) -> Self? {
        if key.isEmpty { return nil }
        let parts = key.split(separator: ":")
        guard parts.count == 2, let id = Int64(parts[1]) else { return .unsupported }
        switch parts[0] {
        case "forum": return .forum(id)
        case "thread": return .thread(id)
        case "direct": return .directMessages(id)
        case "saved": return .savedMessages(id)
        default: return .unsupported
        }
    }
}
