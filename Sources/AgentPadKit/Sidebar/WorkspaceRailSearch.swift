import Foundation

struct WorkspaceRailDestination: Hashable {
    var workspaceID: UUID
    var sessionID: UUID?
}

/// Prepared from in-memory routing and name caches, never by a row body.
/// DM titles and permissions must not fall back to synchronous database reads.
struct WorkspaceRailEntry: Identifiable, Equatable {
    struct Tab: Identifiable, Equatable {
        var id: UUID
        var title: String
        var detail: String
    }
    var id: UUID
    var title: String
    var path: String
    var tabs: [Tab]
    var parentID: UUID? = nil
}

enum WorkspaceRailSearch {
    struct Match: Identifiable, Equatable {
        var entry: WorkspaceRailEntry
        var workspaceMatches: Bool
        var tabs: [WorkspaceRailEntry.Tab]
        var id: UUID { entry.id }
    }

    static func matches(_ entries: [WorkspaceRailEntry], query: String, collapsedParents: Set<UUID> = []) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.compactMap { entry in
            if query.isEmpty, let parent = entry.parentID, collapsedParents.contains(parent) { return nil }
            let workspaceMatches = query.isEmpty || entry.title.localizedStandardContains(query)
            let tabs = entry.tabs.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            guard workspaceMatches || !tabs.isEmpty else { return nil }
            return Match(entry: entry, workspaceMatches: workspaceMatches,
                         tabs: workspaceMatches ? entry.tabs : tabs)
        }
    }

    /// Workspace headers remain context for tab-only matches; Return must
    /// select the matching tab, not the workspace's previously selected tab.
    static func destinations(_ matches: [Match]) -> [WorkspaceRailDestination] {
        matches.flatMap { match in
            (match.workspaceMatches ? [WorkspaceRailDestination(workspaceID: match.id)] : [])
                + match.tabs.map { WorkspaceRailDestination(workspaceID: match.id, sessionID: $0.id) }
        }
    }

    static func moved(_ selection: WorkspaceRailDestination?, by delta: Int,
                      in rows: [WorkspaceRailDestination]) -> WorkspaceRailDestination? {
        guard !rows.isEmpty else { return nil }
        let index = selection.flatMap { rows.firstIndex(of: $0) } ?? (delta < 0 ? rows.count : -1)
        return rows[min(rows.count - 1, max(0, index + delta))]
    }
}

extension WorkspaceStore {
    func workspaceRailEntries(attention: AttentionSidebarModel = .shared) -> [WorkspaceRailEntry] {
        workspaces.map { workspace in
            WorkspaceRailEntry(id: workspace.id, title: workspace.title, path: workspace.workingDirectory.path,
                tabs: workspace.root.allPanes.flatMap(\.tabs).compactMap { tab in
                    let snapshot = attention.projection.tabs[tab.id]
                    guard snapshot?.available ?? tab.hasProcess else { return nil }
                    return WorkspaceRailEntry.Tab(id: tab.id, title: attention.tabTitle(tab),
                        detail: tab.hasProcess ? tab.displayAgent.title : "Tab")
                }, parentID: workspace.worktreeParentId)
        }
    }

    @discardableResult
    func activateRailDestination(_ destination: WorkspaceRailDestination, attention: AttentionSidebarModel = .shared) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == destination.workspaceID }) else { return false }
        if let id = destination.sessionID {
            guard let tab = workspace.root.pane(containingSessionId: id)?.tabs.first(where: { $0.id == id }),
                  attention.projection.tabs[tab.id]?.available ?? tab.hasProcess else { return false }
            // Only the same tab can reuse the navigation owner's editor.
            // A different destination takes focus through its own host/editor.
            closeNavigation(restoreFocus: active === workspace && workspace.activeSession === tab)
            activateWorkspace(workspace)
            activateTab(tab, in: workspace)
        } else {
            closeNavigation(restoreFocus: active === workspace)
            activateWorkspace(workspace)
        }
        return true
    }
}
