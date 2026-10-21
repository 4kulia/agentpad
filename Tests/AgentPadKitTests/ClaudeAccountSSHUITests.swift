import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

private actor SSHAccountUITransport {
    var revisions: [String: UUID] = [:]
    var failures: [String: Int32] = [:]
    var requests = 0

    func seed(_ host: String, revision: UUID) { revisions[host] = revision }
    func fail(_ host: String, code: Int32?) { failures[host] = code }
    func count() -> Int { requests }

    func run(arguments: [String], input: Data?) -> RemoteSSHProcessResult {
        requests += 1
        let host = arguments.dropLast().last ?? ""
        if let code = failures[host] { return RemoteSSHProcessResult(exitCode: code) }
        if let input, let first = String(decoding: input, as: UTF8.self).split(separator: "\n").first,
           let revision = UUID(uuidString: String(first)) {
            revisions[host] = revision
            return RemoteSSHProcessResult(exitCode: 0)
        }
        if arguments.last?.contains("rm -f --") == true {
            revisions[host] = nil
            return RemoteSSHProcessResult(exitCode: 0)
        }
        guard let revision = revisions[host] else { return RemoteSSHProcessResult(exitCode: RemoteClaudeAccount.missingExit) }
        return RemoteSSHProcessResult(exitCode: 0, output: Data((revision.uuidString + "\n").utf8))
    }
}

@MainActor
final class ClaudeAccountSSHUITests: XCTestCase {
    private func profiles(_ transport: SSHAccountUITransport) throws -> (AgentProfileStore, ClaudeAccount) {
        let profiles = AgentProfileStore(accountTokens: MemoryClaudeTokens())
        let account = try profiles.claudeAccounts.add(name: "Work", token: "fake-ui-account-token")
        profiles.remoteClaudeAccounts = RemoteClaudeAccountService(accounts: profiles.claudeAccounts,
            runner: { _, arguments, input, _ in await transport.run(arguments: arguments, input: input) })
        return (profiles, account)
    }

    func testDestructiveSSHConfirmationUsesWindowOwnedLockAndCancelNeverSends() async throws {
        let transport = SSHAccountUITransport(), scope = TeamServiceTestScope()
        defer { scope.close() }
        let (profiles, account) = try profiles(transport)
        let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, agentProfiles: profiles,
            engineFactory: { XCTFail("SSH confirmation must not create a terminal"); return TestEngine() })
        defer { owner.terminate() }
        for kind in [RemoteClaudeAccountOperation.Kind.update, .remove] {
            owner.popups.presentSettings(section: .claudeAccounts)
            owner.popups.presentRemoteClaudeAccountOperation(account: account, host: "fictional-buildbox", kind: kind, profiles: profiles)
            let id = try XCTUnwrap(owner.popups.page?.id)
            XCTAssertTrue(owner.popups.locksDismissal)
            XCTAssertFalse(owner.popups.canGoBack)
            owner.popups.dismiss(reason: .dismiss)
            owner.popups.back()
            XCTAssertEqual(owner.popups.page?.id, id)
            XCTAssertTrue(owner.allSessions.isEmpty)
            owner.popups.dismiss(reason: .cancel)
            XCTAssertEqual(owner.popups.page?.title, "Settings")
            XCTAssertFalse(owner.popups.locksDismissal)
        }
        let count = await transport.count()
        XCTAssertEqual(count, 0)
    }

    func testChangedRevisionInvalidatesSSHConfirmationBeforeTransfer() async throws {
        let transport = SSHAccountUITransport()
        let (profiles, account) = try profiles(transport)
        let operation = RemoteClaudeAccountOperation(account: account, host: "fictional-buildbox", kind: .update, agentName: "Reviewer")
        XCTAssertFalse(operation.startAfterInstall)
        XCTAssertEqual(operation.primaryTitle, "Update on fictional-buildbox")
        try profiles.claudeAccounts.replaceToken(id: account.id, token: "fake-replacement")
        let success = await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts)
        XCTAssertFalse(success)
        XCTAssertTrue(operation.failed)
        XCTAssertFalse(operation.busy)
        XCTAssertEqual(operation.failureTitle, "The account changed while this confirmation was open.")
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(profiles.remoteClaudeAccounts.state(accountID: account.id, host: "fictional-buildbox"), .unchecked)
    }

    func testFailureRetainsSafeReasonAndRetryOnlyReportsSuccessAfterCurrentRevision() async throws {
        let transport = SSHAccountUITransport()
        let (profiles, account) = try profiles(transport)
        let operation = RemoteClaudeAccountOperation(account: account, host: "fictional-staging", kind: .install, agentName: "Reviewer")
        operation.startAfterInstall = true
        XCTAssertEqual(operation.primaryTitle, "Install and start Reviewer")
        await transport.fail("fictional-staging", code: 46)
        let first = await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts)
        XCTAssertFalse(first)
        XCTAssertTrue(operation.failed)
        XCTAssertEqual(operation.failureTitle, "Permission denied")
        XCTAssertEqual(operation.failureDetail, RemoteClaudeAccountFailure.permissions.message)
        XCTAssertEqual(profiles.remoteClaudeAccounts.state(accountID: account.id, host: "fictional-staging"), .failed(.permissions))
        await transport.fail("fictional-staging", code: nil)
        let retry = await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts)
        XCTAssertTrue(retry)
        XCTAssertFalse(operation.failed)
        XCTAssertFalse(operation.busy)
        XCTAssertEqual(profiles.remoteClaudeAccounts.state(accountID: account.id, host: "fictional-staging"), .current)
        let count = await transport.count()
        XCTAssertEqual(count, 2)
    }

    func testConnectionFailureHeadingsKeepRemoteOutcomeUncertain() async throws {
        let transport = SSHAccountUITransport()
        let (profiles, account) = try profiles(transport)
        await transport.fail("fictional-buildbox", code: 255)
        let expected = ["Couldn’t confirm Work’s installation on fictional-buildbox",
            "Couldn’t confirm Work’s update on fictional-buildbox", "Couldn’t confirm Work’s removal from fictional-buildbox"]
        for (index, kind) in [RemoteClaudeAccountOperation.Kind.install, .update, .remove].enumerated() {
            let operation = RemoteClaudeAccountOperation(account: account, host: "fictional-buildbox", kind: kind)
            let succeeded = await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts)
            XCTAssertFalse(succeeded)
            XCTAssertEqual([operation.failureHeading, operation.failureTitle, operation.failureDetail],
                [expected[index], "SSH connection failed", RemoteClaudeAccountFailure.connection.message])
        }
    }

    func testConsoleUnlockRequiresExplicitFalseInDictionaryOrPortableArray() {
        XCTAssertTrue(consoleIsUnlocked(["IOConsoleLocked": false]))
        XCTAssertTrue(consoleIsUnlocked([["IOConsoleLocked": false]]))
        XCTAssertFalse(consoleIsUnlocked(["IOConsoleLocked": true]))
        XCTAssertFalse(consoleIsUnlocked([["IOConsoleLocked": true]]))
        XCTAssertFalse(consoleIsUnlocked([String: Any]()))
        XCTAssertFalse(consoleIsUnlocked([[String: Any]]()))
    }

    func testRenderApprovedSSHFramesInBothAppearances() async throws {
        try requireUnlockedConsole()
        _ = NSApplication.shared
        AgentPadFonts.registerOnce()
        let scope = TeamServiceTestScope()
        let previousSettings = AgentPadSettingsModel.testModel
        let previousContent = NativeTabEngine.content
        let previousStores = SupportTabs.shared.navigation.router.stores
        let previousSettingsModel = SupportTabs.shared.settingsModel
        let previousTelegramSettings = SupportTabs.shared.telegramSettings
        defer {
            AgentPadSettingsModel.testModel = previousSettings
            NativeTabEngine.content = previousContent
            SupportTabs.shared.navigation.router.stores = previousStores
            SupportTabs.shared.settingsModel = previousSettingsModel
            SupportTabs.shared.telegramSettings = previousTelegramSettings
            scope.close()
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTPAD_SSH_ACCOUNT_SHOTS"]
            ?? FileManager.default.currentDirectoryPath + "/.build/ssh-account-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let unusedTelegram = TelegramSettingsViewModel(factory: { _ in fatalError("SSH UI rendering must not start Telegram") })
        SupportTabs.shared.telegramSettings = { unusedTelegram }
        for dark in [true, false] {
            let settings = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] }, write: { _ in }, appliesRuntimeEffects: false)
            AgentPadSettingsModel.testModel = settings
            SupportTabs.shared.settingsModel = { settings }
            for frame in ["hosts", "install", "blocked", "replaced", "failed", "remove"] {
                let transport = SSHAccountUITransport()
                let (profiles, initialAccount) = try profiles(transport)
                let profile = try profiles.add(template: .claudeCode, folder: FileManager.default.temporaryDirectory, name: "Reviewer")
                try profiles.setClaudeAccount(profileID: profile.id, accountID: initialAccount.id)
                let owner = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, agentProfiles: profiles,
                    engineFactory: { XCTFail("Rendering must not create a terminal"); return TestEngine() })
                defer { owner.terminate() }
                SupportTabs.shared.navigation.router.stores = { [owner] }
                NativeTabEngine.content = { SupportTabs.shared.content($0) }
                let hosts = ["devbox", "buildbox", "research", "staging"]
                for (index, host) in hosts.enumerated() {
                    let workspace = index == 0 ? try XCTUnwrap(owner.workspaces.first) : owner.addEmptyWorkspace()
                    workspace.sshRemoteHost = host
                }
                await transport.seed("devbox", revision: initialAccount.credentialRevision)
                await transport.seed("research", revision: UUID())
                await transport.fail("staging", code: 46)
                for host in hosts { _ = await profiles.remoteClaudeAccounts.check(accountID: initialAccount.id, host: host) }
                _ = await profiles.remoteClaudeAccounts.install(accountID: initialAccount.id, host: "staging")
                let selection = owner.popups.claudeAccountSSHSelection
                selection.accountID = initialAccount.id
                selection.remember(.install, accountID: initialAccount.id, host: "staging")
                if frame == "replaced" {
                    await transport.seed("research", revision: initialAccount.credentialRevision)
                    await transport.seed("staging", revision: initialAccount.credentialRevision)
                    try profiles.claudeAccounts.replaceToken(id: initialAccount.id, token: "fake-ui-replacement")
                    selection.replacedAccountID = initialAccount.id
                    _ = await profiles.remoteClaudeAccounts.check(accountID: initialAccount.id, host: "research")
                    _ = await profiles.remoteClaudeAccounts.install(accountID: initialAccount.id, host: "buildbox")
                    await transport.fail("staging", code: 255)
                    _ = await profiles.remoteClaudeAccounts.install(accountID: initialAccount.id, host: "staging")
                    selection.remember(.update, accountID: initialAccount.id, host: "staging")
                }
                let account = try XCTUnwrap(profiles.claudeAccounts.account(initialAccount.id))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentMinSize = NSSize(width: 1240, height: 760)
                window.setContentSize(NSSize(width: 1240, height: 760))
                defer { window.orderOut(nil) }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if frame == "blocked" {
                    let block = RemoteClaudeAccountBlock(accountID: account.id, accountName: account.name, host: "buildbox",
                        status: .notInstalled, profileName: "Reviewer", folder: "~/projects/agentpad")
                    window.contentView = NSHostingView(rootView: RemoteClaudeAccountBlockedView(block: block, onInstall: {}, onManage: {}))
                } else {
                    window.contentView = NSHostingView(rootView: Theme.chromeBackground.popupHost(owner.popups))
                    owner.popups.presentSettings(section: .claudeAccounts)
                    if frame == "install" || frame == "remove" {
                        owner.popups.presentRemoteClaudeAccountOperation(account: account, host: frame == "remove" ? "devbox" : "buildbox",
                            kind: frame == "remove" ? .remove : .install, profiles: profiles)
                    } else if frame == "failed" {
                        let operation = RemoteClaudeAccountOperation(account: account, host: "staging", kind: .install, agentName: "Reviewer")
                        _ = await operation.perform(accounts: profiles.claudeAccounts, service: profiles.remoteClaudeAccounts)
                        let native = PopupCoordinator.NativePage(title: operation.kind.title, width: 620,
                            locksDismissal: { operation.locksDismissal })
                        native.content = { AnyView(RemoteClaudeAccountOperationView(operation: operation, onCancel: {}, onConfirm: {}, onHosts: {})) }
                        owner.popups.presentNative(native)
                    }
                }
                window.makeKeyAndOrderFront(nil)
                for _ in 0..<12 {
                    window.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let content = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("claude-accounts-ssh-\(frame)\(dark ? "" : "-light").png"))
                XCTAssertGreaterThan(data.count, 1000)
                XCTAssertNil(window.attachedSheet)
                XCTAssertTrue(owner.allSessions.isEmpty)
            }
        }
    }

    private func requireUnlockedConsole() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-n", "Root", "-d1", "-a"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard process.terminationStatus == 0, consoleIsUnlocked(plist) else {
            throw NSError(domain: "ClaudeAccountSSHUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Console is locked. UI rendering requires an already unlocked console."])
        }
    }

    private func consoleIsUnlocked(_ plist: Any) -> Bool {
        let root = (plist as? [String: Any]) ?? (plist as? [[String: Any]])?.first
        return root?["IOConsoleLocked"] as? Bool == false
    }
}
