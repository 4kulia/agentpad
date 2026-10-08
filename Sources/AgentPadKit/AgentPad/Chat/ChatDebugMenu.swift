#if DEBUG
import AppKit

/// Debug menu: send `member.set_name` by hand (docs/agentpad/CHAT-PLAN.md
/// C2). Signing in goes only through the connection window (review C13-3).
@MainActor
enum ChatDebugMenu {
    static func setName() { SupportTabs.shared.settings(.advanced) }

    static func disconnect() {
        Task { await ChatService.shared.disconnect() }
    }

}
#endif
