import AppKit
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

@MainActor
final class TerminalAttentionTests: XCTestCase {
    private final class Window: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isVisible: Bool { true }
        override var isMiniaturized: Bool { false }
    }
    private var store: WorkspaceStore!
    private var session: Session!
    private var other: Session!
    private var window: Window!
    private var host: TerminalTabHostView!
    private var ledger: AttentionLedger!
    private var client: RecordingNotificationCenter!
    private var manager: NotificationManager!
    private var visibility = ChannelConversationFilter(channelIds: [])

    override func setUp() async throws {
        ledger = AttentionLedger()
        client = RecordingNotificationCenter()
        manager = NotificationManager(client: client)
        ledger.delivery = manager
        store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { false },
            onSessionAlert: { [unowned self] id, kind in
                guard let tab = self.store.allSessions.first(where: { $0.id == id }),
                      let event = AttentionCoordinator.terminalEvent(tab, kind: kind, workspaceTitle: "Workspace",
                                                                    visibility: self.visibility) else { return }
                self.ledger.upsert(event)
            }, onSessionWaitingEnded: { [unowned self] id in
                AttentionCoordinator().endTerminalWaiting(id, ledger: self.ledger)
            })
        session = try XCTUnwrap(store.active?.activeSession)
        other = store.addTab(in: try XCTUnwrap(store.active))
        window = Window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = TerminalTabHostView()
        window.contentView = host
        host.onVisibilityChange = { [unowned self] in self.ledger.markFocusedAttentionViewed() }
        ledger.isFocused = { [unowned self] event in
            guard case .terminal(let id) = event.destination else { return false }
            return AttentionFocus.terminalVisible(id, in: self.store, window: self.window, appActive: true)
        }
        show(other)
    }

    override func tearDown() async throws {
        host.onVisibilityChange = {}
        store.terminate()
        window.contentView = nil
        window.close()
        await manager.drain()
        store = nil; session = nil; other = nil; host = nil; window = nil
        ledger = nil; manager = nil; client = nil
    }

    private func show(_ tab: Session) {
        let workspace = store.active!
        store.activateTab(tab, in: workspace)
        host.update(tabs: workspace.activePane!.tabs, activeTabId: tab.id, grabsFocusOnMount: false)
    }

    private func hook(_ event: String, name: String, notification: String? = nil) throws {
        var stdin = ["hook_event_name": name]
        stdin["notification_type"] = notification
        var payload = AgentPadHookKit.buildLifecyclePayload(agent: "claude", event: event, surface: session.id.uuidString)
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &payload, stdin: try JSONEncoder().encode(stdin))
        guard case let .agent(agent, event, id, details) = HookServer.parseMessage(try JSONEncoder().encode(payload)) else {
            return XCTFail("Hook payload did not reach the lifecycle decoder")
        }
        store.applyHookEvent(agent: agent, event: event, sessionId: id, details: details)
    }

    private func reminder() {
        session.engine.onDesktopNotification?("Claude Code", "Claude is waiting for your input")
    }

    private func rows(settings: AttentionListSettings = .init()) -> [AttentionItem] {
        AttentionList.items(ledger: ledger.events,
            current: .init(terminals: Dictionary(uniqueKeysWithValues: store.allSessions.map {
                ($0.id, .init(episode: $0.attentionEpisode, failed: $0.hasCurrentAttentionFailure,
                             finished: $0.hasCurrentAttentionCompletion, title: "Claude tab"))
            })), settings: settings, viewed: ledger.viewedAttentionIDs)
    }

    func testSocketTurnCompleteWithBackgroundShellsOnNonVisibleTabRequestsNotificationAndFinishedRow() async throws {
        session = store.addTab(in: try XCTUnwrap(store.active), template: .claudeCode)
        show(session)
        let path = NSTemporaryDirectory() + "completion-\(UUID().uuidString.prefix(8)).sock"
        let started = expectation(description: "start, prompt and conversation hooks applied")
        started.expectedFulfillmentCount = 3
        let completed = expectation(description: "Stop hook applied")
        let server = HookServer(socketPath: path) { [unowned self] message in
            switch message {
            case .agent(let agent, let event, let id, let details):
                self.store.applyHookEvent(agent: agent, event: event, sessionId: id, details: details)
                (details.reason == .completion ? completed : started).fulfill()
            case .conversationId(let conversation, let id, let provenance, let failure, let hook):
                self.store.applyHookConversationId(conversationId: conversation, sessionId: id,
                    provenance: provenance, failure: failure, hook: hook)
                started.fulfill()
            default: XCTFail("Unexpected hook")
            }
        }
        server.start()
        defer { server.stop() }
        let conversation = UUID().uuidString.lowercased()
        for (event, name) in [("idle", "SessionStart"), ("running", "UserPromptSubmit")] {
            var payload = AgentPadHookKit.buildLifecyclePayload(agent: "claude", event: event, surface: session.id.uuidString)
            AgentPadHookKit.applyClaudeLifecycleDetails(to: &payload,
                stdin: try JSONEncoder().encode(["hook_event_name": name, "session_id": conversation]))
            let outgoing = payload
            let sent = await Task.detached { AgentPadHookKit.sendPayload(outgoing, to: path) }.value
            XCTAssertTrue(sent)
        }
        let mirrored = AgentPadHookKit.buildConversationIdPayload(surface: session.id.uuidString, conversationId: conversation)
        let mirroredSent = await Task.detached { AgentPadHookKit.sendPayload(mirrored, to: path) }.value
        XCTAssertTrue(mirroredSent)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(session.activityState, .running)
        XCTAssertEqual(session.conversationId, conversation)
        for id in ["shell-1", "shell-2"] {
            store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: id, event: .pre,
                success: nil, toolUseId: id, sessionId: session.id, mainThread: true)
        }
        XCTAssertEqual(session.openMainThreadCalls.count, 2)
        show(other)
        var completion = AgentPadHookKit.buildLifecyclePayload(agent: "claude", event: "turn_complete", surface: session.id.uuidString)
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &completion,
            stdin: try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Stop", "session_id": conversation,
                "background_tasks": [
                    ["id": "shell-1", "type": "shell", "status": "running"],
                    ["id": "shell-2", "type": "shell", "status": "running"],
                ],
            ]))
        let outgoing = completion
        let sent = await Task.detached { AgentPadHookKit.sendPayload(outgoing, to: path) }.value
        XCTAssertTrue(sent)
        await fulfillment(of: [completed], timeout: 3)
        await manager.drain()
        XCTAssertEqual(session.activityState, .attention)
        XCTAssertEqual(AgentMonitor.state(of: session), .attention)
        XCTAssertEqual(session.attentionReason, .completion)
        XCTAssertEqual(session.backgroundWork, .init(subagents: 0, shells: 2))
        XCTAssertTrue(session.openMainThreadCalls.isEmpty, "Stop ends the foreground batch even with shells open")
        XCTAssertEqual(client.submitted.count, 1)
        XCTAssertEqual(client.submitted.first?.sound, true)
        XCTAssertEqual(rows().map(\.tier), [1])
        XCTAssertEqual(rows().first?.subtitle, "Finished · waiting for you")
        XCTAssertEqual(rows().map(\.id), client.submitted.map(\.id))
        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertFalse(ledger.isFocused(event))
        XCTAssertFalse(ledger.viewedAttentionIDs.contains(event.id))

        // A settled shell status, even beyond the stale-hook override, is
        // background activity and must not retract the finished foreground turn.
        let now = session.hookStateAt.addingTimeInterval(60)
        let shellStatus = try XCTUnwrap(ExternalSessionParser.session(from: [
            "pid": 1, "sessionId": conversation, "cwd": "/p", "status": "shell",
            "statusUpdatedAt": now.addingTimeInterval(-5).timeIntervalSince1970 * 1000,
        ]))
        store.reconcileWithClaudeStatus([shellStatus], now: now)
        XCTAssertEqual(session.activityState, .attention)
        XCTAssertEqual(rows().map(\.id), [event.id])
        for id in ["shell-1", "shell-2"] {
            store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: id, event: .post,
                success: true, toolUseId: id, sessionId: session.id, mainThread: true)
            XCTAssertEqual(rows().map(\.id), [event.id], "Late tool ends must not resume a completed turn")
        }
        store.applyToolBatchResolved(sessionId: session.id)
        XCTAssertEqual(rows().first?.subtitle, "Finished · waiting for you")
        try hook("attention", name: "Notification", notification: "idle_prompt")
        reminder()
        await manager.drain()
        XCTAssertEqual(rows().map(\.id), [event.id])
        XCTAssertEqual(client.submitted.map(\.id), [event.id], "Background reminders share the completed episode")
        show(session)
        XCTAssertTrue(ledger.isFocused(event))
        ledger.markFocusedAttentionViewed()
        XCTAssertTrue(rows().isEmpty)
        show(other)
        reminder()
        await manager.drain()
        XCTAssertTrue(rows().isEmpty, "Background reminders cannot revive a viewed turn")
        XCTAssertEqual(client.submitted.map(\.id), [event.id])
    }

    func testNotificationHooksShowTierOneOnAnotherTabInTheActiveWindow() async throws {
        for type in ["idle_prompt", "permission_prompt"] {
            try hook("running", name: "UserPromptSubmit")
            try hook("turn_complete", name: "Stop")
            try hook("attention", name: "Notification", notification: type)
            let event = try XCTUnwrap(ledger.events.first { $0.kind == .input })
            XCTAssertFalse(ledger.isFocused(event))
            XCTAssertFalse(ledger.viewedAttentionIDs.contains(event.id))
            XCTAssertEqual(rows().map(\.id), [event.id])
            XCTAssertEqual(rows().map(\.tier), [1])
            try hook("attention", name: "Notification", notification: type)
            reminder()
            XCTAssertEqual(rows().map(\.id), [event.id])
            await manager.drain()
            XCTAssertTrue(client.delivered.contains(event.id))
            try hook("running", name: "UserPromptSubmit")
            XCTAssertTrue(rows().isEmpty)
        }
    }

    func testTerminalReminderForKnownWaitingAgentCreatesInputRowWithoutNotificationHook() async throws {
        try hook("running", name: "UserPromptSubmit")
        try hook("turn_complete", name: "Stop")
        let episode = session.attentionEpisode
        reminder() // Live 1.1.13 evidence: completion, then OSC reminder about a minute later.
        await manager.drain()
        XCTAssertEqual(session.attentionEpisode, episode, "OSC must not replace the turn's identity")
        XCTAssertEqual(rows().map(\.tier), [1])
        XCTAssertEqual(ledger.events.first?.kind, .input)
        let id = try XCTUnwrap(rows().first?.id)
        reminder()
        XCTAssertEqual(rows().map(\.id), [id])
        show(session)
        ledger.markFocusedAttentionViewed()
        XCTAssertTrue(rows().isEmpty)
        show(other)
        reminder()
        XCTAssertTrue(rows().isEmpty, "A reminder must not revive a viewed wait")
        try hook("running", name: "UserPromptSubmit")
        XCTAssertFalse(ledger.events.contains { $0.kind == .input })
    }

    func testOrdinaryProgramNotificationsDoNotCreateInputOrInvalidateFailure() throws {
        reminder() // A shell's arbitrary OSC text is not a lifecycle signal.
        XCTAssertEqual(ledger.events.first?.kind, .program)
        XCTAssertTrue(rows().isEmpty)
        try hook("running", name: "UserPromptSubmit")
        reminder()
        XCTAssertTrue(rows().isEmpty)
        try hook("turn_failure", name: "StopFailure")
        let failure = try XCTUnwrap(rows().first?.id)
        reminder()
        XCTAssertEqual(rows().map(\.id), [failure], "Program notifications must not invalidate the current failure")
        XCTAssertFalse(ledger.events.contains { $0.kind == .input })
    }

    func testToolProgressAndCloseClearInputButBackgroundIdleReminderDoesNotCreateIt() throws {
        try hook("running", name: "UserPromptSubmit")
        try hook("attention", name: "Notification", notification: "permission_prompt")
        XCTAssertEqual(rows().map(\.tier), [1])
        store.applyToolBatchResolved(sessionId: session.id)
        XCTAssertTrue(rows().isEmpty)
        session.backgroundWork = .init(subagents: 1, shells: 0)
        try hook("attention", name: "Notification", notification: "idle_prompt")
        reminder()
        XCTAssertEqual(session.activityState, .running)
        XCTAssertTrue(rows().isEmpty)
        try hook("attention", name: "Notification", notification: "permission_prompt")
        XCTAssertEqual(rows().map(\.tier), [1])
        store.closeTab(session, in: store.active!)
        XCTAssertTrue(rows().isEmpty)
    }

    func testExecutorAndUnreadableConversationFiltersBlockHookAndProgramEvents() throws {
        session.conversationId = UUID().uuidString
        for ids: Set<String>? in [[session.conversationId!], nil] {
            visibility = ChannelConversationFilter(channelIds: ids)
            try hook("running", name: "UserPromptSubmit")
            try hook("attention", name: "Notification", notification: "permission_prompt")
            reminder()
            XCTAssertTrue(ledger.events.isEmpty)
            XCTAssertTrue(rows().isEmpty)
        }
    }

    func testFinishedTurnAppearsImmediatelyAndViewedTurnStaysAcknowledgedThroughIdleHook() throws {
        try hook("running", name: "UserPromptSubmit")
        try hook("turn_complete", name: "Stop")
        let finished = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(finished.kind, .completion)
        XCTAssertEqual(rows().map(\.id), [finished.id])
        XCTAssertEqual(rows().map(\.tier), [1])
        XCTAssertEqual(rows().first?.subtitle, "Finished · waiting for you")
        XCTAssertNil(rows().first?.secondary)
        XCTAssertEqual(AttentionList.visible(rows(), expanded: false, collapsed: true).count, 1)
        XCTAssertTrue(rows(settings: .init(finished: false)).isEmpty)
        ledger.markAllRead()
        XCTAssertEqual(rows().count, 1, "Reading Notifications is not viewing the tab")
        show(session)
        ledger.markFocusedAttentionViewed()
        XCTAssertTrue(rows().isEmpty)
        show(other)
        try hook("attention", name: "Notification", notification: "idle_prompt")
        XCTAssertEqual(ledger.events.map(\.id), [finished.id])
        XCTAssertEqual(ledger.events.first?.kind, .input)
        XCTAssertTrue(rows().isEmpty, "A later idle reminder must not revive the finished turn")
        reminder()
        XCTAssertTrue(rows().isEmpty)
    }

    func testUnviewedFinishedTurnAndBothReminderPathsShareOneRowAndDelivery() async throws {
        try hook("running", name: "UserPromptSubmit")
        try hook("turn_complete", name: "Stop")
        let id = try XCTUnwrap(rows().first?.id)
        await manager.drain()
        reminder()
        try hook("attention", name: "Notification", notification: "idle_prompt")
        reminder()
        await manager.drain()
        XCTAssertEqual(rows().map(\.id), [id])
        XCTAssertEqual(ledger.events.map(\.id), [id])
        XCTAssertEqual(client.submitted.map(\.id), [id])
        XCTAssertEqual(rows(settings: .init(finished: false)).map(\.id), [id], "Input remains always shown")
    }

    func testWorkingAgainAndClosingHideCompletionButKeepHistoryAndNextTurnGetsNewRow() throws {
        try hook("running", name: "UserPromptSubmit")
        try hook("turn_complete", name: "Stop")
        let first = try XCTUnwrap(rows().first?.id)
        store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: "next turn", event: .pre,
            success: nil, toolUseId: "next-turn", sessionId: session.id, mainThread: true)
        XCTAssertTrue(rows().isEmpty)
        XCTAssertEqual(ledger.events.map(\.id), [first], "Resuming must retain completion history")
        try hook("turn_complete", name: "Stop")
        let next = try XCTUnwrap(rows().first?.id)
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(rows().count, 1)
        try hook("running", name: "UserPromptSubmit")
        XCTAssertTrue(rows().isEmpty)
        try hook("turn_complete", name: "Stop")
        XCTAssertEqual(rows().count, 1)
        store.closeTab(session, in: store.active!)
        XCTAssertTrue(rows().isEmpty)
        XCTAssertEqual(ledger.events.count, 3)
    }

    func testFocusedCompletionStaysViewedButNewPermissionPromptGetsItsOwnEpisode() throws {
        try hook("running", name: "UserPromptSubmit")
        show(session)
        try hook("turn_complete", name: "Stop")
        let id = try XCTUnwrap(ledger.events.first?.id)
        XCTAssertTrue(ledger.viewedAttentionIDs.contains(id))
        XCTAssertTrue(rows().isEmpty)
        show(other)
        try hook("attention", name: "Notification", notification: "permission_prompt")
        XCTAssertEqual(rows().map(\.tier), [1])
        XCTAssertNotEqual(rows().first?.id, id, "A real permission request is a new wait, even after a viewed turn")
    }
}
