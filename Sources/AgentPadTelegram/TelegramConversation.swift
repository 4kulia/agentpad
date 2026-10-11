import Foundation

/// UI-facing values. No TDLib JSON, server addresses or sequence numbers escape
/// the connector. Every action carries the epoch of the snapshot it came from.
public struct TelegramConversationSnapshot: Equatable, Sendable {
    public let destination: TelegramChatID
    public var epoch: UUID
    public var revision: UInt64 = 0
    public var title = "Telegram"
    public var username = ""
    public var kind: TelegramChatKind = .unknown
    public var messages: [TelegramMessage] = []
    public var draft = TelegramDraft()
    public var capabilities = TelegramConversationCapabilities()
    public var loading = false
    public var hasOlder = true
    public var hasNewer = false
    public var inbox: Int64 = 0
    public var outbox: Int64 = 0
    public var presence = ""
    public var error: String?
    public var connected = false
    public var textLimit = 4096
    public var captionLimit = 1024
    public var cacheLimitMiB = 512
    public var operations: [TelegramSendOperation] = []
    public var consumedDraftRevisions = Set<UUID>()
    public var unavailableMessageIDs = Set<Int64>()
    public var isTopicList = false
    public var topics: [TelegramForumTopic] = []
    public var topicsWindowed = false
    public var topicInfo: TelegramForumTopic?
    public var bot = TelegramBotInfo()
    public var replyKeyboard: TelegramBotKeyboard?
    public var keyboardHidden = false
    public var pendingBotButtons = Set<String>()
    public var sponsored = TelegramSponsoredSnapshot()
    public init(destination: TelegramChatID, epoch: UUID = UUID()) {
        self.destination = destination; self.epoch = epoch
    }
}

public struct TelegramSendOperation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let states: [String]
    public var canRecover: Bool
}

public struct TelegramConversationCapabilities: Equatable, Sendable {
    public var canRead = false
    public var canSend = false
    public var canSendPhotos = false
    public var canSendDocuments = false
    public var sender = ""
    public var reason = "Loading chat details…"
    public init() {}
}

public struct TelegramDraft: Codable, Equatable, Sendable {
    public var revision: UUID
    public var text: String
    public var replyTo: Int64?
    public var attachments: [TelegramStagedAttachment]
    /// Set only by the explicit "Send as text" affordance; edits reset it.
    public var sendAsText: Bool?
    public init(revision: UUID = UUID(), text: String = "", replyTo: Int64? = nil,
                attachments: [TelegramStagedAttachment] = []) {
        self.revision = revision; self.text = text; self.replyTo = replyTo; self.attachments = attachments
    }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

public struct TelegramStagedAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let mime: String
    public let size: Int
    public let width: Int
    public let height: Int
    public init(id: UUID, name: String, mime: String, size: Int, width: Int = 0, height: Int = 0) {
        self.id = id; self.name = name; self.mime = mime; self.size = size; self.width = width; self.height = height
    }
}

public struct TelegramTextEntity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case bold, italic, underline, strikethrough, code, pre, blockquote, spoiler, link }
    public let offset: Int
    public let length: Int
    public let kind: Kind
    public let url: String?
}

public struct TelegramMessage: Equatable, Sendable, Identifiable {
    /// Stable across sendMessage / resendMessages and pending -> final updates.
    public var id: String
    public var messageID: Int64
    public var senderID: Int64
    public var author: String
    public var date: Date
    public var edited: Bool
    public var outgoing: Bool
    public var text: String
    public var entities: [TelegramTextEntity]
    public var content: Content
    public var delivery: Delivery
    public var replyTo: Int64?
    public var replyPreview: String?
    public var protectedContent: Bool
    public var unreadMention: Bool
    public var expiresAt: Date?
    public var attachment: TelegramFile?
    public var canRetry = false
    public var retryReason: String?
    public var senderChatID: Int64?
    public var topic: TelegramMessageTopic?
    public var inlineKeyboard: TelegramBotKeyboard?
    public var keyboardUnavailable = false
    public var viewCount: Int64?
    public var replyCount: Int64?
    public enum Content: Equatable, Sendable { case message, service, unsupported(String), deleted }
    public enum Delivery: Equatable, Sendable { case received, submitting, pending, sent, read, failed(String), unknown }
    public var storageBytes: Int { text.utf8.count + (replyPreview?.utf8.count ?? 0) + (inlineKeyboard?.storageBytes ?? 0) + entities.count * 64 + entities.reduce(0) { $0 + ($1.url?.utf8.count ?? 0) } }
}

public struct TelegramFile: Equatable, Sendable, Identifiable {
    public let id: Int64
    public var name: String
    public var size: Int64
    public var mime: String
    public var downloaded: Int64 = 0
    public var uploaded: Int64 = 0
    public var downloading = false
    public var uploading = false
    public var complete = false
}

public struct TelegramPresentationObservation: Equatable, Sendable {
    public fileprivate(set) var generation: UInt64 = 0
    fileprivate var source: TelegramPresentationObservations?
    public let pane: UUID
    public let epoch: UUID
    public let active: Bool
    public let shown: Bool
    public let ordinaryIDs: Set<Int64>
    public let sponsored: [TelegramSponsoredVisibility]
    public let sponsoredRequests: Set<TelegramSponsoredRef>
    public init(pane: UUID, epoch: UUID, active: Bool, shown: Bool, ordinaryIDs: Set<Int64>,
                sponsored: [TelegramSponsoredVisibility] = [], sponsoredRequests: Set<TelegramSponsoredRef> = []) {
        self.pane = pane; self.epoch = epoch; self.active = active; self.shown = shown; self.ordinaryIDs = ordinaryIDs
        self.sponsored = sponsored; self.sponsoredRequests = sponsoredRequests
    }
    /// Unpublished observations have no authority to trigger a view RPC.
    public var isCurrent: Bool { source?.isCurrent(self) == true }
    func sees(_ item: TelegramPresentationItem) -> Bool {
        guard active, shown, isCurrent else { return false }
        switch item {
        case .message(let id): return ordinaryIDs.contains(id)
        case .sponsored(let ref): return sponsored.contains { $0.ref == ref && $0.fullyLoaded && $0.fullTextVisible }
        }
    }
}

enum TelegramPresentationItem {
    case message(Int64), sponsored(TelegramSponsoredRef)
}

/// Published synchronously by the UI, before hopping to the connector actor.
/// A newer observation invalidates queued and already-reduced snapshots alike.
public final class TelegramPresentationObservations: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latest: [UUID: (epoch: UUID, generation: UInt64)] = [:]
    public init() {}
    public static func == (lhs: TelegramPresentationObservations, rhs: TelegramPresentationObservations) -> Bool { lhs === rhs }
    public func record(_ observation: TelegramPresentationObservation) -> TelegramPresentationObservation {
        lock.withLock {
            generation += 1
            var value = observation
            value.generation = generation; value.source = self
            latest[value.pane] = (value.epoch, generation)
            return value
        }
    }
    public func invalidate(pane: UUID) { lock.withLock { latest[pane] = nil } }
    public func invalidateAll() { lock.withLock { latest.removeAll() } }
    fileprivate func isCurrent(_ observation: TelegramPresentationObservation) -> Bool {
        lock.withLock {
            latest[observation.pane]?.epoch == observation.epoch && latest[observation.pane]?.generation == observation.generation
        }
    }
}

public protocol TelegramConversationProvider: Sendable {
    func conversation(_ id: TelegramChatID, pane: UUID) async -> AsyncStream<TelegramConversationSnapshot>
    func releaseConversation(_ id: TelegramChatID, pane: UUID, epoch: UUID) async
    func loadHistory(_ id: TelegramChatID, epoch: UUID, latest: Bool) async
    func loadMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) async
    @discardableResult func updateDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) async -> Bool
    func sendDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft) async
    func retryMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) async
    func recoverMessage(_ id: TelegramChatID, epoch: UUID, operation: UUID) async
    func discardRecovery(_ id: TelegramChatID, epoch: UUID, operation: UUID) async
    func observePresentation(_ id: TelegramChatID, observation: TelegramPresentationObservation) async
    func setApplicationActive(_ active: Bool) async
    func composerActivity(_ id: TelegramChatID, epoch: UUID, pane: UUID, typing: Bool) async
    func stageAttachment(_ id: TelegramChatID, epoch: UUID, data: Data, name: String, mime: String, width: Int, height: Int) async throws -> TelegramStagedAttachment
    func discardAttachment(_ id: TelegramChatID, epoch: UUID, file: UUID) async
    func downloadAttachment(_ id: TelegramChatID, epoch: UUID, message: Int64, cancel: Bool) async
    func attachmentURL(_ id: TelegramChatID, epoch: UUID, message: Int64) async throws -> URL
    func attachmentImportDirectory(_ id: TelegramChatID, epoch: UUID) async throws -> URL
    func removeAttachmentImportDirectory(_ id: TelegramChatID, epoch: UUID, directory: URL) async
    func setAttachmentCacheLimit(_ id: TelegramChatID, epoch: UUID, mebibytes: Int) async
    func clearAttachmentCache(_ id: TelegramChatID, epoch: UUID) async
    func externalMessageLink(_ id: TelegramChatID, epoch: UUID, message: Int64) async -> URL?
    func performBotAction(_ id: TelegramChatID, epoch: UUID, action: TelegramBotAction) async -> TelegramBotActionResult
    func checkInlineQuery(_ id: TelegramChatID, epoch: UUID, text: String) async -> TelegramInlineQueryCheck
    func conversationIsCurrent(_ id: TelegramChatID, epoch: UUID) async -> Bool
    func performSponsoredAction(_ id: TelegramChatID, epoch: UUID, action: TelegramSponsoredAction) async -> TelegramSponsoredActionResult
}

enum TelegramFeedLimits {
    static let concurrentSends = 2
    static let paneMessages = 500, totalMessages = 2000, textBytes = 16 * 1024 * 1024
    static let fileBytes = 20 * 1024 * 1024, sendBytes = 50 * 1024 * 1024, stagedBytes = 100 * 1024 * 1024
}

public extension TelegramConversationProvider {
    func loadMessage(_ id: TelegramChatID, epoch: UUID, message: Int64) async {}
}

public enum TelegramConversationError: String, Error, LocalizedError {
    case unavailable = "This Telegram action is no longer available."
    case storage = "The Telegram draft could not be saved on this Mac."
    case files = "Use supported files up to 20 MiB each, 10 files / 50 MiB per send, and 20 files / 100 MiB staged."
    case recovery = "Review or remove recovered drafts before sending more messages."
    public var errorDescription: String? { rawValue }
}

enum TelegramMessageDecoder {
    static let serviceTypes: Set<String> = [
        "messageCall", "messageGroupCall", "messageVideoChatScheduled", "messageVideoChatStarted", "messageVideoChatEnded", "messageInviteVideoChatParticipants",
        "messageBasicGroupChatCreate", "messageSupergroupChatCreate", "messageChatChangeTitle", "messageChatChangePhoto", "messageChatDeletePhoto",
        "messageChatOwnerLeft", "messageChatOwnerChanged", "messageChatHasProtectedContentToggled", "messageChatHasProtectedContentDisableRequested",
        "messageChatAddMembers", "messageChatJoinByLink", "messageChatJoinByRequest", "messageChatJoinFromCommunity", "messageChatDeleteMember",
        "messageChatAddedToCommunity", "messageChatRemovedFromCommunity", "messageChatUpgradeTo", "messageChatUpgradeFrom", "messagePinMessage",
        "messageScreenshotTaken", "messageChatSetBackground", "messageChatSetTheme", "messageChatSetMessageAutoDeleteTime", "messageChatBoost", "messageContactRegistered"
    ]
    static func serviceText(_ content: TDLibMessage) -> String {
        switch content.type {
        case "messageChatChangeTitle": return "Chat renamed to " + String((content["title"]?.string ?? "").prefix(512))
        case "messageChatAddMembers": return "Members added"
        case "messageChatDeleteMember": return "A member left or was removed"
        case "messageChatJoinByLink", "messageChatJoinByRequest": return "A member joined"
        case "messageBasicGroupChatCreate", "messageSupergroupChatCreate": return "Group created"
        case "messageChatChangePhoto": return "Chat photo changed"
        case "messageChatDeletePhoto": return "Chat photo removed"
        case "messageChatSetMessageAutoDeleteTime": return "Auto-delete timer changed"
        case "messagePinMessage": return "A message was pinned"
        case "messageCall": return "Telegram call"
        default: return "Telegram service event"
        }
    }
    static func safeURL(_ raw: String) -> String? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty != false { return nil }
        return url.absoluteString
    }
    static func entities(_ formatted: TDLibMessage?, text: String) -> [TelegramTextEntity] {
        let units = Array(text.utf16)
        func boundary(_ n: Int) -> Bool { n == 0 || n == units.count || !(0xDC00...0xDFFF).contains(units[n]) }
        return (formatted?["entities"]?.array ?? []).prefix(4096).compactMap { value in
            guard let entity = value.object, let start = entity["offset"]?.integer, let count = entity["length"]?.integer,
                  start >= 0, count > 0, start <= units.count, count <= units.count - Int(start),
                  boundary(Int(start)), boundary(Int(start + count)), let type = entity["type"]?.object else { return nil }
            let names: [String: TelegramTextEntity.Kind] = ["textEntityTypeBold": .bold, "textEntityTypeItalic": .italic,
                "textEntityTypeUnderline": .underline, "textEntityTypeStrikethrough": .strikethrough, "textEntityTypeCode": .code,
                "textEntityTypePre": .pre, "textEntityTypePreCode": .pre, "textEntityTypeBlockQuote": .blockquote,
                "textEntityTypeExpandableBlockQuote": .blockquote, "textEntityTypeSpoiler": .spoiler]
            var kind = names[type.type], url: String?
            if ["textEntityTypeTextUrl", "textEntityTypeUrl", "textEntityTypeEmailAddress"].contains(type.type) {
                let source = (text as NSString).substring(with: NSRange(location: Int(start), length: Int(count)))
                url = safeURL(type["url"]?.string ?? (type.type == "textEntityTypeEmailAddress" ? "mailto:" + source : source))
                if url != nil { kind = .link }
            }
            guard let kind else { return nil }
            return TelegramTextEntity(offset: Int(start), length: Int(count), kind: kind, url: url)
        }
    }
    static func file(_ content: TDLibMessage) -> TelegramFile? {
        var raw: TDLibMessage?, name = "Photo.jpg", mime = "image/jpeg"
        if content.type == "messageDocument", let document = content["document"]?.object {
            raw = document["document"]?.object; name = document["file_name"]?.string ?? "Document"; mime = document["mime_type"]?.string ?? ""
        } else if content.type == "messagePhoto" {
            raw = content["photo"]?.object?["sizes"]?.array.last?.object?["photo"]?.object
        }
        guard let raw, let id = raw["id"]?.integer else { return nil }
        var result = TelegramFile(id: id, name: String(name.prefix(200)), size: max(raw["size"]?.integer ?? 0, raw["expected_size"]?.integer ?? 0), mime: mime)
        updateFile(&result, raw)
        return result
    }
    static func updateFile(_ file: inout TelegramFile, _ raw: TDLibMessage) {
        let local = raw["local"]?.object, remote = raw["remote"]?.object
        file.size = max(raw["size"]?.integer ?? 0, raw["expected_size"]?.integer ?? 0)
        file.downloaded = local?["downloaded_size"]?.integer ?? 0
        file.uploaded = remote?["uploaded_size"]?.integer ?? 0
        file.downloading = local?["is_downloading_active"]?.bool == true
        file.uploading = remote?["is_uploading_active"]?.bool == true
        file.complete = local?["is_downloading_completed"]?.bool == true
    }
    static func decode(_ raw: TDLibMessage, now: Date, author: String, key: String? = nil) -> TelegramMessage? {
        guard let id = raw["id"]?.integer, let content = raw["content"]?.object else { return nil }
        let disappearing = raw["self_destruct_type"]?.object != nil || content["is_secret"]?.bool == true
        let formatted = content["text"]?.object ?? content["caption"]?.object
        let text = disappearing ? "" : formatted?["text"]?.string ?? (serviceTypes.contains(content.type) ? serviceText(content) : "")
        let known = ["messageText", "messagePhoto", "messageDocument"].contains(content.type)
        let kind: TelegramMessage.Content = disappearing ? .unsupported("Disappearing media · Open in Telegram")
            : known ? .message : serviceTypes.contains(content.type) ? .service : .unsupported("Unsupported content · Open in Telegram")
        let state = raw["sending_state"]?.object
        let outgoing = raw["is_outgoing"]?.bool == true
        let delivery: TelegramMessage.Delivery = state?.type == "messageSendingStateFailed" ? .failed("Message failed to send")
            : state != nil ? .pending : outgoing ? .sent : .received
        let reply = raw["reply_to"]?.object
        let replyID = reply?.type == "messageReplyToMessage" && reply?["chat_id"]?.integer == raw["chat_id"]?.integer ? reply?["message_id"]?.integer : nil
        let expiry = raw["auto_delete_in"]?.number ?? 0
        let keyboard = disappearing ? nil : TelegramBotDecoder.keyboard(raw["reply_markup"]?.object, message: id)
        return TelegramMessage(id: key ?? String(id), messageID: id, senderID: raw["sender_id"]?.object?["user_id"]?.integer ?? 0,
            author: author, date: Date(timeIntervalSince1970: Double(raw["date"]?.integer ?? 0)), edited: (raw["edit_date"]?.integer ?? 0) > 0,
            outgoing: outgoing, text: text, entities: disappearing ? [] : entities(formatted, text: text), content: kind, delivery: delivery,
            replyTo: replyID, replyPreview: replyID == nil ? nil : "Reply to message", protectedContent: raw["can_be_saved"]?.bool != true,
            unreadMention: raw["contains_unread_mention"]?.bool == true, expiresAt: expiry > 0 ? now.addingTimeInterval(expiry) : nil,
            attachment: disappearing ? nil : file(content), senderChatID: raw["sender_id"]?.object?["chat_id"]?.integer,
            topic: TelegramMessageTopic.decode(raw["topic_id"]),
            inlineKeyboard: keyboard.flatMap { $0.kind == .inline ? $0 : nil },
            keyboardUnavailable: raw["reply_markup"]?.object?.type == "replyMarkupInlineKeyboard" && keyboard == nil,
            viewCount: raw["interaction_info"]?.object?["view_count"]?.integer,
            replyCount: raw["interaction_info"]?.object?["reply_info"]?.object?["reply_count"]?.integer)
    }
}

extension TDLibValue {
    var number: Double? { switch self { case .decimal(let n): n; case .integer(let n): Double(n); default: nil } }
    static func typed(_ type: String, _ fields: [String: TDLibValue] = [:]) -> Self { .object(TDLibMessage(type, fields).fields) }
}
