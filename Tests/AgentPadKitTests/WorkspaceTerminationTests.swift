import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class WorkspaceTerminationTests: XCTestCase {
    private func savedTab(in state: PersistedState?, id: UUID) throws -> PersistedTab {
        let root = try XCTUnwrap(state?.workspaces.first?.root)
        let tabs: [PersistedTab]? = switch root.kind {
        case .pane(let pane): pane.tabs
        case .split: nil
        }
        return try XCTUnwrap(tabs?.first { $0.id == id })
    }

    private enum ExitEvent: CaseIterable {
        case hook, status, launch, command, process

        @MainActor
        func emit(store: WorkspaceStore, tab: Session, agent: AgentTemplate) {
            let engine = tab.engine as! TestEngine
            switch self {
            case .hook:
                store.applyHookEvent(agent: agent, event: .ended, sessionId: tab.id)
            case .status:
                engine.emitTitle(AgentStatusMarker.title(slug: agent.initialCommand!, event: .ended))
            case .launch:
                if let launch = tab.pendingAgentLaunch {
                    engine.emitTitle("\(AgentLaunchExitMarker.prefix)\(launch.id):0")
                }
            case .command:
                engine.emitCommandFinished(exit: 0, duration: 1)
            case .process:
                engine.onProcessExitedCleanly?()
            }
        }
    }

    func testTerminationExitEventsPreserveAgentAndResume() throws {
        let fixture = try ClaudeResumeFixture()
        for agent in [AgentTemplate.claudeCode, .codex] {
            for event in ExitEvent.allCases {
                let persistence = InMemoryPersistence()
                let store = makeTestStore(persistence: persistence, claudeProjectsRoot: fixture.root)
                let workspace = try XCTUnwrap(store.active)
                // OSC 133 D also handles agents started by hand in a shell.
                let tab = store.addTab(in: workspace, template: event == .command ? .terminal : agent)
                store.applyHookEvent(agent: agent, event: .running, sessionId: tab.id)
                store.applyConversationId(conversationId: fixture.id, sessionId: tab.id)
                XCTAssertTrue(store.flushPersistence())
                let before = try XCTUnwrap(persistence.saved)
                let engine = try XCTUnwrap(tab.engine as? TestEngine)
                engine.onTerminate = { [weak store, weak tab] in
                    guard let store, let tab else { return }
                    XCTAssertTrue(store.isTerminated, "seal the store before stopping any engine")
                    event.emit(store: store, tab: tab, agent: agent)
                }

                store.terminate()
                // Both immediate shutdown output and already-queued callbacks
                // can arrive before AppDelegate's final post-drain flush.
                event.emit(store: store, tab: tab, agent: agent)
                XCTAssertEqual(tab.agent.id, agent.id, "\(agent.id): \(event)")
                XCTAssertEqual(tab.conversationId, fixture.id)
                XCTAssertNotNil(store.location(ofSessionId: tab.id))
                XCTAssertTrue(store.flushPersistence())
                XCTAssertEqual(persistence.saved, before, "\(agent.id): \(event)")

                let saved = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(persistence.saved))
                let restored = makeTestStore(persistence: InMemoryPersistence(initial: saved), claudeProjectsRoot: fixture.root,
                                             agentProfiles: store.agentProfiles)
                defer { restored.terminate() }
                let resumed = try XCTUnwrap(restored.allSessions.first { $0.id == tab.id })
                XCTAssertEqual(resumed.agent.id, agent.id)
                XCTAssertEqual(resumed.conversationId, fixture.id)
                XCTAssertEqual(resumed.resumedConversationId, fixture.id)
                let command = agent.id == AgentTemplate.claudeCodeID ? "claude --resume" : "codex resume"
                XCTAssertEqual((resumed.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"],
                               "\(command) \(fixture.id)")
            }
        }
    }

    func testUserExitStillPersistsPlainTerminalWithConversationId() throws {
        for agent in [AgentTemplate.claudeCode, .codex] {
            for event in [ExitEvent.hook, .status, .launch, .command] {
                let persistence = InMemoryPersistence()
                let store = makeTestStore(persistence: persistence)
                defer { store.terminate() }
                let workspace = try XCTUnwrap(store.active)
                let tab = store.addTab(in: workspace, template: event == .command ? .terminal : agent)
                let conversationID = UUID().uuidString.lowercased()
                store.applyHookEvent(agent: agent, event: .running, sessionId: tab.id)
                store.applyConversationId(conversationId: conversationID, sessionId: tab.id)

                event.emit(store: store, tab: tab, agent: agent)
                XCTAssertEqual(tab.agent.id, AgentTemplate.terminal.id, "\(agent.id): \(event)")
                XCTAssertEqual(tab.conversationId, conversationID)
                XCTAssertTrue(store.flushPersistence())
                let saved = try XCTUnwrap(persistence.saved)
                let persistedTab = try savedTab(in: saved, id: tab.id)
                XCTAssertEqual(persistedTab.agentId, AgentTemplate.terminal.id)
                XCTAssertEqual(persistedTab.conversationId, conversationID)
                let restored = makeTestStore(persistence: InMemoryPersistence(initial: saved))
                defer { restored.terminate() }
                let terminal = try XCTUnwrap(restored.allSessions.first { $0.id == tab.id })
                XCTAssertNil((terminal.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"])
            }
        }
    }

    func testFinalFlushUsesSnapshotBeforeEnginesTerminate() throws {
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        let tab = try XCTUnwrap(store.active?.activeSession)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        tab.customTitle = "Before quit"
        XCTAssertTrue(store.flushPersistence())
        let before = try XCTUnwrap(persistence.saved)
        engine.onTerminate = { [weak tab] in tab?.customTitle = "Teardown callback" }

        store.terminate()
        // AppKit may terminate the same store again from windowWillClose.
        store.terminate()
        XCTAssertEqual(engine.terminateCount, 1)
        XCTAssertTrue(store.flushPersistence())
        XCTAssertEqual(persistence.saved, before)
        XCTAssertNil(store.pendingSave)
    }

    func testCleanShellExitStillClosesItsTab() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let tab = store.addTab(in: workspace, template: .terminal)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)

        engine.onProcessExitedCleanly?()
        XCTAssertNil(store.location(ofSessionId: tab.id))
        XCTAssertEqual(engine.terminateCount, 1)
    }

    func testLastWindowHideKeepsAgentsLiveAndQuitKeepsThemResumable() throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let persistence = InMemoryPersistence()
        let store = makeTestStore(persistence: persistence)
        let controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let workspace = try XCTUnwrap(store.active)
        let tab = store.addTab(in: workspace, template: .codex)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        let conversationID = UUID().uuidString.lowercased()
        store.applyHookEvent(agent: .codex, event: .running, sessionId: tab.id)
        store.applyConversationId(conversationId: conversationID, sessionId: tab.id)

        controller.hideInsteadOfClose()
        XCTAssertTrue(controller.hiddenOnClose)
        XCTAssertFalse(store.isTerminated)
        XCTAssertEqual(engine.terminateCount, 0)
        // A hidden window still processes a real /exit.
        store.applyHookEvent(agent: .codex, event: .ended, sessionId: tab.id)
        XCTAssertEqual(tab.agent.id, AgentTemplate.terminal.id)
        store.applyHookEvent(agent: .codex, event: .running, sessionId: tab.id)

        store.terminate()
        ExitEvent.status.emit(store: store, tab: tab, agent: .codex)
        XCTAssertTrue(store.flushPersistence())
        let saved = try savedTab(in: persistence.saved, id: tab.id)
        XCTAssertEqual(saved.agentId, AgentTemplate.codex.id)
        XCTAssertEqual(saved.conversationId, conversationID)
    }
}
