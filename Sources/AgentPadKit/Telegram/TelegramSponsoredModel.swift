import AgentPadTelegram
import AppKit

struct TelegramSponsoredDialog: Identifiable {
    var id = UUID()
    let epoch: UUID
    let pane: UUID
    let ref: TelegramSponsoredRef
    let title: String
    let text: String
    var click: TelegramSponsoredClick?
    var step: UUID?
    var options: [TelegramSponsoredReportOption] = []
    var why = false
}

@MainActor extension TelegramConversationModel {
    func sponsoredInfo(_ ad: TelegramSponsoredMessage, pane: UUID, why: Bool) {
        guard !sponsoredBusy, currentAd(ad.ref) != nil else { return }
        sponsoredOperation = UUID()
        sponsoredDialog = .init(epoch: snapshot.epoch, pane: pane, ref: ad.ref,
            title: why ? "Why do I see this?" : "Sponsor info",
            text: why ? "This is an official sponsored message from Telegram. AgentPad displays the advertisement supplied by Telegram."
                : [ad.sponsorInfo, ad.additionalInfo].filter { !$0.isEmpty }.joined(separator: "\n\n"), why: why)
    }
    func currentAd(_ ref: TelegramSponsoredRef) -> TelegramSponsoredMessage? {
        guard snapshot.capabilities.canRead, snapshot.sponsored.state == .ready,
              snapshot.sponsored.expiresAt.map({ Date() < $0 }) == true else { return nil }
        return snapshot.sponsored.messages.first { $0.ref == ref }
    }
    func sponsoredAction(_ action: TelegramSponsoredAction, pane: UUID, ref: TelegramSponsoredRef? = nil,
                         openChat: @escaping (TelegramChatID) -> Void = { _ in }) {
        guard !sponsoredBusy, let provider, snapshot.capabilities.canRead, ref == nil || ref.flatMap(currentAd) != nil else { return }
        let epoch = snapshot.epoch, operation = UUID()
        sponsoredOperation = operation; sponsoredBusy = true
        Task {
            defer { if sponsoredOperation == operation { sponsoredBusy = false } }
            let result = await provider.performSponsoredAction(id, epoch: epoch, action: action)
            guard snapshot.epoch == epoch, sponsoredOperation == operation, panes.contains(pane),
                  await provider.conversationIsCurrent(id, epoch: epoch) else { return }
            switch result {
            case .none: break
            case .error(let error): notice = error
            case .notice(let text): sponsoredDialog = nil; notice = text
            case .confirmURL(let url):
                guard let ref, currentAd(ref) != nil, case .click(_, let target, _) = action else { return }
                if TelegramSponsoredVideoWindow.shared.confirm(url, ref: ref, model: self, pane: pane, target: target, openChat: openChat) { return }
                sponsoredDialog = .init(epoch: epoch, pane: pane, ref: ref, title: "Open \(url.host ?? "website")?", text: url.absoluteString, click: target)
            case .openURL(let url):
                guard let ref, currentAd(ref) != nil else { return }
                sponsoredDialog = nil; NSWorkspace.shared.open(url)
            case .openChat(let id):
                guard let ref, currentAd(ref) != nil else { return }
                sponsoredDialog = nil; openChat(id)
            case .reportOptions(let ref, let step, let title, let options):
                guard currentAd(ref) != nil else { return }
                var dialog = TelegramSponsoredDialog(epoch: epoch, pane: pane, ref: ref, title: title, text: "Choose the option supplied by Telegram.", step: step, options: options)
                if let previous = sponsoredDialog, previous.ref == ref, previous.pane == pane, previous.step != nil { dialog.id = previous.id }
                sponsoredDialog = dialog
            case .fullscreen(let ref):
                guard let ad = currentAd(ref) else { return }
                TelegramSponsoredVideoWindow.shared.show(ad, model: self, pane: pane, openChat: openChat)
            }
        }
    }
    func dismissSponsoredDialog() {
        sponsoredOperation = UUID(); sponsoredBusy = false
        if let dialog = sponsoredDialog, dialog.step != nil {
            let epoch = snapshot.epoch
            Task { _ = await provider?.performSponsoredAction(id, epoch: epoch, action: .cancelReport(dialog.ref)) }
        }
        sponsoredDialog = nil
    }
}

enum TelegramSponsoredLayout {
    static func rows(_ snapshot: TelegramConversationSnapshot) -> [ConversationRow] {
        let ordinary: [ConversationRow] = snapshot.messages.map { row in
            switch row.content { case .message: .message(row.id); case .service: .service(row.id); default: .unsupported(row.id) }
        }
        let ads = snapshot.sponsored
        guard snapshot.kind == .channel, ads.state == .ready, ads.expiresAt.map({ Date() < $0 }) == true, !ads.messages.isEmpty else { return ordinary }
        if ads.messagesBetween == 0 {
            return snapshot.hasNewer ? ordinary : ordinary + [.sponsored(ads.messages[0].ref)]
        }
        // Place from the latest end, preserving the server order and at least
        // messages_between ordinary rows between cards. Overflow stays lazy.
        let count = min(ads.messages.count, max(1, ordinary.count / ads.messagesBetween))
        let first = max(0, ordinary.count - (count - 1) * ads.messagesBetween)
        var result: [ConversationRow] = [], adIndex = 0
        for index in 0...ordinary.count {
            if adIndex < count, index == first + adIndex * ads.messagesBetween { result.append(.sponsored(ads.messages[adIndex].ref)); adIndex += 1 }
            if index < ordinary.count { result.append(ordinary[index]) }
        }
        return result
    }
}
