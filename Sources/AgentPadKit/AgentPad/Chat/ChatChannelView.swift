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
    @State private var showingAgents = false
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
        GeometryReader { geometry in
            if let model {
                let narrow = geometry.size.width < 784
                HSplitView {
                    if !narrow || model.threadRoot == nil {
                        VStack(spacing: 0) {
                            header(model)
                            if let ownerModel { ChatChannelOwnerPanel(model: ownerModel) }
                            if model.searching { ChatLocalSearch(model: model) }
                            ChatTimelineView(model: model, root: nil, members: members, mentionable: mentionable,
                                             me: key.accountId, archived: card.archived, ownerModel: ownerModel)
                            if !card.archived { ChatAskStrip(model: model, agents: agents) }
                            composer(model, root: nil)
                        }.frame(minWidth: narrow ? 0 : 440)
                    }
                    if let root = model.threadRoot {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                if narrow {
                                    ChatIconButton(title: "Back to #\(card.name)", symbol: "chevron.left") { model.openThread(nil) }
                                }
                                Text("Thread").font(Theme.display(14, weight: .semibold))
                                Text("· #\(card.name)").font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                                if narrow { connectionStatus }
                                Spacer(minLength: 0)
                                if narrow && model.hasNavigationReturn {
                                    ChatIconButton(title: "Back to reading", symbol: "arrow.uturn.backward") { model.returnFromNavigation() }
                                }
                                if narrow {
                                    ChatIconButton(title: "Search loaded history (⌘F)", symbol: "magnifyingglass") { model.setSearching(!model.searching) }
                                        .keyboardShortcut("f", modifiers: .command)
                                }
                                ChatIconButton(title: "Close thread", symbol: "xmark") { model.openThread(nil) }
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
                .onChange(of: model.focusRequest) { _, request in
                    if narrow, request?.area == .feed { model.openThread(nil) }
                }
            }
        }
        .background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
        .background(WindowReader(box: window, didAttach: navigatePending))
        .environment(\.openURL, OpenURLAction { ChatMarkdownText.open($0) })
        .onReceive(NotificationCenter.default.publisher(for: .chatMessageNavigation)) { _ in navigatePending() }
        .task(id: "\(key.server)|\(key.accountId)|\(key.orgId)|\(card.channelId)") {
            navigatePending()
        }
        .onChange(of: model?.channel) { _, _ in navigatePending() }
    }

    private func navigatePending() {
        guard let model, let target = ChatMessageNavigation.take(key: key, channel: card.channelId, from: window.view) else { return }
        model.navigate(to: target)
    }

    private func header(_ model: ChatChannelModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("# \(card.name)").font(Theme.display(16, weight: .semibold)).lineLimit(2)
                if let team { Text(team).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary) }
            }
            Spacer(minLength: 0)
            if model.hasNavigationReturn {
                ChatIconButton(title: "Back to reading", symbol: "arrow.uturn.backward") { model.returnFromNavigation() }
            }
            if card.archived { Text("Archived · read only").font(Theme.display(10)).foregroundStyle(ChatAppearance.attention) }
            connectionStatus
            ChatIconButton(title: "Search loaded history (⌘F)", symbol: "magnifyingglass") { model.setSearching(!model.searching) }
                .keyboardShortcut("f", modifiers: .command)
            if service.supports("chat.channel_ux1", key: key) {
                ChatIconButton(title: "Channel agents", symbol: "sparkles") { showingAgents.toggle() }
                    .popover(isPresented: $showingAgents) { ChatChannelTrustView(key: key, channel: card.channelId, agents: agents) }
            }
        }
        .padding(.horizontal, 24).frame(height: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chromeHairline).frame(height: 1) }
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
        guard let view, let window = view.window else { return false }
        return window.isKeyWindow && window.isVisible && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }
}

struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    var didAttach: (() -> Void)? = nil

    final class Reader: NSView {
        var box: WindowBox?
        var didAttach: (() -> Void)?
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
            guard didAttach != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.superview != nil else { return }
                self.didAttach?()
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
