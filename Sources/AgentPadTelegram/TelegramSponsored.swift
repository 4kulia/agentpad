import Foundation

/// Sponsored identities never enter the ordinary message/read namespace.
public struct TelegramSponsoredRef: Hashable, Sendable {
    public let result: UUID
    public let message: Int64
    public var id: String { "sponsored:\(result):\(message)" }
    public init(result: UUID, message: Int64) { self.result = result; self.message = message }
}

public struct TelegramSponsoredSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable { case idle, loading, ready, empty, error }
    public var state: State = .idle
    public var result: UUID?
    public var expiresAt: Date?
    public var retryNotBefore = Date.distantPast
    public var error: String?
    public var messagesBetween = 0
    public var messages: [TelegramSponsoredMessage] = []
    public init() {}
}

public struct TelegramSponsoredMedia: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case photo, video, animation }
    public enum Role: String, Sendable { case content, sponsor, background }
    public let id: Int64
    public let kind: Kind
    public let role: Role
    public let width: Int
    public let height: Int
    public let size: Int64
    public var url: URL?
    public var error: String?
}

public struct TelegramSponsoredMessage: Equatable, Sendable, Identifiable {
    public let ref: TelegramSponsoredRef
    public var id: String { ref.id }
    public let recommended: Bool
    public let canReport: Bool
    public let title: String
    public let text: String
    public let entities: [TelegramTextEntity]
    public let button: String
    public let url: String
    public let sponsorInfo: String
    public let additionalInfo: String
    public let accentColorID: Int
    public let backgroundEmojiID: Int64
    public var lightColors: [UInt32] = []
    public var darkColors: [UInt32] = []
    public var media: [TelegramSponsoredMedia] = []
    public var error: String?
    public var backgroundResolved = true
    public var fullyLoaded: Bool { error == nil && backgroundResolved && media.allSatisfy { $0.url != nil && $0.error == nil } }
}

public struct TelegramSponsoredVisibility: Equatable, Sendable {
    public let ref: TelegramSponsoredRef
    public let fullyLoaded: Bool
    public let fullTextVisible: Bool
    public init(ref: TelegramSponsoredRef, fullyLoaded: Bool, fullTextVisible: Bool) {
        self.ref = ref; self.fullyLoaded = fullyLoaded; self.fullTextVisible = fullTextVisible
    }
}

public enum TelegramSponsoredClick: Equatable, Sendable {
    case title, button, sponsorPhoto, media, silentVideoMedia, expandVideo, fullscreenMedia, fullscreenButton, link(Int)
}
public struct TelegramSponsoredReportOption: Equatable, Sendable, Identifiable {
    /// TDLib JSON bytes, preserved exactly (including non-UTF8 option bytes).
    public let id: String
    public let text: String
}
public enum TelegramSponsoredAction: Sendable {
    case retry
    case retryMedia(TelegramSponsoredRef)
    case cancelMedia(TelegramSponsoredRef)
    case click(TelegramSponsoredRef, TelegramSponsoredClick, confirmed: Bool)
    case report(TelegramSponsoredRef, step: UUID?, option: String?)
    case cancelReport(TelegramSponsoredRef)
}
public enum TelegramSponsoredActionResult: Equatable, Sendable {
    case none, error(String), notice(String)
    case confirmURL(URL), openURL(URL), openChat(TelegramChatID), fullscreen(TelegramSponsoredRef)
    case reportOptions(TelegramSponsoredRef, step: UUID, title: String, options: [TelegramSponsoredReportOption])
}

public enum TelegramSponsoredURL {
    public static func checked(_ string: String) -> URL? {
        guard string.utf8.count <= 8192, !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func requiresConfirmation(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.port == nil || url.port == 443 || url.port == 80 else { return true }
        let trusted = ["telegram.org", "telegram.me", "telegram.dog", "t.me", "telegra.ph", "te.legra.ph", "graph.org", "fragment.com", "telesco.pe"]
        return !trusted.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum TelegramSponsoredLimits {
    static let fileBytes: Int64 = 50 * 1024 * 1024
    static let diskBytes: Int64 = 128 * 1024 * 1024
    static let decodedBytes = 64 * 1024 * 1024
    static let pixels = 16_000_000
    static let queue = 8
    static let resultBytes = 1024 * 1024
    static let accountBytes = 8 * 1024 * 1024
    static let messages = 128
}

enum TelegramSponsoredDecoder {
    struct Decoded {
        var message: TelegramSponsoredMessage
        var files: [Int64: TDLibMessage]
    }
    static func decode(_ raw: TDLibMessage, result: UUID) -> Decoded? {
        guard let id = raw["message_id"]?.integer, let content = raw["content"]?.object,
              let sponsor = raw["sponsor"]?.object, let title = raw["title"]?.string,
              let button = raw["button_text"]?.string, let url = sponsor["url"]?.string else { return nil }
        var formatted = content["text"]?.object ?? content["caption"]?.object
        let text = formatted?["text"]?.string ?? ""
        // Telegram @mentions are links too. Reuse the ordinary UTF-16 validator
        // after converting only well-formed public usernames to checked links.
        if let rawEntities = formatted?["entities"]?.array {
            formatted?["entities"] = .array(rawEntities.map { value in
                guard var entity = value.object, entity["type"]?.object?.type == "textEntityTypeMention",
                      let offset = entity["offset"]?.integer, let length = entity["length"]?.integer,
                      offset >= 0, length > 1, offset <= text.utf16.count, length <= text.utf16.count - Int(offset) else { return value }
                let mention = (text as NSString).substring(with: NSRange(location: Int(offset), length: Int(length)))
                guard let name = TelegramInlineQuery.username(in: mention + " ") else { return value }
                entity["type"] = .typed("textEntityTypeTextUrl", ["url": .string("https://t.me/" + name)])
                return .object(entity.fields)
            })
        }
        var message = TelegramSponsoredMessage(ref: .init(result: result, message: id), recommended: raw["is_recommended"]?.bool == true,
            canReport: raw["can_be_reported"]?.bool == true, title: title, text: text,
            entities: TelegramMessageDecoder.entities(formatted, text: text), button: button, url: url,
            sponsorInfo: sponsor["info"]?.string ?? "", additionalInfo: raw["additional_info"]?.string ?? "",
            accentColorID: Int(raw["accent_color_id"]?.integer ?? 5), backgroundEmojiID: raw["background_custom_emoji_id"]?.integer ?? 0)
        var files: [Int64: TDLibMessage] = [:]
        func add(_ size: TDLibMessage?, kind: TelegramSponsoredMedia.Kind, role: TelegramSponsoredMedia.Role, field: String) {
            guard let size, let file = size[field]?.object, let media = media(file, kind: kind, role: role,
                width: Int(size["width"]?.integer ?? 0), height: Int(size["height"]?.integer ?? 0)) else {
                message.error = "Ad media is unavailable"; return
            }
            message.media.append(media); files[media.id] = file
        }
        switch content.type {
        case "messageText": break
        case "messagePhoto": add(photo(content["photo"]?.object), kind: .photo, role: .content, field: "photo")
        case "messageVideo": add(content["video"]?.object, kind: .video, role: .content, field: "video")
        case "messageAnimation": add(content["animation"]?.object, kind: .animation, role: .content, field: "animation")
        default: message.error = "This ad format is unavailable"
        }
        if let image = sponsor["photo"]?.object { add(photo(image), kind: .photo, role: .sponsor, field: "photo") }
        message.backgroundResolved = message.backgroundEmojiID == 0
        if TelegramSponsoredURL.checked(url) == nil { message.error = "Ad link is unavailable" }
        return Decoded(message: message, files: files)
    }
    static func photo(_ raw: TDLibMessage?) -> TDLibMessage? {
        raw?["sizes"]?.array.compactMap(\.object).max { ($0["width"]?.integer ?? 0) < ($1["width"]?.integer ?? 0) }
    }
    static func media(_ file: TDLibMessage, kind: TelegramSponsoredMedia.Kind, role: TelegramSponsoredMedia.Role, width: Int, height: Int) -> TelegramSponsoredMedia? {
        guard let id = file["id"]?.integer, id > 0 else { return nil }
        let size = max(file["size"]?.integer ?? 0, file["expected_size"]?.integer ?? 0)
        let valid = size >= 0 && size <= TelegramSponsoredLimits.fileBytes && width > 0 && height > 0
            && width <= 8192 && height <= 8192 && width * height <= TelegramSponsoredLimits.pixels
        return .init(id: id, kind: kind, role: role, width: width, height: height, size: size,
                     error: valid ? nil : "Ad media exceeds the supported resource budget")
    }
}
