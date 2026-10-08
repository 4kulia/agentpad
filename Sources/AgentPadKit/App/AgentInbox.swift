import AppKit
import SwiftUI

// MARK: - Event store

/// A view of the shared ledger. Reading a decision does not resolve its source.
@MainActor @Observable
final class NotificationInbox {
    static let shared = NotificationInbox(ledger: .shared)
    let ledger: AttentionLedger
    init(ledger: AttentionLedger = AttentionLedger()) { self.ledger = ledger }

    struct Event: Identifiable {
        let notice: AttentionEvent
        var id: String { notice.id }
        var sessionId: UUID? { if case .terminal(let id) = notice.destination { return id }; return nil }
        var timestamp: Date { notice.timestamp }
        var kind: SessionAlertKind {
            if notice.kind.needsDecision { return .attention }
            return notice.kind.category == .failure ? .failure : .completed
        }
        var agentIcon: String? { nil }
        var agentSymbol: String { notice.kind.needsDecision ? "hand.raised" : "bell" }
        var isRead: Bool { notice.isRead }
        var headline: String {
            notice.actionInFlight ? String(localized: "Decision is being sent", bundle: .agentPadResources)
                : String(localized: String.LocalizationValue(notice.title), bundle: .agentPadResources)
        }
        var subtitle: String {
            if notice.kind.needsDecision { return String(localized: "Waiting for your decision", bundle: .agentPadResources) }
            return notice.body
        }
        var tabTitle: String { notice.localBody?.components(separatedBy: " · ").first ?? "" }
    }
    var events: [Event] { ledger.events.map { Event(notice: $0) } }
    var hasUnread: Bool { ledger.unreadCount > 0 }
    var unreadCount: Int { ledger.unreadCount }

    func add(kind: SessionAlertKind, sessionId: UUID, agent: AgentTemplate, tab: String, workspace: String, isRead: Bool = false) {
        let category: AttentionKind = switch kind {
        case .attention: .input
        case .failure: .failure
        case .completed: .completion
        case .programNotification: .program
        }
        var event = AttentionEvent(source: "legacy-terminal", object: sessionId.uuidString, episode: UUID().uuidString,
                                   kind: category, destination: .terminal(sessionId))
        event.localBody = "\(tab) · \(workspace)"; event.isRead = isRead
        ledger.upsert(event)
        if isRead { ledger.markRead(event.id) }
    }
    func markRead(_ id: String) { ledger.markRead(id) }
    func markRead(forSession sessionId: UUID) {
        for event in ledger.events where event.destination == .terminal(sessionId) { ledger.markRead(event.id) }
    }
    func markAllRead() { ledger.markAllRead() }
    func clearAll() { ledger.clearHistory() }
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

enum InboxLayout {
    static let headerHeight: CGFloat = 50
    static let rowHeight: CGFloat = 50
    static let emptyHeight: CGFloat = 100
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

// MARK: - Notification content

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications-inbox-content")
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
                    Button { onActivate(event) } label: { InboxRow(event: event) }
                        .buttonStyle(.plain).accessibilityIdentifier("notification-" + event.id)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
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
