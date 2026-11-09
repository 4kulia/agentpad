import XCTest
@testable import AgentPadKit

@MainActor
final class TabDestinationResolverTests: XCTestCase {
    private var isolation: TeamServiceTestScope!
    override func setUp() async throws { isolation = TeamServiceTestScope() }
    override func tearDown() async throws { isolation.close() }
    private let scope = AttentionScope(server: "https://chat.example.com", account: "me", organization: "org", generation: "g")

    private func router(_ stores: [WorkspaceStore]) -> TabRouter {
        let router = TabRouter()
        router.stores = { stores }
        router.ensureHost = { stores.first }
        router.prepareDestinations = {}
        router.channelScope = { [scope] ref in
            ref.server == scope.server && ref.account == scope.account && ref.org == scope.organization ? scope : nil
        }
        router.destinations = { [scope] in
            var result: [UUID: AttentionTabSnapshot] = [:]
            for store in stores {
                for workspace in store.workspaces {
                    for pane in workspace.root.allPanes {
                        for tab in pane.tabs {
                            guard let ref = tab.channel else { continue }
                            result[tab.id] = .init(id: tab.id, owner: .init(window: store.windowID, workspace: workspace.id),
                                pane: pane.id, available: true, destinations: [.channel(scope, ref.channel)])
                        }
                    }
                }
            }
            return result
        }
        return router
    }

    func testConversationEntriesOpenLocalPopupWhileExplicitTabIDStillRevealsExactWindow() throws {
        let origin = makeTestStore(), detached = makeTestStore()
        defer { origin.terminate(); detached.terminate() }
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let tab = detached.openChannelTab(ref, in: detached.active!)
        let router = router([origin, detached])
        var raised: [UUID] = []
        router.revealWindow = { raised.append($0.windowID) }
        let agent = try XCTUnwrap(origin.active?.activeSession)
        let count = origin.allSessions.count + detached.allSessions.count
        let popup = try XCTUnwrap(router.openChannel(ref, scope: scope, from: origin))
        XCTAssertFalse(popup === tab)
        for _ in 0..<3 {
            XCTAssertTrue(router.openChannel(ref, scope: scope, from: origin) === popup)
            XCTAssertTrue(origin.popups.visibleConversation === popup)
            XCTAssertTrue(origin.active?.activeSession === agent)
        }
        XCTAssertTrue(raised.isEmpty)
        XCTAssertEqual(origin.allSessions.count + detached.allSessions.count, count)
        let local = try XCTUnwrap(router.openChannel(ref, from: origin, asTab: true))
        XCTAssertTrue(local === popup, "Explicit tab opening promotes the retained local conversation")
        XCTAssertTrue(origin.active?.activeSession === local)
        XCTAssertNil(origin.popups.visibleConversation)
        XCTAssertTrue(raised.isEmpty, "Local tab opening does not raise another window or Space")
        router.reveal(try XCTUnwrap(router.owner(of: tab.id)))
        XCTAssertEqual(raised, [detached.windowID], "Explicit TabID remains exact despite a matching local conversation")
        XCTAssertTrue(detached.active?.activeSession === tab)
        XCTAssertTrue(origin.active?.activeSession === local)
    }

    func testMostRecentLocalDuplicateThenStableSessionIDIgnoresRemoteRecency() throws {
        let origin = makeTestStore(), detached = makeTestStore()
        defer { origin.terminate(); detached.terminate() }
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let first = origin.openChannelTab(ref, in: origin.active!), second = origin.openChannelTab(ref, in: origin.active!)
        let remote = detached.openChannelTab(ref, in: detached.active!)
        let router = router([detached, origin])
        var raised: [UUID] = []; router.revealWindow = { raised.append($0.windowID) }
        first.lastActivated = Date(timeIntervalSince1970: 1); second.lastActivated = Date(timeIntervalSince1970: 2)
        remote.lastActivated = .distantFuture
        XCTAssertTrue(router.openChannel(ref, scope: scope, from: origin, asTab: true) === second)
        first.lastActivated = .distantPast; second.lastActivated = .distantPast
        let stable = first.id.uuidString < second.id.uuidString ? first : second
        XCTAssertTrue(router.openChannel(ref, from: origin, asTab: true) === stable)
        let agent = origin.addTab(in: origin.active!)
        XCTAssertTrue(router.openChannel(ref, from: origin) === stable)
        XCTAssertTrue(origin.popups.visibleConversation === stable)
        XCTAssertTrue(origin.active?.activeSession === agent)
        XCTAssertTrue(raised.isEmpty)
        XCTAssertEqual(origin.allSessions.filter { $0.channel == ref }.count, 2)
    }

    func testScopeMismatchAndRevocationCannotOpenPopupOrTab() throws {
        let origin = makeTestStore()
        defer { origin.terminate() }
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let router = router([origin]), original = origin.allSessions.map(\.id)
        let active = origin.active?.activeSession?.id
        var changed = scope; changed.generation = "new"
        for asTab in [false, true] {
            router.channelScope = { [scope] _ in scope }
            XCTAssertNil(router.openChannel(ref, scope: changed, from: origin, asTab: asTab))
            var validations = 0
            router.channelScope = { [scope] _ in validations += 1; return validations == 1 ? scope : nil }
            XCTAssertNil(router.openChannel(ref, from: origin, asTab: asTab), "Revocation between validation and opening must reject either presentation")
            XCTAssertEqual(validations, 2)
            XCTAssertEqual(origin.allSessions.map(\.id), original)
            XCTAssertEqual(origin.active?.activeSession?.id, active)
            XCTAssertTrue(origin.popups.sessions.isEmpty); XCTAssertFalse(origin.popups.isPresented)
        }
    }

    func testClosedDestinationCreatesOneLocalPopupThenPromotesIt() throws {
        let a = makeTestStore(), b = makeTestStore()
        defer { a.terminate(); b.terminate() }
        let router = router([a, b])
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let tab = b.openChannelTab(ref, in: b.active!)
        let stale = router.destinations()
        b.closeTab(tab, in: b.active!)
        router.destinations = { stale }
        let original = a.allSessions.map(\.id), active = a.active?.activeSession?.id
        let opened = try XCTUnwrap(router.openChannel(ref, from: a))
        XCTAssertNotEqual(opened.id, tab.id)
        XCTAssertTrue(router.openChannel(ref, from: a) === opened)
        XCTAssertTrue(a.popups.visibleConversation === opened)
        XCTAssertEqual(a.allSessions.map(\.id), original)
        XCTAssertEqual(a.active?.activeSession?.id, active)
        XCTAssertTrue(router.openChannel(ref, from: a, asTab: true) === opened)
        XCTAssertNil(a.popups.visibleConversation)
        XCTAssertEqual(a.allSessions.map(\.id), original + [opened.id])
        XCTAssertTrue(a.active?.activeSession === opened)
        XCTAssertNil(b.channelTab(ref))
    }

    func testDirectMessagePopupAndExplicitTabOpeningStayInTheirInitiatingWindows() throws {
        let a = makeTestStore(), b = makeTestStore()
        defer { a.terminate(); b.terminate() }
        let router = router([b, a])
        let key = try XCTUnwrap(ChatAttention.key(scope))
        let dm = ToolRoute.directMessage(ChatDMRef(key, dm: "dm"))
        let remote = b.openToolTab(dm)
        let firstAgent = try XCTUnwrap(a.active?.activeSession), secondAgent = b.addTab(in: b.active!)
        let local = try XCTUnwrap(router.open(dm, from: a))
        XCTAssertFalse(local === remote)
        XCTAssertTrue(a.popups.visibleConversation === local)
        XCTAssertTrue(a.active?.activeSession === firstAgent)
        XCTAssertFalse(a.allSessions.contains { $0.toolRoute == dm })
        XCTAssertTrue(router.open(dm, from: a) === local)
        XCTAssertTrue(router.open(dm, from: b) === remote)
        XCTAssertTrue(b.popups.visibleConversation === remote)
        XCTAssertTrue(b.active?.activeSession === secondAgent)
        XCTAssertTrue(router.open(dm, from: a, asTab: true) === local)
        XCTAssertNil(a.popups.visibleConversation); XCTAssertTrue(a.active?.activeSession === local)
        XCTAssertTrue(b.popups.visibleConversation === remote, "Opening a local tab does not replace another window's popup")
        XCTAssertTrue(router.open(dm, from: b, asTab: true) === remote)
        XCTAssertNil(b.popups.visibleConversation); XCTAssertTrue(b.active?.activeSession === remote)
        XCTAssertEqual(a.allSessions.filter { $0.toolRoute == dm }.map(\.id), [local.id])
        XCTAssertEqual(b.allSessions.filter { $0.toolRoute == dm }.map(\.id), [remote.id])
    }

    func testServicePopupOwnershipAndRetainedReuseRemainWindowLocal() throws {
        let a = makeTestStore(), b = makeTestStore()
        defer { a.terminate(); b.terminate() }
        let router = router([a, b])
        let key = try XCTUnwrap(ChatAttention.key(scope))
        let request = ToolRoute.request(.server(OrgKey(key)), requestID: "request")
        let remoteRequest = b.openToolTab(request)
        let localRequest = try XCTUnwrap(router.open(request, from: a))
        XCTAssertFalse(localRequest === remoteRequest)
        XCTAssertTrue(router.open(request, from: a) === localRequest)
        XCTAssertTrue(router.open(request, from: b) === remoteRequest)
        XCTAssertTrue(router.owner(of: localRequest.id)?.store === a)
        XCTAssertTrue(router.owner(of: remoteRequest.id)?.store === b)
        XCTAssertEqual(a.popups.sessions.map(\.id), [localRequest.id])
        XCTAssertEqual(b.popups.sessions.map(\.id), [remoteRequest.id])
        XCTAssertFalse(a.allSessions.contains { $0.toolRoute == request })
        XCTAssertFalse(b.allSessions.contains { $0.toolRoute == request })
        a.popups.dismiss(reason: .dismiss)
        XCTAssertFalse(a.popups.isPresented)
        XCTAssertEqual(b.popups.page?.id, ObjectIdentifier(remoteRequest))
        XCTAssertTrue(router.open(request, from: a) === localRequest)
        XCTAssertEqual(a.popups.page?.id, ObjectIdentifier(localRequest))
        XCTAssertEqual(b.popups.page?.id, ObjectIdentifier(remoteRequest))
    }

    func testWorkspaceAndPaneActivationChooseTheMostRecentLocalDestination() throws {
        let origin = makeTestStore(), detached = makeTestStore()
        defer { origin.terminate(); detached.terminate() }
        let workspace = try XCTUnwrap(origin.active)
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let first = origin.openChannelTab(ref, in: workspace)
        let otherWorkspace = origin.addWorkspace(workingDirectory: workspace.workingDirectory)
        let second = origin.openChannelTab(ref, in: otherWorkspace)
        let remote = detached.openChannelTab(ref, in: detached.active!)
        remote.lastActivated = .distantFuture
        let router = router([detached, origin])
        XCTAssertTrue(router.openChannel(ref, from: origin) === second, "New local tabs participate in recency")
        origin.popups.dismiss(reason: .dismiss)
        origin.activateWorkspace(workspace)
        XCTAssertTrue(router.openChannel(ref, from: origin) === first)
        origin.popups.dismiss(reason: .dismiss)
        let firstPane = try XCTUnwrap(workspace.activePane)
        let secondPane = try XCTUnwrap(origin.splitPane(firstPane, orientation: .horizontal, in: workspace))
        let third = origin.openChannelTab(ref, in: workspace, pane: secondPane)
        origin.focusPane(firstPane, in: workspace)
        XCTAssertTrue(router.openChannel(ref, from: origin) === first)
        origin.popups.dismiss(reason: .dismiss)
        origin.focusPane(secondPane, in: workspace)
        XCTAssertTrue(router.openChannel(ref, from: origin) === third)
        XCTAssertTrue(detached.active?.activeSession === remote)
    }
}
