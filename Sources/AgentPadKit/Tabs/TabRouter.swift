import Foundation

@MainActor
final class TabRouter {
    static let shared: TabRouter = {
        let router = TabRouter()
        // Even a direct router entry before SupportTabs is installed must wait.
        router.admit = { SupportTabs.shared.navigation.admit($0) }
        return router
    }()
    struct Location {
        let store: WorkspaceStore
        let workspace: Workspace
        let pane: Pane
        let session: Session
    }
    var stores: () -> [WorkspaceStore] = { [] }
    var ensureHost: () -> WorkspaceStore? = { nil }
    var revealWindow: (WorkspaceStore) -> Void = { _ in }
    var admit: ((@escaping () -> Void) -> Bool)?
    var prepareDestinations: () -> Void = { AttentionSidebarModel.shared.updateProjection() }
    var destinations: () -> [UUID: AttentionTabSnapshot] = { AttentionSidebarModel.shared.projection.tabs }
    var channelScope: (ChannelRef) -> AttentionScope? = { ref in
        let service = ChatService.shared
        guard let key = service.connection?.orgKey, ref.belongs(to: key),
              ChatNotifications.allowed(service, key, channel: ref.channel) else { return nil }
        return ChatAttention.scope(key, service)
    }

    func owner(of id: TabID) -> Location? {
        for store in stores() where !store.isTerminated {
            if let location = store.popups.location(of: id) { return location }
            for workspace in store.workspaces {
                for pane in workspace.root.allPanes {
                    if let session = pane.tabs.first(where: { $0.id == id }) {
                        return Location(store: store, workspace: workspace, pane: pane, session: session)
                    }
                }
            }
        }
        return nil
    }
    func owner(of state: TabState) -> Location? {
        for store in stores() where !store.isTerminated {
            if let session = (store.allSessions + store.popups.sessions).first(where: { $0.tabState === state }) {
                return owner(of: session.id)
            }
        }
        return nil
    }
    func find(_ route: ToolRoute, windowID: UUID) -> Location? {
        if route.presentation == .popup {
            return stores().first { !$0.isTerminated && $0.windowID == windowID }?.popups.find(route)
        }
        let key = route.key(windowID: windowID)
        var matches: [Location] = []
        for store in stores() where !store.isTerminated {
            if route.isConversation && store.windowID != windowID { continue }
            for workspace in store.workspaces {
                for pane in workspace.root.allPanes {
                    for session in pane.tabs where session.toolRoute?.key(windowID: store.windowID) == key {
                        matches.append(Location(store: store, workspace: workspace, pane: pane, session: session))
                    }
                }
            }
        }
        return preferred(matches, windowID: windowID)
    }

    /// Conversations prefer the initiating window, then the most recently
    /// activated tab, with stable IDs breaking ties (including detached windows).
    private func preferred(_ matches: [Location], windowID: UUID) -> Location? {
        matches.sorted { a, b in
            let localA = a.store.windowID == windowID, localB = b.store.windowID == windowID
            if localA != localB { return localA }
            if a.session.lastActivated != b.session.lastActivated { return a.session.lastActivated > b.session.lastActivated }
            if a.store.windowID != b.store.windowID { return a.store.windowID.uuidString < b.store.windowID.uuidString }
            return a.session.id.uuidString < b.session.id.uuidString
        }.first
    }

    @discardableResult
    func openChannel(_ ref: ChannelRef, scope: AttentionScope? = nil, from initiator: WorkspaceStore? = nil, asTab: Bool = false) -> Session? {
        let asTab = asTab || ConversationOpenIntent.commandClick
        if let admit, !admit({ [weak self, weak initiator] in self?.openChannel(ref, scope: scope, from: initiator, asTab: asTab) }) { return nil }
        guard let store = initiator ?? ensureHost(), !store.isTerminated,
              let currentScope = channelScope(ref), scope == nil || scope == currentScope else { return nil }
        guard channelScope(ref) == currentScope else { return nil }
        return store.showChannel(ref, asTab: asTab)
    }
    @discardableResult
    func open(_ route: ToolRoute, from initiator: WorkspaceStore? = nil, section: SettingsTabSection? = nil,
              load: ((TabState) async -> Void)? = nil, asTab: Bool = false) -> Session? {
        let asTab = asTab || ConversationOpenIntent.commandClick
        if let admit, !admit({ [weak self, weak initiator] in
            self?.open(route, from: initiator, section: section, load: load, asTab: asTab)
        }) { return nil }
        guard let store = initiator ?? ensureHost(), !store.isTerminated else { return nil }
        if route.isConversation {
            let session = asTab ? store.popups.openConversationAsTab(.tool(route)) : store.popups.presentConversation(.tool(route))
            if let state = session?.tabState, let load { Task { await load(state) } }
            return session
        }
        if route.presentation == .popup {
            let existing = store.popups.find(route)
            let session = store.popups.present(route)
            if let section { session.tabState?.select(section) }
            revealWindow(store)
            if existing == nil, let load, let state = session.tabState { Task { await load(state) } }
            return session
        }
        if let existing = find(route, windowID: store.windowID) {
            if let section { existing.session.tabState?.select(section) }
            reveal(existing); return existing.session
        }
        // Reserve synchronously on MainActor, before any asynchronous loading.
        let session = store.openToolTab(route)
        if let section { session.tabState?.select(section) }
        revealWindow(store)
        if let load, let state = session.tabState { Task { await load(state) } }
        return session
    }
    func reveal(_ location: Location) {
        if location.session.isConversationPopup {
            location.store.popups.presentConversation(location.session)
            return
        }
        if location.store.popups.contains(location.session.id), let route = location.session.toolRoute {
            location.store.popups.present(route)
            revealWindow(location.store)
            return
        }
        location.store.popups.leaveForContent { [weak self] in
            location.workspace.zoomedPaneId = nil
            location.store.activateWorkspace(location.workspace)
            location.store.activateTab(location.session, in: location.workspace)
            self?.revealWindow(location.store)
        }
    }
    @discardableResult
    func rekey(_ id: TabID, to route: ToolRoute) -> Session? {
        guard let current = owner(of: id), let state = current.session.tabState else { return nil }
        if current.session.isConversationPopup, route.isConversation {
            state.leave(); state.route = route; current.session.content = .tool(route)
            return current.session
        }
        if current.store.popups.contains(id) {
            if route.presentation == .popup {
                state.route = route; current.session.content = .tool(route)
                return current.session
            }
            current.store.popups.dismiss(current.session, reason: .applied)
            return open(route, from: current.store)
        }
        if route.presentation == .popup {
            guard current.store.tabCloseCoordinator.prepare([current.session]) else { return nil }
            current.store.closeTab(current.session, in: current.workspace)
            return open(route, from: current.store)
        }
        if let existing = find(route, windowID: current.store.windowID), existing.session.id != id {
            // Save before coalescing; a conflicting edit stays in DraftRepository.
            guard current.store.tabCloseCoordinator.prepare([current.session]) else { return nil }
            current.store.closeTab(current.session, in: current.workspace)
            reveal(existing); return existing.session
        }
        state.leave(); state.route = route; current.session.content = .tool(route)
        current.store.scheduleSave()
        return current.session
    }
    @discardableResult
    func rekey(_ id: TabID, to channel: ChannelRef) -> Session? {
        if let current = owner(of: id), current.store.popups.contains(id) {
            current.store.popups.dismiss(current.session, reason: .applied)
            return current.store.showChannel(channel)
        }
        guard let current = owner(of: id), current.session.toolRoute != nil,
              current.store.tabCloseCoordinator.prepare([current.session]) else { return nil }
        for store in stores() where !store.isTerminated {
            if let (existing, _) = store.channelTab(channel), let location = owner(of: existing.id) {
                current.store.closeTab(current.session, in: current.workspace)
                reveal(location)
                return existing
            }
        }
        current.store.replaceToolWithChannel(current.session, ref: channel)
        return current.session
    }

    /// Restore never loads data or repeats actions. Duplicate addresses collapse,
    /// while their independently persisted drafts remain in the repository.
    func reconcileRestoredTabs() {
        var seen: Set<TabKey> = []
        for store in stores() where !store.isTerminated {
            for workspace in store.workspaces {
                for pane in workspace.root.allPanes {
                    let duplicates = pane.tabs.filter { session in
                        guard let route = session.toolRoute else { return false }
                        return !seen.insert(route.key(windowID: store.windowID)).inserted
                    }
                    for session in duplicates {
                        session.engine.terminate()
                        pane.tabs.removeAll { $0 === session }
                        if session.toolRoute == .connection, let existing = find(.connection, windowID: store.windowID) {
                            reveal(existing)
                        }
                    }
                    if !pane.tabs.contains(where: { $0.id == pane.activeTabId }) { pane.activeTabId = pane.tabs.first?.id }
                }
            }
        }
    }
}
