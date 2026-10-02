import XCTest
@testable import AgentPadKit

final class WorktreeManagerTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        // Each test creates its repo + worktree under temporaryDirectory;
        // collect them here so a `git worktree remove` skip doesn't leave
        // half-built repos around between runs.
        for url in tempRoots { try? FileManager.default.removeItem(at: url) }
        tempRoots.removeAll()
        super.tearDown()
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-wt-\(UUID().uuidString)")
        tempRoots.append(url)
        return url
    }

    /// Spins up a git repo with one empty commit so worktrees can branch
    /// off `main`. `-c user.*` sidesteps machines without global git
    /// identity (CI / fresh dev boxes).
    @discardableResult
    private func makeRepo(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard GitStatusFetcher.runGit(["-C", url.path, "init", "--initial-branch=main"], timeout: 5) != nil else {
            return false
        }
        guard GitStatusFetcher.runGit([
            "-C", url.path,
            "-c", "user.email=test@example.com",
            "-c", "user.name=Test",
            "commit", "--allow-empty", "-m", "init", "--no-gpg-sign"
        ], timeout: 5) != nil else {
            return false
        }
        return true
    }

    // MARK: - parseList (pure)

    func testParseListEmpty() {
        XCTAssertEqual(WorktreeManager.parseList(""), [])
    }

    func testParseListMultipleRecords() {
        let output = """
        worktree /Users/test/repo
        HEAD abc123
        branch refs/heads/main

        worktree /Users/test/repo-feat
        HEAD def456
        branch refs/heads/feat-x

        """
        let infos = WorktreeManager.parseList(output)
        XCTAssertEqual(infos.count, 2)
        XCTAssertEqual(infos[0].path, URL(fileURLWithPath: "/Users/test/repo"))
        XCTAssertEqual(infos[0].branch, "main")
        XCTAssertEqual(infos[1].path, URL(fileURLWithPath: "/Users/test/repo-feat"))
        XCTAssertEqual(infos[1].branch, "feat-x")
    }

    func testParseListDetachedHEADHasNilBranch() {
        let output = """
        worktree /Users/test/repo
        HEAD abc123
        detached

        """
        let infos = WorktreeManager.parseList(output)
        XCTAssertEqual(infos.count, 1)
        XCTAssertNil(infos[0].branch)
    }

    func testCheckedOutBranchesDropsDetachedRecords() {
        let infos = [
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/repo"), branch: "main"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/repo-feat"), branch: "feature/foo"),
            WorktreeManager.Info(path: URL(fileURLWithPath: "/tmp/repo-detached"), branch: nil),
        ]

        XCTAssertEqual(WorktreeManager.checkedOutBranches(in: infos), ["main", "feature/foo"])
    }

    func testDefaultDirectoryNameSlugsBranchPathSeparators() {
        XCTAssertEqual(
            WorktreeManager.defaultDirectoryName(sourceName: "agentpad", branch: "feature/worktree ux"),
            "agentpad-feature-worktree-ux"
        )
        XCTAssertEqual(
            WorktreeManager.defaultDirectoryName(sourceName: "agentpad", branch: "bugfix\\pane:drag"),
            "agentpad-bugfix-pane-drag"
        )
    }

    func testDefaultDirectoryNameKeepsPlaceholderShapeWhenBranchEmpty() {
        XCTAssertEqual(
            WorktreeManager.defaultDirectoryName(sourceName: "agentpad", branch: ""),
            "agentpad-"
        )
    }

    func testRepoRootResolvesFromNestedDirectory() throws {
        let repo = tempDir()
        try XCTSkipUnless(makeRepo(at: repo), "git unavailable")
        let nested = repo.appendingPathComponent("sub/dir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let root = WorktreeManager.repoRoot(near: nested)

        XCTAssertEqual(root?.standardizedFileURL, repo.standardizedFileURL)
    }

    // MARK: - Integration (git on PATH)

    func testAddNewBranchListsAndRemoves() throws {
        let repo = tempDir()
        try XCTSkipUnless(makeRepo(at: repo), "git unavailable")

        let wt = repo.appendingPathExtension("feat-x")

        let addResult = WorktreeManager.add(
            repoPath: repo,
            path: wt,
            mode: .newBranch(name: "feat-x", base: nil)
        )
        if case .failure(let err) = addResult {
            XCTFail("add failed: \(err.description)")
            return
        }

        guard case .success(let infos) = WorktreeManager.list(repoPath: repo) else {
            XCTFail("list failed"); return
        }
        XCTAssertEqual(infos.count, 2)
        XCTAssertTrue(infos.contains { $0.branch == "feat-x" })

        let removeResult = WorktreeManager.remove(repoPath: repo, path: wt, force: false)
        if case .failure(let err) = removeResult {
            XCTFail("remove failed: \(err.description)")
            return
        }

        guard case .success(let afterRemove) = WorktreeManager.list(repoPath: repo) else {
            XCTFail("list after remove failed"); return
        }
        XCTAssertEqual(afterRemove.count, 1)
    }

    func testAddExistingBranchCheckoutWorks() throws {
        let repo = tempDir()
        try XCTSkipUnless(makeRepo(at: repo), "git unavailable")
        _ = GitStatusFetcher.runGit(["-C", repo.path, "branch", "side"], timeout: 5)

        let wt = repo.appendingPathExtension("side")
        let result = WorktreeManager.add(
            repoPath: repo, path: wt, mode: .existing(branch: "side")
        )
        if case .failure(let err) = result {
            XCTFail("add existing failed: \(err.description)")
            return
        }
        guard case .success(let infos) = WorktreeManager.list(repoPath: repo) else {
            XCTFail("list failed"); return
        }
        XCTAssertTrue(infos.contains { $0.branch == "side" })
    }

    func testAddFailsCarriesStderrFromGit() throws {
        // Picking a clearly bogus branch name keeps the failure stable
        // across git versions (some accept an empty dir as the worktree
        // path; none accept an unknown ref).
        let repo = tempDir()
        try XCTSkipUnless(makeRepo(at: repo), "git unavailable")

        let wt = repo.appendingPathExtension("ghost")
        let result = WorktreeManager.add(
            repoPath: repo,
            path: wt,
            mode: .existing(branch: "this-branch-does-not-exist-12345")
        )
        guard case .failure(let err) = result else {
            XCTFail("expected failure when branch is unknown")
            return
        }
        XCTAssertFalse(err.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "stderr should carry git's message")
        XCTAssertNotEqual(err.exitCode, 0)
    }

    // MARK: - runGit pipe drain

    // Regression (Codex review, same class as GitStatusFetcher's): runGit
    // used to read both pipes only AFTER exit — git blocks writing once
    // either stream passes the ~64KB pipe buffer, never exits, and the
    // timeout misreported "git timed out". A `!`-alias makes git itself
    // produce the oversized stream, so no fixture repo is needed.

    func testRunGitDrainsStdoutLargerThanPipeBuffer() throws {
        let result = WorktreeManager.runGit(
            ["-c", "alias.spew=!yes stdout-filler-line | head -c 150000", "spew"],
            timeout: 10
        )
        guard case .success(let output) = result else {
            XCTFail("expected success, got \(result)")
            return
        }
        XCTAssertGreaterThan(output.utf8.count, 100_000)
    }

    func testRunGitDrainsStderrLargerThanPipeBuffer() throws {
        let result = WorktreeManager.runGit(
            ["-c", "alias.spew=!yes stderr-filler-line | head -c 150000 1>&2; exit 3", "spew"],
            timeout: 10
        )
        guard case .failure(let err) = result else {
            XCTFail("expected failure, got \(result)")
            return
        }
        XCTAssertEqual(err.exitCode, 3)
        XCTAssertGreaterThan(err.stderr.utf8.count, 100_000,
                             "the full oversized stderr must reach the caller")
    }
}
