import XCTest
@testable import AgentPadKit

/// AgentPad: file operations in the sidebar tree, against a temp directory.
/// The dialogs and the real pasteboard stay manual; `transfer` takes the
/// conflict answer as a closure so every branch is covered here.
@MainActor
final class FileOperationsTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("fileops-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dst"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? fm.removeItem(at: dir) }
    }

    @discardableResult
    private func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func names(_ path: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.appendingPathComponent(path).path).sorted()
    }

    // MARK: Naming

    func testSplitKeepsDotfilesAndCompoundExtensions() {
        XCTAssertTrue(FileOperations.split(".env") == (".env", nil))
        XCTAssertTrue(FileOperations.split("a.tar.gz") == ("a.tar", "gz"))
        XCTAssertTrue(FileOperations.split("Makefile") == ("Makefile", nil))
        XCTAssertTrue(FileOperations.split("trailing.") == ("trailing.", nil))
    }

    func testUniqueAndDuplicateNamesFollowFinder() {
        let taken: Set<String> = ["/d/a.txt", "/d/a 2.txt", "/d/a copy.txt"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(FileOperations.uniqueURL(for: URL(fileURLWithPath: "/d/a.txt"), exists: exists).lastPathComponent, "a 3.txt")
        XCTAssertEqual(FileOperations.uniqueURL(for: URL(fileURLWithPath: "/d/b.txt"), exists: exists).lastPathComponent, "b.txt")
        XCTAssertEqual(FileOperations.duplicateURL(for: URL(fileURLWithPath: "/d/a.txt"), exists: exists).lastPathComponent, "a copy 2.txt")
        XCTAssertEqual(FileOperations.duplicateURL(for: URL(fileURLWithPath: "/d/folder"), exists: exists).lastPathComponent, "folder copy")
    }

    func testRenameProblems() throws {
        try write("src/taken.txt")
        let src = dir.appendingPathComponent("src")
        XCTAssertNotNil(FileOperations.renameProblem("  ", in: src))
        XCTAssertNotNil(FileOperations.renameProblem("a/b", in: src))
        XCTAssertNotNil(FileOperations.renameProblem("..", in: src))
        XCTAssertNotNil(FileOperations.renameProblem("taken.txt", in: src, current: "other.txt"))
        XCTAssertNil(FileOperations.renameProblem("Taken.txt", in: src, current: "taken.txt"), "case-only rename")
        XCTAssertNil(FileOperations.renameProblem("fresh.txt", in: src, current: "other.txt"))
    }

    // MARK: Transfers

    func testCopyAndMove() throws {
        let a = try write("src/a.txt", "A")
        let b = try write("src/b.txt", "B")
        let dst = dir.appendingPathComponent("dst")
        let copied = FileOperations.transfer([a], into: dst, mode: .copy) { _ in XCTFail("no clash"); return .skip }
        XCTAssertEqual(copied.done.map(\.lastPathComponent), ["a.txt"])
        XCTAssertEqual(read("src/a.txt"), "A")
        let moved = FileOperations.transfer([b], into: dst, mode: .move) { _ in .skip }
        XCTAssertEqual(moved.done.count, 1)
        XCTAssertNil(read("src/b.txt"))
        XCTAssertEqual(try names("dst"), ["a.txt", "b.txt"])
    }

    func testConflictChoices() throws {
        let src = try write("src/a.txt", "new")
        try write("dst/a.txt", "old")
        let dst = dir.appendingPathComponent("dst")

        XCTAssertEqual(FileOperations.transfer([src], into: dst, mode: .copy) { _ in .skip }.skipped.count, 1)
        XCTAssertEqual(read("dst/a.txt"), "old")

        FileOperations.transfer([src], into: dst, mode: .copy) { _ in .keepBoth }
        XCTAssertEqual(try names("dst"), ["a 2.txt", "a.txt"])
        XCTAssertEqual(read("dst/a 2.txt"), "new")

        FileOperations.transfer([src], into: dst, mode: .copy) { _ in .replace }
        XCTAssertEqual(read("dst/a.txt"), "new", "replaced; the old one went to the Trash")
    }

    func testStopEndsTheWholeBatch() throws {
        let a = try write("src/a.txt")
        let b = try write("src/b.txt")
        try write("dst/a.txt")
        let result = FileOperations.transfer([a, b], into: dir.appendingPathComponent("dst"), mode: .copy) { _ in .stop }
        XCTAssertTrue(result.done.isEmpty)
        XCTAssertFalse(try names("dst").contains("b.txt"))
    }

    func testPastingIntoTheSameFolderDuplicatesAndMovingThereIsANoop() throws {
        let a = try write("src/a.txt")
        let src = dir.appendingPathComponent("src")
        FileOperations.transfer([a], into: src, mode: .copy) { _ in XCTFail("no prompt"); return .skip }
        XCTAssertEqual(try names("src"), ["a copy.txt", "a.txt"])
        let move = FileOperations.transfer([a], into: src, mode: .move) { _ in .skip }
        XCTAssertEqual(move.skipped.count, 1)
        XCTAssertNotNil(read("src/a.txt"))
    }

    func testFolderCannotGoInsideItself() throws {
        let folder = dir.appendingPathComponent("src")
        let inner = folder.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertEqual(FileOperations.transfer([folder], into: inner, mode: .move) { _ in .skip }.failures.count, 1)
        XCTAssertEqual(FileOperations.transfer([folder], into: folder, mode: .copy) { _ in .skip }.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: inner.path))
    }

    func testReplaceRefusesToTrashAFolderHoldingTheSource() throws {
        // Moving /src/A/x/A up into /src, where "A" exists: replacing /src/A
        // would trash the source itself.
        let deep = dir.appendingPathComponent("src/A/x/A")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try write("src/A/x/A/keep.txt", "precious")
        let result = FileOperations.transfer([deep], into: dir.appendingPathComponent("src"), mode: .move) { _ in .replace }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(read("src/A/x/A/keep.txt"), "precious")
    }

    func testPastingThroughASymlinkIsRecognisedAsTheSameFolder() throws {
        let a = try write("src/a.txt", "A")
        let alias = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: dir.appendingPathComponent("src"))
        // Without identity checks this looks like a clash, and Replace would trash the source.
        let result = FileOperations.transfer([a], into: alias, mode: .copy) { _ in XCTFail("not a clash"); return .replace }
        XCTAssertEqual(result.done.map(\.lastPathComponent), ["a copy.txt"])
        XCTAssertEqual(read("src/a.txt"), "A")
        let move = FileOperations.transfer([a], into: alias, mode: .move) { _ in .replace }
        XCTAssertEqual(move.skipped.count, 1)
        XCTAssertEqual(read("src/a.txt"), "A")
    }

    func testFailedReplaceKeepsTheOriginal() throws {
        try write("dst/a.txt", "old")
        let missing = dir.appendingPathComponent("src/a.txt")   // never created
        let result = FileOperations.transfer([missing], into: dir.appendingPathComponent("dst"), mode: .copy) { _ in .replace }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(read("dst/a.txt"), "old")
        XCTAssertEqual(try names("dst"), ["a.txt"], "no temp file left behind")
    }

    func testReplaceReportsMovedSources() throws {
        let a = try write("src/a.txt", "new")
        try write("dst/a.txt", "old")
        let result = FileOperations.transfer([a], into: dir.appendingPathComponent("dst"), mode: .move) { _ in .replace }
        XCTAssertEqual(result.doneSources.map(\.lastPathComponent), ["a.txt"])
        XCTAssertEqual(read("dst/a.txt"), "new")
        XCTAssertEqual(try names("dst"), ["a.txt"])
    }

    func testCreateExclusivelyNeverTruncates() throws {
        let existing = try write("src/notes.txt", "keep me")
        XCTAssertNotNil(FileOperations.createExclusively(existing))
        XCTAssertEqual(read("src/notes.txt"), "keep me")
        XCTAssertNil(FileOperations.createExclusively(dir.appendingPathComponent("src/new.txt")))
        XCTAssertEqual(read("src/new.txt"), "")
    }

    // MARK: Drops

    func testDropMovesWithinTheRootAndCopiesFromOutside() {
        let root = URL(fileURLWithPath: "/proj")
        XCTAssertEqual(FileTreeDrop.mode(for: [URL(fileURLWithPath: "/proj/a.txt")], root: root), .move)
        XCTAssertEqual(FileTreeDrop.mode(for: [URL(fileURLWithPath: "/Users/x/Downloads/a.txt")], root: root), .copy)
        XCTAssertEqual(FileTreeDrop.mode(for: [URL(fileURLWithPath: "/project-other/a.txt")], root: root), .copy)
        XCTAssertEqual(FileTreeDrop.mode(for: [URL(fileURLWithPath: "/proj/a")], root: nil), .copy)
    }

    // MARK: Pasteboard

    func testCopyThenCutChangesPasteMode() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agentpad-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        FileOperations.copy([url], pasteboard: pasteboard)
        XCTAssertEqual(FileOperations.pasteboardFiles(pasteboard), [url])
        XCTAssertEqual(FileOperations.pasteMode(pasteboard), .copy)
        FileOperations.copy([url], cut: true, pasteboard: pasteboard)
        XCTAssertEqual(FileOperations.pasteMode(pasteboard), .move)
        // Anyone writing to the pasteboard afterwards cancels the cut.
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        XCTAssertEqual(FileOperations.pasteMode(pasteboard), .copy)
        XCTAssertFalse(FileOperations.canPaste(pasteboard))
    }

    // MARK: Search

    func testSearchMatchesWordsInPathSkipsToolingAndRanksNameHits() throws {
        try fm.createDirectory(at: dir.appendingPathComponent("src/auth"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/login"), withIntermediateDirectories: true)
        try write("src/auth/session.swift")
        try write("src/login.swift")
        try write("node_modules/login/index.js")
        try write("src/Résumé.md")
        func found(_ q: String) -> [String] { FileSearch.search(root: dir, query: q).map(\.relativePath) }
        XCTAssertEqual(found("login"), ["src/login.swift"], "node_modules skipped")
        XCTAssertEqual(found("auth session"), ["src/auth/session.swift"])
        XCTAssertEqual(found("resume"), ["src/Résumé.md"])
        XCTAssertEqual(found("auth").first, "src/auth", "the folder named auth beats files under it")
        XCTAssertEqual(found("   "), [])
    }

    func testHiddenFilesToggle() throws {
        try write("src/.env")
        try write("src/main.swift")
        let src = dir.appendingPathComponent("src")
        let key = FileTreePreferences.showHiddenKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertEqual(try FileTreeLister.children(of: src).map(\.name), [".env", "main.swift"])
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertEqual(try FileTreeLister.children(of: src).map(\.name), ["main.swift"])
    }
}
