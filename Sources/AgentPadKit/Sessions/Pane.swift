import Foundation

/// One leaf region of a workspace's split tree. Owns its own tab list and
/// active-tab pointer — splitting a workspace creates more `Pane`s, each with
/// an independent tab strip rendered above its content.
@MainActor
@Observable
final class Pane: Identifiable {
    let id: UUID
    var tabs: [Session]
    var activeTabId: UUID?

    init(id: UUID = UUID(), tabs: [Session] = [], activeTabId: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
    }

    var activeTab: Session? { tabs.first { $0.id == activeTabId } }
}
