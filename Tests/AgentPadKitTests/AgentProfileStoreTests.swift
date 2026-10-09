import AppKit
import XCTest
@testable import AgentPadKit

final class ProfileArchiveWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var mainThread = false
    private var fails = false
    var count: Int { lock.withLock { writes } }
    var wroteOnMain: Bool { lock.withLock { mainThread } }
    var fail: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }
    func reset() { lock.withLock { writes = 0; mainThread = false } }
    func write(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
            writes += 1; mainThread = mainThread || Thread.isMainThread
            try data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
final class AgentProfileStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }
    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func record(_ id: String, _ cwd: URL, agent: String = "codex", date: Double = 1) -> AgentSessionRecord {
        AgentSessionRecord(agentId: agent, conversationId: id, title: id, cwd: cwd, lastActivity: Date(timeIntervalSince1970: date))
    }

    func testAddOnlyWritesArchiveAndDeduplicatesBaseToolAndCanonicalFolder() throws {
        let project = try folder("project"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let file = root.appendingPathComponent("data/profiles.json")
        let store = AgentProfileStore(fileURL: file)
        let first = try store.add(template: .claudeCode, folder: project, name: "  ", launchOptions: "--model opus")
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "opus", baseAgentId: "claude-code"))
        let duplicate = try store.add(template: custom, folder: alias.appendingPathComponent("."), name: "ignored")
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(try store.add(template: custom, folder: URL(fileURLWithPath: project.path, isDirectory: true)), first)
        XCTAssertEqual(first.name, "project")
        XCTAssertEqual(first.folder, canonicalDiskPath(project))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertNotEqual(try store.add(template: .codex, folder: project).id, first.id)
        XCTAssertNotEqual(try store.add(template: .claudeCode, folder: folder("worktree")).id, first.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
        XCTAssertEqual(AgentProfileStore(fileURL: file).profiles, store.profiles)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["profiles.json"])
    }

    func testBindingsSurviveMoveRestartDisappearingHistoryAndReuseOfOldFolder() throws {
        let old = try folder("old"), new = try folder("new"), sub = try folder("old/sub")
        let file = root.appendingPathComponent("profiles.json"), store = AgentProfileStore(fileURL: file)
        let profile = try store.add(template: .codex, folder: old)
        try store.discover([record("original", old), record("nested", sub)])
        XCTAssertNil(store.binding(agentID: "codex", conversationID: "nested"))
        try store.move(profile.id, to: new)
        let second = try store.add(template: .codex, folder: old)
        try store.discover([record("original", new, date: 4), record("old-new", old, date: 3), record("new", new, date: 2)])
        try store.discover([])
        try store.flush()
        let restored = AgentProfileStore(fileURL: file)
        XCTAssertEqual(restored.profile(profile.id)?.folder, canonicalDiskPath(new))
        XCTAssertEqual(restored.records(for: profile.id).map(\.conversationId), ["original", "new"])
        XCTAssertEqual(restored.binding(agentID: "codex", conversationID: "original")?.record.cwd, canonicalDiskPath(old))
        XCTAssertEqual(restored.records(for: second.id).map(\.conversationId), ["old-new"])
    }

    func testCaseOnlyRenameDeduplicatesPersistedProfileAndRejectsMove() throws {
        try XCTSkipIf(try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != false,
            "Requires a case-insensitive volume")
        let original = try folder("Project"), renamed = root.appendingPathComponent("project")
        let file = root.appendingPathComponent("profiles.json")
        let first = try AgentProfileStore(fileURL: file).add(template: .codex, folder: original)
        let intermediate = root.appendingPathComponent("rename-in-progress")
        try FileManager.default.moveItem(at: original, to: intermediate)
        try FileManager.default.moveItem(at: intermediate, to: renamed)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: renamed)

        let store = AgentProfileStore(fileURL: file)
        let other = try store.add(template: .codex, folder: folder("other"))
        XCTAssertEqual(store.existing(rosterID: "codex", folder: renamed)?.id, first.id)
        XCTAssertThrowsError(try store.move(other.id, to: alias)) { error in
            guard case AgentProfileStore.Problem.duplicate(let duplicate) = error else {
                return XCTFail("Expected a duplicate profile, got \(error)")
            }
            XCTAssertEqual(duplicate.id, first.id)
        }
        XCTAssertEqual(try store.add(template: .codex, folder: alias).id, first.id)
        XCTAssertEqual(store.profiles, [first, other])
    }

    func testDuplicateDetectionUsesVolumeIdentityWhenResolvedPathsKeepTheirCase() throws {
        let upper = canonicalDiskPath(try folder("Project"))
        let lower = upper.deletingLastPathComponent().appendingPathComponent("project")
        let caseSensitive = try XCTUnwrap(upper.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
        if caseSensitive { try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true) }
        // Use the same resolved parent and preserve the folder name's case;
        // duplicate detection must use the filesystem's identity.
        let store = AgentProfileStore(canonicalize: { $0.standardizedFileURL })
        let first = try store.add(template: .codex, folder: upper)
        let second = try store.add(template: .codex, folder: lower)
        if caseSensitive {
            XCTAssertNotEqual(second.id, first.id, "Distinct folders on a case-sensitive volume must remain distinct")
            XCTAssertEqual(store.profiles.count, 2)
        } else {
            XCTAssertEqual(second.id, first.id)
            XCTAssertEqual(store.profiles.count, 1)
        }
    }

    func testQuitWithoutWindowsSynchronouslyFlushesProfileDiscovery() throws {
        let file = root.appendingPathComponent("profiles.json"), profiles = AgentProfileStore(fileURL: file)
        let profile = try profiles.add(template: .codex, folder: root)
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: root.appendingPathComponent("windows.json")), agentProfiles: profiles)
        try profiles.discover([record("during-close", root)])
        defer { try? profiles.flush() }
        XCTAssertTrue(AgentProfileStore(fileURL: file).bindings.isEmpty, "Discovery has not reached its debounce deadline")

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(AgentProfileStore(fileURL: file).records(for: profile.id).map(\.conversationId), ["during-close"])

        // Discovery can finish while native surfaces drain, after the first save.
        try profiles.discover([record("during-drain", root)])
        XCTAssertTrue(delegate.flushTerminationPersistence())
        XCTAssertEqual(Set(AgentProfileStore(fileURL: file).records(for: profile.id).map(\.conversationId)),
            ["during-close", "during-drain"])
    }

    func testQuitWithoutWindowsCancelsOnProfileSaveFailureAndCanRetry() throws {
        let file = root.appendingPathComponent("profiles.json"), probe = ProfileArchiveWriteProbe()
        let profiles = AgentProfileStore(fileURL: file) { try probe.write($0, to: $1) }
        let profile = try profiles.add(template: .codex, folder: root)
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: root.appendingPathComponent("windows.json")), agentProfiles: profiles)
        try profiles.discover([record("pending", root)])
        defer { probe.fail = false; try? profiles.flush() }
        probe.fail = true
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertNotNil(profiles.problem)
        XCTAssertTrue(AgentProfileStore(fileURL: file).bindings.isEmpty)

        probe.fail = false
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertNil(profiles.problem)
        XCTAssertEqual(AgentProfileStore(fileURL: file).records(for: profile.id).map(\.conversationId), ["pending"])
    }

    func testExplicitBindingUsesLaunchOwnershipAndNamespacedConversationIDs() throws {
        let old = try folder("old"), new = try folder("new"), store = AgentProfileStore()
        let codex = try store.add(template: .codex, folder: old)
        let claude = try store.add(template: .claudeCode, folder: old)
        try store.move(codex.id, to: new)
        try store.bind(record("same", old), to: codex.id)
        try store.discover([record("same", old, agent: "claude-code")])
        XCTAssertEqual(store.binding(agentID: "codex", conversationID: "same")?.profileID, codex.id)
        XCTAssertEqual(store.binding(agentID: "claude-code", conversationID: "same")?.profileID, claude.id)
    }

    func testInvalidMovesAndFailedWritesNeverMutatePublishedState() throws {
        let old = try folder("old"), new = try folder("new")
        let probe = ProfileArchiveWriteProbe()
        let store = AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")) { try probe.write($0, to: $1) }
        let a = try store.add(template: .codex, folder: old), b = try store.add(template: .codex, folder: new)
        XCTAssertThrowsError(try store.move(a.id, to: new))
        XCTAssertThrowsError(try store.move(a.id, to: root.appendingPathComponent("missing")))
        probe.fail = true
        XCTAssertThrowsError(try store.add(template: .claudeCode, folder: old))
        XCTAssertThrowsError(try store.bind(record("failed", old), to: a.id))
        XCTAssertEqual(store.profiles, [a, b]); XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertNotNil(store.problem)
    }

    func testCorruptOrFutureArchiveIsPreserved() throws {
        for contents in ["not json", "{\"version\":999,\"profiles\":[],\"bindings\":{}}"] {
            let file = root.appendingPathComponent("profiles.json")
            try Data(contents.utf8).write(to: file)
            let store = AgentProfileStore(fileURL: file)
            XCTAssertThrowsError(try store.add(template: .codex, folder: root))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), contents)
        }
    }

    func testProfileMetadataRoundTripsWithoutChangingLegacyTabs() throws {
        let session = Session(engine: TestEngine(), currentDirectory: root, agent: .codex)
        session.profileID = UUID(); session.profileOriginalCwd = root
        let saved = PersistedTab(session)
        XCTAssertEqual(try JSONDecoder().decode(PersistedTab.self, from: JSONEncoder().encode(saved)), saved)
        let legacy = PersistedTab(id: UUID(), agentId: "codex", currentDirectoryPath: root.path)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.profileID); XCTAssertNil(decoded.profileOriginalCwd)
    }

    func testCatalogDiscoveryDebouncesArchiveWritesOffMainThread() async throws {
        let path = try folder("project"), file = root.appendingPathComponent("profiles.json"), probe = ProfileArchiveWriteProbe()
        let store = AgentProfileStore(fileURL: file) { try probe.write($0, to: $1) }
        let profile = try store.add(template: .codex, folder: path)
        let records = (0..<150).map { record("id-\($0)", path, date: Double($0)) }
        probe.reset()
        let catalog = SessionCatalog(profiles: store) { progress in
            for count in [50, 100, 150] {
                progress(.init(records: Array(records.prefix(count)), scanned: count, total: 150, skipped: 0))
                Thread.sleep(forTimeInterval: 0.01)
            }
            return .init(records: records, scanned: 150, total: 150, skipped: 0)
        }
        catalog.refresh()
        for _ in 0..<100 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(catalog.isScanning)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(probe.count, 1, "Progress batches should coalesce into one archive write")
        XCTAssertFalse(probe.wroteOnMain, "Archive persistence must not run on the UI thread")
        XCTAssertEqual(AgentProfileStore(fileURL: file).records(for: profile.id).count, 150)
        catalog.refresh(force: true)
        for _ in 0..<100 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(probe.count, 1, "Unchanged scans must not rewrite the archive")
    }

    func testUnchangedDiscoveryDoesNotRecanonicalizeSeenPaths() throws {
        let original = try folder("original"), destination = try folder("destination")
        let alias = root.appendingPathComponent("alias"), store = AgentProfileStore()
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let profile = try store.add(template: .codex, folder: destination)
        let found = record("unbound", alias)
        try store.discover([found])
        XCTAssertTrue(store.bindings.isEmpty)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        try store.discover([found])
        XCTAssertTrue(store.bindings.isEmpty, "Repeated progress must not rediscover the same record at a different path")
        try store.discover([record("new-conversation", alias)])
        XCTAssertEqual(store.binding(agentID: "codex", conversationID: "new-conversation")?.profileID, profile.id,
            "A new record must resolve the folder as it exists now")
    }

    func testHistorySeenBeforeProfileCreationAttachesWithoutAnotherScan() throws {
        let path = try folder("project"), store = AgentProfileStore()
        let found = record("earlier", path)
        try store.discover([found])
        XCTAssertTrue(store.bindings.isEmpty)
        let profile = try store.add(template: .codex, folder: path)
        XCTAssertEqual(store.records(for: profile.id).map(\.conversationId), ["earlier"])
        try store.discover([found])
        XCTAssertEqual(store.bindings.count, 1)
    }

    func testDiscoverySaveFailureRetriesAndExplicitCommitKeepsLatestSnapshot() async throws {
        let path = try folder("project"), file = root.appendingPathComponent("profiles.json"), probe = ProfileArchiveWriteProbe()
        let store = AgentProfileStore(fileURL: file) { try probe.write($0, to: $1) }
        let profile = try store.add(template: .codex, folder: path), found = record("history", path)
        probe.fail = true
        try store.discover([found])
        for _ in 0..<100 where store.problem == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.problem)
        XCTAssertEqual(store.records(for: profile.id).count, 1)
        XCTAssertTrue(AgentProfileStore(fileURL: file).bindings.isEmpty)
        probe.fail = false
        try store.discover([found])
        for _ in 0..<100 where store.problem != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.problem)
        XCTAssertEqual(AgentProfileStore(fileURL: file).bindings.count, 1)

        try store.discover([record("newer", path)])
        let second = try store.add(template: .claudeCode, folder: path)
        try await Task.sleep(for: .milliseconds(400))
        let restored = AgentProfileStore(fileURL: file)
        XCTAssertEqual(restored.profiles.map(\.id), [profile.id, second.id])
        XCTAssertEqual(restored.bindings.count, 2, "An explicit commit must include pending discovery")
    }
}
