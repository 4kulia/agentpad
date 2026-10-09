import Foundation

struct WorktreeFormDraft: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case newBranch, existing, adopt }
    var mode: Mode = .newBranch
    var branch = ""
    var existingBranch = ""
    var startRef = ""
    var directory = ""
    var templateID = AgentTemplate.terminal.id
    var adoptPaths: Set<String> = []
}

struct WorkspaceTagDraft: Codable, Equatable {
    var name = ""
    var hex = WorkspaceColorTag.blue.hex
    var seededPreset: String?
}

/// Owned by TabState: remounting never resets input or starts a second load.
@MainActor @Observable
final class LocalFormState {
    let titleEdit = InlineNameEdit()
    var name = "" { didSet { saveSSH() } }
    var host = "" { didSet { saveSSH() } }
    var directory = "" { didSet { saveSSH() } }
    var newAgent = NewAgentDraft() { didSet { changed(.newAgent(newAgent)) } }
    var worktree = WorktreeFormDraft() { didSet { changed(.worktreeForm(worktree)) } }
    var tag = WorkspaceTagDraft() { didSet { changed(.workspaceTag(tag)) } }
    var error: String?
    var working = false
    var completed = false
    var loaded = false
    var loading = false
    var branches: [String] = []
    var diskWorktrees: [WorktreeManager.Info] = []
    @ObservationIgnored var changed: (TabDraft.Payload) -> Void = { _ in }

    private func saveSSH() { changed(.ssh(name: name, host: host, directory: directory)) }
    static func sshProblem(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "Enter an SSH destination." }
        guard !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !host.contains("/"), host.split(separator: "@", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              host.filter({ $0 == "@" }).count <= 1 else {
            return "Enter a host or user@host, without options or spaces. SSH config aliases are supported."
        }
        return nil
    }
}

@MainActor
final class LocalFormTabs {
    static let shared = LocalFormTabs()
    let router: TabRouter
    var addWorktree: @MainActor (URL, URL, WorktreeManager.BranchMode) async -> Result<Void, WorktreeManager.GitError> = { root, path, mode in
        await Task.detached(priority: .userInitiated) { WorktreeManager.add(repoPath: root, path: path, mode: mode) }.value
    }
    var agentTemplates: () -> [AgentTemplate] = { AgentTemplate.visibleOrdered(model: .shared).filter { !$0.isShell } }
    var agentOptions: (String) -> String = { AgentPadSettingsModel.shared.agentOptions[$0] ?? "" }
    init(router: TabRouter = .shared) { self.router = router }

    @discardableResult
    func newAgent(from store: WorkspaceStore? = nil) -> Session? {
        let existing = existingDraft { if case .newAgent = $0 { true } else { false } }
        return router.open(existing ?? .newAgent(draftID: UUID()), from: store)
    }

    func duplicateAgent(_ state: TabState) -> AgentProfile? {
        let draft = form(state).newAgent
        guard !draft.folder.isEmpty, let store = owner(state)?.store,
              let template = agentTemplates().first(where: { $0.id == draft.templateID }) else { return nil }
        return store.agentProfiles.existing(rosterID: template.rosterId, folder: URL(fileURLWithPath: draft.folder))
    }

    func addAgent(_ state: TabState) {
        let form = form(state)
        guard !state.isClosed, !form.completed, let location = owner(state) else { return }
        let draft = form.newAgent
        guard let template = agentTemplates().first(where: { $0.id == draft.templateID }) else {
            form.error = "Choose an agent type."; return
        }
        guard !draft.folder.isEmpty else { form.error = "Choose a folder."; return }
        if duplicateAgent(state) == nil, let error = InlineNameEdit.problem(draft.name) { form.error = error; return }
        do {
            let profile = try location.store.agentProfiles.add(template: template,
                folder: URL(fileURLWithPath: draft.folder), name: draft.name, launchOptions: agentOptions(template.id))
            form.error = nil
            location.store.revealAgentProfile(profile.id)
            finish(state, submittedDraft: state.draft)
        } catch { form.error = error.localizedDescription }
    }

    func owner(_ state: TabState) -> TabRouter.Location? {
        for store in router.stores() {
            if let session = store.allSessions.first(where: { $0.tabState === state }) { return router.owner(of: session.id) }
        }
        return nil
    }
    func workspace(_ id: UUID) -> (store: WorkspaceStore, workspace: Workspace)? {
        for store in router.stores() where !store.isTerminated {
            if let workspace = store.workspaces.first(where: { $0.id == id }) { return (store, workspace) }
        }
        return nil
    }
    private func existingDraft(where matches: (ToolRoute) -> Bool) -> ToolRoute? {
        let stores = router.stores().filter { !$0.isTerminated }
        return stores.flatMap(\.allSessions).compactMap(\.toolRoute).first(where: matches)
            ?? stores.flatMap { $0.drafts.drafts }.sorted { $0.revision > $1.revision }.map(\.route).first(where: matches)
    }

    @discardableResult
    func newSSH(from store: WorkspaceStore, newDraft: Bool = false) -> Session? {
        let existing = newDraft ? nil : existingDraft { if case .newSSH = $0 { true } else { false } }
        guard let session = router.open(existing ?? .newSSH(draftID: UUID()), from: store), let state = session.tabState else { return nil }
        let form = form(state)
        if state.draft == nil {
            // The local launch folder is pinned as well as the typed host.
            form.directory = store.active?.workingDirectory.path ?? NSHomeDirectory()
        }
        return session
    }

    @discardableResult
    func newWorktree(source: Workspace, from store: WorkspaceStore, newDraft: Bool = false) -> Session? {
        let existing = newDraft ? nil : existingDraft {
            if case .newWorktree(_, let id, _) = $0 { id == source.id } else { false }
        }
        let route: ToolRoute
        if let existing { route = existing }
        else {
            let cwd = canonicalDiskPath(source.diskPath)
            let root = GitWatcher.worktreeRoot(near: cwd) ?? cwd
            route = .newWorktree(repository: canonicalDiskPath(root).path, sourceWorkspaceID: source.id, draftID: UUID())
        }
        return router.open(route, from: store)
    }

    @discardableResult
    func details(_ workspace: Workspace, from store: WorkspaceStore) -> Session? {
        router.open(.workspaceDetails(workspace.id), from: store)
    }

    func form(_ state: TabState) -> LocalFormState {
        if let form = state.localForm { return form }
        let form = LocalFormState()
        restoreInputs(form, from: state)
        form.changed = { [weak state] in state?.edit($0) }
        state.localForm = form
        state.discardEdits = { [weak self, weak state] in
            guard let state, let form = state.localForm else { return }
            self?.restoreInputs(form, from: state)
        }
        return form
    }

    private func restoreInputs(_ form: LocalFormState, from state: TabState) {
        // Restoring saved input must not emit edits or replace loaded/working state.
        let changed = form.changed
        form.changed = { _ in }
        defer { form.changed = changed }
        form.name = ""; form.host = ""; form.directory = ""
        form.newAgent = NewAgentDraft(templateID: agentTemplates().first?.id ?? "")
        form.worktree = WorktreeFormDraft()
        form.tag = WorkspaceTagDraft()
        form.error = nil
        switch state.draft?.payload {
        case .newAgent(let draft): form.newAgent = draft
        case .ssh(let name, let host, let directory): form.name = name; form.host = host; form.directory = directory
        case .worktreeForm(let draft): form.worktree = draft
        case .worktree(let branch, let directory): form.worktree.branch = branch; form.worktree.directory = directory
        case .workspaceTag(let draft): form.tag = draft
        default:
            if case .workspaceDetails(let id) = state.route, let tag = workspace(id)?.workspace.tag {
                form.tag = WorkspaceTagDraft(name: tag.name ?? "", hex: tag.colorHex, seededPreset: tag.color.preset?.rawValue)
            }
            if case .newWorktree = state.route {
                form.worktree.templateID = AgentTemplate.defaultLaunchTemplate(model: .shared)?.id ?? AgentTemplate.terminal.id
            }
        }
    }

    func createSSH(_ state: TabState) {
        let form = form(state)
        guard !form.working, !form.completed, let location = owner(state) else { return }
        form.error = LocalFormState.sshProblem(form.host) ?? InlineNameEdit.problem(form.name)
        guard form.error == nil else { return }
        let submittedDraft = state.draft
        let directory = URL(fileURLWithPath: form.directory.isEmpty ? NSHomeDirectory() : form.directory)
        let workspace = location.store.addWorkspace(workingDirectory: directory,
            sshRemoteHost: form.host.trimmingCharacters(in: .whitespacesAndNewlines))
        location.store.renameWorkspace(workspace, to: form.name)
        finish(state, submittedDraft: submittedDraft)
    }

    func loadWorktree(_ state: TabState) async {
        let form = form(state)
        guard !form.loaded, !form.loading, case .newWorktree(let path, _, _) = state.route else { return }
        form.loading = true
        let root = URL(fileURLWithPath: path)
        let (branches, worktrees) = await Task.detached(priority: .userInitiated) {
            (GitBranchInventory.localBranches(cwd: root), WorktreeManager.list(repoPath: root))
        }.value
        form.branches = branches
        switch worktrees {
        case .success(let infos):
            form.diskWorktrees = infos
            form.loaded = true
            pruneAdoptPaths(state)
        case .failure(let error): form.error = error.description
        }
        form.loading = false
    }

    func adoptable(_ state: TabState) -> [WorktreeManager.Info] {
        guard case .newWorktree(let path, _, _) = state.route else { return [] }
        let taken = Set(router.stores().flatMap(\.workspaces).map { canonicalDiskPath($0.diskPath).path })
        return form(state).diskWorktrees.filter {
            let key = canonicalDiskPath($0.path).path
            return key != path && !taken.contains(key)
        }
    }
    func pruneAdoptPaths(_ state: TabState) {
        let form = form(state)
        let paths = form.worktree.adoptPaths.intersection(adoptable(state).map { canonicalDiskPath($0.path).path })
        if paths != form.worktree.adoptPaths { form.worktree.adoptPaths = paths }
    }
    func defaultWorktreePath(_ state: TabState) -> String {
        guard case .newWorktree(let path, _, _) = state.route else { return "" }
        let draft = form(state).worktree, root = URL(fileURLWithPath: path)
        let branch = draft.mode == .existing ? draft.existingBranch : draft.branch
        return root.deletingLastPathComponent().appendingPathComponent(
            WorktreeManager.defaultDirectoryName(sourceName: root.lastPathComponent, branch: branch)).path
    }

    func createWorktree(_ state: TabState) async {
        let form = form(state)
        guard !form.working, !form.completed, !state.isClosed,
              case .newWorktree(let repository, let sourceID, _) = state.route else { return }
        guard workspace(sourceID) != nil else { form.error = "The source workspace is no longer available."; return }
        var submittedDraft = state.draft
        let draft = form.worktree
        let template = AgentTemplate.visibleOrdered(model: .shared).first { $0.id == draft.templateID } ?? .terminal
        let root = URL(fileURLWithPath: repository)
        form.working = true; form.error = nil
        defer { form.working = false }
        let infos: [WorktreeManager.Info]
        if draft.mode == .adopt {
            // Re-read disk immediately before adoption; stale selected rows never create phantom workspaces.
            let listing = await Task.detached { WorktreeManager.list(repoPath: root) }.value
            guard state.draft == submittedDraft else { return }
            guard case .success(let current) = listing else { form.error = "Couldn't read the repository's worktrees."; return }
            form.diskWorktrees = current
            pruneAdoptPaths(state)
            submittedDraft = state.draft
            let selected = form.worktree.adoptPaths
            infos = adoptable(state).filter { selected.contains(canonicalDiskPath($0.path).path) }
            guard !infos.isEmpty, infos.count == selected.count,
                  infos.allSatisfy({ FileManager.default.fileExists(atPath: $0.path.path) }) else {
                form.error = "Select existing worktrees that aren't already open."; return
            }
        } else {
            let branch = (draft.mode == .existing ? draft.existingBranch : draft.branch).trimmingCharacters(in: .whitespacesAndNewlines)
            let pathText = draft.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = ((pathText.isEmpty ? defaultWorktreePath(state) : pathText) as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), InlineNameEdit.problem(expanded) == nil else {
                form.error = "Enter an absolute worktree path."; return
            }
            let path = URL(fileURLWithPath: expanded)
            let mode: WorktreeManager.BranchMode = draft.mode == .existing ? .existing(branch: branch)
                : .newBranch(name: branch, base: normalizedTitle(draft.startRef))
            let result = await addWorktree(root, path, mode)
            if case .failure(let error) = result { form.error = error.description; return }
            infos = [.init(path: path, branch: branch)]
        }
        // Look up the target again after the git operation and any tab transfer.
        guard let target = workspace(sourceID) else {
            form.completed = true
            form.error = "The source workspace closed. Worktrees remain at: " + infos.map { $0.path.path }.joined(separator: ", ")
            return
        }
        for info in infos {
            target.store.addWorkspace(workingDirectory: info.path, worktreeParent: target.workspace,
                worktreeBranch: info.branch, template: template)
        }
        router.revealWindow(target.store)
        finish(state, submittedDraft: submittedDraft)
    }

    func saveTag(_ state: TabState) {
        let form = form(state)
        guard case .workspaceDetails(let id) = state.route, let target = workspace(id) else {
            form.error = "The workspace is no longer available."; return
        }
        guard InlineNameEdit.problem(form.tag.name) == nil else { form.error = "Enter a single-line tag name."; return }
        let hex = form.tag.hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { form.error = "Enter a six-digit color, such as 69B0DB."; return }
        target.store.setTag(.edited(seededPreset: form.tag.seededPreset.flatMap(WorkspaceColorTag.init(rawValue:)),
            pickedHex: hex, name: form.tag.name), for: target.workspace)
        form.error = nil
        clearDraft(state)
    }

    func clearTag(_ state: TabState) {
        guard case .workspaceDetails(let id) = state.route, let target = workspace(id) else { return }
        target.store.setTag(nil, for: target.workspace)
        form(state).tag = WorkspaceTagDraft()
        form(state).error = nil
        clearDraft(state)
    }
    func clearDraft(_ state: TabState) {
        guard let location = owner(state) else { return }
        do {
            if let id = state.navigation.draftID { try location.store.drafts.discard(id) }
            state.draft = nil; state.navigation.draftID = nil; state.savedRevision = nil
            state.saveError = nil
            state.changed()
        } catch { state.saveError = error.localizedDescription }
    }
    private func finish(_ state: TabState, submittedDraft: TabDraft?) {
        // Equality includes the draft ID and revision; a late result cannot consume newer input.
        guard state.draft == submittedDraft else { return }
        form(state).completed = true
        clearDraft(state)
        guard state.saveError == nil, let location = owner(state) else {
            if case .newAgent = state.route { form(state).completed = false }
            return
        }
        if case .newAgent = state.route {
            location.store.closeCompletedAgentForm(location.session, in: location.workspace)
        } else { location.store.closeTab(location.session, in: location.workspace) }
    }
}
