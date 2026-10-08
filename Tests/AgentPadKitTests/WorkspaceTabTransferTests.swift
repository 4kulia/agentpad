import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class WorkspaceTabTransferTests: XCTestCase {
    private func engine(_ session: Session) -> TestEngine { session.engine as! TestEngine }

    private func snapshot(_ store: WorkspaceStore, _ persistence: InMemoryPersistence) throws -> PersistedState {
        store.flushPersistence()
        return try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(XCTUnwrap(persistence.saved)))
    }

    func testSplittingAnAgentAllocatesNoEngineAndCanSplitAnEmptyPane() throws {
        var engines: [TestEngine] = []
        let store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: {
            let engine = TestEngine(); engines.append(engine); return engine
        }, optionsProvider: { _ in nil })
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let source = try XCTUnwrap(workspace.activePane)
        let agent = store.addTab(in: workspace, template: .claudeCode)
        let count = engines.count
        let second = try XCTUnwrap(store.splitPane(source, orientation: .horizontal, in: workspace))
        let third = try XCTUnwrap(store.splitPane(second, orientation: .vertical, in: workspace))
        XCTAssertEqual(engines.count, count)
        XCTAssertEqual(source.activeTabId, agent.id)
        XCTAssertTrue(second.tabs.isEmpty && third.tabs.isEmpty)
        XCTAssertNil(second.activeTabId)
        XCTAssertEqual(workspace.activePaneId, third.id)
    }

    func testSidebarMoveKeepsLiveSessionAndEmptySource() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let source = try XCTUnwrap(store.active)
        let sourcePane = try XCTUnwrap(source.activePane)
        let session = try XCTUnwrap(source.activeSession)
        let terminal = engine(session)
        let view = terminal.view
        session.customTitle = "Review"
        session.activityState = .running
        session.conversationId = UUID().uuidString
        session.lastCommandText = "swift test"
        let destination = store.addWorkspace()
        let first = try XCTUnwrap(destination.activePane)
        let empty = try XCTUnwrap(store.splitPane(first, orientation: .horizontal, in: destination))
        var closed = false
        store.onBecameEmpty = { closed = true }
        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, in: destination))
        XCTAssertTrue(empty.activeTab === session)
        XCTAssertTrue(session.engine.view === view)
        XCTAssertEqual(terminal.startedConfigs.count, 1)
        XCTAssertEqual(terminal.terminateCount, 0)
        XCTAssertEqual(session.activityState, .running)
        XCTAssertEqual(session.lastCommandText, "swift test")
        XCTAssertEqual(session.customTitle, "Review")
        XCTAssertTrue(sourcePane.tabs.isEmpty)
        XCTAssertNil(sourcePane.activeTabId)
        XCTAssertTrue(store.workspaces.contains { $0 === source })
        XCTAssertFalse(closed)
        XCTAssertEqual(store.activeWorkspaceId, destination.id)
        XCTAssertFalse(store.canReopenClosedTab)
        terminal.emitPwd(NSTemporaryDirectory())
        XCTAssertEqual(destination.workingDirectory, session.currentDirectory)
        XCTAssertNotEqual(source.workingDirectory, destination.workingDirectory)
        store.focusPane(first, in: destination)
        terminal.onFocus?()
        XCTAssertEqual(destination.activePaneId, empty.id)
        XCTAssertEqual(store.activeWorkspaceId, destination.id)
    }

    func testNewWorkspaceUsesTabTitleAndNoPlaceholderSession() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let source = try XCTUnwrap(store.active)
        let session = try XCTUnwrap(source.activeSession)
        session.customTitle = "Build logs"
        let terminal = engine(session)
        let created = try XCTUnwrap(store.moveTabToNewWorkspace(session.id))
        XCTAssertEqual(created.title, "Build logs")
        XCTAssertEqual(created.root.allPanes.flatMap(\.tabs).map(\.id), [session.id])
        XCTAssertTrue(created.activeSession === session)
        XCTAssertEqual(created.workingDirectory, session.currentDirectory)
        XCTAssertNil(source.activeSession)
        XCTAssertEqual(terminal.startedConfigs.count, 1)
        XCTAssertEqual(terminal.terminateCount, 0)
        store.renameWorkspace(created, to: "Release checks")
        XCTAssertEqual(created.title, "Release checks")
        XCTAssertNil(store.moveTabToNewWorkspace(UUID()))
        XCTAssertEqual(store.workspaces.count, 2)
    }

    func testMovedChannelWorkspaceNeverPersistsItsAccessibleName() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let notifications = (ChatNotifications.badgeChanged, ChatNotifications.listIds)
        defer { (ChatNotifications.badgeChanged, ChatNotifications.listIds) = notifications }
        var badgeSettled = false
        ChatNotifications.badgeChanged = { badgeSettled = true }
        ChatNotifications.listIds = { [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("channel-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://transfer.example.com"), accountId: "me", orgId: "org")
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "session", deviceName: "Fixture", orgId: key.orgId), token: "fixture")
        service.session(for: key).snapshotOwed = false
        ChatOrgCurrent.shared.refresh(service)
        defer { service.stopFeed(); ChatOrgCurrent.shared.refresh() }
        let model = try XCTUnwrap(ChatOrgCurrent.shared.model)
        let secret = "private-channel-name"
        let visible = ChatOrgView(
            members: [.init(accountId: "me", handle: "me", name: "Me", role: "member")],
            teams: [.init(teamId: "team", name: "Team", isGeneral: false, archived: false, mine: true, members: ["me"])],
            rightsSession: "session",
            channels: [.init(channelId: "channel", teamId: "team", name: secret, archived: false, version: 1)],
            channelsServed: true
        )
        model.set(visible)
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let channel = store.openChannelTab(ChannelRef(key, channel: "channel"), in: try XCTUnwrap(store.active))
        XCTAssertEqual(channel.title, "#\(secret)", "the move starts while the channel name is visible")
        let created = try XCTUnwrap(store.moveTabToNewWorkspace(channel.id))
        XCTAssertEqual(created.title, "Channel")
        XCTAssertTrue(created.activeSession === channel)
        XCTAssertEqual((channel.engine as? ChannelTabEngine)?.starts, 0)
        let saved = try snapshot(store, persistence)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains(secret))

        var revoked = visible
        revoked.channels = []
        model.set(revoked)
        XCTAssertEqual(channel.title, "Channel")
        XCTAssertEqual(created.title, "Channel", "access revocation must hide the name everywhere")
        model.set(visible)
        service.sessionEnded("Signed out")
        XCTAssertEqual(channel.title, "Channel")
        XCTAssertEqual(created.title, "Channel", "sign-out must not leave a copied name")
        try service.saveSignIn(.init(server: key.server, accountId: "other", sessionId: "other-session", deviceName: "Fixture", orgId: key.orgId), token: "other-fixture")
        XCTAssertEqual(channel.title, "Channel")
        XCTAssertEqual(created.title, "Channel", "another account must not see the old name")
        let restored = makeTestStore(persistence: InMemoryPersistence(initial: saved))
        defer { restored.terminate() }
        XCTAssertEqual(restored.workspaces.first { $0.id == created.id }?.title, "Channel")
        // Drain sign-in/out notification work before restoring the app hooks.
        try await waitUntil { badgeSettled }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "timed out waiting for the condition", file: file, line: line)
    }

    func testMovingRelaunchedCodexKeepsDiscoveringItsNewRollout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try XCTUnwrap(CodexUsageMonitor.recentDayDirectories(under: root.appendingPathComponent("sessions"), days: 1).first)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let source = try XCTUnwrap(store.active)
        let session = try XCTUnwrap(source.activeSession)
        let terminal = engine(session)
        terminal.emitPwd(root.path)
        store.applyShellEnvironment(["CODEX_HOME": root.path], sessionId: session.id)
        let destination = store.addWorkspace()
        func rollout(_ id: String, used: Int) throws -> URL {
            let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path]])
            return try SessionStoreFixtures.writeFile("rollout-test-\(id).jsonl", in: day, lines: [
                String(decoding: meta, as: UTF8.self),
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\(used)}}}}"
            ])
        }
        let oldId = UUID().uuidString.lowercased(), newId = UUID().uuidString.lowercased()
        store.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
        _ = try rollout(oldId, used: 81)
        try await waitUntil { session.conversationId == oldId && session.codexUsage?.primaryUsedPercent == 81 }
        store.applyHookEvent(agent: .codex, event: .ended, sessionId: session.id)
        terminal.emitCommandFinished(exit: 0, duration: 1)
        XCTAssertNil(session.codexUsage)
        store.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
        XCTAssertEqual(session.conversationId, oldId, "the persisted id still describes the previous run")
        XCTAssertNil(session.resumedConversationId)

        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, in: destination))
        // Let the pending resolve/retry run before the new rollout exists.
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertNil(session.codexUsage, "moving must not attach the previous run's usage")
        _ = try rollout(newId, used: 12)
        try await waitUntil { session.conversationId == newId && session.codexUsage?.primaryUsedPercent == 12 }
        // Later lifecycle events must not pin discovery to the stale id either.
        store.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.conversationId, newId)
        XCTAssertEqual(session.codexUsage?.primaryUsedPercent, 12)
        let saved = try snapshot(store, persistence)
        let workspace = try XCTUnwrap(saved.workspaces.first { $0.id == destination.id })
        guard case .pane(let pane) = workspace.root.kind else { return XCTFail("expected one pane") }
        XCTAssertEqual(pane.tabs.first { $0.id == session.id }?.conversationId, newId)
        XCTAssertTrue(destination.activeSession === session)
        XCTAssertEqual(terminal.startedConfigs.count, 1)
        XCTAssertEqual(terminal.terminateCount, 0)
    }

    func testMoveBetweenHalvesKeepsEmptySplitAndSupportsReordering() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let left = try XCTUnwrap(workspace.activePane)
        let a = try XCTUnwrap(left.activeTab)
        let b = store.addTab(in: workspace)
        let c = store.addTab(in: workspace)
        let right = try XCTUnwrap(store.splitPane(left, orientation: .horizontal, in: workspace))
        XCTAssertTrue(store.handleTabDrop(droppedId: a.id, to: left, at: 3, in: workspace))
        XCTAssertEqual(left.tabs.map(\.id), [b.id, c.id, a.id])
        XCTAssertTrue(store.handleTabDrop(droppedId: a.id, to: right, at: 0, in: workspace))
        XCTAssertTrue(store.handleTabDrop(droppedId: c.id, to: right, at: 0, in: workspace))
        XCTAssertEqual(right.tabs.map(\.id), [c.id, a.id])
        XCTAssertTrue(store.handleTabDrop(droppedId: b.id, to: right, at: 20, in: workspace))
        XCTAssertEqual(right.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertTrue(left.tabs.isEmpty)
        XCTAssertEqual(workspace.root.allPanes.count, 2)
        XCTAssertTrue([a, b, c].allSatisfy { engine($0).terminateCount == 0 && engine($0).startedConfigs.count == 1 })
    }

    func testCancelInvalidAndSameWorkspaceDropsLeaveLayoutUntouched() throws {
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let session = try XCTUnwrap(workspace.activeSession)
        let before = try snapshot(store, persistence)
        store.draggingTabId = session.id
        XCTAssertTrue(store.draggedTab === session)
        store.draggingTabId = nil // Native draggingSession ended with no drop (Escape).
        XCTAssertFalse(store.handleTabDrop(droppedId: session.id, in: workspace))
        XCTAssertFalse(store.handleTabDrop(droppedId: UUID(), in: workspace))
        XCTAssertFalse(store.handleTabDrop(droppedId: session.id, to: Pane(), at: 0, in: workspace))
        XCTAssertNil(store.moveTabToNewWorkspace(UUID()))
        XCTAssertEqual(try snapshot(store, persistence), before)
        XCTAssertEqual(engine(session).terminateCount, 0)
    }

    func testTransferFromWorktreeDoesNotRequestRemovalOrLoseItsMetadata() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let parent = try XCTUnwrap(store.active)
        let worktree = store.addWorkspace(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                          worktreeParent: parent, worktreeBranch: "feature")
        let session = try XCTUnwrap(worktree.activeSession)
        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, in: parent))
        XCTAssertNil(store.pendingRemovalRequest)
        XCTAssertEqual(worktree.worktreeParentId, parent.id)
        XCTAssertEqual(worktree.worktreeBranch, "feature")
        XCTAssertTrue(worktree.activePane?.tabs.isEmpty == true)
        XCTAssertTrue(store.handleTabDrop(droppedId: session.id, in: worktree))
        XCTAssertTrue(worktree.activeSession === session)
    }

    func testMovedTabOpensPreviewInItsDestinationWorkspace() throws {
        let store = makeTestStore()
        defer { store.terminate(); FilePreviewModel.for(store).close() }
        let source = try XCTUnwrap(store.active)
        let session = try XCTUnwrap(source.activeSession)
        let destination = try XCTUnwrap(store.moveTabToNewWorkspace(session.id))
        store.activateWorkspace(source)
        let file = URL(fileURLWithPath: #filePath)
        engine(session).onOpenFile?(TerminalFileReference(url: file, line: 10, column: 2))
        XCTAssertEqual(store.activeWorkspaceId, destination.id)
        XCTAssertTrue(destination.activeSession === session)
        XCTAssertEqual(FilePreviewModel.for(store).url, file)
    }

    func testMovedLayoutRoundTripPreservesOrderFocusEmptyPanesAndConversation() throws {
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let source = try XCTUnwrap(store.active)
        let left = try XCTUnwrap(source.activePane)
        let terminal = try XCTUnwrap(source.activeSession)
        let agent = store.addTab(in: source, template: .grok)
        let conversation = try XCTUnwrap(agent.conversationId)
        let right = try XCTUnwrap(store.splitPane(left, orientation: .horizontal, in: source))
        if case .split(let orientation, let a, let b, _) = source.root.content {
            source.root.content = .split(orientation: orientation, first: a, second: b, fraction: 0.37)
        }
        XCTAssertTrue(store.handleTabDrop(droppedId: agent.id, to: right, at: 0, in: source))
        let created = try XCTUnwrap(store.moveTabToNewWorkspace(terminal.id))
        store.renameWorkspace(created, to: "Logs")
        let spare = try XCTUnwrap(store.splitPane(created.activePane!, orientation: .vertical, in: created))
        let saved = try snapshot(store, persistence)
        let restoredPersistence = InMemoryPersistence(initial: saved)
        let restored = makeTestStore(persistence: restoredPersistence)
        defer { restored.terminate() }
        XCTAssertEqual(try snapshot(restored, restoredPersistence).workspaces, saved.workspaces)
        XCTAssertEqual(restored.activeWorkspaceId, created.id)
        XCTAssertEqual(restored.active?.activePaneId, spare.id)
        XCTAssertNil(restored.active?.activeSession)
        let restoredSource = try XCTUnwrap(restored.workspaces.first { $0.id == source.id })
        XCTAssertTrue(restoredSource.root.pane(id: left.id)?.tabs.isEmpty == true)
        XCTAssertEqual(restoredSource.root.pane(id: right.id)?.activeTab?.conversationId, conversation)
        XCTAssertEqual(restored.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, 2)
    }

    func testEmptyWorkspaceRoundTripSpawnsNoReplacement() throws {
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let empty = try XCTUnwrap(store.active)
        let session = try XCTUnwrap(empty.activeSession)
        _ = store.moveTabToNewWorkspace(session.id)
        store.activateWorkspace(empty)
        let restored = makeTestStore(persistence: InMemoryPersistence(initial: try snapshot(store, persistence)))
        defer { restored.terminate() }
        XCTAssertEqual(restored.activeWorkspaceId, empty.id)
        XCTAssertNil(restored.active?.activeSession)
        XCTAssertTrue(restored.active?.activePane?.tabs.isEmpty == true)
        XCTAssertEqual(restored.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, 1)
    }

    func testMovedLocalAndSSHReconnectToOriginalHostsAfterRestore() throws {
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        defer { store.terminate() }
        let localWorkspace = try XCTUnwrap(store.active)
        let local = try XCTUnwrap(localWorkspace.activeSession)
        let remoteWorkspace = store.addWorkspace(sshRemoteHost: "deploy@example.com")
        let remote = try XCTUnwrap(remoteWorkspace.activeSession)
        XCTAssertTrue(store.handleTabDrop(droppedId: local.id, in: remoteWorkspace))
        XCTAssertTrue(store.handleTabDrop(droppedId: remote.id, in: localWorkspace))
        let restored = makeTestStore(persistence: InMemoryPersistence(initial: try snapshot(store, persistence)))
        defer { restored.terminate() }
        let tabs = restored.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }
        let restoredLocal = try XCTUnwrap(tabs.first { $0.id == local.id })
        let restoredRemote = try XCTUnwrap(tabs.first { $0.id == remote.id })
        XCTAssertNil(restoredLocal.sshWorkspaceHost)
        XCTAssertNil(engine(restoredLocal).pasteUploadHostProvider?())
        XCTAssertEqual(restoredRemote.sshWorkspaceHost, "deploy@example.com")
        XCTAssertEqual(engine(restoredRemote).pasteUploadHostProvider?(), "deploy@example.com")
        XCTAssertEqual(engine(remote).terminateCount, 0)
        XCTAssertEqual(engine(local).terminateCount, 0)
    }

    func testReopeningMovedSSHAndLocalTabsPreservesTheirConnection() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let localWorkspace = try XCTUnwrap(store.active)
        let local = try XCTUnwrap(localWorkspace.activeSession)
        store.addTab(in: localWorkspace)
        let remoteWorkspace = store.addWorkspace(sshRemoteHost: "deploy@example.com")
        let remote = try XCTUnwrap(remoteWorkspace.activeSession)
        store.addTab(in: remoteWorkspace)
        XCTAssertTrue(store.handleTabDrop(droppedId: local.id, in: remoteWorkspace))
        XCTAssertTrue(store.handleTabDrop(droppedId: remote.id, in: localWorkspace))
        store.closeTab(remote, in: localWorkspace)
        let reopenedRemote = try XCTUnwrap(store.reopenLastClosedTab())
        XCTAssertTrue(localWorkspace.activeSession === reopenedRemote)
        XCTAssertEqual(reopenedRemote.sshWorkspaceHost, "deploy@example.com")
        XCTAssertEqual(engine(reopenedRemote).startedConfigs.last?.environment["AGENTPAD_AGENT"], "agentpad-ssh 'deploy@example.com'")
        XCTAssertEqual(engine(reopenedRemote).pasteUploadHostProvider?(), "deploy@example.com")
        XCTAssertEqual(engine(reopenedRemote).isRemoteSessionProvider?(), true)

        store.closeTab(local, in: remoteWorkspace)
        let reopenedLocal = try XCTUnwrap(store.reopenLastClosedTab())
        XCTAssertTrue(remoteWorkspace.activeSession === reopenedLocal)
        XCTAssertNil(reopenedLocal.sshWorkspaceHost)
        XCTAssertNil(engine(reopenedLocal).startedConfigs.last?.environment["AGENTPAD_AGENT"])
        XCTAssertNil(engine(reopenedLocal).pasteUploadHostProvider?())
        XCTAssertEqual(engine(reopenedLocal).isRemoteSessionProvider?(), false)
        // An ordinary new tab still inherits its workspace's destination.
        XCTAssertEqual(store.addTab(in: remoteWorkspace).sshWorkspaceHost, "deploy@example.com")
    }
}
