import AgentPadTelegram
import AppKit
import CoreImage.CIFilterBuiltins
import ImageIO
import Network
import SwiftUI
import UniformTypeIdentifiers

/// One local service/model for all Settings windows. It has no ChatService,
/// server settings, org, analytics, or window-state persistence dependency.
@MainActor
enum TelegramService {
    static let chats = TelegramChatsModel()
    static let conversations = TelegramConversations()
    private static var suspensions = Set<String>()
    static var isInteractive: Bool { NSApp?.isActive == true && suspensions.isEmpty }
    static let settings = TelegramSettingsViewModel(onInvalidate: { TelegramNotifications.shared.disconnect() }, onConnector: { connector in
        if let provider = connector as? any TelegramChatProvider { chats.attach(provider) }
    })
    private static var recoveryMonitor: NWPathMonitor?
    private static var resourceObservers: [NSObjectProtocol] = []
    private static var presenceObservers: [(NotificationCenter, NSObjectProtocol)] = []

    static func start() {
        SidebarFoldersService.start()
        TelegramNotifications.shared.manager = AttentionCoordinator.shared.notificationManager
        chats.changed = {
            SidebarFoldersService.receive(chats.snapshot, provider: chats.provider)
            TelegramNotifications.shared.receive(chats.snapshot, provider: chats.provider)
            AttentionCoordinator.shared.refreshBadge()
        }
        settings.start()
        guard recoveryMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await settings.retryPendingLogout() }
        }
        monitor.start(queue: DispatchQueue(label: "com.4kulia.agentpad.telegram.network", qos: .utility))
        recoveryMonitor = monitor
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            resourceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await updateResourcePause() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let center = NotificationCenter.default
            presenceObservers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in await updatePresence() }
            }))
        }
        for (center, down, up) in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
            (DistributedNotificationCenter.default() as NotificationCenter, Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"))
        ] {
            for name in [down, up] {
                presenceObservers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        if name == down { suspensions.insert(down.rawValue) } else { suspensions.remove(down.rawValue) }
                        await updatePresence()
                    }
                }))
            }
        }
        Task { await updateResourcePause(); await updatePresence() }
    }
    private static func updatePresence() async {
        await settings.whenInitialized()
        await (chats.provider as? any TelegramConversationProvider)?.setApplicationActive(isInteractive)
        for window in NSApp.windows { NavigationPresentationGate.recheck(window) }
    }

    static func shutdown() async {
        recoveryMonitor?.cancel(); recoveryMonitor = nil
        for observer in resourceObservers { NotificationCenter.default.removeObserver(observer) }; resourceObservers = []
        for (center, token) in presenceObservers { center.removeObserver(token) }; presenceObservers = []
        await (chats.provider as? any TelegramConversationProvider)?.setApplicationActive(false)
        await settings.shutdown()
    }
    private static func updateResourcePause() async {
        // Wait for the shared connector rather than opening a second client.
        await settings.whenInitialized()
        let process = ProcessInfo.processInfo
        let reason = process.isLowPowerModeEnabled ? "Low Power Mode"
            : process.thermalState == .serious || process.thermalState == .critical ? "Mac is cooling down" : nil
        await chats.provider?.setChatScanPaused(reason)
    }
}

@Observable @MainActor
final class TelegramSettingsViewModel {
    typealias Factory = @Sendable ([String: String]) async -> any TelegramConnector
    private(set) var snapshot = TelegramSnapshot()
    private(set) var isWorking = false
    private(set) var qrImage: NSImage?
    var input = ""
    @ObservationIgnored private let factory: Factory
    @ObservationIgnored private let onConnector: (any TelegramConnector) -> Void
    @ObservationIgnored private let onInvalidate: () -> Void
    @ObservationIgnored private var connector: (any TelegramConnector)?
    @ObservationIgnored private var initialization: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(onInvalidate: @escaping () -> Void = {}, onConnector: @escaping (any TelegramConnector) -> Void = { _ in }, factory: @escaping Factory = { environment in
        await Task.detached(priority: .utility) {
            let resource = Bundle.main.url(forResource: "TelegramCredentials", withExtension: "plist")
            let credentials = try? TelegramCredentials.load(environment: environment, resource: resource)
            return LocalTDLibConnector(credentials: credentials, applicationVersion: AgentPadApp.displayVersion)
        }.value
    }) { self.factory = factory; self.onConnector = onConnector; self.onInvalidate = onInvalidate }

    convenience init(connector: any TelegramConnector) { self.init(factory: { _ in connector }) }

    var needsShutdown: Bool {
        if initialization != nil || isWorking { return true }
        switch snapshot.state { case .disconnected, .disabled: return false; default: return true }
    }

    func start(environment: [String: String]? = nil) {
        guard initialization == nil, connector == nil, !stopping else { return }
        var configuration = environment ?? [:]
        if environment == nil {
            // Remove runtime provisioning from the process environment before
            // terminal/helper children are launched. Build resources remain the
            // normal signed-app path. No credential is persisted by this model.
            for key in ["AGENTPAD_TELEGRAM_API_ID", "AGENTPAD_TELEGRAM_API_HASH"] {
                if let pointer = getenv(key) { configuration[key] = String(cString: pointer) }
                unsetenv(key)
            }
        }
        let values = configuration
        initialization = Task { [weak self, factory] in
            let connector = await factory(values)
            guard let self else { return }
            self.connector = connector
            self.onConnector(connector)
            guard !self.stopping else { self.initialization = nil; return }
            let updates = await connector.snapshots()
            self.observation = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled else { return }
                    self?.receive(snapshot)
                }
            }
            await connector.restore()
            self.initialization = nil
        }
    }

    private func readyConnector() async -> (any TelegramConnector)? {
        start()
        await initialization?.value
        return stopping ? nil : connector
    }
    func whenInitialized() async { await initialization?.value }

    func connect() async {
        guard !isWorking, !stopping else { return }
        isWorking = true; defer { finishOperation() }
        guard let connector = await readyConnector() else { return }
        await connector.connect()
    }
    func retry() async {
        guard !isWorking, !stopping else { return }
        isWorking = true; defer { finishOperation() }
        guard let connector = await readyConnector() else { return }
        await connector.retry()
    }
    func retryPendingLogout() async {
        // Retry a persisted cleanup intent on network recovery, never an auth
        // attempt or a form submission. TDLib owns waits within each request.
        guard snapshot.state == .cleanupPending else { return }
        await retry()
    }
    func usePhone() async {
        guard !stopping else { return }
        let form = snapshot
        input = ""
        await connector?.usePhone(attemptID: form.attemptID, revision: form.revision)
    }
    func useQR() async {
        guard !stopping else { return }
        let form = snapshot
        input = ""
        await connector?.useQR(attemptID: form.attemptID, revision: form.revision)
    }
    func submit() async {
        guard !stopping, !snapshot.isSubmitting, !isWorking, !input.isEmpty else { return }
        let form = snapshot
        let value = input
        input = "" // release the UI buffer before the await, including 2FA
        let submission: TelegramAuthInput
        switch form.state {
        case .phoneNumber: submission = .phone(value)
        case .code: submission = .code(value)
        case .password: submission = .password(value)
        case .emailAddress: submission = .email(value)
        case .emailCode: submission = .emailCode(value)
        default: return
        }
        await connector?.submit(submission, attemptID: form.attemptID, revision: form.revision)
    }
    func resend() async {
        guard !stopping else { return }
        let form = snapshot
        input = ""
        await connector?.submit(.resend, attemptID: form.attemptID, revision: form.revision)
    }
    func disconnect() async {
        guard !isWorking, !stopping else { return }
        isWorking = true; input = ""; qrImage = nil; qrTask?.cancel()
        defer { finishOperation() }
        await connector?.disconnect()
    }
    func removeLocalData() async {
        guard !isWorking, !stopping else { return }
        isWorking = true; input = ""; qrImage = nil; qrTask?.cancel()
        defer { finishOperation() }
        await connector?.removeLocalData()
    }
    func shutdown() async {
        stopping = true
        input = ""; qrImage = nil; qrTask?.cancel()
        await initialization?.value
        if isWorking { await withCheckedContinuation { operationWaiters.append($0) } }
        if let connector {
            // Keep awaiting Closed after a diagnostic timeout. AppDelegate's
            // existing termination fallback bounds an unresponsive process;
            // a timed-out close alone is not a clean database shutdown.
            while !(await connector.close()) { }
        }
        observation?.cancel(); observation = nil
    }

    private func finishOperation() {
        isWorking = false
        let waiters = operationWaiters; operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func receive(_ next: TelegramSnapshot) {
        guard !stopping else { return }
        let replaced = next.attemptID != snapshot.attemptID || next.revision != snapshot.revision
        let oldState = snapshot.state
        if replaced { input = "" }
        snapshot = next
        if oldState != next.state {
            switch next.state {
            case .disconnected, .loggingOut, .cleanupPending, .reauthenticationRequired: onInvalidate()
            default: break
            }
        }
        guard oldState != next.state || replaced else { return }
        qrTask?.cancel(); qrImage = nil
        guard case .qr(let link) = next.state else { return }
        qrTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .userInitiated) { TelegramQR.png(link) }.value
            guard !Task.isCancelled, let self, self.snapshot.attemptID == next.attemptID,
                  self.snapshot.revision == next.revision, let bytes else { return }
            self.qrImage = NSImage(data: bytes)
        }
    }
}

enum TelegramQR {
    /// Purely local. No network service, pasteboard, files, or telemetry.
    static func png(_ link: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
