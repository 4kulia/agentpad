import AppKit
import SwiftUI

/// The channel a tab shows (DESIGN-F2). No name: a channel's name is only
/// ever read from its card while the user may see it — never kept with the
/// tab, in `state.json` or the closed-tab history (review F2-1).
struct ChannelRef: Codable, Equatable, Hashable {
    /// `ChatServerAddress`, as `chat/servers.json` has it.
    var server: String
    var account: String
    var org: String
    var channel: String

    init(server: String, account: String, org: String, channel: String) {
        self.server = server
        self.account = account
        self.org = org
        self.channel = channel
    }

    init(_ key: ChatOrgKey, channel: String) {
        self.init(server: "\(key.server)", account: key.accountId, org: key.orgId, channel: channel)
    }

    func belongs(to key: ChatOrgKey) -> Bool {
        server == "\(key.server)" && account == key.accountId && org == key.orgId
    }
}

/// What a channel tab shows, from the organization's model alone: no
/// stored state, no network (DESIGN-F2, "Что показывает вкладка").
enum ChannelTabState: Equatable {
    case notConnected
    case checking
    case noChannels
    case ready(ChatChannelCard, team: String?, offline: Bool)
    case noAccess

    /// In order: the context, then the rights, then the server, then the
    /// card (review F2-2). Nothing of the channel before the rights are known.
    @MainActor
    static func of(_ ref: ChannelRef, model: ChatOrgModel?) -> ChannelTabState {
        guard let model, model.isCurrent(), let key = model.key, ref.belongs(to: key) else { return .notConnected }
        guard model.visible, !model.inDoubt, !model.snapshotOwed() else { return .checking }
        guard model.view.channelsServed else { return .noChannels }
        if let card = model.visibleChannel(ref.channel) {
            return .ready(card, team: model.channelTeam(card)?.name, offline: !model.isOnline())
        }
        // A read of the channels under way or cut off: not known to be gone.
        return model.view.channelsReadOpen ? .checking : .noAccess
    }

    /// The tab's title: the channel's name only while it may be seen.
    var title: String {
        if case .ready(let card, _, _) = self { return "#\(card.name)" }
        return "Channel"
    }
}

enum ChannelTabs {
    @MainActor
    static func state(_ ref: ChannelRef) -> ChannelTabState { .of(ref, model: ChatOrgCurrent.shared.model) }
    @MainActor
    static func title(_ ref: ChannelRef) -> String { state(ref).title }
}

/// Stands in for the terminal engine of a channel tab: shows the channel,
/// starts no process, and takes no terminal action (V1, CHAT-tab-probe.md).
@MainActor
final class ChannelTabEngine: TerminalEngine {
    let ref: ChannelRef
    private(set) var starts = 0
    private(set) var terminations = 0
    /// Closes the tab; set by the store that holds it.
    var onClose: () -> Void = {}
    private lazy var host: NSView = NSHostingView(rootView: ChannelTabView(ref: ref, close: { [weak self] in self?.onClose() }))

    init(ref: ChannelRef) {
        self.ref = ref
        // Its channel is followed while the tab is open (F3).
        ChatService.shared.channelTab(ref, open: true)
    }

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
    func terminate() {
        terminations += 1
        if terminations == 1 { ChatService.shared.channelTab(ref, open: false) }
    }
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

/// The channel tab's content. F3 puts the feed where "ready" stands.
struct ChannelTabView: View {
    let ref: ChannelRef
    let close: () -> Void
    private var current = ChatOrgCurrent.shared

    init(ref: ChannelRef, close: @escaping () -> Void) {
        self.ref = ref
        self.close = close
    }

    var body: some View {
        let state = ChannelTabState.of(ref, model: current.model)
        VStack(spacing: 8) {
            switch state {
            case .ready(let card, let team, let offline):
                if let key = current.model?.key {
                    ChatChannelView(card: card, team: team, offline: offline, key: key)
                }
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking access…").foregroundStyle(.secondary)
                Button("Close", action: close)
            case .notConnected:
                Text("Not connected").font(.title3)
                Text("This channel's organization is not connected on this Mac.").foregroundStyle(.secondary)
                Button("Close", action: close)
            case .noChannels:
                Text("This server has no channels").font(.title3)
                Button("Close", action: close)
            case .noAccess:
                Text("No access").font(.title3)
                Text("The channel is gone, or you are not in its team.").foregroundStyle(.secondary)
                Button("Close", action: close)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: ChatOrgCurrent.identity()) { current.refresh() }
    }
}
