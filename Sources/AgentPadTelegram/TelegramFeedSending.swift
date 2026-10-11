import Foundation

extension TelegramFeedSession {
    func refreshRetryStates(_ feed: Feed) {
        for index in feed.snapshot.messages.indices {
            let id = feed.snapshot.messages[index].messageID
            guard let failed = feed.failed[id] else { continue }
            let state = failed.state
            let owned = journal.operations.contains { $0.chat == feed.snapshot.destination.chat && $0.topic == feed.snapshot.destination.topic && $0.parts.contains { $0.messageID == id && $0.state == .failed } }
            let reason: String?
            if !owned || !feed.snapshot.capabilities.canSend { reason = "Retry unavailable here · Open in Telegram" }
            else if state["can_retry"]?.bool != true { reason = "Telegram does not allow retrying this message" }
            else if state["need_drop_reply"]?.bool != false { reason = "Reply unavailable · Restore a draft to change the reply" }
            else if state["need_another_sender"]?.bool != false { reason = "Another sender is required · Open in Telegram" }
            else if state["need_another_reply_quote"]?.bool != false { reason = "A new quote is required · Open in Telegram" }
            else if state["required_paid_message_star_count"]?.integer != 0 { reason = "Paid messages are available in Telegram" }
            else if now < failed.deadline { reason = "Telegram requires a wait before Retry" }
            else { reason = nil }
            if feed.snapshot.messages[index].canRetry != (reason == nil) || feed.snapshot.messages[index].retryReason != reason {
                feed.snapshot.messages[index].canRetry = reason == nil; feed.snapshot.messages[index].retryReason = reason; feed.dirty = true
            }
        }
    }
    @discardableResult func draft(_ id: TelegramChatID, epoch: UUID, value: TelegramDraft) -> Bool {
        guard matches(id, epoch), let feed = feeds[id], !feed.snapshot.isTopicList,
              ![.channel, .channelDirect, .secret].contains(feed.snapshot.kind),
              id.topic == nil || id.topic?.forumID != nil,
              !journal.operations.contains(where: { $0.chat == id.chat && $0.topic == id.topic && $0.revision == value.revision }) else { return false }
        if let reply = value.replyTo, feed.expired.contains(reply) { problem(feed, "The reply target expired or was deleted. Review the draft."); return false }
        do {
            try journal.saveDraft(value, chat: id.chat, topic: id.topic)
            feed.snapshot.draft = value; feed.snapshot.error = nil; feed.dirty = true
            return true
        } catch { problem(feed, (error as? TelegramConversationError)?.rawValue ?? TelegramConversationError.storage.rawValue); return false }
    }
    func sendDraft(_ id: TelegramChatID, epoch: UUID, revision: UUID) {
        guard let feed = feeds[id], feed.snapshot.draft.revision == revision else { return }
        sendDraft(id, epoch: epoch, draft: feed.snapshot.draft)
    }
    func sendDraft(_ id: TelegramChatID, epoch: UUID, draft: TelegramDraft, botStart: Int64? = nil, keyboardRevision: UUID? = nil, inlineChecked: Bool = false, accepted: (() -> Void)? = nil) {
        let revision = draft.revision
        guard matches(id, epoch), let feed = feeds[id], !draft.isEmpty,
              !journal.operations.contains(where: { $0.chat == id.chat && $0.topic == id.topic && $0.revision == revision }) else { return }
        if !inlineChecked, draft.sendAsText != true, TelegramInlineQuery.username(in: draft.text) != nil {
            inspectInlineQuery(id, epoch: epoch, text: draft.text) { [weak self, weak feed] result in
                guard let self, let feed else { return }
                if result == .ordinary { self.sendDraft(id, epoch: epoch, draft: draft, botStart: botStart, keyboardRevision: keyboardRevision, inlineChecked: true, accepted: accepted) }
                else { self.problem(feed, result == .inlineBot ? "Inline mode is available in Telegram · Use Send as text to send this literally" : "Could not check this inline query · Retry or choose Send as text") }
            }
            return
        }
        guard !feed.validating else { problem(feed, "Another Telegram action is being checked. Try Send again."); return }
        guard network == .ready else { problem(feed, "Telegram is offline. Your draft stays here."); return }
        refresh(feed) { [weak self, weak feed] valid in
            guard let self, let feed else { return }
            guard valid, self.validate(draft, feed: feed) else {
                if !valid { self.problem(feed, feed.snapshot.capabilities.reason.isEmpty ? "Telegram is busy. Try Send again." : feed.snapshot.capabilities.reason) }
                return
            }
            self.validateReply(draft.replyTo, feed: feed) { [weak self, weak feed] valid in
                guard let self, let feed, valid else { return }
                guard self.validate(draft, feed: feed) else { return }
                guard keyboardRevision == nil || keyboardRevision == feed.snapshot.replyKeyboard?.revision else {
                    self.problem(feed, "This keyboard changed or was removed. Choose a current button."); return
                }
                do {
                    var parts: [TelegramSendJournal.Part] = []
                    if draft.attachments.isEmpty || draft.text.utf16.count > self.captionLimit { parts.append(.init()) }
                    parts += draft.attachments.map { .init(attachment: $0.id) }
                    let operation = try self.journal.create(chat: id.chat, topic: id.topic, botStart: botStart, keyboardRevision: keyboardRevision, draft: draft, parts: parts, now: self.now)
                    if feed.snapshot.draft.revision == revision {
                        let empty = TelegramDraft()
                        try self.journal.saveDraft(empty, chat: id.chat, topic: id.topic)
                        feed.snapshot.draft = empty
                    }
                    feed.typing = [:]; self.reconcileTyping(feed)
                    feed.snapshot.error = nil; feed.dirty = true
                    self.enqueueSend(SendWork(operation: operation, index: 0), validated: true)
                    accepted?()
                } catch { self.problem(feed, (error as? TelegramConversationError)?.rawValue ?? TelegramConversationError.storage.rawValue) }
            }
        }
    }
    @discardableResult func validate(_ draft: TelegramDraft, feed: Feed) -> Bool {
        let capabilities = feed.snapshot.capabilities
        guard capabilities.canSend, network == .ready, now >= retryAt else {
            problem(feed, capabilities.reason.isEmpty ? "Sending unavailable. Your draft stays here." : capabilities.reason); return false
        }
        guard draft.text.utf8.count <= 16 * 1024, draft.text.utf16.count <= textLimit else {
            problem(feed, "Message exceeds Telegram’s text limit or AgentPad’s 16 KiB limit. Shorten it before sending."); return false
        }
        guard draft.attachments.count <= 10, draft.attachments.reduce(0, { $0 + $1.size }) <= TelegramFeedLimits.sendBytes else {
            problem(feed, TelegramConversationError.files.rawValue); return false
        }
        if now < feed.slowModeUntil { problem(feed, "Slow mode is active. Wait, then press Send again."); return false }
        do {
            for file in draft.attachments {
                guard file.mime.hasPrefix("image/") ? capabilities.canSendPhotos : capabilities.canSendDocuments else { throw TelegramConversationError.unavailable }
                try journal.validate(file)
            }
        } catch { problem(feed, "An attachment is unavailable or no longer permitted. Review the draft."); return false }
        return true
    }
    func validateReply(_ reply: Int64?, feed: Feed, completion: @escaping (Bool) -> Void) {
        guard let reply else { completion(true); return }
        let fields: [String: TDLibValue] = ["chat_id": .integer(feed.snapshot.destination.chat), "message_id": .integer(reply)]
        guard !feed.expired.contains(reply), request("getMessage", fields, { [weak self, weak feed] message in
            guard let self, let feed else { return }
            guard message.type == "message", message["id"]?.integer == reply,
                  message["chat_id"]?.integer == feed.snapshot.destination.chat,
                  !feed.expired.contains(reply) else {
                self.problem(feed, "Reply target is unavailable here. Review the reply or open Telegram."); completion(false); return
            }
            self.validateReplyContext(message, feed: feed) { [weak self, weak feed] allowed in
                guard let self, let feed else { return }
                guard allowed else { self.problem(feed, "This reply is available in Telegram. Your draft stays here."); completion(false); return }
                guard self.request("getMessageProperties", fields, { [weak self, weak feed] properties in
                    guard let self, let feed else { return }
                    let valid = properties.type == "messageProperties" && properties["can_be_replied"]?.bool == true && !feed.expired.contains(reply)
                    if !valid { self.problem(feed, "This message can no longer be replied to. Your draft stays here.") }
                    completion(valid)
                }) else { self.problem(feed, "Telegram is busy. Try again."); completion(false); return }
            }
        }) else { problem(feed, "Reply unavailable. Your draft stays here."); completion(false); return }
    }
    private func validateReplyContext(_ message: TDLibMessage, feed: Feed, completion: @escaping (Bool) -> Void) {
        func discussionPost(_ value: TDLibMessage) -> Bool {
            value["is_channel_post"]?.bool == true || ([TelegramChatKind.supergroup, .forum].contains(feed.snapshot.kind)
                && value["forward_info"]?.object?["origin"]?.object?.type == "messageOriginChannel"
                && value["forward_info"]?.object?["source"]?.object != nil)
        }
        guard !discussionPost(message) else { completion(false); return }
        if feed.snapshot.destination.topic != nil { completion(acceptsTopic(message["topic_id"], feed: feed)); return }
        guard let topic = message["topic_id"]?.object else { completion(true); return }
        if topic.type == "messageTopicSavedMessages" { completion(feed.snapshot.kind == .savedMessages); return }
        // Ordinary group threads remain replyable; a channel discussion root
        // must never create a comment send through this path.
        guard topic.type == "messageTopicThread", let root = topic["message_thread_id"]?.integer, root > 0 else { completion(false); return }
        if root == message["id"]?.integer { completion(true); return }
        guard request("getMessage", ["chat_id": .integer(feed.snapshot.destination.chat), "message_id": .integer(root)], { result in
            completion(result.type == "message" && result["id"]?.integer == root
                && result["chat_id"]?.integer == feed.snapshot.destination.chat && !discussionPost(result))
        }) else { completion(false); return }
    }
    func submit(_ work: SendWork, feed: Feed) {
        let operationID = work.operation, index = work.index
        guard let operation = journal.operation(operationID), operation.parts.indices.contains(index),
              operation.parts[index].state == .queued, let draft = journal.recovered(operationID), validate(draft, feed: feed) else {
            finishPreparing(work, retryLater: sendBackpressured); return
        }
        if let bot = operation.botStart {
            guard feed.snapshot.kind == .bot, feed.peer?["id"]?.integer == bot, operation.topic == nil else {
                problem(feed, "Start is unavailable here · Open in Telegram"); finishPreparing(work); return
            }
        }
        guard operation.keyboardRevision == nil || operation.keyboardRevision == feed.snapshot.replyKeyboard?.revision else {
            problem(feed, "This keyboard changed before sending. The unsent reply is in recovery."); finishPreparing(work); return
        }
        let part = operation.parts[index]
        let caption = index == 0 ? draft.text : ""
        let formatted: TDLibValue = .typed("formattedText", ["text": .string(caption), "entities": .array([])])
        var content: TDLibValue
        if let attachment = part.attachment, let file = draft.attachments.first(where: { $0.id == attachment }) {
            let input: TDLibValue = .typed("inputFileLocal", ["path": .string(journal.stageURL(file.id).path)])
            if file.mime.hasPrefix("image/") {
                content = .typed("inputMessagePhoto", ["photo": .typed("inputPhoto", ["photo": input, "thumbnail": .null, "video": .null,
                    "added_sticker_file_ids": .array([]), "width": .integer(Int64(file.width)), "height": .integer(Int64(file.height))]),
                    "caption": formatted, "show_caption_above_media": .bool(false), "self_destruct_type": .null, "has_spoiler": .bool(false)])
            } else {
                content = .typed("inputMessageDocument", ["document": .typed("inputDocument", ["document": input, "thumbnail": .null, "disable_content_type_detection": .bool(false)]), "caption": formatted])
            }
        } else {
            content = .typed("inputMessageText", ["text": formatted, "link_preview_options": .typed("linkPreviewOptions", ["is_disabled": .bool(true)]), "clear_draft": .bool(false)])
        }
        guard !sendBackpressured else { finishPreparing(work, retryLater: true); return }
        do { try journal.update(operationID) { $0.parts[index].state = .submitting } }
        catch { problem(feed, TelegramConversationError.storage.rawValue); finishPreparing(work); return }
        sending.insert(part.key)
        reconciled.insert(part.key)
        let reply: TDLibValue = draft.replyTo.map { .typed("inputMessageReplyToMessage", ["message_id": .integer($0), "quote": .null, "checklist_task_id": .integer(0), "poll_option_id": .string("")]) } ?? .null
        var fields: [String: TDLibValue] = ["chat_id": .integer(operation.chat), "topic_id": operation.topic?.wire ?? .null, "reply_to": reply,
            "options": .typed("messageSendOptions", ["scheduling_state": .null, "paid_message_star_count": .integer(0), "sending_id": .integer(part.sendingID), "only_preview": .bool(false)]),
            "reply_markup": .null, "input_message_content": content]
        if let bot = operation.botStart { fields = ["bot_user_id": .integer(bot), "chat_id": .integer(operation.chat), "parameter": .string("")] }
        _ = request(operation.botStart == nil ? "sendMessage" : "sendBotStartMessage", fields, onTimeout: { [weak self, weak feed] in
            try? self?.journal.update(operationID) { $0.parts[index].state = .unknown }
            if let self, let feed { self.problem(feed, "Send outcome unknown. Check Telegram; this message will not be replayed.") }
        }) { [weak self, weak feed] result in
            guard let self else { return }
            self.sendResponse(result, operation: operationID, part: index)
            feed?.dirty = true
        }
        feed.dirty = true
        finishPreparing(work)
    }
    func sendResponse(_ result: TDLibMessage, operation: UUID, part index: Int) {
        guard let op = journal.operation(operation) else { return }
        let part = op.parts[index]
        // A final update already reduced is stronger than a late pending RPC.
        if [.sent, .failed].contains(part.state) { return }
        if result.type == "message", let id = result["id"]?.integer {
            do { try journal.update(operation) { $0.parts[index].messageID = id; $0.parts[index].state = .pending } }
            catch { if let feed = feeds[destination(chat: op.chat, topic: op.topic)] { problem(feed, TelegramConversationError.storage.rawValue) }; return }
            if let feed = feeds[destination(chat: op.chat, topic: op.topic)] { feed.aliases[id] = part.key.uuidString; merge(result, into: feed, outcome: .pending) }
            if let early = earlyOutcomes.removeValue(forKey: "\(op.chat):\(id)") { correlate(early.0, oldID: id, outcome: early.1) }
        } else {
            let unknown = result["message"]?.string == "transport_unknown"
            try? journal.update(operation) { $0.parts[index].state = unknown ? .unknown : .failed }
            finishSend(op, index: index, succeeded: false)
            if let feed = feeds[destination(chat: op.chat, topic: op.topic)] { problem(feed, unknown ? "Send outcome unknown. Check Telegram before creating a new draft." : "Send failed. Your message is available in recovery.") }
        }
    }
    func correlate(_ message: TDLibMessage, oldID: Int64? = nil, outcome: TelegramSendJournal.Part.State?) {
        guard let chat = message["chat_id"]?.integer, let id = message["id"]?.integer else { return }
        let sendingID = message["sending_state"]?.object?["sending_id"]?.integer
        guard let op = journal.operations.first(where: { op in
            op.chat == chat && op.parts.contains { part in part.messageID == id || (oldID != nil && part.messageID == oldID) || (sendingID != nil && part.sendingID == sendingID) }
        }), let index = op.parts.firstIndex(where: { $0.messageID == id || (oldID != nil && $0.messageID == oldID) || (sendingID != nil && $0.sendingID == sendingID) }) else {
            if let oldID, let outcome, earlyOutcomes.count < 100 { earlyOutcomes["\(chat):\(oldID)"] = (message, outcome) }
            return
        }
        let part = op.parts[index]
        if part.state == .sent { return } // recovery may already be pruned; duplicate updates cannot demote success
        if [.sent, .failed].contains(part.state), outcome == nil { return }
        // A changed sender/reply from Telegram is explicit, never normal success.
        let draft = journal.recovered(op.id)
        let senderOK = message["sender_id"]?.object?.type == "messageSenderUser" && message["sender_id"]?.object?["user_id"]?.integer == account
        let replyOK = draft?.replyTo == message["reply_to"]?.object?["message_id"]?.integer
        let returnedTopic = TelegramMessageTopic.decode(message["topic_id"])
        let topicOK: Bool
        switch returnedTopic {
        case nil, .thread, .savedMessages: topicOK = op.topic == nil
        case .forum: topicOK = op.topic == returnedTopic
        default: topicOK = false
        }
        let mismatch = outcome == .sent && (!senderOK || !replyOK || !topicOK)
        do { try journal.update(op.id) { $0.parts[index].messageID = id; $0.parts[index].state = mismatch ? .unknown : outcome ?? .pending } }
        catch { if let feed = feeds[destination(chat: op.chat, topic: op.topic)] { problem(feed, TelegramConversationError.storage.rawValue) }; return }
        if outcome != nil { finishSend(op, index: index, succeeded: outcome == .sent && !mismatch); retrying.remove("\(chat):\(part.previousID ?? 0)") }
        if let feed = feeds[destination(chat: op.chat, topic: op.topic)] {
            if outcome == .sent, !mismatch, let keyboard = feed.snapshot.replyKeyboard,
               op.keyboardRevision == keyboard.revision || draft?.replyTo == keyboard.messageID {
                dismissUsedKeyboard(feed, message: keyboard.messageID)
            }
            feed.aliases[id] = part.key.uuidString
            if let oldID { feed.aliases[oldID] = part.key.uuidString }
            feed.snapshot.messages.removeAll { $0.id == part.key.uuidString }
            merge(message, into: feed, outcome: mismatch ? .unknown : outcome == .sent ? .sent : outcome == .failed ? .failed("Message failed to send") : .pending)
            if mismatch { problem(feed, "Telegram changed the sender, reply or topic. Review the result in Telegram.") }
            feed.dirty = true
        }
    }
    func recover(_ id: TelegramChatID, epoch: UUID, operation: UUID) {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.draft.isEmpty,
              let op = journal.operation(operation), op.chat == id.chat && op.topic == id.topic else { return }
        do {
            feed.snapshot.draft = try journal.restore(operation)
            sendQueue.removeAll { $0.operation == operation }
            feed.dirty = true
            drainSendQueue()
        } catch { problem(feed, TelegramConversationError.storage.rawValue) }
    }
    func discardRecovery(_ id: TelegramChatID, epoch: UUID, operation: UUID) {
        guard matches(id, epoch), let feed = feeds[id], let op = journal.operation(operation), op.chat == id.chat && op.topic == id.topic,
              op.parts.allSatisfy({ ![.pending, .submitting].contains($0.state) }) else { return }
        do {
            try journal.removeRecovery(operation)
            sendQueue.removeAll { $0.operation == operation }
            feed.dirty = true
            drainSendQueue()
        } catch { problem(feed, TelegramConversationError.storage.rawValue) }
    }
    func retry(_ id: TelegramChatID, epoch: UUID, messageID: Int64) {
        guard matches(id, epoch), feeds[id] != nil,
              !retrying.contains("\(id.chat):\(messageID)"),
              let operation = journal.operations.first(where: { $0.chat == id.chat && $0.topic == id.topic && $0.parts.contains { $0.messageID == messageID && $0.state == .failed } }),
              let index = operation.parts.firstIndex(where: { $0.messageID == messageID }), journal.recovered(operation.id) != nil else { return }
        retrying.insert("\(id.chat):\(messageID)")
        enqueueSend(SendWork(operation: operation.id, index: index, retryID: messageID))
    }
    func prepareRetry(_ work: SendWork, feed: Feed) {
        guard let messageID = work.retryID, let operation = journal.operation(work.operation),
              let draft = journal.recovered(work.operation) else { finishPreparing(work); return }
        let id = feed.snapshot.destination, index = work.index
        func rejected(_ reason: String) {
            problem(feed, reason)
            finishPreparing(work, retryLater: sendBackpressured)
        }
        refresh(feed) { [weak self, weak feed] valid in
            guard let self, let feed else { return }
            guard valid, self.validate(draft, feed: feed) else { rejected("Retry is unavailable. Review the message in Telegram."); return }
            let fields: [String: TDLibValue] = ["chat_id": .integer(id.chat), "message_id": .integer(messageID)]
            guard self.request("getMessage", fields, { [weak self, weak feed] failed in
                guard let self, let feed else { return }
                let topic = failed["topic_id"]?.object
                let topicAllowed = self.acceptsTopic(failed["topic_id"], feed: feed)
                    && (topic?.type != "messageTopicThread" || draft.replyTo != nil)
                guard failed.type == "message", failed["id"]?.integer == messageID, failed["chat_id"]?.integer == id.chat,
                      failed["sender_id"]?.object?["user_id"]?.integer == self.account,
                      failed["reply_to"]?.object?["message_id"]?.integer == draft.replyTo,
                      topicAllowed,
                      let state = failed["sending_state"]?.object, state.type == "messageSendingStateFailed" else { rejected("Failed message no longer matches this attempt."); return }
                if feed.failed[messageID] == nil { feed.failed[messageID] = (state, self.now.addingTimeInterval(max(0, state["retry_after"]?.number ?? 0))) }
                guard state["can_retry"]?.bool == true, state["need_drop_reply"]?.bool == false,
                      state["need_another_sender"]?.bool == false, state["need_another_reply_quote"]?.bool == false,
                      state["required_paid_message_star_count"]?.integer == 0,
                      (state["retry_after"]?.number ?? -1) >= 0, self.now >= feed.failed[messageID]!.deadline else {
                    rejected("Retry would change the reply, sender or payment, or Telegram requires a wait. Restore a draft or open Telegram."); return
                }
                guard self.request("getMessageProperties", fields, { [weak self, weak feed] properties in
                    guard let self, let feed else { return }
                    guard properties.type == "messageProperties" else { rejected("Message permissions are unavailable."); return }
                    self.validateReply(draft.replyTo, feed: feed) { [weak self, weak feed] valid in
                        guard let self, let feed else { return }
                        guard self.journal.operation(operation.id)?.parts[index].state == .failed,
                              self.journal.recovered(operation.id) != nil else { self.finishPreparing(work); return }
                        guard valid, self.validate(draft, feed: feed), !self.sendBackpressured else { rejected("Retry unavailable. Your message is unchanged."); return }
                        do { try self.journal.update(operation.id) { op in
                            op.parts[index].previousID = messageID; op.parts[index].state = .submitting
                        } } catch { rejected(TelegramConversationError.storage.rawValue); return }
                        self.sending.insert(operation.parts[index].key)
                        self.reconciled.insert(operation.parts[index].key)
                        _ = self.request("resendMessages", ["chat_id": .integer(id.chat), "message_ids": .array([.integer(messageID)]), "quote": .null, "paid_message_star_count": .integer(0)], onTimeout: { [weak self, weak feed] in
                            try? self?.journal.update(operation.id) { $0.parts[index].state = .unknown }
                            if let self, let feed { self.problem(feed, "Retry outcome unknown. Check Telegram before composing again.") }
                        }) { [weak self, weak feed] response in
                            guard let self else { return }
                            let result = response["messages"]?.array.first?.object ?? response
                            self.sendResponse(result, operation: operation.id, part: index)
                            self.retrying.remove("\(id.chat):\(messageID)"); feed?.dirty = true
                        }
                        self.finishPreparing(work)
                    }
                }) else { rejected("Telegram is busy. Try Retry again."); return }
            }) else { rejected("Telegram is busy. Try Retry again."); return }
        }
    }
    func reconcileOutbox(_ feed: Feed) {
        for operation in journal.operations where operation.chat == feed.snapshot.destination.chat && operation.topic == feed.snapshot.destination.topic {
            for (index, part) in operation.parts.enumerated() where [.pending, .unknown].contains(part.state) && !reconciled.contains(part.key) {
                guard let messageID = part.messageID else { reconciled.insert(part.key); continue }
                if request("getMessage", ["chat_id": .integer(operation.chat), "message_id": .integer(messageID)], { [weak self, weak feed] response in
                    guard let self, let feed else { return }
                    if response.type == "message", response["id"]?.integer == messageID {
                        let state = response["sending_state"]?.object?.type
                        let result: TelegramSendJournal.Part.State? = state == "messageSendingStateFailed" ? .failed
                            : state == nil && messageID > 0 && messageID & ((1 << 20) - 1) == 0 ? .sent : nil
                        self.correlate(response, outcome: result)
                        self.merge(response, into: feed)
                    } else {
                        try? self.journal.update(operation.id) { $0.parts[index].state = .unknown }
                        self.problem(feed, "A previous send could not be resolved. Check Telegram; it will not be replayed.")
                    }
                    feed.dirty = true
                }) { reconciled.insert(part.key) }
                return
            }
        }
    }
}
