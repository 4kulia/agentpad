import Foundation
import Darwin
import XCTest
@testable import AgentPadKit

private actor FakeAccountSSH {
    struct Request: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let input: Data?
        let timeout: TimeInterval
    }
    var requests: [Request] = []
    var result = RemoteSSHProcessResult(exitCode: 0)
    var pending: CheckedContinuation<RemoteSSHProcessResult, Never>?
    var suspend = false

    func setResult(_ result: RemoteSSHProcessResult) { self.result = result }
    func setSuspended() { suspend = true }
    func captured() -> [Request] { requests }
    func run(_ executable: String, _ arguments: [String], _ input: Data?, _ timeout: TimeInterval) async -> RemoteSSHProcessResult {
        requests.append(Request(executable: executable, arguments: arguments, input: input, timeout: timeout))
        if suspend { return await withCheckedContinuation { pending = $0 } }
        return result
    }
    func finish(_ result: RemoteSSHProcessResult) { pending?.resume(returning: result); pending = nil; suspend = false }
}

@MainActor
final class RemoteClaudeAccountTests: XCTestCase {
    private var root: URL!
    private var tokens: MemoryClaudeTokens!
    private var accounts: ClaudeAccountStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-claude-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokens = MemoryClaudeTokens()
        accounts = ClaudeAccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: tokens, isUsed: { _ in false })
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    private func service(_ ssh: FakeAccountSSH) -> RemoteClaudeAccountService {
        RemoteClaudeAccountService(accounts: accounts, runner: { executable, arguments, input, timeout in
            await ssh.run(executable, arguments, input, timeout)
        })
    }

    func testInstallSendsTokenOnlyInStdinAndReplacementMakesCachedStatusStale() async throws {
        let account = try accounts.add(name: "Work", token: "fake-secret-quote'$(false)")
        let ssh = FakeAccountSSH(), remote = service(ssh)
        XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), .unchecked)
        let result = await remote.install(accountID: account.id, host: "fixture-host")
        XCTAssertEqual(result, .current)
        let requests = await ssh.captured()
        XCTAssertEqual(requests, [FakeAccountSSH.Request(executable: "/usr/bin/ssh",
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
                + ["fixture-host", RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)],
            input: Data((account.credentialRevision.uuidString + "\nfake-secret-quote'$(false)\n").utf8), timeout: 20)])
        XCTAssertFalse(requests[0].arguments.joined().contains("fake-secret"))
        try accounts.replaceToken(id: account.id, token: "fake-second")
        XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), .stale)
        XCTAssertEqual(remote.state(accountID: account.id, host: "other-host"), .unchecked)
        let updated = await remote.install(accountID: account.id, host: "fixture-host")
        XCTAssertEqual(updated, .current)
        let updatedAccount = try XCTUnwrap(accounts.account(account.id))
        let after = await ssh.captured()
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last, FakeAccountSSH.Request(executable: "/usr/bin/ssh",
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        "-o", "ControlMaster=no", "-o", "ControlPath=none",
                        "fixture-host", RemoteClaudeAccount.installCommand(accountID: account.id, revision: updatedAccount.credentialRevision)],
            input: Data((updatedAccount.credentialRevision.uuidString + "\nfake-second\n").utf8), timeout: 20))

        // Replay both token-carrying requests through the actual process runner
        // using a local SSH stand-in: never contact a host or read SSH config.
        let probe = root.appendingPathComponent("ssh-probe")
        try Data("#!/bin/sh\nulimit -c\n".utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        for request in after {
            let result = AgentPadShellIntegration.runSSHProcess(probe.path, request.arguments,
                stdin: request.input, timeout: 3, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                inspectLaunch: { executable, arguments, environment in
                    XCTAssertEqual(executable, "/bin/sh")
                    XCTAssertEqual(arguments, ["+x", "-c", "ulimit -c 0 || exit 46\nexec \"$@\"", "agentpad-ssh", probe.path]
                        + request.arguments)
                    XCTAssertEqual(environment, ["HOME": self.root.path, "PATH": "/usr/bin:/bin"])
                    XCTAssertEqual(arguments.filter { $0.hasPrefix("ControlPath=") }, ["ControlPath=none"])
                    XCTAssertTrue(arguments.contains("ControlMaster=no"))
                    XCTAssertFalse(arguments.contains("-S"))
                    XCTAssertTrue(request.arguments.last?.contains("ulimit -c 0 || exit 46") == true)
                })
            XCTAssertEqual(result, .init(exitCode: 0, output: Data("0\n".utf8)))
        }
    }

    func testCheckReadsRevisionWithoutTokenAccessAndMapsMissingStaleAndSafeFailure() async throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        tokens.fails = true
        let ssh = FakeAccountSSH(), remote = service(ssh)
        for (response, expected) in [
            (RemoteSSHProcessResult(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)), RemoteClaudeAccountState.current),
            (RemoteSSHProcessResult(exitCode: 0, output: Data((UUID().uuidString + "\n").utf8)), .stale),
            (RemoteSSHProcessResult(exitCode: RemoteClaudeAccount.missingExit), .notInstalled),
            (RemoteSSHProcessResult(exitCode: 255, output: Data("fake-private-token".utf8)), .failed(.connection)),
            (RemoteSSHProcessResult(exitCode: 0, output: Data("bad record".utf8)), .failed(.invalidRecord)),
            (RemoteSSHProcessResult(exitCode: 46), .failed(.invalidRecord)),
        ] {
            await ssh.setResult(response)
            let status = await remote.check(accountID: account.id, host: "fixture-host")
            XCTAssertEqual(status, expected)
            XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), expected)
        }
        let requests = await ssh.captured()
        XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests.allSatisfy { $0.input == nil && !$0.arguments.joined().contains("fake-private-token") })
        XCTAssertTrue(requests.allSatisfy { $0.arguments ==
            ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + AgentPadShellIntegration.sshMultiplexOptions
                + ["fixture-host", RemoteClaudeAccount.checkCommand(accountID: account.id)] })
        XCTAssertEqual(RemoteClaudeAccountState.failed(.connection).failureMessage,
            "The SSH connection failed. Check the connection and try again.")
        let status = await remote.install(accountID: account.id, host: "fixture-host")
        XCTAssertEqual(status, .failed(.localToken))
        let after = await ssh.captured()
        XCTAssertEqual(after.count, 6)
    }

    func testReplacementDuringInstallStaysStaleAndConcurrentCheckWaitsForCompletion() async throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let ssh = FakeAccountSSH(), remote = service(ssh)
        await ssh.setSuspended()
        let install = Task { await remote.install(accountID: account.id, host: "fixture-host") }
        for _ in 0..<100 {
            if !(await ssh.captured()).isEmpty { break }
            await Task.yield()
        }
        XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), .installing)
        let check = Task { await remote.check(accountID: account.id, host: "fixture-host") }
        await Task.yield()
        let during = await ssh.captured()
        XCTAssertEqual(during.count, 1)
        try accounts.replaceToken(id: account.id, token: "fake-replacement")
        await ssh.setResult(RemoteSSHProcessResult(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
        await ssh.finish(RemoteSSHProcessResult(exitCode: 0))
        let installed = await install.value
        let checked = await check.value
        XCTAssertEqual(installed, .stale)
        XCTAssertEqual(checked, .stale)
        XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), .stale)
        let after = await ssh.captured()
        XCTAssertEqual(after.count, 2)
    }

    func testQueuedInstallAndRemoveRejectChangedConfirmationBeforeAnyRemoteMutation() async throws {
        for remove in [false, true] {
            let account = try accounts.add(name: "Work", token: "fake-approved-token")
            let ssh = FakeAccountSSH(), remote = service(ssh)
            await ssh.setSuspended()
            let check = Task { await remote.check(accountID: account.id, host: "fixture-host") }
            for _ in 0..<100 {
                if !(await ssh.captured()).isEmpty { break }
                await Task.yield()
            }
            XCTAssertEqual(remote.state(accountID: account.id, host: "fixture-host"), .checking)
            let mutation = Task {
                if remove {
                    await remote.remove(accountID: account.id, host: "fixture-host", expectedRevision: account.credentialRevision)
                } else {
                    await remote.install(accountID: account.id, host: "fixture-host", expectedRevision: account.credentialRevision)
                }
            }
            await Task.yield()
            try accounts.replaceToken(id: account.id, token: "fake-unapproved-replacement")
            await ssh.finish(.init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
            _ = await check.value
            let outcome = await mutation.value
            XCTAssertEqual(outcome, .failed(.changedAccount))
            let requests = await ssh.captured()
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests.allSatisfy { $0.input == nil })
            XCTAssertEqual(requests.first?.arguments.last, RemoteClaudeAccount.checkCommand(accountID: account.id))
        }
    }

    func testRemovalAndInvalidHostNeverSendCredentials() async throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        tokens.fails = true
        let ssh = FakeAccountSSH(), remote = service(ssh)
        let removed = await remote.remove(accountID: account.id, host: "fixture-host")
        XCTAssertEqual(removed, .notInstalled)
        let requests = await ssh.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0], FakeAccountSSH.Request(executable: "/usr/bin/ssh",
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + AgentPadShellIntegration.sshMultiplexOptions
                + ["fixture-host", RemoteClaudeAccount.removeCommand(accountID: account.id)],
            input: nil, timeout: 20))
        for host in ["", "-oProxyCommand=bad", "bad\nhost", "bad host"] {
            let status = await remote.check(accountID: account.id, host: host)
            XCTAssertEqual(status, .failed(.connection))
        }
        let after = await ssh.captured()
        XCTAssertEqual(after.count, 1)
        await ssh.setResult(RemoteSSHProcessResult(exitCode: 255))
        let failure = await remote.remove(accountID: account.id, host: "fixture-host")
        XCTAssertEqual(failure, .failed(.connection))
    }

    private func run(_ command: String, input: Data? = nil, extraEnvironment: [String: String] = [:]) throws -> RemoteSSHProcessResult {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
            .merging(extraEnvironment) { _, new in new }
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteSSHProcessResult(exitCode: process.terminationStatus, output: output)
    }

    private func record(_ id: UUID) -> URL {
        root.appendingPathComponent(".agentpad/claude-accounts/\(id.uuidString).credential")
    }

    func testRecordScriptsAreAtomicPrivateAndStatusReturnsOnlyRevision() throws {
        let account = try accounts.add(name: "Work", token: "fake-token'$(false)")
        let input = Data((account.credentialRevision.uuidString + "\nfake-token'$(false)\n").utf8)
        XCTAssertEqual(try run(RemoteClaudeAccount.checkCommand(accountID: account.id)), RemoteSSHProcessResult(exitCode: 44))
        XCTAssertEqual(try run(RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision), input: input),
            RemoteSSHProcessResult(exitCode: 0))
        XCTAssertEqual(try Data(contentsOf: record(account.id)), input)
        for (url, permissions) in [(root.appendingPathComponent(".agentpad"), 0o700),
                                   (record(account.id).deletingLastPathComponent(), 0o700), (record(account.id), 0o600)] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, permissions)
        }
        XCTAssertEqual(try run(RemoteClaudeAccount.checkCommand(accountID: account.id)),
            RemoteSSHProcessResult(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
        try Data("fake-legacy-token-without-revision\n".utf8).write(to: record(account.id))
        XCTAssertEqual(try run(RemoteClaudeAccount.checkCommand(accountID: account.id)), RemoteSSHProcessResult(exitCode: 46))
        try input.write(to: record(account.id))
        let replacement = UUID()
        // A disconnected/truncated transfer must preserve the existing record.
        XCTAssertEqual(try run(RemoteClaudeAccount.installCommand(accountID: account.id, revision: replacement),
            input: Data((replacement.uuidString + "\ntruncated").utf8)).exitCode, 46)
        XCTAssertEqual(try Data(contentsOf: record(account.id)), input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: record(account.id).deletingLastPathComponent().path),
            [account.id.uuidString + ".credential"])
        XCTAssertEqual(try run(RemoteClaudeAccount.removeCommand(accountID: account.id)), RemoteSSHProcessResult(exitCode: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record(account.id).path))
    }

    func testRemoteLaunchUsesStoredTokenClearsCompetingEnvironmentAndRejectsStaleOrMissing() throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        XCTAssertEqual(try run(install, input: Data((account.credentialRevision.uuidString + "\nfake-private-token\n").utf8)).exitCode, 0)
        let child = root.appendingPathComponent("fixture-claude")
        try Data("""
        #!/bin/sh
        IFS= read -r expected
        [ "$CLAUDE_CODE_OAUTH_TOKEN" = "$expected" ] || exit 61
        [ -z "${ANTHROPIC_API_KEY+x}${ANTHROPIC_AUTH_TOKEN+x}${ANTHROPIC_BASE_URL+x}${apiKeyHelper+x}${CLAUDE_CODE_USE_CUSTOM+x}${BASH_ENV+x}${ENV+x}" ] || exit 62
        printf 'launched'
        """.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let launch = RemoteClaudeAccount.command(accountID: account.id, revision: account.credentialRevision,
            launch: AgentPadShellIntegration.quote(child.path))
        XCTAssertFalse(launch.contains("fake-private-token"))
        let environment = Dictionary(uniqueKeysWithValues:
            (ClaudeAccountSettings.competingEnvironmentKeys + ["BASH_ENV", "ENV", "CLAUDE_CODE_USE_CUSTOM"]).map { ($0, "fake-conflict") })
        XCTAssertEqual(try run(launch, input: Data("fake-private-token\n".utf8), extraEnvironment: environment),
            RemoteSSHProcessResult(exitCode: 0, output: Data("launched".utf8)))
        let stale = RemoteClaudeAccount.command(accountID: account.id, revision: UUID(), launch: "printf fallback")
        XCTAssertEqual(try run(stale), RemoteSSHProcessResult(exitCode: 45))
        try FileManager.default.removeItem(at: record(account.id))
        XCTAssertEqual(try run(launch), RemoteSSHProcessResult(exitCode: 44))
    }

    func testRemoteRecordRejectsSymlinksAndNonFileRecords() throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path)
        let parent = root.appendingPathComponent(".agentpad")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        XCTAssertEqual(try run(install, input: Data((account.credentialRevision.uuidString + "\nfake-private-token\n").utf8)).exitCode, 46)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [])
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: record(account.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let untouched = other.appendingPathComponent("untouched")
        try Data("fixture".utf8).write(to: untouched)
        try FileManager.default.createSymbolicLink(at: record(account.id), withDestinationURL: untouched)
        XCTAssertEqual(try run(RemoteClaudeAccount.checkCommand(accountID: account.id)).exitCode, 46)
        XCTAssertEqual(try run(RemoteClaudeAccount.removeCommand(accountID: account.id)).exitCode, 46)
        XCTAssertEqual(try run(install).exitCode, 46)
        XCTAssertEqual(try Data(contentsOf: untouched), Data("fixture".utf8))
        try FileManager.default.removeItem(at: record(account.id))
        try FileManager.default.createDirectory(at: record(account.id), withIntermediateDirectories: false)
        XCTAssertEqual(try run(install, input: Data((account.credentialRevision.uuidString + "\nfake-private-token\n").utf8)).exitCode, 46)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: record(account.id).path), [])
    }

    func testStdinRunnerKeepsInputOutOfArgumentsAndDrainsBoundedOutput() {
        let secret = "fake-stdin-token"
        let result = AgentPadShellIntegration.runSSHProcess("/bin/sh", ["-c", "cat; printf tail"],
            stdin: Data(secret.utf8), timeout: 3)
        XCTAssertEqual(result, RemoteSSHProcessResult(exitCode: 0, output: Data((secret + "tail").utf8)))
        let bounded = AgentPadShellIntegration.runSSHProcess("/bin/sh", ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null"],
            stdin: nil, timeout: 3)
        XCTAssertEqual(bounded, RemoteSSHProcessResult(exitCode: 0, output: Data(repeating: 0, count: 128)))
        XCTAssertEqual(AgentPadShellIntegration.runSSHProcess(root.appendingPathComponent("missing").path, [], stdin: nil, timeout: 1),
            RemoteSSHProcessResult(exitCode: -1))
        XCTAssertNotEqual(AgentPadShellIntegration.runSSHProcess("/bin/sh", ["-c", "exec sleep 5"], stdin: nil, timeout: 0.01).exitCode, 0)
        XCTAssertEqual(AgentPadShellIntegration.runSSHProcess("/bin/sh", ["-c", "cat"],
            stdin: Data(secret.utf8), timeout: 3, captureOutput: false), RemoteSSHProcessResult(exitCode: 0))
    }

    func testSSHProcessReceivesExplicitEnvironmentWithoutProviderCredentials() {
        let arguments = ["-c", "test \"$UNRELATED\" = keep"]
        var captured: FakeAccountSSH.Request?
        var capturedEnvironment: [String: String]?
        let environment = Dictionary(uniqueKeysWithValues:
            (ClaudeAccountSettings.competingEnvironmentKeys + ["CLAUDE_CODE_USE_CUSTOM", "BASH_ENV", "ENV"]).map { ($0, "fake-credential") })
            .merging(["PATH": "/usr/bin:/bin", "HOME": root.path, "UNRELATED": "keep"]) { _, new in new }
        let result = AgentPadShellIntegration.runSSHProcess("/bin/sh", arguments,
            stdin: Data("fake-stdin-token".utf8), timeout: 3, captureOutput: false, environment: environment,
            inspectLaunch: { executable, argv, environment in
                captured = FakeAccountSSH.Request(executable: executable, arguments: argv, input: nil, timeout: 3)
                capturedEnvironment = environment
            })
        XCTAssertEqual(result, RemoteSSHProcessResult(exitCode: 0))
        XCTAssertEqual(captured, FakeAccountSSH.Request(executable: "/bin/sh",
            arguments: ["+x", "-c", "ulimit -c 0 || exit 46\nexec \"$@\"", "agentpad-ssh", "/bin/sh"] + arguments,
            input: nil, timeout: 3))
        XCTAssertEqual(capturedEnvironment, ["PATH": "/usr/bin:/bin", "HOME": root.path, "UNRELATED": "keep"])
    }

    func testRecordOperationsStayInVerifiedDirectoryAfterAncestorReplacement() throws {
        // Foundation preserves some macOS /var aliases even when resolving
        // symlinks. Match the physical cwd returned by the POSIX shell exactly.
        let physicalRoot = try XCTUnwrap(realpath(root.path, nil))
        defer { free(physicalRoot) }
        let account = try accounts.add(name: "Work", token: "fake-pinned-token")
        let input = Data((account.credentialRevision.uuidString + "\nfake-pinned-token\n").utf8)
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        let outside = root.appendingPathComponent("outside/claude-accounts")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let decoy = outside.appendingPathComponent(account.id.uuidString + ".credential")
        let decoyData = Data((UUID().uuidString + "\nfake-decoy\n").utf8)
        try decoyData.write(to: decoy)
        let swap = """
        mv "$HOME/.agentpad" "$HOME/pinned"
        ln -s "$HOME/outside" "$HOME/.agentpad"
        """
        let commands: [(String, Data?, RemoteSSHProcessResult)] = [
            (install, input, .init(exitCode: 0)),
            (RemoteClaudeAccount.checkCommand(accountID: account.id), nil,
             .init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8))),
            (RemoteClaudeAccount.command(accountID: account.id, revision: account.credentialRevision,
                launch: "pwd"), nil, .init(exitCode: 0, output: Data((String(cString: physicalRoot) + "\n").utf8))),
            (RemoteClaudeAccount.removeCommand(accountID: account.id), nil, .init(exitCode: 0)),
        ]
        for (command, stdin, expected) in commands {
            XCTAssertEqual(try run(install, input: input).exitCode, 0)
            // Deterministic interleaving: replace the ancestor after directory
            // verification, immediately before the operation opens its record.
            let raced = command.replacingOccurrences(of: "\n_agentpad_record=", with: "\n" + swap + "\n_agentpad_record=")
            XCTAssertNotEqual(raced, command)
            XCTAssertEqual(try run(raced, input: stdin), expected)
            XCTAssertEqual(try Data(contentsOf: decoy), decoyData)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [decoy.lastPathComponent])
            try FileManager.default.removeItem(at: root.appendingPathComponent(".agentpad"))
            try FileManager.default.moveItem(at: root.appendingPathComponent("pinned"), to: root.appendingPathComponent(".agentpad"))
        }
    }

    func testRecordDirectoryMustBePrivateAndReverifiedAfterEntering() throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        let input = Data((account.credentialRevision.uuidString + "\nfake-private-token\n").utf8)
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        XCTAssertEqual(try run(install, input: input).exitCode, 0)
        for directory in [root.appendingPathComponent(".agentpad"), record(account.id).deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            for command in [install, RemoteClaudeAccount.checkCommand(accountID: account.id),
                            RemoteClaudeAccount.removeCommand(accountID: account.id),
                            RemoteClaudeAccount.command(accountID: account.id, revision: account.credentialRevision, launch: "exit 0")] {
                XCTAssertEqual(try run(command, input: input).exitCode, 46)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let changed = install.replacingOccurrences(of: "CDPATH= cd -P -- \"$1\" || exit 46",
            with: "CDPATH= cd -P -- \"$1\" || exit 46\nchmod 755 .")
        XCTAssertNotEqual(changed, install)
        XCTAssertEqual(try run(changed, input: input).exitCode, 46)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(".agentpad").path)
        let wrongOwner = install.replacingOccurrences(of: "_agentpad_uid=$(id -u)", with: "_agentpad_uid=invalid")
        XCTAssertEqual(try run(wrongOwner, input: input).exitCode, 46)
    }

    func testTemporaryRecordIsExclusiveAndWritesThroughOriginalDescriptor() throws {
        let account = try accounts.add(name: "Work", token: "fake-private-token")
        let input = Data((account.credentialRevision.uuidString + "\nfake-private-token\n").utf8)
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        let collision = install.replacingOccurrences(of: "set -C\n", with: "printf untouched > \"$_agentpad_temp\"\nset -C\n")
        XCTAssertNotEqual(collision, install)
        XCTAssertNotEqual(try run(collision, input: input).exitCode, 0)
        let directory = record(account.id).deletingLastPathComponent()
        let collisionFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(collisionFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(collisionFiles.first)), Data("untouched".utf8))
        let swap = """
        set +C
        rm -f -- "$_agentpad_temp"
        ln -s "$HOME/untouched" "$_agentpad_temp"
        """
        let untouched = root.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: untouched)
        let replaced = install.replacingOccurrences(of: "set +C", with: swap)
        XCTAssertNotEqual(replaced, install)
        _ = try run(replaced, input: input)
        XCTAssertEqual(try Data(contentsOf: untouched), Data("untouched".utf8))
    }

    func testRemoteAndLocalCredentialProcessesDisableCoreDumpsBeforeReading() throws {
        let account = try accounts.add(name: "Work", token: "fake-core-token")
        let input = Data((account.credentialRevision.uuidString + "\nfake-core-token\n").utf8)
        let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: account.credentialRevision)
        let atReceive = install.replacingOccurrences(of: "IFS= read -r _agentpad_revision &&",
            with: "[ \"$(ulimit -c)\" = 0 ] || exit 99\nIFS= read -r _agentpad_revision &&")
        XCTAssertNotEqual(atReceive, install)
        XCTAssertEqual(try run("ulimit -c 65536; " + atReceive, input: input).exitCode, 0)
        let launch = RemoteClaudeAccount.command(accountID: account.id, revision: account.credentialRevision,
            launch: "/bin/sh -c " + AgentPadShellIntegration.quote("ulimit -c"))
        XCTAssertEqual(try run("ulimit -c 65536; " + launch), .init(exitCode: 0, output: Data("0\n".utf8)))

        var invocation: String?
        let result = AgentPadShellIntegration.runSSHProcess("/bin/sh", ["-c", "ulimit -c"], stdin: Data("fake-core-token".utf8),
            timeout: 3, environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], inspectLaunch: { executable, arguments, environment in
                invocation = ([executable] + arguments).map(AgentPadShellIntegration.quote).joined(separator: " ")
                XCTAssertFalse(arguments.joined().contains("fake-core-token"))
                XCTAssertFalse(environment.values.joined().contains("fake-core-token"))
            })
        XCTAssertEqual(result, .init(exitCode: 0, output: Data("0\n".utf8)))
        // Replay the actual child invocation under an enabled inherited limit;
        // a system-wide default of zero must not make this test vacuous.
        XCTAssertEqual(try run("ulimit -c 65536; " + XCTUnwrap(invocation), input: Data("fake-core-token".utf8)),
            .init(exitCode: 0, output: Data("0\n".utf8)))
    }

    func testRemoteGuardRefusalEmitsLaunchMarker() throws {
        let account = try accounts.add(name: "Work", token: "fake-guard-token")
        let launchID = UUID()
        let command = RemoteClaudeAccount.command(accountID: account.id, revision: account.credentialRevision,
            launch: "printf unexpected-agent", launchID: launchID)
        for code in [44, 45] {
            if code == 45 {
                let otherRevision = UUID()
                let install = RemoteClaudeAccount.installCommand(accountID: account.id, revision: otherRevision)
                XCTAssertEqual(try run(install, input: Data((otherRevision.uuidString + "\nfake-guard-token\n").utf8)).exitCode, 0)
            }
            let result = try run(command + " 2>&1")
            XCTAssertEqual(result, .init(exitCode: Int32(code),
                output: Data("\u{1b}]2;\(AgentLaunchExitMarker.prefix)\(launchID.uuidString):\(code)\u{7}".utf8)))
        }
    }
}
