import XCTest
@testable import AgentPadKit

@MainActor
final class NotificationNavigationTests: XCTestCase {
    func testOrganizationLocatorKeepsItsSectionAndReadsEarlierLocators() throws {
        let destination = AttentionDestination.organization("org", section: .devices)
        XCTAssertEqual(try JSONDecoder().decode(AttentionDestination.self, from: JSONEncoder().encode(destination)), destination)
        let old = Data(#"{"organization":{"_0":"org"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AttentionDestination.self, from: old), .organization("org"))
    }
    func testStartupQueuesOneRouteUntilSourcesAreReady() {
        let ledger = AttentionLedger(), router: NotificationNavigation
        router = NotificationNavigation(ledger: ledger)
        let event = AttentionEvent(source: "request", object: "r", kind: .decision, destination: .team(request: "r", outgoing: false))
        ledger.upsert(event)
        var opened: [AttentionDestination] = []
        router.validate = { _ in true }; router.open = { opened.append($0.destination); return true }
        router.activate(event.id); router.activate(event.id)
        XCTAssertTrue(opened.isEmpty)
        router.finishStartup()
        XCTAssertEqual(opened, [event.destination])
        XCTAssertEqual(ledger.pendingCount, 1, "navigation is not consent")
        XCTAssertEqual(ledger.unreadCount, 0)
    }
    func testResolvedExpiredOrChangedScopeIsNeutralAndNeverOpens() {
        for reason in ["resolved", "expired", "account changed", "executor changed", "channel inaccessible"] {
            let ledger = AttentionLedger(), router: NotificationNavigation
            router = NotificationNavigation(ledger: ledger); router.ready = true
            let event = AttentionEvent(source: "request", object: reason, kind: .decision, destination: .channel("channel", request: "r"),
                scope: .init(server: "server", account: "account", organization: "org", generation: "g"))
            ledger.upsert(event)
            var neutral = 0, opens = 0
            router.validate = { _ in false }; router.open = { _ in opens += 1; return true }; router.unavailable = { neutral += 1 }
            router.activate(event.id)
            XCTAssertEqual(opens, 0); XCTAssertEqual(neutral, 1); XCTAssertTrue(ledger.events.isEmpty)
        }
    }
    func testRoutingUsesLiveLookupAfterTabMoves() {
        let ledger = AttentionLedger(), router: NotificationNavigation
        router = NotificationNavigation(ledger: ledger); router.ready = true
        let tab = UUID(), event = AttentionEvent(source: "terminal", object: "one", kind: .input, destination: .terminal(UUID()))
        var notice = event; notice.destination = .terminal(tab); ledger.upsert(notice)
        var window = "old", opened = ""
        router.validate = { $0.destination == .terminal(tab) }
        router.open = { _ in opened = window; return true }
        window = "new"; router.activate(notice.id)
        XCTAssertEqual(opened, "new")
    }
    func testMissingLocatorReturnsNeutralResult() {
        let router = NotificationNavigation(ledger: AttentionLedger()); router.ready = true
        var neutral = false; router.unavailable = { neutral = true }
        router.activate("legacy-team-with-no-destination")
        XCTAssertTrue(neutral)
    }

    func testStartupRouteWaitsForSnapshotAndRevalidatesBeforeOpening() {
        let ledger = AttentionLedger()
        let route = NotificationNavigation(ledger: ledger)
        let event = AttentionEvent(source: "request", object: "r", kind: .decision, destination: .channel("c", request: "r"))
        ledger.upsert(event)
        var snapshotOwed = true, allowed = true, opens = 0, unavailable = 0
        route.shouldWait = { _ in snapshotOwed }; route.validate = { _ in allowed }
        route.open = { _ in opens += 1; return true }; route.unavailable = { unavailable += 1 }
        route.activate(event.id); route.finishStartup(); route.retryPending()
        XCTAssertEqual(opens, 0)
        snapshotOwed = false; allowed = false; route.retryPending()
        XCTAssertEqual(opens, 0); XCTAssertEqual(unavailable, 1)
        XCTAssertTrue(ledger.events.isEmpty)
    }
}
