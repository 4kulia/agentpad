import XCTest
@testable import AgentPadKit

@MainActor
final class FileTransferBatchTests: XCTestCase {
    private var directory: URL!
    private var fm: TestTransferFileManager!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-batch-\(UUID())")
        fm = TestTransferFileManager(trashDirectory: directory.appendingPathComponent("Trash"))
        try fm.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("dst"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? fm.removeItem(at: directory) }
    @discardableResult private func write(_ path: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func read(_ path: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
    private func fixture(_ names: [String]) throws -> (TabState, FileTransferBatch) {
        let sources = try names.map { name in
            try write("dst/\(name)", "old-\(name)")
            return try write("src/\(name)", "new-\(name)")
        }
        let state = TabState(route: .fileOperations(operationID: UUID()))
        let batch = FileTransferBatch(.init(sources: sources, directory: directory.appendingPathComponent("dst"), mode: .copy), state: state, tabID: UUID())
        batch.fileManager = TransferFileIO(fm); state.fileOperation = batch
        return (state, batch)
    }

    func testReplaceStagesThenTrashesAndKeepsOriginalInFixtureTrash() async throws {
        let source = try write("src/a", "new"), destination = try write("dst/a", "old")
        let result = await FileOperations.transfer([source], into: destination.deletingLastPathComponent(), mode: .copy, fileManager: TransferFileIO(fm)) { _ in .replace }
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(fm.events, ["copy", "trash", "move"])
        XCTAssertEqual(try read("dst/a"), "new")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(fm.trashed.first), encoding: .utf8), "old")
    }

    func testFilesChangedWhileAwaitingOrDuringStagingAreNeverReplaced() async throws {
        for duringStaging in [false, true] {
            let source = try write("src/a", "new"), destination = try write("dst/a", "old")
            let manager = TestTransferFileManager(trashDirectory: fm.trashDirectory)
            if duringStaging { manager.afterCopy = { _, _ in try Data("changed externally".utf8).write(to: destination) } }
            let result = await FileOperations.transfer([source], into: destination.deletingLastPathComponent(), mode: .copy, fileManager: TransferFileIO(manager)) { _ in
                if !duringStaging { try? Data("changed externally".utf8).write(to: destination, options: .atomic) }
                return .replace
            }
            XCTAssertEqual(result.issues.count, 1)
            XCTAssertEqual(try read("dst/a"), "changed externally")
            XCTAssertEqual(try read("src/a"), "new")
            XCTAssertTrue(manager.trashed.isEmpty)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["a"])
        }
    }

    func testStopStillStopsWhenTheConflictingFileChangedWhileWaiting() async throws {
        let source = try write("src/a", "new"), next = try write("src/b", "next")
        let destination = try write("dst/a", "old")
        let result = await FileOperations.transfer([source, next], into: destination.deletingLastPathComponent(), mode: .copy, fileManager: TransferFileIO(fm)) { _ in
            try? Data("external edit".utf8).write(to: destination, options: .atomic)
            return .stop
        }
        XCTAssertTrue(result.done.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("dst/b").path))
        XCTAssertEqual(try read("dst/a"), "external edit")
    }

    func testApplyToAllAffectsOnlyRemainingConflictsAndDoesNotBlockTheActor() async throws {
        let (state, batch) = try fixture(["a", "b", "c"])
        let operation = Task { await batch.start() }
        try await settle { batch.conflict?.lastPathComponent == "a" }
        XCTAssertFalse(batch.snapshot.finished)
        XCTAssertEqual(try read("dst/a"), "old-a")
        batch.choose(.skip)
        try await settle { batch.conflict?.lastPathComponent == "b" }
        batch.applyToAll = true; batch.choose(.keepBoth)
        let result = await operation.value
        XCTAssertEqual(result.skipped.map(\.lastPathComponent), ["a"])
        XCTAssertEqual(result.done.map(\.lastPathComponent), ["b 2", "c 2"])
        XCTAssertEqual(try read("dst/a"), "old-a")
        XCTAssertEqual(try read("dst/b 2"), "new-b")
        XCTAssertTrue(state.navigation.fileTransfer?.finished == true)
    }

    func testReplaceRequiresInlineConsentAndApplyToAllStillChecksEachFile() async throws {
        let (state, batch) = try fixture(["a", "b"])
        let operation = Task { await batch.start() }
        try await settle { batch.conflict != nil }
        batch.applyToAll = true; batch.replace()
        XCTAssertEqual(state.confirmation.phase, .awaiting)
        state.confirmation.confirm()
        XCTAssertTrue(fm.trashed.isEmpty, "An unseen decision cannot grant Replace")
        state.confirmation.shown(true); state.confirmation.confirm(); state.confirmation.confirm()
        let result = await operation.value
        XCTAssertEqual(result.doneSources.count, 2)
        XCTAssertEqual(fm.trashed.count, 2)
        XCTAssertEqual(try read("dst/a"), "new-a")
        XCTAssertEqual(try read("dst/b"), "new-b")
    }

    func testStopCloseAndRestartNeverResumeAutomatically() async throws {
        for close in [false, true] {
            let (state, batch) = try fixture(["a", "b"])
            let operation = Task { await batch.start() }
            try await settle { batch.conflict != nil }
            if close { state.close() } else { batch.choose(.stop) }
            let result = await operation.value
            XCTAssertTrue(result.done.isEmpty)
            XCTAssertEqual(try read("dst/a"), "old-a")
            XCTAssertEqual(try read("dst/b"), "old-b")
            let encoded = try JSONEncoder().encode(state.navigation)
            let navigation = try JSONDecoder().decode(TabNavigation.self, from: encoded)
            let restoredState = TabState(route: state.route, navigation: navigation)
            let restored = FileTransferBatch(try XCTUnwrap(navigation.fileTransfer), state: restoredState, tabID: UUID(), restored: true)
            restored.fileManager = TransferFileIO(fm)
            _ = await restored.start()
            XCTAssertTrue(restored.interrupted)
            XCTAssertNil(restored.conflict)
            XCTAssertTrue(restored.snapshot.result.done.isEmpty)
        }
    }

    func testNavigationReleasesPendingConflictAndRetryDoesNotRepeatSuccess() async throws {
        let (state, batch) = try fixture(["a", "b"])
        let operation = Task { await batch.start() }
        try await settle { batch.conflict?.lastPathComponent == "a" }
        batch.choose(.keepBoth)
        try await settle { batch.conflict?.lastPathComponent == "b" }
        state.leave()
        _ = await operation.value
        XCTAssertEqual(batch.snapshot.result.done.count, 1)
        batch.resume()
        try await settle { batch.conflict?.lastPathComponent == "b" }
        batch.choose(.skip)
        try await settle { !batch.running }
        XCTAssertEqual(batch.snapshot.result.done.map(\.lastPathComponent), ["a 2"])
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("dst/a 3").path))
    }
}
