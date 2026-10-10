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
    let conversation: ChatChannelSession
    private var model: ChatChannelModel? {
        guard let model = conversation.model, model.key == key, model.channel == card.channelId else { return nil }
        return model
    }
    private var ownerModel: ChatChannelOwnerModel? { conversation.ownerModel }
    @State private var window = WindowBox()
    private var org = ChatOrgCurrent.shared
    private var service = ChatService.shared

    init(card: ChatChannelCard, team: String?, offline: Bool, key: ChatOrgKey, conversation: ChatChannelSession) {
        self.card = card
        self.team = team
        self.offline = offline
        self.key = key
        self.conversation = conversation
    }

    var body: some View {
        VStack(spacing: 8) {
            // Channel actions keep one host while the content panels change.
            if conversation.confirmation.context?.targetID.hasPrefix("message:") != true,
               conversation.confirmation.context?.targetID.hasPrefix("channel-ask:") != true,
               conversation.confirmation.context?.targetID.hasPrefix("trust:") != true {
                InlineConfirmation(coordinator: conversation.confirmation).padding(.horizontal, 16)
            }
            panels
        }
        .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
        .background(WindowReader(box: window, didAttach: navigatePending))
        .environment(\.openURL, OpenURLAction { ChatMarkdownText.open($0) })
        .onReceive(NotificationCenter.default.publisher(for: .chatMessageNavigation)) { _ in navigatePending() }
        .task(id: "\(key.server)|\(key.accountId)|\(key.orgId)|\(card.channelId)") {
            navigatePending()
        }
        .onChange(of: model?.channel) { _, _ in navigatePending() }
        .onChange(of: model?.threadRoot) { _, _ in
            if conversation.confirmation.context?.targetID.hasPrefix("message:") == true {
                conversation.confirmation.invalidate()
            }
        }
    }

    private var panels: some View {
        GeometryReader { geometry in
            if let model {
                let narrow = geometry.size.width < 784
                let pinsAvailable = model.b1?.supports("chat.pins") == true
                let pinsShown = conversation.pinsShown
                let coversConversation = pinsShown && model.pins.coversConversation(width: geometry.size.width)
                HSplitView {
                    if !coversConversation {
                        conversationPanes(model, narrow: narrow, pinsShown: pinsShown, width: geometry.size.width)
                    }
                    if pinsShown, let b1 = model.b1 {
                        ChatPinnedMessages(b1: b1, model: model, members: members, width: geometry.size.width)
                            .frame(minWidth: coversConversation ? 0 : 340, idealWidth: 400,
                                   maxWidth: coversConversation ? .infinity : 520)
                    }
                }
                .onAppear { model.b1?.showPins(pinsAvailable) }
                .onDisappear { model.b1?.showPins(false) }
                .onChange(of: model.b1.map { ObjectIdentifier($0) }) { _, _ in model.b1?.showPins(pinsAvailable) }
                .onChange(of: pinsAvailable) { _, available in model.b1?.showPins(available) }
                .onChange(of: model.b1?.state.pins) { old, new in
                    model.pins.reconcile(old: ChatPins.ordered(old ?? []), new: ChatPins.ordered(new ?? []))
                }
                .onChange(of: model.focusRequest) { _, request in
                    if narrow, request?.area == .feed { model.openThread(nil) }
                }
            }
        }
    }

    @ViewBuilder private func conversationPanes(_ model: ChatChannelModel, narrow: Bool, pinsShown: Bool, width: Double) -> some View {
        if !narrow || model.threadRoot == nil || pinsShown || conversation.showingAgents {
            VStack(spacing: 0) {
                header(model)
                if conversation.showingAgents {
                    ScrollView { ChatChannelTrustView(key: key, channel: card.channelId, agents: agents, conversation: conversation) }
                } else {
                    if let b1 = model.b1, b1.supports("chat.pins") {
                        ChatPinBanner(b1: b1, model: model, members: members, width: width)
                    }
                    ChatUnreadThreadsBanner(model: model)
                    if let ownerModel { ChatChannelOwnerPanel(model: ownerModel) }
                    if model.searching { ChatLocalSearch(model: model) }
                    ChatTimelineView(model: model, root: nil, members: members, mentionable: mentionable,
                                     me: key.accountId, archived: card.archived, ownerModel: ownerModel)
                    if !card.archived { ChatAskStrip(model: model, agents: agents) }
                    composer(model, root: nil)
                }
            }.frame(minWidth: narrow ? 0 : 440)
        }
        if let root = model.threadRoot, !pinsShown, !conversation.showingAgents {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if narrow {
                        ChatIconButton(title: "Back to #\(card.name)", symbol: "chevron.left") { model.openThread(nil) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thread").font(Theme.display(14, weight: .semibold))
                        if let b1 = model.b1, b1.supports("chat.thread_summary"), let summary = b1.state.metadata[root]?.threadSummary {
                            Text(summary.label).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                        }
                    }
                    Text("· #\(card.name)").font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                    if narrow { connectionStatus }
                    Spacer(minLength: 0)
                    if narrow && model.hasNavigationReturn {
                        ChatIconButton(title: "Back to reading", symbol: "arrow.uturn.backward") { model.returnFromNavigation() }
                    }
                    if narrow {
                        ChatIconButton(title: "Search in this channel (⌘F)", symbol: "magnifyingglass") { NSApp.sendAction(#selector(AppDelegate.handleFind), to: nil, from: nil) }
                            .keyboardShortcut("f", modifiers: .command)
                    }
                    ChatIconButton(title: "Close thread", symbol: "xmark") { model.openThread(nil) }
                    if narrow { pinsButton(model) }
                    ChatIconButton(title: "Mark as read", symbol: "checkmark") { model.markThreadRead(root) }
                }.padding(.horizontal, 18).frame(height: 64)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeHairline).frame(height: 1) }
                if narrow && model.searching { ChatLocalSearch(model: model) }
                ChatTimelineView(model: model, root: root, members: members, mentionable: mentionable,
                                 me: key.accountId, archived: card.archived, ownerModel: ownerModel).id(root)
                composer(model, root: root).id(root)
            }.frame(minWidth: narrow ? 0 : 300, idealWidth: 344, maxWidth: narrow ? .infinity : 480)
                .background(ChatThreadSplitPosition(enabled: !narrow))
        }
    }

    private func navigatePending() {
        guard let model, let target = ChatMessageNavigation.take(key: key, channel: card.channelId, from: window.view) else { return }
        model.pins.close()
        model.navigate(to: target)
    }

    private func header(_ model: ChatChannelModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("# \(card.name)").font(Theme.display(16, weight: .semibold)).lineLimit(2)
                if let team { Text(team).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary) }
            }
            Spacer(minLength: 0)
            if model.pins.returnsToPins {
                ChatIconButton(title: "Back to pinned messages", symbol: "pin.fill") { conversation.togglePins() }
            }
            if model.hasNavigationReturn {
                ChatIconButton(title: "Back to reading", symbol: "arrow.uturn.backward") { model.returnFromNavigation() }
            }
            if card.archived { Text("Archived · read only").font(Theme.display(10)).foregroundStyle(ChatAppearance.attention) }
            connectionStatus
            pinsButton(model)
            ChatIconButton(title: "Mark as read", symbol: "checkmark") { model.markRead() }
            ChatIconButton(title: "Search in this channel (⌘F)", symbol: "magnifyingglass") { NSApp.sendAction(#selector(AppDelegate.handleFind), to: nil, from: nil) }
                .keyboardShortcut("f", modifiers: .command)
            if conversation.showingAgents || service.supports("chat.channel_ux1", key: key) {
                Button(conversation.showingAgents ? "Messages" : "Agents / trust") {
                    model.pins.close()
                    conversation.showingAgents.toggle()
                }
            }
        }
        .padding(.horizontal, 24).frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeHairline).frame(height: 1) }
    }

    @ViewBuilder private func pinsButton(_ model: ChatChannelModel) -> some View {
        if let b1 = model.b1, b1.supports("chat.pins") {
            Button {
                conversation.togglePins()
            } label: {
                Label("Pinned \(b1.state.pins?.count ?? 0)", systemImage: "pin")
                    .font(Theme.display(11, weight: .medium)).lineLimit(1)
            }.buttonStyle(.borderless).chatFocusRing().help("All pinned messages")
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        if offline {
            Label("Offline", systemImage: "network.slash").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                .help("Offline · showing cached messages").accessibilityLabel("Offline, showing cached messages")
        } else if service.orgSessions[key]?.pausedChannels.contains(card.channelId) == true {
            Label("Updates paused", systemImage: "pause.circle").font(Theme.display(10)).foregroundStyle(ChatAppearance.attention)
                .help("No live updates: too many open channels").accessibilityLabel("No live updates: too many open channels")
        }
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
            if let manager = model.service.attachments(model.key) {
                ChatAttachmentDraftStrip(manager: manager, channel: model.channel, root: root)
            }
            Text("The channel is archived: nothing can be posted.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
        } else {
            ChatUX1Composer(model: model, root: root, members: members, mentionable: mentionable, agents: agents)
        }
    }
}

/// The window a SwiftUI view is in: the view shows to the user while that
/// window is key and visible (F4, review F4-B).
@MainActor
final class WindowBox {
    let id = UUID()
    var atBottom = false
    weak var view: NSView?
    var window: NSWindow? { view?.window }
    /// Shown to the user: its window key and visible, and the view itself not
    /// hidden — a tab not selected hides its views (review F4b-1).
    var shown: Bool {
        guard let view else { return false }
        return NavigationPresentationGate.allowsAcknowledgement(view, appActive: true)
    }
}

struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    var didAttach: (() -> Void)? = nil
    var visibilityChanged: ((Bool) -> Void)? = nil

    final class Reader: NSView {
        var box: WindowBox?
        var didAttach: (() -> Void)?
        var visibilityChanged: ((Bool) -> Void)?
        private var lastVisibility: Bool?
        override func viewDidHide() {
            super.viewDidHide()
            attached()
        }
        override func viewDidUnhide() {
            super.viewDidUnhide()
            attached()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attached()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attached()
        }
        func attached() {
            box?.view = self
            guard didAttach != nil || visibilityChanged != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visible = self.window != nil && !self.isHiddenOrHasHiddenAncestor
                if self.lastVisibility != visible {
                    self.lastVisibility = visible
                    self.visibilityChanged?(visible)
                }
                if self.superview != nil { self.didAttach?() }
            }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.box = box
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.box = box
        view.didAttach = didAttach
        view.visibilityChanged = visibilityChanged
        view.attached()
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
            if let ownerModel {
                Button("Open Request…") { RequestTabs.shared.open(card.requestId, scope: .server(OrgKey(ownerModel.key))) }.font(.caption)
            }
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
