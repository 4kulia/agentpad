import XCTest
@testable import AgentPadKit

final class GitStatusFetcherTests: XCTestCase {
    // MARK: - parseNumstat (-z records)

    func testParseNumstatNormalAndBinary() {
        // Two normal entries + one binary (numstat prints `-` → 0/0).
        let raw = "12\t3\tSources/App/Main.swift\u{0}0\t7\tREADME.md\u{0}-\t-\timg/icon.png\u{0}"
        let entries = GitStatusFetcher.parseNumstat(raw)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].path, "Sources/App/Main.swift")
        XCTAssertEqual(entries[0].insertions, 12)
        XCTAssertEqual(entries[0].deletions, 3)
        XCTAssertEqual(entries[1].path, "README.md")
        XCTAssertEqual(entries[1].insertions, 0)
        XCTAssertEqual(entries[1].deletions, 7)
        XCTAssertEqual(entries[2].path, "img/icon.png")
        XCTAssertEqual(entries[2].insertions, 0)
        XCTAssertEqual(entries[2].deletions, 0)
    }

    func testParseNumstatRenameKeepsPostPath() {
        // A rename record is `ins\tdel\t` + two extra NUL fields (pre, post);
        // the post-path is the file's current name on disk.
        let raw = "5\t1\t\u{0}old/Name.swift\u{0}new/Name.swift\u{0}2\t0\tother.txt\u{0}"
        let entries = GitStatusFetcher.parseNumstat(raw)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "new/Name.swift")
        XCTAssertEqual(entries[0].insertions, 5)
        XCTAssertEqual(entries[0].deletions, 1)
        XCTAssertEqual(entries[1].path, "other.txt")
    }

    func testParseNumstatEmpty() {
        XCTAssertTrue(GitStatusFetcher.parseNumstat("").isEmpty)
    }

    func testOrderedDiffEntriesSortsByPath() {
        // Diff pill popover rows: numstat order (git's index order) is
        // replaced by an explicit path sort; binary (`-`) and rename records
        // survive the mapping with the parse's semantics intact.
        let raw = "0\t7\tzeta/tail.md\u{0}-\t-\timg/icon.png\u{0}5\t1\t\u{0}old/Name.swift\u{0}alpha/Name.swift\u{0}"
        let entries = GitStatusFetcher.orderedDiffEntries(numstat: raw)
        XCTAssertEqual(entries.map(\.path), ["alpha/Name.swift", "img/icon.png", "zeta/tail.md"])
        XCTAssertEqual(entries[0].insertions, 5)
        XCTAssertEqual(entries[0].deletions, 1)
        XCTAssertEqual(entries[1].insertions, 0)
        XCTAssertEqual(entries[1].deletions, 0)

        let snapshot = GitDiffSnapshot(repoRoot: "/tmp/repo", entries: entries)
        XCTAssertEqual(snapshot.filesChanged, 3)
        XCTAssertEqual(snapshot.insertions, 5)
        XCTAssertEqual(snapshot.deletions, 8)
    }

    // MARK: - runGit pipe draining

    func testRunGitDrainsOutputLargerThanPipeBuffer() throws {
        // Regression (Codex review): runGit used to read stdout only AFTER
        // exit — git blocks writing once output passes the ~64KB pipe
        // buffer, the timeout kills it, and callers see nil (file-tree
        // badges vanish on exactly the large changesets they matter for).
        // 1500 deletions under a long directory name ≈ 100KB+ of numstat.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpad-numstat-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(
            "deeply-nested-directory-name-that-pads-numstat-lines-past-the-pipe-buffer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for i in 0..<1500 {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent("file-\(String(format: "%04d", i)).txt").path,
                contents: Data("x\n".utf8)
            )
        }
        // Generous timeouts: this test pins the drain behavior, not speed.
        XCTAssertNotNil(GitStatusFetcher.runGit(["-C", root.path, "init", "-q"], timeout: 10))
        XCTAssertNotNil(GitStatusFetcher.runGit(["-C", root.path, "add", "-A"], timeout: 10))
        XCTAssertNotNil(GitStatusFetcher.runGit(
            ["-C", root.path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed"],
            timeout: 10
        ))
        try FileManager.default.removeItem(at: dir)

        let raw = GitStatusFetcher.runGit(
            ["-C", root.path, "--no-optional-locks", "diff", "--numstat", "-z", "HEAD"],
            timeout: 10
        )
        let entries = GitStatusFetcher.parseNumstat(try XCTUnwrap(
            raw, "numstat larger than the pipe buffer must not deadlock into the timeout"
        ))
        XCTAssertEqual(entries.count, 1500)
    }

    // MARK: - parseShortstat

    func testParseShortstatAllThree() {
        let (files, ins, del) = GitStatusFetcher.parseShortstat(
            " 3 files changed, 47 insertions(+), 12 deletions(-)"
        )
        XCTAssertEqual(files, 3)
        XCTAssertEqual(ins, 47)
        XCTAssertEqual(del, 12)
    }

    func testParseShortstatInsertionsOnly() {
        let (files, ins, del) = GitStatusFetcher.parseShortstat(
            " 1 file changed, 5 insertions(+)"
        )
        XCTAssertEqual(files, 1)
        XCTAssertEqual(ins, 5)
        XCTAssertEqual(del, 0)
    }

    func testParseShortstatDeletionsOnly() {
        let (files, ins, del) = GitStatusFetcher.parseShortstat(
            " 1 file changed, 3 deletions(-)"
        )
        XCTAssertEqual(files, 1)
        XCTAssertEqual(ins, 0)
        XCTAssertEqual(del, 3)
    }

    func testParseShortstatSingularNouns() {
        // git uses "1 file"/"1 insertion"/"1 deletion" (singular) when
        // count == 1 — prefix-match handles both forms.
        let (files, ins, del) = GitStatusFetcher.parseShortstat(
            " 1 file changed, 1 insertion(+), 1 deletion(-)"
        )
        XCTAssertEqual(files, 1)
        XCTAssertEqual(ins, 1)
        XCTAssertEqual(del, 1)
    }

    func testParseShortstatEmptyReturnsZeros() {
        let (files, ins, del) = GitStatusFetcher.parseShortstat("")
        XCTAssertEqual(files, 0)
        XCTAssertEqual(ins, 0)
        XCTAssertEqual(del, 0)
    }

    func testParseShortstatGarbageReturnsZeros() {
        let (files, ins, del) = GitStatusFetcher.parseShortstat("not a real shortstat output")
        XCTAssertEqual(files, 0)
        XCTAssertEqual(ins, 0)
        XCTAssertEqual(del, 0)
    }

    func testParseBranchesDropsBlanksAndDuplicates() {
        XCTAssertEqual(
            GitBranchInventory.parseBranches("main\n\nfeature/login\nmain\n"),
            ["main", "feature/login"]
        )
    }

    func testShellSwitchCommandQuotesBranchName() {
        XCTAssertEqual(
            GitBranchInventory.shellSwitchCommand(branch: "feature/needs review"),
            "git switch 'feature/needs review'\r"
        )
    }

    func testShellSwitchCommandEscapesSingleQuote() {
        XCTAssertEqual(
            GitBranchInventory.shellSwitchCommand(branch: "fix/corey's-branch"),
            "git switch 'fix/corey'\\''s-branch'\r"
        )
    }
}
