import AppKit
import XCTest
@testable import AgentPadKit

final class TelegramFeedVisibilityTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 40, width: 260, height: 80)
    private var surface: TelegramFeedVisibility {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
        return .init(viewport: viewport, clip: viewport, screens: [viewport], overlays: [], key: true, visible: true, occlusion: .visible)
    }

    func testJumpToLatestCoveringLastLinePreventsImpression() {
        var visibility = surface
        XCTAssertTrue(visibility.isVisible(frame, requiring: .full))
        visibility.overlays = [CGRect(x: 100, y: 110, width: 100, height: 30)]
        XCTAssertFalse(visibility.isVisible(frame, requiring: .full))
        XCTAssertTrue(visibility.isVisible(frame, requiring: .partial))
        let coveredPost = CGRect(x: 110, y: 112, width: 80, height: 8)
        XCTAssertFalse(visibility.isVisible(coveredPost, requiring: .partial))
        visibility.overlays = []
        XCTAssertTrue(visibility.isVisible(frame, requiring: .full))
        XCTAssertTrue(visibility.isVisible(coveredPost, requiring: .partial))
    }

    func testPostsBelowScreenStayUnreadUntilWindowMovesBack() {
        var visibility = surface
        // Feed still has 200 points, but dragging the window below the display
        // leaves only its first 100 points inside the screen's full frame.
        visibility.screens = [CGRect(x: 0, y: 0, width: 300, height: 100)]
        let belowScreen = CGRect(x: 20, y: 110, width: 260, height: 40)
        XCTAssertFalse(visibility.isVisible(belowScreen, requiring: .partial))
        XCTAssertFalse(visibility.isVisible(frame, requiring: .full))
        XCTAssertTrue(visibility.isVisible(frame, requiring: .partial))
        visibility.screens = surface.screens
        XCTAssertTrue(visibility.isVisible(belowScreen, requiring: .partial))
        XCTAssertTrue(visibility.isVisible(frame, requiring: .full))
    }

    @MainActor func testCaptureIncludesFullScreenAndContentBesideDock() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let content = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 300, height: 200)
        let window = NSWindow(contentRect: content, styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: content.size))
        window.contentView = scroll
        scroll.documentView = NSView(frame: scroll.bounds)
        let viewport = CGRect(origin: .zero, size: scroll.contentView.bounds.size)
        var visibility = try XCTUnwrap(TelegramFeedVisibility.capture(scroll: scroll, viewport: viewport, overlays: []))
        XCTAssertEqual(visibility.screens.first, CGRect(x: -10, y: content.maxY - screen.frame.maxY,
                                                       width: screen.frame.width, height: screen.frame.height))
        // The screen's bottom strip is still on screen beside the Dock, even
        // though visibleFrame can exclude that entire strip. Window gates are
        // tested separately so this does not need to activate a real window.
        visibility.key = true; visibility.visible = true; visibility.occlusion = .visible
        let besideDock = CGRect(x: 10, y: viewport.maxY - 20, width: 40, height: 10)
        XCTAssertTrue(visibility.isVisible(besideDock, requiring: .partial))
        XCTAssertTrue(visibility.isVisible(besideDock, requiring: .full))
    }

    func testSameWindowAndViewportGatesApplyToPostsAndAds() {
        for requirement: TelegramFeedVisibility.Requirement in [.partial, .full] {
            var visibility = surface
            XCTAssertTrue(visibility.isVisible(frame, requiring: requirement))
            visibility.key = false
            XCTAssertFalse(visibility.isVisible(frame, requiring: requirement))
            visibility = surface; visibility.visible = false
            XCTAssertFalse(visibility.isVisible(frame, requiring: requirement))
            visibility = surface; visibility.occlusion = []
            XCTAssertFalse(visibility.isVisible(frame, requiring: requirement))
            visibility = surface; visibility.clip = CGRect(x: 0, y: 140, width: 300, height: 60)
            XCTAssertFalse(visibility.isVisible(frame, requiring: requirement))
            visibility = surface
            XCTAssertFalse(visibility.isVisible(CGRect(x: 10, y: 200, width: 100, height: 30), requiring: requirement))
            for empty: CGRect in [.zero, .null, .infinite] {
                XCTAssertFalse(visibility.isVisible(empty, requiring: requirement))
            }
        }
        var visibility = surface
        visibility.clip.size.width = 200
        XCTAssertFalse(visibility.isVisible(frame, requiring: .full))
        XCTAssertTrue(visibility.isVisible(frame, requiring: .partial))
    }

    func testFullVisibilityAcrossScreensRejectsGaps() {
        var visibility = surface
        visibility.screens = [CGRect(x: 0, y: 0, width: 150, height: 200), CGRect(x: 150, y: 0, width: 150, height: 200)]
        XCTAssertTrue(visibility.isVisible(frame, requiring: .full))
        visibility.screens[1].origin.x += 1
        XCTAssertFalse(visibility.isVisible(frame, requiring: .full))
    }

    @MainActor func testGeometryBurstEvaluatesOnlyLatestVisibilityOnNextTurn() async {
        let updates = TelegramFeedVisibilityUpdates(), visibility = surface
        var evaluated: [Bool] = []
        let scrolledAway = expectation(description: "Latest geometry evaluated once")
        for offset in 0..<100 {
            let frame = self.frame.offsetBy(dx: 0, dy: CGFloat(offset * 10))
            updates.schedule {
                XCTAssertTrue(Thread.isMainThread)
                evaluated.append(visibility.isVisible(frame, requiring: .partial))
                scrolledAway.fulfill()
            }
        }
        XCTAssertTrue(evaluated.isEmpty)
        await fulfillment(of: [scrolledAway], timeout: 1)
        XCTAssertEqual(evaluated, [false])

        let returned = expectation(description: "Next turn evaluates new geometry")
        let frame = self.frame
        updates.schedule {
            evaluated.append(visibility.isVisible(frame, requiring: .partial))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(evaluated, [false, true])
    }

    @MainActor func testDisappearanceCancelsPendingEvaluationAndCanScheduleAgain() async {
        let updates = TelegramFeedVisibilityUpdates()
        updates.schedule { XCTFail("A disappeared feed must not publish pending visibility") }
        updates.cancel()
        let turn = expectation(description: "Pending run-loop work drained")
        RunLoop.main.perform(inModes: [.common]) { turn.fulfill() }
        await fulfillment(of: [turn], timeout: 1)

        let returned = expectation(description: "Reappeared feed evaluated")
        updates.schedule { XCTFail("Superseded evaluation must not run") }
        updates.cancel()
        updates.schedule { returned.fulfill() }
        await fulfillment(of: [returned], timeout: 1)
    }

    @MainActor func testUpdatesDuringEvaluationWaitForAnotherRunLoopTurn() async {
        let updates = TelegramFeedVisibilityUpdates()
        var turn = 0
        let counter = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeTimers.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { turn += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), counter, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), counter, .commonModes) }
        let evaluated = expectation(description: "Reentrant update deferred to another turn")
        updates.schedule {
            let firstTurn = turn
            updates.schedule {
                XCTAssertGreaterThan(turn, firstTurn)
                evaluated.fulfill()
            }
        }
        await fulfillment(of: [evaluated], timeout: 1)
    }
}
