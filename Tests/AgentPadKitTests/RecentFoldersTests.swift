import XCTest
@testable import AgentPadKit

@MainActor
final class RecentFoldersTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-recent-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeRecent() -> RecentFolders {
        RecentFolders(fileURL: fileURL)
    }

    func testNoteIsLRUWithDedup() {
        let recent = makeRecent()
        recent.note(URL(fileURLWithPath: "/tmp/a"))
        recent.note(URL(fileURLWithPath: "/tmp/b"))
        recent.note(URL(fileURLWithPath: "/tmp/a"))

        XCTAssertEqual(recent.paths, ["/tmp/a", "/tmp/b"], "re-noting moves the entry to the front, no duplicate")
    }

    func testNoteExcludesHomeDirectory() {
        let recent = makeRecent()
        recent.note(URL(fileURLWithPath: NSHomeDirectory()))
        XCTAssertTrue(recent.paths.isEmpty, "home is every fresh workspace's default cwd, not a project")
    }

    func testNoteStandardizesPaths() {
        let recent = makeRecent()
        recent.note(URL(fileURLWithPath: "/tmp/a/../a"))
        recent.note(URL(fileURLWithPath: "/tmp/a"))
        XCTAssertEqual(recent.paths.count, 1, "equivalent paths must collapse to one entry")
    }

    func testCapDropsOldest() {
        let recent = makeRecent()
        for i in 0..<(RecentFolders.cap + 5) {
            recent.note(URL(fileURLWithPath: "/tmp/project-\(i)"))
        }
        XCTAssertEqual(recent.paths.count, RecentFolders.cap)
        XCTAssertEqual(recent.paths.first, "/tmp/project-\(RecentFolders.cap + 4)")
        XCTAssertFalse(recent.paths.contains("/tmp/project-0"), "oldest entry falls off at cap")
    }

    func testPersistsAcrossInstances() {
        makeRecent().note(URL(fileURLWithPath: "/tmp/persisted-project"))

        let reloaded = makeRecent()
        XCTAssertEqual(reloaded.paths, ["/tmp/persisted-project"])
    }

    func testClearEmptiesAndPersists() {
        let recent = makeRecent()
        recent.note(URL(fileURLWithPath: "/tmp/a"))
        recent.clear()

        XCTAssertTrue(recent.paths.isEmpty)
        XCTAssertTrue(makeRecent().paths.isEmpty, "clear must survive a reload")
    }

    func testExistingFiltersDeadAndNonDirectoryPaths() throws {
        let fm = FileManager.default
        let liveDir = fm.temporaryDirectory.appendingPathComponent("agentpad-recent-live-\(UUID().uuidString)")
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: liveDir) }
        let file = liveDir.appendingPathComponent("not-a-dir.txt")
        try Data().write(to: file)

        let recent = makeRecent()
        recent.note(URL(fileURLWithPath: "/tmp/agentpad-definitely-gone-\(UUID().uuidString)"))
        recent.note(file)
        recent.note(liveDir)

        XCTAssertEqual(recent.existing.map(\.path), [liveDir.path],
                       "deleted paths and plain files are display-filtered; the raw list keeps them")
        XCTAssertEqual(recent.paths.count, 3, "existing must not purge — an unmounted volume's projects come back")
    }
}
