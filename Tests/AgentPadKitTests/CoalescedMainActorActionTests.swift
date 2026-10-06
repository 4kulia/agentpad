import Foundation
import XCTest
@testable import AgentPadKit

@MainActor final class CoalescedMainActorActionTests: XCTestCase {
    func testWriterBurstDeliversOneMainActorTurnAndBecomesQuiet() async throws {
        let calls = Counter()
        let action = CoalescedMainActorAction {
            XCTAssertTrue(Thread.isMainThread)
            calls.increment()
        }
        await Task.detached { for _ in 0..<1000 { action.schedule() } }.value
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls.value, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls.value, 1)
        action.schedule()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls.value, 2, "a later external change still arrives")
    }

    func testCancelledWorkCannotInvalidateANewerGeneration() async throws {
        let calls = Counter()
        let action = CoalescedMainActorAction { calls.increment() }
        action.schedule()
        action.cancel()
        action.schedule()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls.value, 1)
    }
}
