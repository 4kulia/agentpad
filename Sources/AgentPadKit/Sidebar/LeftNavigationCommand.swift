import AppKit

enum LeftNavigationCommand: Int, CaseIterable, Hashable, Sendable {
    case toggleRail = 4100, togglePanel, workspaces, chat, files, team, previousWorkspace, nextWorkspace
    var title: String {
        switch self {
        case .toggleRail: "Toggle Workspaces Rail"
        case .togglePanel: "Toggle Panel"
        case .workspaces: "Workspaces…"
        case .chat: "Show Chat"
        case .files: "Show Files"
        case .team: "Show Team"
        case .previousWorkspace: "Previous Workspace"
        case .nextWorkspace: "Next Workspace"
        }
    }
    var key: String {
        switch self {
        case .toggleRail: "r"
        case .togglePanel: "s"
        case .workspaces: "0"
        default: ""
        }
    }
    var modifiers: NSEvent.ModifierFlags {
        self == .workspaces ? [.command, .option] : [.command, .control]
    }
}

extension WorkspaceStore {
    func performNavigationCommand(_ command: LeftNavigationCommand) {
        switch command {
        case .toggleRail: toggleWorkspaceRail()
        case .togglePanel: toggleNavigationPanel()
        case .workspaces: openWorkspaceList()
        case .chat: selectNavigationPanel(.chat, toggle: false)
        case .files: selectNavigationPanel(.files, toggle: false)
        case .team: selectNavigationPanel(.team, toggle: false)
        case .previousWorkspace, .nextWorkspace:
            guard let active = workspaces.firstIndex(where: { $0.id == activeWorkspaceId }), !workspaces.isEmpty else { return }
            let next = (active + (command == .previousWorkspace ? -1 : 1) + workspaces.count) % workspaces.count
            activateWorkspace(workspaces[next])
        }
    }

    @discardableResult
    func handleNavigationEscape() -> Bool {
        if let editing = workspaces.first(where: { $0.nameEdit.isEditing }) {
            editing.nameEdit.handle(.escape, save: { _ in nil })
            return true
        }
        guard navigationPresentation.list != .closed || navigationPresentation.narrowPanelOpen
                || navigationPresentation.previewWorkspaceID != nil else { return false }
        closeNavigation()
        return true
    }
}
