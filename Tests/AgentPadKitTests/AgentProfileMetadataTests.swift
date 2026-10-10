import XCTest
@testable import AgentPadKit

@MainActor
final class AgentProfileMetadataTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var profile: AgentProfile!
    private var file: URL { root.appendingPathComponent("agent-profiles.json") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-profiles-1.1.15.json")
        try FileManager.default.copyItem(at: fixture, to: file)
        profiles = AgentProfileStore(fileURL: file, canonicalize: { $0 })
        profile = try XCTUnwrap(profiles.profiles.first)
    }
    override func tearDown() async throws {
        try profiles.flush()
        try FileManager.default.removeItem(at: root)
    }
    private func record(_ id: String, title: String, activity: Date, scan: Date) -> AgentSessionRecord {
        AgentSessionRecord(agentId: "claude-code", conversationId: id, title: title, cwd: profile.folder,
            lastActivity: activity, aiTitle: title, scannedAt: scan)
    }
    private func catalog(_ records: [AgentSessionRecord]) async throws -> SessionCatalog {
        let catalog = SessionCatalog { _ in .init(records: records, scanned: records.count, total: records.count, skipped: 0) }
        catalog.refresh()
        for _ in 0..<100 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(catalog.isScanning)
        return catalog
    }
    private func items(_ catalog: SessionCatalog, sessions: [Session] = []) -> [AgentProfileSessionItem] {
        AgentProfileSessions.items(profile: profile, profiles: profiles, sessions: sessions, catalog: catalog, visibility: .init(channelIds: []))
    }

    func testLoadingAndDisplayingLegacyBindingsNeverRepairsOrWritesArchive() async throws {
        let original = try Data(contentsOf: file), saved = profiles.bindings
        let catalog = try await catalog([])
        XCTAssertEqual(profiles.binding(agentID: "claude-code", conversationID: "legacy")?.record.title, "csm_agent")
        XCTAssertEqual(profiles.binding(agentID: "claude-code", conversationID: "legacy")?.record.lastActivity,
            Date(timeIntervalSinceReferenceDate: 813328260.968203))
        XCTAssertEqual(items(catalog).first { $0.record?.conversationId == "legacy" }?.title, "Claude Code")
        _ = AllSessionsList.filter(records: [], live: [], names: [:], query: "", filters: .init(), bindings: saved.map(\.record))
        _ = EverywhereSearchModel.metadataMatches(records: [], names: [:], query: "csm_agent", filter: .init(), bindings: saved.map(\.record))
        try profiles.flush()
        XCTAssertEqual(profiles.bindings, saved)
        XCTAssertEqual(try Data(contentsOf: file), original)
        // An unrelated later save must preserve the original values as well.
        try profiles.rename(profile.id, to: "Renamed profile")
        let reloaded = AgentProfileStore(fileURL: file)
        XCTAssertEqual(Set(reloaded.bindings.map(\.record)), Set(saved.map(\.record)))
    }

    func testFolderNamedScannedBindingKeepsActivityAcrossReloadAndDisplay() async throws {
        var found = record("folder-title", title: "csm_agent", activity: Date(timeIntervalSince1970: 1_700_000_000), scan: .now)
        found.scannedAt = nil // Older scanned archives have a file URL, not the new marker.
        found.agentTitle = "csm_agent"
        found.fileURL = root.appendingPathComponent("folder-title.jsonl")
        found.startedAt = found.lastActivity.addingTimeInterval(-60)
        try profiles.bind(found, to: profile.id)
        profiles = AgentProfileStore(fileURL: file)
        let before = try Data(contentsOf: file), catalog = try await catalog([])
        let item = try XCTUnwrap(items(catalog).first { $0.record?.conversationId == found.conversationId })
        XCTAssertEqual(item.title, "Claude Code")
        XCTAssertEqual(item.lastActivity, found.lastActivity)
        try profiles.flush()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(profiles.binding(agentID: found.agentId, conversationID: found.conversationId)?.record, found)
    }

    func testNewBoundLiveSessionUsesStartAndSortsIntoFirstFive() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<6 {
            try profiles.bind(record("old-\(index)", title: "Earlier work", activity: old, scan: old), to: profile.id)
        }
        let session = Session(engine: TestEngine(), currentDirectory: profile.folder, agent: .claudeCode, conversationId: "new")
        session.profileID = profile.id
        try profiles.bind(.init(agentId: "claude-code", conversationId: "new", title: "", cwd: profile.folder, lastActivity: .distantPast), to: profile.id)
        let catalog = try await catalog([]), rows = items(catalog, sessions: [session])
        XCTAssertTrue(rows.first?.session === session)
        XCTAssertEqual(rows.first?.lastActivity, session.catalogStartedAt)
        XCTAssertTrue(AgentProfileSessions.page(rows, limit: 5).contains { $0.session === session })
        let live = AllSessionItem(id: session.id.uuidString, record: profiles.binding(agentID: "claude-code", conversationID: "new")!.record,
            source: .own(session.id), status: .working, title: "", liveMetadata: .init(session: session))
        let all = AllSessionsList.filter(records: [], live: [live], names: [:], query: "", filters: .init(period: .today))
        XCTAssertEqual(all.items.first?.record.lastActivity, session.catalogStartedAt)
    }

    func testWorkingTodaySurvivesYesterdayCatalogAndRestoringAloneDoesNotChangeActivity() async throws {
        let today = Date(), yesterday = today.addingTimeInterval(-86_400)
        let found = record("legacy", title: "Customer follow-up", activity: yesterday, scan: yesterday)
        let catalog = try await catalog([found])
        let session = Session(engine: TestEngine(), currentDirectory: profile.folder, agent: .claudeCode, conversationId: "legacy")
        session.profileID = profile.id
        session.terminalTitle = "csm_agent"
        XCTAssertEqual(items(catalog, sessions: [session]).first { $0.session === session }?.lastActivity, yesterday)
        session.hookStateAt = today
        let live = AllSessionItem(id: session.id.uuidString, record: found, source: .own(session.id), status: .working,
            title: "csm_agent", liveMetadata: .init(session: session))
        let all = AllSessionsList.filter(records: [found], live: [live], names: [:], query: "", filters: .init(period: .today), now: today)
        XCTAssertEqual(all.shown, 1)
        XCTAssertEqual(all.items.first?.status, .working)
        XCTAssertEqual(all.items.first?.record.lastActivity, today)
        XCTAssertEqual(all.items.first?.title, "Customer follow-up")
        let row = try XCTUnwrap(items(catalog, sessions: [session]).first { $0.session === session })
        XCTAssertEqual(row.title, all.items.first?.title)
        XCTAssertEqual(row.lastActivity, today)
        let hits = EverywhereSearchModel.metadataMatches(records: [found], names: [:], query: "follow-up", filter: .init(), live: [live])
        XCTAssertEqual(hits.first?.lastActivity, today)
        XCTAssertEqual(hits.first?.title, row.title)
    }

    func testFresherBindingSupersedesStaleCatalogInEveryList() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000), fresh = old.addingTimeInterval(300)
        let stale = record("legacy", title: "Old name", activity: old, scan: old)
        let found = record("legacy", title: "Fresh title", activity: fresh, scan: fresh)
        let catalog = try await catalog([stale])
        try profiles.discover([found])
        let row = try XCTUnwrap(items(catalog).first { $0.record?.conversationId == "legacy" })
        XCTAssertEqual(row.title, found.title)
        XCTAssertEqual(row.lastActivity, fresh)
        let all = AllSessionsList.filter(records: catalog.records, live: [], names: [:], query: "Fresh", filters: .init(), bindings: profiles.records(for: profile.id))
        XCTAssertEqual(all.items.first?.title, row.title)
        XCTAssertEqual(all.items.first?.record.lastActivity, fresh)
        let hits = EverywhereSearchModel.metadataMatches(records: catalog.records, names: [:], query: "Fresh", filter: .init(), bindings: profiles.records(for: profile.id))
        XCTAssertEqual(hits.first?.title, row.title)
        XCTAssertEqual(hits.first?.lastActivity, fresh)
        try profiles.discover([stale])
        XCTAssertEqual(profiles.binding(agentID: "claude-code", conversationID: "legacy")?.record, found, "Late older scans must not overwrite fresh discovery")
    }

    func testRenameToFolderNameDisplaysInEveryList() async throws {
        let found = record("legacy", title: "Scanned AI title", activity: .now, scan: .now)
        let catalog = try await catalog([found])
        let session = Session(engine: TestEngine(), currentDirectory: profile.folder, agent: .claudeCode, conversationId: "legacy")
        session.profileID = profile.id
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: profiles, engineFactory: { TestEngine() })
        defer { store.terminate() }
        store.renameTab(session, to: "csm_agent")
        XCTAssertEqual(session.customTitle, "csm_agent")
        XCTAssertEqual(items(catalog, sessions: [session]).first { $0.session === session }?.title, "csm_agent")
        let live = AllSessionItem(id: session.id.uuidString, record: found, source: .own(session.id), status: .idle,
            title: session.title, liveMetadata: .init(session: session))
        let all = AllSessionsList.filter(records: [found], live: [live], names: [:], query: "", filters: .init())
        XCTAssertEqual(all.items.first?.title, "csm_agent")
        let hits = EverywhereSearchModel.metadataMatches(records: [found], names: [:], query: "csm_agent", filter: .init(), live: [live])
        XCTAssertEqual(hits.first?.title, "csm_agent")
    }

    func testNewerIncompleteScansPreserveSavedTextAcrossReload() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var expected = AgentSessionRecord(agentId: "claude-code", conversationId: "partial-scan", title: "Saved title", cwd: profile.folder,
            lastActivity: old, agentTitle: "Saved agent title", summary: "Saved summary", firstPrompt: "Saved prompt",
            customTitle: "Saved custom title", aiTitle: "Saved AI title", scannedAt: old)
        try profiles.bind(expected, to: profile.id)
        let emptyValues: [String?] = [nil, "", " \n"]
        for (index, empty) in emptyValues.enumerated() {
            let fresh = old.addingTimeInterval(Double(index + 1))
            let incomplete = AgentSessionRecord(agentId: expected.agentId, conversationId: expected.conversationId,
                title: empty ?? "", cwd: URL(fileURLWithPath: "/moved/transcript"), lastActivity: fresh,
                agentTitle: empty, summary: empty, firstPrompt: empty, customTitle: empty, aiTitle: empty, scannedAt: fresh)
            try profiles.discover([incomplete])
            expected.lastActivity = fresh; expected.scannedAt = fresh
            XCTAssertEqual(profiles.binding(agentID: expected.agentId, conversationID: expected.conversationId)?.record, expected)
            try profiles.flush()
            profiles = AgentProfileStore(fileURL: file, canonicalize: { $0 })
            let binding = try XCTUnwrap(profiles.binding(agentID: expected.agentId, conversationID: expected.conversationId))
            XCTAssertEqual(binding.profileID, profile.id)
            XCTAssertEqual(binding.record, expected)
        }

        let fresh = old.addingTimeInterval(10)
        let partial = AgentSessionRecord(agentId: expected.agentId, conversationId: expected.conversationId,
            title: "New title", cwd: expected.cwd, lastActivity: fresh,
            agentTitle: "New agent title", summary: "", firstPrompt: "New prompt", customTitle: nil, aiTitle: "New AI title", scannedAt: fresh)
        try profiles.discover([partial])
        expected.title = partial.title; expected.agentTitle = partial.agentTitle
        expected.firstPrompt = partial.firstPrompt; expected.aiTitle = partial.aiTitle
        expected.lastActivity = fresh; expected.scannedAt = fresh
        XCTAssertEqual(profiles.binding(agentID: expected.agentId, conversationID: expected.conversationId)?.record, expected)

        var complete = expected
        complete.customTitle = "New custom title"; complete.summary = "New summary"
        complete.scannedAt = fresh.addingTimeInterval(1)
        try profiles.discover([complete])
        try profiles.flush()
        profiles = AgentProfileStore(fileURL: file, canonicalize: { $0 })
        XCTAssertEqual(profiles.binding(agentID: expected.agentId, conversationID: expected.conversationId)?.record, complete)
    }

    func testCommandPSearchKeepsOneResultPerConversationWithMultipleLiveProcesses() {
        let found = record("legacy", title: "Customer follow-up", activity: .now, scan: .now)
        let first = AllSessionItem(id: "first", record: found, source: .own(UUID()), status: .working, title: found.title,
            liveMetadata: .init(hookStateAt: found.lastActivity))
        var second = first; second.id = "second"
        second.liveMetadata?.hookStateAt = found.lastActivity.addingTimeInterval(60)
        let hits = EverywhereSearchModel.metadataMatches(records: [found], names: [:], query: "follow-up", filter: .init(), live: [first, second])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.lastActivity, second.liveMetadata?.hookStateAt)
    }

    func testDiscoveryBeforeBindingPreservesMetadataAndOriginalFolder() throws {
        let found = record("discovered-first", title: "Known conversation", activity: .now, scan: .now)
        try profiles.discover([found])
        let cwd = URL(fileURLWithPath: "/original/folder")
        try profiles.bind(.init(agentId: found.agentId, conversationId: found.conversationId, title: "", cwd: cwd, lastActivity: .distantPast), to: profile.id, deferred: true)
        XCTAssertEqual(profiles.binding(agentID: found.agentId, conversationID: found.conversationId)?.record, found.inDirectory(cwd))
    }

    func testFourReviewedOwnerBindingsResolveRealTitlesInEveryList() async throws {
        let fixtures: [(String, String, String)] = [
            ("58cf7745", "Google Ads gclid сохранение и атрибуция", "Нужно сохранить gclid"),
            ("a21ca6c8", "Стенд на вебсаммит 10 ноября", "Подготовь стенд"),
            ("b9c3e8b8", "Статистика кликов GA4 по ассистентам", "можешь посмотрреть статистику"),
            ("9a657254", "Тикет из скриншота в Linear", "<pasted_content>Screenshot</pasted_content>")
        ]
        let transcriptRoot = root.appendingPathComponent("claude"), cwd = profile.folder.path
        let activity = Date(timeIntervalSince1970: 1_791_504_000)
        for (prefix, title, prompt) in fixtures {
            let id = prefix + "-0000-4000-8000-000000000000"
            var user = "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"timestamp\":\"2026-10-09T12:00:00Z\",\"message\":{\"content\":\"\(prompt)\"}}"
            if prefix == "9a657254" {
                // The first user line ends at byte 634,040, matching the review.
                user = user.replacingOccurrences(of: "Screenshot", with: String(repeating: "x", count: 634_039 - user.utf8.count + "Screenshot".utf8.count))
                XCTAssertEqual(user.utf8.count + 1, 634_040)
            }
            var lines = [user]
            if prefix == "b9c3e8b8" {
                lines += ["{\"type\":\"assistant\",\"message\":{\"content\":\"" + String(repeating: "x", count: 300_000) + "\"}}"]
            }
            lines += ["{\"type\":\"ai-title\",\"aiTitle\":\"Old title\"}", "{\"type\":\"ai-title\",\"aiTitle\":\"\(title)\"}"]
            try SessionStoreFixtures.writeFile(id + ".jsonl", in: transcriptRoot.appendingPathComponent("project"), lines: lines, mtime: activity)
            // A pre-fix adoption snapshot with a folder label and fake activity.
            try profiles.bind(.init(agentId: "claude-code", conversationId: id, title: "csm_agent", cwd: profile.folder, lastActivity: .distantFuture), to: profile.id)
        }
        let cache = root.appendingPathComponent("headers.json"), reads = CatalogCounter()
        let scan = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return SessionCatalogScanner.scan(roots: ["claude-code": transcriptRoot], cacheURL: cache,
                visibility: .init(channelIds: []), onRead: { _ in reads.increment() })
        }.value
        XCTAssertEqual(scan.records.count, 4)
        let catalog = try await catalog(scan.records), before = try Data(contentsOf: file)
        for (prefix, expected, _) in fixtures {
            let row = try XCTUnwrap(items(catalog).first { $0.record?.conversationId.hasPrefix(prefix) == true })
            XCTAssertEqual(row.title, expected)
            XCTAssertEqual(row.lastActivity, activity)
            let all = AllSessionsList.filter(records: scan.records, live: [], names: [:], query: expected, filters: .init(), bindings: profiles.records(for: profile.id))
            XCTAssertEqual(all.items.first?.title, expected)
            let hits = EverywhereSearchModel.metadataMatches(records: scan.records, names: [:], query: expected, filter: .init(), bindings: profiles.records(for: profile.id))
            XCTAssertEqual(hits.first?.title, expected)
        }
        try profiles.flush()
        XCTAssertEqual(try Data(contentsOf: file), before, "Display resolution must never write metadata back")
        _ = await Task.detached {
            SessionCatalogScanner.scan(roots: ["claude-code": transcriptRoot], cacheURL: cache,
                visibility: .init(channelIds: []), onRead: { _ in reads.increment() })
        }.value
        XCTAssertEqual(reads.count, 4, "Unchanged transcripts still use the header cache")
    }
}
