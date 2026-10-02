import AppKit
import XCTest
@testable import AgentPadKit

final class PanelPlacementTests: XCTestCase {
    func testKeepsOriginWhenPanelAlreadyFits() {
        let origin = PanelPlacement.clampedOrigin(
            preferred: NSPoint(x: 200, y: 180),
            panelSize: NSSize(width: 300, height: 200),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, NSPoint(x: 200, y: 180))
    }

    func testClampsEveryScreenEdgeWithMargin() {
        let origin = PanelPlacement.clampedOrigin(
            preferred: NSPoint(x: 900, y: -100),
            panelSize: NSSize(width: 300, height: 200),
            visibleFrame: NSRect(x: 100, y: 50, width: 1_000, height: 800)
        )

        XCTAssertEqual(origin, NSPoint(x: 792, y: 58))
    }

    func testOversizedPanelPinsToSafeFrameOrigin() {
        let origin = PanelPlacement.clampedOrigin(
            preferred: NSPoint(x: 500, y: 500),
            panelSize: NSSize(width: 900, height: 700),
            visibleFrame: NSRect(x: 40, y: 20, width: 800, height: 600)
        )

        XCTAssertEqual(origin, NSPoint(x: 48, y: 28))
    }
}
