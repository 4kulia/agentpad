import Foundation

extension TelegramFeedSession {
    func receive(_ update: TDLibMessage, now: Date, uptime: TimeInterval) {
        self.now = now; self.uptime = uptime
        temporalDirty = true
        // Reduce before callbacks: send updates and RPC responses can cross.
        switch update.type {
        case "updateAccentColors":
            sponsoredColors = Self.decodeSponsoredColors(update)
            for (chat, entry) in sponsored {
                for i in entry.snapshot.messages.indices {
                    let colors = sponsoredColors[entry.snapshot.messages[i].accentColorID]
                    entry.snapshot.messages[i].lightColors = colors?.light ?? []
                    entry.snapshot.messages[i].darkColors = colors?.dark ?? []
                }
                publishSponsored(chat)
            }
        case "updateOption":
            let value = update["value"]?.object?["value"]?.integer
            switch update["name"]?.string {
            case "message_text_length_max": if let value, value > 0 { textLimit = Int(min(16384, value)) }
            case "message_caption_length_max": if let value, value > 0 { captionLimit = Int(min(16384, value)) }
            case "unix_time": if let value { serverOffset = Double(value) - now.timeIntervalSince1970 }
            default: break
            }
            for feed in feeds.values { feed.dirty = true }
        case "updateUser":
            if let user = update["user"]?.object {
                rememberUser(user)
                for feed in feeds.values {
                    if feed.chat?["type"]?.object?["user_id"]?.integer == user["id"]?.integer { feed.peer = user; capabilities(feed) }
                    for index in feed.snapshot.messages.indices where feed.snapshot.messages[index].senderID == user["id"]?.integer {
                        feed.snapshot.messages[index].author = userName(user); feed.dirty = true
                    }
                }
            }
        case "updateUserStatus":
            if let id = update["user_id"]?.integer { users[id]?["status"] = update["status"] }
        case "updateUserFullInfo", "updateBasicGroupFullInfo":
            let bot = update.type == "updateUserFullInfo"
            let field = bot ? "user_id" : "basic_group_id"
            if let full = update[bot ? "user_full_info" : "basic_group_full_info"]?.object, let id = update[field]?.integer {
                for feed in feeds.values where feed.chat?["type"]?.object?[field]?.integer == id {
                    feed.snapshot.bot = TelegramBotDecoder.info(full, user: bot ? id : nil); feed.botInfoLoaded = true
                    if bot { feed.fullInfo = TDLibMessage(full.fields.filter { $0.key == "outgoing_paid_message_star_count" }); capabilities(feed) }
                    feed.dirty = true
                }
            }
        case "updateBasicGroup", "updateSupergroup", "updateSupergroupFullInfo":
            let full = update.type == "updateSupergroupFullInfo"
            let field = full ? "supergroup_full_info" : update.type == "updateBasicGroup" ? "basic_group" : "supergroup"
            let value = update[field]?.object
            let id = full ? update["supergroup_id"]?.integer : value?["id"]?.integer
            for feed in feeds.values where feed.chat?["type"]?.object?[update.type == "updateBasicGroup" ? "basic_group_id" : "supergroup_id"]?.integer == id {
                if full {
                    feed.fullInfo = value; feed.slowModeUntil = now.addingTimeInterval(max(0, value?["slow_mode_delay_expires_in"]?.number ?? 0))
                    if let value { feed.snapshot.bot = TelegramBotDecoder.info(value, user: nil); feed.botInfoLoaded = true }
                } else { feed.peer = value }
                capabilities(feed)
            }
        case "updateForumTopicInfo", "updateForumTopic": receiveTopic(update)
        case "updateScopeNotificationSettings":
            if let scope = update["scope"]?.object?.type, ["notificationSettingsScopePrivateChats", "notificationSettingsScopeGroupChats"].contains(scope),
               let settings = update["notification_settings"]?.object {
                scopeMute[scope] = (settings["mute_for"]?.integer ?? 0) > 0
                for feed in feeds.values where muteScope(feed) == scope { applyInheritedMute(feed) }
            }
        case "updateNewChat":
            if let chat = update["chat"]?.object, let id = chat["id"]?.integer {
                for feed in feeds(in: id) { applyChat(chat, to: feed); feed.needsDetails = true }
            }
        case "updateNewMessage":
            if let message = update["message"]?.object, let chat = message["chat_id"]?.integer {
                correlate(message, outcome: nil)
                invalidateTopic(chat: chat, topic: TelegramMessageTopic.decode(message["topic_id"])?.forumID)
                for feed in feeds(in: chat) { applyLastMessage(message, to: feed) }
            }
        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            if let message = update["message"]?.object {
                let success = update.type == "updateMessageSendSucceeded"
                correlate(message, oldID: update["old_message_id"]?.integer, outcome: success ? .sent : .failed)
                if let chat = message["chat_id"]?.integer {
                  invalidateTopic(chat: chat, topic: TelegramMessageTopic.decode(message["topic_id"])?.forumID)
                  for feed in feeds(in: chat) where acceptsTopic(message["topic_id"], feed: feed) {
                    if let old = update["old_message_id"]?.integer { feed.snapshot.messages.removeAll { $0.messageID == old } }
                    let unresolved = journal.operations.contains { $0.chat == chat && $0.parts.contains { $0.messageID == message["id"]?.integer && $0.state == .unknown } }
                    applyLastMessage(message, to: feed, outcome: unresolved ? .unknown : success ? .sent : .failed("Message failed to send"))
                  }
                }
            }
        case "updateFile":
            if let file = update["file"]?.object { applyFile(file) }
        default:
            if let chat = update["chat_id"]?.integer {
                for feed in feeds(in: chat) { receiveChat(update, feed: feed) }
                if ["updateDeleteMessages", "updateMessageContent"].contains(update.type) { invalidateTopic(chat: chat, topic: nil) }
            }
        }
        if let token = update["@extra"]?.string, let call = calls.removeValue(forKey: token) {
            if update.type == "error", update["code"]?.integer == 429 {
                let delay = update["message"]?.string?.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }.last ?? 60
                retryAt = max(retryAt, now.addingTimeInterval(max(1, delay) + 1))
                onFloodWait(retryAt)
            }
            call.callback(update)
        }
        drainSendQueue()
    }
    private func receiveChat(_ update: TDLibMessage, feed: Feed) {
        switch update.type {
        case "updateChatLastMessage":
            if feed.snapshot.destination.topic == nil { applyLastMessage(update["last_message"]?.object, to: feed) }
        case "updateChatPermissions": feed.chat?["permissions"] = update["permissions"]; capabilities(feed)
        case "updateChatNotificationSettings": feed.chat?["notification_settings"] = update["notification_settings"]; applyInheritedMute(feed)
        case "updateChatMessageSender": feed.chat?["message_sender_id"] = update["message_sender_id"]; capabilities(feed)
        case "updateChatHasProtectedContent":
            feed.chat?["has_protected_content"] = update["has_protected_content"]
            if update["has_protected_content"]?.bool == true {
                for i in feed.snapshot.messages.indices { feed.snapshot.messages[i].protectedContent = true }
                filePaths = [:]
            }
        case "updateChatTitle": feed.snapshot.title = update["title"]?.string ?? "Telegram"
        case "updateChatReadInbox":
            if feed.snapshot.destination.topic == nil { feed.snapshot.inbox = update["last_read_inbox_message_id"]?.integer ?? feed.snapshot.inbox }
        case "updateChatReadOutbox":
            guard feed.snapshot.destination.topic == nil else { break }
            feed.snapshot.outbox = update["last_read_outbox_message_id"]?.integer ?? feed.snapshot.outbox
            for i in feed.snapshot.messages.indices where feed.snapshot.messages[i].outgoing && feed.snapshot.messages[i].messageID <= feed.snapshot.outbox && feed.snapshot.messages[i].delivery == .sent {
                feed.snapshot.messages[i].delivery = .read
            }
        case "updateMessageMentionRead":
            if let i = feed.snapshot.messages.firstIndex(where: { $0.messageID == update["message_id"]?.integer }) { feed.snapshot.messages[i].unreadMention = false }
        case "updateMessageInteractionInfo":
            if let i = feed.snapshot.messages.firstIndex(where: { $0.messageID == update["message_id"]?.integer }) {
                feed.snapshot.messages[i].viewCount = update["interaction_info"]?.object?["view_count"]?.integer
                feed.snapshot.messages[i].replyCount = update["interaction_info"]?.object?["reply_info"]?.object?["reply_count"]?.integer
            }
        case "updateMessageEdited":
            if let i = feed.snapshot.messages.firstIndex(where: { $0.messageID == update["message_id"]?.integer }) {
                feed.snapshot.messages[i].edited = (update["edit_date"]?.integer ?? 0) > 0
                feed.snapshot.messages[i].inlineKeyboard = TelegramBotDecoder.keyboard(update["reply_markup"]?.object, message: feed.snapshot.messages[i].messageID)
                    .flatMap { $0.kind == .inline ? $0 : nil }
                feed.snapshot.messages[i].keyboardUnavailable = update["reply_markup"]?.object?.type == "replyMarkupInlineKeyboard" && feed.snapshot.messages[i].inlineKeyboard == nil
            }
            if update["message_id"]?.integer == feed.replyMarkupID { feed.replyMarkupGeneration = UUID(); feed.snapshot.replyKeyboard = nil }
        case "updateChatReplyMarkup": applyReplyKeyboard(update["reply_markup_message"]?.object, to: feed)
        case "updateMessageContent":
            if let i = feed.snapshot.messages.firstIndex(where: { $0.messageID == update["message_id"]?.integer }), let content = update["new_content"]?.object {
                let formatted = content["text"]?.object ?? content["caption"]?.object
                // Protected disappearing rows never acquire bytes on an edit.
                if case .unsupported("Disappearing media · Open in Telegram") = feed.snapshot.messages[i].content { break }
                feed.snapshot.messages[i].text = formatted?["text"]?.string ?? ""
                feed.snapshot.messages[i].entities = TelegramMessageDecoder.entities(formatted, text: feed.snapshot.messages[i].text)
                feed.snapshot.messages[i].inlineKeyboard?.revision = UUID()
                feed.snapshot.messages[i].attachment = TelegramMessageDecoder.file(content)
                feed.snapshot.messages[i].content = ["messageText", "messageDocument", "messagePhoto"].contains(content.type) ? .message : .unsupported("Content unavailable · Open in Telegram")
                resolveReplies(feed)
            }
        case "updateDeleteMessages":
            if update["is_permanent"]?.bool == true && update["from_cache"]?.bool != true {
                for value in update["message_ids"]?.array ?? [] {
                    guard let id = value.integer else { continue }
                    // resendMessages deletes the old failed ID as part of the attempt.
                    let retrying = journal.operations.contains { $0.chat == feed.snapshot.destination.chat && $0.parts.contains { $0.previousID == id && [.submitting, .pending].contains($0.state) } }
                    if !retrying { erase(feed, id: id) }
                }
            }
        case "updateChatAction":
            guard active, network == .ready, feed.snapshot.capabilities.canRead,
                  TelegramMessageTopic.decode(update["topic_id"]) == feed.snapshot.destination.topic,
                  let sender = Sender(update["sender_id"]?.object),
                  let action = update["action"]?.object?.type else { break }
            let names = ["chatActionTyping": "typing…", "chatActionRecordingVideo": "recording video…", "chatActionRecordingVoiceNote": "recording voice…",
                "chatActionRecordingVideoNote": "recording video…", "chatActionUploadingVideo": "uploading video…", "chatActionUploadingVoiceNote": "uploading audio…",
                "chatActionUploadingPhoto": "uploading a photo…", "chatActionUploadingDocument": "uploading a file…", "chatActionUploadingVideoNote": "uploading video…",
                "chatActionChoosingSticker": "choosing a sticker…", "chatActionChoosingLocation": "choosing a location…", "chatActionChoosingContact": "choosing a contact…",
                "chatActionStartPlayingGame": "playing a game…", "chatActionWatchingAnimations": "watching animations…"]
            if let label = names[action], feed.actions.count < 100 || feed.actions[sender] != nil { feed.actions[sender] = (label, uptime + 6) }
            else { feed.actions[sender] = nil }
        default: break
        }
        feed.dirty = true
    }
    func observation(_ id: TelegramChatID, _ observation: TelegramPresentationObservation) {
        guard observation.isCurrent, matches(id, observation.epoch), let feed = feeds[id], feed.observers[observation.pane] != nil else { return }
        feed.observations[observation.pane] = observation
        if observation.shown { feed.used = now }
        if !observation.active || !observation.shown { feed.typing[observation.pane] = nil }
        reconcilePresentation(feed)
        reconcileSponsored()
    }
    func isVisible(_ item: TelegramPresentationItem, in feed: Feed) -> Bool {
        active && feed.snapshot.capabilities.canRead && feed.observations.values.contains { $0.sees(item) }
    }
    func reconcilePresentation(_ feed: Feed) {
        let chat = feed.snapshot.destination.chat
        let shown = feed.snapshot.capabilities.canRead && feed.observations.values.contains { $0.shown }
        feed.opened = shown
        let anyShown = feeds(in: chat).contains { $0.snapshot.capabilities.canRead && $0.observations.values.contains { $0.shown } }
        if anyShown != openedChats.contains(chat) {
            if request(anyShown ? "openChat" : "closeChat", ["chat_id": .integer(chat)], service: true, { [weak self, weak feed] response in
                guard let self, let feed else { return }
                if response.type != "ok" {
                    if anyShown { self.openedChats.remove(chat) } else { self.openedChats.insert(chat) }
                    self.problem(feed, "Telegram could not update chat visibility.")
                }
            }) { if anyShown { openedChats.insert(chat) } else { openedChats.remove(chat) } }
            return
        }
        guard shown, active, network == .ready else { return }
        let known = Set(feed.snapshot.messages.filter { $0.content != .deleted && $0.messageID > 0 }.map(\.messageID))
        let ids = feed.observations.values.filter { $0.active && $0.shown && $0.isCurrent }.reduce(into: Set<Int64>()) { $0.formUnion($1.ordinaryIDs) }
            .intersection(known).subtracting(feed.viewed).subtracting(feed.viewPending)
        guard !ids.isEmpty else { return }
        let batch = Set(ids.sorted().prefix(100))
        if request("viewMessages", ["chat_id": .integer(feed.snapshot.destination.chat), "message_ids": .array(batch.sorted().map(TDLibValue.integer)),
            "source": .typed(feed.snapshot.destination.topic?.forumID == nil ? "messageSourceChatHistory" : "messageSourceForumTopicHistory"), "force_read": .bool(false)], service: true,
            whileValid: { batch.allSatisfy { self.isVisible(.message($0), in: feed) } }, { [weak self, weak feed] response in
                guard let self, let feed else { return }; feed.viewPending.subtract(batch)
                if response.type == "ok" {
                    feed.viewed.formUnion(batch)
                    if let topic = feed.snapshot.destination.topic?.forumID { self.invalidateTopic(chat: chat, topic: topic) }
                }
                else { self.problem(feed, "Read state could not be updated. Telegram will retry."); self.retryAt = max(self.retryAt, self.now.addingTimeInterval(4)) }
                // Never move inbox/outbox or clear mention flags on RPC success.
            }) { feed.viewPending.formUnion(batch) }
    }
    func composer(_ id: TelegramChatID, epoch: UUID, pane: UUID, typing: Bool) {
        guard matches(id, epoch), let feed = feeds[id] else { return }
        if typing && active && network == .ready && feed.snapshot.capabilities.canSend && feed.observations[pane]?.active == true {
            feed.typing[pane] = uptime + 5
        } else { feed.typing[pane] = nil }
        temporalDirty = true
        reconcileTyping(feed)
    }
    func reconcileTyping(_ feed: Feed) {
        let typing = active && network == .ready && feed.snapshot.capabilities.canSend && !feed.typing.isEmpty
        guard typing ? uptime - feed.lastTyping >= 4 : feed.typingSent else { return }
        if request("sendChatAction", ["chat_id": .integer(feed.snapshot.destination.chat), "topic_id": feed.snapshot.destination.topic?.wire ?? .null,
            "business_connection_id": .string(""), "action": typing ? .typed("chatActionTyping") : .null]) {
            feed.typingSent = typing; feed.lastTyping = uptime
        }
    }
    func presence(_ feed: Feed, live: Bool) -> String {
        guard live else { return "" }
        if !feed.actions.isEmpty {
            return feed.actions.sorted { $0.key.key < $1.key.key }.prefix(3).map { sender, action in
                "\(senderName(sender)) \(action.0)"
            }.joined(separator: ", ")
        }
        guard feed.snapshot.kind == .person, let user = feed.chat?["type"]?.object?["user_id"]?.integer,
              let status = users[user]?["status"]?.object else { return "" }
        switch status.type {
        case "userStatusOnline": return Double(status["expires"]?.integer ?? 0) > now.timeIntervalSince1970 + serverOffset ? "Online" : ""
        case "userStatusOffline":
            guard let date = status["was_online"]?.integer, date > 0 else { return "" }
            return "Last seen " + Date(timeIntervalSince1970: Double(date)).formatted(date: .abbreviated, time: .shortened)
        case "userStatusRecently": return "Last seen recently"
        case "userStatusLastWeek": return "Last seen within a week"
        case "userStatusLastMonth": return "Last seen within a month"
        default: return ""
        }
    }
}
