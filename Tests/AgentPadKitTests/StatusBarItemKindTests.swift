import XCTest
@testable import AgentPadKit

final class StatusBarItemKindTests: XCTestCase {
    func testDefaultOrderCoversAllCases() {
        // If a new case is added and someone forgets to drop it into
        // `defaultOrder`, users who haven't customised Settings → Status
        // Bar would silently miss the new slot. This guard catches that
        // at test time.
        XCTAssertEqual(
            Set(StatusBarItemKind.defaultOrder),
            Set(StatusBarItemKind.allCases)
        )
        XCTAssertEqual(StatusBarItemKind.defaultOrder.count, StatusBarItemKind.allCases.count)
    }

    func testRawValuesAreStable() {
        // `rawValue` is persisted in settings.json — renaming a case
        // silently invalidates every user's saved configuration. Pin the
        // mapping so renames force an explicit test update.
        XCTAssertEqual(StatusBarItemKind.toolCallActivity.rawValue, "tool-call-activity")
        XCTAssertEqual(StatusBarItemKind.codexUsage.rawValue, "codex-usage")
        XCTAssertEqual(StatusBarItemKind.pythonVenv.rawValue, "python-venv")
        XCTAssertEqual(StatusBarItemKind.nodeVersion.rawValue, "node-version")
        XCTAssertEqual(StatusBarItemKind.proxy.rawValue, "proxy")
        XCTAssertEqual(StatusBarItemKind.gitRepo.rawValue, "git-repo")
        XCTAssertEqual(StatusBarItemKind.gitBranch.rawValue, "git-branch")
        XCTAssertEqual(StatusBarItemKind.gitDiff.rawValue, "git-diff")
    }
}
