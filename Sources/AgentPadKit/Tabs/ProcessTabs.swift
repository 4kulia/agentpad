import AppKit
import SwiftUI

@MainActor
final class ProcessTabs {
    static let shared = ProcessTabs()
    let router: TabRouter
    init(router: TabRouter = .shared) { self.router = router }

    @discardableResult
    func close(_ targets: [Workspace], from store: WorkspaceStore, details: Bool = false) -> CloseWorkspaceBatch? {
        guard !targets.isEmpty else { return nil }
        let route: ToolRoute = details ? .workspaceDetails(targets[0].id) : .closeWorkspaces(intentID: UUID())
        // Freeze the affected sessions before opening the review in this workspace.
        let batch = CloseWorkspaceBatch(targets: targets, store: store, reviewRoute: route)
        guard let session = router.open(route, from: store), let state = session.tabState else { return nil }
        if details { state.navigation.selection = "close"; state.changed() }
        if let existing = state.closeWorkspaces, !existing.completed, existing.unchanged() { return existing }
        guard state.closeWorkspaces?.working != true else { return state.closeWorkspaces }
        state.confirmation.invalidate()
        state.closeWorkspaces = batch
        batch.state = state; batch.tabID = session.id; batch.router = router
        return batch
    }

    func transfer(_ sources: [URL], into directory: URL, mode: FileOperations.PasteMode,
                  from store: WorkspaceStore? = nil) -> FileTransferBatch? {
        guard let session = router.open(.fileOperations(operationID: UUID()), from: store), let state = session.tabState else { return nil }
        let snapshot = FileTransferSnapshot(sources: sources, directory: directory, mode: mode)
        state.navigation.fileTransfer = snapshot
        let batch = FileTransferBatch(snapshot, state: state, tabID: session.id)
        state.fileOperation = batch; state.changed()
        return batch
    }
}

@MainActor @Observable
final class CloseWorkspaceBatch {
    struct Row: Identifiable {
        let id: UUID
        let title: String
        let path: URL
        let parentID: UUID?
        let sessions: Set<UUID>
        let children: Set<UUID>
        var directoryDeleted = false
        var done = false
        var error: String?
    }
    var rows: [Row]
    var alsoDelete = false
    private(set) var message: String?
    private(set) var working = false
    var completed: Bool { rows.allSatisfy(\.done) }
    weak var store: WorkspaceStore?
    weak var state: TabState?
    var tabID: TabID?
    var router: TabRouter = .shared
    var removeDirectory: (WorkspaceStore, Workspace) async -> String? = { await $0.removeWorktreeDirectory($1) }
    private let reviewRoute: ToolRoute?
    private static let changedMessage = "The workspace contents changed. Review the updated list before closing."

    init(targets: [Workspace], store: WorkspaceStore, reviewRoute: ToolRoute? = nil) {
        self.store = store
        self.reviewRoute = reviewRoute
        rows = Self.snapshot(targets, store: store, reviewRoute: reviewRoute, tabID: nil)
    }
    private static func snapshot(_ targets: [Workspace], store: WorkspaceStore, reviewRoute: ToolRoute?, tabID: TabID?) -> [Row] {
        targets.sorted { $0.worktreeParentId != nil && $1.worktreeParentId == nil }.map { workspace in
            Row(id: workspace.id, title: workspace.title, path: workspace.diskPath, parentID: workspace.worktreeParentId,
                sessions: Set(workspace.root.allPanes.flatMap(\.tabs).filter {
                    $0.id != tabID && (reviewRoute == nil || $0.toolRoute != reviewRoute)
                }.map(\.id)),
                children: Set(store.workspaces.filter { $0.worktreeParentId == workspace.id }.map(\.id)))
        }
    }
    func unchanged() -> Bool {
        guard let store, !store.isTerminated else { return false }
        let completedIDs = Set(rows.filter(\.done).map(\.id))
        let remainingIDs = Set(rows.filter { !$0.done }.map(\.id))
        return rows.filter { !$0.done }.allSatisfy { row in
            guard let workspace = store.workspaces.first(where: { $0.id == row.id }) else { return false }
            let ids = Set(workspace.root.allPanes.flatMap(\.tabs).filter { $0.id != tabID }.map(\.id))
            let children = Set(store.workspaces.filter { $0.worktreeParentId == workspace.id }.map(\.id))
            return workspace.diskPath == row.path && workspace.worktreeParentId == row.parentID && ids == row.sessions
                && children == row.children.subtracting(completedIDs) && children.isSubset(of: remainingIDs)
        }
    }
    private func refreshReview() {
        message = Self.changedMessage
        guard let store, !store.isTerminated else { return }
        let previous = rows
        var targets = Set(rows.filter { !$0.done }.map(\.id))
        // Closing a parent always includes its current worktree family.
        while true {
            let expanded = targets.union(store.workspaces.filter { $0.worktreeParentId.map(targets.contains) == true }.map(\.id))
            if expanded == targets { break }
            targets = expanded
        }
        rows = previous.filter(\.done) + Self.snapshot(store.workspaces.filter { targets.contains($0.id) },
            store: store, reviewRoute: reviewRoute, tabID: tabID).map { row in
                var row = row
                row.directoryDeleted = previous.contains { $0.id == row.id && $0.path == row.path && $0.directoryDeleted }
                return row
            }
    }
    func request() {
        guard let state, let tabID, !working, !completed else { return }
        guard unchanged() else {
            state.confirmation.invalidate(); refreshReview(); return
        }
        if case .failed = state.confirmation.phase { state.confirmation.cancel() }
        message = nil
        let delete = alsoDelete
        state.confirmation.request(.init(tabID: tabID, targetID: "workspaces"), title: "Close these workspaces?",
            consequences: delete ? "Running processes will stop. Worktree directories will be removed with git worktree remove --force; merged branches may be deleted."
                : "Running processes will stop. All directories and branches will remain on disk.",
            verb: delete ? "Close and delete" : "Close workspaces", destructive: true,
            stillValid: { [weak self] in self?.unchanged() == true && self?.alsoDelete == delete },
            completion: { [weak self] accepted in
                guard let self else { return }
                if accepted, self.completed, let state = self.state, state.isPopup,
                   let tabID = self.tabID, let location = self.router.owner(of: tabID) {
                    location.store.popups.dismiss(location.session, reason: .applied)
                } else if !accepted, !self.working, !self.unchanged() { self.refreshReview() }
            },
            operation: { [weak self] in
                guard let self else { return }
                if let problem = await self.execute() { throw ProcessOperationError(problem) }
            })
    }

    func execute() async -> String? {
        guard let store, !working else { return Self.changedMessage }
        guard unchanged() else {
            state?.confirmation.invalidate(); refreshReview(); return Self.changedMessage
        }
        let sessions = store.allSessions.filter { session in rows.contains { !$0.done && $0.sessions.contains(session.id) } }
        guard store.tabCloseCoordinator.prepare(sessions) else { return "Some drafts could not be saved. Keep editing or retry before closing." }
        // The review is never part of the close targets, even for a last-tab close.
        if state?.isPopup != true {
            if let tabID, let location = router.owner(of: tabID), rows.contains(where: { $0.id == location.workspace.id }) {
                guard location.store.moveTabToNewWorkspace(tabID) != nil else { return "The close review could not be kept open." }
            } else if let tabID, let location = store.location(ofSessionId: tabID), rows.contains(where: { $0.id == location.workspace.id }) {
                guard store.moveTabToNewWorkspace(tabID) != nil else { return "The close review could not be kept open." }
            }
        }
        working = true
        defer { working = false }
        for i in rows.indices where !rows[i].done {
            rows[i].error = nil
            guard let workspace = store.workspaces.first(where: { $0.id == rows[i].id }) else {
                rows[i].error = "Workspace is no longer available."; continue
            }
            if store.workspaces.contains(where: { $0.worktreeParentId == workspace.id }) {
                rows[i].error = "A child worktree could not be closed."; continue
            }
            let rowSessions = Set(workspace.root.allPanes.flatMap(\.tabs).filter { $0.id != tabID }.map(\.id))
            guard rowSessions == rows[i].sessions, workspace.diskPath == rows[i].path,
                  workspace.worktreeParentId == rows[i].parentID else {
                rows[i].error = "The workspace changed. Nothing was closed."; continue
            }
            if alsoDelete, workspace.worktreeParentId != nil, !rows[i].directoryDeleted {
                if let error = await removeDirectory(store, workspace) { rows[i].error = error; continue }
                rows[i].directoryDeleted = true
            }
            guard Set(workspace.root.allPanes.flatMap(\.tabs).filter { $0.id != tabID }.map(\.id)) == rows[i].sessions,
                  workspace.diskPath == rows[i].path, workspace.worktreeParentId == rows[i].parentID,
                  !store.workspaces.contains(where: { $0.worktreeParentId == workspace.id }) else {
                rows[i].error = rows[i].directoryDeleted ? "The directory was removed, but the workspace changed and remains open." : "The workspace changed and remains open."
                continue
            }
            if state?.isPopup == true, store.workspaces.count == 1 { _ = store.addEmptyWorkspace() }
            store.closeWorkspace(workspace)
            rows[i].done = !store.workspaces.contains { $0.id == workspace.id }
            if !rows[i].done { rows[i].error = "The workspace could not be closed." }
        }
        if !unchanged() { refreshReview(); return Self.changedMessage }
        return rows.compactMap(\.error).first
    }

    func cancel() {
        guard !working, state?.confirmation.isExecuting != true,
              let tabID, let location = router.owner(of: tabID) else { return }
        state?.confirmation.cancel()
        if state?.isPopup == true { location.store.popups.dismiss(location.session, reason: .cancel) }
        else { location.store.closeTab(location.session, in: location.workspace) }
    }
}

struct CloseWorkspacesView: View {
    @Bindable var batch: CloseWorkspaceBatch
    var showWorkspaceDetails: (() -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            PopupScrollBody {
                VStack(alignment: .leading, spacing: 16) {
                    if batch.state?.isPopup != true { Text("Close workspaces").font(.title2) }
                    Text("Review \(batch.rows.count) \(batch.rows.count == 1 ? "workspace" : "workspaces") before closing.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let message = batch.message { Text(message).foregroundStyle(.orange) }
                    ForEach(batch.rows) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(row.title + (row.parentID == nil ? "" : " · worktree")).font(.headline)
                            Text(row.path.path).font(.caption.monospaced()).textSelection(.enabled)
                            if row.done { Text("Closed").font(.caption).foregroundStyle(.green) }
                            if let error = row.error { Text(error).foregroundStyle(.red) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(Theme.chromeHover.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.chromeHairline))
                    }
                    if !batch.completed {
                        if batch.rows.contains(where: { $0.parentID != nil && !$0.done }) {
                            Toggle("Also delete worktree directories and merged branches", isOn: $batch.alsoDelete)
                                .disabled(batch.working || batch.state?.confirmation.isAwaiting == true)
                                .accessibilityIdentifier("close-workspaces-delete-worktrees")
                        }
                        Text(batch.alsoDelete
                            ? "Running processes in these workspaces will stop. Worktree directories will be removed; merged branches may be deleted."
                            : "Running processes in these workspaces will stop. Directories and branches stay on disk.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        Text("Outside click and Esc cannot dismiss this confirmation.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let showWorkspaceDetails {
                    Button("Workspace details", action: showWorkspaceDetails)
                        .disabled(batch.working || batch.state?.confirmation.isExecuting == true)
                        .accessibilityIdentifier("close-workspaces-details")
                }
                Spacer()
                Button("Cancel") { batch.cancel() }
                    .disabled(batch.working || batch.state?.confirmation.isExecuting == true)
                    .accessibilityIdentifier("close-workspaces-cancel")
                if !batch.completed {
                    Button("Close remaining workspaces…", role: .destructive) { batch.request() }
                        .buttonStyle(PopupPrimaryButtonStyle(destructive: true))
                        .disabled(batch.working || batch.state?.confirmation.showsBlock == true)
                        .accessibilityIdentifier("close-workspaces-accept")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("close-workspaces-content")
    }
}
