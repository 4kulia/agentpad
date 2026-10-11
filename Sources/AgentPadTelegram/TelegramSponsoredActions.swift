import Foundation

extension TelegramFeedSession {
    final class SponsoredReply {
        var completion: ((TelegramSponsoredActionResult) -> Void)?
        init(_ completion: @escaping (TelegramSponsoredActionResult) -> Void) { self.completion = completion }
        func finish(_ result: TelegramSponsoredActionResult) { let callback = completion; completion = nil; callback?(result) }
    }
    func reportSponsored(_ id: TelegramChatID, epoch: UUID, ref: TelegramSponsoredRef, step: UUID?, option: String?, completion: @escaping (TelegramSponsoredActionResult) -> Void) {
        guard let (entry, message) = currentSponsored(id, epoch: epoch, ref: ref), message.canReport,
              entry.pendingReports.isEmpty else { completion(.error("This ad cannot be reported now")); return }
        if let option {
            guard let choices = entry.reportOptions[ref.message], choices.step == step,
                  choices.options.contains(where: { $0.id == option }) else { completion(.error("Choose a current report option")); return }
        } else if step != nil { completion(.error("Choose a current report option")); return }
        let reply = SponsoredReply(completion)
        entry.pendingReports.insert(ref.message)
        let sent = request("reportChatSponsoredMessage", ["chat_id": .integer(id.chat), "message_id": .integer(ref.message), "option_id": .string(option ?? "")],
            onTimeout: { reply.finish(.error("Ad report timed out. Its outcome is unknown.")) }) { [weak self, weak entry] response in
            guard let self, let entry else { reply.finish(.error("This ad is no longer available")); return }
            entry.pendingReports.remove(ref.message)
            guard self.currentSponsored(id, epoch: epoch, ref: ref) != nil else { reply.finish(.error("This ad has expired")); return }
            switch response.type {
            case "reportSponsoredResultOptionRequired":
                guard let bytes = try? JSONEncoder().encode(response).count, bytes <= 64 * 1024,
                      let values = response["options"]?.array, values.count <= 100, let title = response["title"]?.string, title.utf8.count <= 16384 else {
                    reply.finish(.error("Report options are unavailable")); return
                }
                let options = values.compactMap { value -> TelegramSponsoredReportOption? in
                    guard let option = value.object, let raw = option["id"]?.string, raw.utf8.count <= 8192,
                          Data(base64Encoded: raw) != nil, let text = option["text"]?.string, text.utf8.count <= 16384 else { return nil }
                    return .init(id: raw, text: text)
                }
                guard options.count == values.count, !options.isEmpty, Set(options.map(\.id)).count == options.count else { reply.finish(.error("Report options are unavailable")); return }
                let revision = UUID(); entry.reportOptions = [ref.message: (revision, options)]
                reply.finish(.reportOptions(ref, step: revision, title: title, options: options))
            case "reportSponsoredResultOk", "reportSponsoredResultFailed":
                entry.reportOptions[ref.message] = nil
                entry.snapshot.messages.removeAll { $0.ref == ref }
                if entry.snapshot.messages.isEmpty { entry.snapshot.state = .empty }
                self.publishSponsored(id.chat)
                reply.finish(.notice(response.type == "reportSponsoredResultOk" ? "Ad reported to Telegram" : "Telegram could not find this ad. It may have expired."))
            case "reportSponsoredResultAdsHidden":
                // Telegram hid ads account-wide. Invalidate; do not persist an ad-block preference.
                for chat in self.sponsored.keys {
                    self.sponsored[chat] = SponsoredEntry()
                    self.publishSponsored(chat)
                }
                reply.finish(.notice("Telegram has hidden sponsored messages"))
            case "reportSponsoredResultPremiumRequired":
                entry.reportOptions[ref.message] = nil
                reply.finish(.notice("Telegram Premium is required to hide ads"))
            default: reply.finish(.error("Ad report failed · Retry"))
            }
        }
        if !sent { entry.pendingReports.remove(ref.message); reply.finish(.error("Ad report is waiting for Telegram · Retry")) }
    }
    func clickSponsored(_ id: TelegramChatID, epoch: UUID, ref: TelegramSponsoredRef, target: TelegramSponsoredClick,
                        confirmed: Bool, completion: @escaping (TelegramSponsoredActionResult) -> Void) {
        guard let (entry, message) = currentSponsored(id, epoch: epoch, ref: ref), message.fullyLoaded,
              !entry.pendingClicks.contains(ref.message) else { completion(.error("This ad is no longer available")); return }
        let media = message.media.first { $0.role == .content }
        if target == .expandVideo {
            guard media?.kind == .video else { completion(.error("Video unavailable")); return }
            completion(.fullscreen(ref)); return // The separate expand control is not a sponsored click.
        }
        let isMedia = target == .media || target == .silentVideoMedia || target == .fullscreenMedia
        let fullscreen = target == .fullscreenMedia || target == .fullscreenButton
        guard !isMedia || media != nil, !fullscreen || media?.kind == .video,
              target != .silentVideoMedia || media?.kind == .video,
              target != .sponsorPhoto || message.media.contains(where: { $0.role == .sponsor }) else { completion(.error("Ad action unavailable")); return }
        let raw: String
        if case .link(let index) = target {
            guard message.entities.indices.contains(index), let link = message.entities[index].url else { completion(.error("Ad link unavailable")); return }
            raw = link
        } else { raw = message.url }
        guard let url = TelegramSponsoredURL.checked(raw) else { completion(.error("Ad link unavailable")); return }
        let expand = target == .media && media?.kind == .video
        if !expand, !confirmed, TelegramSponsoredURL.requiresConfirmation(url) { completion(.confirmURL(url)); return }
        let reply = SponsoredReply(completion)
        entry.pendingClicks.insert(ref.message)
        let sent = request("clickChatSponsoredMessage", ["chat_id": .integer(id.chat), "message_id": .integer(ref.message),
            "is_media_click": .bool(isMedia), "from_fullscreen": .bool(fullscreen)], onTimeout: { reply.finish(.error("Ad action timed out · Retry")) }) { [weak self, weak entry] response in
            entry?.pendingClicks.remove(ref.message)
            guard let self, reply.completion != nil, self.currentSponsored(id, epoch: epoch, ref: ref) != nil else { reply.finish(.error("This ad has expired")); return }
            guard response.type == "ok" else { reply.finish(.error("Ad action failed · Retry")); return }
            if expand { reply.finish(.fullscreen(ref)); return }
            self.resolveSponsoredLink(id, epoch: epoch, ref: ref, url: url, reply: reply)
        }
        if !sent { entry.pendingClicks.remove(ref.message); reply.finish(.error("Ad action is waiting for Telegram · Retry")) }
    }
    private func resolveSponsoredLink(_ id: TelegramChatID, epoch: UUID, ref: TelegramSponsoredRef, url: URL, reply: SponsoredReply) {
        let host = url.host?.lowercased() ?? ""
        guard ["t.me", "telegram.me", "telegram.dog", "telesco.pe"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { reply.finish(.openURL(url)); return }
        let sent = request("getInternalLinkType", ["link": .string(url.absoluteString)], onTimeout: { reply.finish(.error("Ad link lookup timed out")) }) { [weak self] response in
            guard let self, reply.completion != nil, self.currentSponsored(id, epoch: epoch, ref: ref) != nil else { reply.finish(.error("This ad has expired")); return }
            if response.type == "error" { reply.finish(.openURL(url)); return }
            // Opening never joins, starts a bot, sends a draft, or applies an invite.
            if response.type == "internalLinkTypePublicChat", let name = response["chat_username"]?.string,
               response["open_profile"]?.bool != true, (response["draft_text"]?.string ?? "").isEmpty {
                let sent = self.request("searchPublicChat", ["username": .string(name)], onTimeout: { reply.finish(.error("Ad chat lookup timed out")) }) { [weak self] chat in
                    guard let self, reply.completion != nil, self.currentSponsored(id, epoch: epoch, ref: ref) != nil else { reply.finish(.error("This ad has expired")); return }
                    if chat.type == "chat", let chatID = chat["id"]?.integer { reply.finish(.openChat(self.destination(chat: chatID))) }
                    else { reply.finish(.error("Ad chat unavailable")) }
                }
                if !sent { reply.finish(.error("Ad chat lookup is waiting · Retry")) }
            } else {
                // Unsupported deep links stay in the Telegram app, never a web browser.
                let sent = self.request("getInternalLink", ["type": .object(response.fields.filter { $0.key != "@extra" }), "is_http": .bool(false)],
                    onTimeout: { reply.finish(.error("Ad link lookup timed out")) }) { [weak self] result in
                    guard let self, reply.completion != nil, self.currentSponsored(id, epoch: epoch, ref: ref) != nil,
                          result.type == "httpUrl", let raw = result["url"]?.string, let target = URL(string: raw), target.scheme == "tg" else {
                        reply.finish(.error("Open this destination in Telegram")); return
                    }
                    reply.finish(.openURL(target))
                }
                if !sent { reply.finish(.error("Ad link lookup is waiting · Retry")) }
            }
        }
        if !sent { reply.finish(.error("Ad link lookup is waiting · Retry")) }
    }
}
