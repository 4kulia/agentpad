import AppKit
import AgentPadHookKit
import Observation
import XCTest
@testable import AgentPadKit

@MainActor
final class SessionDisplaySurfaceTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceStore!
    private var workspace: Workspace!
    private var session: Session!
    private var shell: Session!
    private var catalog: SessionCatalog!
    private var profiles: AgentProfileStore!
    private var profile: AgentProfile!
    private var names: SessionNames!
    private var monitor: AgentMonitor!
    private var attention: AttentionSidebarModel!
    private var transcript: AgentSessionRecord!
    private var quick: PaletteItem!
    private var scans: CatalogCounter!
    private let aiTitle = "Investigate customer attribution"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-surfaces-\(UUID())")
        let folder = root.appendingPathComponent("csm_agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try SessionStoreFixtures.writeFile("\(UUID().uuidString.lowercased()).jsonl", in: root, lines: [
            "{\"type\":\"user\",\"cwd\":\"\(folder.path)\",\"message\":{\"content\":\"Find lost conversions\"}}",
            "{\"type\":\"ai-title\",\"aiTitle\":\"\(aiTitle)\"}"
        ])
        transcript = try XCTUnwrap(AgentSessionScanner.readClaudeRecord(file: file, mtime: Date()))
        let record = transcript!, scans = CatalogCounter()
        self.scans = scans
        catalog = SessionCatalog { _ in
            scans.increment()
            return .init(records: [record], scanned: 1, total: 1, skipped: 0)
        }
        catalog.refresh()
        for _ in 0..<200 where catalog.isScanning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(catalog.isScanning)
        // All following display reads must work after the transcript is gone.
        try FileManager.default.removeItem(at: file)
        profiles = AgentProfileStore(canonicalize: { $0 })
        profile = try profiles.add(template: .claudeCode, folder: folder)
        try profiles.bind(.init(agentId: record.agentId, conversationId: record.conversationId,
            title: "csm_agent", cwd: folder, lastActivity: .distantFuture), to: profile.id)
        names = SessionNames(url: root.appendingPathComponent("names.sqlite"))
        store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: profiles, sessionCatalog: catalog, sessionNames: names,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { false },
            conversationVisibility: { .init(channelIds: []) })
        workspace = store.addWorkspace(workingDirectory: folder, template: .claudeCode)
        session = try XCTUnwrap(workspace.activeSession)
        session.conversationId = record.conversationId
        session.profileID = profile.id
        session.profileOriginalCwd = folder
        session.terminalTitle = "csm_agent"
        shell = store.addTab(in: workspace, template: .terminal)
        monitor = AgentMonitor()
        monitor.storesProvider = { [store = store!] in [store] }
        monitor.conversationVisibility = { .init(channelIds: []) }
        let ledger = AttentionLedger()
        ledger.upsert(.init(source: "terminal", object: session.id.uuidString, episode: session.attentionEpisode,
            kind: .input, destination: .terminal(session.id)))
        attention = AttentionSidebarModel(ledger: ledger, storesProvider: { [store = store!] in [store] })
        quick = PaletteItem(id: "tab-\(session.id)", title: "csm_agent", subtitle: "tab in CSM",
            kind: .tab(sessionId: session.id, workspaceId: workspace.id, windowId: store.windowID),
            symbol: "terminal", iconAsset: nil)
    }

    override func tearDown() async throws {
        store?.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    private func assertSurfaces(_ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        func check(_ actual: String?, _ surface: String) {
            XCTAssertEqual(actual, expected, surface, file: file, line: line)
        }
        check(session.title, "Session Info, drag label and close confirmation")
        let entry = try XCTUnwrap(monitor.entries.first { $0.id == session.id })
        check(entry.tabTitle, "Right sessions panel / AgentOverviewRow")
        XCTAssertTrue(entry.hoverText(tag: nil).contains(expected), file: file, line: line)
        // The right panel's capped history must not overwrite Rename or be
        // necessary to find a title for an old live conversation.
        for history in [[], [transcript!]] {
            let row = SessionListModel.items(own: monitor.entries, external: [], history: history,
                visibility: .init(channelIds: []), names: names.values).first
            check(row?.title, "Right sessions list model")
            if case .own(let rowEntry) = row?.kind { check(rowEntry.tabTitle, "Right panel row and accessibility") }
            else { XCTFail("Missing own row", file: file, line: line) }
        }
        let rail = store.workspaceRailEntries(attention: attention)
        check(rail.flatMap(\.tabs).first { $0.id == session.id }?.title, "Expanded rail and accessibility")
        check(WorkspaceRailSearch.matches(rail, query: expected).flatMap(\.tabs).first?.title, "Rail search")
        check(attention.tabTitle(session.id), "Rail preview and accessibility")
        check(attention.tabTitle(session), "Tab bar, hover and accessibility")
        let item = try XCTUnwrap(attention.items.first)
        check(attention.title(for: item), "Needs attention row")
        let indicator = try XCTUnwrap(attention.tabIndicators[session.id])
        XCTAssertTrue(attention.tooltip(indicator).hasPrefix(expected + ":"), file: file, line: line)
        let live = AllSessionsLive.snapshot(monitor: monitor, external: ExternalSessionMonitor())
        check(live.first?.title, "All sessions live model")
        let all = AllSessionsList.filter(records: catalog.records, live: live, names: names.values,
            query: "", filters: .init(), bindings: profiles.bindings.map(\.record))
        check(all.items.first?.title, "All sessions row, preview and accessibility")
        check(store.profileSessionItems(profile).first?.title, "Agent profile session row")
        let readouts = PaletteIndex.readouts([quick], attention: attention)
        check(readouts.first?.title, "Command-P quick match readout")
        check(PaletteIndex.match(query: expected, in: readouts).first?.title, "Command-P matching current title")
        let metadata = EverywhereSearchModel.metadataMatches(records: catalog.records, names: names.values,
            query: expected, filter: .init(), bindings: profiles.bindings.map(\.record), live: live)
        check(metadata.first?.title, "Command-P session metadata matches")
        let menu = NSMenu()
        let filler = DockTabMenuFiller(sessions: [{ [session = session!] in session }]) { title, _ in
            NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        filler.menuNeedsUpdate(menu)
        check(menu.items.first?.title, "Dock tab menu")
        check(DockTabMenuFiller.workspaceTitle(workspace, singleTab: session), "Single agent Dock entry")
        XCTAssertEqual(ChatSessionIdentity.name(ChatSessionIdentity.tab(session, processes: [])),
            session.explicitName ?? "csm_agent", "Public identity never uses the display title", file: file, line: line)
        XCTAssertEqual(shell.title, "csm_agent", "Shell cwd naming stays unchanged", file: file, line: line)
        XCTAssertEqual(rail.flatMap(\.tabs).first { $0.id == shell.id }?.title, "csm_agent", file: file, line: line)
        XCTAssertEqual(scans.count, 1, "Display reads never rescan", file: file, line: line)
    }

    func testTranscriptAITitleAndRenameReachEverySurface() async throws {
        try assertSurfaces(aiTitle)
        try await store.renameTab(session, to: "Shipping attribution fixes")?.value
        try assertSurfaces("Shipping attribution fixes")
        try await store.renameTab(session, to: "csm_agent")?.value
        try assertSurfaces("csm_agent") // An explicit Rename may intentionally equal the folder.
        try await store.renameTab(session, to: "")?.value
        try assertSurfaces(aiTitle)
        try await names.rename("Saved session name", for: transcript.nameKey)
        try assertSurfaces("Saved session name")
    }

    func testTitleUpdatesInvalidateReadersWithoutRebuildingAttention() async throws {
        let builds = attention.projectionBuildCount, projection = attention.projection
        let changes = CatalogCounter()
        withObservationTracking { _ = attention.tabTitle(session) } onChange: { changes.increment() }
        try await store.renameTab(session, to: "Live rename")?.value
        await Task.yield()
        XCTAssertEqual(changes.count, 1)
        try assertSurfaces("Live rename")
        try await store.renameTab(session, to: "")?.value
        var fresh = transcript!
        fresh.aiTitle = "Fresh transcript title"
        fresh.scannedAt = Date().addingTimeInterval(60)
        try profiles.discover([fresh])
        await Task.yield()
        try assertSurfaces("Fresh transcript title")
        catalog.refresh(force: true)
        for _ in 0..<200 where catalog.isScanning { try await Task.sleep(for: .milliseconds(5)) }
        try await names.rename("Name from All sessions", for: transcript.nameKey)
        await Task.yield()
        XCTAssertEqual(attention.tabTitle(session), "Name from All sessions")
        attention.updateProjection()
        XCTAssertEqual(attention.projectionBuildCount, builds)
        XCTAssertEqual(attention.projection, projection)
    }

    func testBindingOnlyUnboundAndResumedConversationsUseSameAccessor() throws {
        let empty = SessionCatalog { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }
        session.displaySources?.catalog = empty
        XCTAssertEqual(session.title, "Claude Code", "Folder placeholder must never name an agent")
        try profiles.discover([transcript])
        XCTAssertEqual(session.title, aiTitle, "Existing binding works before the catalog loads")
        session.displaySources?.profiles = AgentProfileStore(canonicalize: { $0 })
        session.displaySources?.catalog = catalog
        XCTAssertEqual(session.title, aiTitle, "A profile binding is not required")
        session.conversationId = nil
        session.resumedConversationId = transcript.conversationId
        XCTAssertEqual(session.title, aiTitle)
        XCTAssertEqual(monitor.entries.first?.tabTitle, aiTitle)
    }

    func testOpenQuickMatchesFollowTitleChangesWithoutReopening() async throws {
        let index = ConversationIndex(directory: root.appendingPathComponent("search"), roots: [:],
            visibility: { .init(channelIds: []) })
        let search = EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam },
            fetch: { _, _ in XCTFail("No network needed for tab titles"); return .init(hits: [], next: nil) }),
            indexing: .init(index: index), catalog: catalog, names: names, profiles: profiles,
            visibility: { .init(channelIds: []) })
        let original = quick!, builds = CatalogCounter()
        search.quickItems = { builds.increment(); return [original] }
        search.quickReadouts = { [attention = attention!] in PaletteIndex.readouts($0, attention: attention) }
        search.source = .messages
        search.query = aiTitle
        search.begin()
        for _ in 0..<200 where search.quick.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(search.quick.first?.title, aiTitle)
        try await store.renameTab(session, to: "Renamed while searching")?.value
        search.query = "Renamed while searching"
        XCTAssertEqual(search.quick.first?.title, "Renamed while searching")
        XCTAssertTrue(search.quick.first?.subtitle.hasPrefix("tab in CSM") == true)
        XCTAssertEqual(builds.count, 1, "A name update must reuse the open quick index")
        search.dismiss()
    }

    func testNonAgentTabNamesStayUnchanged() {
        shell.terminalTitle = "Remote shell"
        XCTAssertEqual(shell.title, "Remote shell")
        store.renameTab(shell, to: "My shell")
        XCTAssertEqual(shell.title, "My shell")
        XCTAssertEqual(DockTabMenuFiller.workspaceTitle(workspace, singleTab: shell), workspace.title)
        store.renameTab(shell, to: "")
        XCTAssertEqual(shell.title, "Remote shell")
        let settings = store.openToolTab(.settings)
        XCTAssertEqual(settings.title, settings.toolRoute?.title)
        XCTAssertEqual(attention.tabTitle(settings), settings.toolRoute?.title)
        let file = store.openToolTab(.files(canonicalPath: root.appendingPathComponent("notes.md").path))
        XCTAssertEqual(file.title, file.toolRoute?.title)
        XCTAssertEqual(attention.tabTitle(file), file.toolRoute?.title)
    }

    private func cli(_ request: AgentPadCLIRequest, store: WorkspaceStore? = nil) async -> AgentPadCLIResponse {
        let owner = store ?? self.store!
        let controller = AgentPadCLIController(appVersion: "test", windows: {
            [.init(store: owner, isKey: true, reveal: { _, _ in XCTFail("Rename must not steal focus") })]
        }, fallbackWindow: { nil }, activateApp: {}, templates: { [.claudeCode] }, resume: { _, _, _, _, _ in })
        return await withCheckedContinuation { continuation in
            controller.handle(request) { continuation.resume(returning: $0) }
        }
    }

    func testLatestExplicitRenameWinsAcrossAllSessionsTabCLIAndRestore() async throws {
        try await names.rename("A", for: transcript.nameKey)
        try assertSurfaces("A")
        try await store.renameTab(session, to: "B")?.value
        try assertSurfaces("B")
        XCTAssertEqual(names.values[transcript.nameKey], "B")
        let renamed = await cli(.init(verb: .rename, tab: session.id.uuidString, title: "C"))
        XCTAssertTrue(renamed.ok, renamed.error ?? "")
        try assertSurfaces("C")
        try await names.rename("D", for: transcript.nameKey)
        try assertSurfaces("D")
        let listed = await cli(.init(verb: .list))
        XCTAssertEqual(listed.windows?.flatMap(\.workspaces).flatMap(\.tabs).first { $0.id == session.id.uuidString }?.title, "D")
        let restoredNames = SessionNames(url: root.appendingPathComponent("names.sqlite"))
        await restoredNames.load()
        XCTAssertEqual(restoredNames.values[transcript.nameKey], "D")
        session.displaySources?.names = restoredNames
        XCTAssertEqual(session.explicitName, "D")
        XCTAssertEqual(session.title, "D")
    }

    func testRestoredUnboundWindowHasLastTitleBeforeAnyScanAndCannotShareIt() async throws {
        session.profileID = nil; session.profileOriginalCwd = nil; session.launchOrigin = nil
        let snapshot = PersistedTab(session)
        XCTAssertEqual(snapshot.lastDisplayTitle?.key, transcript.nameKey)
        XCTAssertEqual(snapshot.lastDisplayTitle?.title, aiTitle)
        XCTAssertEqual(snapshot.explicitNameKey, transcript.nameKey)
        let disk = try JSONDecoder().decode(PersistedTab.self, from: JSONEncoder().encode(snapshot))
        var saved = PersistedState(workspaces: [PersistedWorkspace(workspace)], activeWorkspaceId: workspace.id)
        saved.agentTabRepair119Applied = true
        let persistence = InMemoryPersistence(initial: try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved)))
        let empty = SessionCatalog { _ in XCTFail("Restore must not scan"); return .init(records: [], scanned: 0, total: 0, skipped: 0) }
        let restored = WorkspaceStore(persistence: persistence, agentProfiles: AgentProfileStore(canonicalize: { $0 }),
            sessionCatalog: empty, sessionNames: names, engineFactory: { TestEngine() }, optionsProvider: { _ in nil },
            resumeProvider: { false }, conversationVisibility: { .init(channelIds: []) })
        defer { restored.terminate() }
        let tab = try XCTUnwrap(restored.allSessions.first { $0.id == disk.id })
        XCTAssertEqual(tab.title, aiTitle)
        XCTAssertEqual(ChatSessionIdentity.name(ChatSessionIdentity.tab(tab, processes: [])), "csm_agent")
        let listed = await cli(.init(verb: .list), store: restored)
        XCTAssertEqual(listed.windows?.flatMap(\.workspaces).flatMap(\.tabs).first { $0.id == tab.id.uuidString }?.title, "csm_agent")
        try await restored.renameTab(tab, to: "Explicit")?.value
        try await restored.renameTab(tab, to: "")?.value
        XCTAssertEqual(tab.title, aiTitle, "Clearing Rename retains the restored automatic title")
        tab.conversationId = "another-conversation"
        XCTAssertNotEqual(tab.title, aiTitle, "A title is scoped to its conversation")
    }

    func testRenameBeforeConversationHookJoinsTheSharedNameStore() async throws {
        session.conversationId = nil
        try await store.renameTab(session, to: "Before hook")?.value
        store.applyConversationId(conversationId: transcript.conversationId, sessionId: session.id)
        for _ in 0..<200 where names.values[transcript.nameKey] != "Before hook" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(names.values[transcript.nameKey], "Before hook")
        try assertSurfaces("Before hook")
        try await names.rename("After hook", for: transcript.nameKey)
        try assertSurfaces("After hook")
    }

    func testRenameAndClearSurviveExitRestartAndStaleSnapshotsWithOneStore() async throws {
        try await names.rename("A", for: transcript.nameKey)
        let beforeRename = PersistedState(workspaces: [PersistedWorkspace(workspace)], activeWorkspaceId: workspace.id)
        try await store.renameTab(session, to: "B")?.value
        store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
        XCTAssertTrue(session.agent.isShell)
        XCTAssertEqual(session.explicitName, "B")
        XCTAssertEqual(session.displayTitle, "B")

        func restart(_ saved: PersistedState) async throws -> WorkspaceStore {
            let database = SessionNames(url: root.appendingPathComponent("names.sqlite"))
            await database.load()
            var saved = saved; saved.agentTabRepair119Applied = true
            let disk = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(saved))
            return WorkspaceStore(persistence: InMemoryPersistence(initial: disk), agentProfiles: profiles,
                sessionCatalog: catalog, sessionNames: database, engineFactory: { TestEngine() },
                optionsProvider: { _ in nil }, resumeProvider: { false }, conversationVisibility: { .init(channelIds: []) })
        }

        let afterExit = PersistedState(workspaces: [PersistedWorkspace(workspace)], activeWorkspaceId: workspace.id)
        let restored = try await restart(afterExit)
        defer { restored.terminate() }
        let tab = try XCTUnwrap(restored.allSessions.first { $0.id == session.id })
        XCTAssertTrue(tab.agent.isShell)
        XCTAssertEqual(tab.explicitNameKey, transcript.nameKey)
        XCTAssertEqual(tab.explicitName, "B")
        // All Sessions still addresses the same row after /exit.
        try await tab.names.rename("C", for: transcript.nameKey)
        XCTAssertEqual(tab.displayTitle, "C")
        try await restored.renameTab(tab, to: "")?.value
        XCTAssertNil(tab.explicitName)
        XCTAssertEqual(tab.displayTitle, aiTitle)
        XCTAssertEqual(tab.publicName, "csm_agent")
        XCTAssertEqual(ChatSessionIdentity.name(ChatSessionIdentity.tab(tab, processes: [])), "csm_agent")

        for snapshot in [beforeRename, afterExit] {
            let reopened = try await restart(snapshot)
            defer { reopened.terminate() }
            let tab = try XCTUnwrap(reopened.allSessions.first { $0.id == session.id })
            XCTAssertNil(tab.explicitName, "An older window snapshot cannot resurrect A, B, or C")
            XCTAssertEqual(tab.displayTitle, aiTitle)
            XCTAssertEqual(tab.publicName, "csm_agent")
        }
    }

    func testUnknownLegacyCustomTitleIsIgnoredInsteadOfMigratedToRename() throws {
        var saved = PersistedState(workspaces: [PersistedWorkspace(workspace)], activeWorkspaceId: workspace.id)
        saved.agentTabRepair119Applied = true
        let legacy = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            .replacingOccurrences(of: "\"agentId\":\"claude-code\"",
                                  with: "\"customTitle\":\"PRIVATE legacy title\",\"agentId\":\"claude-code\"")
        XCTAssertTrue(legacy.contains("PRIVATE legacy title"))
        let disk = try JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        let restored = WorkspaceStore(persistence: InMemoryPersistence(initial: disk), agentProfiles: profiles,
            sessionCatalog: catalog, sessionNames: names, engineFactory: { TestEngine() }, optionsProvider: { _ in nil },
            resumeProvider: { false }, conversationVisibility: { .init(channelIds: []) })
        defer { restored.terminate() }
        let tab = try XCTUnwrap(restored.allSessions.first { $0.id == session.id })
        XCTAssertNil(tab.explicitName)
        XCTAssertEqual(tab.displayTitle, aiTitle)
        XCTAssertEqual(tab.publicName, "csm_agent")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(PersistedTab(tab)), as: UTF8.self).contains("customTitle"))
    }

    func testPublicationDefaultsAndNotificationPayloadsUseOldNameSource() async throws {
        session.terminalTitle = "PRIVATE program title"
        XCTAssertEqual(session.title, aiTitle)
        XCTAssertEqual(TeamSessionPublication.name(conversationID: transcript.conversationId, folder: transcript.cwd, session: session, names: names), "csm_agent")
        XCTAssertEqual(TeamSessionPublication.name(conversationID: transcript.conversationId, folder: transcript.cwd, names: names), "csm_agent")
        let event = try XCTUnwrap(AttentionCoordinator.terminalEvent(session, kind: .attention, workspaceTitle: "Workspace", visibility: .init(channelIds: [])))
        XCTAssertEqual(event.body, "csm_agent · Workspace")
        XCTAssertFalse(event.body.contains(aiTitle))
        let external = ExternalAgentSession(pid: 42, sessionId: transcript.conversationId, kind: "interactive",
            cwd: transcript.cwd, name: nil, status: .waiting(reason: nil), statusSince: nil, startedAt: nil, title: aiTitle)
        XCTAssertEqual(AttentionCoordinator.waitingEvent(external, names: names).title, "csm_agent")
        try await names.rename("Public explicit name", for: transcript.nameKey)
        XCTAssertEqual(TeamSessionPublication.name(conversationID: transcript.conversationId, folder: transcript.cwd, session: session, names: names), "Public explicit name")
        XCTAssertEqual(TeamSessionPublication.name(conversationID: transcript.conversationId, folder: transcript.cwd, names: names), "Public explicit name")
        XCTAssertEqual(AttentionCoordinator.waitingEvent(external, names: names).title, "Public explicit name")
    }

    func testPartialCatalogSnapshotsKeepUnboundTitleAndSearchUntilAtomicSwap() async throws {
        let previous = transcript!, counter = CatalogCounter()
        var changed = previous
        changed.aiTitle = "Completed scan title"; changed.scannedAt = Date().addingTimeInterval(60)
        let fresh = changed
        let obsolete = AgentSessionRecord(agentId: previous.agentId, conversationId: "removed",
            title: "Obsolete", cwd: previous.cwd, lastActivity: previous.lastActivity)
        let emptyGate = DispatchSemaphore(value: 0), partialGate = DispatchSemaphore(value: 0)
        defer { emptyGate.signal(); partialGate.signal() }
        let catalog = SessionCatalog { progress in
            counter.increment()
            if counter.count == 1 { return .init(records: [previous, obsolete], scanned: 2, total: 2, skipped: 0) }
            progress(.init(records: [], scanned: 0, total: 10, skipped: 0))
            _ = emptyGate.wait(timeout: .now() + 10)
            progress(.init(records: [fresh], scanned: 1, total: 10, skipped: 0))
            _ = partialGate.wait(timeout: .now() + 10)
            return .init(records: [fresh], scanned: 10, total: 10, skipped: 0)
        }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(condition(), "Catalog did not reach the expected phase")
        }
        catalog.refresh()
        try await waitFor { !catalog.isScanning }
        let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(canonicalize: { $0 }), sessionCatalog: catalog, sessionNames: names,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { false },
            conversationVisibility: { .init(channelIds: []) })
        defer { owner.terminate() }
        let workspace = owner.addWorkspace(workingDirectory: root, template: .claudeCode)
        let tab = try XCTUnwrap(workspace.activeSession)
        tab.conversationId = previous.conversationId
        let attention = AttentionSidebarModel(ledger: AttentionLedger(), storesProvider: { [owner] })
        let revision = catalog.revision
        catalog.refresh(force: true)
        try await waitFor { catalog.total == 10 }
        for stage in 0..<2 {
            XCTAssertEqual(tab.title, aiTitle)
            XCTAssertEqual(catalog.revision, revision)
            XCTAssertEqual(catalog.records.map(\.nameKey), [previous.nameKey, obsolete.nameKey])
            XCTAssertNotNil(catalog.record(for: obsolete.nameKey))
            XCTAssertEqual(WorkspaceRailSearch.matches(owner.workspaceRailEntries(attention: attention), query: aiTitle).flatMap(\.tabs).first?.title, aiTitle)
            let listed = await cli(.init(verb: .list), store: owner)
            XCTAssertEqual(listed.windows?.flatMap(\.workspaces).flatMap(\.tabs).first { $0.id == tab.id.uuidString }?.title, tab.publicName)
            if stage == 0 { emptyGate.signal(); try await waitFor { catalog.scanned == 1 } }
        }
        partialGate.signal()
        try await waitFor { !catalog.isScanning }
        XCTAssertEqual(tab.title, "Completed scan title")
        XCTAssertEqual(catalog.revision, revision + 1)
        XCTAssertNil(catalog.record(for: obsolete.nameKey), "Completed scans still remove missing records")
    }
}
