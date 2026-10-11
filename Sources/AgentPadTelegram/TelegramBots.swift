import Foundation

public struct TelegramBotCommand: Equatable, Sendable, Identifiable {
    public let botUserID: Int64
    public let command: String
    public let description: String
    public let isEphemeral: Bool
    public var id: String { "\(botUserID):\(command)" }
}

public struct TelegramBotInfo: Equatable, Sendable {
    public var description = ""
    public var commands: [TelegramBotCommand] = []
    public init() {}
}

public struct TelegramBotKeyboard: Equatable, Sendable {
    public enum Kind: Sendable { case inline, reply, forceReply }
    public var revision = UUID()
    public let messageID: Int64
    public let kind: Kind
    public let rows: [[TelegramBotButton]]
    public let oneTime: Bool
    public let persistent: Bool
    public let resize: Bool
    public let personal: Bool
    public let forceReply: Bool
    public let placeholder: String
    public var storageBytes: Int { rows.flatMap { $0 }.reduce(placeholder.utf8.count) { $0 + $1.storageBytes } }
    func keepingRevision(of old: Self?) -> Self {
        guard let old else { return self }
        var candidate = self; candidate.revision = old.revision
        return candidate == old ? candidate : self
    }
}

public struct TelegramBotButton: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case text, callback(Data), url(String), user(Int64), copy(String)
        case openTelegram(String), disabled(String)
    }
    public let text: String
    public let action: Action
    public var enabled: Bool { if case .disabled = action { false } else { true } }
    public var explanation: String {
        switch action { case .disabled(let text), .openTelegram(let text): text; default: "" }
    }
    var storageBytes: Int {
        let payload = switch action {
        case .callback(let data): data.count
        case .url(let text), .copy(let text), .openTelegram(let text), .disabled(let text): text.utf8.count
        default: 0
        }
        return text.utf8.count + 64 + payload
    }
}

public enum TelegramBotAction: Sendable {
    case start
    case command(String)
    case button(message: Int64, revision: UUID, row: Int, column: Int, replyKeyboard: Bool)
    case dismissKeyboard(revision: UUID)
    case showKeyboard(revision: UUID)
}

public enum TelegramBotActionResult: Equatable, Sendable {
    case notice(String), alert(String), error(String), confirmURL(URL), user(TelegramChatID, String), copy(String), insertCommand(String)
    case openTelegram(String)
    case answerWithURL(String, alert: Bool, url: URL)
}

public enum TelegramInlineQueryCheck: Sendable { case ordinary, inlineBot, unavailable }

public enum TelegramInlineQuery {
    public static func username(in text: String) -> String? {
        guard text.first == "@", let end = text.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let name = String(text[text.index(after: text.startIndex)..<end])
        guard !name.isEmpty, name.count <= 32, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return name.lowercased()
    }
}

enum TelegramBotDecoder {
    static func keyboard(_ raw: TDLibMessage?, message: Int64) -> TelegramBotKeyboard? {
        guard let raw else { return nil }
        let kind: TelegramBotKeyboard.Kind
        switch raw.type {
        case "replyMarkupInlineKeyboard": kind = .inline
        case "replyMarkupShowKeyboard": kind = .reply
        case "replyMarkupForceReply": kind = .forceReply
        default: return nil
        }
        let rows = (raw["rows"]?.array ?? [])
        // Reject oversized layouts rather than silently changing a button's data.
        guard rows.count <= 32, rows.reduce(0, { $0 + $1.array.count }) <= 128 else { return nil }
        let buttons = rows.map { row in row.array.compactMap { $0.object.map { button($0, inline: kind == .inline) } } }
        let keyboard = TelegramBotKeyboard(messageID: message, kind: kind, rows: buttons,
            oneTime: raw["one_time"]?.bool == true, persistent: raw["is_persistent"]?.bool == true,
            resize: raw["resize_keyboard"]?.bool == true, personal: raw["is_personal"]?.bool == true,
            forceReply: kind == .forceReply || raw["force_reply"]?.bool == true,
            placeholder: String((raw["input_field_placeholder"]?.string ?? "").prefix(64)))
        return keyboard.storageBytes <= 64 * 1024 ? keyboard : nil
    }
    static func button(_ raw: TDLibMessage, inline: Bool) -> TelegramBotButton {
        let text = raw["text"]?.string ?? "Action", type = raw["type"]?.object
        guard type?.type.hasPrefix(inline ? "inlineKeyboardButtonType" : "keyboardButtonType") == true else {
            return .init(text: String(text.prefix(256)), action: .disabled("Unsupported bot action"))
        }
        let action: TelegramBotButton.Action
        switch type?.type {
        case "inlineKeyboardButtonTypeUrl":
            action = type?["url"]?.string.flatMap(safeButtonURL).map { .url($0) } ?? .disabled("Unsafe or unsupported link")
        case "inlineKeyboardButtonTypeCallback":
            action = type?["data"]?.string.flatMap { Data(base64Encoded: $0) }.map { .callback($0) } ?? .disabled("Invalid callback data")
        case "inlineKeyboardButtonTypeUser":
            action = type?["user_id"]?.integer.flatMap { $0 > 0 ? .user($0) : nil } ?? .disabled("User unavailable")
        case "inlineKeyboardButtonTypeCopyText":
            action = type?["text"]?.string.map { .copy($0) } ?? .disabled("Text unavailable")
        case "inlineKeyboardButtonTypeDisabled": action = .disabled("This button is disabled by the bot")
        case "inlineKeyboardButtonTypeSwitchInline": action = .openTelegram("Inline mode is available in Telegram")
        case "inlineKeyboardButtonTypeLoginUrl", "inlineKeyboardButtonTypeWebApp", "inlineKeyboardButtonTypeCallbackWithPassword",
             "inlineKeyboardButtonTypeCallbackGame", "inlineKeyboardButtonTypeBuy":
            action = .openTelegram("Action available in Telegram")
        case "keyboardButtonTypeText": action = .text
        case "keyboardButtonTypeRequestPhoneNumber", "keyboardButtonTypeRequestLocation", "keyboardButtonTypeRequestPoll",
             "keyboardButtonTypeRequestUsers", "keyboardButtonTypeRequestChat", "keyboardButtonTypeRequestManagedBot", "keyboardButtonTypeWebApp":
            action = .openTelegram("Action available in Telegram")
        default: action = .disabled("Unsupported bot action")
        }
        guard text.utf8.count <= 4096 else { return .init(text: "Unsupported button", action: .disabled("Button exceeds the display limit")) }
        return TelegramBotButton(text: text, action: action)
    }
    static func safeButtonURL(_ raw: String) -> String? {
        guard raw.utf8.count <= 8192, let url = URL(string: raw), url.user == nil, url.password == nil,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if url.scheme?.lowercased() == "tg" { return raw } // still requires TDLib's typed resolver
        return TelegramMessageDecoder.safeURL(raw)
    }
    static func info(_ full: TDLibMessage, user: Int64?) -> TelegramBotInfo {
        let bot = full["bot_info"]?.object
        let groups: [(Int64, [TDLibValue])] = user.map { [($0, bot?["commands"]?.array ?? [])] }
            ?? (full["bot_commands"]?.array ?? []).prefix(100).compactMap { value in
                guard let raw = value.object, let id = raw["bot_user_id"]?.integer else { return nil }
                return (id, raw["commands"]?.array ?? [])
            }
        var info = TelegramBotInfo(); info.description = String((bot?["description"]?.string ?? bot?["short_description"]?.string ?? "").prefix(4096))
        for (user, commands) in groups {
            for value in commands.prefix(100) {
                guard let raw = value.object, let command = raw["command"]?.string, !command.isEmpty, command.count <= 64,
                      command.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }), info.commands.count < 100 else { continue }
                let item = TelegramBotCommand(botUserID: user, command: command, description: String((raw["description"]?.string ?? "").prefix(256)), isEphemeral: raw["is_ephemeral"]?.bool == true)
                if !info.commands.contains(where: { $0.id == item.id }) { info.commands.append(item) }
            }
        }
        return info
    }
}
