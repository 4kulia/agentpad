import Foundation

/// Pinned MessageTopic constructors are distinct identities, including routes
/// that this release deliberately cannot open. Unknown constructors fail closed.
public enum TelegramMessageTopic: Codable, Hashable, Sendable {
    case forum(Int64), thread(Int64), directMessages(Int64), savedMessages(Int64), unsupported

    static func decode(_ value: TDLibValue?) -> Self? {
        guard let value, value != .null else { return nil }
        guard let raw = value.object else { return .unsupported }
        switch raw.type {
        case "messageTopicForum": return raw["forum_topic_id"]?.integer.map(Self.forum) ?? .unsupported
        case "messageTopicThread": return raw["message_thread_id"]?.integer.map(Self.thread) ?? .unsupported
        case "messageTopicDirectMessages": return raw["direct_messages_chat_topic_id"]?.integer.map(Self.directMessages) ?? .unsupported
        case "messageTopicSavedMessages": return raw["saved_messages_topic_id"]?.integer.map(Self.savedMessages) ?? .unsupported
        default: return .unsupported
        }
    }
    public var forumID: Int64? { if case .forum(let id) = self, id > 0, id <= Int32.max { id } else { nil } }
    var wire: TDLibValue {
        if let id = forumID { .typed("messageTopicForum", ["forum_topic_id": .integer(id)]) } else { .null }
    }
}

public struct TelegramForumTopic: Equatable, Sendable, Identifiable {
    public let id: Int64
    public var name: String
    public var iconColor: Int
    public var customEmojiID: Int64
    public var isGeneral: Bool
    public var isClosed: Bool
    public var isHidden: Bool
    public var isOwned: Bool
    public var order: Int64
    public var unreadCount: Int
    public var mentionCount: Int
    public var muted: Bool
    public var muteKnown: Bool
    public var inheritsMute: Bool
    public var inbox: Int64
    public var outbox: Int64

    init?(_ raw: TDLibMessage, chatMuted: Bool?) {
        guard let info = raw["info"]?.object, let id = info["forum_topic_id"]?.integer,
              id > 0, id <= Int32.max else { return nil }
        self.id = id; name = ""; iconColor = 0; customEmojiID = 0
        isGeneral = false; isClosed = true; isHidden = false; isOwned = false
        order = raw["order"]?.integer ?? 0
        unreadCount = Int(max(0, raw["unread_count"]?.integer ?? 0))
        mentionCount = 0; muted = false; muteKnown = false; inheritsMute = true; inbox = 0; outbox = 0
        applyInfo(info); applyRead(raw, chatMuted: chatMuted)
    }
    mutating func applyInfo(_ info: TDLibMessage) {
        name = String((info["name"]?.string ?? "Topic").prefix(128))
        iconColor = Int(info["icon"]?.object?["color"]?.integer ?? 0)
        customEmojiID = info["icon"]?.object?["custom_emoji_id"]?.integer ?? 0
        isGeneral = info["is_general"]?.bool == true
        isClosed = info["is_closed"]?.bool != false
        isHidden = info["is_hidden"]?.bool == true
        // TDLib tracks ownership separately when the topic was created as a chat.
        isOwned = info["is_outgoing"]?.bool == true
    }
    mutating func applyRead(_ raw: TDLibMessage, chatMuted: Bool?) {
        inbox = raw["last_read_inbox_message_id"]?.integer ?? inbox
        outbox = raw["last_read_outbox_message_id"]?.integer ?? outbox
        mentionCount = Int(max(0, raw["unread_mention_count"]?.integer ?? Int64(mentionCount)))
        if let settings = raw["notification_settings"]?.object {
            inheritsMute = settings["use_default_mute_for"]?.bool != false
            muted = inheritsMute ? chatMuted == true : (settings["mute_for"]?.integer ?? 0) > 0
            muteKnown = !inheritsMute || chatMuted != nil
        }
    }
}
