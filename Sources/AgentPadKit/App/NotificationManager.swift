import AppKit
import UserNotifications

/// What kind of agent event warrants a notification. Drives the notification
/// copy; both kinds only fire when the originating tab isn't currently visible.
enum SessionAlertKind: Equatable {
    /// The agent entered an attention (waiting-on-you) state.
    case attention
    /// The most recent command in the tab exited non-zero.
    case failure
    /// The agent finished / exited. Inbox-only — never posts a banner.
    case completed
    /// A terminal program posted its own notification (OSC 9 / OSC 777),
    /// carrying its own text — rides the same alert seam as the fixed kinds.
    case programNotification(title: String, body: String)
}

/// Thin wrapper over `UNUserNotificationCenter` for AgentPad's agent
/// notifications. `AppDelegate` decides *whether* to post (only for a tab the
/// user can't currently see); this type owns the macOS plumbing — permission
/// request, delivery, and routing a click back to the originating tab via
/// `onActivate`.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked with the originating session id when the user clicks a
    /// delivered notification. `AppDelegate` wires this to its reveal-tab
    /// routing (deminiaturize → key → activate workspace + tab).
    var onActivate: ((UUID) -> Void)?
    /// AgentPad: clicked a banner about a session in another terminal.
    var onActivateExternal: ((String) -> Void)?

    /// `UNUserNotificationCenter` needs an app bundle: a bare `swift run`
    /// binary (the dev build) has no bundle id and `current()` traps. Gate
    /// every entry point on this so notifications simply no-op under
    /// `swift run` and work in the packaged, bundle-id'd .app.
    private let isAvailable = Bundle.main.bundleIdentifier != nil
    private lazy var center = UNUserNotificationCenter.current()

    /// Registers the delegate and requests banner/sound permission. Called
    /// once at launch; macOS shows its permission prompt the first time.
    func start() {
        guard isAvailable else { return }
        // Set the delegate only. Permission is requested lazily on the first
        // real post (see `requestAuthorizationIfNeeded`) — a user who disabled
        // notifications shouldn't get the OS authorization prompt at launch.
        center.delegate = self
    }

    /// Delivers a banner immediately. The session id rides `userInfo` so a
    /// click can route back to the tab. Silently no-ops if the user denied
    /// permission — the OS drops the request.
    func post(title: String, body: String, sessionId: UUID) {
        guard isAvailable else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId.uuidString]
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// AgentPad: a banner about a Claude Code session in another terminal.
    /// Carries the Claude session id instead of one of our tab ids.
    func postExternal(title: String, body: String, externalSessionId: String) {
        guard isAvailable else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["externalSessionId": externalSessionId]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// AgentPad: a colleague's call waiting for a decision (team work).
    /// A click only brings AgentPad forward, where the right panel shows it.
    func postTeam(title: String, body: String) {
        guard isAvailable else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// AgentPad (F4): a chat notice — a title only, nothing of what it is
    /// about (no text, channel, author or organization); `id` lets it be
    /// taken back, shown or still pending.
    func postChat(id: String, title: String) {
        guard isAvailable else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// AgentPad (F4): takes back chat notices by id, or every one whose id
    /// starts with `prefix` — pending and shown alike.
    func removeChat(ids: [String] = [], prefix: String? = nil) {
        guard isAvailable else { return }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        guard let prefix else { return }
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { notes in
            let ids = notes.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// AgentPad (F4): ids of chat notices shown or pending, to reconcile them.
    func chatIds() async -> [String] {
        guard isAvailable else { return [] }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let shown = await center.deliveredNotifications().map(\.request.identifier)
        return (pending + shown).filter { $0.hasPrefix("chat:") }
    }

    /// Requests banner/sound permission once, on the first notification AgentPad
    /// actually wants to deliver — so the OS prompt only ever appears for a
    /// user who has notifications enabled and just hit a notifiable event.
    private var didRequestAuthorization = false
    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show the banner even while AgentPad is frontmost: we only post for a tab
    // the user isn't looking at, so a foreground banner is still wanted.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let raw = userInfo["sessionId"] as? String
        let external = userInfo["externalSessionId"] as? String
        completionHandler()
        if let external {
            Task { @MainActor [weak self] in self?.onActivateExternal?(external) }
            return
        }
        guard let raw, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor [weak self] in self?.onActivate?(id) }
    }
}
