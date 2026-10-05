import Foundation
import XCTest
@testable import AgentPadKit

/// Writes what a team run would get for the executor boundary probe
/// (`docs/agentpad/Y1-probe/run-checks.sh`), so the probe runs `claude` with
/// the command line `ClaudeCodeRunner` builds. Skipped unless `Y1_PROBE_DUMP`
/// names the output file.
///
/// It never serializes a real environment value. `environment(...)` is fed a
/// synthetic base of sentinel names standing in for the owner's variables, so
/// the dump holds only variable names and synthetic values; the probe builds
/// the live launch environment itself, in memory, from these names.
final class TeamExecutorProbeArgsTests: XCTestCase {
    /// Sentinel names, one per class the executor's environment must handle.
    /// Values are synthetic; `-PASS-THROUGH` marks the ones that, if they
    /// reach the agent, are a finding (secrets, loader and shell hooks).
    static let syntheticBase: [String: String] = [
        "PATH": "/synthetic/bin:/usr/bin:/bin",
        "HOME": "/synthetic/home",
        "LANG": "en_US.UTF-8",
        "FOO_PLAIN": "SYNTH-plain",
        "TWINE_PASSWORD": "SYNTH-PASS-THROUGH-secret",
        "AWS_SECRET_ACCESS_KEY": "SYNTH-PASS-THROUGH-secret",
        "GITHUB_TOKEN": "SYNTH-PASS-THROUGH-secret",
        "OPENAI_API_KEY": "SYNTH-PASS-THROUGH-secret",
        "CLAUDE_CONFIG_DIR": "SYNTH-PASS-THROUGH-claude-config",
        "CLAUDE_CODE_FOO": "SYNTH-claude-code",
        "CLAUDECODE": "1",
        "GIT_SSH_COMMAND": "SYNTH-git-ssh",
        "AGENTPAD_FOO": "SYNTH-agentpad",
        "LD_PRELOAD": "SYNTH-PASS-THROUGH-loader",
        "DYLD_INSERT_LIBRARIES": "SYNTH-PASS-THROUGH-loader",
        "BASH_ENV": "SYNTH-PASS-THROUGH-shell",
        "ENV": "SYNTH-PASS-THROUGH-shell",
    ]

    func testDumpProbeCommandLines() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["Y1_PROBE_DUMP"], let folder = env["Y1_PROBE_FOLDER"], let claude = env["Y1_PROBE_CLAUDE"] else {
            throw XCTSkip("Y1_PROBE_DUMP, Y1_PROBE_FOLDER and Y1_PROBE_CLAUDE are not set")
        }
        // Several folders, one per line: their paths may hold spaces and brackets.
        let extra = env["Y1_PROBE_EXTRA"].map { $0.split(separator: "\n").map(String.init) }
        let source = env["Y1_PROBE_SOURCE_SESSION"]
        let transcripts = try ClaudeResumeFixture()
        if let source { try transcripts.add(source) }
        let commands = (env["Y1_PROBE_COMMANDS"] ?? "").split(separator: ",").map(String.init)
        var dump: [String: Any] = [:]
        // The launch environment: the executor's own function over a base the
        // probe controls — the user's identity and locale (claude needs them
        // to sign in), plus the synthetic sentinels. Holds no secret by
        // construction; written 0600 and removed by the probe after its run.
        var controlled = Self.syntheticBase
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { controlled[name] = env[name] }
        controlled["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for access in TeamAccessProfile.allCases {
            for variant in ["plain", "runTools", "session", "resume"] {
                var agent = TeamPublishedAgent(name: "probe", description: "probe", folder: folder, access: access)
                agent.allowedCommands = commands
                agent.maxTurns = 20
                agent.model = "haiku"
                agent.extraFolders = extra
                if variant == "session" { agent.sessionId = source }
                let request = TeamRunRequest(
                    agent: agent, prompt: "", sessionId: variant == "resume" ? transcripts.id : UUID().uuidString.lowercased(),
                    resume: variant == "resume",
                    callerName: "Probe", callerProject: nil,
                    runToolsCallId: variant == "runTools" ? UUID().uuidString.lowercased() : nil
                )
                // Over the synthetic base, so every value in the dump is
                // synthetic or a constant the code itself sets.
                let synthetic = ClaudeCodeRunner.environment(
                    claudePath: claude, isolateGit: !access.takesCommands, ownersPath: access.runsShell, base: Self.syntheticBase
                )
                let launch = ClaudeCodeRunner.environment(
                    claudePath: claude, isolateGit: !access.takesCommands, ownersPath: access.runsShell, base: controlled
                )
                dump["\(access.rawValue)-\(variant)"] = [
                    "arguments": try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcripts.root),
                    "env_synthetic": synthetic,
                    "env_kept_names": synthetic.keys.sorted(),
                    "env_launch": launch,
                ]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: out, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: URL(fileURLWithPath: out))
    }
}
