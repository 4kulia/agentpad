import Foundation

/// All methods run on LocalTDLibConnector's serial actor, including callbacks.
/// There is one reducer, no task per update, and newest-only UI subscriptions.
final class TelegramFeedSession {
    enum Sender: Hashable {
        case user(Int64), chat(Int64)
        init?(_ raw: TDLibMessage?) {
            if raw?.type == "messageSenderUser", let id = raw?["user_id"]?.integer { self = .user(id) }
            else if raw?.type == "messageSenderChat", let id = raw?["chat_id"]?.integer { self = .chat(id) }
            else { return nil }
        }
        var key: String { switch self { case .user(let id): "user:\(id)"; case .chat(let id): "chat:\(id)" } }
    }
    final class Feed {
        var snapshot: TelegramConversationSnapshot
        var observers: [UUID: AsyncStream<TelegramConversationSnapshot>.Continuation] = [:]
        var observations: [UUID: TelegramPresentationObservation] = [:]
        var chat: TDLibMessage?
        var peer: TDLibMessage?
        var fullInfo: TDLibMessage?
        var topicCursor = TopicCursor()
        var topicPageLimit = 50
        var topicCursors = Set<TopicCursor>()
        var topicGeneration = UUID()
        var topicVersions: [Int64: TopicVersion] = [:]
        var lastTopicRefresh: Int64 = 0
        var topicListInvalid = false
        var topicListRefreshAt = Date.distantPast
        var invalidTopics = Set<Int64>()
        var topicRefreshPending = false
        var topicRefreshAt = Date.distantPast
        var replyMarkupID: Int64 = 0
        var replyMarkupPending = false
        var replyMarkupGeneration = UUID()
        var botInfoPending = false
        var botInfoLoaded = false
        var dismissReplyMarkup: Int64?
        var dismissReplyMarkupInFlight = false
        var slowModeUntil = Date.distantPast
        var needsDetails = true
        var validating = false
        var historyCursor: Int64 = 0
        var requestedMessage: Int64?
        var pageLimit = 50
        var historyGeneration = UUID()
        var loading = false
        var loaded = false
        var opened = false
        var viewed = Set<Int64>()
        var viewPending = Set<Int64>()
        var aliases: [Int64: String] = [:]
        var failed: [Int64: (state: TDLibMessage, deadline: Date)] = [:]
        var expired = Set<Int64>()
        var expiry: [Int64: TimeInterval] = [:]
        var actions: [Sender: (String, TimeInterval)] = [:]
        var typing: [UUID: TimeInterval] = [:]
        var lastTyping: TimeInterval = -.infinity
        var typingSent = false
        var used = Date()
        var dirty = true
        init(_ snapshot: TelegramConversationSnapshot) { self.snapshot = snapshot }
    }
    struct Call {
        let method: String
        let service: Bool
        let localControl: Bool
        let started: Date
        let callback: (TDLibMessage) -> Void
        let timeout: (() -> Void)?
        var timedOut = false
    }
    let account: Int64
    let environment: TelegramEnvironment
    let epoch: UUID
    let journal: TelegramSendJournal
    let send: (TDLibMessage) throws -> Void
    var externalInteractive: () -> Int = { 0 }
    var nameLookup: (Int64) -> String? = { _ in nil }
    var chatNameLookup: (Int64) -> String? = { _ in nil }
    var feeds: [TelegramChatID: Feed] = [:]
    var openedChats = Set<Int64>()
    var scopeMute: [String: Bool] = [:]
    var scopeMuteAttempted = Set<String>()
    var calls: [String: Call] = [:]
    var network = TelegramNetworkState.waiting
    var active = false
    var stopped = false
    var online: Bool?
    var onlinePending = false
    var accountRetryAt: () -> Date = { .distantPast }
    var onFloodWait: (Date) -> Void = { _ in }
    private var localRetryAt = Date.distantPast
    var retryAt: Date {
        get { max(localRetryAt, accountRetryAt()) }
        set { localRetryAt = newValue }
    }
    var now = Date()
    var uptime: TimeInterval = 0
    var users: [Int64: TDLibMessage] = [:]
    var textLimit = 4096
    var captionLimit = 1024
    var serverOffset: TimeInterval = 0
    var downloads: [Int64: Int64] = [:] // file -> chat, explicit user requests only
    var sponsored: [Int64: SponsoredEntry] = [:]
    var sponsoredDownload: SponsoredDownload?
    var sponsoredDisk: TelegramSponsoredDiskCache?
    var sponsoredDeletions = Set<Int64>()
    var sponsoredDeleteRetryAt = Date.distantPast
    var sponsoredColors: [Int: (light: [UInt32], dark: [UInt32])] = [:]
    var filePaths: [Int64: String] = [:]
    var earlyOutcomes: [String: (TDLibMessage, TelegramSendJournal.Part.State)] = [:]
    var sending = Set<UUID>()
    var sendQueue: [SendWork] = []
    var preparingSend: SendWork?
    var retrying = Set<String>()
    var reconciled = Set<UUID>()
    var cacheOptions = Set<String>()
    var pendingCacheOptions = Set<String>()
    var cacheRetryAt = Date.distantPast
    var lastPublish = Date.distantPast
    var temporalDirty = true
    var nextTemporalDeadline = -Double.infinity
    private var wasLive = false
    var interactiveCount: Int { calls.values.filter { !$0.service && !$0.localControl }.count }

    init(account: Int64, environment: TelegramEnvironment, epoch: UUID, journal: TelegramSendJournal,
         send: @escaping (TDLibMessage) throws -> Void) {
        self.account = account; self.environment = environment; self.epoch = epoch; self.journal = journal; self.send = send
    }
    func matches(_ id: TelegramChatID, _ epoch: UUID) -> Bool {
        !stopped && id.account == account && id.environment == environment && self.epoch == epoch
    }
    func destination(chat: Int64, topic: TelegramMessageTopic? = nil) -> TelegramChatID {
        .init(environment: environment, account: account, chat: chat, topic: topic)
    }
    func feeds(in chat: Int64) -> [Feed] { feeds.values.filter { $0.snapshot.destination.chat == chat } }
    @discardableResult func request(_ type: String, _ fields: [String: TDLibValue] = [:], service: Bool = false) -> Bool {
        request(type, fields, service: service) { _ in }
    }
    @discardableResult func request(_ type: String, _ fields: [String: TDLibValue] = [:], service: Bool = false, localControl: Bool = false, onTimeout: (() -> Void)? = nil,
                                    whileValid: () -> Bool = { true },
                                    _ callback: @escaping (TDLibMessage) -> Void) -> Bool {
        guard !stopped, localControl || now >= retryAt else { return false }
        if localControl { guard ["cancelDownloadFile", "deleteFile"].contains(type), !calls.values.contains(where: { $0.localControl && $0.method == type }) else { return false } }
        else if service { guard !calls.values.contains(where: \.service) else { return false } }
        else { guard interactiveCount + externalInteractive() < 6 else { return false } }
        let token = (["getChatHistory", "getForumTopicHistory", "getForumTopics"].contains(type) ? "feed:history:" : "feed:rpc:") + UUID().uuidString
        var message = TDLibMessage(type, fields); message["@extra"] = .string(token)
        guard whileValid() else { return false }
        calls[token] = Call(method: type, service: service, localControl: localControl, started: now, callback: callback, timeout: onTimeout)
        do { try send(message) }
        catch { calls[token] = nil; callback(TDLibMessage("error", ["message": .string("transport_unknown")])) }
        return true
    }
    func subscribe(_ id: TelegramChatID, pane: UUID) -> AsyncStream<TelegramConversationSnapshot> {
        let pair = AsyncStream<TelegramConversationSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard matches(id, epoch) else { pair.continuation.finish(); return pair.stream }
        let feed: Feed
        if let existing = feeds[id] { feed = existing }
        else {
            var value = TelegramConversationSnapshot(destination: id, epoch: epoch)
            guard feeds.count < 64 else {
                value.error = "Close another Telegram conversation, then reopen this one."
                pair.continuation.yield(value); pair.continuation.finish(); return pair.stream
            }
            do { if id.topic == nil || id.topic?.forumID != nil { value.draft = try journal.draft(chat: id.chat, topic: id.topic) } }
            catch { value.error = TelegramConversationError.storage.rawValue }
            feed = Feed(value); feeds[id] = feed
        }
        feed.observers[pane] = pair.continuation; feed.used = now
        pair.continuation.yield(feed.snapshot)
        return pair.stream
    }
    func release(_ id: TelegramChatID, pane: UUID) {
        guard let feed = feeds[id] else { return }
        feed.observers.removeValue(forKey: pane)?.finish()
        feed.observations[pane] = nil; feed.typing[pane] = nil
        if feed.observers.isEmpty {
            feed.snapshot.messages = []; feed.loaded = false; feed.historyCursor = 0
            feed.historyGeneration = UUID(); feed.aliases = [:]; feed.failed = [:]
        }
        reconcilePresentation(feed)
        reconcileSponsored()
    }
    func stop() {
        stopped = true
        let waiting = Array(calls.values); calls = [:]
        for call in waiting { call.callback(TDLibMessage("error", ["message": .string("transport_unknown")])) }
        sendQueue = []; preparingSend = nil; sending = []
        for feed in feeds.values {
            var value = TelegramConversationSnapshot(destination: feed.snapshot.destination, epoch: UUID())
            value.error = "Connect this Telegram account to open this conversation."
            for observer in feed.observers.values { observer.yield(value); observer.finish() }
        }
        feeds = [:]; openedChats = []; calls = [:]; users = [:]; downloads = [:]; filePaths = [:]
        sponsored = [:]; sponsoredDownload = nil; sponsoredDeletions = []; sponsoredDisk?.clear(); sponsoredDisk = nil
    }
    func tick(now: Date, uptime: TimeInterval) {
        self.now = now; self.uptime = uptime
        guard !stopped else { return }
        drainSendQueue()
        configureCache()
        for (token, call) in calls where !call.timedOut && now.timeIntervalSince(call.started) >= 40 {
            calls[token]?.timedOut = true; call.timeout?()
            // A timeout never frees an RPC slot or replays a send. The eventual
            // TDLib reply still owns this correlation and can settle unknown.
        }
        let live = active && network == .ready
        if live != wasLive { temporalDirty = true; wasLive = live }
        let checkTime = temporalDirty || uptime >= nextTemporalDeadline
        if checkTime { temporalDirty = false; nextTemporalDeadline = .infinity }
        if online != active && !onlinePending {
            let desired = active
            onlinePending = request("setOption", ["name": .string("online"), "value": .typed("optionValueBoolean", ["value": .bool(desired)])], service: true) { [weak self] response in
                guard let self else { return }; self.onlinePending = false
                if response.type == "ok" { self.online = desired }
            }
        }
        for feed in feeds.values.sorted(by: { $0.used > $1.used }) {
            if feed.snapshot.connected != (network == .ready) { feed.snapshot.connected = network == .ready; feed.dirty = true }
            if checkTime {
                if !live { feed.actions = [:]; feed.typing = [:] }
                feed.actions = feed.actions.filter { uptime < $0.value.1 }
                feed.typing = feed.typing.filter { uptime < $0.value }
                for (id, deadline) in feed.expiry where uptime >= deadline { erase(feed, id: id) }
                refreshRetryStates(feed)
                // One nearest deadline for the account, driven by the existing
                // receive heartbeat. No timers/polling tasks on message rows.
                let deadlines = Array(feed.expiry.values) + feed.actions.values.map { $0.1 } + Array(feed.typing.values)
                    + feed.failed.values.filter { $0.deadline > now }.map { uptime + $0.deadline.timeIntervalSince(now) }
                nextTemporalDeadline = min(nextTemporalDeadline, deadlines.min() ?? .infinity)
                if let user = feed.chat?["type"]?.object?["user_id"]?.integer,
                   let status = users[user]?["status"]?.object, status.type == "userStatusOnline",
                   let expires = status["expires"]?.integer {
                    let remaining = Double(expires) - now.timeIntervalSince1970 - serverOffset
                    if remaining > 0 { nextTemporalDeadline = min(nextTemporalDeadline, uptime + remaining) }
                }
                let status = presence(feed, live: live)
                if feed.snapshot.presence != status { feed.snapshot.presence = status; feed.dirty = true }
            }
            if !feed.observers.isEmpty {
                if feed.needsDetails && !feed.validating { refresh(feed) }
                if let message = feed.requestedMessage, !feed.loading, feed.snapshot.capabilities.canRead { loadAround(feed, message: message) }
                if !feed.loaded && !feed.loading && feed.snapshot.capabilities.canRead { load(feed, latest: true) }
                if feed.topicListInvalid, feed.loaded, !feed.loading, now >= feed.topicListRefreshAt { loadTopics(feed, latest: true) }
                refreshInvalidTopic(feed)
                refreshTopicMute(feed)
                refreshBotDetails(feed)
                if feed.snapshot.capabilities.canRead && !feed.validating { reconcileOutbox(feed) }
            }
            reconcilePresentation(feed)
            reconcileTyping(feed)
        }
        // Hidden, unsubscribed destinations retain only encrypted disk drafts.
        for (id, feed) in feeds where feed.observers.isEmpty && !feed.opened && !feed.typingSent && !feed.validating && !feed.loading {
            let sending = journal.operations.contains { operation in
                operation.chat == id.chat && operation.topic == id.topic && (operation.parts.contains { [.submitting, .pending].contains($0.state) || self.sending.contains($0.key) }
                    || sendQueue.contains { $0.operation == operation.id } || preparingSend?.operation == operation.id)
            }
            if !sending && !openedChats.contains(id.chat) { feeds[id] = nil }
        }
        reconcileSponsored()
        boundMemory()
        if now.timeIntervalSince(lastPublish) >= 0.05 { publish() }
    }
    func publish() {
        lastPublish = now
        for feed in feeds.values where feed.dirty {
            feed.snapshot.textLimit = textLimit; feed.snapshot.captionLimit = captionLimit
            feed.snapshot.cacheLimitMiB = journal.cacheLimitMiB
            feed.snapshot.unavailableMessageIDs = feed.expired
            feed.snapshot.consumedDraftRevisions = Set(journal.operations.filter { $0.chat == feed.snapshot.destination.chat && $0.topic == feed.snapshot.destination.topic }.suffix(10).map(\.revision))
            feed.snapshot.operations = journal.operations.filter { $0.chat == feed.snapshot.destination.chat && $0.topic == feed.snapshot.destination.topic && journal.recovered($0.id) != nil && !$0.parts.allSatisfy { $0.state == .sent } }.suffix(10).map {
                TelegramSendOperation(id: $0.id, states: $0.parts.map { $0.state.rawValue }, canRecover: $0.parts.contains { $0.state.canRestore })
            }
            feed.dirty = false; feed.snapshot.revision &+= 1
            for observer in feed.observers.values { observer.yield(feed.snapshot) }
        }
    }
    func problem(_ feed: Feed, _ text: String) { feed.snapshot.error = text; feed.dirty = true }
    func refresh(_ feed: Feed, completion: ((Bool) -> Void)? = nil) {
        guard !feed.validating else { completion?(false); return }
        let chat = feed.snapshot.destination.chat
        feed.validating = true
        let sent = request("getChat", ["chat_id": .integer(chat)]) { [weak self, weak feed] response in
            guard let self, let feed else { return }
            guard response.type == "chat" else {
                feed.validating = false; feed.needsDetails = false
                feed.snapshot.capabilities = .init(); feed.snapshot.capabilities.reason = "Chat unavailable · Open in Telegram"
                self.problem(feed, "Chat details could not be loaded. Retry when connected."); completion?(false); return
            }
            self.applyChat(response, to: feed)
            let type = response["type"]?.object
            let peerID = type?[type?.type == "chatTypePrivate" ? "user_id" : type?.type == "chatTypeBasicGroup" ? "basic_group_id" : "supergroup_id"]?.integer
            let method = type?.type == "chatTypePrivate" ? "getUser" : type?.type == "chatTypeBasicGroup" ? "getBasicGroup" : "getSupergroup"
            let field = type?.type == "chatTypePrivate" ? "user_id" : type?.type == "chatTypeBasicGroup" ? "basic_group_id" : "supergroup_id"
            guard let peerID, ["chatTypePrivate", "chatTypeBasicGroup", "chatTypeSupergroup"].contains(type?.type ?? "") else {
                feed.validating = false; feed.needsDetails = false; self.capabilities(feed); completion?(false); return
            }
            guard self.request(method, [field: .integer(peerID)], { [weak self, weak feed] peer in
                guard let self, let feed else { return }
                feed.peer = peer.type == "error" ? nil : peer
                if peer.type == "user" { self.rememberUser(peer) }
                if method == "getSupergroup", peer.type == "supergroup" {
                    guard self.request("getSupergroupFullInfo", ["supergroup_id": .integer(peerID)], { [weak self, weak feed] full in
                        guard let self, let feed else { return }
                        feed.fullInfo = full.type == "supergroupFullInfo" ? full : nil
                        feed.slowModeUntil = self.now.addingTimeInterval(max(0, full["slow_mode_delay_expires_in"]?.number ?? 0))
                        self.finishDetails(feed, completion: completion)
                    }) else { feed.validating = false; completion?(false); return }
                } else {
                    self.finishDetails(feed, completion: completion)
                }
            }) else { feed.validating = false; completion?(false); return }
        }
        if !sent { feed.validating = false; completion?(false) }
    }
    func applyChat(_ raw: TDLibMessage, to feed: Feed) {
        // Avoid retaining full last-message/preview trees in a second cache.
        feed.chat = TDLibMessage(raw.fields.filter { ["id", "type", "permissions", "message_sender_id", "has_protected_content", "notification_settings", "reply_markup_message_id"].contains($0.key) })
        feed.snapshot.title = raw["title"]?.string ?? "Telegram"
        let markup = raw["reply_markup_message_id"]?.integer ?? 0
        if feed.replyMarkupID != markup {
            feed.replyMarkupID = markup; feed.replyMarkupGeneration = UUID()
            feed.snapshot.replyKeyboard = nil; feed.snapshot.keyboardHidden = false
        }
        if feed.snapshot.destination.topic == nil {
            feed.snapshot.inbox = raw["last_read_inbox_message_id"]?.integer ?? 0
            feed.snapshot.outbox = raw["last_read_outbox_message_id"]?.integer ?? 0
        }
        feed.dirty = true
    }
    func capabilities(_ feed: Feed) {
        var value = TelegramConversationCapabilities()
        let type = feed.chat?["type"]?.object, peer = feed.peer
        let isPrivate = type?.type == "chatTypePrivate"
        var kind: TelegramChatKind = .unknown
        if isPrivate {
            kind = peer?["type"]?.object?.type == "userTypeBot" ? .bot
                : peer?["id"]?.integer == account ? .savedMessages : peer?["type"]?.object?.type == "userTypeRegular" ? .person : .unknown
        } else if type?.type == "chatTypeBasicGroup" { kind = .group }
        else if type?.type == "chatTypeSecret" { kind = .secret }
        else if type?.type == "chatTypeSupergroup", let peer {
            kind = peer["is_direct_messages_group"]?.bool == true ? .channelDirect
                : type?["is_channel"]?.bool == true || peer["is_channel"]?.bool == true ? .channel
                : peer["is_forum"]?.bool == true ? .forum : .supergroup
        }
        let hasTopics = kind == .forum || (kind == .bot && peer?["type"]?.object?["has_topics"]?.bool == true)
        let topicID = feed.snapshot.destination.topic?.forumID
        let list = hasTopics && feed.snapshot.destination.topic == nil
        if feed.snapshot.isTopicList != list {
            feed.loaded = false; feed.historyGeneration = UUID(); feed.snapshot.messages = []
        }
        if feed.snapshot.kind != kind {
            feed.snapshot.bot = .init(); feed.botInfoLoaded = false
        }
        feed.snapshot.kind = kind; feed.snapshot.isTopicList = list
        feed.snapshot.username = (peer?["usernames"]?.object?["active_usernames"]?.array ?? []).compactMap(\.string)
            .first(where: { TelegramInlineQuery.username(in: "@" + $0 + " ") != nil }) ?? ""
        if kind == .channel, feed.snapshot.destination.topic == nil {
            let status = peer?["status"]?.object
            value.canRead = ["chatMemberStatusAdministrator", "chatMemberStatusMember"].contains(status?.type ?? "")
                || (status?.type == "chatMemberStatusCreator" && status?["is_member"]?.bool == true)
            value.reason = value.canRead ? "Read-only in AgentPad · Open in Telegram to post" : "Subscribe to this channel in Telegram to read it here"
            feed.snapshot.capabilities = value
            feed.snapshot.draft = .init(); feed.typing = [:]; feed.actions = [:]
            if !value.canRead {
                feed.snapshot.messages = []; feed.loaded = false
                feed.historyGeneration = UUID()
                sponsored[feed.snapshot.destination.chat] = nil; feed.snapshot.sponsored = .init()
            }
            feed.dirty = true; return
        }
        // Saved Messages is the same cloud private-chat path, with no bot UI.
        guard [.person, .savedMessages, .group, .supergroup, .forum, .bot].contains(kind), let peer,
              feed.snapshot.destination.topic == nil || (hasTopics && topicID != nil) else {
            value.reason = kind == .secret ? "Not available on this Mac" : "Open this chat in Telegram"
            feed.snapshot.capabilities = value
            feed.snapshot.sponsored = .init()
            feed.snapshot.messages = []; feed.dirty = true; return
        }
        let status = peer["status"]?.object
        let member = isPrivate ? peer["have_access"]?.bool == true : ["chatMemberStatusAdministrator", "chatMemberStatusMember"].contains(status?.type ?? "") || (["chatMemberStatusCreator", "chatMemberStatusRestricted"].contains(status?.type ?? "") && status?["is_member"]?.bool == true)
        value.canRead = member && (topicID == nil || feed.snapshot.topicInfo != nil)
        let senderValue = feed.chat?["message_sender_id"], sender = senderValue?.object
        // TDLib's JSON serializer omits null objects. No selected send-as
        // identity means the account owner in every supported chat type;
        // membership and permissions below still determine whether sending is allowed.
        let owner = senderValue == nil || senderValue == .null
            || (sender?.type == "messageSenderUser" && sender?["user_id"]?.integer == account)
        value.sender = owner ? (users[account].map(userName) ?? "You") : "Sender unavailable"
        let paid = (peer["paid_message_star_count"]?.integer ?? 0) > 0 || (feed.fullInfo?["outgoing_paid_message_star_count"]?.integer ?? 0) > 0
        let anonymous = status?["is_anonymous"]?.bool == true || status?["rights"]?.object?["is_anonymous"]?.bool == true
        let infoKnown = ![.supergroup, .forum].contains(kind) || feed.fullInfo != nil
        let topic = feed.snapshot.topicInfo
        let canManageTopics = status?.type == "chatMemberStatusCreator" || status?["rights"]?.object?["can_manage_topics"]?.bool == true
        let topicAllowed = !list && (!hasTopics || (topic != nil && (!(topic!.isClosed || topic!.isHidden) || topic!.isOwned || canManageTopics)))
        let allowed = member && owner && !paid && !anonymous && infoKnown && topicAllowed && (kind != .group || peer["is_active"]?.bool == true)
        let permissions = feed.chat?["permissions"]?.object
        let restricted = status?.type == "chatMemberStatusRestricted" ? status?["permissions"]?.object : nil
        let admin = ["chatMemberStatusCreator", "chatMemberStatusAdministrator"].contains(status?.type ?? "")
        func permission(_ name: String) -> Bool { isPrivate || admin || (permissions?[name]?.bool == true && (restricted == nil || restricted?[name]?.bool == true)) }
        value.canSend = allowed && permission("can_send_basic_messages")
        value.canSendPhotos = allowed && permission("can_send_photos")
        value.canSendDocuments = allowed && permission("can_send_documents")
        value.reason = !member ? "You no longer have access to this chat" : !owner || anonymous ? "Sending as another identity is available in Telegram"
            : paid ? "Paid messages are available in Telegram" : !infoKnown ? "Waiting for chat permissions"
            : list ? "Choose a topic to read or send a message" : !topicAllowed ? "This topic is closed or unavailable · Read-only"
            : !value.canSend ? "Sending is restricted in this chat" : ""
        feed.snapshot.capabilities = value
        if !member { feed.snapshot.messages = []; feed.actions = [:] }
        feed.dirty = true
    }
    func load(_ feed: Feed, latest: Bool) {
        if feed.snapshot.isTopicList { loadTopics(feed, latest: latest); return }
        guard !feed.loading, feed.snapshot.capabilities.canRead else { return }
        let cursor = latest ? 0 : feed.historyCursor
        let generation = feed.historyGeneration
        feed.loading = true; feed.snapshot.loading = true; feed.dirty = true
        var fields: [String: TDLibValue] = ["chat_id": .integer(feed.snapshot.destination.chat), "from_message_id": .integer(cursor),
            "offset": .integer(0), "limit": .integer(Int64(feed.pageLimit))]
        let topicID = feed.snapshot.destination.topic?.forumID
        if let topicID { fields["forum_topic_id"] = .integer(topicID) } else { fields["only_local"] = .bool(false) }
        let started = request(topicID == nil ? "getChatHistory" : "getForumTopicHistory", fields) { [weak self, weak feed] result in
            guard let self, let feed else { return }
            feed.loading = false; feed.snapshot.loading = false; feed.dirty = true
            guard generation == feed.historyGeneration, !feed.observers.isEmpty, feed.snapshot.capabilities.canRead else { return }
            if result.type == "error" {
                if result["message"]?.string == "page_too_large", feed.pageLimit > 1 { feed.pageLimit = max(1, feed.pageLimit / 2); self.load(feed, latest: latest) }
                else { feed.loaded = true; self.problem(feed, "History unavailable · Retry loading messages") }
                return
            }
            guard result.type == "messages" else { self.problem(feed, "History unavailable · Retry loading messages"); feed.loaded = true; return }
            let values = Array((result["messages"]?.array ?? []).prefix(100))
            if latest { feed.snapshot.messages = []; feed.snapshot.hasNewer = false }
            let before = Set(feed.snapshot.messages.map(\.messageID))
            for value in values { if let raw = value.object { self.merge(raw, into: feed) } }
            feed.loaded = true; feed.snapshot.error = nil
            // TDLib may return a short page. Only an empty page ends history.
            if values.isEmpty { feed.snapshot.hasOlder = false }
            else if let minimum = values.compactMap({ $0.object?["id"]?.integer }).min(), minimum != cursor {
                feed.historyCursor = minimum; feed.snapshot.hasOlder = true
            } else if !latest {
                self.problem(feed, "History cursor did not advance · Retry loading messages")
            }
            let added = feed.snapshot.messages.filter { !before.contains($0.messageID) }.reduce(0) { $0 + $1.storageBytes }
            if added > 1024 * 1024 { feed.pageLimit = max(1, feed.pageLimit / 2) }
            self.trim(feed, keepOlder: !latest)
        }
        if !started { feed.loading = false; feed.snapshot.loading = false; problem(feed, "Telegram is busy · Retry loading messages") }
    }

    func loadAround(_ feed: Feed, message: Int64) {
        let generation = UUID(); feed.historyGeneration = generation
        let topic = feed.snapshot.destination.topic?.forumID
        var fields: [String: TDLibValue] = ["chat_id": .integer(feed.snapshot.destination.chat), "from_message_id": .integer(message),
            "offset": .integer(-25), "limit": .integer(50)]
        if let topic { fields["forum_topic_id"] = .integer(topic) } else { fields["only_local"] = .bool(false) }
        feed.loading = true; feed.snapshot.loading = true; feed.dirty = true
        let started = request(topic == nil ? "getChatHistory" : "getForumTopicHistory", fields) { [weak self, weak feed] result in
            guard let self, let feed, feed.historyGeneration == generation else { return }
            feed.loading = false; feed.snapshot.loading = false; feed.dirty = true
            guard result.type == "messages" else { self.problem(feed, "Unread message unavailable · Retry loading messages"); return }
            feed.snapshot.messages = []
            for value in (result["messages"]?.array ?? []).prefix(100) {
                if let raw = value.object { self.merge(raw, into: feed) }
            }
            feed.loaded = true; feed.snapshot.hasNewer = true; feed.snapshot.hasOlder = true
            feed.historyCursor = feed.snapshot.messages.first?.messageID ?? message
            self.trim(feed, keepOlder: false); feed.dirty = true
        }
        if started { feed.requestedMessage = nil }
        else { feed.loading = false; feed.snapshot.loading = false }
    }
    func merge(_ raw: TDLibMessage, into feed: Feed, outcome: TelegramMessage.Delivery? = nil) {
        guard feed.snapshot.capabilities.canRead, raw["chat_id"]?.integer == feed.snapshot.destination.chat,
              let messageID = raw["id"]?.integer, !feed.expired.contains(messageID),
              acceptsTopic(raw["topic_id"], feed: feed), !feed.snapshot.isTopicList else { return }
        let sender = Sender(raw["sender_id"]?.object)
        let key = feed.aliases[messageID] ?? journal.operations.lazy.filter { $0.chat == feed.snapshot.destination.chat && $0.topic == feed.snapshot.destination.topic }
            .flatMap(\.parts).first { $0.messageID == messageID }?.key.uuidString
        guard var row = TelegramMessageDecoder.decode(raw, now: now, author: sender.map(senderName) ?? "Telegram", key: key) else { return }
        if let old = feed.snapshot.messages.first(where: { $0.messageID == messageID }) {
            row.id = old.id
            if old.text == row.text, old.edited == row.edited { row.inlineKeyboard = row.inlineKeyboard?.keepingRevision(of: old.inlineKeyboard) }
            if let expiry = old.expiresAt { row.expiresAt = min(expiry, row.expiresAt ?? expiry) }
        }
        if let expires = row.expiresAt {
            feed.expiry[messageID] = min(feed.expiry[messageID] ?? .infinity, uptime + max(0, expires.timeIntervalSince(now)))
            temporalDirty = true
        }
        if let outcome { row.delivery = outcome }
        if row.outgoing && row.delivery == .sent && row.messageID <= feed.snapshot.outbox { row.delivery = .read }
        if feed.chat?["has_protected_content"]?.bool == true { row.protectedContent = true }
        if !row.protectedContent, let file = row.attachment, file.complete, let content = raw["content"]?.object {
            let fileValue = content.type == "messageDocument" ? content["document"]?.object?["document"]?.object
                : content["photo"]?.object?["sizes"]?.array.last?.object?["photo"]?.object
            if let path = fileValue?["local"]?.object?["path"]?.string { filePaths[file.id] = path }
        }
        if row.content == .service && row.text.isEmpty { row.text = "Telegram service event" }
        if let failed = raw["sending_state"]?.object, failed.type == "messageSendingStateFailed" {
            feed.failed[messageID] = (failed, feed.failed[messageID]?.deadline ?? now.addingTimeInterval(max(0, failed["retry_after"]?.number ?? 0)))
        }
        feed.snapshot.messages.removeAll { $0.id == row.id || $0.messageID == row.messageID }
        feed.snapshot.messages.append(row)
        feed.snapshot.messages.sort { $0.messageID < $1.messageID }
        resolveReplies(feed); feed.dirty = true
        refreshRetryStates(feed)
    }
    func resolveReplies(_ feed: Feed) {
        let rows = Dictionary(uniqueKeysWithValues: feed.snapshot.messages.map { ($0.messageID, $0) })
        for i in feed.snapshot.messages.indices {
            guard let reply = feed.snapshot.messages[i].replyTo else { continue }
            let target = rows[reply]
            feed.snapshot.messages[i].replyPreview = feed.expired.contains(reply) || target?.content == .deleted ? "Message unavailable"
                : target?.protectedContent == true ? "Protected message" : target.map { String($0.text.prefix(160)) } ?? "Reply to message · not loaded"
        }
    }
    func erase(_ feed: Feed, id: Int64) {
        feed.expiry[id] = nil
        feed.expired.insert(id)
        if feed.expired.count > 2000 { feed.expired = Set(feed.expired.sorted().suffix(2000)) }
        feed.snapshot.messages.removeAll { $0.messageID == id }
        if feed.snapshot.replyKeyboard?.messageID == id { feed.snapshot.replyKeyboard = nil; feed.replyMarkupID = 0; feed.replyMarkupGeneration = UUID() }
        if feed.snapshot.draft.replyTo == id {
            feed.snapshot.draft.replyTo = nil; feed.snapshot.draft.revision = UUID()
            try? journal.saveDraft(feed.snapshot.draft, chat: feed.snapshot.destination.chat, topic: feed.snapshot.destination.topic)
            problem(feed, "The reply target expired or was deleted. Review the draft before sending.")
        }
        resolveReplies(feed); feed.dirty = true
    }
    func trim(_ feed: Feed, keepOlder: Bool) {
        var lastEvicted: Int64?
        while feed.snapshot.messages.count > TelegramFeedLimits.paneMessages || feed.snapshot.messages.reduce(0, { $0 + $1.storageBytes }) > 4 * 1024 * 1024 {
            if keepOlder { feed.snapshot.messages.removeLast(); feed.snapshot.hasNewer = true }
            else { lastEvicted = feed.snapshot.messages.removeFirst().messageID }
        }
        if let lastEvicted { evictedOldest(feed, lastRemoved: lastEvicted) }
        pruneWindow(feed)
    }
    private func evictedOldest(_ feed: Feed, lastRemoved: Int64) {
        // Pagination must meet the retained window, not the old page boundary.
        // If the entire window was evicted, reload around its newest position.
        feed.historyCursor = feed.snapshot.messages.first?.messageID ?? lastRemoved
        feed.snapshot.hasOlder = true
        if feed.snapshot.messages.isEmpty { feed.snapshot.hasNewer = true }
        // An in-flight page from the previous boundary would leave a hole too.
        feed.historyGeneration = UUID()
        feed.dirty = true
    }
    private func pruneWindow(_ feed: Feed) {
        let ids = Set(feed.snapshot.messages.map(\.messageID))
        feed.aliases = feed.aliases.filter { ids.contains($0.key) }
        feed.failed = feed.failed.filter { ids.contains($0.key) }
        feed.expiry = feed.expiry.filter { ids.contains($0.key) || feed.snapshot.draft.replyTo == $0.key || feed.replyMarkupID == $0.key }
        feed.viewed.formIntersection(ids)
    }
    func boundMemory() {
        for feed in feeds.values { trim(feed, keepOlder: feed.snapshot.hasNewer) }
        var topicBudget = 2000
        for feed in feeds.values.sorted(by: { $0.used > $1.used }) {
            if feed.snapshot.topics.count > topicBudget {
                feed.snapshot.topics = Array(feed.snapshot.topics.prefix(topicBudget)); feed.snapshot.topicsWindowed = true; feed.dirty = true
            }
            topicBudget -= feed.snapshot.topics.count
            let retainedTopics = Set(feed.snapshot.topics.map(\.id) + [feed.snapshot.destination.topic?.forumID].compactMap { $0 })
            feed.invalidTopics.formIntersection(retainedTopics)
            feed.topicVersions = feed.topicVersions.filter { retainedTopics.contains($0.key) }
        }
        var count = feeds.values.reduce(0) { $0 + $1.snapshot.messages.count }
        var bytes = feeds.values.reduce(0) { $0 + $1.snapshot.messages.reduce(0) { $0 + $1.storageBytes } }
        for feed in feeds.values.sorted(by: { $0.used < $1.used }) {
            var lastEvicted: Int64?
            while !feed.snapshot.messages.isEmpty && (count > TelegramFeedLimits.totalMessages || bytes > TelegramFeedLimits.textBytes) {
                let row = feed.snapshot.messages.removeFirst(); count -= 1; bytes -= row.storageBytes
                lastEvicted = row.messageID
            }
            if let lastEvicted { evictedOldest(feed, lastRemoved: lastEvicted); pruneWindow(feed) }
        }
    }
    func rememberUser(_ user: TDLibMessage) {
        guard let id = user["id"]?.integer else { return }
        users[id] = TDLibMessage(user.fields.filter { ["id", "first_name", "last_name", "status", "type", "usernames", "have_access"].contains($0.key) })
        if users.count > 512 { for key in users.keys.sorted() where key != account && users.count > 512 { users[key] = nil } }
    }
    func userName(_ user: TDLibMessage) -> String {
        [user["first_name"]?.string, user["last_name"]?.string].compactMap { $0 }.joined(separator: " ")
    }
    func senderName(_ sender: Sender) -> String {
        switch sender {
        case .user(let id): users[id].map(userName) ?? nameLookup(id) ?? (id == account ? "You" : "User \(id)")
        case .chat(let id): feeds[destination(chat: id)]?.snapshot.title ?? chatNameLookup(id) ?? "Chat \(id)"
        }
    }
}
