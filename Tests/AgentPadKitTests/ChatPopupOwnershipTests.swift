import AgentPadTelegram
import Foundation
import XCTest
@testable import AgentPadKit

/// Ownership checks use retained sessions and production move/close APIs. They
/// do not mount a window, start a backend connection, or read any account token.
@MainActor
final class ChatPopupOwnershipTests: XCTestCase {
    private enum FixtureError: Error { case nonConversation }
    private var scope: TeamServiceTestScope!
    private var directory: URL!
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://popup-ownership.example.test"),
                                 accountId: "fictional-maya", orgId: "fictional-northstar")

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("popup-ownership-\(UUID())")
    }

    override func tearDown() async throws {
        scope.close(); scope = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(peers: @escaping @MainActor () -> [WorkspaceStore] = { [] }) -> WorkspaceStore {
        WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
            drafts: DraftRepository(), engineFactory: { TestEngine() }, optionsProvider: { _ in nil },
            peerStores: peers, claudeProjectsRoot: directory.appendingPathComponent("fictional-claude"),
            codexSessionsRoot: directory.appendingPathComponent("fictional-codex"))
    }

    private func openTab(_ content: TabContent, in store: WorkspaceStore) throws -> Session {
        switch content {
        case .channel(let ref): return store.openChannelTab(ref, in: try XCTUnwrap(store.active))
        case .tool(let route): return store.openToolTab(route)
        default:
            XCTFail("The ownership fixture requires a conversation")
            throw FixtureError.nonConversation
        }
    }

    private func ordinaryOpen(_ content: TabContent, in store: WorkspaceStore, router: TabRouter) throws -> Session {
        switch content {
        case .channel(let ref): return try XCTUnwrap(store.showChannel(ref))
        case .tool(let route): return try XCTUnwrap(router.open(route, from: store))
        default:
            XCTFail("The ownership fixture requires a conversation")
            throw FixtureError.nonConversation
        }
    }

    private func terminations(_ session: Session) throws -> Int {
        if let engine = session.engine as? ChannelTabEngine { return engine.terminations }
        return try XCTUnwrap(session.engine as? NativeTabEngine).terminations
    }

    func testCrossWindowDropReleasesBorrowedPopupOwnershipForEveryBackend() throws {
        let conversations: [TabContent] = [
            .channel(ChannelRef(key, channel: "design-\(UUID())")),
            .tool(.directMessage(ChatDMRef(key, dm: "fictional-nora-dm"))),
            .tool(.telegram(.init(environment: .test, account: 42, chat: 710)))
        ]
        for content in conversations {
            var peers: [WorkspaceStore] = []
            let source = store(peers: { peers }), destination = store(peers: { peers })
            peers = [source, destination]
            defer { source.terminate(); destination.terminate(); peers = [] }
            let router = TabRouter()
            router.stores = { peers }
            let moved = try openTab(content, in: source)
            let movedEngine = moved.engine
            let sourceWorkspace = try XCTUnwrap(source.active)
            let agent = source.addTab(in: sourceWorkspace, template: .terminal)
            XCTAssertTrue(try ordinaryOpen(content, in: source, router: router) === moved)
            source.popups.dismiss(reason: .dismiss)
            XCTAssertFalse(source.popups.isPresented)
            XCTAssertTrue(source.popups.sessions.contains { $0 === moved })
            XCTAssertTrue(sourceWorkspace.activeSession === agent)

            let destinationWorkspace = try XCTUnwrap(destination.active)
            let destinationPane = try XCTUnwrap(destinationWorkspace.activePane)
            XCTAssertTrue(destination.handleTabDrop(droppedId: moved.id, to: destinationPane,
                at: destinationPane.tabs.count, in: destinationWorkspace))
            XCTAssertEqual(source.popups.sessions.map(\.id), [])
            XCTAssertNil(source.popups.location(of: moved.id))
            XCTAssertTrue(router.owner(of: moved.id)?.store === destination)
            XCTAssertEqual(destination.allSessions.map(\.id), [moved.id])
            XCTAssertTrue(moved.engine === movedEngine)
            XCTAssertEqual(try terminations(moved), 0)

            let local = try ordinaryOpen(content, in: source, router: router)
            XCTAssertFalse(local === moved, "The old window must create its own conversation after a move")
            XCTAssertFalse(local.engine === movedEngine)
            XCTAssertTrue(source.popups.visibleConversation === local)
            XCTAssertTrue(destinationPane.activeTab === moved)
            XCTAssertTrue(router.owner(of: moved.id)?.store === destination)
            source.terminate()
            XCTAssertEqual(try terminations(local), 1)
            XCTAssertEqual(try terminations(moved), 0, "Closing the old window must not terminate the destination's engine")
            XCTAssertFalse(moved.tabState?.isClosed == true)
            XCTAssertEqual(destination.allSessions.map(\.id), [moved.id])
            XCTAssertTrue(router.owner(of: moved.id)?.store === destination)
        }
    }

    func testSurrenderReleasesBorrowedChannelWithoutTerminatingDuringHandoff() throws {
        let source = store(), destination = store(), router = TabRouter()
        defer { source.terminate(); destination.terminate() }
        router.stores = { [source, destination] }
        let ref = ChannelRef(key, channel: "handoff-\(UUID())")
        let moved = source.openChannelTab(ref, in: try XCTUnwrap(source.active))
        let engine = try XCTUnwrap(moved.engine as? ChannelTabEngine)
        XCTAssertTrue(source.showChannel(ref) === moved)
        source.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(source.popups.isPresented)
        XCTAssertTrue(source.popups.sessions.contains { $0 === moved })

        XCTAssertTrue(source.surrenderSession(id: moved.id) === moved)
        XCTAssertTrue(source.popups.sessions.isEmpty)
        XCTAssertNil(router.owner(of: moved.id))
        XCTAssertEqual(engine.terminations, 0, "The pane owns the engine until structural detachment finishes")
        XCTAssertTrue(ChatService.shared.openChannels(key).contains(ref.channel))
        destination.adoptConversationTab(moved)
        XCTAssertTrue(router.owner(of: moved.id)?.store === destination)
        XCTAssertTrue(destination.active?.activeSession === moved)
        XCTAssertTrue(moved.engine === engine)
        source.terminate()
        XCTAssertEqual(engine.terminations, 0)
        XCTAssertTrue(ChatService.shared.openChannels(key).contains(ref.channel))
    }

    func testClosingBorrowedChannelEvictsTerminatedEngineBeforeOrdinaryReopen() throws {
        let owner = store(), router = TabRouter()
        defer { owner.terminate() }
        router.stores = { [owner] }
        let ref = ChannelRef(key, channel: "close-reopen-\(UUID())")
        let workspace = try XCTUnwrap(owner.active)
        let closed = owner.openChannelTab(ref, in: workspace)
        let closedEngine = try XCTUnwrap(closed.engine as? ChannelTabEngine)
        let agent = owner.addTab(in: workspace, template: .terminal)
        XCTAssertTrue(owner.showChannel(ref) === closed)
        owner.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertTrue(owner.popups.sessions.contains { $0 === closed })
        XCTAssertTrue(ChatService.shared.openChannels(key).contains(ref.channel))

        owner.closeTab(closed, in: workspace)
        XCTAssertEqual(closedEngine.terminations, 1)
        XCTAssertTrue(owner.popups.sessions.isEmpty)
        XCTAssertNil(owner.popups.location(of: closed.id))
        XCTAssertNil(router.owner(of: closed.id))
        XCTAssertFalse(ChatService.shared.openChannels(key).contains(ref.channel))
        XCTAssertTrue(workspace.activeSession === agent)

        let reopened = try XCTUnwrap(owner.showChannel(ref))
        let reopenedEngine = try XCTUnwrap(reopened.engine as? ChannelTabEngine)
        XCTAssertFalse(reopened === closed)
        XCTAssertFalse(reopenedEngine === closedEngine)
        XCTAssertEqual(reopenedEngine.terminations, 0)
        XCTAssertEqual(owner.popups.sessions.map(\.id), [reopened.id])
        XCTAssertTrue(owner.popups.visibleConversation === reopened)
        XCTAssertTrue(router.owner(of: reopened.id)?.store === owner)
        XCTAssertTrue(ChatService.shared.openChannels(key).contains(ref.channel), "The fresh engine must register its channel subscription")
        XCTAssertTrue(workspace.activeSession === agent)
        XCTAssertEqual(owner.allSessions.map(\.id), [agent.id])
        owner.terminate()
        XCTAssertEqual(closedEngine.terminations, 1, "The stale engine must not remain in the popup termination list")
        XCTAssertEqual(reopenedEngine.terminations, 1)
        XCTAssertFalse(ChatService.shared.openChannels(key).contains(ref.channel))
    }
}
