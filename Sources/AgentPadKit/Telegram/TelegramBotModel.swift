import AgentPadTelegram
import AppKit

struct TelegramBotDialog: Identifiable {
    let id = UUID()
    let epoch: UUID
    let title: String
    let text: String
    var url: URL?
    var action: TelegramBotAction?
    var handoffMessage: Int64?
    var pane: UUID?
}

@MainActor extension TelegramConversationModel {
    var blocksInlineSend: Bool {
        guard draft.sendAsText != true, let name = TelegramInlineQuery.username(in: draft.text) else { return false }
        return checkingInline || checkedInlineName != name || inlineCheck != .ordinary
    }
    var inlineNotice: String? {
        guard blocksInlineSend else { return nil }
        if checkingInline || checkedInlineName != TelegramInlineQuery.username(in: draft.text) { return "Checking inline bot…" }
        return inlineCheck == .inlineBot ? "Inline mode is available in Telegram" : "Inline bot could not be checked"
    }
    func inspectInlineDraft() {
        guard inlineTask == nil, draft.sendAsText != true, let name = TelegramInlineQuery.username(in: draft.text),
              checkedInlineName != name, let provider else { return }
        checkingInline = true
        inlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            while let name = TelegramInlineQuery.username(in: self.draft.text), self.draft.sendAsText != true, !Task.isCancelled {
                let epoch = self.snapshot.epoch, text = self.draft.text
                let result = await provider.checkInlineQuery(self.id, epoch: epoch, text: text)
                guard !Task.isCancelled, self.snapshot.epoch == epoch else { return }
                if TelegramInlineQuery.username(in: self.draft.text) == name {
                    self.checkedInlineName = name; self.inlineCheck = result; break
                }
            }
            self.checkingInline = false; self.inlineTask = nil
        }
    }
    func sendInlineAsText() { change { $0.sendAsText = true } }
    func retryInlineCheck() { checkedInlineName = nil; inspectInlineDraft() }
    func reconcileForceReply() {
        if let forcedReplyMessage, snapshot.replyKeyboard?.messageID != forcedReplyMessage {
            if draft.replyTo == forcedReplyMessage { change { $0.replyTo = nil } }
            self.forcedReplyMessage = nil
        }
        guard let keyboard = snapshot.replyKeyboard, keyboard.forceReply, keyboard.personal || keyboard.kind == .inline,
              keyboard.revision != appliedForceReply else { return }
        appliedForceReply = keyboard.revision
        guard draft.replyTo == nil, snapshot.capabilities.canSend else { return }
        forcedReplyMessage = keyboard.messageID
        change { $0.replyTo = keyboard.messageID }
    }
    func cancelReply() {
        if forcedReplyMessage != nil, let keyboard = snapshot.replyKeyboard { botAction(.dismissKeyboard(revision: keyboard.revision)) }
        forcedReplyMessage = nil; change { $0.replyTo = nil }
    }
    func replyToKeyboard() {
        guard let keyboard = snapshot.replyKeyboard, snapshot.capabilities.canSend else { return }
        appliedForceReply = keyboard.revision; forcedReplyMessage = keyboard.messageID
        change { $0.replyTo = keyboard.messageID }
    }
    func currentBotAction(_ action: TelegramBotAction?) -> Bool {
        guard snapshot.capabilities.canRead else { return false }
        guard case let .button(message, revision, row, column, reply) = action else { return true }
        let keyboard = reply ? snapshot.replyKeyboard : snapshot.messages.first { $0.messageID == message }?.inlineKeyboard
        return keyboard?.revision == revision && keyboard?.messageID == message
            && keyboard?.rows.indices.contains(row) == true && keyboard?.rows[row].indices.contains(column) == true
    }
    func botAction(_ action: TelegramBotAction, pane: UUID? = nil, openUser: @escaping (TelegramChatID, String) -> Void = { _, _ in }) {
        guard let provider, currentBotAction(action) else { return }
        let epoch = snapshot.epoch
        Task {
            let result = await provider.performBotAction(id, epoch: epoch, action: action)
            guard await provider.conversationIsCurrent(id, epoch: epoch), snapshot.epoch == epoch,
                  currentBotAction(action), pane.map({ panes.contains($0) }) ?? true else { return }
            applyBotResult(result, action: action, pane: pane, openUser: openUser)
        }
    }
    func applyBotResult(_ result: TelegramBotActionResult, action: TelegramBotAction? = nil, pane: UUID? = nil,
                        openUser: (TelegramChatID, String) -> Void = { _, _ in }) {
        let previousDialog = botDialog?.id
        switch result {
        case .notice(let text): notice = text
        case .error(let text): problem = text
        case .alert(let text): botDialog = .init(epoch: snapshot.epoch, title: snapshot.title, text: text, action: action)
        case .confirmURL(let url):
            botDialog = .init(epoch: snapshot.epoch, title: "Open \(url.host ?? url.scheme ?? "link")?", text: url.absoluteString, url: url, action: action)
        case .answerWithURL(let text, let alert, let url):
            botDialog = .init(epoch: snapshot.epoch, title: alert ? snapshot.title : "Open \(url.host ?? "link")?", text: text + "\n\n" + url.absoluteString, url: url, action: action)
        case .copy(let text): NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "Copied"
        case .insertCommand(let command): change { $0.text += ($0.text.isEmpty || $0.text.hasSuffix("\n") ? "" : "\n") + command }
        case .user(let destination, let title): openUser(destination, title)
        case .openTelegram(let reason):
            let message: Int64? = if case .button(let message, _, _, _, _) = action { message } else { nil }
            let plainHandoff = if case .none = action { true } else { false }
            let botURL = inlineCheck == .inlineBot && plainHandoff ? checkedInlineName.flatMap { URL(string: "https://t.me/" + $0) } : nil
            let chatURL = snapshot.username.isEmpty ? nil : URL(string: "https://t.me/" + snapshot.username)
            botDialog = .init(epoch: snapshot.epoch, title: "Open in Telegram", text: reason + ". Your chat, topic and draft stay here.", url: botURL ?? chatURL ?? URL(string: "tg://"), action: action, handoffMessage: message)
        }
        if botDialog?.id != previousDialog { botDialog?.pane = pane }
    }
    func canConfirmBotURL(_ dialog: TelegramBotDialog) -> Bool {
        dialog.epoch == snapshot.epoch && currentBotAction(dialog.action) && dialog.url != nil
    }
    func confirmBotURL(_ dialog: TelegramBotDialog) {
        guard canConfirmBotURL(dialog), let url = dialog.url, let provider else { return }
        Task {
            guard await provider.conversationIsCurrent(id, epoch: dialog.epoch), canConfirmBotURL(dialog) else { return }
            if let message = dialog.handoffMessage { openMessageInTelegram(message); return }
            NSWorkspace.shared.open(url)
        }
    }
}
