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
        store.applyToolBatchResolved(sessionId: session.id)
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
