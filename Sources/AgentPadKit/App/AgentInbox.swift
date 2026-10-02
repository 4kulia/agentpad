import AppKit
import SwiftUI

// MARK: - Event store

/// App-level (cross-window) inbox of agent events — attention / failure /
/// completion. Runtime-only (cleared on relaunch), capped LIFO. `@Observable`
/// so the top-chrome bell's red dot and the panel both invalidate on change;
/// a singleton because the inbox spans every window (like the Command Palette).
@MainActor
@Observable
final class NotificationInbox {
    static let shared = NotificationInbox()
    /// `internal` (not `private`) so tests can build an isolated instance
    /// rather than mutating the shared singleton. Production uses `.shared`.
    init() {}

    struct Event: Identifiable {
        let id = UUID()
        let kind: SessionAlertKind
        /// Target tab — the row click resolves this through `dockTabLocation`.
        let sessionId: UUID
        let timestamp: Date
        // Agent + location are snapshotted at capture time: the session may
        // be closed (or its agent reverted to Terminal) by the time the user
        // opens the inbox, so the row can't read them live.
        let agentTitle: String
        let agentIcon: String?
        let agentSymbol: String
        let tabTitle: String
        let workspaceTitle: String
        var isRead = false

        @MainActor
        var headline: String {
            switch kind {
            case .attention:
                return String.localizedStringWithFormat(
                    String(localized: "%@ is waiting on you", bundle: .agentPadResources),
                    agentTitle
                )
            case .failure: return String(localized: "Command failed", bundle: .agentPadResources)
            case .completed:
                return String.localizedStringWithFormat(
                    String(localized: "%@ finished", bundle: .agentPadResources),
                    agentTitle
                )
            case .programNotification(let title, let body):
                return [title, body].filter { !$0.isEmpty }.joined(separator: ": ")
            }
        }

        var subtitle: String {
            tabTitle == workspaceTitle ? tabTitle : "\(tabTitle) · \(workspaceTitle)"
        }
    }

    private static let cap = 100
    private(set) var events: [Event] = []

    /// Drives the bell's red dot — true when any event is unread.
    var hasUnread: Bool { events.contains { !$0.isRead } }
    /// Unread count — surfaced as the header badge.
    var unreadCount: Int { events.lazy.filter { !$0.isRead }.count }

    func add(kind: SessionAlertKind, sessionId: UUID, agent: AgentTemplate, tab: String, workspace: String, isRead: Bool = false) {
        var event = Event(
            kind: kind,
            sessionId: sessionId,
            timestamp: Date(),
            agentTitle: agent.title,
            agentIcon: agent.iconAsset,
            agentSymbol: agent.symbol,
            tabTitle: tab,
            workspaceTitle: workspace
        )
        // If the tab was already on-screen when the event fired, the user has
        // effectively seen it — land it read so the bell's dot doesn't light.
        event.isRead = isRead
        events.insert(event, at: 0)
        if events.count > Self.cap { events.removeLast() }
    }

    func markRead(_ id: UUID) {
        guard let i = events.firstIndex(where: { $0.id == id }), !events[i].isRead else { return }
        events[i].isRead = true
    }

    /// Mark every unread event pointing at `sessionId` as read — called when the
    /// user switches to that tab, so a notification they've already acted on by
    /// going to look doesn't keep the bell's red dot lit.
    func markRead(forSession sessionId: UUID) {
        for i in events.indices where events[i].sessionId == sessionId && !events[i].isRead {
            events[i].isRead = true
        }
    }

    func markAllRead() {
        for i in events.indices where !events[i].isRead { events[i].isRead = true }
    }

    func clearAll() {
        events.removeAll()
    }
}

/// "now" / "2m ago" / "3h ago" / "1d ago". Computed once when the panel
/// renders (the panel rebuilds its host on every open, so each open is fresh).
enum InboxTime {
    static func relative(
        from date: Date,
        now: Date = Date(),
        bundle: Bundle = .agentPadResources
    ) -> String {
        // One ago-vocabulary app-wide: the tiers live in `relativeAgeTier`
        // (shared with the session-history rows); the inbox adds the suffix.
        let elapsed = max(0, now.timeIntervalSince(date))
        let tier = relativeAgeTier(elapsed, bundle: bundle)
        guard elapsed >= 60 else { return tier }
        return String.localizedStringWithFormat(
            String(localized: "%@ ago", bundle: bundle),
            tier
        )
    }
}

/// Single source for the inbox panel's height math, shared by the SwiftUI
/// frames (`InboxView`) and the NSPanel sizing (`InboxWindowController`) so the
/// two can't drift — a mismatch leaves a chrome strip at the panel's edge. The
/// per-section frames reference these same constants.
enum InboxLayout {
    static let headerHeight: CGFloat = 50   // single row, fits the 28pt buttons
    static let rowHeight: CGFloat = 50
    static let emptyHeight: CGFloat = 100
    static let maxListHeight: CGFloat = 412

    /// Height of the scrollable list for `rowCount` rows (+8 list v-padding, capped).
    static func listHeight(rowCount: Int) -> CGFloat {
        min(CGFloat(rowCount) * rowHeight + 8, maxListHeight)
    }
    /// Total panel content: header + hairline + list (or the empty block).
    static func panelHeight(rowCount: Int) -> CGFloat {
        let base = headerHeight + 1
        return rowCount == 0 ? base + emptyHeight : base + listHeight(rowCount: rowCount)
    }
}

// MARK: - Top-chrome bell

/// Bell icon for the top strip. Shows a red dot (no count, per design) when
/// the inbox has unread events. Reads `NotificationInbox.shared` directly so
/// SwiftUI re-renders the dot as events arrive / are read.
struct InboxBell: View {
    var inbox = NotificationInbox.shared

    var body: some View {
        // Same chrome button as the sidebar-toggle (HoverableIconButton) so the
        // top strip stays consistent — only the symbol differs. The unread dot
        // overlays the 28×28 frame's top-right corner.
        HoverableIconButton(
            systemName: "bell",
            fontSize: 12,
            size: Theme.chromeToolbarButtonSize,
            help: "Notifications (⇧⌘I)"
        ) {
            NSApp.sendAction(#selector(AppDelegate.handleShowInbox), to: nil, from: nil)
        }
        .overlay(alignment: .topTrailing) {
            if inbox.hasUnread {
                Circle()
                    .fill(Theme.activityFailure)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .padding(.trailing, 5)
            }
        }
    }
}

// MARK: - Panel view

struct InboxView: View {
    var inbox = NotificationInbox.shared
    let onActivate: (NotificationInbox.Event) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            if inbox.events.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 420, height: InboxLayout.panelHeight(rowCount: inbox.events.count), alignment: .top)
        // Fill the whole panel with the chrome background, content top-aligned,
        // so any rounding slack lands at the bottom as chrome rather than the
        // panel's default window color showing through as a mismatched strip.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        // The hosting controller drops the titlebar safe area
        // (`safeAreaRegions = []`); this is the matching SwiftUI-side guard,
        // same as `ContentView` does for the main window.
        .ignoresSafeArea(.all)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(String(localized: "Notifications", bundle: .agentPadResources))
                .font(Theme.mono(13, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground)
            if inbox.unreadCount > 0 {
                Text("\(inbox.unreadCount)")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(Theme.activityFailure)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.activityFailure.opacity(0.15)))
            }
            Spacer(minLength: 8)
            // Icon buttons; the label surfaces on hover via the tooltip.
            HoverableIconButton(
                systemName: "checkmark",
                fontSize: 12,
                size: Theme.chromeToolbarButtonSize,
                help: "Mark all read"
            ) {
                inbox.markAllRead()
            }
            .disabled(!inbox.hasUnread)
            HoverableIconButton(
                systemName: "trash",
                fontSize: 12,
                size: Theme.chromeToolbarButtonSize,
                help: "Clear all"
            ) {
                inbox.clearAll()
                onClear()
            }
            .disabled(inbox.events.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(height: InboxLayout.headerHeight)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(inbox.events) { event in
                    InboxRow(event: event)
                        .onTapGesture { onActivate(event) }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: InboxLayout.listHeight(rowCount: inbox.events.count))
    }

    private var empty: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 7) {
                Image(systemName: "tray")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.4))
                Text(String(localized: "no notifications", bundle: .agentPadResources))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: InboxLayout.emptyHeight)
    }
}

private struct InboxRow: View {
    let event: NotificationInbox.Event
    @State private var isHovered = false

    // `Theme.activity*` is @MainActor; resolve the kind accent here in the
    // view body rather than on the nonisolated `Event` struct. The left bar
    // carries the kind (amber=attention / red=failure / blue=done); a read
    // row dims the whole line instead of showing a separate unread dot.
    private var accent: Color {
        switch event.kind {
        case .attention: return Theme.activityAttention
        case .failure: return Theme.activityFailure
        case .completed: return Theme.activityRunning
        case .programNotification: return Theme.chromeMuted
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.opacity(event.isRead ? 0.22 : 1))
                .frame(width: 3, height: 30)
            AgentIconView(asset: event.agentIcon, fallbackSymbol: event.agentSymbol, size: 15)
                .opacity(event.isRead ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.headline)
                    .font(Theme.mono(12.5, weight: event.isRead ? .regular : .medium))
                    .foregroundStyle(event.isRead ? Theme.chromeMuted : Theme.chromeForeground)
                    .lineLimit(1)
                Text(event.subtitle)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Hover swaps the timestamp for a jump glyph — a quiet hint that
            // the row is clickable. Fixed trailing width keeps it from jitter.
            Group {
                if isHovered {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.chromeForeground.opacity(0.75))
                } else {
                    Text(InboxTime.relative(from: event.timestamp))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.chromeMuted.opacity(0.7))
                }
            }
            .frame(minWidth: 32, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: InboxLayout.rowHeight)
        .background(isHovered ? Theme.chromeHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Floating panel host

/// Singleton NSPanel host for the inbox — mirrors `CommandPaletteWindowController`
/// (nonactivating floating panel, rebuild the `NSHostingController` on each
/// `show` for a clean SwiftUI state, dismiss on resign-key). Anchored top-right
/// (near the bell) rather than centered.
@MainActor
final class InboxWindowController: NSWindowController, DismissablePanel {
    static let shared = InboxWindowController()

    private static let panelSize = NSSize(width: 420, height: 480)

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.appearance = Theme.windowAppearance
        panel.applyGlassBacking()
        self.init(window: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey(_:)),
            name: NSWindow.didResignKeyNotification, object: panel
        )
    }

    @objc private func panelResignedKey(_ note: Notification) {
        dismiss()
    }

    func toggle(anchor: NSWindow?, onActivate: @escaping (NotificationInbox.Event) -> Void) {
        if window?.isVisible == true {
            dismiss()
        } else {
            show(anchor: anchor, onActivate: onActivate)
        }
    }

    func show(anchor: NSWindow?, onActivate: @escaping (NotificationInbox.Event) -> Void) {
        guard let panel = window else { return }
        let view = InboxView(
            onActivate: { [weak self] event in
                self?.dismiss()
                onActivate(event)
            },
            onClear: { [weak self] in self?.dismiss() }
        )
        // Fresh host on each open keeps the SwiftUI state clean (matches the
        // Command Palette's rebuild-on-show rationale).
        let host = NSHostingController(rootView: view)
        // Drop the titlebar safe-area inset at the hosting layer. With it, the
        // hosting view's fitting height ran 28pt over the content, leaving the
        // panel taller than the content and a chrome strip at the bottom.
        host.safeAreaRegions = []
        panel.contentViewController = host
        // Size the panel to the content ourselves, sharing InboxLayout with the
        // SwiftUI frames. (Content-driven `.preferredContentSize` sizing was
        // tried and crashed on the list's then-unbounded ScrollView.)
        let height = InboxLayout.panelHeight(rowCount: NotificationInbox.shared.events.count)
        panel.setContentSize(NSSize(width: Self.panelSize.width, height: height))
        positionTopRight(of: anchor)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func positionTopRight(of anchor: NSWindow?) {
        guard let panel = window else { return }
        // Read back the size just set via `setContentSize` so the panel pins to
        // the top-right corner regardless of how tall it ended up.
        let size = panel.frame.size
        let ref = anchor?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferred = NSPoint(
            x: ref.maxX - size.width - 16,
            y: ref.maxY - 44 - size.height
        )
        let visibleFrame = anchor?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? ref
        panel.setFrameOrigin(PanelPlacement.clampedOrigin(
            preferred: preferred,
            panelSize: size,
            visibleFrame: visibleFrame
        ))
    }
}
