import Foundation
import XCTest
@testable import AgentPadKit

@MainActor
final class IsolatedClaudeFixtureTests: XCTestCase {
    private var root: URL!
    private var previousJournalBlocks: ((String) -> Bool)?
    private var home: URL { root.appendingPathComponent("home") }
    private var persistent: URL { home.appendingPathComponent(".agentpad-live-claude") }

    override func setUp() async throws {
        previousJournalBlocks = TeamRunAdmission.journalBlocks
        TeamRunAdmission.journalBlocks = { _ in false }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-claude-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TeamRunAdmission.journalBlocks = previousJournalBlocks ?? { _ in false }
        previousJournalBlocks = nil
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

    func testVersionAndExecutorUseTheFixturesHomeAndConfig() async throws {
        let isolated = try IsolatedClaudeFixture(environment: [:], requireAuthentication: false, homeDirectory: home)
        defer { isolated.remove() }
        let binary = try NativeVersionFixture.make(in: isolated.project)
        let request = TeamRunRequest(agent: TeamPublishedAgent(name: "isolated", description: "test", folder: isolated.project.path, access: .read),
                                     prompt: "fixture", sessionId: UUID().uuidString, resume: false, callerName: "test", callerProject: nil, dmHistoryFiles: ChatFiles(directory: isolated.root.appendingPathComponent("chat")))
        _ = try await isolated.runner(claudePath: binary.path).run(request, onActivity: { _ in })
        for phase in ["version", "executor"] {
            let actualHome = try String(contentsOf: isolated.project.appendingPathComponent("\(phase)-home"), encoding: .utf8)
            XCTAssertTrue(actualHome.hasPrefix(isolated.root.path + "/"))
            XCTAssertNotEqual(actualHome, home.path)
            XCTAssertEqual(try String(contentsOf: isolated.project.appendingPathComponent("\(phase)-config"), encoding: .utf8), isolated.config.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    func testPreparedProfileCannotRedirectHistoryOutsideTheFixture() throws {
        try FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
        let outside = home.appendingPathComponent("outside-history")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: persistent.appendingPathComponent("projects"), withDestinationURL: outside)
        XCTAssertThrowsError(try fixture(persistent))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testUnconfirmedCleanupKeepsJournalOpenAndRecoveryUsesFixtureRegistry() async throws {
        let previous = TeamRunAdmission.journalBlocks
        defer { TeamRunAdmission.journalBlocks = previous }
        let isolated = try IsolatedClaudeFixture(environment: [:], requireAuthentication: false, homeDirectory: home)
        defer { isolated.remove() }
        let binary = try NativeVersionFixture.make(in: isolated.project)
        var base = isolated.runner(claudePath: binary.path)
        base.stopTiming = .init(grace: .milliseconds(10), killWait: .milliseconds(10), output: .seconds(1))
        let runner = IncompleteRunner(base: base)
        let f = try ExecutorFixture(root: isolated.profile, runner: runner)
        f.agent.access = .read
        try f.assign(.active)
        let approval = try f.approve()
        let answer = try await f.launcher.launch(approvalId: approval.id)
        XCTAssertEqual(answer.text, "fixture answer")
        let row = try XCTUnwrap(f.journal.runs().first)
        XCTAssertNil(row.outcome, "an answer with unconfirmed cleanup must not be journaled as finished")
        let left = try XCTUnwrap(isolated.processes.leftOvers().first)
        XCTAssertNotNil(f.launcher.processesLeft(left.leader))
        let admission = TeamService(storage: TeamStorage(directory: isolated.profile.appendingPathComponent("team")), runner: runner)
        XCTAssertFalse(admission.canMoveToServer)

        // Recovery must consult that entry's descendants as well as its
        // already exited leader, and remove that same entry after confirmation.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let alive = ProcessIdentity(pid: child.processIdentifier, startTime: try XCTUnwrap(TeamProcesses.startTime(child.processIdentifier)))
        try XCTUnwrap(isolated.processes.seen(of: left.leader)).insert([alive])
        let service = ChatService(files: f.files, tokens: FakeTokenStore())
        service.executorRunner = runner
        await service.recoverRunsAtLaunch()
        let recovery = try XCTUnwrap(service.recovery)
        XCTAssertEqual(recovery.blocked.first?.found, [alive])
        let refused = await recovery.confirmGone(row.runId)
        XCTAssertNotNil(refused, "the live process keeps recovery blocked")
        XCTAssertNotNil(isolated.processes.seen(of: left.leader))
        XCTAssertFalse(admission.canMoveToServer)
        child.terminate()
        child.waitUntilExit()
        let confirmed = await recovery.confirmGone(row.runId)
        XCTAssertNil(confirmed)
        XCTAssertNil(isolated.processes.seen(of: left.leader))
        XCTAssertNotNil(try f.journal.run(row.runId)?.processesGoneAt)
        XCTAssertTrue(admission.canMoveToServer)
    }
}

private struct IncompleteRunner: TeamAgentRunner {
    let base: ClaudeCodeRunner
    var processes: TeamProcesses { base.processes }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        try await base.run(request, onActivity: onActivity, onProcessStarted: { start in
            try onProcessStarted(start)
            try XCTUnwrap(processes.seen(of: start)).markIncomplete()
        })
    }
}
