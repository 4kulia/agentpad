import AppKit

/// Native window lifecycle remains outside the store's live-session transfer.
/// A failed adoption never exposes or persists an empty destination window.
@MainActor
enum NavigationWindowLifecycle {
    @discardableResult
    static func detach(_ sessionID: UUID, from source: AgentPadWindowController,
                       makeDestination: (WorkspaceStore) -> AgentPadWindowController,
                       discard: (AgentPadWindowController) -> Void) -> Bool {
        guard source.store.location(ofSessionId: sessionID) != nil else { return false }
        let responder = source.window?.firstResponder
        let destination = makeDestination(source.store)
        guard let workspace = destination.store.active, let pane = workspace.activePane,
              destination.store.handleTabDrop(droppedId: sessionID, to: pane, at: 0, in: workspace) else {
            discard(destination)
            source.window?.makeKeyAndOrderFront(nil)
            if let responder { source.window?.makeFirstResponder(responder) }
            return false
        }
        destination.window?.makeKeyAndOrderFront(nil)
        return true
    }

    static func shouldClose(_ controller: AgentPadWindowController, lastVisible: Bool,
                            terminating: Bool, removeSlot: () -> Bool) -> Bool {
        guard controller.store.tabCloseCoordinator.prepare(controller.store.allSessions),
              controller.store.flushPersistence() else { return false }
        if terminating { return true }
        if lastVisible {
            controller.hideInsteadOfClose()
            return false
        }
        guard removeSlot() else { return false }
        controller.persistedSlotRemoved = true
        return true
    }
}
