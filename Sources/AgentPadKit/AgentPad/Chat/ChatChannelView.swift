import AppKit
import SwiftUI

/// A channel tab when its channel may be seen (F2 "ready"): the feed, the
/// thread at the right, the composer (DESIGN-F3). Text is native
/// (`ChatMarkdownText`); a link opens only through `chatLinkTarget`.
struct ChatChannelView: View {
    let card: ChatChannelCard
    let team: String?
    let offline: Bool
    let key: ChatOrgKey
    @State private var model: ChatChannelModel?
    @State private var ownerModel: ChatChannelOwnerModel?
    @State private var showingAgents = false
    private var org = ChatOrgCurrent.shared
    private var service = ChatService.shared

    init(card: ChatChannelCard, team: String?, offline: Bool, key: ChatOrgKey) {
        self.card = card
        self.team = team
        self.offline = offline
        self.key = key
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let ownerModel { ChatChannelOwnerPanel(model: ownerModel) }
            if let model {
                HSplitView {
                    VStack(spacing: 0) {
                        ChatFeedView(model: model, members: members, mentionable: mentionable, me: key.accountId, archived: card.archived)
                        Divider()
                        if !card.archived { ChatAskStrip(model: model, agents: agents) }
                        composer(model, root: nil)
                    }
                    .frame(minWidth: 320)
                    if let root = model.threadRoot {
                        ChatThreadView(model: model, root: root, members: members, mentionable: mentionable, me: key.accountId, archived: card.archived, ownerModel: ownerModel) {
                            composer(model, root: root)
                        }
                        .frame(minWidth: 260, idealWidth: 340)
                    }
                }
            } else {
                Spacer()
            }
        }
        .environment(\.openURL, OpenURLAction { ChatMarkdownText.open($0) })
        .task(id: "\(key.orgId)|\(card.channelId)") {
            guard let store = service.orgSessions[key]?.store else { return }
            let made = ChatChannelModel(key: key, channel: card.channelId)
            made.follow(store)
            model = made
            ownerModel = ChatChannelOwnerModel(service: service, key: key, channel: card.channelId)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("#\(card.name)").font(.headline)
            if let team { Text(team).foregroundStyle(.secondary) }
            Spacer()
            if service.supports("chat.channel_ux1", key: key) {
                Button("Agents") { showingAgents.toggle() }
                    .popover(isPresented: $showingAgents) { ChatChannelTrustView(key: key, channel: card.channelId, agents: agents) }
            }
            if card.archived { Text("Archived: read only").foregroundStyle(.orange) }
            if offline { Text("Offline").foregroundStyle(.secondary) }
            if service.orgSessions[key]?.pausedChannels.contains(card.channelId) == true {
                Text("No live updates: too many open channels").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// F5: the channel's agents seen now (none without the server's agents).
    private var agents: [ChatChannelAgent] { org.model?.agents(in: card.channelId) ?? [] }

    /// Names: the organization's members (shown only while its model may show them).
    private var members: [ChatOrgView.Member] { org.model?.members ?? [] }
    /// Who `@handle` may mention: members of the channel's team only — the
    /// server refuses any other (review F3-p2-4).
    private var mentionable: [(account: String, handle: String)] {
        ChatChannelModel.mentionable(members, team: org.model?.channelTeams.first { $0.teamId == card.teamId }?.members ?? [])
    }

    @ViewBuilder
    private func composer(_ model: ChatChannelModel, root: String?) -> some View {
        if card.archived {
            Text("The channel is archived: nothing can be posted.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
        } else {
            if service.supports("chat.channel_ux1", key: key) {
                ChatUX1Composer(model: model, root: root, members: members, mentionable: mentionable, agents: agents)
            } else {
                ChatComposer(model: model, root: root, mentionable: mentionable, agents: agents)
            }
        }
    }
}

/// The channel's root messages, oldest at the top.
struct ChatFeedView: View {
    let model: ChatChannelModel
    @State var box = WindowBox()
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.feed.hasOlder {
                        Button("Load earlier messages") { model.loadOlder() }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.feed.messages) { message in
                        ChatMessageRow(model: model, message: message, members: members, mentionable: mentionable, me: me,
                                       archived: archived, replies: model.feed.replies[message.messageId] ?? 0,
                                       requests: model.feed.requests[message.messageId] ?? 0)
                            .id(message.messageId)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.feed.messages.last?.messageId) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
                readIfLooking()
            }
            .onChange(of: model.editing?.messageId) { _, id in
                if let id, model.editing?.root == nil { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let last = model.feed.messages.last?.messageId { proxy.scrollTo(last, anchor: .bottom) }
                // F4: this feed shows while its window is key (review F4-B).
                ChatNotifications.show(place, view: box.id) { [box] in box.shown }
                readIfLooking()
            }
            .onDisappear { ChatNotifications.hide(place, view: box.id) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readIfLooking() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in readIfLooking() }
        }
        .background(WindowReader(box: box))
    }
}

extension ChatFeedView {
    var place: String { "c:\(model.channel)" }
    /// Read only while the user looks at it: app in front, its window key (DESIGN-F4, review F4-B).
    fileprivate func readIfLooking() { if ChatNotifications.isLooking(place) { model.markRead() } }
}

/// A thread at the right: its root, then the replies.
struct ChatThreadView<Composer: View>: View {
    let model: ChatChannelModel
    let root: String
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    var ownerModel: ChatChannelOwnerModel? = nil
    @ViewBuilder let composer: () -> Composer
    @State private var box = WindowBox()
    @State private var shownRoot: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Thread").font(.headline)
                Spacer()
                Button { model.openThread(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.threadHasEarlier {
                            Button("Earlier replies") { model.earlierReplies() }.buttonStyle(.link)
                        }
                        ForEach(model.thread) { message in
                            ChatMessageRow(model: model, message: message, members: members, mentionable: mentionable, me: me,
                                           archived: archived, replies: 0, inThread: true)
                            .id(message.messageId)
                        }
                        ForEach(model.threadRequests) { card in ChatRequestCardRow(card: card, members: members, ownerModel: ownerModel) }
                    }
                    .padding(10)
                }
                .onChange(of: model.editing?.messageId) { _, id in
                    if let id, model.editing?.root == root { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Divider()
            composer()
        }
        .background(WindowReader(box: box))
        // F4: this thread's panel shows while its window is key (review F4-B); read
        // when it opens, when a reply comes and when its window comes back in front.
        .task(id: root) {
            // This panel's own entry only: another window's thread stays (review F4b-5).
            if let shown = shownRoot { ChatNotifications.hide("t:\(shown)", view: box.id) }
            shownRoot = root
            ChatNotifications.show("t:\(root)", view: box.id) { [box] in box.shown }
            readIfLooking()
        }
        .onChange(of: model.thread.last?.messageId) { _, _ in readIfLooking() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readIfLooking() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in readIfLooking() }
        .onDisappear { ChatNotifications.hide("t:\(root)", view: box.id) }
    }

    private func readIfLooking() { if ChatNotifications.isLooking("t:\(root)") { model.markThreadRead(root) } }
}

/// The window a SwiftUI view is in: the view shows to the user while that
/// window is key and visible (F4, review F4-B).
@MainActor
final class WindowBox {
    let id = UUID()
    weak var view: NSView?
    var window: NSWindow? { view?.window }
    /// Shown to the user: its window key and visible, and the view itself not
    /// hidden — a tab not selected hides its views (review F4b-1).
    var shown: Bool {
        guard let view, let window = view.window else { return false }
        return window.isKeyWindow && window.isVisible && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }
}

struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    final class Reader: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.view = self
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.box = box
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.box = box
        box.view = view
    }
}

/// One message, with discoverable hover actions and the same context menu.
struct ChatMessageRow: View {
    let model: ChatChannelModel
    let message: ChatMessage
    let members: [ChatOrgView.Member]
    let mentionable: [(account: String, handle: String)]
    let me: String
    let archived: Bool
    let replies: Int
    /// F5: requests to agents in its thread.
    var requests = 0
    var inThread = false
    @State private var hovering = false
    @State private var editSelection = NSRange(location: 0, length: 0)
    private var editRoot: String? { inThread ? model.threadRoot : nil }
    private var editing: ChatChannelModel.Editing? {
        guard model.editing?.messageId == message.messageId, model.editing?.root == editRoot else { return nil }
        return model.editing
    }
    /// The revision the deletion's confirmation was opened on.
    @State private var deleting: Int?

    private var mine: Bool { message.authorAccountId == me }
    private var author: ChatMessageAttribution {
        let owner = members.first { $0.accountId == message.authorAccountId }
        return ChatMessageAttribution(message, ownerName: owner?.name ?? (mine ? "You" : "Former member"), ownerHandle: owner?.handle,
            catalogAgentName: ChatOrgCurrent.shared.model?.agents(in: message.channelId).first { $0.agentId == message.authorAgentId }?.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: author.title).fontWeight(.semibold).help(author.ownerTooltip)
                if let id = author.publishedAgentId {
                    Text("Agent").font(.caption2).foregroundStyle(.secondary).help("Published agent · \(id)")
                }
                Text(Self.time(message.createdAt)).foregroundStyle(.secondary).font(.caption)
                if message.editedAt != nil, !message.deleted { Text("edited").foregroundStyle(.secondary).font(.caption) }
                marks
            }
            body(of: message)
            if let source = message.inReplyToMessageId {
                Button("Reply to: \(model.message(source).map { $0.deleted ? "Message deleted" : String($0.text.prefix(90)) } ?? "original message")") {
                    model.openThread(message.threadRootId ?? source)
                }.buttonStyle(.link).font(.caption)
            }
            ChatSourceProgress(model: model, source: message.messageId)
            if editing != nil, !message.deleted {
                editor
            }
            if !inThread, replies > 0 || message.threadRootId == nil && message.hasFixed {
                if replies > 0 {
                    Button("\(replies) \(replies == 1 ? "reply" : "replies")") { model.openThread(message.messageId) }
                        .buttonStyle(.link).font(.caption)
                }
                if requests > 0 {
                    Button("\(requests) \(requests == 1 ? "request" : "requests") to agents") { model.openThread(message.messageId) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(hovering ? Color.secondary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering, editing == nil { hoverActions }
        }
        .contextMenu { menu }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil && !message.deleted },
                                                                          set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let revision = deleting { model.delete(message, revision: revision) }
                deleting = nil
            }
        } message: {
            Text("Copies already in the context of a running agent stay.")
        }
        // Deleted: the editor and its text go too (review F3-p1-2).
        .onChange(of: message.deleted) { _, deleted in
            if deleted {
                if editing != nil { model.cancelEditing() }
                deleting = nil
            }
        }
    }

    @ViewBuilder
    private var marks: some View {
        switch message.localState {
        case .sending: Text("sending…").foregroundStyle(.secondary).font(.caption)
        case .failed:
            Text("not sent: \(ChatChannelModel.reason(message.localError))").foregroundStyle(.red).font(.caption)
            Button("Retry") { model.retry(message) }.buttonStyle(.link).font(.caption)
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
                ChatMentionText(markdown: message.text, addresses: mentionable.map(\.handle)
                    + (ChatOrgCurrent.shared.model?.agents(in: message.channelId).compactMap(\.address) ?? []))
                if message.stale != nil { Text("updating…").foregroundStyle(.secondary).font(.caption) }
            }
        }
        // An edit or deletion that did not go — refused, dropped or held by the
        // queue: its text kept, again or away (review F3c-1).
        if let local = message.localEdit, local.state == "failed", editing == nil, !message.deleted {
            HStack {
                Text(local.error == "revision_conflict" ? "It was changed elsewhere: this is the current version."
                     : (local.kind == "delete" ? "Not deleted: " : "Not changed: ") + ChatChannelModel.reason(local.error))
                    .foregroundStyle(.orange).font(.caption)
                if local.kind == "edit" {
                    // Again from the version shown now: its revision is the one expected. In an
                    // archived channel it opens to read and copy; Save stays off (review F3d-3).
                    Button("Edit again") { model.beginEditing(message, root: editRoot, recovering: true) }
                        .disabled(model.editing != nil)
                        .buttonStyle(.link).font(.caption)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(local.text ?? "", forType: .string)
                    }
                    .buttonStyle(.link).font(.caption)
                }
                Button("Discard") { model.discardEdit(message) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing) {
            ChatMentionEditor(text: Binding(get: { editing?.text ?? "" }, set: { model.editing?.text = $0 }),
                              selection: $editSelection, candidates: [], autofocus: true) { code, modifiers in
                if code == 53 { model.cancelEditing(); return true }
                if code == 36, modifiers.contains(.command), canSave { save(); return true }
                return false
            }
                .onAppear { editSelection = NSRange(location: ((editing?.text ?? "") as NSString).length, length: 0) }
                .frame(minHeight: 60, maxHeight: 160)
                .border(Color.secondary.opacity(0.3))
            HStack {
                if let problem = editing?.problem { Text(problem).foregroundStyle(.red).font(.caption) }
                Spacer()
                if archived { Text("Archived: it can't be changed").foregroundStyle(.secondary).font(.caption) }
                Button("Cancel") { model.cancelEditing() }
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
    }

    /// Archived, or a change of it still on its way: the text stays, Save waits (review F3b-2, F3b-p2-5).
    private var canSave: Bool { !archived && model.canEdit(message) }

    private func save() {
        guard let now = editing, canSave else { return }
        // Closed only once it went: refused here, the text stays with why (review F3-p2-2).
        if let problem = model.edit(message, to: now.text, revision: now.revision, members: mentionable) {
            model.editing?.problem = problem
        } else {
            model.cancelEditing()
        }
    }

    private var canReply: Bool { message.hasFixed && !message.deleted && message.localState == nil }
    private var canDelete: Bool { mine && message.hasFixed && !message.deleted && !message.changing && message.localState == nil }

    @ViewBuilder
    private var hoverActions: some View {
        if canReply || canDelete {
            HStack(spacing: 8) {
                if canReply {
                    Button { model.openThread(message.threadRootId ?? message.messageId) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }.help("Reply in thread")
                }
                if mine, message.authorAgentId == nil, message.authorSessionName == nil, !archived {
                    Button { model.beginEditing(message, root: editRoot) } label: {
                        Label("Edit", systemImage: "pencil")
                    }.disabled(!model.canEdit(message) || model.editing != nil).help("Edit message")
                }
                if canDelete {
                    Button(role: .destructive) { deleting = message.revision } label: {
                        Label("Delete", systemImage: "trash")
                    }.help("Delete message…")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder
    private var menu: some View {
        if message.hasFixed, !message.deleted {
            if canReply { Button("Reply in Thread") { model.openThread(message.threadRootId ?? message.messageId) } }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            if mine {
                // One change at a time (review F3b-2).
                // An agent's message is edited by nobody (F8); its owner may delete it.
                if !archived, model.canEdit(message) {
                    Button("Edit") { model.beginEditing(message, root: editRoot) }.disabled(model.editing != nil)
                }
                if canDelete { Button("Delete…", role: .destructive) { deleting = message.revision } }
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

/// The text of a new message: ⌘↩ sends; the draft is kept per channel
/// and per thread, half a second after each change.
struct ChatComposer: View {
    let model: ChatChannelModel
    let root: String?
    let mentionable: [(account: String, handle: String)]
    var agents: [ChatChannelAgent] = []
    @State private var text = ""
    @State private var selection = NSRange(location: 0, length: 0)
    /// The thread (or the channel, nil) whose draft `text` is.
    @State private var loaded: String??

    private func send() {
        if model.send(text, root: root, members: mentionable, agents: agents) { text = "" }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChatMentionEditor(text: $text, selection: $selection, candidates: []) { code, modifiers in
                if code == 36, modifiers.contains(.command) { send(); return true }
                if code == 126, modifiers.intersection([.command, .control, .option, .shift]).isEmpty {
                    return model.editLastMessage(root: root, composerText: text)
                }
                return false
            }
            .frame(minHeight: 44, maxHeight: 140)
            HStack {
                if let problem = model.problem { Text(problem).foregroundStyle(.red).font(.caption) }
                Spacer()
                Text("\(text.utf8.count) / \(ChatChannelModel.maxBytes) bytes")
                    .foregroundStyle(text.utf8.count > ChatChannelModel.maxBytes ? .red : .secondary)
                    .font(.caption)
                Button("Send") { send() }
                    .disabled(ChatChannelModel.textProblem(text) != nil)
            }
        }
        .padding(8)
        .task(id: root ?? "") {
            loaded = .some(root)
            text = model.draft(root: root)
        }
        // Every change is written at once — no save left pending to lose on a
        // thread's switch or close (review F3b-1); `saveDraft` writes only
        // while the channel may be seen (review F3-p1-3).
        .onChange(of: text) { _, now in
            if case .some(let draftRoot) = loaded, draftRoot == root { model.saveDraft(now, root: draftRoot) }
        }
    }
}

/// A request to an agent in its thread (DESIGN-F5 §3): the agent, who
/// asked, and where it is — the same for every member of the team.
struct ChatRequestCardRow: View {
    let card: ChatChannelRequests.Card
    let members: [ChatOrgView.Member]
    var ownerModel: ChatChannelOwnerModel? = nil
    @State private var problem: String?

    private func name(_ account: String?) -> String {
        account.flatMap { id in members.first { $0.accountId == id }?.name } ?? "a former member"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(name(card.initiatorAccountId)) asked \(card.agentName) (\(name(card.ownerAccountId))'s agent)").font(.callout)
            Text(card.stateWord).font(.caption).foregroundStyle(card.publication == "publish_failed" ? .orange : .secondary)
            if let ownerModel, ownerModel.canOpenSession(card.requestId) {
                Button("Open Session") { problem = ownerModel.openSession(card.requestId) }.font(.caption)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .help(card.state.meaning ?? card.state.rawValue)
    }
}
