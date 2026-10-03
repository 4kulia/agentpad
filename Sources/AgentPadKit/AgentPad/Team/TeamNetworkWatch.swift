import Foundation
import Network

/// Calls back on the main actor when the Mac's network path changes (a new
/// Wi-Fi, a VPN, back online), so team deliveries retry at once (TEAM.md D-3).
@MainActor
final class TeamNetworkWatch {
    static let shared = TeamNetworkWatch()
    private var monitor: NWPathMonitor?
    private var last: NWPath.Status?

    func start(onChange: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let status = path.status
            Task { @MainActor in
                let watch = TeamNetworkWatch.shared
                defer { watch.last = status }
                // The first report is the state at start, not a change.
                guard watch.last != nil, status == .satisfied else { return }
                onChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "agentpad.team.network"))
        self.monitor = monitor
    }
}
