import Foundation
import XCTest
@testable import AgentPadKit

final class AgentPadAgentPromptTests: XCTestCase {
    private var directory: URL!
    private let codexContextEnabled: [String: Any] = ["agents": ["codexAgentPadPrompt": true]]

    private static let hasTOMLParser: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-c", "import tomllib"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agentpad-prompt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A synthetic project boundary and HOME keep the resolver away from
        // the developer's real user/project configuration.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Execute the shipped shim in a PTY against a synthetic agent. No real
    /// agent, user configuration, credentials or Application Support writes.
    private func launch(agent: String = "claude", settings: [String: Any] = [:], custom: String? = nil,
                        help: String = "  --append-system-prompt <prompt>  Append text",
                        helpExit: Int = 0, hangingHelp: Bool = false,
                        arguments: [String] = ["--model", "test", "user's question"],
                        surface: Bool = true, tty: Bool = true, hooks: Bool = false,
                        workingDirectory: URL? = nil, environment: [String: String] = [:],
                        pythonStub: String? = nil) throws -> [String] {
        if agent == "codex", pythonStub == nil, !Self.hasTOMLParser {
            throw XCTSkip("Codex context merge tests require Python 3.11+ with tomllib; fallback tests run without it")
        }
        let shimDir = directory.appendingPathComponent("shim")
        let realDir = directory.appendingPathComponent("real")
        for dir in [shimDir, realDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let shim = shimDir.appendingPathComponent(agent)
        let fake = realDir.appendingPathComponent(agent)
        let capture = directory.appendingPathComponent("argv")
        let override = directory.appendingPathComponent("custom prompt.md")
        if let custom { try custom.write(to: override, atomically: true, encoding: .utf8) }
        let script = agent == "claude" ? AgentPadShellIntegration.claudeWrapperScript : AgentPadShellIntegration.codexWrapperScript
        try script.write(to: shim, atomically: true, encoding: .utf8)
        let fakeScript = """
        #!/bin/bash
        if [[ "$1" == "--help" ]]; then
            \(hangingHelp ? "exec /bin/sleep 20" : "printf '%s' \(AgentPadShellIntegration.quote(help))")
            exit \(helpExit)
        fi
        : > "$CAPTURE"
        if [[ $# -gt 0 ]]; then printf '%s\\0' "$@" > "$CAPTURE"; fi
        """
        try fakeScript.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        if let pythonStub {
            let python = realDir.appendingPathComponent("python3")
            try ("#!/bin/bash\n" + pythonStub).write(to: python, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        }
        var env = AgentPadAgentPrompt.environment(settings: settings, override: override)
        env["PATH"] = realDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        env["HOME"] = directory.appendingPathComponent("home").path
        env["CAPTURE"] = capture.path
        env["AGENTPAD_HOOKS_PATH"] = directory.appendingPathComponent("hooks.json").path
        if hooks { env["AGENTPAD_HOOK_BIN"] = "/usr/bin/true" }
        if surface { env["AGENTPAD_SURFACE_ID"] = "test-tab" }
        env.merge(environment) { _, new in new }
        try? FileManager.default.removeItem(at: capture)
        let process = Process()
        process.currentDirectoryURL = workingDirectory ?? directory
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
        return try Data(contentsOf: capture).split(separator: 0, omittingEmptySubsequences: false)
            .dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    private func bundledPrompt() throws -> String {
        try String(contentsOf: XCTUnwrap(AgentPadAgentPrompt.builtInURL), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
    }

    private func claudePrompt(in argv: [String]) throws -> String {
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        return argv[index + 1]
    }

    private func codexPrompt(in argv: [String]) throws -> String {
        let options = Array(argv.prefix(while: { $0 != "--" }))
        let index = try XCTUnwrap(options.lastIndex(where: { $0.hasPrefix("developer_instructions=") }))
        XCTAssertGreaterThan(index, 0)
        XCTAssertEqual(argv[index - 1], "-c")
        // The encoder uses the TOML/JSON common subset of basic string escapes.
        let value = String(argv[index].dropFirst("developer_instructions=".count))
        return try JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private func writeConfig(_ text: String, path: String = "home/.codex/config.toml") throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func projectTrust(_ level: String = "trusted") throws -> String {
        // Foundation may shorten /private/var back to /var on macOS. The
        // resolver uses the physical cwd, so use the POSIX path in fixtures.
        let resolved = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(resolved) }
        return "\n[projects.\"\(String(cString: resolved))\"]\ntrust_level = '\(level)'\n"
    }

    func testOrdinaryTabGetsBundledPromptAsOneLiteralArgument() throws {
        let argv = try launch()
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        let text = try String(contentsOf: XCTUnwrap(AgentPadAgentPrompt.builtInURL), encoding: .utf8)
        XCTAssertEqual(argv[index + 1], text.trimmingCharacters(in: .newlines))
        XCTAssertEqual(Array(argv.suffix(3)), ["--model", "test", "user's question"])
        XCTAssertTrue(text.contains("chat_post"))
        XCTAssertTrue(text.contains("thread_root_id"))
        XCTAssertLessThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 25)
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("http"))
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

    func testAdditionalInstructionAppendsToBothAgentsAsLiteralText() throws {
        let additional = "Owner's \"context\" / правила 🧭\nKeep $HOME, $(touch forbidden), `commands`, \\paths\tand\rcontrols\u{7F} literal."
        let settings: [String: Any] = ["agents": ["codexAgentPadPrompt": true, "agentPadPromptAdditionalInstruction": additional]]
        let expected = try bundledPrompt() + "\n\nAdditional owner instruction:\n" + additional
        XCTAssertEqual(try claudePrompt(in: launch(settings: settings)), expected)
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: settings)), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
    }

    func testAdditionalInstructionAlsoExtendsLegacyOverride() throws {
        let settings: [String: Any] = ["agents": ["agentPadPromptAdditionalInstruction": "Owner addition"]]
        XCTAssertEqual(try claudePrompt(in: launch(settings: settings, custom: "Legacy context")),
                       "Legacy context\n\nAdditional owner instruction:\nOwner addition")
    }

    func testDisabledClearsBothContextsButRetainsTheOwnerSetting() throws {
        let settings: [String: Any] = ["agents": ["agentPadPrompt": false, "agentPadPromptAdditionalInstruction": "Keep this"]]
        XCTAssertEqual(AgentPadAgentPrompt.additionalInstruction(in: settings), "Keep this")
        let env = AgentPadAgentPrompt.environment(settings: settings, override: directory)
        XCTAssertTrue(env.values.allSatisfy(\.isEmpty))
        XCTAssertFalse(try launch(settings: settings).contains("--append-system-prompt"))
        XCTAssertEqual(try launch(agent: "codex", settings: settings, arguments: ["resume", "test-session"]),
                       ["resume", "test-session"])
    }

    func testEmptyAdditionalInstructionDoesNotChangeBuiltin() throws {
        let settings: [String: Any] = ["agents": ["codexAgentPadPrompt": true, "agentPadPromptAdditionalInstruction": " \n\t"]]
        XCTAssertEqual(try claudePrompt(in: launch(settings: settings)), try bundledPrompt())
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: settings)), try bundledPrompt())
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
        for flag in ["--system-prompt", "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file"] {
            for original in [[flag, "explicit"], [flag + "=explicit"]] {
                let argv = try launch(arguments: original)
                XCTAssertEqual(Array(argv.dropFirst(2)), original, "only the existing --settings is added")
            }
        }
    }

    func testClaudeResumeAndForkArgumentsArePreserved() throws {
        for original in [["--resume", UUID().uuidString], ["--continue"],
                         ["--resume", UUID().uuidString, "--fork-session", "--model", "test", "next question"]] {
            let argv = try launch(arguments: original)
            XCTAssertEqual(try claudePrompt(in: argv), try bundledPrompt())
            XCTAssertEqual(Array(argv.suffix(original.count)), original)
        }
    }

    func testIsolatedClaudeArgumentsPassThroughEvenInATabTTY() throws {
        for original in [["--strict-mcp-config", "--mcp-config", "private.json"],
                         ["--setting-sources", ""], ["--setting-sources="],
                         ["-p", "--strict-mcp-config", "--setting-sources", "", "--append-system-prompt", "executor", "question"]] {
            XCTAssertEqual(try launch(arguments: original), original)
        }
    }

    func testClaudePrintAndHelpDoNotReceiveTabPrompt() throws {
        for original in [["-p", "question"], ["--print", "question"], ["--version"]] {
            XCTAssertFalse(try launch(arguments: original).contains("--append-system-prompt"))
        }
    }

    func testEndOfOptionsKeepsPromptLikeFlagsLiteral() throws {
        let original = ["--", "--system-prompt"]
        let argv = try launch(arguments: original)
        XCTAssertEqual(try claudePrompt(in: argv), try bundledPrompt())
        XCTAssertEqual(Array(argv.suffix(original.count)), original)
        let codex = try launch(agent: "codex", settings: codexContextEnabled, arguments: ["--", "exec"])
        XCTAssertEqual(try codexPrompt(in: codex), try bundledPrompt())
        XCTAssertEqual(Array(codex.suffix(2)), ["--", "exec"])
    }

    func testOutsideAgentPadAndPipeDrivenInvocationsStayUnchanged() throws {
        let original = ["-p", "question"]
        XCTAssertEqual(try launch(arguments: original, surface: false), original)
        XCTAssertEqual(try launch(arguments: original, tty: false), original)
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original, surface: false), original)
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original, tty: false), original)
    }

    func testCodexNewAndFixedDirectoryResumeForkPreserveArgumentsAndNotify() throws {
        for original in [[], ["--model", "test", "user's question"],
                         ["resume", UUID().uuidString, "next question", "-C", directory.path],
                         ["resume", "--last", "--cd", directory.path],
                         ["fork", UUID().uuidString, "--cd=\(directory.path)"],
                         ["-C", directory.path, "-c", "model=\"test\"", "resume", "--last"]] {
            let argv = try launch(agent: "codex", settings: codexContextEnabled, arguments: original, hooks: true)
            XCTAssertEqual(try codexPrompt(in: argv), try bundledPrompt())
            XCTAssertEqual(Array(argv.prefix(2)), ["-c", "notify=[\"/usr/bin/true\",\"codex\",\"turn_complete\"]"])
            XCTAssertEqual(Array(argv.dropFirst(2).dropLast(2)), original)
        }
    }

    func testCodexDefaultAndDisabledModesNeverInvokeResolverOrChangeInstructions() throws {
        try writeConfig("developer_instructions = 'user configuration'")
        let config = directory.appendingPathComponent("home/.codex/config.toml")
        let originalConfig = try Data(contentsOf: config)
        let marker = directory.appendingPathComponent("resolver-ran")
        let original = ["-c", "developer_instructions='explicit'", "--", "literal user's question"]
        let disabledSettings: [[String: Any]] = [
            [:],
            ["agents": ["codexAgentPadPrompt": false]],
            ["agents": ["agentPadPrompt": false, "codexAgentPadPrompt": true]],
        ]
        for settings in disabledSettings {
            let env = AgentPadAgentPrompt.environment(settings: settings, override: directory)
            XCTAssertEqual(env["AGENTPAD_AGENT_PROMPT_CODEX_CONFIG"], "")
            if AgentPadAgentPrompt.isEnabled(in: settings) {
                XCTAssertEqual(env["AGENTPAD_AGENT_PROMPT_TEXT"], try bundledPrompt(), "Claude context remains on")
            }
            for hooks in [false, true] {
                try? FileManager.default.removeItem(at: marker)
                let argv = try launch(agent: "codex", settings: settings, arguments: original, hooks: hooks,
                                      environment: ["RESOLVER_MARKER": marker.path],
                                      pythonStub: #"printf ran > "$RESOLVER_MARKER"; printf '%s' 'developer_instructions="unexpected"'"#)
                let notify = hooks ? ["-c", "notify=[\"/usr/bin/true\",\"codex\",\"turn_complete\"]"] : []
                XCTAssertEqual(argv, notify + original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "off means the config resolver does not run at all")
                XCTAssertEqual(try Data(contentsOf: config), originalConfig)
            }
        }
    }

    func testCodexExplicitInstructionsMergeBeforeAndAfterResume() throws {
        try writeConfig("developer_instructions = 'file instructions'")
        for original in [["-c", "developer_instructions=\"explicit\""],
                         ["--config=developer_instructions=\"explicit\""],
                         ["-cdeveloper_instructions=\"explicit\""],
                         ["-c=developer_instructions=\"explicit\""],
                         ["resume", "--last", "-C", directory.path, "--config", "developer_instructions = \"explicit\""],
                         ["-c", "developer_instructions='earlier'", "--config", "developer_instructions='explicit'"]] {
            let argv = try launch(agent: "codex", settings: codexContextEnabled, arguments: original)
            XCTAssertEqual(try codexPrompt(in: argv), "explicit\n\n" + (try bundledPrompt()))
            XCTAssertEqual(Array(argv.dropLast(2)), original)
        }
    }

    func testCodexInstructionFileOverridesStillPassThrough() throws {
        for original in [["-c", "model_instructions_file=\"own.md\""],
                         ["--config", "experimental_instructions_file=\"own.md\""]] {
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
    }

    func testCodexUserTOMLStringsAreParsedAndMergedLiterally() throws {
        let expected = "Owner's \"rules\" 🧭\nKeep $HOME, $(touch forbidden), `touch forbidden`, \\paths\tand\rcontrols\u{7F}.\n"
        try writeConfig(#"""
        # developer_instructions = "not the real value"
        "developer_instructions" = """
        Owner's "rules" 🧭
        Keep $HOME, $(touch forbidden), `touch forbidden`, \\paths\tand\rcontrols\u007F.
        """
        [profiles.unselected]
        developer_instructions = "unused profile"
        [mcp_servers.example]
        developer_instructions = "nested key is not the root key"
        """#)
        let before = try Data(contentsOf: directory.appendingPathComponent("home/.codex/config.toml"))
        let argv = try launch(agent: "codex", settings: codexContextEnabled, custom: "AgentPad context", arguments: [])
        XCTAssertEqual(try codexPrompt(in: argv), expected + "\n\nAgentPad context")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("home/.codex/config.toml")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden").path))
    }

    func testCodexLiteralMultilineAndEmptyInstructions() throws {
        for (toml, expected) in [
            ("developer_instructions = '''\nKeep \\n and # literal\n'''", "Keep \\n and # literal\n\n\ncontext"),
            ("developer_instructions = ''", "context"),
            ("[profiles.unselected]\ndeveloper_instructions = 'unused'", "context"),
        ] {
            try writeConfig(toml)
            XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: [])), expected)
        }
    }

    func testCodexProjectLayersUseLiveCWDAndCDWithClosestValueWinning() throws {
        try writeConfig("developer_instructions = 'user'\n" + projectTrust())
        try writeConfig("developer_instructions = 'project'", path: ".codex/config.toml")
        try writeConfig("developer_instructions = 'closest'", path: "nested/.codex/config.toml")
        let nested = directory.appendingPathComponent("nested")
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: [])), "project\n\ncontext")
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: [], workingDirectory: nested)),
                       "closest\n\ncontext")
        for original in [["-C", "nested"], ["--cd", nested.path], ["--cd=nested"], ["-Cnested"], ["-C=nested"]] {
            let argv = try launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: original)
            XCTAssertEqual(try codexPrompt(in: argv), "closest\n\ncontext")
            XCTAssertEqual(Array(argv.dropLast(2)), original)
        }
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context",
                                                arguments: ["-C", "nested", "-c", "developer_instructions='CLI'"])), "CLI\n\ncontext")
        try writeConfig("model = 'test'", path: "nested/.codex/config.toml")
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: [], workingDirectory: nested)),
                       "project\n\ncontext")
    }

    func testCodexDoesNotPromoteUntrustedOrUndecidedProjectConfig() throws {
        try writeConfig("developer_instructions = 'project'", path: ".codex/config.toml")
        for trust in ["", try projectTrust("untrusted")] {
            try writeConfig("developer_instructions = 'user'\n" + trust)
            let original = ["--model", "test"]
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
    }

    func testCodexSelectedProfilesAlwaysSkipContext() throws {
        try writeConfig("developer_instructions = 'user'\n[profiles.selected]\ndeveloper_instructions = 'profile'")
        for original in [["-p", "selected"], ["--profile", "selected"], ["--profile=selected"],
                         ["-pselected"], ["-p=selected"], ["resume", "--last", "--profile", "selected"],
                         ["-c", "profile='selected'"], ["--config=profile='selected'"]] {
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
        try writeConfig("profile = 'selected'\ndeveloper_instructions = 'user'\n[profiles.selected]\ndeveloper_instructions = 'profile'")
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: []), [])
    }

    func testCodexInvalidOrUnsupportedConfigSkipsContextWithoutChangingArguments() throws {
        let original = ["--model", "test", "-c", "developer_instructions='CLI'"]
        for toml in ["developer_instructions = 'unterminated", "developer_instructions = 42",
                     "developer_instructions = 'one'\ndeveloper_instructions = 'two'",
                     "developer_instructions = 'valid'\n[broken", "model_instructions_file = 'own.md'",
                     "project_root_markers = ['.hg']"] {
            try writeConfig(toml)
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
        try writeConfig("developer_instructions = 'user'\n" + projectTrust())
        try writeConfig("developer_instructions = 'unterminated", path: ".codex/config.toml")
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        let config = directory.appendingPathComponent(".codex/config.toml")
        try Data([0xff, 0xfe]).write(to: config)
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: directory.appendingPathComponent("missing.toml"))
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
    }

    func testCodexAmbiguousArgumentsAndCustomHomeSkipContext() throws {
        for original in [["-c", "developer_instructions=unquoted"], ["-c", "developer_instructions=['array']"],
                         ["-c", "developer_instructions.text='nested'"], ["-c", "developer_instructions='one'\nother='two'"],
                         ["-c"], ["--cd"], ["--cd", "missing-directory"], ["--unknown-option", "value"],
                         ["--model", "--"], ["--image", "--"]] {
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
        let original = ["-c", "developer_instructions='CLI'"]
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original, environment: ["CODEX_HOME": directory.appendingPathComponent("custom-codex").path]), original)
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: [],
                                                environment: ["CODEX_HOME": directory.appendingPathComponent("home/.codex").path])), "context")
    }

    func testCodexMergedOverridePrecedesEndOfOptionsAndFollowsUserOverrides() throws {
        let prefix = ["-c", "developer_instructions='user'"]
        let suffix = ["--", "--profile=literal prompt"]
        let argv = try launch(agent: "codex", settings: codexContextEnabled, custom: "context", arguments: prefix + suffix)
        XCTAssertEqual(try codexPrompt(in: argv), "user\n\ncontext")
        XCTAssertEqual(Array(argv.prefix(prefix.count)), prefix)
        XCTAssertEqual(Array(argv.suffix(suffix.count)), suffix)
    }

    func testCodexResumeAndForkWithoutFixedDirectorySkipContext() throws {
        try writeConfig("developer_instructions = 'user'\n" + projectTrust())
        try writeConfig("developer_instructions = 'project'", path: ".codex/config.toml")
        for original in [["resume", "--last"], ["resume", "--all"], ["resume", UUID().uuidString],
                         ["fork", "--last"], ["fork", UUID().uuidString],
                         ["-c", "developer_instructions='CLI'", "resume", "--last"]] {
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, custom: "context",
                                                arguments: ["resume", "--last", "-C", directory.path])),
                       "project\n\ncontext")
    }

    func testCodexMissingParserLeavesInstructionsAndNotifyIntact() throws {
        let original = ["-c", "developer_instructions='user'"]
        let argv = try launch(agent: "codex", settings: codexContextEnabled, arguments: original, hooks: true, pythonStub: "exit 1")
        XCTAssertEqual(argv, ["-c", "notify=[\"/usr/bin/true\",\"codex\",\"turn_complete\"]"] + original)
    }

    func testCodexUnresponsiveResolverIsBoundedAndStillLaunches() throws {
        let start = Date()
        let original = ["-c", "developer_instructions='user'"]
        XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original, pythonStub: "exec /bin/sleep 20"), original)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testCodexNonInteractiveCommandsDoNotReceiveTabContextInTTY() throws {
        for original in [["exec", "question"], ["review"], ["app-server"], ["mcp", "list"],
                         ["--model", "test", "exec", "question"], ["--version"], ["help", "resume"]] {
            XCTAssertEqual(try launch(agent: "codex", settings: codexContextEnabled, arguments: original), original)
        }
        // An option's value is not a subcommand or an instruction override.
        XCTAssertEqual(try codexPrompt(in: launch(agent: "codex", settings: codexContextEnabled, arguments: ["--model", "review"])), try bundledPrompt())
    }

    func testExecutorKeepsOnlyItsOwnContextAndDropsTabPromptEnvironment() throws {
        let request = TeamRunRequest(agent: TeamPublishedAgent(name: "test", description: "test", folder: directory.path, access: .read),
                                     prompt: "question", sessionId: UUID().uuidString.lowercased(), resume: false, callerName: "Colleague", callerProject: nil)
        let argv = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: directory, visibility: .init(channelIds: []))
        let index = try XCTUnwrap(argv.firstIndex(of: "--append-system-prompt"))
        XCTAssertEqual(argv[index + 1], ClaudeCodeRunner.systemPrompt(for: request))
        XCTAssertFalse(argv[index + 1].contains("This tab is a personal session"))
        let env = ClaudeCodeRunner.environment(claudePath: "/synthetic/claude", base: AgentPadAgentPrompt.environment(settings: [:], override: directory))
        XCTAssertNil(env["AGENTPAD_AGENT_PROMPT_TEXT"])
        XCTAssertNil(env["AGENTPAD_AGENT_PROMPT_CODEX_CONFIG"])
    }
}
