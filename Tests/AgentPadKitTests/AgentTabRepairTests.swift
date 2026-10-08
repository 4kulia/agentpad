import XCTest
@testable import AgentPadKit

@MainActor
final class AgentTabRepairTests: XCTestCase {
    private func tab(_ conversationId: String? = nil) -> PersistedTab {
        PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: "/tmp", conversationId: conversationId)
    }

    private func state(_ tabs: [PersistedTab]) -> PersistedState {
        let pane = PersistedPane(id: UUID(), tabs: tabs, activeTabId: tabs.first?.id)
        let workspace = PersistedWorkspace(id: UUID(), workingDirectoryPath: "/tmp",
                                          root: PersistedPaneNode(id: pane.id, kind: .pane(pane)))
        return PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id)
    }

    private func tabs(_ state: PersistedState) -> [PersistedTab] {
        func collect(_ node: PersistedPaneNode) -> [PersistedTab] {
            switch node.kind {
            case .pane(let pane): pane.tabs
            case let .split(_, first, second, _): collect(first) + collect(second)
            }
        }
        return state.workspaces.flatMap { collect($0.root) }
    }

    private func rollout(_ id: String, root: URL, metadataId: String? = nil) throws {
        try SessionStoreFixtures.writeFile("rollout-2025-01-02T10-00-00-\(id).jsonl",
            in: root.appendingPathComponent("2025/01/02"), lines: [
                #"{"type":"session_meta","payload":{"cwd":"/tmp","id":"\#(metadataId ?? id)"}}"#
            ])
    }

    @discardableResult
    private func repair(_ state: inout PersistedState, fixture: ClaudeResumeFixture,
                        visibility: ChannelConversationFilter = .init(channelIds: [])) -> Bool {
        AgentTabRepair.apply(to: &state, claudeProjectsRoot: fixture.root,
                             codexSessionsRoot: fixture.root.appendingPathComponent("codex"), visibility: visibility)
    }

    func testRepairsClaudeAndOldCodexRolloutAcrossSplitPanes() throws {
        let fixture = try ClaudeResumeFixture()
        let codexId = UUID().uuidString.lowercased()
        try rollout(codexId, root: fixture.root.appendingPathComponent("codex"))
        var claude = tab(fixture.id.uppercased())
        claude.customTitle = "Keep my title"
        claude.content = .terminal
        var duplicate = claude; duplicate.id = UUID()
        var saved = state([claude, duplicate])
        let second = state([tab(codexId)]).workspaces[0].root
        let first = saved.workspaces[0].root
        saved.workspaces[0].root = PersistedPaneNode(id: UUID(), kind: .split(
            orientation: .horizontal, first: first, second: second, fraction: 0.4))
        let original = saved

        XCTAssertTrue(repair(&saved, fixture: fixture))
        XCTAssertEqual(tabs(saved).map(\.agentId), [AgentTemplate.claudeCodeID, AgentTemplate.claudeCodeID, AgentTemplate.codex.id])
        XCTAssertEqual(tabs(saved).map(\.conversationId), [fixture.id, fixture.id, codexId])
        XCTAssertEqual(saved.agentTabRepair119Applied, true)
        XCTAssertEqual(tabs(saved).map(\.id), tabs(original).map(\.id))
        XCTAssertEqual(tabs(saved).map(\.customTitle), tabs(original).map(\.customTitle))
        XCTAssertEqual(tabs(saved).map(\.currentDirectoryPath), tabs(original).map(\.currentDirectoryPath))
        XCTAssertEqual(tabs(saved).map(\.content), tabs(original).map(\.content))
        XCTAssertEqual(saved.activeWorkspaceId, original.activeWorkspaceId)
        XCTAssertEqual(saved.workspaces[0].root.id, original.workspaces[0].root.id)
        guard case let .split(orientation, restoredFirst, restoredSecond, fraction) = saved.workspaces[0].root.kind,
              case .pane(let restoredPane) = restoredFirst.kind else { return XCTFail("lost split layout") }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(fraction, 0.4)
        XCTAssertEqual(restoredFirst.id, first.id)
        XCTAssertEqual(restoredSecond.id, second.id)
        XCTAssertEqual(restoredPane.activeTabId, claude.id)
    }

    func testMissingAmbiguousAndMismatchedFilesRemainTerminals() throws {
        let fixture = try ClaudeResumeFixture()
        let codexRoot = fixture.root.appendingPathComponent("codex")
        try rollout(fixture.id, root: codexRoot)
        let mismatchedId = UUID().uuidString.lowercased()
        try rollout(mismatchedId, root: codexRoot, metadataId: UUID().uuidString.lowercased())
        let directoryId = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("-tmp/\(directoryId).jsonl"),
                                                withIntermediateDirectories: true)
        let original = [tab(), tab(""), tab(" \n"), tab(UUID().uuidString), tab(fixture.id), tab(mismatchedId), tab(directoryId)]
        var saved = state(original)

        XCTAssertTrue(repair(&saved, fixture: fixture))
        XCTAssertEqual(tabs(saved), original)
        XCTAssertEqual(saved.agentTabRepair119Applied, true)
    }

    func testSecondLoadDoesNotRepairEvenIfMissingFileAppears() throws {
        let fixture = try ClaudeResumeFixture()
        let missingId = UUID().uuidString.lowercased()
        var saved = state([tab(missingId)])
        XCTAssertNil(saved.agentTabRepair119Applied)
        XCTAssertTrue(repair(&saved, fixture: fixture))
        let encoded = try JSONEncoder().encode(saved)
        var reloaded = try JSONDecoder().decode(PersistedState.self, from: encoded)
        try fixture.add(missingId)

        XCTAssertFalse(repair(&reloaded, fixture: fixture))
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(tabs(reloaded).first?.agentId, "terminal")
    }

    func testSkipsNativeTabsRemoteTabsAndChannelConversationIds() throws {
        let fixture = try ClaudeResumeFixture()
        let channel = ChannelRef(server: "https://chat.example.com", account: "a1", org: "o1", channel: "c1")
        var tool = tab(fixture.id); tool.content = .tool(.settings)
        var native = tab(fixture.id); native.content = .channel(channel)
        var legacyChannel = tab(fixture.id); legacyChannel.channel = channel
        var remote = tab(fixture.id); remote.sshWorkspaceHost = "server"
        var existingAgent = tab(fixture.id); existingAgent.agentId = AgentTemplate.ohMyPi.id
        let original = [tool, native, legacyChannel, remote, existingAgent]
        var saved = state(original)
        repair(&saved, fixture: fixture)
        XCTAssertEqual(tabs(saved), original)

        var inherited = state([tab(fixture.id)])
        inherited.workspaces[0].sshRemoteHost = "server"
        repair(&inherited, fixture: fixture)
        XCTAssertEqual(tabs(inherited).first?.agentId, "terminal")

        var local = tab(fixture.id); local.sshWorkspaceHost = ""
        var explicitLocal = state([local])
        explicitLocal.workspaces[0].sshRemoteHost = "server"
        repair(&explicitLocal, fixture: fixture)
        XCTAssertEqual(tabs(explicitLocal).first?.agentId, AgentTemplate.claudeCodeID)

        for visibility in [ChannelConversationFilter(channelIds: [fixture.id]), .init(channelIds: nil)] {
            var blocked = state([tab(fixture.id)])
            repair(&blocked, fixture: fixture, visibility: visibility)
            XCTAssertEqual(tabs(blocked).first?.agentId, "terminal")
        }
    }

    func testRestorePersistsRepairBeforeStartingEnginesAndResumesBothAgents() throws {
        let fixture = try ClaudeResumeFixture()
        let codexId = UUID().uuidString.lowercased()
        let codexRoot = fixture.root.appendingPathComponent("codex")
        try rollout(codexId, root: codexRoot)
        let legacy = state([tab(fixture.id), tab(codexId)])
        let windowId = UUID()
        let file = fixture.root.appendingPathComponent("state-v2.json")
        try JSONEncoder().encode(PersistedApp(windows: [.init(id: windowId, state: legacy)])).write(to: file)
        let app = AppPersistence(fileURL: file)
        let store = WorkspaceStore(persistence: WindowPersistence(windowId: windowId, app: app),
            engineFactory: {
                XCTAssertEqual(app.state(for: windowId)?.agentTabRepair119Applied, true)
                return TestEngine()
            }, optionsProvider: { _ in nil }, resumeProvider: { true },
            claudeProjectsRoot: fixture.root, codexSessionsRoot: codexRoot)
        defer { store.terminate() }

        XCTAssertEqual(store.allSessions.map(\.agent.id), [AgentTemplate.claudeCodeID, AgentTemplate.codex.id])
        XCTAssertEqual(store.allSessions.map(\.resumedConversationId), [fixture.id, codexId])
        XCTAssertEqual(store.allSessions.map { ($0.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"] },
                       ["claude --resume \(fixture.id)", "codex resume \(codexId)"])
        let persisted = try XCTUnwrap(AppPersistence(fileURL: file).state(for: windowId))
        XCTAssertEqual(persisted.agentTabRepair119Applied, true)
        XCTAssertEqual(tabs(persisted).map(\.agentId), [AgentTemplate.claudeCodeID, AgentTemplate.codex.id])
        let before = try Data(contentsOf: file)
        let reloaded = WorkspaceStore(persistence: WindowPersistence(windowId: windowId, app: AppPersistence(fileURL: file)),
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true },
            claudeProjectsRoot: fixture.root, codexSessionsRoot: codexRoot)
        defer { reloaded.terminate() }
        XCTAssertEqual(reloaded.allSessions.map(\.resumedConversationId), [fixture.id, codexId])
        XCTAssertEqual(try Data(contentsOf: file), before, "the second load must not rewrite the saved state")
    }

    func testRestoreDoesNotRetryMissingTranscriptOnSecondLoad() throws {
        let fixture = try ClaudeResumeFixture()
        let id = UUID().uuidString.lowercased()
        let first = InMemoryPersistence(initial: state([tab(id)]))
        let store = makeStore(persistence: first, fixture: fixture)
        defer { store.terminate() }
        let persisted = try XCTUnwrap(first.saved)
        XCTAssertEqual(persisted.agentTabRepair119Applied, true)
        XCTAssertEqual(store.allSessions.first?.agent.id, "terminal")
        try fixture.add(id)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(persisted))
        let second = InMemoryPersistence(initial: decoded)
        let reloaded = makeStore(persistence: second, fixture: fixture)
        defer { reloaded.terminate() }

        XCTAssertEqual(second.saveCount, 0)
        let terminal = try XCTUnwrap(reloaded.allSessions.first)
        XCTAssertEqual(terminal.agent.id, "terminal")
        XCTAssertEqual(terminal.conversationId, id)
        XCTAssertNil(terminal.resumedConversationId)
        XCTAssertNil((terminal.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"])
    }

    func testIntentionalExitInRepairedOrNewStateRemainsTerminalOnNextLoad() throws {
        let fixture = try ClaudeResumeFixture()
        for legacy in [true, false] {
            let first = InMemoryPersistence(initial: legacy ? state([tab(fixture.id)]) : nil)
            let store = makeStore(persistence: first, fixture: fixture)
            defer { store.terminate() }
            let session = try XCTUnwrap(store.allSessions.first)
            if !legacy {
                store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
                store.applyConversationId(conversationId: fixture.id, sessionId: session.id)
            }
            store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
            XCTAssertTrue(store.flushPersistence())
            let saved = try XCTUnwrap(first.saved)
            XCTAssertEqual(saved.agentTabRepair119Applied, true)
            XCTAssertEqual(tabs(saved).first?.agentId, "terminal")
            XCTAssertEqual(tabs(saved).first?.conversationId, fixture.id)
            let second = InMemoryPersistence(initial: saved)
            let reloaded = makeStore(persistence: second, fixture: fixture)
            defer { reloaded.terminate() }

            XCTAssertEqual(reloaded.allSessions.first?.agent.id, "terminal")
            XCTAssertNil(reloaded.allSessions.first?.resumedConversationId)
            XCTAssertEqual(second.saveCount, 0)
            XCTAssertTrue(reloaded.flushPersistence())
            XCTAssertEqual(second.saved, saved)
        }
    }

    private func makeStore(persistence: any Persistence, fixture: ClaudeResumeFixture) -> WorkspaceStore {
        WorkspaceStore(persistence: persistence, engineFactory: { TestEngine() },
                       optionsProvider: { _ in nil }, resumeProvider: { true },
                       claudeProjectsRoot: fixture.root, codexSessionsRoot: fixture.root.appendingPathComponent("codex"))
    }
}
