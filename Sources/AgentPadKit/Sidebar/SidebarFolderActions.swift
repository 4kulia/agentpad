import AgentPadTelegram
import Foundation
import Observation

/// Runtime-only presentation boundary for the generic chooser. Telegram
/// references are profile-bound and are never encoded into workspace state.
@MainActor @Observable final class SidebarFolderActions {
    static let shared = SidebarFolderActions()
    struct Request: Identifiable, Equatable {
        let id = UUID()
        var item: SidebarItemReference
        var binding: TelegramProfileBinding?
        var windowID: UUID?
        var anchor: String?
    }
    var request: Request?
    let folders = SidebarFoldersModel()
    func present(_ item: SidebarItemReference, binding: TelegramProfileBinding? = nil, windowID: UUID? = nil, anchor: String? = nil) {
        if case .telegram = item, binding == nil { return }
        folders.start()
        request = .init(item: item, binding: binding, windowID: windowID, anchor: anchor)
    }
    func invalidateTelegram(binding: TelegramProfileBinding?) {
        if case .telegram = request?.item, request?.binding != binding { request = nil }
    }
}
