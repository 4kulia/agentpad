import AgentPadTelegram
import AppKit
import SwiftUI

/// Capture this before asynchronous search/authorization work. A keyboard
/// command's modifiers must not turn an ordinary conversation route into a tab.
@MainActor enum ConversationOpenIntent {
    static var commandClick: Bool {
        isCommandClick(NSApp?.currentEvent)
    }
    static func isCommandClick(_ event: NSEvent?) -> Bool {
        guard let event,
              [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
        return event.modifierFlags.contains(.command)
    }
}

extension ToolRoute {
    var isConversation: Bool {
        switch self {
        case .directMessage, .directMessageDraft, .telegram: true
        default: false
        }
    }
}

extension TabContent {
    var isConversation: Bool {
        switch self {
        case .channel: true
        case .tool(let route): route.isConversation
        default: false
        }
    }
}

extension Session {
    var channelConversation: ChatChannelSession? { (engine as? ChannelTabEngine)?.conversation }
    var conversationTitle: String {
        if let engine = engine as? ChannelTabEngine {
            if case .ready(let card, _, _) = engine.presentationState { return "# \(card.name)" }
            return engine.presentationState.title
        }
        if let card = tabState?.dmModel?.card { return card.peer.name }
        if let peer = tabState?.dmPeerModel?.person { return peer.name }
        if case .telegram = toolRoute {
            return tabState?.telegramModel?.snapshot.topicInfo?.name ?? tabState?.telegramTopicTitle
                ?? tabState?.telegramRow?.title ?? tabState?.telegramModel?.snapshot.title ?? "Telegram"
        }
        return toolRoute?.title ?? "Conversation"
    }
    var conversationSubtitle: String {
        if let engine = engine as? ChannelTabEngine {
            if let model = channelConversation?.model, let root = model.threadRoot {
                return "\(conversationTitle) · \(model.feed.replies[root] ?? model.thread.count) replies"
            }
            if case .ready(let card, let team, _) = engine.presentationState {
                return (card.archived ? "Channel · read only" : "Channel") + (team.map { " · \($0)" } ?? "")
            }
            return "Channel"
        }
        if case .telegram = toolRoute {
            return "Telegram · \(tabState?.telegramRow?.displayKind ?? "Chat")"
        }
        return tabState?.dmModel?.threadRoot == nil ? "Direct message · only the two of you" : "Thread · direct message"
    }
    var conversationHeaderTitle: String {
        channelConversation?.model?.threadRoot != nil || tabState?.dmModel?.threadRoot != nil ? "Thread" : conversationTitle
    }
    var conversationSymbol: String {
        if channel != nil { return "number" }
        if case .telegram = toolRoute { return "paperplane" }
        return "person.fill"
    }
    var conversationHasBack: Bool {
        channelConversation?.model?.threadRoot != nil || tabState?.dmModel?.threadRoot != nil || {
            if case .telegram(let id) = toolRoute { return id.topic != nil }
            return false
        }()
    }
    var conversationBackTitle: String {
        if case .telegram(let id) = toolRoute, id.topic != nil { return "Back to topics" }
        return "Back to conversation"
    }
    var hasConversationDraft: Bool {
        channelConversation?.model?.hasConversationDraft == true || tabState?.dmModel?.hasConversationDraft == true
            || tabState?.dmPeerModel?.hasConversationDraft == true || tabState?.telegramModel?.draft.isEmpty == false
    }
    func setConversationPopup(_ value: Bool) {
        isConversationPopup = value
        channelConversation?.isPopup = value
        tabState?.isPopup = value
        tabState?.dmModel?.isPopup = value
        tabState?.dmPeerModel?.isPopup = value
    }
    func flushConversationDrafts() throws {
        try channelConversation?.model?.flushConversationDrafts()
        try tabState?.dmModel?.flushConversationDrafts()
        try tabState?.dmPeerModel?.flushConversationDrafts()
    }
    func conversationBack() {
        if let model = channelConversation?.model { model.openThread(nil) }
        else if let model = tabState?.dmModel { model.openThread(nil) }
        else if case .telegram(let id) = toolRoute, let state = tabState {
            TelegramTabs.openTopic(id.root, title: nil, state: state)
        }
    }
}

struct ChatPopupHeader: View {
    @Bindable var coordinator: PopupCoordinator
    let session: Session
    var body: some View {
        HStack(spacing: 12) {
            if coordinator.showConversationPicker || session.conversationHasBack || coordinator.canGoBack {
                Button {
                    if coordinator.showConversationPicker { coordinator.showConversationPicker = false }
                    else if session.conversationHasBack { session.conversationBack() }
                    else { coordinator.back() }
                } label: { Image(systemName: "chevron.left").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).help(session.conversationBackTitle)
                    .accessibilityLabel(session.conversationBackTitle).accessibilityIdentifier("popup-conversation-back")
            } else if let personID = session.tabState?.dmModel?.card?.peer.accountId ?? session.tabState?.dmPeerModel?.person?.accountId {
                ContactAvatar(stableID: personID, name: session.conversationTitle, kind: .person, size: 34)
            } else {
                Image(systemName: session.conversationSymbol).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ChatAppearance.secondary).frame(width: 34)
            }
            Button { coordinator.showConversationPicker.toggle() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(coordinator.showConversationPicker ? "Switch conversation" : session.conversationHeaderTitle)
                            .font(Theme.display(15, weight: .semibold)).lineLimit(1)
                        if !coordinator.showConversationPicker {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ChatAppearance.secondary)
                        }
                    }
                    Text(coordinator.showConversationPicker ? "Recent conversations" : session.conversationSubtitle)
                        .font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Switch conversation")
                .accessibilityIdentifier("popup-conversation-title")
            if !coordinator.showConversationPicker {
            Menu { conversationActions } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 20).help("Conversation actions")
            Button { coordinator.promoteConversation() } label: {
                Label("Open as tab", systemImage: "arrow.up.right.square").font(Theme.display(11))
                    .fixedSize().padding(.horizontal, 9).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.chromeHairline))
            }.buttonStyle(.plain).disabled(coordinator.conversationSaving)
                .accessibilityIdentifier("popup-open-as-tab")
            }
            Button { coordinator.dismiss(reason: .dismiss) } label: {
                Image(systemName: "xmark").font(.system(size: 12)).frame(width: 24, height: 28)
            }.buttonStyle(.plain).disabled(coordinator.locksDismissal)
                .accessibilityLabel("Close popup").accessibilityIdentifier("popup-close")
        }.padding(.horizontal, 20).frame(height: 73)
    }
    @ViewBuilder private var conversationActions: some View {
        if let conversation = session.channelConversation, let model = conversation.model {
            Button("Mark as read") {
                if let root = model.threadRoot { model.markThreadRead(root) } else { model.markRead() }
            }
            Button("Search in conversation") { model.searching.toggle() }
            if model.hasNavigationReturn { Button("Back to reading") { model.returnFromNavigation() } }
            if model.b1?.supports("chat.pins") == true { Button("Pinned messages") { conversation.togglePins() } }
            Button(conversation.showingAgents ? "Messages" : "Agents / trust") { conversation.showingAgents.toggle() }
        } else if let model = session.tabState?.dmModel {
            Button("Mark as read") { model.markConversationRead(root: model.threadRoot) }
            Button(model.muted ? "Unmute" : "Mute") { model.setMuted(!model.muted) }
        } else if let state = session.tabState, let model = state.telegramModel {
            TelegramConversationActions(state: state, model: model, chats: TelegramService.chats)
        }
        Button("Switch conversation…") { coordinator.showConversationPicker = true }
        Button("Open as tab") { coordinator.promoteConversation() }
    }
}

struct ChatPopupPicker: View {
    @Bindable var coordinator: PopupCoordinator
    @State private var query = ""
    @FocusState private var focused: Bool
    struct Choice: Identifiable {
        let content: TabContent
        let title: String
        let detail: String
        let symbol: String
        var draft = false
        var id: String { String(describing: content) }
    }
    private var choices: [Choice] {
        var result = (coordinator.sessions + (coordinator.ownerStore?.allSessions ?? []))
            .filter { $0.content.isConversation }.map {
                Choice(content: $0.content, title: $0.conversationTitle, detail: $0.conversationSubtitle,
                       symbol: $0.conversationSymbol, draft: $0.hasConversationDraft)
            }
        let service = ChatService.shared
        if let org = service.orgCurrent.model, let key = org.key, org.channelsVisible {
            result += org.view.channels.filter { org.visibleChannel($0.channelId) != nil }.map {
                Choice(content: .channel(ChannelRef(key, channel: $0.channelId)), title: "# \($0.name)", detail: "Channel", symbol: "number")
            }
            if let list = service.dmList(key) {
                result += list.people.map { Choice(content: .tool($0.route(key)), title: $0.peer.name, detail: "Direct message", symbol: "person.fill") }
            }
        }
        let chats = TelegramService.chats
        let rows = Array(chats.customRows.values) + Array(chats.attentionRows.values)
            + chats.listPages.values.flatMap { $0.values.flatMap(\.rows) } + chats.snapshot.suggestionRows
        result += rows.map { Choice(content: .tool(.telegram($0.id)), title: $0.title, detail: "Telegram · \($0.displayKind)", symbol: "paperplane") }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Find a channel, person or Telegram chat…", text: $query).textFieldStyle(.plain)
                .padding(11).background(Theme.chromeHover.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ChatAppearance.accent.opacity(0.7)))
                .focused($focused).accessibilityLabel("Find a conversation")
            Text("Recent").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(choices) { choice in
                        Button {
                            if ConversationOpenIntent.commandClick { _ = coordinator.openConversationAsTab(choice.content) }
                            else { _ = coordinator.presentConversation(choice.content) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.symbol).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.title).font(Theme.display(13, weight: .medium))
                                    Text(choice.detail).font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                                }
                                Spacer()
                                if choice.draft {
                                    Text("Draft kept").font(Theme.display(10)).foregroundStyle(.green)
                                        .padding(4).background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                } else if coordinator.visibleConversation?.content == choice.content {
                                    Text("Current").font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                                }
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.chromeHover.opacity(coordinator.visibleConversation?.content == choice.content ? 0.65 : 0), in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("Open as tab") { _ = coordinator.openConversationAsTab(choice.content) }
                        }
                    }
                }
            }
            Divider()
            Text("⌘-click a conversation to open it as a tab. Your draft is kept when you switch.")
                .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("popup-conversation-picker").onAppear { focused = true }
    }
}

/// Reparent the exact tab host, including its native editor and timeline. The
/// covered pane omits this session while borrowed, so there is one publisher.
struct ChatPopupMount: NSViewRepresentable {
    let session: Session
    let visible: Bool
    final class Container: NSView {
        weak var session: Session?
        override func layout() { super.layout(); subviews.forEach { $0.frame = bounds } }
        func update(_ session: Session, visible: Bool) {
            self.session = session
            guard session.isConversationPopup else { return }
            let view = session.engine.view
            view.autoresizingMask = [.width, .height]; view.frame = bounds; view.isHidden = false
            if view.superview !== self { addSubview(view) }
            isHidden = !visible
        }
    }
    func makeNSView(context: Context) -> Container {
        let container = Container(); container.update(session, visible: visible); return container
    }
    func updateNSView(_ view: Container, context: Context) { view.update(session, visible: visible) }
    static func dismantleNSView(_ view: Container, coordinator: ()) {
        if let content = view.session?.engine.view, content.superview === view { content.removeFromSuperview() }
    }
}
