import XCTest
@testable import AgentPadKit

/// The profiles without a shell (owner's decision after Y1) and what the
/// profiles with one say when published.
final class TeamAccessProfileTests: XCTestCase {
    private func args(_ access: TeamAccessProfile) throws -> [String] {
        var agent = TeamPublishedAgent(name: "backend", description: "d", folder: "/p", access: access)
        agent.allowedCommands = ["swift test"]
        return try ClaudeCodeRunner.arguments(for: TeamRunRequest(agent: agent, prompt: "hi", sessionId: "11111111-2222-4333-8444-555555555555", resume: false,
                                                              callerName: "Masha", callerProject: nil))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    func testEditFilesEditsWithoutAShell() throws {
        let args = try args(.editFiles)
        XCTAssertEqual(value(after: "--tools", in: args), "Read,Glob,Grep,Edit,Write")
        XCTAssertEqual(value(after: "--permission-mode", in: args), "dontAsk", "acceptEdits also passes a shell's file commands")
        XCTAssertTrue(args.contains("Edit") && args.contains("Write"), "edits inside the folders are allowed by rule")
        XCTAssertFalse(args.contains { $0.contains("Bash") }, "no shell, so no shell rules either")
        XCTAssertTrue(args.contains("Read(**/.env)"))
        XCTAssertTrue(args.contains("Edit(**/.env)"), "a path never read is never written either")
        XCTAssertTrue(args.contains("Edit(~/.ssh/**)"))
    }

    func testEditAlsoMayNotWriteDeniedPaths() throws {
        XCTAssertTrue(try args(.edit).contains("Edit(**/.env)"))
        XCTAssertFalse(try args(.read).contains { $0.hasPrefix("Edit(") }, "Read has no Edit tool to rule")
    }

    func testWhatEachProfileDoes() {
        XCTAssertEqual(TeamAccessProfile.allCases.filter(\.runsShell), [.readGit, .edit])
        XCTAssertEqual(TeamAccessProfile.allCases.filter(\.usesGit), [.readGit, .edit])
        XCTAssertEqual(TeamAccessProfile.allCases.filter(\.takesCommands), [.edit])
        XCTAssertEqual(TeamAccessProfile(rawValue: "edit-files"), .editFiles)
    }

    func testShellProfilesSayWhatTheShellCanDo() {
        for access in TeamAccessProfile.allCases {
            let lines = TeamPublishWarnings.lines(access: access, fromSession: false, teamNames: [])
            XCTAssertEqual(lines.contains(TeamAccessProfile.shellWarning), access.runsShell, access.rawValue)
        }
        XCTAssertTrue(TeamPublishWarnings.lines(access: .editFiles, fromSession: false, teamNames: [])
            .contains(TeamAccessProfile.editFilesWarning))
    }

    /// The server takes every profile now, Edit files included (server fdb6b70).
    func testEveryProfileIsPublished() {
        for access in TeamAccessProfile.allCases {
            XCTAssertNil(TeamAccessProfile.notOnServerYet([TeamPublishedAgent(name: "a", description: "d", folder: "/p", access: access)]), access.rawValue)
        }
    }

    func testNoSettingsFileAppliesInAnyProfile() throws {
        for access in TeamAccessProfile.allCases {
            let args = try args(access)
            XCTAssertEqual(value(after: "--setting-sources", in: args), "", access.rawValue)
            XCTAssertTrue(args.contains("--restricted") && args.contains("--strict-mcp-config"), access.rawValue)
        }
    }

    /// Y1, row 8: the owner's secrets, Claude Code's redirections and the
    /// loader's and shell's start-up variables reached the agent.
    func testRunsInheritOnlyTheirVariables() {
        let base = [
            "HOME": "/Users/m", "USER": "m", "LOGNAME": "m", "TMPDIR": "/t/", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
            "HTTPS_PROXY": "http://proxy:3128", "PATH": "/Users/m/.nvm/bin:/usr/bin",
            "TWINE_PASSWORD": "s", "AWS_SECRET_ACCESS_KEY": "s", "GITHUB_TOKEN": "s", "OPENAI_API_KEY": "s",
            "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_CODE_FOO": "1", "CLAUDECODE": "1", "AGENTPAD_FOO": "1",
            "DYLD_INSERT_LIBRARIES": "/x.dylib", "LD_PRELOAD": "/x.so", "BASH_ENV": "/x.sh", "ENV": "/x.sh",
            "GIT_SSH_COMMAND": "x", "FOO_PLAIN": "x",
        ]
        let gitConstants = ["GIT_PAGER", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT"]
            + (0..<4).flatMap { ["GIT_CONFIG_KEY_\($0)", "GIT_CONFIG_VALUE_\($0)"] }
        let env = ClaudeCodeRunner.environment(claudePath: "/x/bin/claude", ownersPath: false, base: base)
        XCTAssertEqual(Set(env.keys),
                       Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "HTTPS_PROXY", "PATH"] + gitConstants))
        XCTAssertEqual(env["HTTPS_PROXY"], "http://proxy:3128", "claude needs the network settings")
    }

    func testOnlyShellProfilesKeepTheOwnersPath() {
        let base = ["PATH": "/Users/m/.nvm/bin:/usr/bin"]
        let fixed = ClaudeCodeRunner.environment(claudePath: "/x/bin/claude", ownersPath: false, base: base)["PATH"]!
        XCTAssertFalse(fixed.contains("/Users/m/.nvm/bin"))
        XCTAssertEqual(fixed, "/usr/local/bin:/opt/homebrew/bin:/x/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        let owners = ClaudeCodeRunner.environment(claudePath: "/x/bin/claude", ownersPath: true, base: base)["PATH"]!
        XCTAssertTrue(owners.contains("/Users/m/.nvm/bin"), "the commands the owner allows must be found")
    }

    /// Y3-lite probe: a `.env` in a folder given besides the project was
    /// read; review y3lite, 1: a folder's path a rule cannot spell must not
    /// leave it without the rules. The names go for the whole disk instead.
    func testDeniedNamesHoldInEveryGivenFolder() throws {
        var agent = TeamPublishedAgent(name: "a", description: "d", folder: "/p", access: .editFiles)
        agent.extraFolders = ["/Users/m/Archive (2026)", "/Users/m/[work]"]
        let args = try ClaudeCodeRunner.arguments(for: TeamRunRequest(agent: agent, prompt: "hi", sessionId: "11111111-2222-4333-8444-555555555555", resume: false,
                                                                  callerName: "M", callerProject: nil))
        for name in ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa*"] {
            XCTAssertTrue(args.contains("Read(\(name))"), name)
            XCTAssertTrue(args.contains("Read(//\(name))"), name)
            XCTAssertTrue(args.contains("Edit(//\(name))"), name)
        }
        XCTAssertFalse(args.contains { ($0.hasPrefix("Read(") || $0.hasPrefix("Edit(")) && $0.contains("/Users/m/") },
                       "no rule depends on a given folder's path")
        XCTAssertTrue(args.contains("Read(~/.ssh/**)"))
        XCTAssertFalse(args.contains("Read(//~/.ssh/**)"), "a home path is no name")
    }
}
