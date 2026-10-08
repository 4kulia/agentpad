import AppKit
import UserNotifications

enum SessionAlertKind: Equatable {
    case attention, failure, completed
    case programNotification(title: String, body: String)
}

enum NotificationAuthorization: String, Sendable {
    case unknown, authorized, denied, unavailable
    var label: String {
        switch self {
        case .unknown: "Permission not requested"
        case .authorized: "Allowed"
        case .denied: "Denied in macOS"
        case .unavailable: "Unavailable outside the app bundle"
        }
    }
}

struct NotificationPayload: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let sound: Bool
    var category = "attention.open"
    var userInfo: [String: String] { ["locator": id] }
}

@MainActor
protocol NotificationCenterClient: AnyObject {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
    func add(_ payload: NotificationPayload) async throws
    func remove(_ ids: [String])
    func identifiers() async -> [String]
}

@MainActor
private final class SystemNotificationCenter: NotificationCenterClient {
    let center: UNUserNotificationCenter
    init(_ center: UNUserNotificationCenter) { self.center = center }
    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .unknown
        }
    }
    func requestAuthorization() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound])) == true }
    func add(_ payload: NotificationPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title; content.body = payload.body
        content.categoryIdentifier = payload.category
        content.userInfo = payload.userInfo
        content.sound = payload.sound ? .default : nil
        try await center.add(UNNotificationRequest(identifier: payload.id, content: content, trigger: nil))
    }
    func remove(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    func identifiers() async -> [String] {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        return Array(Set(pending + delivered))
    }
}

@MainActor @Observable
final class NotificationAuthorizationModel {
    static let shared = NotificationAuthorizationModel()
    var status: NotificationAuthorization = .unknown
}

/// One serialized chain per locator. Revocation invalidates authorization and add
/// continuations; a late add is removed before a replacement can be submitted.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onActivateLocator: ((String) -> Void)?
    private var client: (any NotificationCenterClient)?
    private var revisions: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var queued: [String: NotificationPayload] = [:]
    private var authorizationTask: Task<Bool, Never>?
    private var requestedAuthorization = false
    private(set) var status: NotificationAuthorization = .unknown {
        didSet { NotificationAuthorizationModel.shared.status = status }
    }

    init(client: (any NotificationCenterClient)? = nil) { self.client = client; super.init() }

    func start() {
        if client == nil {
            // current() traps without a bundle identifier (swift run / tests).
            guard Bundle.main.bundleIdentifier != nil else { status = .unavailable; return }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let open = UNNotificationAction(identifier: "open", title: String(localized: "Open", bundle: .agentPadResources), options: [.foreground])
            center.setNotificationCategories([UNNotificationCategory(identifier: "attention.open", actions: [open], intentIdentifiers: [])])
            client = SystemNotificationCenter(center)
        }
        Task { await refreshAuthorization() }
    }
    func refreshAuthorization() async { status = await client?.authorization() ?? .unavailable }

    private func authorized() async -> Bool {
        guard let client else { status = .unavailable; return false }
        if let task = authorizationTask { return await task.value }
        // Share the status query too: two queries can both report "unknown"
        // while one event is already presenting the authorization prompt.
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            self.status = await client.authorization()
            if self.status == .authorized { return true }
            guard self.status == .unknown, !self.requestedAuthorization else { return false }
            self.requestedAuthorization = true
            let granted = await client.requestAuthorization()
            self.status = granted ? .authorized : .denied
            return granted
        }
        authorizationTask = task
        let granted = await task.value
        authorizationTask = nil
        return granted
    }

    func upsert(_ event: AttentionEvent, sound: Bool,
                isCurrent: @escaping @MainActor () -> Bool,
                didDeliver: @escaping @MainActor () -> Void = {}) {
        guard client != nil else { return }
        let payload = NotificationPayload(id: event.id,
            title: event.localTitle == nil || event.scope != nil
                ? String(localized: String.LocalizationValue(event.kind.title), bundle: .agentPadResources) : event.title,
            body: event.body, sound: sound)
        if queued[event.id] != nil { return }
        queued[event.id] = payload
        let revision = (revisions[event.id] ?? 0) + 1
        revisions[event.id] = revision
        let previous = tasks[event.id]
        tasks[event.id] = Task { [weak self] in
            await previous?.value
            guard let self, let client = self.client else { return }
            guard self.revisions[event.id] == revision, isCurrent(), await self.authorized(),
                  self.revisions[event.id] == revision, isCurrent() else {
                if self.revisions[event.id] == revision { self.queued[event.id] = nil }
                return
            }
            do {
                try await client.add(payload)
                guard self.revisions[event.id] == revision, isCurrent() else {
                    client.remove([event.id])
                    if self.revisions[event.id] == revision { self.queued[event.id] = nil }
                    return
                }
                didDeliver()
            } catch { if self.revisions[event.id] == revision { self.queued[event.id] = nil } }
        }
    }

    func remove(ids: [String]) {
        for id in ids { revisions[id, default: 0] += 1; queued[id] = nil }
        client?.remove(ids)
    }
    func identifiers() async -> [String] { await client?.identifiers() ?? [] }
    func reconcile(keeping: Set<String>) async {
        let ids = await identifiers()
        // This center belongs to AgentPad. Legacy UUID/Team/chat IDs have no safe route.
        remove(ids: ids.filter { !keeping.contains($0) })
    }
    func drain() async { for task in tasks.values { await task.value } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["locator"] as? String
        let action = response.actionIdentifier
        completionHandler()
        guard action == UNNotificationDefaultActionIdentifier || action == "open", let id else { return }
        Task { @MainActor [weak self] in self?.onActivateLocator?(id) }
    }
}
