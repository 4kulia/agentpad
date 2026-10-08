import XCTest
@testable import AgentPadKit

/// AgentPad: file operations in the sidebar tree, against a temp directory.
/// The dialogs and the real pasteboard stay manual; `transfer` takes the
/// conflict answer as a closure so every branch is covered here.
@MainActor
final class FileOperationsTests: XCTestCase {
    private var dir: URL!
    private var fm: TestTransferFileManager!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileops-\(UUID().uuidString)")
        fm = TestTransferFileManager(trashDirectory: dir.appendingPathComponent("Trash"))
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

    func testCopyAndMove() async throws {
        let a = try write("src/a.txt", "A")
        let b = try write("src/b.txt", "B")
        let dst = dir.appendingPathComponent("dst")
        let copied = await FileOperations.transfer([a], into: dst, mode: .copy, fileManager: TransferFileIO(fm)) { _ in XCTFail("no clash"); return .skip }
        XCTAssertEqual(copied.done.map(\.lastPathComponent), ["a.txt"])
        XCTAssertEqual(read("src/a.txt"), "A")
        let moved = await FileOperations.transfer([b], into: dst, mode: .move, fileManager: TransferFileIO(fm)) { _ in .skip }
        XCTAssertEqual(moved.done.count, 1)
        XCTAssertNil(read("src/b.txt"))
        XCTAssertEqual(try names("dst"), ["a.txt", "b.txt"])
    }

    func testConflictChoices() async throws {
        let src = try write("src/a.txt", "new")
        try write("dst/a.txt", "old")
        let dst = dir.appendingPathComponent("dst")

        let transferCount1 = await FileOperations.transfer([src], into: dst, mode: .copy, fileManager: TransferFileIO(fm)) { _ in .skip }.skipped.count
        XCTAssertEqual(transferCount1, 1)
        XCTAssertEqual(read("dst/a.txt"), "old")

        await FileOperations.transfer([src], into: dst, mode: .copy, fileManager: TransferFileIO(fm)) { _ in .keepBoth }
        XCTAssertEqual(try names("dst"), ["a 2.txt", "a.txt"])
        XCTAssertEqual(read("dst/a 2.txt"), "new")

        await FileOperations.transfer([src], into: dst, mode: .copy, fileManager: TransferFileIO(fm)) { _ in .replace }
        XCTAssertEqual(read("dst/a.txt"), "new", "replaced; the old one went to the Trash")
    }

    func testStopEndsTheWholeBatch() async throws {
        let a = try write("src/a.txt")
        let b = try write("src/b.txt")
        try write("dst/a.txt")
        let result = await FileOperations.transfer([a, b], into: dir.appendingPathComponent("dst"), mode: .copy, fileManager: TransferFileIO(fm)) { _ in .stop }
        XCTAssertTrue(result.done.isEmpty)
        XCTAssertFalse(try names("dst").contains("b.txt"))
    }

    func testPastingIntoTheSameFolderDuplicatesAndMovingThereIsANoop() async throws {
        let a = try write("src/a.txt")
        let src = dir.appendingPathComponent("src")
        await FileOperations.transfer([a], into: src, mode: .copy, fileManager: TransferFileIO(fm)) { _ in XCTFail("no prompt"); return .skip }
        XCTAssertEqual(try names("src"), ["a copy.txt", "a.txt"])
        let move = await FileOperations.transfer([a], into: src, mode: .move, fileManager: TransferFileIO(fm)) { _ in .skip }
        XCTAssertEqual(move.skipped.count, 1)
        XCTAssertNotNil(read("src/a.txt"))
    }

    func testFolderCannotGoInsideItself() async throws {
        let folder = dir.appendingPathComponent("src")
        let inner = folder.appendingPathComponent("inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let transferCount1 = await FileOperations.transfer([folder], into: inner, mode: .move, fileManager: TransferFileIO(fm)) { _ in .skip }.failures.count
        XCTAssertEqual(transferCount1, 1)
        let transferCount2 = await FileOperations.transfer([folder], into: folder, mode: .copy, fileManager: TransferFileIO(fm)) { _ in .skip }.failures.count
        XCTAssertEqual(transferCount2, 1)
        XCTAssertTrue(fm.fileExists(atPath: inner.path))
    }

    func testReplaceRefusesToTrashAFolderHoldingTheSource() async throws {
        // Moving /src/A/x/A up into /src, where "A" exists: replacing /src/A
        // would trash the source itself.
        let deep = dir.appendingPathComponent("src/A/x/A")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try write("src/A/x/A/keep.txt", "precious")
        let result = await FileOperations.transfer([deep], into: dir.appendingPathComponent("src"), mode: .move, fileManager: TransferFileIO(fm)) { _ in .replace }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(read("src/A/x/A/keep.txt"), "precious")
    }

    func testPastingThroughASymlinkIsRecognisedAsTheSameFolder() async throws {
        let a = try write("src/a.txt", "A")
        let alias = dir.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: dir.appendingPathComponent("src"))
        // Without identity checks this looks like a clash, and Replace would trash the source.
        let result = await FileOperations.transfer([a], into: alias, mode: .copy, fileManager: TransferFileIO(fm)) { _ in XCTFail("not a clash"); return .replace }
        XCTAssertEqual(result.done.map(\.lastPathComponent), ["a copy.txt"])
        XCTAssertEqual(read("src/a.txt"), "A")
        let move = await FileOperations.transfer([a], into: alias, mode: .move, fileManager: TransferFileIO(fm)) { _ in .replace }
        XCTAssertEqual(move.skipped.count, 1)
        XCTAssertEqual(read("src/a.txt"), "A")
    }

    func testFailedReplaceKeepsTheOriginal() async throws {
        try write("dst/a.txt", "old")
        let missing = dir.appendingPathComponent("src/a.txt")   // never created
        let result = await FileOperations.transfer([missing], into: dir.appendingPathComponent("dst"), mode: .copy, fileManager: TransferFileIO(fm)) { _ in .replace }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(read("dst/a.txt"), "old")
        XCTAssertEqual(try names("dst"), ["a.txt"], "no temp file left behind")
    }

    func testReplaceReportsMovedSources() async throws {
        let a = try write("src/a.txt", "new")
        try write("dst/a.txt", "old")
        let result = await FileOperations.transfer([a], into: dir.appendingPathComponent("dst"), mode: .move, fileManager: TransferFileIO(fm)) { _ in .replace }
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

    func testInlineFileRenameCollisionKeepsInputAndOnlyMarksItsRow() throws {
        let source = try write("src/source.txt", "source")
        let taken = try write("src/taken.txt", "keep")
        let edit = FileNameEdit()
        edit.beginRename(source)
        edit.draft?.name = "taken.txt"
        edit.commit()
        XCTAssertEqual(edit.draft?.name, "taken.txt")
        XCTAssertNotNil(edit.error(for: source))
        XCTAssertNil(edit.error(for: taken))
        XCTAssertEqual(read("src/source.txt"), "source")
        XCTAssertEqual(read("src/taken.txt"), "keep")
        edit.draft?.name = "renamed.txt"
        edit.commit()
        XCTAssertNil(edit.draft)
        XCTAssertNil(edit.error(for: source))
        XCTAssertEqual(read("src/renamed.txt"), "source")
        XCTAssertEqual(read("src/taken.txt"), "keep")
    }

    func testCaseOnlyRenameChangesDirectoryEntryWithoutReplacingOtherFiles() throws {
        let source = try write("src/notes.txt", "keep case")
        XCTAssertNil(FileOperations.renameItem(source, to: "Notes.txt"))
        XCTAssertEqual(try names("src"), ["Notes.txt"])
        XCTAssertEqual(read("src/Notes.txt"), "keep case")
        let other = try write("src/other.txt", "other")
        XCTAssertNotNil(FileOperations.renameItem(other, to: "Notes.txt"))
        XCTAssertEqual(read("src/Notes.txt"), "keep case")
        XCTAssertEqual(read("src/other.txt"), "other")
    }

    func testRenameSymlinkMovesLinkAndDanglingSymlinkBlocksCreate() throws {
        let target = try write("src/target.txt", "target")
        let link = dir.appendingPathComponent("src/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let edit = FileNameEdit()
        edit.beginRename(link)
        edit.draft?.name = "moved-link"
        edit.commit()
        XCTAssertNil(edit.draft)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("src/moved-link").path), target.path)
        XCTAssertEqual(read("src/target.txt"), "target")
        XCTAssertFalse(FileOperations.defaultExists(link))
        let dangling = dir.appendingPathComponent("src/dangling")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing-target")
        edit.beginNew(in: dir.appendingPathComponent("src"))
        edit.draft?.name = "dangling"
        edit.commit()
        XCTAssertNotNil(edit.draft)
        XCTAssertNotNil(edit.error(for: dir.appendingPathComponent("src")))
        XCTAssertNotNil(FileOperations.createExclusively(dangling))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dangling.path), "missing-target")
    }

    func testFilePermissionErrorsStayWithCorrectRowAndCanRetry() throws {
        let root = dir.appendingPathComponent("src"), source = try write("src/locked.txt", "keep")
        let unrelated = try write("src/other.txt", "other")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let edit = FileNameEdit()
        edit.beginRename(source); edit.draft?.name = "renamed.txt"; edit.commit()
        XCTAssertNotNil(edit.error(for: source))
        XCTAssertNil(edit.error(for: unrelated))
        XCTAssertEqual(edit.draft?.name, "renamed.txt")
        XCTAssertEqual(read("src/locked.txt"), "keep")
        XCTAssertNotNil(FileOperations.createExclusively(root.appendingPathComponent("new.txt")))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        edit.commit()
        XCTAssertNil(edit.draft)
        XCTAssertNil(edit.error(for: source))
        XCTAssertEqual(read("src/renamed.txt"), "keep")
    }

    func testInlineCreateCollisionAndEscapeHaveNoEffectOnExistingFile() throws {
        let root = dir.appendingPathComponent("src")
        try write("src/existing", "keep")
        let edit = FileNameEdit()
        edit.beginNew(in: root); edit.draft?.name = "existing"; edit.commit()
        XCTAssertEqual(read("src/existing"), "keep")
        XCTAssertEqual(edit.draft?.name, "existing")
        edit.draft?.name = "cancelled"
        edit.cancel()
        XCTAssertNil(edit.draft)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("cancelled").path))
        for invalid in ["", "a/b", ".", "..", "bad\0name", "bad\nname", "a:b"] {
            edit.beginNew(in: root); edit.draft?.name = invalid; edit.commit()
            XCTAssertNotNil(edit.error(for: root), invalid)
            XCTAssertEqual(edit.draft?.name, invalid)
            edit.cancel()
        }
    }

    func testBatchErrorsAreAddressedToFailedSourceAndSuccessStaysClear() async throws {
        let good = try write("src/good.txt", "good")
        let missing = dir.appendingPathComponent("src/missing.txt")
        let result = await FileOperations.transfer([good, missing], into: dir.appendingPathComponent("dst"), mode: .copy, fileManager: TransferFileIO(fm)) { _ in .skip }
        let edit = FileNameEdit()
        FileOperations.report(result.issues, editor: edit)
        XCTAssertEqual(result.doneSources, [good.standardizedFileURL])
        XCTAssertEqual(result.issues.map(\.url), [missing.standardizedFileURL])
        XCTAssertNil(edit.error(for: good))
        XCTAssertNotNil(edit.error(for: missing))
        XCTAssertEqual(read("dst/good.txt"), "good")
        edit.record([.init(url: missing, message: "Copy failed"), .init(url: missing, message: "Staging cleanup failed")])
        XCTAssertEqual(edit.error(for: missing), "Copy failed\nStaging cleanup failed")
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
