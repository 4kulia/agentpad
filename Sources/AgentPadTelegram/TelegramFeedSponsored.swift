import Foundation

extension TelegramFeedSession {
    final class SponsoredEntry {
        var snapshot = TelegramSponsoredSnapshot()
        var inFlight = false
        var used = Date.distantPast
        var wasShown = false
        var bytes = 0
        var files: [Int64: TDLibMessage] = [:]
        var viewed = Set<Int64>()
        var pendingViews = Set<Int64>()
        var visible = Set<Int64>()
        var failedViews: [Int64: (attempts: Int, retryAt: Date)] = [:]
        var viewRetries = Set<Int64>()
        var reportOptions: [Int64: (step: UUID, options: [TelegramSponsoredReportOption])] = [:]
        var pendingReports = Set<Int64>()
        var pendingClicks = Set<Int64>()
        var backgroundPending = Set<Int64>()
        var failures = 0
    }

    func sponsoredEntry(_ chat: Int64) -> SponsoredEntry? {
        if let entry = sponsored[chat] { return entry }
        if sponsored.count >= 64, let oldest = sponsored.filter({ !$0.value.inFlight && !sponsoredShown($0.key) }).min(by: { $0.value.used < $1.value.used }) {
            sponsored[oldest.key] = nil
        }
        guard sponsored.count < 64 else { return nil }
        let entry = SponsoredEntry(); sponsored[chat] = entry; return entry
    }
    func publishSponsored(_ chat: Int64) {
        for feed in feeds(in: chat) {
            let value = feed.snapshot.kind == .channel && feed.snapshot.capabilities.canRead ? sponsored[chat]?.snapshot ?? .init() : .init()
            if value != feed.snapshot.sponsored { feed.snapshot.sponsored = value; feed.dirty = true }
        }
    }
    func sponsoredShown(_ chat: Int64) -> Bool {
        active && feeds(in: chat).contains { $0.snapshot.kind == .channel && $0.snapshot.capabilities.canRead && $0.observations.values.contains { $0.shown } }
    }
    func reconcileSponsored() {
        guard !stopped else { return }
        for feed in feeds.values where feed.snapshot.kind == .channel && feed.snapshot.capabilities.canRead {
            guard let entry = sponsoredEntry(feed.snapshot.destination.chat) else { continue }
            let chat = feed.snapshot.destination.chat, shown = sponsoredShown(chat)
            let opened = shown && !entry.wasShown
            entry.wasShown = shown
            if entry.snapshot.state == .error {
                let deadline = max(entry.snapshot.retryNotBefore, retryAt)
                entry.snapshot.retryNotBefore = now >= deadline ? .distantPast : deadline
            }
            if shown {
                entry.used = now
                let expired = entry.snapshot.expiresAt.map { now >= $0 } ?? false
                if expired || entry.snapshot.state == .idle || (opened && entry.snapshot.state == .error) { fetchSponsored(chat, entry: entry) }
                reconcileSponsoredViews(chat, entry: entry)
            }
            publishSponsored(chat)
        }
        for (chat, entry) in sponsored where !sponsoredShown(chat) {
            entry.wasShown = false; entry.visible = []
            if !entry.inFlight, now.timeIntervalSince(entry.used) >= 300 { sponsored[chat] = nil; publishSponsored(chat) }
        }
        // Evict closed results first, without silently truncating an ad or its media.
        var bytes = sponsored.values.reduce(0) { $0 + $1.bytes }
        for (chat, entry) in sponsored.sorted(by: { $0.value.used < $1.value.used }) where bytes > TelegramSponsoredLimits.accountBytes {
            if !sponsoredShown(chat), !entry.inFlight { sponsored[chat] = nil; bytes -= entry.bytes; publishSponsored(chat) }
        }
        reconcileSponsoredDownloads()
    }
    func fetchSponsored(_ chat: Int64, entry: SponsoredEntry) {
        guard !entry.inFlight, sponsoredShown(chat), network == .ready, now >= entry.snapshot.retryNotBefore, now >= retryAt else {
            if !entry.inFlight, sponsoredShown(chat), network != .ready, entry.snapshot.state == .idle { sponsoredFailure(entry) }
            if entry.snapshot.expiresAt.map({ now >= $0 }) == true {
                entry.snapshot.state = .error; entry.snapshot.messages = []; entry.snapshot.error = "Ad unavailable · Retry"
                entry.snapshot.retryNotBefore = max(entry.snapshot.retryNotBefore, retryAt)
            }
            return
        }
        let generation = UUID()
        entry.snapshot = .init(); entry.snapshot.result = generation; entry.snapshot.state = .loading
        entry.viewed = []; entry.pendingViews = []; entry.visible = []; entry.failedViews = [:]; entry.viewRetries = []
        entry.reportOptions = [:]; entry.pendingReports = []; entry.pendingClicks = []; entry.files = [:]; entry.backgroundPending = []
        entry.inFlight = true
        let sent = request("getChatSponsoredMessages", ["chat_id": .integer(chat)], onTimeout: { [weak self, weak entry] in
            guard let self, let entry, entry.snapshot.result == generation else { return }
            self.sponsoredFailure(entry); self.publishSponsored(chat)
        }) { [weak self, weak entry] response in
            guard let self, let entry, !self.stopped, self.sponsored[chat] === entry, entry.snapshot.result == generation else { return }
            entry.inFlight = false
            guard response.type == "sponsoredMessages", let values = response["messages"]?.array,
                  let spacing = response["messages_between"]?.integer, spacing >= 0, spacing <= Int32.max,
                  values.count <= TelegramSponsoredLimits.messages,
                  let bytes = try? JSONEncoder().encode(response).count, bytes <= TelegramSponsoredLimits.resultBytes,
                  self.sponsored.values.filter({ $0 !== entry }).reduce(0, { $0 + $1.bytes }) + bytes <= TelegramSponsoredLimits.accountBytes else {
                self.sponsoredFailure(entry); self.publishSponsored(chat); return
            }
            var messages: [TelegramSponsoredMessage] = [], ids = Set<Int64>()
            for raw in values {
                guard let raw = raw.object, var decoded = TelegramSponsoredDecoder.decode(raw, result: generation), ids.insert(decoded.message.ref.message).inserted else {
                    self.sponsoredFailure(entry); self.publishSponsored(chat); return
                }
                let colors = self.sponsoredColors[decoded.message.accentColorID]
                decoded.message.lightColors = colors?.light ?? []; decoded.message.darkColors = colors?.dark ?? []
                messages.append(decoded.message); entry.files.merge(decoded.files, uniquingKeysWith: { _, new in new })
            }
            entry.bytes = bytes; entry.failures = 0; entry.used = self.now
            entry.snapshot.state = messages.isEmpty ? .empty : .ready
            entry.snapshot.messages = messages; entry.snapshot.messagesBetween = Int(spacing)
            entry.snapshot.expiresAt = self.now.addingTimeInterval(300); entry.snapshot.error = nil
            self.publishSponsored(chat)
        }
        if !sent { entry.inFlight = false; sponsoredFailure(entry) }
        publishSponsored(chat)
    }
    func sponsoredFailure(_ entry: SponsoredEntry) {
        entry.failures = min(6, entry.failures + 1)
        entry.snapshot.state = .error; entry.snapshot.messages = []; entry.snapshot.expiresAt = nil
        entry.snapshot.error = "Ad unavailable · Retry"
        entry.snapshot.retryNotBefore = max(retryAt, now.addingTimeInterval(min(60, pow(2, Double(entry.failures)))))
        entry.files = [:]; entry.bytes = 0
    }
    func currentSponsored(_ id: TelegramChatID, epoch: UUID, ref: TelegramSponsoredRef) -> (SponsoredEntry, TelegramSponsoredMessage)? {
        guard matches(id, epoch), id.topic == nil, let feed = feeds[id], feed.snapshot.kind == .channel,
              feed.snapshot.capabilities.canRead, let entry = sponsored[id.chat], entry.snapshot.state == .ready,
              entry.snapshot.result == ref.result, entry.snapshot.expiresAt.map({ now < $0 }) == true,
              let message = entry.snapshot.messages.first(where: { $0.ref == ref }) else { return nil }
        return (entry, message)
    }
    func reconcileSponsoredViews(_ chat: Int64, entry: SponsoredEntry) {
        guard entry.snapshot.state == .ready, entry.snapshot.expiresAt.map({ now < $0 }) == true, network == .ready else { return }
        let ready = Set(entry.snapshot.messages.filter(\.fullyLoaded).map(\.ref))
        let visible = Set(feeds(in: chat).flatMap { $0.observations.values }.filter { $0.active && $0.shown && $0.isCurrent }.flatMap { $0.sponsored }
            .filter { $0.fullTextVisible && $0.fullyLoaded && ready.contains($0.ref) }.map { $0.ref.message })
        let entered = visible.subtracting(entry.visible)
        entry.viewRetries.formUnion(entered.filter { entry.failedViews[$0].map { $0.attempts < 3 && now >= $0.retryAt } == true })
        entry.viewRetries.formIntersection(visible)
        entry.visible = visible
        for id in visible.sorted() where !entry.viewed.contains(id) && !entry.pendingViews.contains(id) {
            if entry.failedViews[id] != nil && !entry.viewRetries.contains(id) { continue }
            let result = entry.snapshot.result
            entry.pendingViews.insert(id); entry.viewRetries.remove(id)
            let sent = request("viewMessages", ["chat_id": .integer(chat), "message_ids": .array([.integer(id)]),
                "source": .typed("messageSourceChatHistory"), "force_read": .bool(false)], service: true,
                whileValid: {
                    guard let result else { return false }
                    return self.feeds(in: chat).contains { self.isVisible(.sponsored(.init(result: result, message: id)), in: $0) }
                }) { [weak self, weak entry] response in
                guard let self, let entry, !self.stopped, entry.snapshot.result == result else { return }
                entry.pendingViews.remove(id)
                if response.type == "ok" { entry.viewed.insert(id) }
                else { entry.failedViews[id] = ((entry.failedViews[id]?.attempts ?? 0) + 1, max(self.retryAt, self.now.addingTimeInterval(4))) }
                // Sponsored success never touches feed.viewed, inbox or unread.
            }
            if !sent { entry.pendingViews.remove(id); if entry.failedViews[id] != nil { entry.viewRetries.insert(id) } }
        }
    }
    func sponsoredAction(_ id: TelegramChatID, epoch: UUID, action: TelegramSponsoredAction, completion: @escaping (TelegramSponsoredActionResult) -> Void) {
        guard matches(id, epoch), let feed = feeds[id], feed.snapshot.kind == .channel, feed.snapshot.capabilities.canRead else {
            completion(.error("This ad is no longer available")); return
        }
        switch action {
        case .retry:
            if let entry = sponsoredEntry(id.chat) { fetchSponsored(id.chat, entry: entry) }
            completion(.none)
        case .retryMedia(let ref):
            guard let (entry, _) = currentSponsored(id, epoch: epoch, ref: ref), let index = entry.snapshot.messages.firstIndex(where: { $0.ref == ref }) else { completion(.error("This ad has expired")); return }
            if entry.snapshot.messages[index].error != nil && entry.snapshot.messages[index].backgroundResolved {
                fetchSponsored(id.chat, entry: entry); completion(.none); return
            }
            for media in entry.snapshot.messages[index].media where media.url == nil { entry.files[media.id]?["local"] = .null }
            for i in entry.snapshot.messages[index].media.indices { entry.snapshot.messages[index].media[i].error = nil }
            entry.snapshot.messages[index].error = nil
            publishSponsored(id.chat); reconcileSponsoredDownloads(); completion(.none)
        case .cancelMedia(let ref):
            cancelSponsoredMedia(id, epoch: epoch, ref: ref); completion(.none)
        case .cancelReport(let ref):
            sponsored[id.chat]?.reportOptions[ref.message] = nil; completion(.none)
        case .report(let ref, let step, let option):
            reportSponsored(id, epoch: epoch, ref: ref, step: step, option: option, completion: completion)
        case .click(let ref, let target, let confirmed):
            clickSponsored(id, epoch: epoch, ref: ref, target: target, confirmed: confirmed, completion: completion)
        }
    }
}

extension TelegramFeedSession {
    static func decodeSponsoredColors(_ update: TDLibMessage) -> [Int: (light: [UInt32], dark: [UInt32])] {
        var result: [Int: (light: [UInt32], dark: [UInt32])] = [:]
        for color in (update["colors"]?.array ?? []).prefix(256) {
            guard let raw = color.object, let id = raw["id"]?.integer else { continue }
            func values(_ key: String) -> [UInt32] { (raw[key]?.array ?? []).prefix(3).compactMap { $0.integer.flatMap { $0 >= 0 && $0 <= 0xFFFFFF ? UInt32($0) : nil } } }
            result[Int(id)] = (values("light_theme_colors"), values("dark_theme_colors"))
        }
        return result
    }
}
