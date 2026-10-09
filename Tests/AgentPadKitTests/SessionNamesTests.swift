import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class SessionNamesTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-names-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("session-names.sqlite") }

    func testNamesPersistByToolAndConversationAndEmptyResets() async throws {
        let names = SessionNames(url: url), key = SessionNameKey("claude-code", "conversation")
        await names.load()
        try await names.rename("  My release  ", for: key)
        let next = SessionNames(url: url); await next.load()
        XCTAssertEqual(next.values[key], "My release")
        XCTAssertNil(next.values[SessionNameKey("codex", "conversation")])
        try await next.rename("   \n", for: key)
        let reset = SessionNames(url: url); await reset.load()
        XCTAssertNil(reset.values[key])
    }
    func testOnlyCorruptDatabaseIsArchivedAndNewNamesStillWork() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("not a sqlite database".utf8)
        try original.write(to: url)
        let names = SessionNames(url: url); await names.load()
        XCTAssertTrue(names.problem?.contains("Session names could not be read") == true)
        let broken = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".broken-") }
        XCTAssertEqual(broken.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(broken.first)), original)
        try await names.rename("Recovered work", for: .init("codex", "id"))
        let restored = SessionNames(url: url); await restored.load()
        XCTAssertEqual(restored.values[.init("codex", "id")], "Recovered work")
    }
    private func execute(_ queue: DatabaseQueue, _ sql: String) throws {
        try queue.writeWithoutTransaction { try $0.execute(sql: sql) }
    }
    func testBusyKeepsDatabaseAndLastSnapshotAndRetriesNextAccess() async throws {
        let names = SessionNames(url: url), key = SessionNameKey("codex", "id")
        try await names.rename("Saved", for: key)
        var locking = Configuration(); locking.allowsUnsafeTransactions = true
        let blocker = try DatabaseQueue(path: url.path, configuration: locking)
        try execute(blocker, "BEGIN EXCLUSIVE")
        do { try await names.rename("Must not be shown", for: key); XCTFail("Write should fail while locked") } catch {}
        XCTAssertEqual(names.values[key], "Saved")
        let blockedReader = SessionNames(url: url); await blockedReader.load()
        XCTAssertNotNil(blockedReader.problem)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".broken-") })
        try execute(blocker, "ROLLBACK")
        await names.load(); XCTAssertEqual(names.values[key], "Saved")
        await blockedReader.load(); XCTAssertEqual(blockedReader.values[key], "Saved")
        try await names.rename("After lock", for: key)
        XCTAssertEqual(names.values[key], "After lock")
    }
    func testAccessFailureDoesNotArchiveAnything() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notDirectory = directory.appendingPathComponent("unavailable")
        try Data("keep me".utf8).write(to: notDirectory)
        let names = SessionNames(url: notDirectory.appendingPathComponent("session-names.sqlite"))
        await names.load()
        XCTAssertNotNil(names.problem)
        XCTAssertEqual(try Data(contentsOf: notDirectory), Data("keep me".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("broken") })
    }
    func testTitlePrioritySentenceBoundaryAndUnicodeLimit() {
        let folder = URL(fileURLWithPath: "/work/project")
        XCTAssertEqual(SessionTitle.resolve(manual: "Manual", agentName: "Agent", firstPrompt: "Prompt. Rest", summary: "Summary", folder: folder), "Manual")
        XCTAssertEqual(SessionTitle.resolve(agentName: "Agent", firstPrompt: "Prompt", folder: folder), "Agent")
        XCTAssertEqual(SessionTitle.resolve(firstPrompt: "Первая фраза! Вторая", summary: "Summary", folder: folder), "Первая фраза")
        XCTAssertEqual(SessionTitle.resolve(firstPrompt: "/clear", summary: "Summary", folder: folder), "Summary")
        XCTAssertEqual(SessionTitle.resolve(firstPrompt: "<system>hidden", folder: folder), "Session in project")
        let title = SessionTitle.firstPhrase(String(repeating: "word ", count: 30))
        XCTAssertLessThanOrEqual(title.count, 80); XCTAssertTrue(title.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(SessionTitle.boundedPrompt(String(repeating: "я", count: 3000))!.utf8.count, 2048)
    }
}
