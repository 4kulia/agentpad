import Foundation
import XCTest
@testable import AgentPadKit

/// The table of 6.12: a request's state and the journal's facts give the
/// actions it owes — one test per row.
final class ChatReconcileTests: XCTestCase {
    private func kinds(_ state: TeamRequestState, here: Bool = true, asked: Bool = false, answered: Bool = false,
                       facts: ChatLocalFacts? = ChatLocalFacts()) -> [ChatActionKind] {
        ChatReconcile.actions(.init(state: state, onThisDevice: here, askedHere: asked, answered: answered), facts: facts)
    }

    private func facts(_ approval: ChatLocalFacts.Approval, run: ChatLocalFacts.Run? = nil, undelivered: Bool = false) -> ChatLocalFacts {
        ChatLocalFacts(approval: approval, approvalId: "ap-1", run: run, resultUndelivered: undelivered)
    }

    func testReceiveForASubmittedRequestOfThisDevice() {
        XCTAssertEqual(kinds(.submitted), [.receive])
        XCTAssertEqual(kinds(.submitted, here: false), [])
    }

    func testNotifyDecisionForARequestAwaitingThisDevice() {
        XCTAssertEqual(kinds(.awaitingDecision), [.notifyDecision])
        XCTAssertEqual(kinds(.awaitingDecision, here: false), [], "another device of the owner shows it without buttons")
    }

    func testStartWithAValidApproval() {
        XCTAssertEqual(kinds(.approved, facts: facts(.valid)), [.start])
        XCTAssertEqual(kinds(.starting, facts: facts(.valid)), [.start])
    }

    func testFailStartWithoutAValidApprovalAndRun() {
        XCTAssertEqual(kinds(.approved, facts: facts(.none)), [.failStart])
        XCTAssertEqual(kinds(.starting, facts: facts(.void("server_restored"))), [.failStart])
        XCTAssertEqual(kinds(.approved, facts: facts(.spent, run: .init(runId: "r", ended: true, live: false))), [])
        XCTAssertEqual(kinds(.approved, here: false, facts: facts(.none)), [], "not this device's to start or fail")
    }

    func testRecoverARunLeftWithoutItsOutcome() {
        let left = ChatLocalFacts.Run(runId: "r", ended: false, live: false)
        XCTAssertEqual(kinds(.starting, facts: facts(.spent, run: left)), [.recover])
        XCTAssertEqual(kinds(.running, facts: facts(.spent, run: left)), [.recover])
        XCTAssertEqual(kinds(.running, facts: facts(.spent, run: .init(runId: "r", ended: false, live: true))), [], "running here now")
        XCTAssertEqual(kinds(.finished, facts: facts(.spent, run: left)), [], "the server has its end")
    }

    func testDeliverAResultTheServerHasNotTaken() {
        XCTAssertEqual(kinds(.finished, facts: facts(.spent, run: .init(runId: "r", ended: true, live: false), undelivered: true)), [.deliver])
        XCTAssertEqual(kinds(.running, here: false, facts: facts(.none, undelivered: true)), [.deliver], "from another session of the owner")
    }

    func testNotifyOutcomeOfARequestAskedHere() {
        XCTAssertEqual(kinds(.declined, here: false, asked: true), [.notifyOutcome])
        XCTAssertEqual(kinds(.failedToStart, here: false, asked: true, facts: nil), [.notifyOutcome])
        XCTAssertEqual(kinds(.finished, here: false, asked: true), [], "the text is still to come")
        XCTAssertEqual(kinds(.finished, here: false, asked: true, answered: true), [.notifyOutcome])
        XCTAssertEqual(kinds(.running, here: false, asked: true), [])
        XCTAssertEqual(kinds(.declined, here: false, asked: false), [], "asked from another Mac")
    }

    func testUnknownJournalDecidesNothingOfTheExecutor() {
        for state in [TeamRequestState.submitted, .awaitingDecision, .approved, .starting] {
            XCTAssertEqual(kinds(state, facts: nil), [], state.rawValue)
        }
    }

    func testUnknownStateIsNotFinalAndOwesNothing() {
        let later = TeamRequestState(rawValue: "stop_requested_v2")
        XCTAssertFalse(later.isFinal)
        XCTAssertEqual(kinds(later, asked: true, facts: facts(.valid)), [])
    }
}
