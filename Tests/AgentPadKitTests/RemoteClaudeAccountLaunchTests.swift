import XCTest
@testable import AgentPadKit

private actor LaunchSSHFixture {
    var result: RemoteSSHProcessResult
    var calls: [(String, [String], Data?)] = []
    private var suspendsInstall = false
    private var installResult: CheckedContinuation<RemoteSSHProcessResult, Never>?
    private var installStarted: CheckedContinuation<Void, Never>?
    init(_ result: RemoteSSHProcessResult) { self.result = result }
    func run(_ executable: String, _ arguments: [String], _ input: Data?) async -> RemoteSSHProcessResult {
        calls.append((executable, arguments, input))
        if input != nil, suspendsInstall {
            return await withCheckedContinuation { continuation in
                installResult = continuation
                installStarted?.resume()
                installStarted = nil
            }
        }
        return result
    }
    func setResult(_ result: RemoteSSHProcessResult) { self.result = result }
    func suspendInstall() { suspendsInstall = true }
    func waitForInstall() async {
        if installResult != nil { return }
        await withCheckedContinuation { installStarted = $0 }
    }
    func finishInstall() {
        suspendsInstall = false
        installResult?.resume(returning: .init(exitCode: 0))
        installResult = nil
    }
}

@MainActor
final class RemoteClaudeAccountLaunchTests: XCTestCase {
    private var root: URL!
    private var tokens: MemoryClaudeTokens!
    private var profiles: AgentProfileStore!
    private var owners: [WorkspaceStore] = []
    private var engines: [TestEngine] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-account-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokens = MemoryClaudeTokens()
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"), accountTokens: tokens)
    }

    override func tearDown() async throws {
        owners.forEach { $0.terminate() }
        owners = []; engines = []
        try profiles.flush()
        try FileManager.default.removeItem(at: root)
    }

    private func owner(persistence: InMemoryPersistence = .init(), deferred: Bool = false) -> WorkspaceStore {
        let owner = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            sessionNames: .testing, engineFactory: { [weak self] in
                let engine = TestEngine()
                engine.preparesClaudeAccountLaunch = !deferred
                self?.engines.append(engine)
                return engine
            }, optionsProvider: { _ in nil }, resumeProvider: { true },
            conversationVisibility: { .init(channelIds: []) }, peerStores: { [] },
            claudeProjectsRoot: root.appendingPathComponent("empty-projects"))
        owners.append(owner)
        return owner
    }

    private func fixture(_ result: RemoteSSHProcessResult) -> LaunchSSHFixture {
        let fixture = LaunchSSHFixture(result)
        profiles.remoteClaudeAccounts = RemoteClaudeAccountService(accounts: profiles.claudeAccounts) { executable, arguments, input, _ in
            await fixture.run(executable, arguments, input)
        }
        return fixture
    }

    private func selected() throws -> (ClaudeAccount, AgentProfile) {
        let account = try profiles.claudeAccounts.add(name: "Work", token: "in-memory-ssh-test-token")
        let profile = try profiles.add(template: .claudeCode, folder: root, name: "Reviewer", launchOptions: "--model opus")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        return (account, try XCTUnwrap(profiles.profile(profile.id)))
    }

    private func settle(_ session: Session) async {
        await session.remoteClaudeAccountCheck?.value
    }

    func testMainAccountCommandIsUnchangedAndEveryProfileUsesWorkspaceSSH() throws {
        let expected = "agentpad-ssh 'buildbox' -- claude --model opus"
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", sshHost: "buildbox")
        XCTAssertEqual(config.environment["AGENTPAD_AGENT"], expected)
        XCTAssertNil(config.claudeAccountLaunch)
        XCTAssertNil(config.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        for template in [AgentTemplate.claudeCode, .codex] {
            let owner = owner()
            owner.active?.sshRemoteHost = "buildbox"
            let profile = try profiles.add(template: template, folder: root, launchOptions: "--model opus")
            let session = try owner.startAgentProfile(profile.id).get()
            XCTAssertEqual(session.sshWorkspaceHost, "buildbox")
            let actual = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last)
            XCTAssertTrue(actual.environment["AGENTPAD_AGENT"]?.hasPrefix("agentpad-ssh 'buildbox' -- ") == true)
            XCTAssertNil(actual.claudeAccountLaunch)
        }
    }

    func testSecondAccountCommandContainsOnlyIdentifiersAndNoLocalHelper() throws {
        let (account, _) = try selected()
        let config = AgentTemplate.claudeCode.makeSessionConfig(extraOptions: "--model opus", sshHost: "buildbox",
            remoteClaudeAccount: account)
        let command = try XCTUnwrap(config.environment["AGENTPAD_AGENT"])
        XCTAssertTrue(command.hasPrefix("agentpad-ssh 'buildbox' -- "))
        XCTAssertTrue(command.contains(account.id.uuidString))
        XCTAssertTrue(command.contains(account.credentialRevision.uuidString))
        XCTAssertTrue(command.contains("exec claude --model opus"))
        XCTAssertFalse(command.contains("claude-account-check"))
        XCTAssertFalse(command.contains("in-memory-ssh-test-token"))
        XCTAssertNil(config.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(config.claudeAccountLaunch)
        XCTAssertFalse(config.description.contains("in-memory-ssh-test-token"))
    }

    func testInstalledLaunchReadsOnlyRevisionAndNeverReadsLocalToken() async throws {
        let (account, profile) = try selected()
        let ssh = fixture(.init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
        tokens.fails = true
        let owner = owner()
        owner.active?.sshRemoteHost = "buildbox"
        let session = try owner.startAgentProfile(profile.id).get()
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        XCTAssertTrue(engine.startedConfigs.isEmpty)
        await settle(session)
        XCTAssertEqual(engine.startedConfigs.count, 1)
        XCTAssertNil(session.remoteClaudeAccountBlock)
        XCTAssertTrue(session.hasProcess)
        let command = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_AGENT"])
        XCTAssertTrue(command.contains(account.credentialRevision.uuidString))
        let calls = await ssh.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.2)
        XCTAssertFalse(calls.flatMap(\.1).joined().contains("in-memory-ssh-test-token"))
    }

    func testMissingStaleAndFailedRemoteRecordsBlockWithoutMainFallback() async throws {
        let (account, profile) = try selected()
        for result in [RemoteSSHProcessResult(exitCode: RemoteClaudeAccount.missingExit),
                       .init(exitCode: 0, output: Data((UUID().uuidString + "\n").utf8)),
                       .init(exitCode: 255)] {
            _ = fixture(result)
            let owner = owner()
            owner.active?.sshRemoteHost = "buildbox"
            let session = try owner.startAgentProfile(profile.id).get()
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            await settle(session)
            XCTAssertTrue(engine.startedConfigs.isEmpty)
            XCTAssertFalse(session.hasProcess)
            XCTAssertEqual(session.remoteClaudeAccountBlock?.accountID, account.id)
            XCTAssertEqual(session.remoteClaudeAccountBlock?.host, "buildbox")
            XCTAssertEqual(session.title, profile.name)
            XCTAssertEqual(session.unavailableTab?.profileID, profile.id)
            XCTAssertEqual(session.unavailableTab?.sshWorkspaceHost, "buildbox")
            XCTAssertEqual(owner.profileSessionItems(profile).first?.session?.id, session.id)
            XCTAssertEqual(owner.profileSessionItems(profile).first?.title, "Waiting to start · buildbox")
            XCTAssertFalse(session.tabState?.message?.contains("in-memory-ssh-test-token") == true)
        }
    }

    func testInstallDoesNotStartUntilRetryAndRetryReplacesBlockedTabOnce() async throws {
        let (account, profile) = try selected()
        let ssh = fixture(.init(exitCode: RemoteClaudeAccount.missingExit))
        let owner = owner()
        owner.active?.sshRemoteHost = "buildbox"
        let blocked = try owner.startAgentProfile(profile.id).get()
        await settle(blocked)
        await ssh.setResult(.init(exitCode: 0))
        let status = await profiles.remoteClaudeAccounts.install(accountID: account.id, host: "buildbox")
        XCTAssertEqual(status, .current)
        XCTAssertFalse(blocked.hasProcess)
        await ssh.setResult(.init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
        owner.retryRemoteClaudeAccount(sessionID: blocked.id)
        let retried = try XCTUnwrap(owner.allSessions.first { $0.id == blocked.id })
        XCTAssertFalse(retried === blocked)
        await settle(retried)
        XCTAssertTrue(retried.hasProcess)
        XCTAssertEqual((retried.engine as? TestEngine)?.startedConfigs.count, 1)
        owner.retryRemoteClaudeAccount(sessionID: blocked.id)
        XCTAssertTrue(owner.allSessions.first { $0.id == blocked.id } === retried)
    }

    func testInstallAndStartPreservesBlockedTabAfterProfileSwitchWhileInstallIsPending() async throws {
        let (account, profile) = try selected()
        let ssh = fixture(.init(exitCode: RemoteClaudeAccount.missingExit))
        let owner = owner()
        owner.active?.sshRemoteHost = "buildbox"
        let blocked = try owner.startAgentProfile(profile.id).get()
        await settle(blocked)
        let start = try XCTUnwrap(owner.remoteClaudeAccountStartAfterInstall(sessionID: blocked.id,
            accountID: account.id, host: "buildbox"))
        let operation = RemoteClaudeAccountOperation(account: account, host: "buildbox", kind: .install,
            agentName: profile.name, canStartAfterInstall: true)
        operation.startAfterInstall = true
        await ssh.suspendInstall()
        let installation = Task { await operation.perform(accounts: profiles.claudeAccounts,
            service: profiles.remoteClaudeAccounts) }
        await ssh.waitForInstall()
        try profiles.setClaudeAccount(profileID: profile.id, accountID: nil)
        await ssh.finishInstall()
        let installed = await installation.value
        XCTAssertTrue(installed)
        if installed && operation.startAfterInstall { start() }
        XCTAssertEqual(profiles.remoteClaudeAccounts.state(accountID: account.id, host: "buildbox"), .current)
        XCTAssertTrue(owner.allSessions.first { $0.id == blocked.id } === blocked)
        XCTAssertFalse(blocked.hasProcess)
        XCTAssertEqual(blocked.remoteClaudeAccountBlock?.accountID, account.id)
        XCTAssertEqual(engines.reduce(0) { $0 + $1.startedConfigs.count }, 0)
    }

    func testInstallAndStartRequiresOriginalBlockedSessionProfileAccountAndHost() async throws {
        enum Change: CaseIterable { case unchanged, account, profile, host, replacement, closed }
        let (account, profile) = try selected()
        let other = try profiles.add(template: .claudeCode, folder: root, name: "Other reviewer")
        try profiles.setClaudeAccount(profileID: other.id, accountID: account.id)
        let secondAccount = try profiles.claudeAccounts.add(name: "Other", token: "another-in-memory-token")
        for change in Change.allCases {
            try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
            let ssh = fixture(.init(exitCode: RemoteClaudeAccount.missingExit))
            let owner = owner()
            owner.active?.sshRemoteHost = "buildbox"
            let blocked = try owner.startAgentProfile(profile.id).get()
            await settle(blocked)
            let start = try XCTUnwrap(owner.remoteClaudeAccountStartAfterInstall(sessionID: blocked.id,
                accountID: account.id, host: "buildbox"))
            switch change {
            case .unchanged: break
            case .account: try profiles.setClaudeAccount(profileID: profile.id, accountID: secondAccount.id)
            case .profile: blocked.profileID = other.id
            case .host: blocked.sshWorkspaceHost = "other-buildbox"
            case .replacement:
                owner.retryRemoteClaudeAccount(sessionID: blocked.id)
                let replacement = try XCTUnwrap(owner.allSessions.first { $0.id == blocked.id })
                await settle(replacement)
                XCTAssertFalse(replacement === blocked)
                XCTAssertNotNil(replacement.remoteClaudeAccountBlock)
            case .closed: owner.closeTab(blocked, in: try XCTUnwrap(owner.active))
            }
            let before = owner.allSessions.first { $0.id == blocked.id }
            let count = engines.reduce(0) { $0 + $1.startedConfigs.count }
            await ssh.setResult(.init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
            start()
            if change == .unchanged {
                let started = try XCTUnwrap(owner.allSessions.first { $0.id == blocked.id })
                XCTAssertFalse(started === blocked)
                await settle(started)
                XCTAssertTrue(started.hasProcess)
                XCTAssertEqual(engines.reduce(0) { $0 + $1.startedConfigs.count }, count + 1)
            } else {
                XCTAssertTrue(owner.allSessions.first { $0.id == blocked.id } === before, "\(change) must preserve the current tab")
                XCTAssertEqual(engines.reduce(0) { $0 + $1.startedConfigs.count }, count)
            }
        }
    }

    func testRemoteGuardRefusalAfterSuccessfulPreflightShowsBlockedRecoveryActions() async throws {
        let (account, profile) = try selected()
        for (exit, status) in [(RemoteClaudeAccount.missingExit, RemoteClaudeAccountState.notInstalled),
                               (RemoteClaudeAccount.staleExit, .stale)] {
            _ = fixture(.init(exitCode: 0, output: Data((account.credentialRevision.uuidString + "\n").utf8)))
            let owner = owner()
            owner.active?.sshRemoteHost = "buildbox"
            let session = try owner.startAgentProfile(profile.id).get()
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            await settle(session)
            let launch = try XCTUnwrap(session.remoteClaudeAccountLaunch)
            let command = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_AGENT"])
            XCTAssertTrue(command.contains(launch.id.uuidString))
            // The same terminal title callback used by the rendered terminal,
            // after revision preflight already allowed its process to start.
            engine.onTitleChange?("\(AgentLaunchExitMarker.prefix)\(UUID().uuidString):\(exit)")
            XCTAssertTrue(session.hasProcess, "an obsolete launch marker must be ignored")
            engine.onTitleChange?("\(AgentLaunchExitMarker.prefix)\(launch.id.uuidString):43")
            XCTAssertTrue(session.hasProcess, "unrelated failures must not become account refusals")
            engine.onTitleChange?("\(AgentLaunchExitMarker.prefix)\(launch.id.uuidString):\(exit)")
            XCTAssertEqual(session.remoteClaudeAccountBlock, RemoteClaudeAccountBlock(accountID: account.id,
                accountName: account.name, host: "buildbox", status: status,
                profileName: profile.name, folder: root.path))
            XCTAssertEqual(profiles.remoteClaudeAccounts.state(accountID: account.id, host: "buildbox"), status)
            XCTAssertFalse(session.hasProcess)
            XCTAssertEqual(engine.terminateCount, 1)
            XCTAssertNil(session.remoteClaudeAccountLaunch)
            XCTAssertEqual(session.toolRoute, .unavailable(session.id))
            XCTAssertEqual(session.unavailableTab?.profileID, profile.id)
            XCTAssertEqual(session.unavailableTab?.sshWorkspaceHost, "buildbox")
            XCTAssertNotNil(owner.remoteClaudeAccountStartAfterInstall(sessionID: session.id,
                accountID: account.id, host: "buildbox"), "the blocked state must retain its install-and-start action")
            XCTAssertEqual(owner.profileSessionItems(profile).first?.title, "Waiting to start · buildbox")
            XCTAssertEqual(engine.startedConfigs.count, 1, "the refused account must never fall back to Main")
        }
    }

    func testRestoredRemoteProfileKeepsHostAndUsesAccountChosenAtReveal() async throws {
        let (_, profile) = try selected()
        let disk = InMemoryPersistence()
        let first = owner(persistence: disk, deferred: true)
        first.active?.sshRemoteHost = "buildbox"
        let original = try first.startAgentProfile(profile.id).get()
        XCTAssertTrue(first.flushPersistence())
        first.terminate()
        let restored = owner(persistence: .init(initial: try XCTUnwrap(disk.saved)), deferred: true)
        let session = try XCTUnwrap(restored.allSessions.first { $0.id == original.id })
        XCTAssertEqual(session.sshWorkspaceHost, "buildbox")
        let second = try profiles.claudeAccounts.add(name: "Other", token: "second-in-memory-token")
        try profiles.setClaudeAccount(profileID: profile.id, accountID: second.id)
        _ = fixture(.init(exitCode: 0, output: Data((second.credentialRevision.uuidString + "\n").utf8)))
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        let config = try XCTUnwrap(engine.startedConfigs.last)
        engine.preparesClaudeAccountLaunch = true
        engine.start(config: config)
        await settle(session)
        let command = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_AGENT"])
        XCTAssertTrue(command.contains(second.id.uuidString))
        XCTAssertFalse(command.contains("second-in-memory-token"))
    }

    func testDeferredMainSelectionUsesRemoteLoginWithoutSSHCredentialCheck() throws {
        let (_, profile) = try selected()
        let owner = owner(deferred: true)
        owner.active?.sshRemoteHost = "buildbox"
        let session = try owner.startAgentProfile(profile.id).get()
        try profiles.setClaudeAccount(profileID: profile.id, accountID: nil)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        var config = try XCTUnwrap(engine.startedConfigs.last)
        XCTAssertTrue(config.prepareForProcessStart())
        XCTAssertEqual(config.environment["AGENTPAD_AGENT"], "agentpad-ssh 'buildbox' -- claude --model opus")
        XCTAssertNil(session.remoteClaudeAccountCheck)
    }
}
