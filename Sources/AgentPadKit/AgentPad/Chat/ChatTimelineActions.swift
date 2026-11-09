import AppKit
import Observation
import SwiftUI

/// Commands resolve the current scoped message and permissions at execution,
/// never a value retained by a reusable cell. Domain models remain the owners.
@MainActor @Observable final class ChatTimelineActions {
    enum MessageAction {
        case reply, openExistingThread, openAsTab, replySource, edit, recoverEdit, retry, discard, discardEdit
        case requestDelete(revision: Int)
        case togglePin, toggleReaction(String)
    }
    enum SourceAction { case stop, cancel, answer, details }
    struct SourcePresentation: Equatable {
        var expanded = false
        var problem: String?
    }
    @ObservationIgnored private weak var model: (any ChatConversationPresentation)?
    @ObservationIgnored private weak var ownerModel: ChatChannelOwnerModel?
    private let root: String?
    private let conversation: NativeTimelineSnapshot.Conversation
    private let serviceID: ObjectIdentifier
    private let storeID: ObjectIdentifier?
    @ObservationIgnored private var valid = true
    @ObservationIgnored private var readingVisit = false
    @ObservationIgnored var jumpToLatest: (() -> Void)?
    @ObservationIgnored private var archived = true
    @ObservationIgnored private var mentionable: [(account: String, handle: String)] = []
    /// A renderer registers only the accounts in its loaded reactor tooltip or
    /// popup, and clears them on dismissal/reuse. Directory changes then affect
    /// that row, without making every reaction depend on every member.
    private(set) var reactorAccounts: [String: Set<String>] = [:]
    private var sourcePresentations: [String: SourcePresentation] = [:]
    private var requestProblems: [String: String] = [:]
    @ObservationIgnored var requestDetails: (String, ChatOrgKey) -> Void = { id, key in
        RequestTabs.shared.open(id, scope: .server(OrgKey(key)))
    }
    struct AttachmentContext {
        let manager: ChatAttachmentManager
        let message: ChatMessage
        let file: ChatAttachment
        let stamp: ChatAttachmentManager.Stamp
    }
    struct AttachmentPresentation {
        var problem: String?
        var operation = NativeTimelineSnapshot.AttachmentOperation()
    }
    private struct AttachmentKey: Hashable {
        let manager: ObjectIdentifier
        let stamp: ChatAttachmentManager.Stamp
    }
    private var attachmentPresentations: [AttachmentKey: AttachmentPresentation] = [:]
    @ObservationIgnored private var saves: [AttachmentKey: Task<Void, Never>] = [:]
    @ObservationIgnored var attachmentViewer: (ChatOrgKey, ChatMessage, ChatAttachment) -> Void = { key, message, file in
        CompositionTabs.shared.viewer(key: key, message: message, file: file)
    }

    func setReactorAccounts(_ accounts: Set<String>, messageID: String) {
        guard reactorAccounts[messageID] != (accounts.isEmpty ? nil : accounts) else { return }
        if accounts.isEmpty { reactorAccounts[messageID] = nil; return }
        guard resolve(messageID) != nil else { return }
        reactorAccounts[messageID] = accounts.isEmpty ? nil : accounts
    }

    init(model: any ChatConversationPresentation, root: String?, conversation: NativeTimelineSnapshot.Conversation) {
        self.model = model; self.root = root; self.conversation = conversation
        serviceID = ObjectIdentifier(model.service)
        storeID = model.service.orgSessions[model.key]?.store.map(ObjectIdentifier.init)
    }
    isolated deinit { if readingVisit { model?.endReading(root: root) } }
    func update(archived: Bool, mentionable: [(account: String, handle: String)], ownerModel: ChatChannelOwnerModel? = nil) {
        self.archived = archived; self.mentionable = mentionable
        self.ownerModel = ownerModel
        let messages = Set(current?.conversationMessages(root: root).map(\.id) ?? [])
        let sources = sourcePresentations.filter { messages.contains($0.key) }
        if sources != sourcePresentations { sourcePresentations = sources }
        let reactors = reactorAccounts.filter { messages.contains($0.key) }
        if reactors != reactorAccounts { reactorAccounts = reactors }
        let requests = Set(current?.threadRequests.map(\.id) ?? [])
        let problems = requestProblems.filter { requests.contains($0.key) }
        if problems != requestProblems { requestProblems = problems }
    }
    func invalidate() { endReading(); valid = false }
    var notificationPlace: String? { current?.notificationPlace(root: root) }
    var permitsNotificationSuppression: Bool {
        guard let model = current else { return false }
        return !model.searching && !model.hasNavigationReturn
    }
    func matches(_ identity: NativeTimelineSnapshot.Conversation?) -> Bool {
        current != nil && identity == conversation
    }
    /// A model update can precede the next SwiftUI/native snapshot. Do not let
    /// a queued window callback acknowledge content not laid out yet, or replace
    /// a newly restored position with the old viewport's bottom/anchor.
    func matchesPresented(_ snapshot: NativeTimelineSnapshot?) -> Bool {
        guard let snapshot, matches(snapshot.conversation), let model = current,
              model.readingPositionRestored == snapshot.state.readingPositionRevision else { return false }
        let messages = model.conversationMessages(root: root)
        guard messages.count == snapshot.messageIDs.count else { return false }
        let currentMessages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        return snapshot.rows.allSatisfy { row in
            guard case .message(let message) = row.payload else { return true }
            return currentMessages[message.content.message.id] == message.content.message
        }
    }
    private var current: (any ChatConversationPresentation)? {
        guard valid, let model, ChatTimelineAdapter.conversation(model, root: root) == conversation,
              ObjectIdentifier(model.service) == serviceID,
              model.service.orgSessions[model.key]?.store.map(ObjectIdentifier.init) == storeID,
              root == nil || model.threadRoot == root else { return nil }
        return model
    }
    private func resolve(_ id: String) -> (any ChatConversationPresentation, ChatMessage)? {
        guard let model = current, model.conversationMessages(root: root).contains(where: { $0.id == id }),
              let message = model.message(id) else { return nil }
        return (model, message)
    }
    func avatarService(messageID: String) -> ChatService? { resolve(messageID)?.0.service }
    func attachmentContext(messageID: String, fileID: String) -> AttachmentContext? {
        guard let (model, message) = resolve(messageID), !message.deleted,
              let file = message.attachments.first(where: { $0.id == fileID }),
              let manager = model.service.attachments(model.key),
              let stamp = manager.stamp(owner: message.attachmentOwner, message: message, file: file) else { return nil }
        return .init(manager: manager, message: message, file: file, stamp: stamp)
    }
    /// A stale message may retain its descriptor while its new revision is
    /// hydrating. It can display the old read's unavailable error, but this
    /// presentation key grants no permission to read, open, or save the file.
    private func attachmentPresentationContext(messageID: String, fileID: String) -> AttachmentContext? {
        guard let (model, message) = resolve(messageID), !message.deleted,
              let file = message.attachments.first(where: { $0.id == fileID }),
              let manager = model.service.attachments(model.key),
              var stamp = manager.stamp(owner: message.attachmentOwner) else { return nil }
        stamp.message = message.id; stamp.revision = message.revision; stamp.file = file
        return .init(manager: manager, message: message, file: file, stamp: stamp)
    }
    private func attachmentKey(_ context: AttachmentContext) -> AttachmentKey {
        .init(manager: ObjectIdentifier(context.manager), stamp: context.stamp)
    }
    func attachmentPresentation(_ context: AttachmentContext) -> AttachmentPresentation {
        attachmentPresentations[attachmentKey(context)] ?? .init()
    }
    func attachmentPresentations(message: ChatMessage) -> [String: AttachmentPresentation] {
        Dictionary(uniqueKeysWithValues: message.attachments.compactMap { file in
            guard let context = attachmentPresentationContext(messageID: message.id, fileID: file.id) else { return nil }
            return (file.id, attachmentPresentation(context))
        })
    }
    /// Cell-owned speculative work may publish a new immutable presentation, but
    /// cannot mutate installed row geometry or another message's error state.
    func previewFinished(_ context: AttachmentContext, problem: String?) {
        guard let live = attachmentPresentationContext(messageID: context.message.id, fileID: context.file.id),
              attachmentKey(live) == attachmentKey(context) else { return }
        let problem = problem.map { context.manager.current(context.stamp) ? $0 : "File unavailable." }
        var value = attachmentPresentation(context)
        guard value.problem != problem else { return }
        value.problem = problem; attachmentPresentations[attachmentKey(context)] = value
    }
    func retryAttachment(messageID: String, fileID: String, from view: NSView) {
        guard let context = attachmentContext(messageID: messageID, fileID: fileID) else { return }
        if context.file.isImage {
            var value = attachmentPresentation(context)
            value.problem = nil; value.operation.retry &+= 1
            attachmentPresentations[attachmentKey(context)] = value
        } else { saveAttachment(messageID: messageID, fileID: fileID, from: view) }
    }
    func openAttachment(messageID: String, fileID: String) {
        guard let context = attachmentContext(messageID: messageID, fileID: fileID), context.file.isImage,
              !attachmentPresentation(context).operation.busy else { return }
        attachmentViewer(context.manager.key, context.message, context.file)
    }
    func saveAttachment(messageID: String, fileID: String, from anchor: NSView) {
        guard let context = attachmentContext(messageID: messageID, fileID: fileID),
              let window = anchor.window,
              let session = TabRouter.shared.stores().flatMap({ $0.allSessions + $0.popups.sessions })
                .first(where: { anchor.isDescendant(of: $0.engine.view) }),
              let owner = TabRouter.shared.owner(of: session.id) else { return }
        // The stable engine/window owns this operation. A recycled row is never
        // part of its validity predicate and cannot cancel the user's download.
        let engine = session.engine.view
        startAttachmentSave(context, window: window, stillValid: { [weak window, weak engine] in
            guard let window, let engine else { return false }
            return engine.window === window && TabRouter.shared.owner(of: session.id)?.store === owner.store
        })
    }
    typealias AttachmentSave = @MainActor (ChatAttachmentManager, ChatMessage, ChatAttachment, NSWindow, @escaping @MainActor () -> Bool) async throws -> Void
    /// The injected operation is also used by fixture tests without presenting a
    /// save sheet. The production path uses the existing manager's stamp gates.
    func startAttachmentSave(_ context: AttachmentContext, window: NSWindow,
                             stillValid: @escaping @MainActor () -> Bool,
                             save: AttachmentSave? = nil) {
        let key = attachmentKey(context)
        guard current != nil, context.manager.current(context.stamp), saves[key] == nil else { return }
        var value = attachmentPresentation(context); value.problem = nil; value.operation.busy = true
        attachmentPresentations[key] = value
        let operation: AttachmentSave = save ?? { manager, message, file, window, valid in
            try await manager.save(message, file: file, window: window, stillValid: valid)
        }
        saves[key] = Task { [weak self] in
            let valid: @MainActor () -> Bool = { [weak self] in
                self?.current != nil && context.manager.current(context.stamp) && stillValid()
            }
            var problem: String?
            do { try await operation(context.manager, context.message, context.file, window, valid) }
            catch { if !Task.isCancelled { problem = ChatAttachments.reason(error) } }
            guard let self else { return }
            saves[key] = nil
            guard valid() else { attachmentPresentations[key] = nil; return }
            var value = attachmentPresentation(context); value.operation.busy = false; value.problem = problem
            attachmentPresentations[key] = value
        }
    }
    @discardableResult func perform(_ action: MessageAction, messageID: String) -> Bool {
        guard let (model, message) = resolve(messageID) else { return false }
        switch action {
        case .reply:
            guard message.hasFixed, !message.deleted || model.isDM, message.localState == nil else { return false }
            model.openThreadFromMessage(message.threadRootId ?? message.id)
        case .openExistingThread:
            // Existing reply/request links remain navigable after root deletion.
            model.openThreadFromMessage(message.id)
        case .openAsTab:
            guard message.hasFixed, message.localState == nil else { return false }
            model.openThreadFromMessage(message.threadRootId ?? message.id, asTab: true)
        case .replySource:
            guard let source = message.inReplyToMessageId else { return false }
            model.openThreadFromMessage(message.threadRootId ?? source)
        case .edit:
            guard !archived, !model.feed.archived, model.editing == nil, model.canEdit(message) else { return false }
            return model.beginEditing(message, root: root)
        case .recoverEdit:
            guard model.editing == nil, !message.deleted, message.localEdit?.kind == "edit", message.localEdit?.state == "failed" else { return false }
            return model.beginEditing(message, root: root, recovering: true)
        case .requestDelete(let displayedRevision):
            guard message.revision == displayedRevision, model.canDelete(message) else { return false }
            return model.requestDelete(message, root: root)
        case .retry:
            guard message.localState == .failed, !archived, !model.feed.archived, model.canRetry(message) else { return false }
            model.retry(message)
        case .discard:
            guard message.localState != nil else { return false }
            model.discard(message)
        case .discardEdit:
            guard message.localEdit?.state == "failed" else { return false }
            model.discardEdit(message)
        case .togglePin:
            guard let b1 = model.b1, b1.supports("chat.pins"), b1.canChange, !b1.pending(message.id, choice: "pin"),
                  !message.deleted, b1.state.metadata[message.id] != nil else { return false }
            b1.togglePin(message.id)
        case .toggleReaction(let emoji):
            guard let b1 = model.b1, b1.supports("chat.reactions"), b1.canChange, !message.deleted,
                  let canonical = ChatEmoji.canonical(emoji), !b1.pending(message.id, choice: canonical) else { return false }
            b1.toggle(message.id, emoji: canonical)
        }
        return true
    }
    func copyText(messageID: String) -> String? {
        guard let (model, message) = resolve(messageID) else { return nil }
        return model.copyText(message)
    }
    func copyFailedEdit(messageID: String) -> String? { resolve(messageID)?.1.localEdit?.text }
    func copyLink(messageID: String) -> String? {
        guard let (model, message) = resolve(messageID), !model.isDM, message.hasFixed,
              !message.deleted, message.seq != nil else { return nil }
        return ChatMessageLink(key: model.key, message: message).url?.absoluteString
    }
    func activeEditing(messageID: String) -> ChatChannelModel.Editing? {
        guard let model = current, let edit = model.editing, edit.messageId == messageID,
              edit.root == root, model.conversationMessages(root: root).contains(where: { $0.id == messageID && !$0.deleted }) else { return nil }
        return edit
    }
    func confirmation(messageID: String, actionID: UUID) -> ConfirmationCoordinator? {
        guard let model = current, let confirmation = model.confirmation,
              model.deletionRoot == root, confirmation.context?.targetID == "message:\(messageID)",
              confirmation.context?.actionID == actionID else { return nil }
        return confirmation
    }
    func reactionPicker(messageID: String) -> AnyView? {
        guard let (model, message) = resolve(messageID), !message.deleted,
              let b1 = model.b1, b1.supports("chat.reactions"), b1.state.accessible else { return nil }
        return AnyView(ChatNativeReactionPicker(b1: b1, message: messageID))
    }
    func reactionContext(messageID: String) -> ChatB1Channel? {
        guard let (model, message) = resolve(messageID), !message.deleted,
              let b1 = model.b1, b1.supports("chat.reactions"), b1.state.accessible else { return nil }
        return b1
    }
    func reactorsView(messageID: String, emoji: String, members: [ChatOrgView.Member],
                      accountsChanged: ((Set<String>) -> Void)? = nil) -> AnyView? {
        guard let b1 = reactionContext(messageID: messageID),
              b1.state.metadata[messageID]?.reactions.contains(where: { $0.emoji == emoji }) == true else { return nil }
        return AnyView(ChatNativeReactorsContent(b1: b1, message: messageID, emoji: emoji,
            members: members, onAccountsChanged: accountsChanged))
    }
    func sourcePresentation(messageID: String) -> SourcePresentation { sourcePresentations[messageID] ?? .init() }
    func requestProblem(requestID: String) -> String? { requestProblems[requestID] }
    func toggleSources(messageID: String) {
        guard let (model, _) = resolve(messageID), model is ChatChannelModel,
              model.sourceStatuses.filter({ $0.source == messageID }).count > 3 else { return }
        var value = sourcePresentation(messageID: messageID); value.expanded.toggle()
        sourcePresentations[messageID] = value
    }
    @discardableResult func performSource(_ action: SourceAction, messageID: String, requestID: String) -> Bool {
        guard let (model, _) = resolve(messageID), let channel = model as? ChatChannelModel,
              ChatNotifications.allowed(channel.service, channel.key, channel: channel.channel),
              let status = channel.sourceStatuses.first(where: { $0.source == messageID && $0.id == requestID }) else { return false }
        let presentation = ChatSourcePresentation(status, me: model.key.accountId,
            connected: model.service.isServerKnown(model.service, model.key))
        var value = sourcePresentation(messageID: messageID)
        switch action {
        case .stop:
            guard presentation.action == .stop else { return false }
            value.problem = model.service.askToEnd(model.key, requestID, type: "request.stop", states: [.starting, .running])
        case .cancel:
            guard presentation.action == .cancel else { return false }
            value.problem = model.service.cancelChannelIntent(model.key, request: requestID)
        case .answer:
            guard presentation.answered, let id = status.answer, let message = model.message(id) else { return false }
            channel.navigate(to: message)
        case .details: requestDetails(requestID, model.key)
        }
        if sourcePresentations[messageID] != value { sourcePresentations[messageID] = value }
        return true
    }
    @discardableResult func addAgent(messageID: String, agentID: String) -> Bool {
        guard let (model, message) = resolve(messageID), let channel = model as? ChatChannelModel,
              !message.deleted, message.hasMutable || message.localState != nil,
              let org = ChatOrgCurrent.shared.model, org.key == channel.key,
              let store = channel.service.orgSessions[channel.key]?.store,
              org.missingAgentMentions(in: message.text, channel: channel.channel,
                  catalog: (try? store.calls.catalog()) ?? []).contains(where: { $0.id == agentID && $0.canAdd }) else { return false }
        ChatAgentMembershipHint.add(agentID, model: channel)
        return true
    }
    private func requestOwner(_ requestID: String) -> ChatChannelOwnerModel? {
        guard let model = current as? ChatChannelModel, root != nil,
              model.threadRequests.contains(where: { $0.id == requestID }),
              !model.sourceStatuses.contains(where: { $0.id == requestID }),
              let ownerModel, ownerModel.key == model.key, ownerModel.channel == model.channel,
              ownerModel.service === model.service,
              ChatNotifications.allowed(model.service, model.key, channel: model.channel) else { return nil }
        return ownerModel
    }
    @discardableResult func openRequest(requestID: String) -> Bool {
        guard let owner = requestOwner(requestID) else { return false }
        requestDetails(requestID, owner.key)
        return true
    }
    @discardableResult func openRequestSession(requestID: String) -> Bool {
        guard let owner = requestOwner(requestID) else { return false }
        requestProblems[requestID] = owner.openSession(requestID)
        return true
    }
    func loadOlder() { guard let model = current else { return }; if root == nil { model.loadOlder() } else { model.earlierReplies() } }
    func markRead() { current?.markConversationRead(root: root) }
    func finishNavigation() { current?.finishNavigation() }
    @discardableResult func dismissTransient() -> Bool { current?.dismissTransient() ?? false }
    func beginReading() {
        guard let model = current else { return }
        readingVisit = true; model.beginReading(root: root)
    }
    func endReading() {
        guard readingVisit else { return }
        readingVisit = false
        // End the old visit even after its store/root binding was invalidated.
        model?.endReading(root: root)
    }
    func readIfLooking(appActive: Bool, shown: Bool, atBottom: Bool) {
        current?.readIfLooking(root: root, appActive: appActive, shown: shown, atBottom: atBottom)
    }
    func setPosition(_ position: ChatScrollPosition) {
        guard let model = current, model.positions[root ?? ""] != position else { return }
        model.positions[root ?? ""] = position
    }
    func retryMetadata() { current?.b1?.retryReads() }
    @discardableResult func saveEditing(messageID: String) -> Bool {
        guard let (model, message) = resolve(messageID), model.editing?.messageId == messageID, model.editing?.root == root,
              !archived, !model.feed.archived, model.canEdit(message) else { return false }
        return model.saveEditing(members: mentionable)
    }
    func cancelEditing(messageID: String) {
        guard let model = current, model.editing?.messageId == messageID, model.editing?.root == root else { return }
        model.cancelEditing(messageID: messageID, all: false)
    }
    func updateEditing(messageID: String, version: String?, text: String) {
        guard let model = current, model.editing?.messageId == messageID, model.editing?.root == root,
              model.editing?.version == version else { return }
        model.editing?.text = text
    }
}
