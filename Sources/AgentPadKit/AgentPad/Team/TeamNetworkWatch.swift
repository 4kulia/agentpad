import AppKit
import Foundation
import Network

/// Coalesces recovery and changes of used interfaces. Repeated reports of
/// the same working path must not interrupt a healthy server connection.
@MainActor
final class TeamNetworkWatch {
    struct Path: Equatable, Sendable {
        var status: NWPath.Status
        var interfaces: Set<String>

        init(status: NWPath.Status, interfaces: Set<String> = []) {
            self.status = status
            self.interfaces = interfaces
        }

        init(_ path: NWPath) {
            status = path.status
            interfaces = Set(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.name):\($0.index)" })
        }
    }

    static let shared = TeamNetworkWatch()
    private var monitor: NWPathMonitor?
    private var last: Path?
    private var pending: Task<Void, Never>?
    private let monitorsNetwork: Bool
    private let coalescingDelay: Duration
    private var subscribers: [@MainActor () -> Void] = []

    init(monitorsNetwork: Bool = true, coalescingDelay: Duration = .milliseconds(250)) {
        self.monitorsNetwork = monitorsNetwork
        self.coalescingDelay = coalescingDelay
    }

    /// Adds a subscriber; the path monitor starts with the first one.
    func add(onChange: @escaping @MainActor () -> Void) {
        subscribers.append(onChange)
        guard monitorsNetwork, monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Path(path)
            Task { @MainActor [weak self] in self?.pathChanged(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "agentpad.team.network"))
        self.monitor = monitor
    }

    func pathChanged(_ path: Path) {
        let previous = last
        last = path
        guard path.status == .satisfied else {
            pending?.cancel()
            pending = nil
            return
        }
        // The first report is the state at start, not a change.
        guard let previous, previous.status != .satisfied || previous.interfaces != path.interfaces else { return }
        pending?.cancel()
        let delay = coalescingDelay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            for subscriber in self.subscribers { subscriber() }
        }
    }
}

/// Calls back on the main actor when the Mac wakes from sleep — every
/// subscriber, not only the first (C0).
@MainActor
final class TeamWake {
    static let shared = TeamWake()
    private var observer: NSObjectProtocol?
    private var subscribers: [@MainActor () -> Void] = []

    func add(onWake: @escaping @MainActor () -> Void) {
        subscribers.append(onWake)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in TeamWake.shared.woke() }
        }
    }

    func woke() {
        for subscriber in subscribers { subscriber() }
    }
}
