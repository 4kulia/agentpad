import XCTest
@testable import AgentPadKit

@MainActor
final class BackgroundInspectionTests: XCTestCase {
    func testBusyWorkersQueueWithoutADefaultTimeoutAndExplicitDeadlinesStillFire() async throws {
        let gate = Gate()
        gate.close(); defer { gate.open() }
        let entered = expectation(description: "all workers occupied")
        entered.expectedFulfillmentCount = BackgroundInspection.workerLimit
        let blockers = (0..<BackgroundInspection.workerLimit).map { _ in
            Task {
                try await BackgroundInspection.run {
                    XCTAssertFalse(Thread.isMainThread)
                    entered.fulfill()
                    gate.pass()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 3)

        var finished = false
        let queued = Task {
            defer { finished = true }
            return try await BackgroundInspection.run {
                XCTAssertFalse(Thread.isMainThread)
                return 42
            }
        }
        do {
            _ = try await BackgroundInspection.run(timeout: 0.05) {
                XCTFail("An expired queued inspection must not run later")
            }
            XCTFail("The explicit deadline must fire while all workers are blocked")
        } catch { XCTAssertTrue(error is BackgroundInspection.TimedOut) }
        // Longer than the former implicit two-second timeout.
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertFalse(finished, "Busy workers must retain untimed work in the queue")
        gate.open()
        let result = try await queued.value
        XCTAssertEqual(result, 42)
        for blocker in blockers { try await blocker.value }
    }

    func testCancellationReturnsWhileWorkerIsBlockedAndIgnoresItsLateResult() async throws {
        let gate = Gate()
        gate.close(); defer { gate.open() }
        let entered = expectation(description: "worker blocked")
        let finished = expectation(description: "worker released")
        let task = Task {
            try await BackgroundInspection.run {
                entered.fulfill()
                gate.pass()
                finished.fulfill()
                return 42
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.open()
        await fulfillment(of: [finished], timeout: 3)
    }
}
