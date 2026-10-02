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
        let raw = response.notification.request.content.userInfo["sessionId"] as? String
        completionHandler()
        guard let raw, let id = UUID(uuidString: raw) else { return }
        Task { @MainActor [weak self] in self?.onActivate?(id) }
    }
}
