import SwiftUI

extension View {
    func tabDropHighlight(_ active: Bool) -> some View {
        background(active ? Color.accentColor.opacity(0.12) : .clear,
                   in: RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: Theme.chromeSelectionCornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    func workspaceTabDropTarget(store: WorkspaceStore, workspace: Workspace) -> some View {
        modifier(WorkspaceTabDropTarget(store: store, workspace: workspace))
    }
}

/// Worktree children accept tabs too, but keep their fixed family ordering.
private struct WorkspaceTabDropTarget: ViewModifier {
    let store: WorkspaceStore
    let workspace: Workspace
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .tabDropHighlight(isTargeted && store.draggedTab.map { store.canDropTab($0.id, in: workspace) } == true)
            .dropDestination(for: String.self) { dropped, _ in
                defer { store.draggingTabId = nil; store.finishNavigationDrag() }
                guard let id = dropped.first.flatMap(UUID.init) else { return false }
                return store.handleTabDrop(droppedId: id, in: workspace)
            } isTargeted: {
                isTargeted = $0
                store.setRailDragTarget(workspace.id.uuidString, entered: $0)
            }
    }
}

struct NewWorkspaceDropZone: View {
    let store: WorkspaceStore
    let isCompact: Bool
    @State private var isTargeted = false

    var body: some View {
        let dragging = store.draggedTab != nil
        Button { store.closeNavigation(restoreFocus: false); store.addWorkspace() } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 17))
                if !isCompact { Text("New").font(Theme.display(9)) }
            }
            .foregroundStyle(isTargeted && dragging ? Color.accentColor : Theme.chromeMuted)
            .frame(maxWidth: .infinity).frame(height: isCompact ? 40 : 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if dragging {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .tabDropHighlight(isTargeted && dragging)
        .help("New workspace · ⌘N\nDrag a tab here to create a workspace")
        .accessibilityLabel("New workspace")
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil; store.finishNavigationDrag() }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            guard store.moveTabToNewWorkspace(id) != nil else { return false }
            store.closeNavigation(restoreFocus: false)
            return true
        } isTargeted: {
            isTargeted = $0
            store.setRailDragTarget("new-workspace", entered: $0)
        }
    }
}
