import AppKit
import Foundation
import Network

/// Calls back on the main actor when the Mac's network path changes (a new
/// Wi-Fi, a VPN, back online), so the server connection retries at once (C3).
@MainActor
final class TeamNetworkWatch {
    static let shared = TeamNetworkWatch()
    private var monitor: NWPathMonitor?
    private var last: NWPath.Status?
    private var subscribers: [@MainActor () -> Void] = []

    /// Adds a subscriber; the path monitor starts with the first one.
    func add(onChange: @escaping @MainActor () -> Void) {
        subscribers.append(onChange)
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let status = path.status
            Task { @MainActor in TeamNetworkWatch.shared.pathChanged(status) }
        }
        monitor.start(queue: DispatchQueue(label: "agentpad.team.network"))
        self.monitor = monitor
    }

    func pathChanged(_ status: NWPath.Status) {
        defer { last = status }
        // The first report is the state at start, not a change.
        guard last != nil, status == .satisfied else { return }
        for subscriber in subscribers { subscriber() }
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
