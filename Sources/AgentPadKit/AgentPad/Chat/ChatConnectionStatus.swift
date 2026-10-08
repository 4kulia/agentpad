import SwiftUI

/// Connection presentation is separate from the sidebar's access/cache gate.
/// Reconnecting and terminal errors must not be hidden by cached channels.
enum ChatConnectionStatus: Equatable {
    case connected, connecting, checking, offline, notConnected, unavailable, error

    init(snapshot: ChatSidebarSnapshot.State, service: ChatService.State, socket: ChatSocket.State?) {
        switch service {
        case .needsSignIn, .notMember: self = .error; return
        default: break
        }
        switch socket {
        case .failed, .needsSignIn: self = .error; return
        case .connecting: self = .connecting; return
        default: break
        }
        switch snapshot {
        case .ready(let offline): self = offline ? .offline : (socket == .disconnected ? .connecting : .connected)
        case .checking: self = .checking
        case .noChannels: self = .unavailable
        case .notConnected: self = .notConnected
        }
    }

    var text: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .checking: "Checking access…"
        case .offline: "Offline · cached channels"
        case .notConnected: "Not connected"
        case .unavailable: "Channels unavailable"
        case .error: "Connection error"
        }
    }
    var icon: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting, .checking: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.circle.fill"
        default: "network.slash"
        }
    }
    @MainActor var color: Color {
        switch self {
        case .connected: ChatAppearance.success
        case .connecting, .checking: ChatAppearance.attention
        case .error: ChatAppearance.failure
        case .offline, .notConnected, .unavailable: ChatAppearance.secondary
        }
    }
}

struct ChatConnectionLabel: View {
    let status: ChatConnectionStatus
    var body: some View {
        Label {
            Text(status.text).foregroundStyle(ChatAppearance.secondary)
        } icon: {
            Image(systemName: status.icon).foregroundStyle(status.color)
        }.font(Theme.display(10))
    }
}
