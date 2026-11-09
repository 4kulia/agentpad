import XCTest
@testable import AgentPadKit

@MainActor
final class PopupRecoveryTests: XCTestCase {
    private func operation(mode: FileOperations.PasteMode = .copy) -> (ToolRoute, FileTransferSnapshot) {
        let source = URL(fileURLWithPath: "/fictional/popup-recovery/source")
        let destination = URL(fileURLWithPath: "/fictional/popup-recovery/destination")
        let readme = source.appendingPathComponent("README.md")
        let config = source.appendingPathComponent("config.json")
        let notes = source.appendingPathComponent("notes.md")
        let snapshot = FileTransferSnapshot(sources: [readme, config, notes], directory: destination, mode: mode,
            result: .init(done: [destination.appendingPathComponent("README.md")], doneSources: [readme],
                skipped: [config], issues: [.init(url: notes, message: "Copy interrupted")]))
        return (.fileOperations(operationID: UUID()), snapshot)
    }

    private func store(_ persistence: InMemoryPersistence) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, initiallyEmpty: true, engineFactory: {
            XCTFail("Restoring file operations must not start a terminal"); return TestEngine()
        })
    }

    private func saved(_ route: ToolRoute, _ snapshot: FileTransferSnapshot) -> PersistedState {
        var tab = PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: snapshot.directory.path)
        tab.content = .tool(route)
        tab.navigation = TabNavigation(fileTransfer: snapshot)
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let workspace = PersistedWorkspace(id: UUID(), workingDirectoryPath: snapshot.directory.path,
            root: PersistedPaneNode(id: pane.id, kind: .pane(pane)), activePaneId: pane.id)
        return PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id,
            agentTabRepair119Applied: true)
    }

    func testLegacyFileOperationReopensAsPopupWithCompleteRecoveryState() async throws {
        let (route, snapshot) = operation()
        let owner = store(InMemoryPersistence(initial: saved(route, snapshot)))
        defer { owner.terminate() }

        XCTAssertEqual(route.presentation, .popup, "popups.html Inventory classifies File operations as Popup")
        XCTAssertTrue(owner.allSessions.isEmpty)
        let popup = try XCTUnwrap(owner.popups.sessions.first)
        XCTAssertEqual(owner.popups.sessions.map(\.toolRoute), [route])
        guard case .tool(let visible) = owner.popups.page else { return XCTFail("Recovery must reopen its popup") }
        XCTAssertTrue(visible === popup)
        XCTAssertFalse(owner.popups.canGoBack, "Restoring an operation is a direct popup entry")
        let state = try XCTUnwrap(popup.tabState)
        XCTAssertTrue(state.isPopup)
        XCTAssertEqual(state.navigation, TabNavigation(fileTransfer: snapshot))
        let batch = try XCTUnwrap(state.fileOperation)
        XCTAssertEqual(batch.snapshot, snapshot)
        XCTAssertTrue(batch.interrupted)
        XCTAssertFalse(batch.running)
        let result = await batch.start()
        XCTAssertEqual(result, snapshot.result, "Recovery must wait for Review and continue")
        XCTAssertEqual(batch.snapshot, snapshot)
    }

    func testDismissedOperationRecoverySurvivesSaveAndRelaunch() throws {
        let (route, snapshot) = operation()
        let memory = InMemoryPersistence()
        let owner = store(memory)
        defer { owner.terminate() }
        let popup = owner.openToolTab(route, navigation: TabNavigation(fileTransfer: snapshot))
        let state = try XCTUnwrap(popup.tabState)
        state.fileOperation = FileTransferBatch(snapshot, state: state, tabID: popup.id, restored: true)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertTrue(owner.allSessions.isEmpty)
        XCTAssertTrue(owner.flushPersistence())

        let reloaded = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
        defer { reloaded.terminate() }
        XCTAssertTrue(reloaded.allSessions.isEmpty)
        XCTAssertEqual(reloaded.popups.sessions.map(\.toolRoute), [route])
        XCTAssertEqual(reloaded.popups.sessions.first?.tabState?.navigation, TabNavigation(fileTransfer: snapshot))
        XCTAssertEqual(reloaded.popups.sessions.first?.tabState?.fileOperation?.snapshot, snapshot)
        XCTAssertTrue(reloaded.popups.isPresented)
    }

    func testTerminateThenFlushKeepsOperationRecoveryUntilExplicitCompletion() throws {
        let (route, snapshot) = operation()
        let memory = InMemoryPersistence()
        let owner = store(memory)
        let popup = owner.openToolTab(route, navigation: TabNavigation(fileTransfer: snapshot))
        let state = try XCTUnwrap(popup.tabState)
        state.fileOperation = FileTransferBatch(snapshot, state: state, tabID: popup.id, restored: true)
        owner.terminate()
        XCTAssertTrue(owner.flushPersistence())

        let restoredMemory = InMemoryPersistence(initial: try XCTUnwrap(memory.saved))
        let reloaded = store(restoredMemory)
        defer { reloaded.terminate() }
        let recovered = try XCTUnwrap(reloaded.popups.sessions.first)
        XCTAssertEqual(recovered.toolRoute, route)
        XCTAssertEqual(recovered.tabState?.navigation.fileTransfer, snapshot)
        reloaded.popups.dismiss(recovered, reason: .applied)
        XCTAssertTrue(reloaded.flushPersistence())
        let completed = store(InMemoryPersistence(initial: try XCTUnwrap(restoredMemory.saved)))
        defer { completed.terminate() }
        XCTAssertTrue(completed.allSessions.isEmpty)
        XCTAssertTrue(completed.popups.sessions.isEmpty)
        XCTAssertFalse(completed.popups.isPresented)
    }

    func testInterruptedCopySurvivesClosingFinalTerminalAndWindow() throws {
        try checkFinalTerminalRecovery(mode: .copy)
    }

    func testInterruptedMoveSurvivesClosingFinalTerminalAndWindow() throws {
        try checkFinalTerminalRecovery(mode: .move)
    }

    private func checkFinalTerminalRecovery(mode: FileOperations.PasteMode) throws {
        let (route, snapshot) = operation(mode: mode)
        var initial = saved(route, snapshot)
        guard case .pane(var pane) = initial.workspaces[0].root.kind else { return XCTFail("Expected one pane") }
        let terminal = PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: homeDirectoryPath)
        pane.tabs.append(terminal)
        pane.activeTabId = terminal.id
        initial.workspaces[0].root.kind = .pane(pane)
        let memory = InMemoryPersistence(initial: initial)
        let owner = WorkspaceStore(persistence: memory, engineFactory: { TestEngine() })
        defer { owner.terminate() }
        let workspace = try XCTUnwrap(owner.active)
        XCTAssertNil(workspace.worktreeParentId)
        XCTAssertEqual(owner.allSessions.map(\.id), [terminal.id])
        XCTAssertEqual(owner.popups.sessions.first?.tabState?.fileOperation?.snapshot, snapshot)
        owner.popups.dismiss(reason: .dismiss)

        var windowClosed = false
        owner.onBecameEmpty = {
            windowClosed = true
            XCTAssertTrue(owner.workspaces.isEmpty)
            // The last window's will-close handler flushes, then terminates.
            XCTAssertTrue(owner.flushPersistence())
            owner.terminate()
        }
        owner.closeTab(try XCTUnwrap(owner.allSessions.first), in: workspace)
        XCTAssertTrue(windowClosed)
        XCTAssertTrue(owner.isTerminated)
        XCTAssertTrue(owner.flushPersistence(), "The quit drain must preserve the same recovery")

        let reloaded = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
        defer { reloaded.terminate() }
        XCTAssertTrue(reloaded.allSessions.isEmpty, "No closed terminal may be resurrected")
        XCTAssertEqual(reloaded.popups.sessions.map(\.toolRoute), [route])
        XCTAssertEqual(reloaded.popups.sessions.first?.tabState?.navigation, TabNavigation(fileTransfer: snapshot))
        XCTAssertEqual(reloaded.popups.sessions.first?.tabState?.fileOperation?.snapshot, snapshot)
        XCTAssertEqual(reloaded.popups.sessions.first?.tabState?.fileOperation?.interrupted, true)
        XCTAssertTrue(reloaded.popups.isPresented)
    }
}
