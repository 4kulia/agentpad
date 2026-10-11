import AgentPadTelegram
import AppKit
import Observation

@MainActor @Observable
final class TelegramConversationModel: ConversationActions {
    let id: TelegramChatID
    private(set) var snapshot: TelegramConversationSnapshot
    var draft = TelegramDraft()
    var problem: String?
    var notice: String?
    var importing = false
    var botDialog: TelegramBotDialog?
    var sponsoredDialog: TelegramSponsoredDialog?
    var sponsoredBusy = false
    @ObservationIgnored var sponsoredOperation = UUID()
    var checkingInline = false
    var inlineCheck: TelegramInlineQueryCheck = .ordinary
    var checkedInlineName: String?
    var scrollAnchor: String?
    var requestedMessage: Int64?
    @ObservationIgnored private var requestedMessageEpoch: UUID?
    @ObservationIgnored var inlineTask: Task<Void, Never>?
    @ObservationIgnored var appliedForceReply: UUID?
    @ObservationIgnored var forcedReplyMessage: Int64?
    var draftThumbnails: [UUID: CGImage] = [:]
    @ObservationIgnored let previewOwner = UUID()
    @ObservationIgnored var previewMessage: Int64?
    @ObservationIgnored var importDirectory: URL?
    @ObservationIgnored var preparingDirectory = false
    @ObservationIgnored var provider: (any TelegramConversationProvider)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirtyDraft = false
    @ObservationIgnored private var persistedRevision: UUID?
    @ObservationIgnored private var submitted: UUID?
    @ObservationIgnored var panes = Set<UUID>()
    @ObservationIgnored private let observations = TelegramPresentationObservations()
    init(id: TelegramChatID) { self.id = id; snapshot = .init(destination: id) }
    deinit { observations.invalidateAll(); saveTask?.cancel(); inlineTask?.cancel() }
    var canSend: Bool { snapshot.capabilities.canSend && snapshot.connected && !draft.isEmpty && !importing && submitted != draft.revision && !blocksInlineSend }
    var presentation: ConversationSnapshot {
        .init(destination: .telegram(id), epoch: snapshot.epoch, revision: snapshot.revision,
              rows: TelegramSponsoredLayout.rows(snapshot), hasOlder: snapshot.hasOlder, draftRevision: draft.revision, presence: snapshot.presence, canSend: canSend)
    }
    func observe(pane: UUID, provider: any TelegramConversationProvider) async {
        self.provider = provider; panes.insert(pane)
        let stream = await provider.conversation(id, pane: pane)
        var observedEpoch = snapshot.epoch
        for await value in stream {
            guard !Task.isCancelled else { break }
            observedEpoch = value.epoch
            receive(value)
        }
        observations.invalidate(pane: pane)
        if dirtyDraft { await provider.updateDraft(id, epoch: observedEpoch, draft: draft) }
        await provider.releaseConversation(id, pane: pane, epoch: observedEpoch)
        panes.remove(pane)
        if botDialog?.pane == pane { botDialog = nil }
        if sponsoredDialog?.pane == pane { dismissSponsoredDialog() }
        TelegramSponsoredVideoWindow.shared.close(pane: pane)
    }
    func receive(_ value: TelegramConversationSnapshot) {
        guard value.destination == id, value.epoch != snapshot.epoch || value.revision >= snapshot.revision else { return }
        if let previewMessage, snapshot.epoch != value.epoch || !value.messages.contains(where: { $0.messageID == previewMessage && !$0.protectedContent }) {
            QuickLookPanel.dismiss(owner: previewOwner); self.previewMessage = nil
        }
        if snapshot.epoch != value.epoch {
            observations.invalidateAll()
            saveTask?.cancel(); saveTask = nil; dirtyDraft = false; submitted = nil; draft = value.draft; persistedRevision = value.draft.revision
            importDirectory = nil
            botDialog = nil; appliedForceReply = nil; forcedReplyMessage = nil; checkedInlineName = nil
            sponsoredOperation = UUID(); sponsoredBusy = false
            inlineTask?.cancel(); inlineTask = nil; checkingInline = false
        } else if !dirtyDraft || value.draft.revision == draft.revision {
            draft = value.draft; dirtyDraft = false
        } else if submitted == draft.revision && value.consumedDraftRevisions.contains(draft.revision) {
            draft = value.draft; dirtyDraft = false
        }
        snapshot = value
        resolveRequestedMessage()
        if let dialog = sponsoredDialog, dialog.epoch != value.epoch || currentAd(dialog.ref) == nil { dismissSponsoredDialog() }
        TelegramSponsoredVideoWindow.shared.reconcile(model: self)
        reconcileForceReply()
        inspectInlineDraft()
        if let reply = draft.replyTo, value.unavailableMessageIDs.contains(reply) { change { $0.replyTo = nil } }
        let retained = Set(draft.attachments.map(\.id))
        draftThumbnails = draftThumbnails.filter { retained.contains($0.key) }
        if value.capabilities.canSend && importDirectory == nil { prepareImportDirectory() }
        if value.error != nil { submitted = nil }
    }
    func change(_ mutate: (inout TelegramDraft) -> Void) {
        draft.sendAsText = nil
        mutate(&draft); draft.revision = UUID(); dirtyDraft = true; problem = nil
        inspectInlineDraft()
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            while self.dirtyDraft && self.persistedRevision != self.draft.revision && !Task.isCancelled {
                let value = self.draft, epoch = self.snapshot.epoch
                let saved = await self.provider?.updateDraft(self.id, epoch: epoch, draft: value) == true
                guard !Task.isCancelled else { break }
                if saved { self.persistedRevision = value.revision }
                else {
                    if self.submitted != value.revision && self.draft.revision == value.revision { self.problem = "Draft not saved. Keep this tab open and try again." }
                    break
                }
            }
            self.saveTask = nil
        }
    }
    func send() {
        guard canSend, let provider else { return }
        let value = draft, epoch = snapshot.epoch
        submitted = value.revision
        Task {
            // Both operations enter the same connector actor in this order.
            await provider.updateDraft(id, epoch: epoch, draft: value)
            await provider.sendDraft(id, epoch: epoch, draft: value)
        }
    }
    func reply(to row: String) {
        guard snapshot.capabilities.canSend, let message = snapshot.messages.first(where: { $0.id == row }), message.messageID > 0 else { return }
        change { $0.replyTo = message.messageID }
    }
    func retry(_ row: String) {
        guard let message = snapshot.messages.first(where: { $0.id == row }) else { return }
        let epoch = snapshot.epoch
        Task { await provider?.retryMessage(id, epoch: epoch, message: message.messageID) }
    }
    func recover(_ operation: UUID) {
        let epoch = snapshot.epoch
        Task { await provider?.recoverMessage(id, epoch: epoch, operation: operation) }
    }
    func discardRecovery(_ operation: UUID) {
        let epoch = snapshot.epoch
        Task { await provider?.discardRecovery(id, epoch: epoch, operation: operation) }
    }
    func loadOlder() { load(latest: false) }
    func showMessage(_ message: Int64) {
        guard message > 0 else { return }
        requestedMessage = message; requestedMessageEpoch = nil
        resolveRequestedMessage()
    }
    private func resolveRequestedMessage() {
        guard let message = requestedMessage else { return }
        if let row = snapshot.messages.first(where: { $0.messageID == message }) { scrollAnchor = row.id; return }
        guard snapshot.capabilities.canRead, !snapshot.loading, requestedMessageEpoch != snapshot.epoch, let provider else { return }
        let epoch = snapshot.epoch; requestedMessageEpoch = epoch
        Task { await provider.loadMessage(id, epoch: epoch, message: message) }
    }
    func load(latest: Bool) { let epoch = snapshot.epoch; Task { await provider?.loadHistory(id, epoch: epoch, latest: latest) } }
    func observe(_ value: TelegramPresentationObservation) {
        let latest = observations.record(value)
        Task { await provider?.observePresentation(id, observation: latest) }
    }
    func invalidatePresentation(pane: UUID) { observations.invalidate(pane: pane) }
    func typing(_ typing: Bool, pane: UUID) {
        let epoch = snapshot.epoch
        Task { await provider?.composerActivity(id, epoch: epoch, pane: pane, typing: typing) }
    }
    func pin() {
        guard id.topic == nil || id.topic?.forumID != nil else { return }
        Task {
            guard let row = await TelegramService.chats.row(id.root) else { return }
            await TelegramService.chats.mode(row, .pinned)
        }
    }
    func cacheLimit(_ limit: Int) {
        let epoch = snapshot.epoch
        Task { await provider?.setAttachmentCacheLimit(id, epoch: epoch, mebibytes: limit) }
    }
    func clearCache() {
        let epoch = snapshot.epoch
        Task { await provider?.clearAttachmentCache(id, epoch: epoch) }
    }
    func openMessageInTelegram(_ message: Int64) {
        let epoch = snapshot.epoch
        Task {
            let exact = await provider?.externalMessageLink(id, epoch: epoch, message: message)
            guard await provider?.conversationIsCurrent(id, epoch: epoch) == true, snapshot.epoch == epoch else { return }
            if let exact { NSWorkspace.shared.open(exact) }
            else {
                notice = "Select this chat in Telegram; a link to this message is unavailable."
                NSWorkspace.shared.open(URL(string: "tg://")!)
            }
        }
    }
}

@MainActor final class TelegramConversations {
    private final class Reference {
        weak var model: TelegramConversationModel?
        init(_ model: TelegramConversationModel) { self.model = model }
    }
    private var models: [TelegramChatID: Reference] = [:]
    func model(_ id: TelegramChatID) -> TelegramConversationModel {
        if let existing = models[id]?.model { return existing }
        models = models.filter { $0.value.model != nil }
        let model = TelegramConversationModel(id: id); models[id] = Reference(model); return model
    }
}

enum TelegramComposerKey: Equatable {
    case send, pin, native
    static func action(code: UInt16, modifiers: NSEvent.ModifierFlags, markedText: Bool, repeatKey: Bool) -> Self {
        guard !markedText, !repeatKey, [36, 76].contains(code) else { return .native }
        let flags = modifiers.intersection([.command, .shift, .control, .option])
        if flags == .command { return .send }
        if flags == [.command, .shift] { return .pin }
        return .native
    }
}
