import Foundation

extension TelegramFeedSession {
    struct TopicCursor: Hashable {
        var date: Int64 = 0
        var message: Int64 = 0
        var topic: Int64 = 0
    }

    struct TopicVersion {
        var generation = UUID()
        var fields: [String: TDLibValue] = [:]
        var hasUpdate = false

        mutating func invalidate(_ update: TDLibMessage?) {
            generation = UUID(); hasUpdate = update != nil
            if let info = update?["info"] { fields["info"] = info }
            else if let update {
                // Retain only fields represented by our topic snapshot, without
                // duplicating draft/message trees in this bounded version cache.
                for key in ["last_read_inbox_message_id", "last_read_outbox_message_id", "unread_mention_count", "notification_settings"] {
                    if let value = update[key] { fields[key] = value }
                }
            }
        }

        func isConsistent(with response: TDLibMessage) -> Bool {
            guard hasUpdate, !fields.isEmpty, response.type == "forumTopic" else { return false }
            return fields.allSatisfy { key, value in
                if key == "last_read_inbox_message_id" || key == "last_read_outbox_message_id" {
                    guard let current = value.integer, let incoming = response[key]?.integer else { return false }
                    return incoming >= current
                }
                return response[key] == value
            }
        }
    }

    func acceptsTopic(_ value: TDLibValue?, feed: Feed) -> Bool {
        let topic = TelegramMessageTopic.decode(value)
        if let selected = feed.snapshot.destination.topic { return selected.forumID != nil && selected == topic }
        switch topic {
        case nil: return !feed.snapshot.isTopicList
        case .savedMessages: return feed.snapshot.kind == .savedMessages
        case .thread: return [.group, .supergroup].contains(feed.snapshot.kind)
        default: return false
        }
    }

    func finishDetails(_ feed: Feed, completion: ((Bool) -> Void)?) {
        feed.needsDetails = false
        capabilities(feed)
        guard let topic = feed.snapshot.destination.topic?.forumID,
              feed.snapshot.kind == .forum || (feed.snapshot.kind == .bot && feed.peer?["type"]?.object?["has_topics"]?.bool == true) else {
            feed.validating = false; completion?(feed.snapshot.capabilities.canSend); return
        }
        let generation = feed.topicVersions[topic]?.generation
        if !request("getForumTopic", ["chat_id": .integer(feed.snapshot.destination.chat), "forum_topic_id": .integer(topic)], { [weak self, weak feed] result in
            guard let self, let feed else { return }
            feed.validating = false
            // The pinned TDLib emits topic updates before this RPC's response.
            // Accept matching/newer data, but never undo an intervening live update.
            guard generation == feed.topicVersions[topic]?.generation || feed.topicVersions[topic]?.isConsistent(with: result) == true else { completion?(false); return }
            if let value = self.decodeTopic(result, feed: feed), value.id == topic {
                self.applyTopic(value, to: feed); feed.invalidTopics.remove(topic)
            } else {
                feed.snapshot.topicInfo = nil; self.capabilities(feed)
                self.problem(feed, "Topic unavailable · Retry or open in Telegram")
            }
            completion?(feed.snapshot.capabilities.canSend)
        }) { feed.validating = false; completion?(false) }
    }

    func decodeTopic(_ raw: TDLibMessage, feed: Feed) -> TelegramForumTopic? {
        guard raw.type == "forumTopic", raw["info"]?.object?["chat_id"]?.integer == feed.snapshot.destination.chat else { return nil }
        return TelegramForumTopic(raw, chatMuted: inheritedMute(feed))
    }

    func applyTopic(_ topic: TelegramForumTopic, to feed: Feed) {
        if feed.snapshot.destination.topic?.forumID == topic.id {
            feed.snapshot.topicInfo = topic
            feed.snapshot.inbox = topic.inbox; feed.snapshot.outbox = topic.outbox
            for i in feed.snapshot.messages.indices where feed.snapshot.messages[i].outgoing && feed.snapshot.messages[i].messageID <= topic.outbox && feed.snapshot.messages[i].delivery == .sent {
                feed.snapshot.messages[i].delivery = .read
            }
            capabilities(feed)
        } else if feed.snapshot.isTopicList {
            feed.snapshot.topics.removeAll { $0.id == topic.id }
            feed.snapshot.topics.append(topic)
            feed.snapshot.topics.sort { $0.order == $1.order ? $0.id < $1.id : $0.order > $1.order }
        }
        feed.dirty = true
    }

    func loadTopics(_ feed: Feed, latest: Bool) {
        guard !feed.loading, feed.snapshot.capabilities.canRead, feed.snapshot.isTopicList else { return }
        let cursor = latest ? TopicCursor() : feed.topicCursor
        guard latest || feed.snapshot.hasOlder else { return }
        let generation = feed.historyGeneration
        let topicGeneration = feed.topicGeneration
        feed.loading = true; feed.snapshot.loading = true; feed.dirty = true
        feed.topicListInvalid = false; feed.topicListRefreshAt = now.addingTimeInterval(1)
        let sent = request("getForumTopics", ["chat_id": .integer(feed.snapshot.destination.chat), "query": .string(""),
            "offset_date": .integer(cursor.date), "offset_message_id": .integer(cursor.message),
            "offset_forum_topic_id": .integer(cursor.topic), "limit": .integer(Int64(feed.topicPageLimit))]) { [weak self, weak feed] result in
            guard let self, let feed else { return }
            feed.loading = false; feed.snapshot.loading = false; feed.dirty = true
            guard generation == feed.historyGeneration, feed.snapshot.isTopicList, feed.snapshot.capabilities.canRead else { return }
            feed.loaded = true
            guard result.type == "forumTopics" else {
                if result["message"]?.string == "page_too_large", feed.topicPageLimit > 1 {
                    feed.topicPageLimit = max(1, feed.topicPageLimit / 2); self.loadTopics(feed, latest: latest)
                } else { self.problem(feed, "Topics unavailable · Retry loading topics") }
                return
            }
            if latest { feed.snapshot.topics = []; feed.topicCursors = []; feed.snapshot.topicsWindowed = false }
            let topics = (result["topics"]?.array ?? []).prefix(100).compactMap { $0.object.flatMap { self.decodeTopic($0, feed: feed) } }
            // Keep a bounded window; the cursor still reaches every later page.
            let incoming = Set(topics.map(\.id))
            feed.snapshot.topics.removeAll { incoming.contains($0.id) }
            if feed.snapshot.topics.count + topics.count > 500 {
                feed.snapshot.topics = Array(feed.snapshot.topics.suffix(max(0, 500 - topics.count))); feed.snapshot.topicsWindowed = true
            }
            for topic in topics { self.applyTopic(topic, to: feed) }
            if topicGeneration != feed.topicGeneration { feed.invalidTopics.formUnion(topics.map(\.id)) }
            let next = TopicCursor(date: result["next_offset_date"]?.integer ?? 0, message: result["next_offset_message_id"]?.integer ?? 0,
                                   topic: result["next_offset_forum_topic_id"]?.integer ?? 0)
            feed.snapshot.error = nil
            feed.snapshot.hasOlder = next != TopicCursor() && next != cursor && !feed.topicCursors.contains(next)
            if next != TopicCursor(), !feed.snapshot.hasOlder { self.problem(feed, "Topic cursor did not advance · Reload topics") }
            feed.topicCursors.insert(cursor)
            // A bounded recent cursor ledger plus the current-cursor check.
            if feed.topicCursors.count > 64 { feed.topicCursors = [cursor] }
            feed.topicCursor = next
        }
        if !sent { feed.loading = false; feed.snapshot.loading = false; problem(feed, "Telegram is busy · Retry loading topics") }
    }

    func invalidateTopic(chat: Int64, topic: Int64?, update: TDLibMessage? = nil) {
        for feed in feeds(in: chat) where feed.snapshot.isTopicList || feed.snapshot.destination.topic?.forumID != nil {
            let known = Set(feed.snapshot.topics.map(\.id) + [feed.snapshot.destination.topic?.forumID].compactMap { $0 })
            if let topic, known.contains(topic) {
                feed.topicGeneration = UUID(); feed.topicVersions[topic, default: TopicVersion()].invalidate(update); feed.invalidTopics.insert(topic)
            } else if topic == nil {
                feed.topicGeneration = UUID(); feed.invalidTopics.formUnion(known)
                for id in known { feed.topicVersions[id, default: TopicVersion()].invalidate(nil) }
            } else if feed.snapshot.isTopicList {
                feed.topicGeneration = UUID(); feed.topicListInvalid = true
            }
        }
    }

    func refreshInvalidTopic(_ feed: Feed) {
        guard !feed.topicRefreshPending, !feed.validating, !feed.loading, now >= feed.topicRefreshAt,
              feed.snapshot.capabilities.canRead else { return }
        let pending = feed.invalidTopics.sorted()
        guard let id = pending.first(where: { $0 > feed.lastTopicRefresh }) ?? pending.first else { return }
        let generation = feed.topicVersions[id]?.generation
        feed.topicRefreshPending = true
        let sent = request("getForumTopic", ["chat_id": .integer(feed.snapshot.destination.chat), "forum_topic_id": .integer(id)]) { [weak self, weak feed] result in
            guard let self, let feed else { return }
            feed.topicRefreshPending = false; feed.topicRefreshAt = self.now.addingTimeInterval(1); feed.lastTopicRefresh = id
            guard generation == feed.topicVersions[id]?.generation || feed.topicVersions[id]?.isConsistent(with: result) == true else { return }
            feed.invalidTopics.remove(id)
            if let topic = self.decodeTopic(result, feed: feed), topic.id == id { self.applyTopic(topic, to: feed) }
            else {
                if feed.snapshot.destination.topic?.forumID == id { feed.snapshot.topicInfo = nil; self.capabilities(feed) }
                self.problem(feed, "Topic details unavailable · Reload to retry")
            }
        }
        if !sent { feed.topicRefreshPending = false }
    }

    func receiveTopic(_ update: TDLibMessage) {
        let info = update["info"]?.object
        guard let chat = info?["chat_id"]?.integer ?? update["chat_id"]?.integer,
              let id = info?["forum_topic_id"]?.integer ?? update["forum_topic_id"]?.integer else { return }
        for feed in feeds(in: chat) {
            if var topic = feed.snapshot.topicInfo ?? feed.snapshot.topics.first(where: { $0.id == id }), topic.id == id {
                if let info { topic.applyInfo(info) }
                else { topic.applyRead(update, chatMuted: inheritedMute(feed)) }
                applyTopic(topic, to: feed)
            }
        }
        invalidateTopic(chat: chat, topic: id, update: update)
    }

    func muteScope(_ feed: Feed) -> String {
        feed.chat?["type"]?.object?.type == "chatTypePrivate" ? "notificationSettingsScopePrivateChats" : "notificationSettingsScopeGroupChats"
    }
    func inheritedMute(_ feed: Feed) -> Bool? {
        guard let settings = feed.chat?["notification_settings"]?.object else { return nil }
        if settings["use_default_mute_for"]?.bool != false { return scopeMute[muteScope(feed)] }
        return (settings["mute_for"]?.integer ?? 0) > 0
    }
    func applyInheritedMute(_ feed: Feed) {
        let muted = inheritedMute(feed)
        for i in feed.snapshot.topics.indices where feed.snapshot.topics[i].inheritsMute {
            feed.snapshot.topics[i].muted = muted == true; feed.snapshot.topics[i].muteKnown = muted != nil
        }
        if feed.snapshot.topicInfo?.inheritsMute == true { feed.snapshot.topicInfo?.muted = muted == true; feed.snapshot.topicInfo?.muteKnown = muted != nil }
        feed.dirty = true
    }
    func refreshTopicMute(_ feed: Feed) {
        guard feed.snapshot.isTopicList || feed.snapshot.topicInfo != nil, inheritedMute(feed) == nil else { return }
        let scope = muteScope(feed)
        guard !scopeMuteAttempted.contains(scope) else { return }
        scopeMuteAttempted.insert(scope)
        if !request("getScopeNotificationSettings", ["scope": .typed(scope)], { [weak self] result in
            guard let self else { return }
            if result.type == "scopeNotificationSettings", self.scopeMute[scope] == nil {
                self.scopeMute[scope] = (result["mute_for"]?.integer ?? 0) > 0
                for feed in self.feeds.values where self.muteScope(feed) == scope { self.applyInheritedMute(feed) }
            }
        }) { scopeMuteAttempted.remove(scope) }
    }
}
