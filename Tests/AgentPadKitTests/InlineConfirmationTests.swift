import XCTest
@testable import AgentPadKit

@MainActor
final class InlineConfirmationTests: XCTestCase {
    func testBusyDoubleClickAndLateResultCompleteExactlyOnce() async throws {
        let coordinator = ConfirmationCoordinator()
        var calls = 0, results: [Bool] = []
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Operation started")
        let completed = expectation(description: "Confirmation completed")
        let context = ConfirmationCoordinator.Context(tabID: UUID(), targetID: "file", revision: "1")
        XCTAssertTrue(coordinator.request(context, title: "Delete file", consequences: "The file will be removed", verb: "Delete",
            destructive: true, stillValid: { true }, completion: { results.append($0); completed.fulfill() }) {
                calls += 1
                await withCheckedContinuation { resume = $0; started.fulfill() }
            })
        coordinator.shown(true)
        coordinator.confirm(); coordinator.confirm()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(calls, 1)
        var busy: Bool?
        XCTAssertFalse(coordinator.request(context, title: "Other", consequences: "", verb: "Do", stillValid: { true }, completion: { busy = $0 }) {})
        XCTAssertEqual(busy, false)
        coordinator.invalidate(); coordinator.shown(false)
        XCTAssertEqual(coordinator.phase, .executing)
        try XCTUnwrap(resume).resume()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(coordinator.phase, .completed)
        coordinator.cancel(); XCTAssertEqual(results, [true])
    }

    func testNoAcceptanceWithoutVisibleBlockAndAllInvalidationReasonsRefuse() {
        for reason in ["tab", "section", "workspace", "window", "move", "close", "account", "revision", "caller", "deadline"] {
            let coordinator = ConfirmationCoordinator()
            var current = true, decisions: [Bool] = [], operations = 0
            let time = Date(); coordinator.now = { time }
            let context = ConfirmationCoordinator.Context(tabID: UUID(), targetID: reason, deadline: time.addingTimeInterval(10), callerWaiting: true)
            XCTAssertTrue(coordinator.request(context, title: "Confirm", consequences: "Consequence", verb: "Remove",
                stillValid: { current }, completion: { decisions.append($0) }) { operations += 1 })
            coordinator.confirm()
            XCTAssertEqual(operations, 0)
            coordinator.shown(true)
            if reason == "deadline" { coordinator.now = { time.addingTimeInterval(20) }; coordinator.validate() }
            else if ["account", "revision", "caller"].contains(reason) { current = false; coordinator.validate() }
            else { coordinator.invalidate() }
            coordinator.confirm(); coordinator.cancel(); coordinator.invalidate()
            XCTAssertEqual(decisions, [false], reason)
            XCTAssertEqual(operations, 0, reason)
            XCTAssertFalse(PendingConfirmations.shared.open(context.actionID))
        }
    }

    func testNewDecisionCannotInheritVisibilityFromCancelledBlock() {
        let coordinator = ConfirmationCoordinator()
        var calls = 0
        XCTAssertTrue(coordinator.request(.init(tabID: UUID(), targetID: "first"), title: "First", consequences: "", verb: "Do", stillValid: { true }) { calls += 1 })
        coordinator.shown(true); coordinator.cancel()
        XCTAssertTrue(coordinator.request(.init(tabID: UUID(), targetID: "second"), title: "Second", consequences: "", verb: "Do", stillValid: { true }) { calls += 1 })
        coordinator.confirm()
        XCTAssertTrue(coordinator.isAwaiting)
        XCTAssertFalse(coordinator.isVisible)
        XCTAssertEqual(calls, 0)
        coordinator.invalidate()
    }

    func testRevisionChangeBeforeScheduledExecutionRefuses() async {
        let coordinator = ConfirmationCoordinator()
        var current = true, calls = 0, results: [Bool] = []
        let completed = expectation(description: "Stale confirmation completed")
        XCTAssertTrue(coordinator.request(.init(tabID: UUID(), targetID: "file", revision: "1"), title: "Delete", consequences: "", verb: "Delete",
            stillValid: { current }, completion: { results.append($0); completed.fulfill() }) { calls += 1 })
        coordinator.shown(true); coordinator.confirm(); current = false
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(calls, 0); XCTAssertEqual(results, [false])
        XCTAssertEqual(coordinator.phase, .invalidated)
    }

    func testFailureDropsConsentAndRequiresNewRequest() async {
        let coordinator = ConfirmationCoordinator()
        var calls = 0, results: [Bool] = []
        let started = expectation(description: "Failing operation started")
        let completed = expectation(description: "Failed confirmation completed")
        XCTAssertTrue(coordinator.request(.init(tabID: UUID(), targetID: "target"), title: "Remove", consequences: "Gone", verb: "Remove",
            destructive: true, stillValid: { true }, completion: { results.append($0); completed.fulfill() }) {
                calls += 1; started.fulfill(); throw CocoaError(.fileWriteNoPermission)
            })
        coordinator.shown(true); coordinator.confirm()
        await fulfillment(of: [started, completed], timeout: 3, enforceOrder: true)
        coordinator.confirm()
        XCTAssertEqual(calls, 1); XCTAssertEqual(results, [false])
        guard case .failed = coordinator.phase else { return XCTFail("failed operation must stay inline") }
        coordinator.cancel()
        XCTAssertEqual(results, [false])
    }

    func testPendingConsentIsNotStoredInNotificationMetadata() throws {
        let metadata = NotificationDeliveryStore()
        let ledger = AttentionLedger(metadata: metadata)
        let event = AttentionEvent(source: "tab-confirmation", object: "action", kind: .confirmation,
            destination: .tabAction(tabID: UUID(), actionID: UUID()))
        ledger.upsert(event)
        XCTAssertNil(metadata.markers[event.id]?.locator)
    }
}
