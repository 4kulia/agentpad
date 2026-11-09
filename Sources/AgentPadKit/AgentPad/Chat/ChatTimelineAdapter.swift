import AppKit
import SwiftUI

/// Observation is deliberately evaluated in the SwiftUI body, before passing
/// immutable values into a native view. It installs no observers or read visits.
struct ChatTimelineSnapshotHost: View {
    let model: any ChatConversationPresentation
    let root: String?
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    let ownerModel: ChatChannelOwnerModel?
    let content: @MainActor (NativeTimelineSnapshot, ChatTimelineActions) -> AnyView
    @State private var adapter = ChatTimelineAdapter()
    @AppStorage("chat.ux2.alwaysShowTime") private var alwaysShowTime = false
    @Environment(\.displayScale) private var scale
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorSchemeContrast) private var contrast

    private var presentationCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    var body: some View {
        let style = ChatTimelineAdapter.style(scale: scale, locale: locale, calendar: presentationCalendar,
            increasedContrast: contrast == .increased, alwaysShowTime: alwaysShowTime)
        let snapshot = adapter.snapshot(model: model, root: root, members: members, mentionable: mentionable,
            me: me, archived: archived, ownerModel: ownerModel, style: style)
        content(snapshot, adapter.actions!)
            .overlay(alignment: .bottom) {
                if !snapshot.state.position.atBottom && snapshot.state.position.initialized {
                    Button { adapter.actions?.jumpToLatest?() } label: {
                        Label(snapshot.state.position.unseen.isEmpty ? "Jump to latest" : "New messages · \(snapshot.state.position.unseen.count)", systemImage: "arrow.down")
                            #if DEBUG && AGENTPAD_CHAT_NATIVE_W09_CAPTURE
                            .chatReviewParity("overlay/" + (root ?? "feed"), text: snapshot.state.position.unseen.isEmpty ? "Jump to latest" : "New messages · \(snapshot.state.position.unseen.count)", colors: ["foreground": ChatAppearance.surface], font: Theme.display(11, weight: .medium))
                            #endif
                            .font(Theme.display(11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                    }.buttonStyle(.plain).foregroundStyle(ChatAppearance.surface)
                        .background(ChatAppearance.accent, in: Capsule()).padding(.bottom, 8)
                }
            }
            .onDisappear { adapter.invalidate() }
    }
}

@MainActor final class ChatTimelineAdapter {
    typealias Snapshot = NativeTimelineSnapshot
    private struct Binding: Equatable {
        let model: ObjectIdentifier
        let service: ObjectIdentifier
        let store: ObjectIdentifier?
        let conversation: Snapshot.Conversation
    }
    let builder = ChatTimelineSnapshotBuilder()
    private var binding: Binding?
    private var epoch: UUID
    private(set) var actions: ChatTimelineActions?

    init(epoch: UUID = UUID()) { self.epoch = epoch }

    func invalidate() { actions?.invalidate(); actions = nil; binding = nil; epoch = UUID() }

    static func conversation(_ model: any ChatConversationPresentation, root: String?) -> Snapshot.Conversation {
        switch model.destination(root: root) {
        case .channel(let key, let channel, let thread): .init(key: key, address: .channel(channel), root: thread)
        case .directMessage(let ref, let thread): .init(key: model.key, address: .directMessage(ref), root: thread)
        case .telegram: preconditionFailure("The AgentPad timeline adapter requires an AgentPad conversation")
        }
    }

    func snapshot(model: any ChatConversationPresentation, root: String?, members: [ChatOrgView.Member],
                  mentionable: [(account: String, handle: String)], me: String, archived: Bool,
                  ownerModel: ChatChannelOwnerModel?, style: Snapshot.Style, selectedID: String? = nil,
                  aliases: [String: String] = [:], now: Date = Date()) -> Snapshot {
        let conversation = Self.conversation(model, root: root)
        let nextBinding = Binding(model: ObjectIdentifier(model), service: ObjectIdentifier(model.service),
            store: model.service.orgSessions[model.key]?.store.map(ObjectIdentifier.init), conversation: conversation)
        if binding != nextBinding || actions == nil {
            if binding != nil { actions?.invalidate(); epoch = UUID() }
            binding = nextBinding
            actions = ChatTimelineActions(model: model, root: root, conversation: conversation)
        }
        actions?.update(archived: archived, mentionable: mentionable, ownerModel: ownerModel)
        return builder.build(Self.capture(model: model, root: root, members: members, mentionable: mentionable,
            me: me, archived: archived, ownerModel: ownerModel, style: style, selectedID: selectedID,
            aliases: aliases, now: now, conversation: conversation, epoch: epoch, reactorAccounts: actions?.reactorAccounts ?? [:], mediaActions: actions))
    }

    static func capture(model: any ChatConversationPresentation, root: String?, members: [ChatOrgView.Member],
                        mentionable: [(account: String, handle: String)], me: String, archived: Bool,
                        ownerModel: ChatChannelOwnerModel?, style: Snapshot.Style, selectedID: String?,
                        aliases: [String: String], now: Date, conversation: Snapshot.Conversation,
                        epoch: UUID, reactorAccounts: [String: Set<String>] = [:], mediaActions: ChatTimelineActions? = nil) -> ChatTimelineSnapshotBuilder.Input {
        let service = model.service
        let feed = model.feed
        let messages = model.conversationMessages(root: root)
        let b1 = model.b1
        let metadata = b1?.state
        let canChange = b1?.canChange ?? false
        let reactions = b1?.supports("chat.reactions") == true
        let pins = b1?.supports("chat.pins") == true
        let summaries = b1?.supports("chat.thread_summary") == true
        let editing = model.editing
        let org = ChatOrgCurrent.shared.model
        let channel = model as? ChatChannelModel
        let manager = service.attachments(model.key)
        let connected = service.isServerKnown(service, model.key)
        let statuses = model.sourceStatuses
        let avatarAccess = service.avatarEpoch
        let avatarContext = service.avatarDisplayContext(model.key)
        func avatar(_ identity: ChatAuthorIdentity) -> Snapshot.Avatar {
            let ref = ChatAvatarReference(key: model.key, subject: identity.agent.map { .agent($0) } ?? .account(identity.account))
            return .init(reference: ref, metadata: service.avatars.metadata[ref.subject],
                         generation: service.avatars.imageGeneration(ref), context: avatarContext)
        }
        // All rows of one owner share this owner-level gate. Keep its reads
        // inside each synchronous snapshot capture so capability/access changes
        // remain observed; message/file authorization is still checked below.
        var attachmentAvailability: [ChatAttachmentOwner: Bool] = [:]
        func ownerAttachmentsAvailable(_ owner: ChatAttachmentOwner) -> Bool {
            if let available = attachmentAvailability[owner] { return available }
            let available = manager?.limits(for: owner) != nil && manager?.stamp(owner: owner) != nil
            attachmentAvailability[owner] = available
            return available
        }
        var visuals: [Snapshot.Visual] = []
        let contents: [Snapshot.MessageContent] = messages.map { message in
            // Catalog-only/current-organization changes must participate in
            // observation even when message bytes and caller members are equal.
            let agents = org?.agents(in: message.channelId) ?? []
            let agent = agents.first { $0.agentId == message.authorAgentId }
            let owner = members.first { $0.accountId == message.authorAccountId }
            let attribution = ChatMessageAttribution(message,
                ownerName: owner?.name ?? (message.authorAccountId == me ? "You" : "Former member"),
                ownerHandle: owner?.handle, catalogAgentName: agent?.name)
            let name = message.authorAgentId != nil ? message.authorAgentName ?? agent?.name ?? "Agent" : attribution.title
            let edit = editing.flatMap { $0.messageId == message.id && $0.root == root ? $0 : nil }
            let summary = feed.replySummaries[message.id]
            let b1Value = b1.map { b1 in
                Snapshot.Metadata(value: metadata?.metadata[message.id],
                    intents: (metadata?.intents[message.id] ?? []).map { .init(choice: $0.choice, present: $0.present, error: $0.error) },
                    reactionsSupported: reactions, pinsSupported: pins, summarySupported: summaries,
                    accessible: metadata?.accessible ?? false, canChange: canChange, loadError: metadata?.loadError, problem: b1.problem(message.id))
            }
            let sourceValues = channel.map { channel in
                statuses.filter { $0.source == message.id }.map { status in
                    Snapshot.SourceStatus(value: status, word: channel.sourceStatusWord(status),
                        activity: service.activity(model.key, request: status.id), connected: connected,
                        canGoToAnswer: status.answer.flatMap { model.message($0) } != nil)
                }
            } ?? []
            let hints: [Snapshot.MembershipHint]
            if message.text.contains("@"), let channel, let org, org.key == model.key,
               let store = service.orgSessions[model.key]?.store {
                hints = org.missingAgentMentions(in: message.text, channel: channel.channel, catalog: (try? store.calls.catalog()) ?? [])
                    .map { .init(agentID: $0.id, address: $0.address, canAdd: $0.canAdd, guidance: $0.guidance) }
            } else { hints = [] }
            let participantIdentities = (summary?.participants ?? []).map(ChatAuthorIdentity.init)
                + (metadata?.metadata[message.id]?.threadSummary?.lastParticipants ?? []).map(\.identity)
            let hasAttachments = !message.deleted && !message.attachments.isEmpty
            let presentations = mediaActions?.attachmentPresentations(message: message) ?? [:]
            // The legacy attachment container adds padding even without files.
            // Capture its presence, not raw limit changes that leave it unchanged.
            let attachmentsAvailable = !message.deleted && ownerAttachmentsAvailable(message.attachmentOwner)
            // Highlighting matches rendered text, including mentions split by
            // Markdown. Reuse the renderer's bounded cache instead of reparsing.
            let renderedText = message.text.contains("@") ? ChatMentionText.attributed(message.text, addresses: []).string : ""
            visuals.append(.init(selected: selectedID == message.id || model.revealMessageID == message.id,
                avatars: ([ChatAuthorIdentity(message)] + participantIdentities).map(avatar), avatarAccess: avatarAccess,
                attachmentPreviews: hasAttachments ? manager?.cachedPreviews(message) ?? [:] : [:],
                attachmentEpoch: hasAttachments ? service.attachmentEpoch : 0,
                metadataTicket: metadata?.versions[message.id]?.ticket, metadataHead: metadata?.versions[message.id]?.head,
                attachmentOperations: presentations.mapValues(\.operation)))
            return .init(message: message, author: name,
                authorTooltip: (agent?.address.map { "@\($0) · " } ?? "") + attribution.title + " · " + attribution.ownerTooltip,
                addresses: Set(mentionable.map(\.handle) + (model.isDM ? [] : agents.compactMap(\.address)))
                    .filter { !ChatMentions.ranges($0, in: renderedText).isEmpty }.sorted(),
                replyToText: message.inReplyToMessageId.map { id in model.message(id).map { $0.deleted ? "Message deleted" : String($0.text.prefix(90)) } ?? "original message" },
                replySummary: summary, replyCount: feed.replies[message.id, default: 0],
                unreadReplyCount: feed.unreadReplyCounts[message.id, default: 0], requestCount: root == nil ? feed.requests[message.id, default: 0] : 0,
                editing: edit, confirmation: confirmation(model, message: message.id, root: root),
                actions: .init(reply: message.hasFixed && (!message.deleted || model.isDM) && message.localState == nil,
                    edit: model.canEdit(message) && editing == nil, delete: model.canDelete(message),
                    retry: !archived && model.canRetry(message), save: !archived && model.canEdit(message),
                    recoverEdit: editing == nil, copyLink: !model.isDM && message.seq != nil ? ChatMessageLink(key: model.key, message: message).url?.absoluteString : nil),
                metadata: b1Value, sources: sourceValues, membershipHints: hints,
                attachments: .init(limits: hasAttachments ? manager?.limits(for: message.attachmentOwner) : nil,
                    available: attachmentsAvailable,
                    availableFileIDs: Set(message.attachments.filter { manager?.stamp(owner: message.attachmentOwner, message: message, file: $0) != nil }.map(\.id)),
                    pauseReason: hasAttachments ? manager?.pauseReason(owner: message.attachmentOwner) : nil,
                    problems: presentations.compactMapValues(\.problem),
                    busyFileIDs: Set(presentations.filter { $0.value.operation.busy }.map(\.key))),
                bodyAddresses: !message.deleted && (message.hasMutable || message.localState != nil)
                    ? mentionable.map(\.handle) + (model.isDM ? [] : agents.compactMap(\.address)) : nil,
                sourcesExpanded: mediaActions?.sourcePresentation(messageID: message.id).expanded ?? false,
                sourceProblem: mediaActions?.sourcePresentation(messageID: message.id).problem)
        }
        func name(_ account: String?) -> String { account.flatMap { id in members.first { $0.accountId == id }?.name } ?? "a former member" }
        let requests: [Snapshot.Request] = root == nil ? [] : model.threadRequests.filter { card in !statuses.contains { $0.id == card.id } }.map { card in
            .init(id: card.id, agentName: card.agentName, initiatorAccountID: card.initiatorAccountId, ownerAccountID: card.ownerAccountId,
                  state: card.state.rawValue, publication: card.publication, publishReason: card.publishReason, cause: card.cause,
                  title: "\(name(card.initiatorAccountId)) asked \(card.agentName) (\(name(card.ownerAccountId))'s agent)",
                  stateWord: card.stateWord, help: card.state.meaning ?? card.state.rawValue,
                  canOpenRequest: ownerModel != nil, canOpenSession: ownerModel?.canOpenSession(card.id) ?? false,
                  problem: mediaActions?.requestProblem(requestID: card.id))
        }
        let position = model.positions[root ?? ""] ?? ChatScrollPosition()
        func paneTarget(_ id: String?) -> String? {
            guard let id else { return nil }
            if messages.contains(where: { $0.id == id }) { return id }
            // Keep unknown targets pending, but a target known to belong to
            // another pane must not cancel this pane's navigation/restoration.
            guard let message = model.message(id) else { return id }
            let belongs = root == nil ? message.threadRootId == nil : message.id == root || message.threadRootId == root
            return belongs ? id : nil
        }
        return .init(conversation: conversation, epoch: epoch, messages: contents, visuals: visuals, requests: requests,
            threadSummary: root.map { id in
                (summaries ? metadata?.metadata[id]?.threadSummary?.label : nil)
                    ?? ChatReplySummary(messages: messages.filter { $0.threadRootId == id }, complete: !model.threadHasEarlier).label
            }, members: members, mentionable: mentionable.map { .init(account: $0.account, handle: $0.handle) }, me: me, style: style,
            state: .init(isDM: model.isDM, archived: archived, hasOlder: root == nil ? feed.hasOlder : model.threadHasEarlier,
                earlierUnread: root == nil && feed.earlierUnread, unreadID: root == nil ? feed.unreadID : model.threadUnreadID,
                searching: model.searching, hasNavigationReturn: model.hasNavigationReturn,
                position: .init(position),
                accessibilityLabel: root != nil ? "Thread messages" : model.isDM ? "Direct messages" : "Channel messages",
                readingPositionRevision: model.readingPositionRestored),
            navigation: .init(reveal: paneTarget(model.revealMessageID), editing: editing?.root == root ? editing?.messageId : nil,
                focused: paneTarget(model.focusedMessageID), focusID: model.focusRequest?.id, focusArea: model.focusRequest?.area.rawValue,
                restored: model.readingPositionRestored, revealRequest: model.revealRequest), aliases: aliases,
            today: style.metrics.calendar.startOfDay(for: now), reactorAccounts: reactorAccounts)
    }

    private static func confirmation(_ model: any ChatConversationPresentation, message: String, root: String?) -> Snapshot.Confirmation? {
        guard let confirmation = model.confirmation, let context = confirmation.context,
              context.targetID == "message:\(message)", model.deletionRoot == root else { return nil }
        let phase: Snapshot.Confirmation.Phase
        switch confirmation.phase {
        case .awaiting: phase = .awaiting
        case .executing: phase = .executing
        case .failed(let error): phase = .failed(error)
        default: return nil
        }
        return .init(actionID: context.actionID, phase: phase, title: confirmation.title, consequences: confirmation.consequences,
                     verb: confirmation.verb, cancelTitle: confirmation.cancelTitle, destructive: confirmation.destructive)
    }

    static func style(scale: CGFloat, locale: Locale, calendar: Calendar, increasedContrast: Bool, alwaysShowTime: Bool) -> Snapshot.Style {
        func color(_ value: NSColor) -> Snapshot.Color {
            let rgb = value.usingColorSpace(.deviceRGB) ?? .black
            return .init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
        let theme = Theme.resolved
        return .init(metrics: .init(displayFont: NSFont(name: "Onest", size: 14)?.fontName ?? NSFont.systemFont(ofSize: 14).fontName,
            monoFont: NSFont(name: "JetBrainsMono-Regular", size: 12)?.fontName ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName,
            scale: scale, locale: locale, calendar: calendar), colors: [
                "surface": color(theme.backgroundColor), "foreground": color(theme.foregroundColor),
                "chrome": color(theme.chromeBackgroundColor), "hover": color(NSColor(theme.chromeHover)),
                "hairline": color(NSColor(theme.chromeHairline)), "separator": color(NSColor(theme.chromeSeparator)),
                "secondary": color(NSColor(ChatAppearance.secondary)), "accent": color(NSColor(ChatAppearance.accent)),
                "attention": color(NSColor(ChatAppearance.attention)), "success": color(NSColor(ChatAppearance.success)),
                "failure": color(NSColor(ChatAppearance.failure)), "border": color(NSColor(ChatAppearance.border)),
                "systemAccent": color(.controlAccentColor)
            ], appearance: NSApp?.effectiveAppearance.name.rawValue ?? "", increasedContrast: increasedContrast,
            alwaysShowTime: alwaysShowTime)
    }
}
