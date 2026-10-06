import Foundation
import XCTest
@testable import AgentPadKit

@MainActor final class MainThreadWatchdogTests: XCTestCase {
    func testLogContainsTheSampledMainStackNotTheWatchdogStack() {
        let frames = MainThreadWatchdog.mainThreadStack(in: """
            Call graph:
                91 Thread_1459533: Main Thread
                + 91 static WatchdogSmoke.main()
                +   91 __semwait_signal
                91 Thread_1459547
                + 91 MainThreadWatchdog.tick()
            """)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.joined().contains("WatchdogSmoke.main()"))
        XCTAssertFalse(frames.joined().contains("MainThreadWatchdog.tick()"))
    }

    func testReportsWhileMainIsBlockedOnceAndRecovers() async throws {
        let reports = Counter()
        let reported = DispatchSemaphore(value: 0)
        let watchdog = MainThreadWatchdog(threshold: 0.08) { stall in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertGreaterThan(stall.seconds, 0.08)
            XCTAssertTrue(stall.checkpoint.contains("testReportsWhileMainIsBlockedOnceAndRecovers"))
            reports.increment()
            reported.signal()
        }
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.checkpoint()
        // Deliberately block the UI. A main-actor timer could not report here.
        XCTAssertEqual(reported.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(reported.wait(timeout: .now() + 0.15), .timedOut, "one report per continuous stall")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reports.value, 1, "a recovered main queue is quiet")
        XCTAssertEqual(reported.wait(timeout: .now() + 2), .success, "a later stall is detected again")
    }

    func testResponsiveAndStoppedWatchdogRemainQuiet() async throws {
        let reports = Counter()
        let watchdog = MainThreadWatchdog(threshold: 0.1) { _ in reports.increment() }
        watchdog.start()
        try await Task.sleep(for: .milliseconds(300))
        watchdog.stop()
        let barrier = DispatchSemaphore(value: 0)
        XCTAssertEqual(barrier.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(reports.value, 0)
    }
}
