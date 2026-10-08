import XCTest
@testable import AgentPadKit

@MainActor
final class LocalFormTabsTests: XCTestCase {
    private var directory: URL!
    private var stores: [WorkspaceStore] = []
    private var router: TabRouter!
    private var tabs: LocalFormTabs!
    private var sharedDrafts: DraftRepository!

    override func setUp() async throws {
        try await MainActor.run {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-forms-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            router = TabRouter()
            router.stores = { [weak self] in self?.stores ?? [] }
            tabs = LocalFormTabs(router: router)
            sharedDrafts = DraftRepository()
        }
    }
    override func tearDown() async throws {
        try await MainActor.run {
            stores.forEach { $0.terminate() }; stores = []
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func store(drafts: DraftRepository? = nil) -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), drafts: drafts ?? sharedDrafts,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil },
            peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store)
        store.active?.workingDirectory = directory
        return store
    }
    private func repo(_ name: String) throws -> URL {
        let root = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, ["init", "-b", "main"])
        try git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        return root
    }
    private func git(_ root: URL, _ args: [String]) throws {
        if case .failure(let error) = WorktreeManager.runGit(["-C", root.path] + args, timeout: 5) {
            throw NSError(domain: "git", code: Int(error.exitCode), userInfo: [NSLocalizedDescriptionKey: error.description])
        }
    }
    private func move(_ session: Session, to store: WorkspaceStore) throws {
        let workspace = try XCTUnwrap(store.active)
        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, in: workspace))
        XCTAssertTrue(router.owner(of: session.id)?.store === store)
    }

    func testSSHValidationPersistsExactInvalidInputAndReopensDraft() throws {
        let archive = directory.appendingPathComponent("drafts.json")
        let a = store(drafts: DraftRepository(fileURL: archive))
        a.setSidebarMode(.hidden)
        a.requestCreateSSHWorkspace(tabs: tabs)
        let session = try XCTUnwrap(a.active?.activeSession), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        XCTAssertEqual(a.sidebarMode, .hidden)
        XCTAssertTrue(tabs.newSSH(from: a) === session)
        for host in ["", "user@", "@host", "bad host", "-oProxyCommand=touch", "a\nb", "user@@host"] {
            form.host = host; tabs.createSSH(state)
            XCTAssertNotNil(form.error, host)
            XCTAssertEqual(form.host, host)
            XCTAssertEqual(a.workspaces.count, 1)
        }
        for host in ["build-server", "user@example.com", "me@192.0.2.1", "me@2001:db8::1"] {
            XCTAssertNil(LocalFormState.sshProblem(host), host)
        }
        form.host = "valid-alias"; form.name = "bad\nname"
        tabs.createSSH(state)
        XCTAssertNotNil(form.error)
        XCTAssertFalse(form.completed)
        a.flushPersistence()
        let saved = try XCTUnwrap(state.draft)
        XCTAssertEqual(DraftRepository(fileURL: archive).draft(saved.id), saved)
        let route = state.route
        XCTAssertTrue(a.tabCloseCoordinator.prepare([session]))
        a.closeTab(session, in: try XCTUnwrap(a.active))
        let reopened = try XCTUnwrap(tabs.newSSH(from: a)?.tabState)
        XCTAssertEqual(reopened.route, route)
        XCTAssertEqual(tabs.form(reopened).name, "bad\nname")
        XCTAssertEqual(tabs.form(reopened).host, "valid-alias")
    }

    func testSSHTransferCreatesAtCurrentOwnerWithPinnedHostAndDirectory() throws {
        let a = store(), b = store()
        let session = try XCTUnwrap(tabs.newSSH(from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.name = "Remote"; form.host = "alice@build"
        let pinned = form.directory
        try move(session, to: b)
        a.active?.workingDirectory = directory.appendingPathComponent("changed-a")
        b.active?.workingDirectory = directory.appendingPathComponent("changed-b")
        tabs.createSSH(state)
        let created = try XCTUnwrap(b.active)
        XCTAssertEqual(created.sshRemoteHost, "alice@build")
        XCTAssertEqual(created.workingDirectory.path, pinned)
        XCTAssertEqual(created.customTitle, "Remote")
        XCTAssertEqual(a.workspaces.count, 1)
        XCTAssertEqual(b.workspaces.count, 2)
        XCTAssertNil(router.owner(of: session.id))
        XCTAssertTrue(b.drafts.drafts.isEmpty)
        tabs.createSSH(state)
        XCTAssertEqual(b.workspaces.count, 2)
    }

    func testDiscardRestoresCachedLocalFormsAfterDraftSaveFailure() throws {
        var failing = false
        let drafts = DraftRepository(fileURL: directory.appendingPathComponent("drafts.json")) { data, url in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        }
        let a = store(drafts: drafts), workspace = try XCTUnwrap(a.active)
        let routes: [ToolRoute] = [.newSSH(draftID: UUID()),
            .newWorktree(repository: directory.path, sourceWorkspaceID: workspace.id, draftID: UUID()),
            .workspaceDetails(workspace.id)]
        for route in routes {
            failing = false
            let session = a.openToolTab(route), state = try XCTUnwrap(session.tabState)
            let form = tabs.form(state)
            switch route {
            case .newSSH: form.host = "host-a"
            case .newWorktree: form.worktree.branch = "saved-branch"
            default: form.tag.name = "Saved tag"
            }
            try a.tabCloseCoordinator.save(state)
            let saved = try XCTUnwrap(state.draft)
            failing = true
            switch route {
            case .newSSH: form.host = "host-b"
            case .newWorktree: form.worktree.branch = "discarded-branch"
            default: form.tag.name = "Discarded tag"
            }
            var discarded = false
            a.tabCloseCoordinator.request(session) { discarded = true }
            XCTAssertNotNil(state.saveError)
            a.tabCloseCoordinator.discard(session.id)
            XCTAssertTrue(discarded)
            XCTAssertEqual(state.draft, saved)

            let restored = tabs.form(state)
            switch route {
            case .newSSH:
                XCTAssertEqual(restored.host, "host-a")
                restored.name = "New name"
                XCTAssertEqual(state.draft?.payload, .ssh(name: "New name", host: "host-a", directory: ""))
                failing = false
                tabs.createSSH(state)
                XCTAssertEqual(a.active?.sshRemoteHost, "host-a")
            case .newWorktree:
                XCTAssertEqual(restored.worktree.branch, "saved-branch")
                restored.worktree.startRef = "main"
                if case .worktreeForm(let draft) = state.draft?.payload { XCTAssertEqual(draft.branch, "saved-branch") }
                else { XCTFail("missing worktree draft") }
            default:
                XCTAssertEqual(restored.tag.name, "Saved tag")
                restored.tag.hex = "123ABC"
                if case .workspaceTag(let draft) = state.draft?.payload { XCTAssertEqual(draft.name, "Saved tag") }
                else { XCTFail("missing tag draft") }
            }
        }
    }

    func testDiscardKeepsLoadedWorktreeInventoryAfterSaveFailure() async throws {
        let root = try repo("repo"), adoptPath = directory.appendingPathComponent("adopt")
        try git(root, ["branch", "available"])
        try git(root, ["worktree", "add", "-b", "adopt", adoptPath.path])
        var failing = false
        let drafts = DraftRepository(fileURL: directory.appendingPathComponent("drafts.json")) { data, url in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        }
        let a = store(drafts: drafts), source = try XCTUnwrap(a.active)
        source.workingDirectory = root
        let session = try XCTUnwrap(tabs.newWorktree(source: source, from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        await tabs.loadWorktree(state)
        let branches = form.branches, worktrees = form.diskWorktrees, adoptable = tabs.adoptable(state)
        XCTAssertTrue(form.loaded)
        XCTAssertTrue(branches.contains("available"))
        XCTAssertEqual(adoptable.map { canonicalDiskPath($0.path) }, [canonicalDiskPath(adoptPath)])
        form.worktree = WorktreeFormDraft(mode: .existing, branch: "saved", existingBranch: "available",
            startRef: "main", directory: directory.appendingPathComponent("saved").path,
            templateID: AgentTemplate.terminal.id, adoptPaths: [canonicalDiskPath(adoptPath).path])
        let savedInput = form.worktree
        XCTAssertTrue(a.flushPersistence())
        let saved = try XCTUnwrap(state.draft)
        failing = true
        form.worktree = WorktreeFormDraft(branch: "discarded")
        XCTAssertFalse(a.flushPersistence())
        XCTAssertNotNil(state.saveError)

        // The save-error banner discards without closing or remounting the view.
        a.tabCloseCoordinator.discardEdits(state)
        let restored = tabs.form(state)
        XCTAssertTrue(restored === form)
        XCTAssertEqual(state.draft, saved)
        XCTAssertEqual(state.savedRevision, saved.revision)
        XCTAssertEqual(restored.worktree, savedInput)
        XCTAssertEqual(restored.branches, branches)
        XCTAssertEqual(restored.diskWorktrees, worktrees)
        XCTAssertTrue(restored.loaded)
        XCTAssertFalse(restored.loading)
        XCTAssertEqual(tabs.adoptable(state), adoptable)
        XCTAssertNil(state.saveError)
        XCTAssertNotNil(router.owner(of: session.id))
    }

    func testDiscardCannotUnlockWorktreeFormDuringCheckout() async throws {
        let root = try repo("repo")
        var failing = false
        let drafts = DraftRepository(fileURL: directory.appendingPathComponent("drafts.json")) { data, url in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        }
        let a = store(drafts: drafts), source = try XCTUnwrap(a.active)
        source.workingDirectory = root
        let session = try XCTUnwrap(tabs.newWorktree(source: source, from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.worktree.branch = "saved"
        XCTAssertTrue(a.flushPersistence())
        failing = true
        form.worktree.branch = "operation-a"
        XCTAssertFalse(a.flushPersistence())
        let submitted = try XCTUnwrap(state.draft), saveError = try XCTUnwrap(state.saveError)
        failing = false
        let started = expectation(description: "checkout started")
        var release: CheckedContinuation<Void, Never>?
        tabs.addWorktree = { repository, path, mode in
            await withCheckedContinuation { release = $0; started.fulfill() }
            return WorktreeManager.add(repoPath: repository, path: path, mode: mode)
        }
        let operation = Task { await tabs.createWorktree(state) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(form.working)
        a.tabCloseCoordinator.discardEdits(state)
        XCTAssertTrue(tabs.form(state) === form)
        XCTAssertTrue(tabs.form(state).working)
        XCTAssertEqual(tabs.form(state).worktree.branch, "operation-a")
        XCTAssertEqual(state.draft, submitted)
        XCTAssertEqual(state.saveError, saveError)

        // The pending-close version of the banner must honor the same working guard.
        failing = true
        var closed = false
        a.tabCloseCoordinator.request(session) { closed = true }
        XCTAssertTrue(a.tabCloseCoordinator.hasPending(session.id))
        a.tabCloseCoordinator.discard(session.id)
        XCTAssertFalse(closed)
        XCTAssertTrue(a.tabCloseCoordinator.hasPending(session.id))
        XCTAssertTrue(tabs.form(state) === form)
        XCTAssertTrue(form.working)
        XCTAssertEqual(state.draft, submitted)
        failing = false
        release?.resume()
        await operation.value
        XCTAssertFalse(form.working)
        XCTAssertTrue(form.completed)
        XCTAssertNil(form.error)
        XCTAssertNil(state.draft)
        XCTAssertNil(drafts.draft(submitted.id))
        XCTAssertNil(router.owner(of: session.id))
        XCTAssertEqual(a.workspaces.filter { $0.worktreeParentId == source.id }.map(\.worktreeBranch), ["operation-a"])
    }

    func testWorktreeCompletionPreservesNewerDraftAndKeepsTabOpen() async throws {
        for replaceID in [false, true] {
            let root = try repo("repo-\(replaceID)"), archive = directory.appendingPathComponent("drafts-\(replaceID).json")
            let a = store(drafts: DraftRepository(fileURL: archive)), source = try XCTUnwrap(a.active)
            source.workingDirectory = root
            let session = try XCTUnwrap(tabs.newWorktree(source: source, from: a)), state = try XCTUnwrap(session.tabState)
            let form = tabs.form(state)
            form.worktree.branch = "operation-a"
            let submitted = try XCTUnwrap(state.draft)
            let started = expectation(description: "checkout started")
            var release: CheckedContinuation<Void, Never>?
            tabs.addWorktree = { repository, path, mode in
                await withCheckedContinuation { release = $0; started.fulfill() }
                return WorktreeManager.add(repoPath: repository, path: path, mode: mode)
            }
            let operation = Task { await tabs.createWorktree(state) }
            await fulfillment(of: [started], timeout: 2)
            // Exercise the completion guard even if newer input arrives outside the disabled UI.
            if replaceID { state.draft = nil; state.navigation.draftID = nil }
            form.worktree.branch = "draft-b"
            try a.tabCloseCoordinator.save(state)
            let newer = try XCTUnwrap(state.draft)
            if replaceID {
                XCTAssertNotEqual(newer.id, submitted.id)
                XCTAssertEqual(newer.revision, submitted.revision)
            } else {
                XCTAssertEqual(newer.id, submitted.id)
                XCTAssertGreaterThan(newer.revision, submitted.revision)
            }
            release?.resume()
            await operation.value
            XCTAssertEqual(state.draft, newer)
            XCTAssertEqual(state.navigation.draftID, newer.id)
            XCTAssertEqual(a.drafts.draft(newer.id), newer)
            XCTAssertEqual(DraftRepository(fileURL: archive).draft(newer.id), newer)
            XCTAssertNotNil(router.owner(of: session.id))
            XCTAssertFalse(state.isClosed)
            XCTAssertFalse(form.completed)
            XCTAssertFalse(form.working)
            XCTAssertEqual(form.worktree.branch, "draft-b")
            XCTAssertEqual(a.workspaces.filter { $0.worktreeParentId == source.id }.map(\.worktreeBranch), ["operation-a"])
        }
    }

    func testWorktreeUsesPinnedRepositoryAndSourceAfterTransferAndCwdChange() async throws {
        let root = try repo("source"), unrelated = try repo("unrelated")
        let a = store(), b = store(), source = try XCTUnwrap(a.active)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        source.workingDirectory = nested
        let session = try XCTUnwrap(tabs.newWorktree(source: source, from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.worktree.branch = "feature/pinned"
        let expectedPath = tabs.defaultWorktreePath(state)
        let started = expectation(description: "git operation started")
        var release: CheckedContinuation<Void, Never>?
        tabs.addWorktree = { repository, path, mode in
            await withCheckedContinuation { release = $0; started.fulfill() }
            return WorktreeManager.add(repoPath: repository, path: path, mode: mode)
        }
        let operation = Task { await tabs.createWorktree(state) }
        await fulfillment(of: [started], timeout: 2)
        try move(session, to: b)
        source.workingDirectory = unrelated
        b.active?.workingDirectory = unrelated
        XCTAssertTrue(tabs.newWorktree(source: source, from: a) === session)
        XCTAssertEqual(tabs.defaultWorktreePath(state), expectedPath)
        // A second click during the operation cannot enqueue a duplicate.
        await tabs.createWorktree(state)
        release?.resume()
        await operation.value
        XCTAssertNil(form.error)
        let created = try XCTUnwrap(a.workspaces.first { $0.worktreeParentId == source.id })
        XCTAssertEqual(created.diskPath.path, URL(fileURLWithPath: expectedPath).standardizedFileURL.path)
        XCTAssertEqual(created.worktreeBranch, "feature/pinned")
        guard case .success(let infos) = WorktreeManager.list(repoPath: root) else { return XCTFail("source repository missing") }
        XCTAssertTrue(infos.contains { $0.branch == "feature/pinned" })
        guard case .success(let other) = WorktreeManager.list(repoPath: unrelated) else { return XCTFail("other repository missing") }
        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(b.workspaces.count, 1)
        XCTAssertNil(router.owner(of: session.id))
    }

    func testWorktreeBranchPathAndRefErrorsKeepEveryFieldAcrossPersistence() async throws {
        let root = try repo("repo"), archive = directory.appendingPathComponent("drafts.json")
        let a = store(drafts: DraftRepository(fileURL: archive)), source = try XCTUnwrap(a.active)
        source.workingDirectory = root
        let session = try XCTUnwrap(tabs.newWorktree(source: source, from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        for branch in ["", "bad branch", "a..b", "-option", "@{-1}", "main"] {
            form.worktree.branch = branch
            await tabs.createWorktree(state)
            XCTAssertNotNil(form.error, branch)
            XCTAssertEqual(form.worktree.branch, branch)
            XCTAssertEqual(a.workspaces.count, 1)
        }
        form.worktree.branch = "good"
        form.worktree.directory = "relative path"
        await tabs.createWorktree(state)
        XCTAssertNotNil(form.error)
        form.worktree.directory = directory.appendingPathComponent("worktree").path
        form.worktree.startRef = "missing-ref"
        await tabs.createWorktree(state)
        XCTAssertNotNil(form.error)
        let expected = form.worktree
        a.flushPersistence()
        let draft = try XCTUnwrap(state.draft)
        let restored = TabState(route: state.route)
        restored.draft = DraftRepository(fileURL: archive).draft(draft.id)
        XCTAssertEqual(tabs.form(restored).worktree, expected)
        await tabs.loadWorktree(restored)
        XCTAssertEqual(tabs.form(restored).worktree, expected, "loading cannot replace invalid input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.directory))
    }

    func testAdoptCreatesEachSelectedWorkspaceOnceAndRejectsStaleSelection() async throws {
        let root = try repo("repo"), a = store(), source = try XCTUnwrap(a.active)
        source.workingDirectory = root
        let paths = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        for (index, path) in paths.enumerated() {
            try git(root, ["worktree", "add", "-b", "branch-\(index)", path.path])
        }
        let state = try XCTUnwrap(tabs.newWorktree(source: source, from: a)?.tabState), form = tabs.form(state)
        form.worktree.mode = .adopt
        form.worktree.adoptPaths = Set(paths.map { canonicalDiskPath($0).path })
        await tabs.createWorktree(state)
        XCTAssertNil(form.error)
        XCTAssertEqual(a.workspaces.filter { $0.worktreeParentId == source.id }.count, 2)
        await tabs.createWorktree(state)
        XCTAssertEqual(a.workspaces.count, 3)
        let next = try XCTUnwrap(tabs.newWorktree(source: source, from: a, newDraft: true)?.tabState)
        tabs.form(next).worktree.mode = .adopt
        tabs.form(next).worktree.adoptPaths = [canonicalDiskPath(paths[0]).path]
        await tabs.createWorktree(next)
        XCTAssertNotNil(tabs.form(next).error)
        XCTAssertEqual(a.workspaces.count, 3)
    }

    func testAdoptDropsStalePathsAfterRestoreAndBeforeCreatingWorkspaces() async throws {
        let root = try repo("repo"), a = store(), b = store(), source = try XCTUnwrap(a.active)
        source.workingDirectory = root
        let paths = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        for (index, path) in paths.enumerated() {
            try git(root, ["worktree", "add", "-b", "branch-\(index)", path.path])
        }
        let state = try XCTUnwrap(tabs.newWorktree(source: source, from: a)?.tabState), form = tabs.form(state)
        await tabs.loadWorktree(state)
        form.worktree.mode = .adopt
        form.worktree.adoptPaths = Set(paths.map { canonicalDiskPath($0).path })
        try a.tabCloseCoordinator.save(state)
        let saved = try XCTUnwrap(state.draft)
        let refreshed = TabState(route: state.route)
        refreshed.draft = a.drafts.draft(saved.id)
        await tabs.loadWorktree(refreshed)
        XCTAssertEqual(tabs.form(refreshed).worktree.adoptPaths, form.worktree.adoptPaths)
        b.addWorkspace(workingDirectory: paths[0])
        XCTAssertEqual(tabs.adoptable(state).map { canonicalDiskPath($0.path).path }, [canonicalDiskPath(paths[1]).path])
        tabs.pruneAdoptPaths(refreshed)
        XCTAssertEqual(tabs.form(refreshed).worktree.adoptPaths, [canonicalDiskPath(paths[1]).path])
        XCTAssertEqual(refreshed.draft?.payload, .worktreeForm(tabs.form(refreshed).worktree))

        let restored = TabState(route: state.route)
        restored.draft = a.drafts.draft(saved.id)
        await tabs.loadWorktree(restored)
        XCTAssertEqual(tabs.form(restored).worktree.adoptPaths, [canonicalDiskPath(paths[1]).path])

        // No view refresh is needed for submitting a selection that became stale.
        await tabs.createWorktree(state)
        XCTAssertNil(form.error)
        XCTAssertEqual(a.workspaces.filter { $0.worktreeParentId == source.id }.map { canonicalDiskPath($0.diskPath).path },
            [canonicalDiskPath(paths[1]).path])
        XCTAssertEqual(b.workspaces.filter { canonicalDiskPath($0.diskPath) == canonicalDiskPath(paths[0]) }.count, 1)
    }

    func testWorkspaceDetailsEditsOriginalTargetAfterTransferAndPersistsTagInput() throws {
        let a = store(), b = store(), target = try XCTUnwrap(a.active), unrelated = try XCTUnwrap(b.active)
        let session = try XCTUnwrap(tabs.details(target, from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.tag.name = "Release"; form.tag.hex = "not a color"
        try move(session, to: b)
        target.workingDirectory = directory.appendingPathComponent("changed")
        tabs.saveTag(state)
        XCTAssertNotNil(form.error)
        XCTAssertEqual(form.tag.hex, "not a color")
        XCTAssertNil(target.tag)
        b.flushPersistence()
        XCTAssertEqual(b.drafts.draft(try XCTUnwrap(state.navigation.draftID))?.payload, .workspaceTag(form.tag))
        form.tag.hex = "123ABC"
        tabs.saveTag(state)
        XCTAssertEqual(target.tag?.name, "Release")
        XCTAssertEqual(target.tag?.colorHex, "123ABC")
        XCTAssertNil(unrelated.tag)
        XCTAssertTrue(tabs.details(target, from: b) === session)
        tabs.clearTag(state)
        XCTAssertNil(target.tag)
    }

    func testRenameEnterEscapeValidationAndHiddenSidebar() throws {
        let a = store(), workspace = try XCTUnwrap(a.active)
        let terminal = a.addTab(in: workspace)
        a.setSidebarMode(.hidden)
        a.requestRenameActiveWorkspace()
        XCTAssertTrue(a.workspaceRenameInHeader)
        XCTAssertEqual(a.sidebarMode, .hidden)
        workspace.nameEdit.text = "cancelled"
        workspace.nameEdit.handle(.escape) { a.renameWorkspace(workspace, to: $0); return nil }
        XCTAssertNil(workspace.customTitle)
        a.requestRenameActiveWorkspace()
        workspace.nameEdit.text = "bad\nname"
        workspace.nameEdit.handle(.enter) { a.renameWorkspace(workspace, to: $0); return nil }
        XCTAssertTrue(workspace.nameEdit.isEditing)
        XCTAssertNotNil(workspace.nameEdit.error)
        workspace.nameEdit.text = "  Project  "
        workspace.nameEdit.handle(.enter) { a.renameWorkspace(workspace, to: $0); return nil }
        XCTAssertEqual(workspace.customTitle, "Project")
        a.requestRenameActiveTab()
        terminal.nameEdit.text = "Build"
        terminal.nameEdit.handle(.enter) { a.renameTab(terminal, to: $0); return nil }
        XCTAssertEqual(terminal.customTitle, "Build")
        a.requestRenameActiveTab()
        terminal.nameEdit.text = "Don't save"
        terminal.nameEdit.handle(.escape) { a.renameTab(terminal, to: $0); return nil }
        XCTAssertEqual(terminal.customTitle, "Build")
    }

    func testFilesPinnedAfterTransferAndCwdChangeAndInvalidNameRestores() throws {
        let a = store(), b = store()
        a.setSidebarMode(.hidden)
        router.ensureHost = { a }
        FileOperations.newFile(in: directory, tabs: tabs)
        let session = try XCTUnwrap(a.active?.activeSession), state = try XCTUnwrap(session.tabState)
        let editor = tabs.filesModel(state).nameEdit
        tabs.filesModel(state).searchQuery = "notes"
        editor.draft?.name = "invalid/name"
        editor.commit()
        XCTAssertNotNil(editor.error(for: directory))
        XCTAssertEqual(editor.draft?.name, "invalid/name")
        try move(session, to: b)
        XCTAssertEqual(tabs.filesModel(state).searchQuery, "notes")
        b.active?.workingDirectory = directory.appendingPathComponent("other")
        let restored = TabState(route: state.route)
        restored.draft = state.draft
        XCTAssertEqual(tabs.filesModel(restored).nameEdit.draft?.name, "invalid/name")
        editor.draft?.name = "pinned.txt"
        editor.commit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pinned.txt").path))
        XCTAssertNil(editor.draft)
        XCTAssertEqual(a.sidebarMode, .hidden)
        XCTAssertEqual(state.route, .files(canonicalPath: canonicalDiskPath(directory).path))
    }
}
