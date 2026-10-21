import XCTest
import Darwin
@testable import AgentPadKit

@MainActor
final class ClaudeAccountLaunchTests: XCTestCase {
    private var root: URL!
    private var tokens: MemoryClaudeTokens!
    private var profiles: AgentProfileStore!
    private var owners: [WorkspaceStore] = []
    private var engines: [TestEngine] = []
    private var secret: String!
    private var launchError = ""

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/tmp/account-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // An isolated, unborn Git fixture stops discovery at this root. No
        // branch/worktree operation runs in the checkout, and all writes below
        // use explicit fixture paths regardless of discovery's result.
        let git = root.appendingPathComponent(".git")
        for directory in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: git.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        try Data("[core]\nrepositoryformatversion = 0\nbare = false\n".utf8).write(to: git.appendingPathComponent("config"))
        tokens = MemoryClaudeTokens(); secret = UUID().uuidString
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"), accountTokens: tokens)
    }
    override func tearDown() async throws {
        owners.forEach { $0.terminate() }; owners = []
        // Test-owned sources still get removed if a cleanup regression fails.
        for source in engines.flatMap(\.startedConfigs).compactMap(\.claudeAccountLaunch) {
            let directory = source.fileURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        try profiles.flush()
        try FileManager.default.removeItem(at: root)
    }
    private var settings: ClaudeAccountSettings {
        .init(homeDirectory: root.appendingPathComponent("user-home"), environment: [:],
              managedSettings: root.appendingPathComponent("managed/managed-settings.json"))
    }
    private func owner(persistence: InMemoryPersistence = InMemoryPersistence(), projects: URL? = nil,
                       deferred: Bool = false) -> WorkspaceStore {
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            sessionNames: .testing,
            engineFactory: { [weak self] in
                let engine = TestEngine()
                engine.preparesClaudeAccountLaunch = !deferred
                self?.engines.append(engine)
                return engine
            },
            optionsProvider: { _ in "--model global" }, resumeProvider: { true },
            conversationVisibility: { .init(channelIds: []) }, peerStores: { [] },
            claudeProjectsRoot: projects ?? root.appendingPathComponent("empty-projects"))
        owners.append(store); return store
    }
    private func assignedProfile() throws -> (AgentProfile, ClaudeAccount) {
        let account = try profiles.claudeAccounts.add(name: "Work", token: secret)
        let profile = try profiles.add(template: .claudeCode, folder: root, name: "Reviewer", launchOptions: "--model opus")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        return (try XCTUnwrap(profiles.profile(profile.id)), account)
    }
    private func config(_ session: Session) throws -> TerminalSessionConfig {
        try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last)
    }
    private func launch(token: String? = nil, timeout: TimeInterval = 60) -> ClaudeAccountLaunch {
        let value = token ?? secret!
        return ClaudeAccountLaunch(accountName: "Work",
                                   temporaryDirectory: root, timeout: timeout) { value }
    }
    private func assertToken(_ session: Session, equals expected: String) throws {
        let config = try config(session)
        XCTAssertTrue(config.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let source = try XCTUnwrap(config.claudeAccountLaunch)
        XCTAssertTrue(try Data(contentsOf: source.fileURL) == Data((expected + "\n").utf8))
    }

    private func runLaunch(
        _ config: TerminalSessionConfig,
        childCheck: String,
        environment: [String: String] = [:],
        startup: String? = nil,
        shell: String = "/bin/zsh",
        childShell: String = "/bin/sh",
        afterLaunch: String = "exit $?",
        helper: URL? = nil
    ) throws -> Int32 {
        launchError = ""
        let onFailure = config.claudeAccountLaunch?.onFailure
        config.claudeAccountLaunch?.onFailure = { [weak self] message in
            self?.launchError = message
            onFailure?(message)
        }
        guard config.claudeAccountLaunch?.prepare() ?? true else {
            return -1
        }
        let binary = root.appendingPathComponent("claude")
        try Data("#!\(childShell)\n\(childCheck)\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        if let startup {
            try Data(startup.utf8).write(to: root.appendingPathComponent(".zshrc"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.currentDirectoryURL = root
        let command = "eval \"$AGENTPAD_AGENT\"\n\(afterLaunch)"
        process.arguments = shell == "/bin/bash"
            ? ["--noprofile", "--rcfile", root.appendingPathComponent(".zshrc").path, "-i", "-c", command]
            : [startup == nil ? "-f" : "-d", "-i", "-c", command]
        process.environment = ["PATH": root.path + ":/usr/bin:/bin", "HOME": root.path, "ZDOTDIR": root.path]
        process.environment?.merge(config.environment) { _, value in value }
        if config.environment["AGENTPAD_HOOKS_PATH"] != nil {
            // TestEngine does not install shell integration's generated hooks.
            // Supply a harmless fixture instead of using the user's real file.
            let hooks = root.appendingPathComponent("generated-hooks.json")
            try Data(#"{"hooks":{}}"#.utf8).write(to: hooks)
            process.environment?["AGENTPAD_HOOKS_PATH"] = hooks.path
        }
        process.environment?.merge(environment) { _, value in value }
        let helper = helper ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/agentpad-cli")
        process.environment?["AGENTPAD_AGENT"] = config.environment["AGENTPAD_AGENT"]?
            .replacingOccurrences(of: AgentPadShellIntegration.agentPadCLIBinaryPath, with: helper.path)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty,
                      "The launch must never print credentials")
        launchError = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(launchError.contains(secret))
        return process.terminationStatus
    }

    func testMissingHelperExplainsHowToRepairLaunchAndRemovesCredentialSource() throws {
        let source = launch()
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: source)
        let marker = root.appendingPathComponent("started")
        XCTAssertEqual(try runLaunch(config,
            childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))",
            helper: root.appendingPathComponent("missing-agentpad-cli")), 1)
        XCTAssertEqual(launchError,
            "Claude account “Work” could not start because agentpad-cli is unavailable or does not support claude-account-check. Rebuild AgentPad or reinstall the app.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.deletingLastPathComponent().path))
    }

    func testOutdatedHelperExplainsHowToRepairLaunchAndRemovesCredentialSource() throws {
        let helper = root.appendingPathComponent("outdated-agentpad-cli")
        try Data("#!/bin/sh\nprintf '%s\\n' \"agentpad-cli: unknown command 'claude-account-check'\" >&2\nexit 1\n".utf8)
            .write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let source = launch()
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: source)
        let marker = root.appendingPathComponent("started")
        XCTAssertEqual(try runLaunch(config,
            childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))", helper: helper), 1)
        XCTAssertEqual(launchError,
            "Claude account “Work” could not start because agentpad-cli is unavailable or does not support claude-account-check. Rebuild AgentPad or reinstall the app.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.deletingLastPathComponent().path))
    }

    func testGatewayURLIsRemovedTogetherWithGatewayCredential() throws {
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
        XCTAssertEqual(try runLaunch(config,
            childCheck: #"test -n "$CLAUDE_CODE_OAUTH_TOKEN" && test -z "${ANTHROPIC_BASE_URL+x}" && test -z "${ANTHROPIC_AUTH_TOKEN+x}""#,
            environment: ["ANTHROPIC_BASE_URL": "https://gateway.invalid", "ANTHROPIC_AUTH_TOKEN": UUID().uuidString]), 0)
    }

    func testSettingsCannotOverrideOAuthOrRouteItToGateway() throws {
        let file = settings.homeDirectory.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"] {
            try JSONSerialization.data(withJSONObject: ["env": [key: secret!]]).write(to: file)
            let failure = settings.failure(accountName: "Work", folder: root)
            XCTAssertTrue(failure?.contains(file.path) == true)
            XCTAssertTrue(failure?.contains("env." + key) == true)
            XCTAssertFalse((failure ?? "").contains(secret))
        }
    }

    func testPreflightUsesConfigDirectoryAndWorkingDirectoryAfterShellStartup() throws {
        let alternate = root.appendingPathComponent("after-rc")
        let project = root.appendingPathComponent("after-cd")
        for file in [alternate.appendingPathComponent("settings.json"),
                     project.appendingPathComponent(".claude/settings.local.json")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["apiKeyHelper": secret!]).write(to: file)
        }
        for (startup, file) in [
            ("export CLAUDE_CONFIG_DIR=\(AgentPadShellIntegration.quote(alternate.path))",
             alternate.appendingPathComponent("settings.json")),
            ("cd \(AgentPadShellIntegration.quote(project.path))",
             project.appendingPathComponent(".claude/settings.local.json")),
        ] {
            let marker = root.appendingPathComponent("started")
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            let status = try runLaunch(config, childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))",
                                       startup: startup + "\n")
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(launchError.contains(file.path))
            XCTAssertTrue(launchError.contains("apiKeyHelper"))
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testPreflightChecksShellWrapperSettingsAfterStartup() throws {
        let file = root.appendingPathComponent("wrapper-settings.json")
        let marker = root.appendingPathComponent("started")
        let startup = "export AGENTPAD_HOOKS_PATH=wrapper-settings.json\n"
        for contents in [
            ["env": ["ANTHROPIC_BASE_URL": secret!]] as [String: Any],
            ["env": ["CLAUDE_CODE_OAUTH_TOKEN": secret!]],
            ["apiKeyHelper": secret!],
        ] {
            try JSONSerialization.data(withJSONObject: contents).write(to: file)
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            XCTAssertNotEqual(try runLaunch(config,
                childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))",
                environment: ["AGENTPAD_SURFACE_ID": UUID().uuidString], startup: startup), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(launchError.contains(file.path))
            try? FileManager.default.removeItem(at: marker)
        }
        // A hook source containing no authentication settings still launches.
        try Data(#"{"hooks":{}}"#.utf8).write(to: file)
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
        XCTAssertEqual(try runLaunch(config, childCheck: "test -n \"$CLAUDE_CODE_OAUTH_TOKEN\"",
            environment: ["AGENTPAD_SURFACE_ID": UUID().uuidString], startup: startup), 0)
    }

    func testShellWrapperSettingsMustBeAReadableFileWithoutEchoingInlineValues() throws {
        let inline = String(decoding: try JSONSerialization.data(withJSONObject:
            ["env": ["CLAUDE_CODE_OAUTH_TOKEN": secret!]]), as: UTF8.self)
        let marker = root.appendingPathComponent("started")
        for path in [inline, "missing-wrapper-settings.json"] {
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            XCTAssertNotEqual(try runLaunch(config,
                childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))",
                environment: ["AGENTPAD_SURFACE_ID": UUID().uuidString, "AGENTPAD_HOOKS_PATH": path]), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(launchError.contains("AGENTPAD_HOOKS_PATH"))
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testPreflightIncludesRepositoryRootMainCheckoutAndManagedFragments() throws {
        // A minimal Git fixture, including the standard linked-checkout metadata.
        // No branch/worktree operation touches the user's checkout.
        let main = root.appendingPathComponent("repository")
        let git = main.appendingPathComponent(".git")
        let linked = root.appendingPathComponent("linked")
        let metadata = git.appendingPathComponent("worktrees/linked")
        for directory in [git.appendingPathComponent("objects"), git.appendingPathComponent("refs"),
                          metadata, linked.appendingPathComponent("subfolder"), main.appendingPathComponent("subfolder")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        try Data("[core]\nrepositoryformatversion = 0\nbare = false\n".utf8).write(to: git.appendingPathComponent("config"))
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
        try Data("../..\n".utf8).write(to: metadata.appendingPathComponent("commondir"))
        try Data((linked.appendingPathComponent(".git").path + "\n").utf8).write(to: metadata.appendingPathComponent("gitdir"))
        try Data(("gitdir: " + metadata.path + "\n").utf8).write(to: linked.appendingPathComponent(".git"))
        let fragment = settings.managedSettings.deletingLastPathComponent()
            .appendingPathComponent("managed-settings.d/20-auth.json")
        for file in [main.appendingPathComponent(".claude/settings.json"),
                     main.appendingPathComponent(".claude/settings.local.json"), fragment] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["apiKeyHelper": secret!]).write(to: file)
            for folder in [main.appendingPathComponent("subfolder"), linked.appendingPathComponent("subfolder")] {
                let failure = settings.failure(accountName: "Work", folder: folder)
                XCTAssertTrue(failure?.contains(file.path) == true)
                XCTAssertFalse((failure ?? "").contains(secret))
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    func testNonMainProfilesRefuseSettingsOptionsAtSaveAndLaunch() throws {
        let account = try profiles.claudeAccounts.add(name: "Work", token: secret)
        for options in ["--settings alternate.json", "--settings='{\"env\":{}}'", "--setting-sources user,project"] {
            let profile = try profiles.add(template: .claudeCode, folder: root, launchOptions: options)
            XCTAssertThrowsError(try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id))
            XCTAssertThrowsError(try profiles.editProfile(profile.id, name: profile.name, claudeAccountID: account.id))
            let marker = root.appendingPathComponent("started")
            let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: options, claudeAccountLaunch: launch())
            XCTAssertNotEqual(try runLaunch(config, childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(launchError.contains("--settings") || launchError.contains("--setting-sources"))
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testBashStartupHooksCannotRestoreCredentialsInClaudeShim() throws {
        let injection = root.appendingPathComponent("bash-env")
        try Data("export ANTHROPIC_AUTH_TOKEN=injected\nexport CLAUDE_CODE_OAUTH_TOKEN=injected\n".utf8).write(to: injection)
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
        XCTAssertEqual(try runLaunch(config,
            childCheck: #"IFS= read -r expected; test "$CLAUDE_CODE_OAUTH_TOKEN" = "$expected" && test -z "${ANTHROPIC_AUTH_TOKEN+x}" && test -z "${BASH_ENV+x}" && test -z "${ENV+x}""#,
            environment: ["BASH_ENV": injection.path, "ENV": injection.path], childShell: "/bin/bash"), 0)
    }

    func testAllProviderFlagsAreRemovedAndRejectedInSettings() throws {
        for key in ["CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_FUTURE_PROVIDER"] {
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            XCTAssertEqual(try runLaunch(config,
                childCheck: "test -n \"$CLAUDE_CODE_OAUTH_TOKEN\" && test -z \"${\(key)+x}\"",
                startup: "export \(key)=1\n"), 0)
            let file = root.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["env": [key: "1"]]).write(to: file)
            XCTAssertTrue(settings.failure(accountName: "Work", folder: root)?.contains(key) == true)
            try FileManager.default.removeItem(at: file)
        }
    }

    func testAppStartupSweepsOrphanedTokenFiles() throws {
        let value = secret!
        let privateRoot = root.appendingPathComponent("private-sources")
        let orphan = ClaudeAccountLaunch(accountName: "Work", temporaryDirectory: privateRoot) { value }
        XCTAssertTrue(orphan.prepare())
        let directory = orphan.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: privateRoot.path)[.posixPermissions] as? Int, 0o700)
        let extra = privateRoot.appendingPathComponent("interrupted-write/nested")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("keep")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: privateRoot.appendingPathComponent("link"),
                                                  withDestinationURL: outside)
        let leftover = directory.appendingPathComponent("unfinished")
        try Data().write(to: leftover)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.fileURL.path))
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: root.appendingPathComponent("windows.json")),
                                   agentProfiles: profiles, claudeTokenDirectory: privateRoot)
        withExtendedLifetime(delegate) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.fileURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateRoot.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: privateRoot.path)[.posixPermissions] as? Int, 0o700)
    }

    func testAppStartupSweepsSourcesLeftByPreviousVersion() throws {
        // Recreate the previous version's source without its in-process timer
        // or deinit cleanup, as after Force Quit.
        let legacy = root.appendingPathComponent("previous-version")
        let directory = legacy
            .appendingPathComponent("agentpad-claude-\(getuid())-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("oauth")
        try Data((secret + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = legacy.appendingPathComponent("keep")
        try Data().write(to: unrelated)
        let link = legacy.appendingPathComponent("agentpad-claude-\(getuid())-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: root.appendingPathComponent("windows.json")),
                                   agentProfiles: profiles, claudeTokenDirectory: root.appendingPathComponent("private-sources"),
                                   legacyClaudeTokenDirectory: legacy)
        withExtendedLifetime(delegate) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testShellStartupCannotReplaceSelectedAccount() throws {
        for shell in ["/bin/zsh", "/bin/bash"] {
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            let status = try runLaunch(config,
                childCheck: #"IFS= read -r expected; test "$CLAUDE_CODE_OAUTH_TOKEN" = "$expected""#,
                startup: "export CLAUDE_CODE_OAUTH_TOKEN=from-shell-startup\n", shell: shell)
            XCTAssertEqual(status, 0, "The selected account must win after the user's rc files in \(shell)")
        }
    }

    func testInheritedProviderFlagsCannotOverrideSelectedAccount() throws {
        for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
            let status = try runLaunch(config,
                childCheck: "test -n \"$CLAUDE_CODE_OAUTH_TOKEN\" && test -z \"${\(key)+x}\"",
                environment: [key: "1"])
            XCTAssertEqual(status, 0, "\(key) must be absent in Claude")
        }
    }

    func testSelectedTokenNeverEntersPersistentShellEnvironment() throws {
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
        XCTAssertTrue(config.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let status = try runLaunch(config,
            childCheck: #"IFS= read -r expected; test "$CLAUDE_CODE_OAUTH_TOKEN" = "$expected""#,
            afterLaunch: """
                result=$?
                test "$result" -eq 0 || exit "$result"
                test -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" || exit 41
                /bin/sh -c 'test -z "${CLAUDE_CODE_OAUTH_TOKEN+x}"'
                """)
        XCTAssertEqual(status, 0, "The persistent shell and later commands must have no selected token")
    }

    func testProjectSettingsWithCompetingCredentialsRefuseBeforeStartingClaude() throws {
        let (profile, _) = try assignedProfile(), owner = owner()
        let settingsDirectory = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        for filename in ["settings.json", "settings.local.json"] {
            let file = settingsDirectory.appendingPathComponent(filename)
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                        "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "apiKeyHelper"] {
                let settings: [String: Any] = key == "apiKeyHelper" ? [key: secret!] : ["env": [key: secret!]]
                try JSONSerialization.data(withJSONObject: settings).write(to: file)
                let session = try owner.startAgentProfile(profile.id).get()
                let marker = root.appendingPathComponent("started")
                XCTAssertNotEqual(try runLaunch(config(session),
                    childCheck: "/usr/bin/touch \(AgentPadShellIntegration.quote(marker.path))"), 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                XCTAssertEqual(launchError,
                    "agentpad-cli: Claude account “Work” can’t be used here: \(file.path) sets \(key == "apiKeyHelper" ? key : "env." + key), which Claude Code prefers over the account. Remove it or use Main account.\n")
                XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(session.claudeAccountLaunch).fileURL.path))
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    func testInvalidOrUnreadableProjectSettingsRefuseBeforeStartingClaude() throws {
        let (profile, _) = try assignedProfile(), owner = owner()
        let directory = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for filename in ["settings.json", "settings.local.json"] {
            let file = directory.appendingPathComponent(filename)
            for contents in ["{", "[]"] {
                try Data(contents.utf8).write(to: file)
                let session = try owner.startAgentProfile(profile.id).get()
                XCTAssertNotEqual(try runLaunch(config(session), childCheck: "exit 0"), 0)
                XCTAssertTrue(launchError.contains(file.path))
            }
            try FileManager.default.removeItem(at: file)
            // A directory in place of settings is a deterministic read failure.
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let session = try owner.startAgentProfile(profile.id).get()
            XCTAssertNotEqual(try runLaunch(config(session), childCheck: "exit 0"), 0)
            XCTAssertTrue(launchError.contains(file.path))
            try FileManager.default.removeItem(at: file)
        }
    }

    func testTokenAbsentFromConfigAndCommandUnsetsCompetingCredentials() throws {
        let source = launch()
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", claudeAccountLaunch: source)
        XCTAssertTrue(config.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        let command = try XCTUnwrap(config.environment["AGENTPAD_AGENT"])
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            XCTAssertTrue(command.contains("-u " + key))
        }
        XCTAssertTrue(command.contains("exec claude --model opus"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(config.command.contains(secret))
        XCTAssertFalse(config.arguments.contains { $0.contains(secret) })
        XCTAssertFalse(config.environment.values.contains { $0.contains(secret) })
    }

    func testRealChildSeesOAuthAndNeitherInheritedAPIKey() throws {
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: launch())
        XCTAssertEqual(try runLaunch(config,
            childCheck: #"[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "${ANTHROPIC_API_KEY+x}" ] && [ -z "${ANTHROPIC_AUTH_TOKEN+x}" ]"#,
            environment: ["ANTHROPIC_API_KEY": UUID().uuidString, "ANTHROPIC_AUTH_TOKEN": UUID().uuidString]), 0)
    }

    func testNilAccountCommandsStayByteIdentical() {
        let template = AgentTemplate.claudeCode
        XCTAssertEqual(template.makeSessionConfig(extraOptions: " --model opus ", claudeAccountLaunch: nil).environment["AGENTPAD_AGENT"],
                       "claude --model opus")
        XCTAssertEqual(template.makeSessionConfig(extraOptions: "--model opus", resumeId: "old-session",
            claudeResolution: .success("old-session"), claudeAccountLaunch: nil).environment["AGENTPAD_AGENT"],
            "claude --resume old-session --model opus")
        XCTAssertNil(template.makeSessionConfig().environment["CLAUDE_CODE_OAUTH_TOKEN"])
        let remote = template.makeSessionConfig(sshHost: "host", claudeAccountLaunch: launch())
        XCTAssertNil(remote.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(remote.environment["AGENTPAD_AGENT"], template.makeSessionConfig(sshHost: "host").environment["AGENTPAD_AGENT"])
        XCTAssertNil(AgentTemplate.codex.makeSessionConfig(claudeAccountLaunch: launch()).environment["CLAUDE_CODE_OAUTH_TOKEN"])
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "custom-claude", baseAgentId: "claude-code"))
        XCTAssertNil(custom.makeSessionConfig(claudeAccountLaunch: launch()).environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(custom.makeSessionConfig(claudeAccountLaunch: launch()).environment["AGENTPAD_AGENT"],
                       custom.makeSessionConfig().environment["AGENTPAD_AGENT"])
    }

    func testResumeRefusalRetainsFailureExitWithoutPreparingCredential() throws {
        let source = launch()
        let config = AgentTemplate.claudeCode.makeSessionConfig(resumeId: UUID().uuidString,
            claudeResolution: .failure(.notFound), claudeAccountLaunch: source)
        XCTAssertNil(config.claudeAccountLaunch)
        XCTAssertEqual(config.environment["AGENTPAD_AGENT"], ClaudeSessionResume.Refusal.notFound.shellCommand)
        if let launch = config.claudeAccountLaunch { XCTAssertTrue(launch.prepare()) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", try XCTUnwrap(config.environment["AGENTPAD_AGENT"])]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(secret))
    }

    func testConfigurationDiagnosticsNeverDescribeCredentialValues() {
        // Explicit insertion checks diagnostic redaction independently of launch wiring.
        var config = AgentTemplate.claudeCode.makeSessionConfig()
        config.environment["CLAUDE_CODE_OAUTH_TOKEN"] = secret
        XCTAssertFalse(String(describing: config).contains(secret))
        XCTAssertFalse(String(reflecting: config).contains(secret))
    }

    func testProfileLaunchAndAllPersistedStringsExcludeToken() throws {
        let (profile, _) = try assignedProfile(), owner = owner()
        let session = try owner.startAgentProfile(profile.id).get()
        try assertToken(session, equals: secret)
        owner.applyConversationId(conversationId: UUID().uuidString, sessionId: session.id)
        XCTAssertTrue(owner.flushPersistence())
        let encoder = JSONEncoder()
        let strings = [try encoder.encode(PersistedTab(session)), try encoder.encode(PersistedWorkspace(try XCTUnwrap(owner.active))),
                       try encoder.encode(profile), try encoder.encode(session.launchOrigin), try encoder.encode(profiles.bindings)]
        for data in strings { XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret)) }
        for name in ["agent-profiles.json", "claude-accounts.json", "agent-profile-details.json"] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains(secret))
            }
        }
        XCTAssertFalse(String(describing: try config(session)).contains(secret))
        XCTAssertFalse(owner.agentProfileErrors.values.contains { $0.contains(secret) })
    }

    func testMissingOrUnreadableTokenCreatesFailureTabWithoutStartingProcess() throws {
        let (profile, account) = try assignedProfile(), owner = owner()
        for unreadable in [true, false] {
            tokens.fails = unreadable
            if !unreadable { try tokens.delete(account: account.id.uuidString) }
            let before = engines.reduce(0) { $0 + $1.startedConfigs.count }
            let session = try owner.startAgentProfile(profile.id).get()
            XCTAssertFalse(session.hasProcess)
            XCTAssertEqual(engines.reduce(0) { $0 + $1.startedConfigs.count }, before)
            XCTAssertEqual(session.tabState?.message,
                "Claude account “Work” is unavailable. Replace its token in Settings → Claude accounts.")
            XCTAssertEqual(owner.agentProfileErrors[profile.id], session.tabState?.message)
            XCTAssertEqual(session.unavailableTab?.profileID, profile.id)
            XCTAssertFalse(String(describing: session.tabState?.message).contains(secret))
        }
    }

    func testResumeUsesCurrentProfileAccountIncludingLegacyBinding() throws {
        let (profile, _) = try assignedProfile(), fixture = try ClaudeResumeFixture()
        let record = AgentSessionRecord(agentId: "claude-code", conversationId: fixture.id, title: "Earlier", cwd: root, lastActivity: .now)
        try profiles.bind(record, to: profile.id) // no launch origin, as in older archives
        let replacement = UUID().uuidString
        let current = try profiles.claudeAccounts.add(name: "Current", token: replacement)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: current.id)
        let owner = owner(projects: fixture.root)
        let binding = try XCTUnwrap(profiles.binding(agentID: record.agentId, conversationID: record.conversationId))
        let resumed = try owner.resumeProfileConversation(binding).get()
        try assertToken(resumed, equals: replacement)
        XCTAssertTrue(try XCTUnwrap(config(resumed).environment["AGENTPAD_AGENT"]).contains("--resume " + fixture.id))
        XCTAssertTrue(try XCTUnwrap(config(resumed).environment["AGENTPAD_AGENT"]).hasSuffix("--model global'"),
                      "Legacy provenance must retain its existing option rules")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: nil)
        try assertToken(resumed, equals: replacement)
        let fresh = try owner.startAgentProfile(profile.id).get()
        XCTAssertNil(try config(fresh).environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertEqual(try config(fresh).environment["AGENTPAD_AGENT"], "claude --model opus")
    }

    func testRestoreUsesCurrentAccountAndPreservesFailedTerminalForRetry() throws {
        let (profile, account) = try assignedProfile(), disk = InMemoryPersistence()
        let first = owner(persistence: disk)
        let started = try first.startAgentProfile(profile.id).get()
        XCTAssertTrue(first.flushPersistence()); first.terminate()
        let replacement = UUID().uuidString
        try profiles.claudeAccounts.replaceToken(id: account.id, token: replacement)
        let secondDisk = InMemoryPersistence(initial: try XCTUnwrap(disk.saved))
        let second = owner(persistence: secondDisk)
        let restored = try XCTUnwrap(second.allSessions.first { $0.id == started.id })
        try assertToken(restored, equals: replacement)
        XCTAssertTrue(second.flushPersistence()); second.terminate()
        try tokens.delete(account: account.id.uuidString)
        let thirdDisk = InMemoryPersistence(initial: try XCTUnwrap(secondDisk.saved))
        let third = owner(persistence: thirdDisk)
        let failed = try XCTUnwrap(third.allSessions.first { $0.id == started.id })
        XCTAssertFalse(failed.hasProcess)
        XCTAssertEqual(failed.unavailableTab?.id, started.id)
        XCTAssertTrue(third.flushPersistence()); third.terminate()
        try profiles.claudeAccounts.replaceToken(id: account.id, token: replacement)
        let fourth = owner(persistence: InMemoryPersistence(initial: try XCTUnwrap(thirdDisk.saved)))
        let retried = try XCTUnwrap(fourth.allSessions.first { $0.id == started.id })
        XCTAssertTrue(retried.hasProcess)
        try assertToken(retried, equals: replacement)
    }

    func testSettingsPathsHonorConfigDirectoryAndIncludeManagedSettings() {
        var settings = self.settings
        let projectFiles = [root.appendingPathComponent(".claude/settings.json"),
                            root.appendingPathComponent(".claude/settings.local.json"), settings.managedSettings]
        XCTAssertEqual(settings.files(in: root), [settings.homeDirectory.appendingPathComponent(".claude/settings.json")] + projectFiles)
        let alternate = root.appendingPathComponent("alternate config")
        settings.environment["CLAUDE_CONFIG_DIR"] = alternate.path
        XCTAssertEqual(settings.files(in: root), [alternate.appendingPathComponent("settings.json")] + projectFiles)
        settings.environment["CLAUDE_CONFIG_DIR"] = "relative-config"
        XCTAssertEqual(settings.files(in: root), [root.appendingPathComponent("relative-config/settings.json")] + projectFiles)
        XCTAssertEqual(ClaudeAccountSettings().managedSettings.path,
                       "/Library/Application Support/ClaudeCode/managed-settings.json")
    }

    func testUserConfigDirectoryAndManagedSettingsRejectEveryCompetingKey() throws {
        var alternate = settings
        alternate.environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("alternate").path
        let userFile = settings.homeDirectory.appendingPathComponent(".claude/settings.json")
        let alternateFile = root.appendingPathComponent("alternate/settings.json")
        for (settings, userSettingsFile) in [(self.settings, userFile), (alternate, alternateFile)] {
            for file in [userSettingsFile, settings.managedSettings] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                            "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "apiKeyHelper"] {
                    let json: [String: Any] = key == "apiKeyHelper" ? [key: secret!] : ["env": [key: secret!]]
                    try JSONSerialization.data(withJSONObject: json).write(to: file)
                    let failure = settings.failure(accountName: "Work", folder: root)
                    XCTAssertEqual(failure,
                        "Claude account “Work” can’t be used here: \(file.path) sets \(key == "apiKeyHelper" ? key : "env." + key), which Claude Code prefers over the account. Remove it or use Main account.")
                    XCTAssertFalse((failure ?? "").contains(secret))
                }
                for invalid in ["{", "[]"] {
                    try Data(invalid.utf8).write(to: file)
                    XCTAssertTrue(settings.failure(accountName: "Work", folder: root)?.contains(file.path) == true)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
                XCTAssertTrue(settings.failure(accountName: "Work", folder: root)?.contains(file.path) == true)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func testMainIgnoresConflictingAndInvalidSettingsAndBenignSettingsAllowAccount() throws {
        let (profile, _) = try assignedProfile(), owner = owner()
        // Never write to discovered settings paths: Git discovery can include
        // real checkout roots if a fixture is accidentally placed in a repo.
        let fixtureFiles = [
            settings.homeDirectory.appendingPathComponent(".claude/settings.json"),
            root.appendingPathComponent(".claude/settings.json"),
            root.appendingPathComponent(".claude/settings.local.json"), settings.managedSettings,
        ]
        for file in fixtureFiles {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["env": ["EDITOR": "vi"], "permissions": ["allow": []]]).write(to: file)
        }
        let selected = try owner.startAgentProfile(profile.id).get()
        try assertToken(selected, equals: secret)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: nil)
        for file in fixtureFiles {
            try JSONSerialization.data(withJSONObject: ["apiKeyHelper": secret!]).write(to: file)
        }
        let main = try owner.startAgentProfile(profile.id).get()
        XCTAssertEqual(try config(main).environment["AGENTPAD_AGENT"], "claude --model opus")
        XCTAssertNil(try config(main).claudeAccountLaunch)
        try Data("{".utf8).write(to: settings.managedSettings)
        let invalid = try owner.startAgentProfile(profile.id).get()
        XCTAssertEqual(try config(invalid).environment["AGENTPAD_AGENT"], "claude --model opus")
        XCTAssertNil(try config(invalid).claudeAccountLaunch)
    }

    func testOneShotSourcePermissionsRemovalAndNoTokenInLiveParentOrArgv() throws {
        let source = launch()
        let config = AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: source)
        XCTAssertTrue(source.prepare())
        let directory = source.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.fileURL.path)[.posixPermissions] as? Int, 0o600)
        let pidFile = root.appendingPathComponent("child-pid")
        let binary = root.appendingPathComponent("claude")
        try Data("""
            #!/bin/sh
            test ! -e "$SOURCE_FILE" && test ! -e "$SOURCE_DIRECTORY" || exit 51
            IFS= read -r expected
            test "$CLAUDE_CODE_OAUTH_TOKEN" = "$expected" || exit 52
            printf '%s' "$$" > "$CHILD_PID_FILE"
            IFS= read -r finish
            """.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", """
            eval "$AGENTPAD_AGENT"
            result=$?
            test "$result" -eq 0 || exit "$result"
            test -z "${CLAUDE_CODE_OAUTH_TOKEN+x}" || exit 53
            /bin/sh -c 'test -z "${CLAUDE_CODE_OAUTH_TOKEN+x}"'
            """]
        process.environment = ["PATH": root.path + ":/usr/bin:/bin", "SOURCE_FILE": source.fileURL.path,
                               "SOURCE_DIRECTORY": directory.path, "CHILD_PID_FILE": pidFile.path,
                               "HOME": root.path, "CLAUDE_CONFIG_DIR": root.appendingPathComponent("user-home/.claude").path]
        process.currentDirectoryURL = root
        process.environment?.merge(config.environment) { _, value in value }
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/agentpad-cli")
        process.environment?["AGENTPAD_AGENT"] = config.environment["AGENTPAD_AGENT"]?
            .replacingOccurrences(of: AgentPadShellIntegration.agentPadCLIBinaryPath, with: helper.path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path), process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "Claude must reach its live-process checkpoint")
        let childPID = try String(contentsOf: pidFile, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // Read only these two fixture processes; never print captured argv/env.
        for (pid, includeEnvironment) in [(String(process.processIdentifier), true), (childPID, false)] {
            let ps = Process(), captured = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = [includeEnvironment ? "eww" : "ww", "-p", pid, "-o", "command="]
            ps.standardOutput = captured
            ps.standardError = FileHandle.nullDevice
            try ps.run()
            let text = String(decoding: captured.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            XCTAssertEqual(ps.terminationStatus, 0)
            XCTAssertFalse(text.contains(secret))
        }
        try input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        // A second invocation cannot reuse the selected token or fall back.
        XCTAssertNotEqual(try runLaunch(config, childCheck: "exit 0"), 0)
    }

    func testSourceIsRemovedOnTimeoutSessionTerminationAndLaunchFailure() async throws {
        let timed = launch(timeout: 0.01)
        XCTAssertTrue(timed.prepare())
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: timed.fileURL.deletingLastPathComponent().path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: timed.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: timed.fileURL.deletingLastPathComponent().path))
        let (profile, _) = try assignedProfile(), owner = owner()
        let terminated = try owner.startAgentProfile(profile.id).get()
        let terminatedFile = try XCTUnwrap(terminated.claudeAccountLaunch).fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminatedFile.path))
        let failed = try owner.startAgentProfile(profile.id).get()
        let failedFile = try XCTUnwrap(failed.claudeAccountLaunch).fileURL
        let launchID = try XCTUnwrap(failed.pendingAgentLaunch?.id)
        (failed.engine as? TestEngine)?.emitTitle(AgentLaunchExitMarker.prefix + launchID.uuidString + ":127")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedFile.path))
        owner.terminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminatedFile.path))
    }

    func testLazyPreparationRechecksTokenDefersSettingsAndRefusesSourceWriteFailure() throws {
        var token = secret!
        let source = ClaudeAccountLaunch(accountName: "Work",
                                        temporaryDirectory: root) { token }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.deletingLastPathComponent().path))
        token = UUID().uuidString
        XCTAssertTrue(source.prepare())
        XCTAssertTrue(try Data(contentsOf: source.fileURL) == Data((token + "\n").utf8))
        source.cleanup()
        let delayed = launch()
        let file = root.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["apiKeyHelper": secret!]).write(to: file)
        var failure: String?
        delayed.onFailure = { failure = $0 }
        XCTAssertTrue(delayed.prepare())
        XCTAssertNil(failure)
        XCTAssertNotEqual(try runLaunch(AgentTemplate.claudeCode.makeSessionConfig(claudeAccountLaunch: delayed),
                                       childCheck: "exit 0"), 0)
        XCTAssertTrue(launchError.contains(file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delayed.fileURL.path))
        try FileManager.default.removeItem(at: file)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let value = secret!
        let unwritable = ClaudeAccountLaunch(accountName: "Work",
                                             temporaryDirectory: blocker) { value }
        unwritable.onFailure = { failure = $0 }
        XCTAssertFalse(unwritable.prepare())
        XCTAssertEqual(failure, "Claude account “Work” is unavailable. Replace its token in Settings → Claude accounts.")
        XCTAssertFalse((failure ?? "").contains(secret))
    }

    func testDeferredLaunchFailuresUseExistingFailureTabAndPreserveRetryState() throws {
        let (profile, account) = try assignedProfile(), owner = owner(deferred: true)
        for unreadable in [true, false] {
            let session = try owner.startAgentProfile(profile.id).get()
            XCTAssertNil(session.claudeAccountLaunch)
            var config = try config(session)
            let saved = PersistedTab(session)
            tokens.fails = unreadable
            if !unreadable { try tokens.delete(account: account.id.uuidString) }
            XCTAssertFalse(config.prepareForProcessStart())
            XCTAssertFalse(session.hasProcess)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(session.unavailableTab), try encoder.encode(Optional(saved)))
            XCTAssertEqual(session.profileID, profile.id)
            XCTAssertEqual(owner.agentProfileErrors[profile.id], session.tabState?.message)
            XCTAssertTrue(owner.flushPersistence())
            XCTAssertFalse((session.tabState?.message ?? "").contains(secret))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(config.claudeAccountLaunch).fileURL.path))
            tokens.fails = false
        }
    }
}
