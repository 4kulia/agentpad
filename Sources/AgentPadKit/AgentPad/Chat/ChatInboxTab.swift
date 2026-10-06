import AppKit
import SwiftUI

@MainActor
final class ChatInboxTabEngine: TerminalEngine {
    let ref: ChatInboxRef
    private(set) var starts = 0
    private(set) var terminations = 0
    var onClose: () -> Void = {}
    var openMessage: (ChatMessage) -> Void = { _ in }
    var openChannel: (String) -> Void = { _ in }
    private lazy var host: NSView = NSHostingView(rootView: ChatInboxTabView(ref: ref,
        openMessage: { [weak self] in self?.openMessage($0) }, openChannel: { [weak self] in self?.openChannel($0) },
        close: { [weak self] in self?.onClose() }))

    init(ref: ChatInboxRef) { self.ref = ref }
    var view: NSView { host }
    func renderNowIfNeeded() {}
    func setOnScreen(_ onScreen: Bool) {}
    var backgroundColor: NSColor { .windowBackgroundColor }
    var onPwdChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandFinished: ((Int?, TimeInterval) -> Void)?
    var onUserInput: (() -> Void)?
    var onSearchStart: ((String) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int) -> Void)?
    var onSearchSelected: ((Int) -> Void)?
    var pasteUploadHostProvider: (() -> String?)?
    var isRemoteSessionProvider: (() -> Bool)?
    var foregroundPid: pid_t? { nil }
    var onProcessExitedCleanly: (() -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var onLinkHover: ((String?) -> Void)?
    var needsConfirmQuit: Bool { false }
    func start(config: TerminalSessionConfig) { starts += 1 }
    func terminate() { terminations += 1 }
    var suspendsSizePropagation: Bool { false }
    func beginSizePropagationSuspension() {}
    func endSizePropagationSuspension() {}
    func flushSize() {}
    var grabsFocusOnMount = false
    var spawnsWhileHidden = false
    @discardableResult func performAction(_ name: String) -> Bool { false }
    func sendInput(_ text: String) {}
    func paste(_ text: String) {}
    func pasteFromClipboardViaCore() -> Bool { false }
    func readSelection() -> String? { nil }
}

@MainActor
enum ChatInboxNavigation {
    @discardableResult
    static func open(_ message: ChatMessage, ref: ChatInboxRef, org: ChatOrgModel?, workspace: WorkspaceStore) -> Session? {
        guard case .ready = ref.state(org), let key = org?.key, org?.visibleChannel(message.channelId) != nil,
              let tab = workspace.showChannel(ChannelRef(key, channel: message.channelId)) else { return nil }
        ChatMessageNavigation.request(ChatMessageLink(key: key, message: message), key: key, destination: tab.engine.view)
        return tab
    }
}

struct ChatInboxTabView: View {
    let ref: ChatInboxRef
    var openMessage: (ChatMessage) -> Void
    var openChannel: (String) -> Void
    var close: () -> Void
    @State private var model: ChatInboxModel
    private var current = ChatOrgCurrent.shared

    init(ref: ChatInboxRef, openMessage: @escaping (ChatMessage) -> Void, openChannel: @escaping (String) -> Void,
         close: @escaping () -> Void) {
        self.ref = ref; self.openMessage = openMessage; self.openChannel = openChannel; self.close = close
        _model = State(initialValue: ChatInboxModel(ref: ref))
    }

    var body: some View {
        Group {
            switch ref.state(current.model) {
            case .ready:
                if let org = current.model {
                    ChatInboxView(kind: ref.kind, entries: model.entries(org), sidebar: ChatSidebarSnapshot(model: org, active: nil),
                                  members: org.members, problem: model.problem,
                                  markAllRead: { model.markAllRead(org) }, openMessage: openMessage, openChannel: openChannel)
                }
            case .checking:
                unavailable("Checking access…", detail: "Your messages will appear when access is confirmed.")
            case .notConnected:
                unavailable("Not connected", detail: "Connect to this tab’s organization to see its messages.")
            case .noChannels:
                unavailable("No channels available", detail: "This server has no chat channels.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatAppearance.surface)
        .task(id: ChatOrgCurrent.identity()) {
            ChatOrgCurrent.shared.refresh()
            if let org = current.model, let key = org.key, ref.belongs(to: key),
               let store = ChatService.shared.orgSessions[key]?.store { model.follow(store, org: org) }
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: ref.kind.symbol).font(.system(size: 28)).foregroundStyle(ChatAppearance.secondary)
            Text(title).font(Theme.display(18, weight: .semibold))
            Text(detail).font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
            Button("Close", action: close)
        }.padding(24)
    }
}

/// Native list content, shared by the tab and the isolated AppKit render test.
struct ChatInboxView: View {
    let kind: ChatInboxKind
    let entries: [ChatInbox.Entry]
    let sidebar: ChatSidebarSnapshot
    let members: [ChatOrgView.Member]
    var problem: String?
    var markAllRead: () -> Void
    var openMessage: (ChatMessage) -> Void
    var openChannel: (String) -> Void

    private var channels: [ChatSidebarSnapshot.Channel] { sidebar.teams.flatMap(\.channels) }
    private var groups: [ChatSidebarSnapshot.Channel] {
        let ids = Set(entries.map { $0.message.channelId })
        return channels.filter { ids.contains($0.id) || $0.unread.more || $0.unread.something }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).foregroundStyle(ChatAppearance.accent)
                Text(kind.title).font(Theme.display(18, weight: .semibold))
                Text(kind == .unread ? (ChatSidebarSnapshot.unreadLabel(sidebar.unread) ?? "0") : "\(entries.count)")
                    .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
                Spacer()
                if kind == .unread {
                    Button("Mark all read", action: markAllRead).chatFocusRing()
                        .disabled(entries.isEmpty && !sidebar.incomplete)
                        .accessibilityIdentifier("chat-inbox-mark-all-read")
                }
            }.padding(.horizontal, 24).frame(height: 62)
            Divider().overlay(ChatAppearance.border)
            if let problem { Text(problem).font(Theme.display(12)).foregroundStyle(ChatAppearance.failure).padding(16) }
            if entries.isEmpty && (kind == .mentions || groups.isEmpty) && problem == nil {
                VStack(spacing: 12) {
                    Image(systemName: kind == .unread ? "checkmark.circle" : "at")
                        .font(.system(size: 32)).foregroundStyle(ChatAppearance.accent)
                    Text(kind == .unread ? (sidebar.incomplete ? "No unread messages in loaded history" : "You’re all caught up") : "No mentions yet")
                        .font(Theme.display(18, weight: .semibold))
                    Text(kind == .unread ? "New messages from your channels and threads will appear here." : "Messages that mention you will appear here, newest first.")
                        .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if kind == .unread {
                            ForEach(groups) { channel in
                                HStack {
                                    Text("# \(channel.card.name)").font(Theme.display(14, weight: .semibold))
                                    Spacer()
                                    Text(channel.unreadLabel ?? "").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                                }.padding(.horizontal, 24).padding(.vertical, 14)
                                    .background(Theme.chromeBackground)
                                ForEach(entries.filter { $0.message.channelId == channel.id }) { row($0) }
                                if channel.unread.more || channel.unread.something {
                                    Button("Open channel to see more unread messages") { openChannel(channel.id) }
                                        .buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 12).chatFocusRing()
                                }
                            }
                        } else {
                            ForEach(entries) { row($0) }
                        }
                    }.padding(.vertical, 8)
                }
            }
            HStack {
                Text("From loaded history" + (sidebar.incomplete ? " · More messages may be available in your channels" : ""))
                Spacer()
                if case .ready(offline: true) = sidebar.state { Text("Offline") }
            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 24).padding(.vertical, 10)
        }.foregroundStyle(Theme.chromeForeground).background(ChatAppearance.surface)
    }

    private func row(_ entry: ChatInbox.Entry) -> some View {
        let message = entry.message
        let name = message.authorAgentName ?? members.first { $0.accountId == message.authorAccountId }?.name ?? "Unknown author"
        let channel = channels.first { $0.id == message.channelId }?.card.name ?? "Channel"
        return Button { openMessage(message) } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(String(name.prefix(1)).uppercased()).font(Theme.display(14, weight: .semibold))
                    .foregroundStyle(ChatAppearance.accent).frame(width: 34, height: 34)
                    .background(ChatAppearance.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(name).font(Theme.display(13, weight: .semibold))
                        if message.authorAgentId != nil { ChatBotBadge() }
                        Text(timestamp(message.createdAt)).font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                        Spacer(minLength: 8)
                        if entry.unread {
                            Text("Unread").font(Theme.display(10, weight: .semibold)).foregroundStyle(ChatAppearance.accent)
                        }
                    }
                    if kind == .mentions || message.threadRootId != nil {
                        Label(message.threadRootId == nil ? channel : "Thread in #\(channel)",
                              systemImage: message.threadRootId == nil ? "number" : "text.bubble")
                            .font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary)
                    }
                    Text(message.deleted ? "Message deleted" : message.loading ? "Message not loaded yet. Open to load it." : message.text)
                        .font(Theme.display(13)).lineLimit(4).multilineTextAlignment(.leading)
                        .foregroundStyle(message.deleted || message.loading ? ChatAppearance.secondary : Theme.chromeForeground)
                }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(ChatAppearance.secondary).padding(.top, 10)
            }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .background(entry.unread ? ChatAppearance.accent.opacity(0.055) : .clear)
                .overlay(alignment: .leading) { if entry.unread { Rectangle().fill(ChatAppearance.accent).frame(width: 3) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).chatFocusRing().accessibilityHint("Open message" + (message.threadRootId == nil ? " in channel" : " in thread"))
            .accessibilityIdentifier("chat-inbox-message-\(entry.id)")
    }

    private func timestamp(_ value: String) -> String {
        guard let date = ChatFeedLayout.date(value) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
