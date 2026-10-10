import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class NavigationWindowLifecycleTests: XCTestCase {
    private var scope: TeamServiceTestScope!
    override func setUp() async throws { scope = TeamServiceTestScope() }
    override func tearDown() async throws { scope.close(); scope = nil }

    func testDetachCopiesPreferencesBeforePresentationAndTransfersOneLiveEngine() async throws {
        try await checkDetach(failWrite: false)
    }
    func testFailedDetachDiscardsUnshownWindowAndKeepsSourceEngineAndSlot() async throws {
        try await checkDetach(failWrite: true)
    }

    func testFailedKiroDetachPreservesLiveRecordAndSourceMonitor() async throws {
        try await checkDetach(failWrite: true, kiro: true)
    }

    private func checkDetach(failWrite: Bool, kiro: Bool = false) async throws {
        var fails = false
        let app = AppPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            writer: { _, _ in if fails { throw CocoaError(.fileWriteNoPermission) } })
        var stores: [WorkspaceStore] = []
        func makeStore(_ id: UUID, empty: Bool = false) -> WorkspaceStore {
            let store = WorkspaceStore(persistence: WindowPersistence(windowId: id, app: app), initiallyEmpty: empty,
                engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true },
                peerStores: { stores })
            stores.append(store)
            return store
        }
        let sourceID = UUID(), sourceStore = makeStore(sourceID)
        sourceStore.leftNavigation = .init(railVisible: false, panelVisible: true, panelContent: .files)
        sourceStore.sidebarWidth = 381
        sourceStore.chatSidebarPreferences.width = 289
        sourceStore.openWorkspaceList()
        sourceStore.navigationPresentation.query = "not inherited"
        let source = AgentPadWindowController(windowId: sourceID, store: sourceStore)
        var destination: AgentPadWindowController?
        defer {
            source.close(); destination?.close()
            stores.forEach { $0.terminate() }
        }
        let session = kiro ? sourceStore.addTab(in: try XCTUnwrap(sourceStore.active), template: .kiro)
            : try XCTUnwrap(sourceStore.active?.activeSession)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        let repo = kiro ? FileManager.default.temporaryDirectory.appendingPathComponent("rail-rollback-\(UUID())") : nil
        defer { if let repo { try? FileManager.default.removeItem(at: repo) } }
        if let repo {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try XCTUnwrap(GitStatusFetcher.runGit(["-C", repo.path, "init", "-q"], timeout: 10))
            engine.emitPwd(repo.path)
        }
        let subscriptions = sourceStore.gitWatchHubStats.subscriptions
        let record = kiro ? URL(fileURLWithPath: AgentPadShellIntegration.kiroACPRecordPath(for: session.id)) : nil
        if let record { try Data().write(to: record) }
        defer { if let record { try? FileManager.default.removeItem(at: record) } }
        sourceStore.flushPersistence()
        fails = failWrite
        var discarded = false
        let result = NavigationWindowLifecycle.detach(session.id, from: source, makeDestination: { parent in
            let id = UUID(), child = makeStore(id, empty: true)
            child.inheritNavigation(from: parent)
            let controller = AgentPadWindowController(windowId: id, store: child)
            destination = controller
            XCTAssertEqual(child.leftNavigation, parent.leftNavigation)
            XCTAssertEqual(child.sidebarWidth, 381)
            XCTAssertEqual(child.chatSidebarPreferences.width, 289)
            XCTAssertEqual(child.navigationPresentation.query, "")
            XCTAssertEqual(child.navigationPresentation.list, .closed)
            XCTAssertFalse(controller.window?.isVisible == true)
            return controller
        }, discard: { controller in
            discarded = true
            XCTAssertFalse(controller.window?.isVisible == true)
            XCTAssertTrue(controller.store.allSessions.isEmpty)
            XCTAssertEqual(controller.store.gitWatchHubStats.subscriptions, 0, "Rollback must release destination monitors before termination")
            controller.store.terminate(); controller.close()
        })
        XCTAssertEqual(result, !failWrite)
        XCTAssertEqual(discarded, failWrite)
        XCTAssertEqual(engine.terminateCount, 0)
        let target = try XCTUnwrap(destination)
        if failWrite {
            XCTAssertTrue(sourceStore.allSessions.contains { $0 === session })
            XCTAssertEqual(app.windowIds, [sourceID])
            XCTAssertTrue(target.store.isTerminated)
            XCTAssertEqual(sourceStore.gitWatchHubStats.subscriptions, subscriptions)
            if let record {
                XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "Discarding the destination must preserve the live ACP record")
                XCTAssertNil(session.conversationId)
                let handle = try FileHandle(forWritingTo: record)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"id\":1,\"method\":\"session/new\"}\n{\"id\":1,\"result\":{\"sessionId\":\"after-rollback\"}}\n".utf8))
                let deadline = ContinuousClock.now + .seconds(5)
                while session.conversationId == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(session.conversationId, "after-rollback", "The source monitor must still follow this session")
                XCTAssertEqual(engine.terminateCount, 0)
            }
        } else {
            XCTAssertFalse(sourceStore.allSessions.contains { $0 === session })
            XCTAssertTrue(target.store.allSessions.first === session)
            XCTAssertEqual(app.windowIds.count, 2)
            target.store.toggleWorkspaceRail()
            XCTAssertFalse(sourceStore.leftNavigation.railVisible)
        }
    }

    func testLastCloseHidesAndRemoveFailureKeepsWindowAlive() throws {
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let engine = try XCTUnwrap(store.active?.activeSession?.engine as? TestEngine)
        XCTAssertFalse(NavigationWindowLifecycle.shouldClose(controller, lastVisible: false, terminating: false, removeSlot: { false }))
        XCTAssertFalse(controller.hiddenOnClose)
        XCTAssertFalse(controller.persistedSlotRemoved)
        XCTAssertFalse(NavigationWindowLifecycle.shouldClose(controller, lastVisible: true, terminating: false,
            removeSlot: { XCTFail("Last close keeps its slot"); return false }))
        XCTAssertTrue(controller.hiddenOnClose)
        XCTAssertFalse(store.isTerminated)
        XCTAssertEqual(engine.terminateCount, 0)
    }

    func testRealCloseRemovesSlotButQuitRetainsIt() {
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        XCTAssertTrue(NavigationWindowLifecycle.shouldClose(controller, lastVisible: false, terminating: true,
            removeSlot: { XCTFail("Quit keeps its slot"); return false }))
        XCTAssertFalse(controller.persistedSlotRemoved)
        XCTAssertTrue(NavigationWindowLifecycle.shouldClose(controller, lastVisible: false, terminating: false, removeSlot: { true }))
        XCTAssertTrue(controller.persistedSlotRemoved)
    }

    func testOverlayGateCoversOnlyOwningWindowAndResetsOnEscape() {
        let a = makeTestStore(), b = makeTestStore()
        let first = AgentPadWindowController(windowId: UUID(), store: a), second = AgentPadWindowController(windowId: UUID(), store: b)
        defer { first.close(); second.close(); a.terminate(); b.terminate() }
        a.leftNavigation.railVisible = false
        a.openWorkspaceList()
        XCTAssertTrue(NavigationPresentationGate.obscures(first.window!))
        XCTAssertFalse(NavigationPresentationGate.obscures(second.window!))
        a.handleNavigationEscape()
        XCTAssertFalse(NavigationPresentationGate.obscures(first.window!))
    }
}
