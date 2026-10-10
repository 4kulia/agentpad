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

    func testMentionPaletteAndNotificationDestinationReuseDetachedTabAndExactIDs() throws {
        let origin = makeTestStore(), detached = makeTestStore()
        defer { origin.terminate(); detached.terminate() }
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let tab = detached.openChannelTab(ref, in: detached.active!)
        let router = router([origin, detached])
        var raised: UUID?
        router.revealWindow = { raised = $0.windowID }
        let count = origin.allSessions.count + detached.allSessions.count
        for _ in 0..<3 {
            XCTAssertTrue(router.openChannel(ref, scope: scope, from: origin) === tab)
            XCTAssertEqual(raised, detached.windowID)
        }
        XCTAssertEqual(origin.allSessions.count + detached.allSessions.count, count)
        let local = origin.openChannelTab(ref, in: origin.active!)
        XCTAssertTrue(router.openChannel(ref, from: origin) === local, "Conversation routes prefer the initiating window")
        router.reveal(try XCTUnwrap(router.owner(of: tab.id)))
        XCTAssertEqual(raised, detached.windowID, "Explicit TabID remains exact despite a matching local conversation")
    }

    func testMostRecentThenStableIDsAndScopeRevalidation() throws {
        let origin = makeTestStore(), a = makeTestStore(), b = makeTestStore()
        defer { origin.terminate(); a.terminate(); b.terminate() }
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let first = a.openChannelTab(ref, in: a.active!), second = b.openChannelTab(ref, in: b.active!)
        let router = router([origin, b, a])
        first.lastActivated = Date(timeIntervalSince1970: 1); second.lastActivated = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(router.openChannel(ref, scope: scope, from: origin) === second)
        first.lastActivated = .distantPast; second.lastActivated = .distantPast
        let stable = a.windowID.uuidString < b.windowID.uuidString ? first : second
        XCTAssertTrue(router.openChannel(ref, from: origin) === stable)
        var changed = scope; changed.generation = "new"
        XCTAssertNil(router.openChannel(ref, scope: changed, from: origin))
        var validations = 0
        router.channelScope = { [scope] _ in validations += 1; return validations == 1 ? scope : nil }
        XCTAssertNil(router.openChannel(ref, from: origin), "Revocation between lookup and reveal cannot open or duplicate")
        XCTAssertNil(origin.channelTab(ref))
    }

    func testClosedDestinationCreatesOnlyOneNewTabAndToolsUseSamePreference() throws {
        let a = makeTestStore(), b = makeTestStore()
        defer { a.terminate(); b.terminate() }
        let router = router([a, b])
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let tab = b.openChannelTab(ref, in: b.active!)
        let stale = router.destinations()
        b.closeTab(tab, in: b.active!)
        router.destinations = { stale }
        let opened = try XCTUnwrap(router.openChannel(ref, from: a))
        XCTAssertNotEqual(opened.id, tab.id)
        XCTAssertTrue(router.openChannel(ref, from: a) === opened)
        let key = try XCTUnwrap(ChatAttention.key(scope))
        let dm = ToolRoute.directMessage(ChatDMRef(key, dm: "dm"))
        let remote = b.openToolTab(dm), local = a.openToolTab(dm)
        XCTAssertTrue(router.open(dm, from: a) === local)
        XCTAssertTrue(router.open(dm, from: b) === remote)
        let request = ToolRoute.request(.server(OrgKey(key)), requestID: "request")
        let requestTab = b.openToolTab(request)
        XCTAssertTrue(router.open(request, from: a) === requestTab)
    }

    func testWorkspaceAndPaneActivationChooseTheMostRecentDestination() throws {
        let origin = makeTestStore(), a = makeTestStore(), b = makeTestStore()
        defer { origin.terminate(); a.terminate(); b.terminate() }
        let workspace = try XCTUnwrap(a.active)
        let ref = ChannelRef(server: scope.server, account: scope.account, org: scope.organization, channel: "c")
        let first = a.openChannelTab(ref, in: workspace), second = b.openChannelTab(ref, in: b.active!)
        let router = router([origin, a, b])
        XCTAssertTrue(router.openChannel(ref, from: origin) === second, "New tabs participate in recency")
        _ = a.addWorkspace(workingDirectory: workspace.workingDirectory)
        a.activateWorkspace(workspace)
        XCTAssertTrue(router.openChannel(ref, from: origin) === first)
        b.focusPane(try XCTUnwrap(b.active?.activePane), in: b.active!)
        XCTAssertTrue(router.openChannel(ref, from: origin) === second)
    }
}
