import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramBotTests: XCTestCase {
    private func bot(_ h: TelegramFeedHarness, inline: Bool = true, topics: Bool = false) -> TDLibMessage {
        var user = h.user(type: "userTypeBot")
        user["type"] = .typed("userTypeBot", ["is_inline": .bool(inline), "has_topics": .bool(topics)])
        user["usernames"] = .typed("usernames", ["active_usernames": .array([.string("helper_bot")])]); return user
    }
    private func prepare(_ h: TelegramFeedHarness) {
        h.feed.peer = bot(h); h.session.rememberUser(bot(h)); h.session.capabilities(h.feed)
    }
    private func markup(_ type: String, button: String = "inlineKeyboardButtonTypeCallback", fields: [String: TDLibValue] = ["data": .string("AP/+gA==")], extras: [String: TDLibValue] = [:]) -> TDLibValue {
        var values = extras
        values["rows"] = .array([.array([.typed(type == "replyMarkupInlineKeyboard" ? "inlineKeyboardButton" : "keyboardButton", ["text": .string("Visible text"), "type": .typed(button, fields)])])])
        return .typed(type, values)
    }
    private func inline(_ h: TelegramFeedHarness, button: String = "inlineKeyboardButtonTypeCallback", fields: [String: TDLibValue] = ["data": .string("AP/+gA==")]) -> TelegramBotAction {
        var message = h.message(10); message["reply_markup"] = markup("replyMarkupInlineKeyboard", button: button, fields: fields)
        h.session.merge(message, into: h.feed)
        return .button(message: 10, revision: h.feed.snapshot.messages[0].inlineKeyboard!.revision, row: 0, column: 0, replyKeyboard: false)
    }
    private func act(_ h: TelegramFeedHarness, _ action: TelegramBotAction, result: @escaping (TelegramBotActionResult) -> Void) {
        h.session.botAction(h.id, epoch: h.epoch, action: action, completion: result)
    }
    func testEveryPinnedButtonConstructorIsTypedAndMissingTypeIsDisabled() {
        let supported = ["Url", "Callback", "User", "CopyText", "Disabled", "SwitchInline", "LoginUrl", "WebApp", "CallbackWithPassword", "CallbackGame", "Buy"]
        for kind in supported {
            let fields: [String: TDLibValue] = switch kind {
            case "Url", "LoginUrl", "WebApp": ["url": .string("https://example.com")]
            case "Callback", "CallbackWithPassword": ["data": .string("AP/+gA==")]
            case "User": ["user_id": .integer(7)]
            case "CopyText": ["text": .string("Exact copied text")]
            default: [:]
            }
            let raw = TDLibMessage("inlineKeyboardButton", ["text": .string("Test"), "type": .typed("inlineKeyboardButtonType" + kind,
                fields)])
            let button = TelegramBotDecoder.button(raw, inline: true)
            switch kind {
            case "Url": XCTAssertEqual(button.action, .url("https://example.com"))
            case "Callback": XCTAssertEqual(button.action, .callback(Data([0, 255, 254, 128])))
            case "User": XCTAssertEqual(button.action, .user(7))
            case "CopyText": XCTAssertEqual(button.action, .copy("Exact copied text"))
            case "Disabled": XCTAssertFalse(button.enabled)
            default: if case .openTelegram = button.action {} else { XCTFail(kind) }
            }
        }
        for kind in ["Text", "RequestPhoneNumber", "RequestLocation", "RequestPoll", "RequestUsers", "RequestChat", "RequestManagedBot", "WebApp"] {
            let raw = TDLibMessage("keyboardButton", ["text": .string("Send me"), "type": .typed("keyboardButtonType" + kind)])
            let button = TelegramBotDecoder.button(raw, inline: false)
            if kind == "Text" { XCTAssertEqual(button.action, .text) }
            else { XCTAssertEqual(button.action, .openTelegram("Action available in Telegram")) }
        }
        for inline in [true, false] {
            let button = TelegramBotDecoder.button(TDLibMessage(inline ? "inlineKeyboardButton" : "keyboardButton"), inline: inline)
            XCTAssertFalse(button.enabled)
        }
        XCTAssertNil(TelegramBotDecoder.safeButtonURL("file:///tmp/test"))
        XCTAssertNil(TelegramBotDecoder.safeButtonURL("https://user:password@example.com"))
    }
    func testCallbackBytesDoubleClickAlertErrorAndNoOutgoingOperation() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        let draft = TelegramDraft(text: "Do not consume this")
        h.session.draft(h.id, epoch: h.epoch, value: draft)
        let action = inline(h)
        var answers: [TelegramBotActionResult] = []
        act(h, action) { answers.append($0) }; act(h, action) { answers.append($0) }
        XCTAssertEqual(h.client.requests.filter { $0.type == "getCallbackQueryAnswer" }.count, 1)
        let request = try h.answer("getCallbackQueryAnswer", TDLibMessage("callbackQueryAnswer", ["text": .string("Done"), "show_alert": .bool(true)]))
        XCTAssertEqual(request["payload"], .typed("callbackQueryPayloadData", ["data": .string("AP/+gA==")]))
        XCTAssertTrue(answers.contains(.alert("Done"))); XCTAssertTrue(h.feed.snapshot.pendingBotButtons.isEmpty)
        act(h, action) { answers.append($0) }
        try h.answer("getCallbackQueryAnswer", TDLibMessage("error", ["code": .integer(502)]))
        XCTAssertEqual(h.client.requests.filter { $0.type == "getCallbackQueryAnswer" }.count, 2)
        XCTAssertEqual(h.feed.snapshot.draft, draft); XCTAssertTrue(h.journal.operations.isEmpty)
        XCTAssertFalse(h.client.requests.contains { ["sendMessage", "sendBotStartMessage"].contains($0.type) })
    }
    func testEditedDeletedAndOldEpochButtonsCannotExecuteOrDeliverLateAlert() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        let action = inline(h)
        var result: TelegramBotActionResult?
        act(h, action) { result = $0 }
        h.update("updateMessageEdited", ["chat_id": .integer(h.id.chat), "message_id": .integer(10), "edit_date": .integer(20),
            "reply_markup": markup("replyMarkupInlineKeyboard", fields: ["data": .string("bmV3")])])
        try h.answer("getCallbackQueryAnswer", TDLibMessage("callbackQueryAnswer", ["text": .string("Stale alert"), "show_alert": .bool(true)]))
        XCTAssertEqual(result, .error("This button changed or was removed"))
        act(h, action) { result = $0 }
        XCTAssertEqual(h.client.requests.filter { $0.type == "getCallbackQueryAnswer" }.count, 1)
        let current = inline(h)
        h.update("updateDeleteMessages", ["chat_id": .integer(h.id.chat), "message_ids": .array([.integer(10)]), "is_permanent": .bool(true)])
        act(h, current) { result = $0 }; XCTAssertEqual(result, .error("This button changed or was removed"))
        h.session.botAction(h.id, epoch: UUID(), action: current) { result = $0 }
        XCTAssertEqual(h.client.requests.filter { $0.type == "getCallbackQueryAnswer" }.count, 1)
    }
    func testCallbackTimeoutNeverReplaysAndLateReplyDoesNotCompleteTwice() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        let action = inline(h)
        var results: [TelegramBotActionResult] = []
        act(h, action) { results.append($0) }
        h.session.tick(now: h.now.addingTimeInterval(41), uptime: 51)
        XCTAssertEqual(results.count, 1); XCTAssertTrue(h.feed.snapshot.pendingBotButtons.isEmpty)
        try h.answer("getCallbackQueryAnswer", TDLibMessage("callbackQueryAnswer", ["text": .string("Late"), "show_alert": .bool(true)]))
        XCTAssertEqual(results.count, 1); XCTAssertEqual(h.client.requests.filter { $0.type == "getCallbackQueryAnswer" }.count, 1)
    }
    func testStartUsesSharedJournalQueueAndPreservesDraftWithoutStartingOnOpen() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        XCTAssertNil(h.chat()["message_sender_id"])
        XCTAssertEqual(h.feed.snapshot.capabilities.sender, "You")
        XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
        XCTAssertTrue(h.feed.snapshot.capabilities.canSendPhotos)
        XCTAssertTrue(h.feed.snapshot.capabilities.canSendDocuments)
        let draft = TelegramDraft(text: "Keep draft"); h.session.draft(h.id, epoch: h.epoch, value: draft)
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendBotStartMessage" })
        act(h, .start) { _ in }; act(h, .start) { _ in }
        try h.answer("getChat", h.chat()); try h.answer("getUser", bot(h))
        let start = try h.answer("sendBotStartMessage", h.message(91, outgoing: true, state: .typed("messageSendingStatePending")))
        XCTAssertEqual(start["parameter"], .string("")); XCTAssertEqual(start["bot_user_id"], .integer(202))
        XCTAssertEqual(h.journal.operations.first?.botStart, 202); XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .pending)
        XCTAssertEqual(h.feed.snapshot.draft, draft)
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(h.message(100, outgoing: true).fields)])
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .sent)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendBotStartMessage" }.count, 1)
    }
    func testReplyKeyboardTextOneTimeRemoveAndForceReplyKeepComposer() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        var message = h.message(10)
        message["reply_markup"] = markup("replyMarkupShowKeyboard", button: "keyboardButtonTypeText", fields: [:], extras: ["one_time": .bool(true), "is_personal": .bool(true), "is_persistent": .bool(true), "resize_keyboard": .bool(true), "input_field_placeholder": .string("Choose a task")])
        h.update("updateChatReplyMarkup", ["chat_id": .integer(h.id.chat), "reply_markup_message": .object(message.fields)])
        let keyboard = try XCTUnwrap(h.feed.snapshot.replyKeyboard)
        XCTAssertTrue(keyboard.oneTime && keyboard.personal && keyboard.persistent && keyboard.resize)
        let draft = TelegramDraft(text: "Unsent draft"); h.session.draft(h.id, epoch: h.epoch, value: draft)
        act(h, .button(message: 10, revision: keyboard.revision, row: 0, column: 0, replyKeyboard: true)) { _ in }
        var chat = h.chat(); chat["reply_markup_message_id"] = .integer(10)
        try h.answer("getChat", chat); try h.answer("getUser", bot(h))
        let sent = try XCTUnwrap(h.client.requests.last { $0.type == "sendMessage" })
        XCTAssertEqual(sent["input_message_content"]?.object?["text"]?.object?["text"], .string("Visible text"))
        XCTAssertEqual(h.feed.snapshot.draft, draft); XCTAssertTrue(h.feed.snapshot.keyboardHidden)
        message["reply_markup"] = .typed("replyMarkupForceReply", ["is_personal": .bool(true), "input_field_placeholder": .string("Reply here")])
        h.update("updateChatReplyMarkup", ["chat_id": .integer(h.id.chat), "reply_markup_message": .object(message.fields)])
        XCTAssertTrue(h.feed.snapshot.replyKeyboard?.forceReply == true); XCTAssertFalse(h.feed.snapshot.keyboardHidden)
        h.update("updateChatReplyMarkup", ["chat_id": .integer(h.id.chat), "reply_markup_message": .null])
        XCTAssertNil(h.feed.snapshot.replyKeyboard); XCTAssertEqual(h.feed.snapshot.draft, draft)
    }
    func testChangedReplyKeyboardDuringValidationDoesNotSendOldLabel() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        var message = h.message(10); message["reply_markup"] = markup("replyMarkupShowKeyboard", button: "keyboardButtonTypeText")
        h.session.applyReplyKeyboard(message, to: h.feed)
        let keyboard = try XCTUnwrap(h.feed.snapshot.replyKeyboard)
        act(h, .button(message: 10, revision: keyboard.revision, row: 0, column: 0, replyKeyboard: true)) { _ in }
        h.update("updateChatReplyMarkup", ["chat_id": .integer(h.id.chat)])
        try h.answer("getChat", h.chat()); try h.answer("getUser", bot(h))
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendMessage" }); XCTAssertTrue(h.journal.operations.isEmpty)
    }
    func testFullInfoCommandsEphemeralAndInlineModeGuard() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        h.session.refreshBotDetails(h.feed)
        try h.answer("getUserFullInfo", TDLibMessage("userFullInfo", ["bot_info": .typed("botInfo", ["description": .string("Bot description"), "commands": .array([
            .typed("botCommand", ["command": .string("help"), "description": .string("Help"), "is_ephemeral": .bool(false)]),
            .typed("botCommand", ["command": .string("special"), "is_ephemeral": .bool(true)])])])]))
        XCTAssertEqual(h.feed.snapshot.bot.description, "Bot description")
        var result: TelegramBotActionResult?
        act(h, .command("202:help")) { result = $0 }; XCTAssertEqual(result, .insertCommand("/help"))
        act(h, .command("202:special")) { result = $0 }; XCTAssertEqual(result, .openTelegram("This command is available in Telegram"))
        let draft = TelegramDraft(text: "@helper_bot find this")
        h.session.draft(h.id, epoch: h.epoch, value: draft); h.session.sendDraft(h.id, epoch: h.epoch, draft: draft)
        XCTAssertTrue(h.journal.operations.isEmpty); XCTAssertEqual(h.feed.snapshot.draft, draft)
        XCTAssertTrue(h.feed.snapshot.error?.contains("Inline mode") == true)
        var literal = draft; literal.sendAsText = true
        h.session.sendDraft(h.id, epoch: h.epoch, draft: literal)
        try h.answer("getChat", h.chat()); try h.answer("getUser", bot(h))
        XCTAssertEqual(h.client.requests.last { $0.type == "sendMessage" }?["input_message_content"]?.object?["text"]?.object?["text"], .string(draft.text))
        XCTAssertFalse(h.client.requests.contains { ["getBotCommands", "getInlineQueryResults", "sendInlineQueryResultMessage"].contains($0.type) })
    }
    func testURLCopyUserAndSpecialActionsPreserveDraftAndDoNotSend() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        let draft = TelegramDraft(text: "Keep this"); h.session.draft(h.id, epoch: h.epoch, value: draft)
        var result: TelegramBotActionResult?
        act(h, inline(h, button: "inlineKeyboardButtonTypeUrl", fields: ["url": .string("https://example.com/path")])) { result = $0 }
        XCTAssertEqual(result, .confirmURL(URL(string: "https://example.com/path")!))
        act(h, inline(h, button: "inlineKeyboardButtonTypeCopyText", fields: ["text": .string("Exact\ntext")])) { result = $0 }
        XCTAssertEqual(result, .copy("Exact\ntext"))
        act(h, inline(h, button: "inlineKeyboardButtonTypeSwitchInline")) { result = $0 }
        XCTAssertEqual(result, .openTelegram("Inline mode is available in Telegram"))
        act(h, inline(h, button: "inlineKeyboardButtonTypeUser", fields: ["user_id": .integer(202)])) { result = $0 }
        try h.answer("getUser", h.user()); try h.answer("createPrivateChat", h.chat())
        XCTAssertEqual(result, .user(h.id, "Casey")); XCTAssertEqual(h.feed.snapshot.draft, draft)
        XCTAssertTrue(h.journal.operations.isEmpty)
    }
    func testBotWithTopicsUsesForumCapabilityAndNeverOpensOrdinaryHistory() throws {
        let h = try TelegramFeedHarness(); h.feed.peer = bot(h, topics: true); h.session.capabilities(h.feed)
        XCTAssertEqual(h.feed.snapshot.kind, .bot); XCTAssertTrue(h.feed.snapshot.isTopicList); XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
        h.session.load(h.feed, latest: true)
        XCTAssertEqual(h.client.requests.last?.type, "getForumTopics")
        XCTAssertFalse(h.client.requests.contains { $0.type == "getChatHistory" })
        var result: TelegramBotActionResult?
        act(h, .start) { result = $0 }
        XCTAssertEqual(result, .openTelegram("Start is available in Telegram for this topic"))
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendBotStartMessage" })
    }
    func testCallbackURLRequiresConfirmationAndTelegramLinksUseTypedResolver() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        var result: TelegramBotActionResult?
        act(h, inline(h)) { result = $0 }
        try h.answer("getCallbackQueryAnswer", TDLibMessage("callbackQueryAnswer", ["text": .string("Review this"), "show_alert": .bool(true), "url": .string("https://example.com/result")]))
        XCTAssertEqual(result, .answerWithURL("Review this", alert: true, url: URL(string: "https://example.com/result")!))
        act(h, inline(h, button: "inlineKeyboardButtonTypeUrl", fields: ["url": .string("tg://resolve?domain=helper_bot&start=synthetic")])) { result = $0 }
        try h.answer("getInternalLinkType", TDLibMessage("internalLinkTypeBotStart", ["bot_username": .string("helper_bot"), "start_parameter": .string("synthetic"), "autostart": .bool(true)]))
        let request = try h.answer("getInternalLink", TDLibMessage("httpUrl", ["url": .string("https://t.me/helper_bot?start=synthetic")]))
        XCTAssertEqual(request["is_http"], .bool(true)); XCTAssertEqual(result, .confirmURL(URL(string: "https://t.me/helper_bot?start=synthetic")!))
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendBotStartMessage" })
    }
    func testReplyKeyboardOutsideHistoryExpiresAndOneTimeDismissalUsesPinnedAPI() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        var message = h.message(10)
        message["auto_delete_in"] = .decimal(2)
        message["reply_markup"] = markup("replyMarkupShowKeyboard", button: "keyboardButtonTypeText", extras: ["one_time": .bool(true), "is_personal": .bool(true)])
        h.session.applyReplyKeyboard(message, to: h.feed); h.session.boundMemory()
        h.session.tick(now: h.now.addingTimeInterval(3), uptime: 13)
        XCTAssertNil(h.feed.snapshot.replyKeyboard); XCTAssertTrue(h.feed.expired.contains(10))
        message["id"] = .integer(20); message["auto_delete_in"] = .decimal(0)
        h.session.applyReplyKeyboard(message, to: h.feed)
        h.session.dismissUsedKeyboard(h.feed, message: 20)
        let dismissed = try h.answer("deleteChatReplyMarkup")
        XCTAssertEqual(dismissed["message_id"], .integer(20)); XCTAssertTrue(h.feed.snapshot.keyboardHidden)
        XCTAssertTrue(h.journal.operations.isEmpty)
    }
    func testCommandsInGroupsResolveBotUsernameAndUnknownLayoutsHaveBoundedFallback() throws {
        let h = try TelegramFeedHarness(); prepare(h)
        h.feed.snapshot.kind = .group
        h.feed.snapshot.bot = TelegramBotDecoder.info(TDLibMessage("basicGroupFullInfo", ["bot_commands": .array([
            .typed("botCommands", ["bot_user_id": .integer(202), "commands": .array([.typed("botCommand", ["command": .string("help")])])])])]), user: nil)
        var result: TelegramBotActionResult?
        act(h, .command("202:help")) { result = $0 }; try h.answer("getUser", bot(h))
        XCTAssertEqual(result, .insertCommand("/help@helper_bot"))
        var message = h.message(10)
        message["reply_markup"] = .typed("replyMarkupInlineKeyboard", ["rows": .array(Array(repeating: .array([]), count: 33))])
        let decoded = try XCTUnwrap(TelegramMessageDecoder.decode(message, now: h.now, author: "Bot"))
        XCTAssertNil(decoded.inlineKeyboard); XCTAssertTrue(decoded.keyboardUnavailable)
    }

}
