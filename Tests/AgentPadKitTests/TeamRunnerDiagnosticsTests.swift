import XCTest
@testable import AgentPadKit

@MainActor
final class TeamRunnerDiagnosticsTests: XCTestCase {
    private var isolated: IsolatedClaudeFixture!
    private var binary: URL!

    override func setUp() async throws {
        isolated = try IsolatedClaudeFixture(environment: [:], requireAuthentication: false)
        binary = try NativeVersionFixture.make(in: isolated.project)
    }

    override func tearDown() async throws { isolated.remove() }

    private func request() -> TeamRunRequest {
        TeamRunRequest(agent: TeamPublishedAgent(name: "diagnostic", description: "fixture", folder: isolated.project.path, access: .read),
                       prompt: "test", sessionId: UUID().uuidString, resume: false, callerName: "test", callerProject: nil)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: isolated.project.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func failure(_ runner: ClaudeCodeRunner) async -> String {
        do {
            _ = try await runner.run(request(), onActivity: { _ in })
            XCTFail("a failed Claude process must not return a successful answer")
            return ""
        } catch { return error.localizedDescription }
    }

    func testUnauthenticatedFirstRunHasSafeActionVersionAndExitCodeThenCanRetry() async throws {
        try write("executor-error.txt", "Not logged in. Please run /login. synthetic-credential \(isolated.project.path) https://example.invalid/?token=synthetic-query\n")
        let runner = isolated.runner(claudePath: binary.path)
        let message = await failure(runner)
        XCTAssertTrue(message.contains("claude не авторизован — откройте claude и войдите"), message)
        XCTAssertTrue(message.contains("Версия: 2.1.289"), message)
        XCTAssertTrue(message.contains("код возврата: 17"), message)
        XCTAssertFalse(message.contains("synthetic-"))
        XCTAssertFalse(message.contains(isolated.project.path))
        XCTAssertFalse(message.contains("example.invalid"))
        XCTAssertLessThan(message.count, 300)
        try FileManager.default.removeItem(at: isolated.project.appendingPathComponent("executor-error.txt"))
        let answer = try await runner.run(request(), onActivity: { _ in })
        XCTAssertFalse(answer.isError)
        XCTAssertEqual(answer.text, "fixture answer")
    }

    func testUnknownStderrIsNeverEchoed() async throws {
        try write("executor-error.txt", String(repeating: "arbitrary-private-value\n", count: 700))
        let message = await failure(isolated.runner(claudePath: binary.path))
        XCTAssertTrue(message.contains("claude не запускается"), message)
        XCTAssertTrue(message.contains("код возврата: 17"), message)
        XCTAssertTrue(message.contains("ответ не получен"), message)
        XCTAssertFalse(message.contains("arbitrary-private-value"))
        XCTAssertLessThan(message.count, 300)
    }

    func testAuthenticationErrorInJSONResultUsesTheSameSafeDiagnostic() async throws {
        for result in [
            #"{"type":"result","is_error":true,"result":"Invalid API key: synthetic-credential"}"#,
            #"{"type":"result","is_error":true,"errors":["authentication_error: synthetic-credential"]}"#
        ] {
            try write("executor-result.txt", result)
            let message = await failure(isolated.runner(claudePath: binary.path))
            XCTAssertTrue(message.contains("claude не авторизован"), message)
            XCTAssertTrue(message.contains("код возврата: 0"), message)
            XCTAssertFalse(message.contains("synthetic-credential"))
        }
    }

    func testVersionCommandFailureHasItsOwnExitCodeWithoutStartingExecutor() async throws {
        try write("version.txt", "auth-error")
        let message = await failure(isolated.runner(claudePath: binary.path))
        XCTAssertTrue(message.contains("claude не авторизован"), message)
        XCTAssertTrue(message.contains("Версия: не определена"), message)
        XCTAssertTrue(message.contains("код возврата: 7"), message)
        XCTAssertFalse(message.contains("synthetic-credential"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.project.appendingPathComponent("runs").path))
    }

    func testSpawnFailureDoesNotExposeItsWorkingDirectory() async throws {
        var req = request()
        let checker = isolated.preflight()
        _ = try await checker.prepare(selectedPath: binary.path, request: req, onActivity: { _ in })
        req.agent.folder = isolated.root.appendingPathComponent("missing-private-directory").path
        do {
            _ = try await isolated.runner(claudePath: binary.path, preflight: checker).run(req, onActivity: { _ in })
            XCTFail("missing cwd should refuse the spawn")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("claude не запускается"), message)
            XCTAssertTrue(message.contains("Версия: 2.1.289"), message)
            XCTAssertTrue(message.contains("код возврата: нет"), message)
            XCTAssertFalse(message.contains("missing-private-directory"))
            XCTAssertFalse(message.contains(isolated.root.path))
        }
    }
}
