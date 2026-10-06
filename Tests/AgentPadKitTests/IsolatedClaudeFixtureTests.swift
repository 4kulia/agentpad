import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class IsolatedClaudeFixtureTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var persistent: URL { home.appendingPathComponent(".agentpad-live-claude") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-claude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ config: URL) throws -> IsolatedClaudeFixture {
        try IsolatedClaudeFixture(environment: ["AGENTPAD_LIVE_CLAUDE_CONFIG_DIR": config.path], homeDirectory: home)
    }

    func testExplicitPersistentProfileIsAcceptedAndRetainedAfterCleanup() throws {
        try FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
        // Convert XCTSkip into a failure: rejecting an explicitly allowed path is a regression.
        let isolated = try XCTUnwrap(try? fixture(persistent))
        defer { isolated.remove() }
        XCTAssertEqual(isolated.config, persistent.resolvingSymlinksInPath())
        XCTAssertEqual(isolated.projects, isolated.config.appendingPathComponent("projects"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated.project.path))
        isolated.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolated.projects.path))
    }

    func testExplicitExecutableNeverFallsBackToTheDefaultInstallation() throws {
        let selected = root.appendingPathComponent("missing-selected-claude").path
        let isolated = try IsolatedClaudeFixture(environment: ["AGENTPAD_LIVE_CLAUDE_EXECUTABLE": selected],
                                                 requireAuthentication: false, homeDirectory: home)
        defer { isolated.remove() }
        XCTAssertEqual(isolated.executablePath, selected)
        XCTAssertEqual(isolated.runner().claudePath, selected, "a missing selected file must fail preflight, not run another installation")
        let override = root.appendingPathComponent("explicit-override-claude").path
        XCTAssertEqual(isolated.runner(claudePath: override).claudePath, override)
    }

    func testPersistentProfileMustBeAnExistingDirectoryAtTheExactPath() throws {
        XCTAssertThrowsError(try fixture(persistent))
        for name in [".claude", ".agentpad-live-claude-other", "arbitrary"] {
            let other = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            XCTAssertThrowsError(try fixture(other), name)
        }
        XCTAssertThrowsError(try fixture(home))
        try Data().write(to: persistent)
        XCTAssertThrowsError(try fixture(persistent), "a file is not a prepared profile")
    }

    func testPersistentProfileCannotBeASymlinkToAPersonalProfile() throws {
        let personal = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try Data().write(to: personal.appendingPathComponent("agentpad-e2e-ready"))
        try FileManager.default.createSymbolicLink(at: persistent, withDestinationURL: personal)
        XCTAssertThrowsError(try fixture(persistent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: personal.appendingPathComponent("projects").path))
    }

    func testTemporaryProfileStillRequiresItsNameAndReadyMarker() throws {
        let config = root.appendingPathComponent("agentpad-e2e-claude-test")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture(config))
        try Data().write(to: config.appendingPathComponent("agentpad-e2e-ready"))
        let isolated = try XCTUnwrap(try? fixture(config))
        defer { isolated.remove() }
        XCTAssertEqual(isolated.config, config.resolvingSymlinksInPath())
        let other = root.appendingPathComponent("other-profile")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent("agentpad-e2e-ready"))
        XCTAssertThrowsError(try fixture(other))
    }
}
