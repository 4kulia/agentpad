import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class NativeTabsTests: XCTestCase {
    private func empty(_ persistence: any Persistence = InMemoryPersistence(), drafts: DraftRepository? = nil,
                       peers: @escaping @MainActor () -> [WorkspaceStore] = { [] }) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, initiallyEmpty: true, drafts: drafts, engineFactory: {
            XCTFail("A tool must never allocate a process engine"); return TestEngine()
        }, peerStores: peers)
    }
    private func scope(_ account: String = "me") throws -> OrgKey {
        try OrgKey(server: "https://EXAMPLE.com/", accountID: account, orgID: "org")
    }
    private func routes() throws -> [ToolRoute] {
        let org = try scope(), team = TeamScope.server(org), id = UUID()
        return [.settings, .notifications, .linkFailure, .organization(org), .agent(org, agentID: "agent"),
                .ask(org, agentID: "agent"), .request(team, requestID: "request"), .publishedAgents(team), .teamActivity(team),
                .publication(team, publicationID: "publication"), .publish(team, draftID: id, sourceSessionID: id, conversationID: "c"),
                .forward(sourceSessionID: id, answerSnapshotID: id), .connection, .newChannel(org, teamID: "t", draftID: id),
                .newSSH(draftID: id), .newWorktree(repository: "/tmp", sourceWorkspaceID: id, draftID: id), .workspaceDetails(id),
                .files(canonicalPath: "/tmp"), .closeWorkspaces(intentID: id), .fileOperations(operationID: id),
                .importSession(agentID: "claude", conversationID: "conversation", externalSourceID: "source"),
                .viewer(org, channelID: "channel", messageID: "message", attachmentID: "attachment")]
    }

    func testAllKeysReserveBeforeConcurrentLoadAndSectionIsNotIdentity() async throws {
        let store = empty(); defer { store.terminate() }
        let router = TabRouter(); router.stores = { [store] }
        for route in try routes() {
            var loads = 0
            let first = try XCTUnwrap(router.open(route, from: store, load: { _ in loads += 1; await Task.yield() }))
            let second = Task { @MainActor in router.open(route, from: store, load: { _ in loads += 1 }) }
            let repeated = await second.value
            XCTAssertTrue(first === repeated, "\(route)")
            await Task.yield()
            XCTAssertEqual(loads, 1)
            XCTAssertFalse(first.hasProcess)
            XCTAssertEqual((first.engine as? NativeTabEngine)?.starts, 0)
        }
        let settings = router.open(.settings, from: store, section: .about)
        XCTAssertTrue(settings === router.open(.settings, from: store, section: .updates))
        XCTAssertEqual(settings?.tabState?.navigation.settingsSection, .updates)
        XCTAssertEqual(try scope().server, try OrgKey(server: "https://example.com:443", accountID: "me", orgID: "org").server)
        XCTAssertNotEqual(ToolRoute.ask(try scope(), agentID: "a").key(windowID: store.windowID),
                          ToolRoute.ask(try scope("other"), agentID: "a").key(windowID: store.windowID))
        XCTAssertNotEqual(ToolRoute.request(.local, requestID: "a"), .request(.server(try scope()), requestID: "a"))
    }

    func testSingletonTransferCollisionSplitCwdOwnerAndRekey() throws {
        var stores: [WorkspaceStore] = []
        let a = empty(peers: { stores }), b = empty(peers: { stores }); stores = [a, b]
        defer { stores.forEach { $0.terminate() } }
        let router = TabRouter(); router.stores = { stores }
        let settingsA = try XCTUnwrap(router.open(.settings, from: a))
        let settingsB = try XCTUnwrap(router.open(.settings, from: b))
        XCTAssertFalse(settingsA === settingsB)
        let workspace = try XCTUnwrap(b.active), originalCwd = workspace.workingDirectory
        XCTAssertFalse(b.handleTabDrop(droppedId: settingsA.id, in: workspace))
        XCTAssertTrue(a.allSessions.contains { $0 === settingsA })
        XCTAssertTrue(workspace.activeSession === settingsB)
        let source = try XCTUnwrap(router.open(.newSSH(draftID: UUID()), from: a))
        let state = try XCTUnwrap(source.tabState)
        state.edit(.ssh(name: "invalid draft", host: "", directory: "relative"))
        state.transient["password"] = "not-persisted"
        let oldRevision = state.revision
        let pane = try XCTUnwrap(workspace.activePane)
        let split = try XCTUnwrap(b.splitPane(pane, orientation: .horizontal, in: workspace))
        workspace.zoomedPaneId = pane.id
        XCTAssertTrue(b.handleTabDrop(droppedId: source.id, to: split, at: 0, in: workspace))
        XCTAssertTrue(source.tabState === state)
        XCTAssertEqual(workspace.workingDirectory, originalCwd)
        XCTAssertNil(workspace.zoomedPaneId)
        XCTAssertFalse(state.accept(revision: oldRevision) { XCTFail("late picker changed a moved draft") })
        XCTAssertTrue((source.engine as? NativeTabEngine)?.owner === b)
        XCTAssertEqual((source.engine as? NativeTabEngine)?.terminations, 0)
        XCTAssertTrue(router.rekey(source.id, to: .workspaceDetails(workspace.id)) === source)
        XCTAssertTrue(router.open(.workspaceDetails(workspace.id), from: a) === source)
    }

    func testSplittingOpeningAndChangingWorkspaceInvalidatePendingDecision() throws {
        for operation in 0..<3 {
            let store = empty(); defer { store.terminate() }
            let tab = store.openToolTab(.settings), coordinator = tab.tabState!.confirmation
            var decisions: [Bool] = []
            XCTAssertTrue(coordinator.request(.init(tabID: tab.id, targetID: "target"), title: "Remove", consequences: "", verb: "Remove",
                stillValid: { true }, completion: { decisions.append($0) }) { XCTFail("navigation accepted consent") })
            switch operation {
            case 0: _ = store.splitPane(store.active!.activePane!, orientation: .horizontal, in: store.active!)
            case 1: _ = store.openToolTab(.notifications)
            default: _ = store.addEmptyWorkspace()
            }
            XCTAssertEqual(coordinator.phase, .invalidated)
            XCTAssertEqual(decisions, [false])
        }
    }

    func testCreateChannelRekeysSameTabAndReusesExistingChannel() throws {
        let store = empty(); defer { store.terminate() }
        let router = TabRouter(); router.stores = { [store] }
        let route = ToolRoute.newChannel(try scope(), teamID: "team", draftID: UUID())
        let tab = try XCTUnwrap(router.open(route, from: store))
        let oldState = try XCTUnwrap(tab.tabState)
        let channel = ChannelRef(server: "https://example.com:443", account: "me", org: "org", channel: "created")
        XCTAssertTrue(router.rekey(tab.id, to: channel) === tab)
        XCTAssertEqual(tab.channel, channel)
        XCTAssertTrue(oldState.isClosed)
        XCTAssertEqual((tab.engine as? ChannelTabEngine)?.starts, 0)
        let second = try XCTUnwrap(router.open(.newChannel(try scope(), teamID: "team", draftID: UUID()), from: store))
        XCTAssertTrue(router.rekey(second.id, to: channel) === tab)
        XCTAssertEqual(store.allSessions.count, 1)
    }

    func testRoundTripMultiWindowEmptySplitSecretsAndRestoreDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state-v2.json")
        let app = AppPersistence(fileURL: url)
        let a = empty(WindowPersistence(windowId: UUID(), app: app)), b = empty(WindowPersistence(windowId: UUID(), app: app))
        defer { a.terminate(); b.terminate() }
        let route = ToolRoute.newSSH(draftID: UUID())
        let tab = a.openToolTab(route)
        let state = try XCTUnwrap(tab.tabState)
        state.edit(.ssh(name: "unfinished", host: "invalid host", directory: "relative"))
        state.navigation.anchor = "field-host"
        for secret in ["OTP-MARKER", "TOKEN-MARKER", "CLIPBOARD-MARKER", "ENV-MARKER", "SIGNED-URL-MARKER"] { state.transient[secret] = secret }
        let workspace = try XCTUnwrap(a.active)
        _ = a.splitPane(try XCTUnwrap(workspace.activePane), orientation: .horizontal, in: workspace)
        _ = b.openToolTab(route) // Simulate duplicate persisted addresses from an older build.
        XCTAssertTrue(a.flushPersistence()); XCTAssertTrue(b.flushPersistence())
        for file in [url, root.appendingPathComponent("tab-drafts-v1.json")] {
            let text = try String(contentsOf: file, encoding: .utf8)
            for marker in state.transient.values { XCTAssertFalse(text.contains(marker)) }
        }
        let loaded = AppPersistence(fileURL: url)
        let restored = loaded.windowIds.map { empty(WindowPersistence(windowId: $0, app: loaded)) }
        defer { restored.forEach { $0.terminate() } }
        let router = TabRouter(); router.stores = { restored }; router.reconcileRestoredTabs()
        XCTAssertEqual(restored.flatMap(\.allSessions).count, 1)
        XCTAssertEqual(restored[0].active?.root.allPanes.count, 2)
        let restoredState = try XCTUnwrap(restored[0].allSessions.first?.tabState)
        XCTAssertEqual(restoredState.draft?.payload, state.draft?.payload)
        XCTAssertEqual(restoredState.navigation.anchor, "field-host")
        XCTAssertTrue(restoredState.transient.isEmpty)
    }

    func testLegacyImportIsOneTimeAndCorruptOrUnknownTabsNeverSpawnShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("state.json"), v2 = root.appendingPathComponent("state-v2.json")
        let seed = empty(); defer { seed.terminate() }
        let memory = InMemoryPersistence(); let source = empty(memory); defer { source.terminate() }
        _ = source.openToolTab(.settings); XCTAssertTrue(source.flushPersistence())
        let old = try JSONEncoder().encode(PersistedApp(windows: [PersistedWindow(id: UUID(), state: XCTUnwrap(memory.saved))]))
        try old.write(to: legacy)
        let migrated = AppPersistence(fileURL: v2)
        XCTAssertEqual(migrated.windowIds.count, 1)
        XCTAssertEqual(try Data(contentsOf: legacy), old)
        try Data("broken".utf8).write(to: v2)
        let corrupt = AppPersistence(fileURL: v2)
        XCTAssertNotNil(corrupt.lastError)
        let restored = empty(WindowPersistence(windowId: corrupt.windowIds[0], app: corrupt)); defer { restored.terminate() }
        XCTAssertEqual(restored.allSessions.count, 1)
        XCTAssertFalse(restored.allSessions[0].hasProcess)
        let json = """
        [{"id":"\(UUID())","agentId":"terminal","currentDirectoryPath":"/tmp","content":{"futureEditor":{"token":"SECRET"}}},42]
        """
        let tabs = try JSONDecoder().decode([PersistedTab].self, from: Data(json.utf8))
        XCTAssertEqual(tabs.count, 2)
        for tab in tabs { guard case .tool(.unavailable) = tab.content else { return XCTFail("unsafe recovery") } }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tabs), as: UTF8.self).contains("SECRET"))
    }

    func testCorruptStateIsBackedUpAndAllowsWindowAndQuitSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state-v2.json"), damaged = Data("{broken state".utf8)
        try damaged.write(to: url)
        let app = AppPersistence(fileURL: url)
        XCTAssertNotNil(app.lastError)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state-v2.json.corrupt-") }
        XCTAssertEqual(backups.count, 1, "preserve the damaged file at startup before saving a new layout")
        for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), damaged) }

        let store = empty(WindowPersistence(windowId: try XCTUnwrap(app.windowIds.first), app: app))
        defer { store.terminate() }
        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.allSessions.first).hasProcess)
        // Both window close and Cmd-Q use this save gate.
        XCTAssertTrue(store.tabCloseCoordinator.prepare(store.allSessions) && store.flushPersistence())
        XCTAssertNil(store.persistenceError)
        XCTAssertNil(app.lastError)
        let restored = AppPersistence(fileURL: url)
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.state(for: store.windowID), app.state(for: store.windowID))
        for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), damaged) }
    }

    func testDraftFailureBlocksRepeatedCloseAndStaleWriteKeepsConflict() throws {
        var failing = true
        let repository = DraftRepository(fileURL: URL(fileURLWithPath: "/unused"), write: { _, _ in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let store = empty(drafts: repository); defer { store.terminate() }
        let tab = store.openToolTab(.newSSH(draftID: UUID())), workspace = try XCTUnwrap(store.active)
        let state = try XCTUnwrap(tab.tabState)
        state.edit(.ssh(name: "", host: "broken input", directory: "not absolute"))
        let stale = try XCTUnwrap(state.draft)
        store.closeTab(tab, in: workspace); store.closeTab(tab, in: workspace)
        XCTAssertTrue(store.allSessions.contains { $0 === tab }); XCTAssertNotNil(state.saveError)
        state.edit(.ssh(name: "new", host: "still broken", directory: ""))
        failing = false
        store.tabCloseCoordinator.retry(tab.id)
        XCTAssertFalse(store.allSessions.contains { $0 === tab })
        XCTAssertEqual(repository.draft(stale.id)?.revision, 2)
        XCTAssertThrowsError(try repository.save(stale))
        XCTAssertEqual(repository.conflicts, [stale])
        XCTAssertEqual(repository.draft(stale.id)?.revision, 2)
        // Re-entering the action works without the runtime closed-tab stack.
        let reopened = store.openToolTab(stale.route)
        XCTAssertEqual(reopened.tabState?.draft, repository.draft(stale.id))
    }

    func testTransferWriteFailureKeepsBothLayoutsAndLiveDraft() throws {
        var fail = false, writes = 0
        let app = AppPersistence(fileURL: URL(fileURLWithPath: "/nonexistent-\(UUID())/state-v2.json"), writer: { _, _ in
            writes += 1; if fail { throw CocoaError(.fileWriteOutOfSpace) }
        })
        var stores: [WorkspaceStore] = []
        let a = empty(WindowPersistence(windowId: UUID(), app: app), peers: { stores })
        let b = empty(WindowPersistence(windowId: UUID(), app: app), peers: { stores }); stores = [a, b]
        defer { stores.forEach { $0.terminate() } }
        let tab = a.openToolTab(.settings)
        XCTAssertTrue(a.flushPersistence()); XCTAssertTrue(b.flushPersistence())
        let savedA = app.state(for: a.windowID), savedB = app.state(for: b.windowID)
        let before = writes; fail = true
        XCTAssertFalse(b.handleTabDrop(droppedId: tab.id, in: try XCTUnwrap(b.active)))
        XCTAssertEqual(writes, before + 1)
        XCTAssertEqual(app.state(for: a.windowID), savedA); XCTAssertEqual(app.state(for: b.windowID), savedB)
        XCTAssertTrue(a.allSessions.first === tab); XCTAssertTrue(b.allSessions.isEmpty)
        XCTAssertEqual((tab.engine as? NativeTabEngine)?.terminations, 0)
    }
}
