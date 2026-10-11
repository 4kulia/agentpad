import Foundation

extension TelegramFeedSession {
    /// A callback timeout may finish the UI action while its RPC still owns a
    /// scheduler slot. Late answers cannot deliver a second alert or URL.
    final class BotReply {
        private var completion: ((TelegramBotActionResult) -> Void)?
        init(_ completion: @escaping (TelegramBotActionResult) -> Void) { self.completion = completion }
        func finish(_ result: TelegramBotActionResult) { let callback = completion; completion = nil; callback?(result) }
    }

    func refreshBotDetails(_ feed: Feed) {
        guard feed.snapshot.capabilities.canRead else { return }
        persistKeyboardDismissal(feed)
        if !feed.botInfoLoaded, !feed.botInfoPending {
            let bot = feed.snapshot.kind == .bot
            let basic = feed.snapshot.kind == .group
            if bot || basic {
                let field = bot ? "user_id" : "basic_group_id"
                if let id = feed.chat?["type"]?.object?[field]?.integer {
                    feed.botInfoPending = true
                    let sent = request(bot ? "getUserFullInfo" : "getBasicGroupFullInfo", [field: .integer(id)]) { [weak self, weak feed] response in
                        guard let self, let feed else { return }
                        feed.botInfoPending = false; feed.botInfoLoaded = true
                        if response.type == (bot ? "userFullInfo" : "basicGroupFullInfo") {
                            feed.snapshot.bot = TelegramBotDecoder.info(response, user: bot ? id : nil)
                            if bot { feed.fullInfo = TDLibMessage(response.fields.filter { ["outgoing_paid_message_star_count"].contains($0.key) }); self.capabilities(feed) }
                            feed.dirty = true
                        } else { self.problem(feed, "Bot details unavailable · Reload to retry") }
                    }
                    if !sent { feed.botInfoPending = false }
                }
            } else if let info = feed.fullInfo { feed.snapshot.bot = TelegramBotDecoder.info(info, user: nil); feed.botInfoLoaded = true; feed.dirty = true }
        }
        guard feed.replyMarkupID != 0, feed.snapshot.replyKeyboard == nil, !feed.replyMarkupPending, !feed.snapshot.isTopicList else { return }
        let messageID = feed.replyMarkupID, generation = feed.replyMarkupGeneration
        feed.replyMarkupPending = true
        let sent = request("getMessage", ["chat_id": .integer(feed.snapshot.destination.chat), "message_id": .integer(messageID)]) { [weak self, weak feed] message in
            guard let self, let feed else { return }
            feed.replyMarkupPending = false
            guard generation == feed.replyMarkupGeneration else { return }
            if message.type == "message", message["id"]?.integer == messageID { self.applyReplyKeyboard(message, to: feed) }
            else { feed.replyMarkupID = 0; self.problem(feed, "Bot keyboard unavailable · Reload to retry") }
        }
        if !sent { feed.replyMarkupPending = false }
    }

    func applyReplyKeyboard(_ message: TDLibMessage?, to feed: Feed) {
        feed.replyMarkupGeneration = UUID()
        feed.chat?["reply_markup_message_id"] = .integer(message?["id"]?.integer ?? 0)
        guard let message, message["chat_id"]?.integer == feed.snapshot.destination.chat,
              let id = message["id"]?.integer, !feed.expired.contains(id), acceptsTopic(message["topic_id"], feed: feed),
              message["self_destruct_type"]?.object == nil, message["content"]?.object?["is_secret"]?.bool != true,
              let keyboard = TelegramBotDecoder.keyboard(message["reply_markup"]?.object, message: id), keyboard.kind != .inline || keyboard.forceReply else {
            feed.snapshot.replyKeyboard = nil; feed.replyMarkupID = 0; feed.snapshot.keyboardHidden = false; feed.dirty = true; return
        }
        let updated = keyboard.keepingRevision(of: feed.snapshot.replyKeyboard)
        if updated.revision != feed.snapshot.replyKeyboard?.revision { feed.snapshot.keyboardHidden = updated.oneTime && !updated.personal }
        feed.snapshot.replyKeyboard = updated; feed.replyMarkupID = id; feed.dirty = true
        if let expiry = message["auto_delete_in"]?.number, expiry > 0 {
            feed.expiry[id] = min(feed.expiry[id] ?? .infinity, uptime + expiry); temporalDirty = true
        }
    }

    func dismissUsedKeyboard(_ feed: Feed, message: Int64? = nil) {
        guard let keyboard = feed.snapshot.replyKeyboard, message == nil || keyboard.messageID == message else { return }
        if keyboard.oneTime || keyboard.forceReply {
            feed.snapshot.keyboardHidden = true; feed.dirty = true
            feed.dismissReplyMarkup = keyboard.messageID
            persistKeyboardDismissal(feed)
        }
    }
    private func persistKeyboardDismissal(_ feed: Feed) {
        guard let message = feed.dismissReplyMarkup, !feed.dismissReplyMarkupInFlight else { return }
        feed.dismissReplyMarkupInFlight = true
        let sent = request("deleteChatReplyMarkup", ["chat_id": .integer(feed.snapshot.destination.chat), "message_id": .integer(message)]) { [weak self, weak feed] result in
            guard let self, let feed else { return }
            feed.dismissReplyMarkupInFlight = false
            if feed.dismissReplyMarkup == message { feed.dismissReplyMarkup = nil }
            if result.type != "ok" { self.problem(feed, "Keyboard dismissal could not be saved · Hide it again to retry") }
        }
        if !sent { feed.dismissReplyMarkupInFlight = false }
    }

    func currentButton(_ action: TelegramBotAction, feed: Feed) -> (TelegramBotKeyboard, TelegramBotButton)? {
        guard feed.snapshot.capabilities.canRead, !feed.snapshot.isTopicList,
              case let .button(message, revision, row, column, reply) = action, !feed.expired.contains(message) else { return nil }
        let keyboard = reply ? feed.snapshot.replyKeyboard : feed.snapshot.messages.first { $0.messageID == message }?.inlineKeyboard
        guard let keyboard, keyboard.messageID == message, keyboard.revision == revision,
              keyboard.rows.indices.contains(row), keyboard.rows[row].indices.contains(column) else { return nil }
        return (keyboard, keyboard.rows[row][column])
    }

    func botAction(_ id: TelegramChatID, epoch: UUID, action: TelegramBotAction, completion: @escaping (TelegramBotActionResult) -> Void) {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.capabilities.canRead else { completion(.error("This bot action is no longer available")); return }
        switch action {
        case .dismissKeyboard(let revision):
            if feed.snapshot.replyKeyboard?.revision == revision { feed.snapshot.keyboardHidden = true; feed.dirty = true; dismissUsedKeyboard(feed) }
            completion(.notice("Keyboard hidden"))
        case .showKeyboard(let revision):
            if feed.snapshot.replyKeyboard?.revision == revision { feed.snapshot.keyboardHidden = false; feed.dirty = true }
            completion(.notice("Keyboard shown"))
        case .start:
            guard feed.snapshot.kind == .bot, let user = feed.peer?["id"]?.integer, id.topic == nil, !feed.snapshot.isTopicList else {
                completion(.openTelegram("Start is available in Telegram for this topic")); return
            }
            guard !feed.validating, !journal.operations.contains(where: { $0.chat == id.chat && $0.botStart != nil && $0.parts.contains { [.queued, .submitting, .pending].contains($0.state) } }) else {
                completion(.notice("Start is already pending")); return
            }
            sendDraft(id, epoch: epoch, draft: TelegramDraft(text: "/start"), botStart: user)
            completion(.notice("Starting bot…"))
        case .command(let key):
            guard let command = feed.snapshot.bot.commands.first(where: { $0.id == key }) else { completion(.error("Command is no longer available")); return }
            guard !command.isEphemeral else { completion(.openTelegram("This command is available in Telegram")); return }
            if feed.snapshot.kind == .bot { completion(.insertCommand("/" + command.command)); return }
            let reply = BotReply(completion)
            guard request("getUser", ["user_id": .integer(command.botUserID)], onTimeout: { reply.finish(.error("Bot lookup timed out · Retry")) }, { [weak self, weak feed] user in
                guard let self, let feed, self.matches(id, epoch), feed.snapshot.bot.commands.contains(command),
                      user.type == "user", user["id"]?.integer == command.botUserID, user["type"]?.object?.type == "userTypeBot",
                      let username = user["usernames"]?.object?["active_usernames"]?.array.first?.string,
                      TelegramInlineQuery.username(in: "@" + username + " ") != nil else { reply.finish(.error("Bot command unavailable")); return }
                self.rememberUser(user); reply.finish(.insertCommand("/" + command.command + "@" + username))
            }) else { reply.finish(.error("Telegram is busy · Try again")); return }
        case .button:
            guard let (keyboard, button) = currentButton(action, feed: feed) else { completion(.error("This button changed or was removed")); return }
            guard button.enabled else { completion(.error(button.explanation)); return }
            switch button.action {
            case .disabled: completion(.error(button.explanation))
            case .openTelegram(let reason): completion(.openTelegram(reason))
            case .copy(let text):
                guard feed.chat?["has_protected_content"]?.bool != true,
                      feed.snapshot.messages.first(where: { $0.messageID == keyboard.messageID })?.protectedContent != true else { completion(.error("Protected content · Open in Telegram")); return }
                completion(.copy(text))
            case .text:
                guard feed.snapshot.capabilities.canSend, !feed.snapshot.keyboardHidden else { completion(.error("Sending is unavailable")); return }
                var draft = TelegramDraft(text: button.text, replyTo: keyboard.forceReply ? keyboard.messageID : nil)
                draft.sendAsText = true // an explicit text button is not an inline query
                sendDraft(id, epoch: epoch, draft: draft, keyboardRevision: keyboard.revision, accepted: { [weak feed] in
                    guard let feed, feed.snapshot.replyKeyboard?.revision == keyboard.revision else { return }
                    if keyboard.oneTime { feed.snapshot.keyboardHidden = true; feed.dirty = true }
                })
                completion(.notice("Sending keyboard reply…"))
            case .url(let raw):
                resolveBotURL(raw) { [weak self, weak feed] result in
                    guard let self, let feed, self.matches(id, epoch), self.currentButton(action, feed: feed) != nil else { completion(.error("This button changed or was removed")); return }
                    completion(result)
                }
            case .user(let userID):
                let reply = BotReply(completion)
                guard request("getUser", ["user_id": .integer(userID)], onTimeout: { reply.finish(.error("User lookup timed out · Retry")) }, { [weak self, weak feed] user in
                    guard let self, let feed, self.matches(id, epoch), self.currentButton(action, feed: feed) != nil,
                          user.type == "user", user["id"]?.integer == userID, user["have_access"]?.bool == true,
                          ["userTypeRegular", "userTypeBot"].contains(user["type"]?.object?.type ?? "") else { reply.finish(.error("User unavailable")); return }
                    self.rememberUser(user)
                    guard self.request("createPrivateChat", ["user_id": .integer(userID), "force": .bool(false)], onTimeout: { reply.finish(.error("User lookup timed out · Retry")) }, { [weak self, weak feed] chat in
                        guard let self, let feed, self.matches(id, epoch), self.currentButton(action, feed: feed) != nil,
                              chat.type == "chat", chat["type"]?.object?.type == "chatTypePrivate", chat["type"]?.object?["user_id"]?.integer == userID,
                              let chatID = chat["id"]?.integer else { reply.finish(.error("User unavailable")); return }
                        reply.finish(.user(self.destination(chat: chatID), self.userName(user)))
                    }) else { reply.finish(.error("Telegram is busy · Try again")); return }
                }) else { reply.finish(.error("Telegram is busy · Try again")); return }
            case .callback(let data):
                guard network == .ready else { completion(.error("Telegram is offline · Try again when connected")); return }
                let key = "\(keyboard.messageID):\(keyboard.revision)"
                guard !feed.snapshot.pendingBotButtons.contains(key) else { completion(.notice("Waiting for the bot…")); return }
                feed.snapshot.pendingBotButtons.insert(key); feed.dirty = true
                let reply = BotReply(completion)
                let sent = request("getCallbackQueryAnswer", ["chat_id": .integer(id.chat), "message_id": .integer(keyboard.messageID),
                    "payload": .typed("callbackQueryPayloadData", ["data": .string(data.base64EncodedString())])], onTimeout: { [weak feed] in
                        feed?.snapshot.pendingBotButtons.remove(key); feed?.dirty = true
                        reply.finish(.error("Bot response timed out · Retry manually; the action may have completed"))
                    }) { [weak self, weak feed] response in
                        guard let self, let feed else { reply.finish(.error("Bot action unavailable")); return }
                        feed.snapshot.pendingBotButtons.remove(key); feed.dirty = true
                        guard self.matches(id, epoch), self.currentButton(action, feed: feed) != nil else { reply.finish(.error("This button changed or was removed")); return }
                        guard response.type == "callbackQueryAnswer" else { reply.finish(.error("Bot request failed · Press the button to retry")); return }
                        let text = String((response["text"]?.string ?? "").prefix(4096))
                        if let url = response["url"]?.string, !url.isEmpty {
                            self.resolveBotURL(url) { [weak self, weak feed] result in
                                guard let self, let feed, self.matches(id, epoch), self.currentButton(action, feed: feed) != nil else { reply.finish(.error("This button changed or was removed")); return }
                                if case .confirmURL(let url) = result, !text.isEmpty {
                                    reply.finish(.answerWithURL(text, alert: response["show_alert"]?.bool == true, url: url))
                                } else { reply.finish(result) }
                            }
                        } else { reply.finish(response["show_alert"]?.bool == true ? .alert(text) : .notice(text.isEmpty ? "Bot action completed" : text)) }
                    }
                if !sent { feed.snapshot.pendingBotButtons.remove(key); feed.dirty = true; reply.finish(.error("Telegram is busy · Try again")) }
            }
        }
    }

    func resolveBotURL(_ raw: String, completion: @escaping (TelegramBotActionResult) -> Void) {
        guard let safe = TelegramBotDecoder.safeButtonURL(raw), let url = URL(string: safe) else { completion(.error("Unsafe or unsupported link")); return }
        let telegram = url.scheme?.lowercased() == "tg" || ["t.me", "telegram.me", "telegram.dog"].contains(url.host?.lowercased() ?? "")
        guard telegram else { completion(.confirmURL(url)); return }
        let reply = BotReply(completion)
        guard request("getInternalLinkType", ["link": .string(raw)], onTimeout: { reply.finish(.error("Link lookup timed out · Retry")) }, { [weak self] type in
            guard let self, ["internalLinkTypePublicChat", "internalLinkTypeBotStart", "internalLinkTypeMessage", "internalLinkTypeSavedMessages", "internalLinkTypeDirectMessagesChat"].contains(type.type) else {
                reply.finish(.openTelegram("This Telegram link requires an action in Telegram")); return
            }
            guard self.request("getInternalLink", ["type": .object(type.fields), "is_http": .bool(true)], onTimeout: { reply.finish(.error("Link lookup timed out · Retry")) }, { result in
                guard result.type == "httpUrl", let raw = result["url"]?.string, let safe = TelegramMessageDecoder.safeURL(raw),
                      let verified = URL(string: safe), verified.scheme == "https", ["t.me", "telegram.me"].contains(verified.host?.lowercased() ?? ""), verified.user == nil, verified.password == nil else { reply.finish(.error("Telegram link unavailable")); return }
                reply.finish(.confirmURL(verified))
            }) else { reply.finish(.error("Telegram is busy · Try again")); return }
        }) else { reply.finish(.error("Telegram is busy · Try again")); return }
    }

    func inspectInlineQuery(_ id: TelegramChatID, epoch: UUID, text: String, completion: @escaping (TelegramInlineQueryCheck) -> Void) {
        guard matches(id, epoch) else { completion(.unavailable); return }
        guard let name = TelegramInlineQuery.username(in: text) else { completion(.ordinary); return }
        func result(_ user: TDLibMessage) -> TelegramInlineQueryCheck {
            user["type"]?.object?.type == "userTypeBot" && user["type"]?.object?["is_inline"]?.bool == true ? .inlineBot : .ordinary
        }
        if let user = users.values.first(where: { ($0["usernames"]?.object?["active_usernames"]?.array ?? []).contains { $0.string?.lowercased() == name } }) {
            completion(result(user)); return
        }
        var finished = false
        func finish(_ result: TelegramInlineQueryCheck) { guard !finished else { return }; finished = true; completion(result) }
        guard request("searchPublicChat", ["username": .string(name)], onTimeout: { finish(.unavailable) }, { [weak self] chat in
            guard let self, self.matches(id, epoch) else { finish(.unavailable); return }
            if chat.type == "error" {
                finish(["USERNAME_NOT_OCCUPIED", "USERNAME_INVALID"].contains(chat["message"]?.string ?? "") ? .ordinary : .unavailable); return
            }
            guard chat.type == "chat" else { finish(.unavailable); return }
            guard chat["type"]?.object?.type == "chatTypePrivate", let user = chat["type"]?.object?["user_id"]?.integer else { finish(.ordinary); return }
            guard self.request("getUser", ["user_id": .integer(user)], onTimeout: { finish(.unavailable) }, { [weak self] value in
                guard let self, self.matches(id, epoch), value.type == "user", value["id"]?.integer == user else { finish(.unavailable); return }
                self.rememberUser(value); finish(result(value))
            }) else { finish(.unavailable); return }
        }) else { finish(.unavailable); return }
    }
}
