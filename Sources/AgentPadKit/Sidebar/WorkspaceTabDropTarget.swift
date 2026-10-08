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
                defer { store.draggingTabId = nil }
                guard let id = dropped.first.flatMap(UUID.init) else { return false }
                return store.handleTabDrop(droppedId: id, in: workspace)
            } isTargeted: { isTargeted = $0 }
    }
}

struct NewWorkspaceDropZone: View {
    let store: WorkspaceStore
    let isCompact: Bool
    @State private var isTargeted = false

    var body: some View {
        let dragging = store.draggedTab != nil
        Button { store.addWorkspace() } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    if !isCompact { Text("New workspace") }
                }
                if !isCompact {
                    Text(dragging ? "Release to create a workspace\nEsc to cancel" : "Drag a tab here\nto create a workspace")
                        .font(Theme.display(11))
                        .multilineTextAlignment(.center)
                }
            }
            .font(Theme.display(12))
            .foregroundStyle(isTargeted && dragging ? Color.accentColor : Theme.chromeMuted)
            .padding(.vertical, isCompact ? 12 : 18)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dragging ? Color.accentColor.opacity(0.65) : Theme.chromeHairline,
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
        .tabDropHighlight(isTargeted && dragging)
        .help("Drag a tab here to create a workspace")
        .dropDestination(for: String.self) { dropped, _ in
            defer { store.draggingTabId = nil }
            guard let id = dropped.first.flatMap(UUID.init) else { return false }
            return store.moveTabToNewWorkspace(id) != nil
        } isTargeted: { isTargeted = $0 }
        .padding(Theme.space2)
    }
}
