import XCTest
@testable import AgentPadKit

/// Pure listing / flatten / icon logic — nonisolated, no store or MainActor.
final class FileTreeListerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpad-filetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func touch(_ relative: String) {
        FileManager.default.createFile(
            atPath: tempRoot.appendingPathComponent(relative).path,
            contents: Data()
        )
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Fixture node for the pure flatten/symbol tests — no filesystem behind it.
    private func node(_ path: String, isDirectory: Bool = false) -> FileNode {
        FileNode(
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: false
        )
    }

    // MARK: children(of:)

    func testChildrenSortsDirectoriesFirstThenNaturally() throws {
        touch("file10.txt")
        touch("file2.txt")
        touch("alpha")
        try mkdir("zebra-dir")
        try mkdir("beta-dir")
        let names = try FileTreeLister.children(of: tempRoot).map(\.name)
        // Directories lead; `file2` before `file10` is the natural-sort
        // (localizedStandardCompare) guarantee.
        XCTAssertEqual(names, ["beta-dir", "zebra-dir", "alpha", "file2.txt", "file10.txt"])
    }

    func testChildrenShowsDotfilesButHidesGitAndDSStore() throws {
        touch(".env")
        touch(".DS_Store")
        touch("readme.md")
        try mkdir(".git")
        let names = try FileTreeLister.children(of: tempRoot).map(\.name)
        XCTAssertEqual(Set(names), [".env", "readme.md"])
    }

    func testChildrenThrowsOnMissingDirectory() {
        let missing = tempRoot.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try FileTreeLister.children(of: missing))
    }

    func testSymlinkToDirectoryIsNotExpandable() throws {
        // Expanding through links is what would make cycles representable —
        // a symlink must come back as a non-directory leaf.
        try mkdir("real")
        let link = tempRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: tempRoot.appendingPathComponent("real", isDirectory: true)
        )
        let nodes = try FileTreeLister.children(of: tempRoot)
        let linkNode = try XCTUnwrap(nodes.first { $0.name == "link" })
        XCTAssertTrue(linkNode.isSymlink)
        XCTAssertFalse(linkNode.isDirectory)
    }

    // MARK: flatten

    func testFlattenWalksExpandedDirsDepthFirst() {
        let rows = FileTreeLister.flatten(
            root: URL(fileURLWithPath: "/root"),
            childrenByDir: [
                "/root": [node("/root/src", isDirectory: true), node("/root/a.txt")],
                "/root/src": [node("/root/src/main.swift")],
            ],
            expandedDirs: ["/root/src"],
            failedDirs: []
        )
        XCTAssertEqual(rows.map(\.id), ["/root/src", "/root/src/main.swift", "/root/a.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
        XCTAssertEqual(rows.map(\.isExpanded), [true, false, false])
    }

    func testFlattenSkipsCollapsedSubtrees() {
        let rows = FileTreeLister.flatten(
            root: URL(fileURLWithPath: "/root"),
            childrenByDir: [
                "/root": [node("/root/src", isDirectory: true), node("/root/a.txt")],
                "/root/src": [node("/root/src/main.swift")],
            ],
            expandedDirs: [],
            failedDirs: []
        )
        XCTAssertEqual(rows.map(\.id), ["/root/src", "/root/a.txt"])
        XCTAssertEqual(rows.map(\.isExpanded), [false, false])
    }

    func testFlattenEmitsPlaceholderForFailedDir() {
        let rows = FileTreeLister.flatten(
            root: URL(fileURLWithPath: "/root"),
            childrenByDir: ["/root": [node("/root/locked", isDirectory: true)]],
            expandedDirs: ["/root/locked"],
            failedDirs: ["/root/locked"]
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].depth, 1)
        guard case .placeholder = rows[1].kind else {
            return XCTFail("expected a placeholder row under the failed dir")
        }
    }

    // MARK: symbolName

    func testSymbolNames() {
        XCTAssertEqual(FileTreeLister.symbolName(for: node("/d", isDirectory: true)), "folder.fill")
        XCTAssertEqual(FileTreeLister.symbolName(for: node("/x/shot.PNG")), "photo")
        XCTAssertEqual(FileTreeLister.symbolName(for: node("/x/main.swift")), "doc.text")
    }
}

/// Model behaviour against a real temp directory tree. Fixtures are built
/// per-test (not in `setUp`) — the nonisolated setUp/tearDown overrides
/// can't touch this @MainActor class's state or call `FileTreeModel()`,
/// same reason `WorkspaceStoreTests` builds stores inside test methods.
@MainActor
final class FileTreeModelTests: XCTestCase {
    /// Fresh on-disk tree (`root/src/main.swift`, `root/readme.md`) + model.
    /// Teardown cancels the model's watchers and removes the tree.
    private func makeFixture() throws -> (root: URL, src: URL, model: FileTreeModel) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpad-filetreemodel-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: src.appendingPathComponent("main.swift").path, contents: Data())
        FileManager.default.createFile(atPath: root.appendingPathComponent("readme.md").path, contents: Data())
        let model = FileTreeModel()
        // Production hops every listing off-main; model tests inject a
        // synchronous runner so row assertions stay deterministic.
        model.listingRunner = { work, apply in apply(work()) }
        addTeardownBlock {
            await model.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        return (root, src, model)
    }

    private func entryNode(id: String, in model: FileTreeModel) throws -> FileNode {
        let row = try XCTUnwrap(model.rows.first { $0.id == id })
        guard case .entry(let node) = row.kind else {
            struct NotAnEntry: Error {}
            XCTFail("row \(id) is not an entry")
            throw NotAnEntry()
        }
        return node
    }

    func testActivateListsOnlyTopLevel() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        // Lazy: `src`'s contents stay unlisted until it's expanded.
        XCTAssertEqual(model.rows.map(\.id), [src.path, root.appendingPathComponent("readme.md").path])
        XCTAssertEqual(model.rows.map(\.depth), [0, 0])
    }

    func testRenameDraftRemainsInHeaderWhenItsDirectoryBecomesRoot() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        model.nameEdit.beginRename(src)
        model.nameEdit.draft?.name = "renamed"
        XCTAssertNil(model.headerDraft, "the directory row contains the editor")

        model.setRoot(src)
        XCTAssertFalse(model.rows.contains { $0.id == FileNameEdit.key(src) })
        XCTAssertEqual(model.headerDraft?.name, "renamed", "the header must expose the editor for Enter/Esc")
        model.nameEdit.cancel()
        XCTAssertNil(model.headerDraft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))

        model.setRoot(root)
        model.nameEdit.beginRename(src)
        model.nameEdit.draft?.name = "renamed"
        model.setRoot(src)
        XCTAssertEqual(model.headerDraft, model.nameEdit.draft)
        model.nameEdit.commit()
        XCTAssertNil(model.nameEdit.draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))

        model.nameEdit.beginNew(in: root)
        model.setRoot(root)
        XCTAssertEqual(model.nameEdit.draft?.path, FileNameEdit.key(root))
        XCTAssertNil(model.headerDraft, "root new-file edits already appear in FileRowFeedback")
        model.nameEdit.draft?.name = "created.txt"
        model.nameEdit.commit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("created.txt").path))
    }

    func testRenameCollisionAppearsInHeaderDuringSearchEvenForLoadedRow() throws {
        let (root, _, model) = try makeFixture()
        let source = root.appendingPathComponent("a.txt"), taken = root.appendingPathComponent("b.txt")
        try Data("source".utf8).write(to: source)
        try Data("keep".utf8).write(to: taken)
        model.activate(root: root)
        XCTAssertTrue(model.rows.contains { $0.id == FileNameEdit.key(source) })
        model.searchQuery = "a"
        model.nameEdit.beginRename(source)
        model.nameEdit.draft?.name = "b.txt"
        model.nameEdit.commit()

        XCTAssertNotNil(model.nameEdit.error(for: source))
        XCTAssertEqual(model.headerErrorPaths, [FileNameEdit.key(source)])
        XCTAssertEqual(model.headerDraft?.name, "b.txt")
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "keep")
        model.searchQuery = ""
        XCTAssertTrue(model.headerErrorPaths.isEmpty, "normal tree rows display their own errors")
        model.searchQuery = "a"
        model.nameEdit.cancel()
        XCTAssertTrue(model.headerErrorPaths.isEmpty)
    }

    func testActivateSchedulesRootListingThroughRunner() throws {
        let (root, src, model) = try makeFixture()
        var pending: (() -> Void)?
        model.listingRunner = { work, apply in
            pending = { apply(work()) }
        }

        model.activate(root: root)

        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(pending)

        pending?()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.rows.map(\.id), [src.path, root.appendingPathComponent("readme.md").path])
    }

    func testNewerRootRefreshSkipsQueuedOlderListing() throws {
        let (root, src, model) = try makeFixture()
        var pending: [() -> Void] = []
        var listedCounts: [Int] = []
        model.listingRunner = { work, apply in
            pending.append {
                let result = work()
                listedCounts.append(result.listed.count)
                apply(result)
            }
        }

        model.activate(root: root)
        model.refresh(dirPath: root.path)
        XCTAssertEqual(pending.count, 2)

        pending[0]()
        XCTAssertEqual(listedCounts, [0], "the superseded queued walk must bail before touching disk")
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.rows.isEmpty)

        pending[1]()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.rows.map(\.id), [src.path, root.appendingPathComponent("readme.md").path])
    }

    func testDeactivateSkipsQueuedListingBeforeDiskWalk() throws {
        let (root, _, model) = try makeFixture()
        var pending: (() -> FileTreeLister.SubtreeListing)?
        model.listingRunner = { work, _ in pending = work }

        let token = model.activate(root: root)
        model.deactivate(token: token)

        let listing = try XCTUnwrap(pending)()
        XCTAssertTrue(listing.listed.isEmpty)
        XCTAssertTrue(listing.failed.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testSymlinkedRootListsThroughTheLink() throws {
        // Shells report the *logical* cwd, so a symlinked project dir
        // (~/proj → ~/dev/proj) arrives as the link path. The URL-based
        // lister refuses to traverse a symlink final component (ENOTDIR),
        // so the root must be canonicalized or the tree strands on
        // "Folder unavailable". The temp-dir fixtures never cover this —
        // /var and /tmp are Foundation-special-cased — hence a real link.
        let (root, _, model) = try makeFixture()
        let target = root.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: target.appendingPathComponent("inside.txt").path,
            contents: Data()
        )
        let link = root.appendingPathComponent("link-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        model.activate(root: link)
        XCTAssertFalse(model.rootError, "a symlinked root must list through the link")
        XCTAssertEqual(
            model.rows.map { ($0.id as NSString).lastPathComponent },
            ["inside.txt"]
        )
        // Root and child keys must share one canonical prefix, or expansion
        // and watcher bookkeeping silently key-miss.
        let rootPath = try XCTUnwrap(model.rootURL?.path)
        XCTAssertTrue(model.rows.allSatisfy { $0.id.hasPrefix(rootPath + "/") })
    }

    func testExpandAndCollapse() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        let srcNode = try entryNode(id: src.path, in: model)

        model.toggleExpanded(srcNode)
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 0])
        XCTAssertEqual(model.rows[1].id, src.appendingPathComponent("main.swift").path)
        XCTAssertTrue(model.rows[0].isExpanded)

        model.toggleExpanded(srcNode)
        XCTAssertEqual(model.rows.map(\.depth), [0, 0])
        XCTAssertFalse(model.rows[0].isExpanded)
    }

    /// The expand cascade runs off-main in production; a listing that lands
    /// AFTER a superseding mutation must be dropped, not merged — else a
    /// slow first expansion overwrites whatever a fresher refresh saw.
    func testStaleExpandListingCannotOverwriteAFresherRefresh() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        // Capture the cascade instead of applying inline: `work()` runs NOW
        // (listing src before the extra file exists), the apply is parked.
        var pendingApply: (() -> Void)?
        var listingCount = 0
        model.listingRunner = { work, apply in
            let result = work()
            listingCount += 1
            if listingCount == 1 {
                pendingApply = { apply(result) }
            } else {
                apply(result)
            }
        }
        let srcNode = try entryNode(id: src.path, in: model)
        model.toggleExpanded(srcNode)

        let extraId = src.appendingPathComponent("extra.swift").path
        FileManager.default.createFile(atPath: extraId, contents: Data())
        model.refresh(dirPath: src.path)
        XCTAssertTrue(model.rows.contains { $0.id == extraId })

        pendingApply?()   // the pre-refresh listing lands late
        XCTAssertTrue(model.rows.contains { $0.id == extraId },
                      "a superseded cascade must not overwrite the fresher refresh")
    }

    /// Cancellation is PER-DIRECTORY: expanding B while A's listing is
    /// still in flight must not drop A's result — a global token left A
    /// stuck "expanded but empty" until an unrelated event relisted it.
    func testConcurrentExpandsBothLand() throws {
        let (root, src, model) = try makeFixture()
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: docs.appendingPathComponent("guide.md").path, contents: Data())
        model.activate(root: root)

        var pending: [() -> Void] = []
        model.listingRunner = { work, apply in
            let result = work()
            pending.append { apply(result) }
        }
        let srcNode = try entryNode(id: src.path, in: model)
        let docsNode = try entryNode(id: docs.path, in: model)
        model.toggleExpanded(srcNode)
        model.toggleExpanded(docsNode)   // second expand while the first is in flight
        pending.forEach { $0() }

        XCTAssertTrue(model.rows.contains { $0.id == src.appendingPathComponent("main.swift").path },
                      "expanding docs must not drop src's in-flight listing")
        XCTAssertTrue(model.rows.contains { $0.id == docs.appendingPathComponent("guide.md").path })
    }

    func testRefreshPicksUpExternalCreateAndDelete() throws {
        let (root, _, model) = try makeFixture()
        model.activate(root: root)

        FileManager.default.createFile(atPath: root.appendingPathComponent("new.txt").path, contents: Data())
        model.refresh(dirPath: root.path)
        XCTAssertTrue(model.rows.contains { $0.id == root.appendingPathComponent("new.txt").path })

        try FileManager.default.removeItem(at: root.appendingPathComponent("readme.md"))
        model.refresh(dirPath: root.path)
        XCTAssertFalse(model.rows.contains { $0.id == root.appendingPathComponent("readme.md").path })
    }

    func testDeletedExpandedSubtreeIsPrunedAndSelectionCleared() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        let srcNode = try entryNode(id: src.path, in: model)
        model.toggleExpanded(srcNode)
        model.selectedId = src.appendingPathComponent("main.swift").path

        try FileManager.default.removeItem(at: src)
        model.refresh(dirPath: root.path)

        XCTAssertEqual(model.rows.map(\.id), [root.appendingPathComponent("readme.md").path])
        XCTAssertNil(model.selectedId, "selection pointing into the deleted subtree must clear")
        XCTAssertEqual(model.watchedDirectoryCount, 1, "the deleted dir's watcher must drop; only the root remains")
    }

    func testSetRootResetsExpansionAndSelection() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        let srcNode = try entryNode(id: src.path, in: model)
        model.toggleExpanded(srcNode)
        model.selectedId = src.path

        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: otherRoot.appendingPathComponent("only.txt").path, contents: Data())

        model.setRoot(otherRoot)
        XCTAssertEqual(model.rows.map(\.id), [otherRoot.appendingPathComponent("only.txt").path])
        XCTAssertNil(model.selectedId)

        // Same-path setRoot is a no-op.
        model.setRoot(otherRoot)
        XCTAssertEqual(model.rows.map(\.id), [otherRoot.appendingPathComponent("only.txt").path])
    }

    func testRootDeletionSetsRootErrorAndRecoversOnActivate() throws {
        let (root, _, model) = try makeFixture()
        model.activate(root: root)
        XCTAssertFalse(model.rootError)

        try FileManager.default.removeItem(at: root)
        model.refresh(dirPath: root.path)
        XCTAssertTrue(model.rootError)
        XCTAssertTrue(model.rows.isEmpty)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("back.txt").path, contents: Data())
        model.activate(root: root)
        XCTAssertFalse(model.rootError)
        XCTAssertEqual(model.rows.map(\.id), [root.appendingPathComponent("back.txt").path])
    }

    func testDeactivateDropsWatchersButKeepsExpansion() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        let srcNode = try entryNode(id: src.path, in: model)
        model.toggleExpanded(srcNode)
        XCTAssertEqual(model.watchedDirectoryCount, 2, "root + expanded src")

        model.deactivate()
        XCTAssertEqual(model.watchedDirectoryCount, 0)

        // Re-entry restores the same expanded view and re-arms watchers.
        model.activate(root: root)
        XCTAssertTrue(model.rows.contains { $0.id == src.appendingPathComponent("main.swift").path })
        XCTAssertEqual(model.watchedDirectoryCount, 2)
    }

    func testApplyGitDiffFiltersToRootAndAggregatesAncestors() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)

        let mainSwift = src.appendingPathComponent("main.swift").path
        model.applyGitDiff([
            mainSwift: GitFileDiff(insertions: 10, deletions: 2),
            root.appendingPathComponent("readme.md").path: GitFileDiff(insertions: 1, deletions: 0),
            "/somewhere/else/outside.txt": GitFileDiff(insertions: 99, deletions: 99),
        ])

        // Files keep exact counts; outside-root paths are dropped.
        XCTAssertEqual(model.gitDiff[mainSwift], GitFileDiff(insertions: 10, deletions: 2))
        XCTAssertNil(model.gitDiff["/somewhere/else/outside.txt"])
        // `src` (ancestor dir of main.swift) carries the subtree total for
        // its collapsed-row badge; the root itself is not a row → no entry.
        XCTAssertEqual(model.gitDiffDirTotals[src.path], GitFileDiff(insertions: 10, deletions: 2))
        XCTAssertNil(model.gitDiffDirTotals[root.path])
    }

    func testSetRootClearsGitDiff() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        model.applyGitDiff([
            src.appendingPathComponent("main.swift").path: GitFileDiff(insertions: 3, deletions: 1)
        ])
        XCTAssertFalse(model.gitDiff.isEmpty)

        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        model.setRoot(otherRoot)
        XCTAssertTrue(model.gitDiff.isEmpty, "a re-rooted tree must not render the old root's badges")
        XCTAssertTrue(model.gitDiffDirTotals.isEmpty)
    }

    func testCancelClearsEverything() throws {
        let (root, src, model) = try makeFixture()
        model.activate(root: root)
        let srcNode = try entryNode(id: src.path, in: model)
        model.toggleExpanded(srcNode)

        model.cancel()
        XCTAssertEqual(model.watchedDirectoryCount, 0)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.rootURL)
    }

    /// One live kqueue round-trip: an external write must surface in `rows`
    /// through DirectoryWatcher's debounce without a manual `refresh` call.
    func testWatcherPicksUpExternalWrite() throws {
        let (root, _, model) = try makeFixture()
        model.activate(root: root)
        let liveFile = root.appendingPathComponent("live.txt")
        FileManager.default.createFile(atPath: liveFile.path, contents: Data())

        // Watcher fires on .main after ~200ms; spin the run loop generously
        // (slow CI) and bail as soon as the row lands.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !model.rows.contains(where: { $0.id == liveFile.path }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(model.rows.contains { $0.id == liveFile.path })
    }
}
