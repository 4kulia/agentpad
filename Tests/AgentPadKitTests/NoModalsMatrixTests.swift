import XCTest
@testable import AgentPadKit

final class NoModalsMatrixTests: XCTestCase {
    func testFullscreenHelpersRequireExactAppKitClass() {
        for name in ["_NSFullScreenTransitionOverlayWindow", "NSToolbarFullScreenWindow"] {
            XCTAssertTrue(NoModalsMatrixInventory.isFullscreenHelper(name, frameworkOwned: true), name)
            XCTAssertFalse(NoModalsMatrixInventory.isFullscreenHelper(name, frameworkOwned: false), name)
        }
        for name in ["NSWindow", "NSPanel", "NSToolbarFullScreenWindowFake", "_NSFullScreenTransitionOverlayWindowFake"] {
            XCTAssertFalse(NoModalsMatrixInventory.isFullscreenHelper(name, frameworkOwned: true), name)
        }
    }

    func testNamedFramesExpandToBothThemesWithoutCountingFiles() {
        XCTAssertEqual(NoModalsMatrixInventory.images(["connect-server", "telegram-video-url"]), [
            "popups-connect-server.png", "popups-connect-server-light.png",
            "popups-telegram-video-url.png", "popups-telegram-video-url-light.png"
        ])
        XCTAssertEqual(NoModalsMatrixInventory.images(["publish-confirmation"], prefix: "layout-"), [
            "layout-publish-confirmation.png", "layout-publish-confirmation-light.png"
        ])
        let requiredStates: Set<String> = ["connect-server", "connect-code", "connect-organization", "connect-name",
            "connect-connected", "connect-busy", "request-approval-draft", "publish", "publish-session", "publication"]
        XCTAssertTrue(requiredStates.isSubset(of: Set(NoModalsMatrixInventory.phaseTwoFrames)))
        XCTAssertEqual(Set(NoModalsMatrixInventory.phaseTwoFrames).count, NoModalsMatrixInventory.phaseTwoFrames.count)
    }
}
