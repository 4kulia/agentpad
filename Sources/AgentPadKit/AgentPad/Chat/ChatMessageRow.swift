import AppKit
import SwiftUI

/// One message, with discoverable hover actions and the same context menu.
struct ChatMessageRow: View {
    let model: any ChatConversationPresentation
    let message: ChatMessage
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    let replies: Int
    /// F5: requests to agents in its thread.
    var requests = 0
    var inThread = false
    var startsGroup = true
    var selected = false
    @State private var control = ChatEditorControl()
    @State private var window = WindowBox()
    @FocusState private var actionFocused: Bool
    @FocusState private var replyFocused: Bool
    @AppStorage("chat.ux2.alwaysShowTime") private var alwaysShowTime = false
    private var active: Bool { hovering || toolbarHovering || selected || actionFocused }
    private var identity: ChatAuthorIdentity { ChatAuthorIdentity(message) }
    private var unreadReplies: Int { model.feed.unreadReplyCounts[message.messageId, default: 0] }
    @State private var hovering = false
    @State private var pointerInside = false
    @State private var toolbarHovering = false
    @State private var editSelection = NSRange(location: 0, length: 0)
    private var editRoot: String? { inThread ? model.threadRoot : nil }
    private var editing: ChatChannelModel.Editing? {
        guard model.editing?.messageId == message.messageId, model.editing?.root == editRoot else { return nil }
        return model.editing
    }
    @State private var showingReactions = false

    private var mine: Bool { message.authorAccountId == me }
    private var author: ChatMessageAttribution {
        let owner = members.first { $0.accountId == message.authorAccountId }
        return ChatMessageAttribution(message, ownerName: owner?.name ?? (mine ? "You" : "Former member"), ownerHandle: owner?.handle,
            catalogAgentName: ChatOrgCurrent.shared.model?.agents(in: message.channelId).first { $0.agentId == message.authorAgentId }?.name)
    }

    private var displayName: String {
        if message.authorAgentId != nil { return message.authorAgentName ?? ChatOrgCurrent.shared.model?.agents(in: message.channelId).first { $0.agentId == message.authorAgentId }?.name ?? "Agent" }
        return author.title
    }
    private var tooltip: String {
        let address = ChatOrgCurrent.shared.model?.agents(in: message.channelId).first { $0.agentId == message.authorAgentId }?.address
        return (address.map { "@\($0) · " } ?? "") + author.title + " · " + author.ownerTooltip
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if startsGroup { ChatAvatar(identity: identity, name: displayName, key: model.key) }
                else { timestamp.font(Theme.display(9)).padding(.top, 3) }
            }.frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                if startsGroup {
                    HStack(spacing: 7) {
                        Text(verbatim: displayName).font(Theme.display(inThread ? 12 : 13, weight: .semibold)).help(tooltip)
                        if identity.isBot { ChatBotBadge() }
                        timestamp.font(Theme.display(9))
                    }.frame(minHeight: 19, alignment: .leading)
                }
                if editing != nil && !message.deleted { editor } else { body(of: message) }
                if !message.deleted, let attachments = model.service.attachments(model.key), attachments.limits(for: message.attachmentOwner) != nil {
                    ChatMessageAttachments(manager: attachments, message: message, inThread: inThread)
                }
                if message.editedAt != nil && !message.deleted { Text("edited").font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary) }
                marks
                if let confirmation = model.confirmation, confirmation.context?.targetID == "message:\(message.id)",
                   model.deletionRoot == editRoot {
                    InlineConfirmation(coordinator: confirmation)
                }
                if !message.deleted, let b1 = model.b1 {
                    if b1.state.metadata[message.id] == nil, message.seq != nil,
                       b1.supports("chat.reactions") || b1.supports("chat.pins") || b1.supports("chat.thread_summary") {
                        if let error = b1.state.loadError {
                            HStack { Text(error); Button("Retry") { b1.retryReads() }.buttonStyle(.link) }.font(Theme.display(9))
                        } else { Text("Loading message details…").font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary) }
                    }
                    if b1.supports("chat.pins"), b1.state.metadata[message.id]?.pin != nil {
                        Label("Pinned", systemImage: "pin.fill").font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                    }
                    if b1.supports("chat.pins"), b1.pending(message.id, choice: "pin") { ProgressView().controlSize(.mini) }
                    if b1.supports("chat.reactions"), !(b1.state.metadata[message.id]?.reactions.isEmpty ?? true) || b1.state.intents[message.id]?.isEmpty == false {
                        ChatReactionStrip(b1: b1, message: message.id, members: members).padding(.top, 3)
                    }
                    if let problem = b1.problem(message.id) { Text(problem).font(.caption).foregroundStyle(ChatAppearance.failure) }
                    ForEach((b1.state.intents[message.id] ?? []).filter { $0.error != nil }, id: \.choice) { intent in
                        Text(intent.error ?? "").font(.caption).foregroundStyle(ChatAppearance.failure)
                    }
                }
                if let source = message.inReplyToMessageId {
                    Button("Reply to: \(model.message(source).map { $0.deleted ? "Message deleted" : String($0.text.prefix(90)) } ?? "original message")") {
                        model.openThread(message.threadRootId ?? source)
                    }.buttonStyle(.link).font(Theme.display(10))
                }
                if let channel = model as? ChatChannelModel { ChatSourceProgress(model: channel, source: message.messageId) }
                if !inThread {
                    if let b1 = model.b1, b1.supports("chat.thread_summary"), let summary = b1.state.metadata[message.id]?.threadSummary {
                        if summary.replyCount > 0 {
                            ChatServerReplies(key: model.key, summary: summary, members: members, unreadCount: unreadReplies) { model.openThread(message.id) }
                        } else if unreadReplies > 0 { localReplies }
                    } else { localReplies }
                    if requests > 0 {
                        Button("\(requests) \(requests == 1 ? "request" : "requests") to agents") { model.openThread(message.messageId) }
                            .buttonStyle(.link).font(Theme.display(10))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inThread ? 18 : 24)
        .padding(.top, startsGroup ? 12 : 3).padding(.bottom, startsGroup ? 7 : 3)
        .background(active ? Theme.chromeHover : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(ChatAppearance.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            pointerInside = inside
            if inside { hovering = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if !pointerInside { hovering = false } } }
        }
        .overlay(alignment: .topTrailing) {
            if active && editing == nil { hoverActions.padding(.trailing, inThread ? 8 : 20).offset(y: -12).onHover { toolbarHovering = $0 } }
        }
        .contextMenu { menu }
        .popover(isPresented: $showingReactions) {
            if let b1 = model.b1, b1.supports("chat.reactions"), b1.state.accessible { ChatReactionPicker(b1: b1, message: message.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayName)\(identity.isBot ? ", BOT" : ""), \(fullTime)")
        .background(WindowReader(box: window))
        .onChange(of: message) { old, new in
            if let announcement = ChatAccessibility.delivery(from: old, to: new) {
                ChatAccessibility.announce(announcement, in: window.view)
            }
        }
        .onChange(of: message.deleted) { _, deleted in
            if deleted {
                if editing != nil { model.cancelEditing() }
            }
        }
    }

    private var fullTime: String {
        guard let date = ChatFeedLayout.date(message.createdAt) else { return message.createdAt }
        return date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
    }
    private var timestamp: some View {
        Text(ChatFeedLayout.date(message.createdAt)?.formatted(date: .omitted, time: .shortened) ?? "")
            .monospacedDigit().foregroundStyle(ChatAppearance.secondary).opacity(active || alwaysShowTime ? 1 : 0)
            .help(fullTime).accessibilityHidden(true)
    }
    @ViewBuilder private var localReplies: some View {
        if let summary = model.feed.replySummaries[message.messageId], summary.count > 0 { replyButton(summary) }
    }

    private func replyButton(_ summary: ChatReplySummary) -> some View {
        Button { model.openThread(message.messageId) } label: {
            HStack(spacing: 8) {
                HStack(spacing: -4) {
                    ForEach(summary.participants) { participant in
                        ChatAvatar(identity: ChatAuthorIdentity(participant),
                                   name: members.first { $0.accountId == participant.authorAccountId }?.name ?? "?", size: 21, key: model.key)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChatAppearance.surface, lineWidth: 2))
                    }
                }
                Text(summary.label).font(Theme.display(11, weight: .medium)).foregroundStyle(ChatAppearance.accent)
                ChatUnreadReplyBadge(count: unreadReplies)
                if let date = summary.latest.flatMap({ ChatFeedLayout.date($0.createdAt) }) {
                    Text(date.formatted(date: .omitted, time: .shortened)).font(Theme.display(9)).foregroundStyle(ChatAppearance.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(ChatAppearance.accent)
            }.padding(.vertical, 5)
        }.buttonStyle(.plain).help(summary.complete ? "Open thread" : "Loaded replies · more may exist")
            .accessibilityLabel("\(summary.label)\(unreadReplies > 0 ? ", \(unreadReplies) new" : ""), open thread")
            .focusable(selected || replyFocused)
            .focused($replyFocused)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(replyFocused ? ChatAppearance.accent : .clear, lineWidth: 2))
            .onChange(of: model.focusedMessageID, initial: true) { _, id in
                if id == message.id && model.threadRoot == nil { replyFocused = true }
            }
    }

    @ViewBuilder
    private var marks: some View {
        switch message.localState {
        case .sending:
            Text(message.attachments.isEmpty ? "sending…" : (model.service.attachments(model.key)?.pauseReason(owner: message.attachmentOwner) ?? "sending…"))
                .foregroundStyle(.secondary).font(.caption)
            if model.isDM {
                Button("Don't send") { model.discard(message) }.buttonStyle(.link).font(.caption)
            }
        case .failed:
            Text("not sent: \(ChatChannelModel.reason(message.localError))").foregroundStyle(ChatAppearance.failure).font(.caption)
            if !archived && model.canRetry(message) {
                Button("Retry") { model.retry(message) }.buttonStyle(.link).font(.caption)
            }
            Button("Delete") { model.discard(message) }.buttonStyle(.link).font(.caption)
        case nil:
            if let local = message.localEdit, local.state == "saving" {
                Text(local.kind == "delete" ? "deleting…" : "saving…").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    @ViewBuilder
    private func body(of message: ChatMessage) -> some View {
        if message.deleted {
            Text("Message deleted").italic().foregroundStyle(.secondary)
        } else if !message.hasMutable && message.localState == nil {
            Text("Loading…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ChatMentionText(markdown: message.attachmentDisplayText(available: model.service.attachments(model.key)?.stamp(owner: message.attachmentOwner) != nil), addresses: mentionable.map(\.handle)
                    + (model.isDM ? [] : ChatOrgCurrent.shared.model?.agents(in: message.channelId).compactMap(\.address) ?? []), fontSize: inThread ? 13 : 14)
                if let channel = model as? ChatChannelModel { ChatAgentMembershipHint(model: channel, text: message.text) }
                if message.stale != nil { Text("updating…").foregroundStyle(.secondary).font(.caption) }
            }
        }
        // An edit or deletion that did not go — refused, dropped or held by the
        // queue: its text kept, again or away (review F3c-1).
        if let local = message.localEdit, local.state == "failed", editing == nil, !message.deleted {
            HStack {
                Text(local.error == "revision_conflict" ? "It was changed elsewhere: this is the current version."
                     : (local.kind == "delete" ? "Not deleted: " : "Not changed: ") + ChatChannelModel.reason(local.error))
                    .foregroundStyle(ChatAppearance.attention).font(.caption)
                if local.kind == "edit" {
                    // Again from the version shown now: its revision is the one expected. In an
                    // archived channel it opens to read and copy; Save stays off (review F3d-3).
                    Button("Edit again") { model.beginEditing(message, root: editRoot, recovering: true) }
                        .disabled(model.editing != nil)
                        .buttonStyle(.link).font(.caption)
                    Button("Copy") {
                        guard let current = model.message(message.id)?.localEdit else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(current.text ?? "", forType: .string)
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Button("Discard") { model.discardEdit(message) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChatFormattingBar(control: control)
            ChatMentionEditor(text: Binding(get: { editing?.text ?? "" }, set: { model.editing?.text = $0 }),
                              selection: $editSelection, candidates: [], autofocus: true, control: control, accessibilityName: "Edit message") { code, modifiers in
                switch ChatEditingKey.action(code: code, modifiers: modifiers) {
                case .cancel: model.cancelEditing(); return true
                case .save: if canSave { save() }; return true
                case .native: return false
                }
            }
                .onAppear { editSelection = NSRange(location: ((editing?.text ?? "") as NSString).length, length: 0) }
                .frame(minHeight: 60, maxHeight: 160)
                .accessibilityLabel("Edit message")
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(control.focused ? ChatAppearance.accent : ChatAppearance.border, lineWidth: control.focused ? 2 : 1))
            HStack {
                if message.loading { Text("Loading the current message…").foregroundStyle(ChatAppearance.secondary).font(.caption) }
                if let problem = editing?.problem { Text(problem).foregroundStyle(ChatAppearance.failure).font(.caption) }
                Spacer()
                if archived { Text(model.isDM ? "Read-only: it can't be changed" : "Archived: it can't be changed").foregroundStyle(.secondary).font(.caption) }
                Button("Cancel") { model.cancelEditing() }
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    /// Archived, or a change of it still on its way: the text stays, Save waits (review F3b-2, F3b-p2-5).
    private var canSave: Bool { !archived && model.canEdit(message) }

    private func save() {
        guard editing != nil, canSave else { return }
        // Closed only once it went: refused here, the text stays with why (review F3-p2-2).
        model.saveEditing(members: mentionable)
    }

    private var canReply: Bool { message.hasFixed && (!message.deleted || model.isDM) && message.localState == nil }
    private var canDelete: Bool { model.canDelete(message) }

    @ViewBuilder
    private var hoverActions: some View {
        if canReply || canDelete {
            HStack(spacing: 2) {
                if let b1 = model.b1, b1.supports("chat.reactions"), !message.deleted {
                    ChatIconButton(title: "Add reaction", symbol: "face.smiling") { showingReactions = true }.disabled(!b1.canChange)
                }
                if canReply { ChatIconButton(title: "Reply in thread", symbol: "arrowshape.turn.up.left") { model.openThread(message.threadRootId ?? message.messageId) } }
                if model.canEdit(message) {
                    ChatIconButton(title: "Edit message", symbol: "pencil") { model.beginEditing(message, root: editRoot) }.disabled(model.editing != nil)
                }
                if canDelete { ChatIconButton(title: "Delete message…", symbol: "trash") { model.requestDelete(message, root: editRoot) } }
                Menu { menu } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More message actions")
                    .accessibilityLabel("More message actions").chatFocusRing()
            }
            .focused($actionFocused).padding(3)
            .background(ChatAppearance.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeForeground.opacity(0.18)))
        }
    }

    @ViewBuilder
    private var menu: some View {
        if message.hasFixed, !message.deleted || model.isDM {
            if let b1 = model.b1 {
                if b1.supports("chat.reactions") { Button("Add reaction…") { showingReactions = true }.disabled(!b1.canChange) }
                if b1.supports("chat.pins") {
                    Button(b1.state.metadata[message.id]?.pin == nil ? "Pin message" : "Unpin message") { b1.togglePin(message.id) }
                        .disabled(!b1.canChange || b1.pending(message.id, choice: "pin") || b1.state.metadata[message.id] == nil)
                }
            }
            if canReply { Button("Reply in Thread") { model.openThread(message.threadRootId ?? message.messageId) } }
            if !model.isDM, message.seq != nil, let link = ChatMessageLink(key: model.key, message: message).url {
                Button("Copy message link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string) }
            }
            Toggle("Always show time", isOn: $alwaysShowTime)
            Button("Copy text") {
                guard let text = model.copyText(message) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if mine {
                // One change at a time (review F3b-2).
                // An agent's message is edited by nobody (F8); its owner may delete it.
                if !archived, model.canEdit(message) {
                    Button("Edit") { model.beginEditing(message, root: editRoot) }.disabled(model.editing != nil)
                }
                if canDelete { Button("Delete…", role: .destructive) { model.requestDelete(message, root: editRoot) } }
            }
        }
    }

    static func time(_ iso: String) -> String {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parse.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}
