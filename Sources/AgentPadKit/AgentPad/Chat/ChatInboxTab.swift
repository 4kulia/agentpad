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
    private let current: ChatOrgCurrent
    private let service: ChatService

    init(ref: ChatInboxRef, openMessage: @escaping (ChatMessage) -> Void, openChannel: @escaping (String) -> Void,
         close: @escaping () -> Void, model: ChatInboxModel? = nil, current: ChatOrgCurrent = .shared,
         service: ChatService = .shared) {
        self.ref = ref; self.openMessage = openMessage; self.openChannel = openChannel; self.close = close
        self.current = current; self.service = service
        _model = State(initialValue: model ?? ChatInboxModel(ref: ref))
    }

    private struct Binding: Equatable {
        var org, store, sync: ObjectIdentifier?
        var session: String?
        var state: ChatSidebarSnapshot.State
    }

    private var binding: Binding {
        let org = current.model
        let session = org?.key.flatMap { service.orgSessions[$0] }
        return Binding(org: org.map(ObjectIdentifier.init), store: session?.store.map(ObjectIdentifier.init),
                       sync: session?.sync.map(ObjectIdentifier.init), session: org?.session, state: ref.state(org))
    }

    private func follow() {
        guard let org = current.model, let key = org.key, case .ready = ref.state(org),
              let session = service.orgSessions[key], let store = session.store else { model.stop(); return }
        model.follow(store, org: org) { [weak sync = session.sync] target, before in
            guard let sync else { throw ChatInboxLoadError.unavailable }
            return try await sync.readInboxPage(target, before: before)
        }
    }

    var body: some View {
        Group {
            switch ref.state(current.model) {
            case .ready:
                if let org = current.model {
                    ChatInboxView(kind: ref.kind, entries: model.entries(org), sidebar: ChatSidebarSnapshot(model: org, active: nil),
                                  members: org.members, problem: model.problem,
                                  loading: model.loading, limited: model.limited, retry: { model.retry() },
                                  markAllRead: { model.markAllRead(org, service: service) }, openMessage: openMessage, openChannel: openChannel)
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
        .task(id: ChatOrgCurrent.identity(service)) { current.refresh(service); follow() }
        // Readiness can arrive after the identity's task has already finished.
        .onChange(of: binding, initial: true) { _, _ in model.stop(); follow() }
        .onDisappear { model.stop() }
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

/// A positive badge must always have either messages or an actionable remainder.
struct ChatInboxPresentation {
    struct Missing: Identifiable {
        var channel: ChatSidebarSnapshot.Channel
        var count: Int
        var kind: ChatInboxKind
        var id: String { channel.id }
        var title: String {
            let noun = kind == .unread ? "message" : "mention"
            let amount = count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")" : "More \(noun)s may be available"
            return "\(amount) in #\(channel.card.name) — Open channel"
        }
    }
    var entries: [ChatInbox.Entry]
    var groups: [ChatSidebarSnapshot.Channel]
    var missing: [Missing]
    var isEmpty: Bool { entries.isEmpty && missing.isEmpty }

    init(kind: ChatInboxKind, entries: [ChatInbox.Entry], sidebar: ChatSidebarSnapshot) {
        let channels = sidebar.teams.flatMap(\.channels)
        let ids = Set(channels.map(\.id))
        self.entries = entries.filter { ids.contains($0.message.channelId) && !$0.message.loading }
        let byChannel = Dictionary(grouping: self.entries, by: { $0.message.channelId })
        missing = channels.compactMap { channel in
            let shown = byChannel[channel.id, default: []].filter(\.unread).count
            let expected = kind == .unread ? channel.unread.count : channel.mentions
            let remaining = max(0, expected - shown)
            guard remaining > 0 || channel.unread.more || channel.unread.something else { return nil }
            return Missing(channel: channel, count: remaining, kind: kind)
        }
        let missingIDs = Set(missing.map(\.id))
        groups = channels.filter { byChannel[$0.id] != nil || missingIDs.contains($0.id) }
    }
}

/// Native list content, shared by the tab and the isolated AppKit render test.
struct ChatInboxView: View {
    let kind: ChatInboxKind
    let entries: [ChatInbox.Entry]
    let sidebar: ChatSidebarSnapshot
    let members: [ChatOrgView.Member]
    var problem: String?
    var loading = false
    var limited = false
    var retry: () -> Void = {}
    var markAllRead: () -> Void
    var openMessage: (ChatMessage) -> Void
    var openChannel: (String) -> Void

    private var channels: [ChatSidebarSnapshot.Channel] { sidebar.teams.flatMap(\.channels) }
    private var presentation: ChatInboxPresentation { ChatInboxPresentation(kind: kind, entries: entries, sidebar: sidebar) }

    var body: some View {
        let presentation = presentation
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).foregroundStyle(ChatAppearance.accent)
                Text(kind.title).font(Theme.display(18, weight: .semibold))
                Text(kind == .unread ? (ChatSidebarSnapshot.unreadLabel(sidebar.unread) ?? "0") : "\(sidebar.mentions) unread")
                    .font(Theme.display(12)).foregroundStyle(ChatAppearance.secondary)
                Spacer()
                if kind == .unread {
                    Button("Mark all read", action: markAllRead).chatFocusRing()
                        .disabled(entries.isEmpty && sidebar.unread.count == 0 && !sidebar.incomplete)
                        .accessibilityIdentifier("chat-inbox-mark-all-read")
                }
            }.padding(.horizontal, 24).frame(height: 62)
            Divider().overlay(ChatAppearance.border)
            if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading unread messages…").font(Theme.display(12))
                }.padding(16).accessibilityIdentifier("chat-inbox-loading")
            }
            if let problem {
                HStack {
                    Text(problem).font(Theme.display(12)).foregroundStyle(ChatAppearance.failure)
                    Button("Retry", action: retry).disabled(loading).chatFocusRing()
                }.padding(16).accessibilityIdentifier("chat-inbox-error")
            } else if limited {
                HStack {
                    Text("More unread messages are available.").font(Theme.display(12))
                    Button("Load more", action: retry).disabled(loading).chatFocusRing()
                }.padding(16)
            }
            if presentation.isEmpty && !loading && !limited && problem == nil {
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
                            ForEach(presentation.groups) { channel in
                                HStack {
                                    Text("# \(channel.card.name)").font(Theme.display(14, weight: .semibold))
                                    Spacer()
                                    Text(channel.unreadLabel ?? "").font(Theme.display(11)).foregroundStyle(ChatAppearance.secondary)
                                }.padding(.horizontal, 24).padding(.vertical, 14)
                                    .background(Theme.chromeBackground)
                                ForEach(presentation.entries.filter { $0.message.channelId == channel.id }) { row($0) }
                                ForEach(presentation.missing.filter { $0.id == channel.id }) { remainder($0) }
                            }
                        } else {
                            ForEach(presentation.entries) { row($0) }
                            ForEach(presentation.missing) { remainder($0) }
                        }
                    }.padding(.vertical, 8)
                }
            }
            HStack {
                Text("Open a message or channel to read it.")
                Spacer()
                if case .ready(offline: true) = sidebar.state { Text("Offline") }
            }.font(Theme.display(10)).foregroundStyle(ChatAppearance.secondary).padding(.horizontal, 24).padding(.vertical, 10)
        }.foregroundStyle(Theme.chromeForeground).background(ChatAppearance.surface)
    }

    private func remainder(_ missing: ChatInboxPresentation.Missing) -> some View {
        Button(missing.title) { openChannel(missing.id) }
            .buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 12).chatFocusRing()
            .accessibilityIdentifier("chat-inbox-remainder-\(missing.id)")
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
