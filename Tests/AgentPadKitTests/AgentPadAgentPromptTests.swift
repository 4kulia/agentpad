import Foundation
import XCTest
@testable import AgentPadKit

final class AgentPadAgentPromptTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-prompt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Execute the shipped shim in a PTY against a synthetic Claude. No real
    /// agent, user configuration, credentials or Application Support writes.
    private func launch(settings: [String: Any] = [:], custom: String? = nil,
                        help: String = "  --append-system-prompt <prompt>  Append text",
                        helpExit: Int = 0, hangingHelp: Bool = false,
                        arguments: [String] = ["--model", "test", "user's question"],
                        surface: Bool = true, tty: Bool = true) throws -> [String] {
        let shimDir = directory.appendingPathComponent("shim")
        let realDir = directory.appendingPathComponent("real")
        for dir in [shimDir, realDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let shim = shimDir.appendingPathComponent("claude")
        let fake = realDir.appendingPathComponent("claude")
        let capture = directory.appendingPathComponent("argv")
        let override = directory.appendingPathComponent("custom prompt.md")
        if let custom { try custom.write(to: override, atomically: true, encoding: .utf8) }
        try AgentPadShellIntegration.claudeWrapperScript.write(to: shim, atomically: true, encoding: .utf8)
        let fakeScript = """
        #!/bin/bash
        if [[ "$1" == "--help" ]]; then
            \(hangingHelp ? "exec /bin/sleep 20" : "printf '%s' \(AgentPadShellIntegration.quote(help))")
            exit \(helpExit)
        fi
        printf '%s\\0' "$@" > "$CAPTURE"
        """
        try fakeScript.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        var env = AgentPadAgentPrompt.environment(settings: settings, override: override)
        env["PATH"] = "\(realDir.path):/usr/bin:/bin"
        env["CAPTURE"] = capture.path
        env["AGENTPAD_HOOKS_PATH"] = directory.appendingPathComponent("hooks.json").path
        if surface { env["AGENTPAD_SURFACE_ID"] = "test-tab" }
        try? FileManager.default.removeItem(at: capture)
        let process = Process()
        process.currentDirectoryURL = directory
        process.environment = env
        process.executableURL = URL(fileURLWithPath: tty ? "/usr/bin/script" : "/bin/bash")
        process.arguments = (tty ? ["-q", "/dev/null", "/bin/bash", shim.path] : [shim.path]) + arguments
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: capture).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    func testOrdinaryTabGetsBundledPromptAsOneLiteralArgument() throws {
        let argv = try launch()
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        let text = try String(contentsOf: XCTUnwrap(AgentPadAgentPrompt.builtInURL), encoding: .utf8)
        XCTAssertEqual(argv[index + 1], text.trimmingCharacters(in: .newlines))
        XCTAssertEqual(Array(argv.suffix(3)), ["--model", "test", "user's question"])
        XCTAssertTrue(text.contains("chat_post"))
        XCTAssertTrue(text.contains("thread_root_id"))
    }

    func testUserFileReplacesBuiltinWithoutShellExpansion() throws {
        let custom = "Owner's context\nKeep $HOME and $(touch forbidden) and `commands` literal."
        let argv = try launch(custom: custom)
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        XCTAssertEqual(argv[index + 1], custom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
    }

    func testDisabledSkipsEvenTheUserFile() throws {
        XCTAssertTrue(AgentPadAgentPrompt.isEnabled(in: [:]))
        let argv = try launch(settings: ["agents": ["agentPadPrompt": false]], custom: "owner context")
        XCTAssertFalse(argv.contains("--append-system-prompt"))
    }

    func testOldClaudeAndFailedProbeStillLaunch() throws {
        XCTAssertFalse(try launch(help: "--append-system-prompt-file <file>").contains("--append-system-prompt"))
        XCTAssertFalse(try launch(helpExit: 1).contains("--append-system-prompt"))
    }

    func testUnresponsiveProbeIsBoundedAndStillLaunches() throws {
        let start = Date()
        XCTAssertFalse(try launch(hangingHelp: true).contains("--append-system-prompt"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testExplicitPromptAndBareModeWin() throws {
        XCTAssertFalse(try launch(arguments: ["--bare"]).contains("--append-system-prompt"))
        let argv = try launch(arguments: ["--append-system-prompt", "explicit"])
        XCTAssertEqual(argv.filter { $0 == "--append-system-prompt" }.count, 1)
        XCTAssertEqual(argv.last, "explicit")
    }

    func testOutsideAgentPadAndPipeDrivenInvocationsStayUnchanged() throws {
        let original = ["-p", "question"]
        XCTAssertEqual(try launch(arguments: original, surface: false), original)
        XCTAssertEqual(try launch(arguments: original, tty: false), original)
    }

    func testExecutorKeepsOnlyItsOwnContextAndDropsTabPromptEnvironment() throws {
        let request = TeamRunRequest(agent: TeamPublishedAgent(name: "test", description: "test", folder: directory.path, access: .read),
                                     prompt: "question", sessionId: UUID().uuidString.lowercased(), resume: false, callerName: "Colleague", callerProject: nil)
        let argv = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: directory, visibility: .init(channelIds: []))
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        XCTAssertEqual(argv[index + 1], ClaudeCodeRunner.systemPrompt(for: request))
        XCTAssertFalse(argv[index + 1].contains("This tab is a personal session"))
        let env = ClaudeCodeRunner.environment(claudePath: "/synthetic/claude", base: AgentPadAgentPrompt.environment(settings: [:], override: directory))
        XCTAssertNil(env["AGENTPAD_AGENT_PROMPT_PATH"])
        XCTAssertNil(env["AGENTPAD_AGENT_PROMPT_OVERRIDE"])
    }
}
