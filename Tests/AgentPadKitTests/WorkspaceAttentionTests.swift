import AppKit
import AgentPadHookKit
import XCTest
@testable import AgentPadKit

/// The selected tab survives in a mounted, hidden workspace. Selection alone
/// must not acknowledge its wait, including when another window is key.
@MainActor
final class WorkspaceAttentionTests: XCTestCase {
    private final class Window: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
        override var isVisible: Bool { true }
        override var isMiniaturized: Bool { false }
    }

    private struct Context {
        let store: WorkspaceStore
        let window: Window
        let host: PaneTreeHostView
    }

    private enum Signal: CaseIterable {
        case inputHook, finished, idleReminder
        var kind: AttentionKind { self == .finished ? .completion : .input }
    }

    private var contexts: [Context] = []
    private var ledger: AttentionLedger!
    private var coordinator: AttentionCoordinator!
    private var client: RecordingNotificationCenter!
    private var manager: NotificationManager!

    override func setUp() async throws {
        ledger = AttentionLedger()
        coordinator = AttentionCoordinator()
        client = RecordingNotificationCenter()
        manager = NotificationManager(client: client)
        ledger.delivery = manager
        // Same per-window visibility composition as AppDelegate.isSessionVisible.
        coordinator.terminalFocused = { [unowned self] id in
            self.contexts.contains {
                AttentionFocus.terminalVisible(id, in: $0.store, window: $0.window, appActive: true)
            }
        }
        ledger.isFocused = { [unowned self] in self.coordinator.focused($0) }
    }

    override func tearDown() async throws {
        for context in contexts {
            visitHosts(context.host) { $0.onVisibilityChange = {} }
            context.store.terminate()
            context.window.contentView = nil
            context.window.close()
        }
        await manager.drain()
        contexts = []
        ledger = nil; coordinator = nil; client = nil; manager = nil
    }

    private func makeContext(key: Bool = true) -> Context {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { false },
            onSessionAlert: { [unowned self] id, kind in
                guard let workspace = self.contexts.flatMap({ $0.store.workspaces }).first(where: {
                    $0.root.pane(containingSessionId: id) != nil
                }), let session = workspace.root.pane(containingSessionId: id)?.tabs.first(where: { $0.id == id }),
                    let event = AttentionCoordinator.terminalEvent(session, kind: kind,
                        workspaceTitle: workspace.title, visibility: .init(channelIds: [])) else { return }
                self.ledger.upsert(event)
            }, onSessionWaitingEnded: { [unowned self] id in
                self.coordinator.endTerminalWaiting(id, ledger: self.ledger)
            })
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.key = key
        window.isReleasedWhenClosed = false
        let host = PaneTreeHostView(store: store)
        window.contentView = host
        let context = Context(store: store, window: window, host: host)
        contexts.append(context)
        return context
    }

    private func visitHosts(_ view: NSView, _ visit: (TerminalTabHostView) -> Void) {
        if let host = view as? TerminalTabHostView { visit(host) }
        for child in view.subviews { visitHosts(child, visit) }
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Workspace visibility did not settle", file: file, line: line)
    }

    private func render(_ context: Context) async throws {
        context.host.renderNow()
        try await eventually {
            context.host.layoutSubtreeIfNeeded()
            self.visitHosts(context.host) { host in
                host.onVisibilityChange = { [ledger = self.ledger!] in ledger.markFocusedAttentionViewed() }
            }
            return context.store.active!.root.allPanes.compactMap(\.activeTab).allSatisfy {
                let view = $0.engine.view
                return view.window === context.window && !view.frame.isEmpty
                    && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
            }
        }
    }

    private func show(_ workspace: Workspace, in context: Context) async throws {
        context.store.activateWorkspace(workspace)
        try await render(context)
    }

    private func hook(_ event: String, name: String, session: Session, store: WorkspaceStore,
                      notification: String? = nil) throws {
        var stdin = ["hook_event_name": name]
        stdin["notification_type"] = notification
        var payload = AgentPadHookKit.buildLifecyclePayload(agent: "claude", event: event, surface: session.id.uuidString)
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &payload, stdin: try JSONEncoder().encode(stdin))
        guard case let .agent(agent, event, id, details) = HookServer.parseMessage(try JSONEncoder().encode(payload)) else {
            return XCTFail("Hook payload did not reach the lifecycle decoder")
        }
        store.applyHookEvent(agent: agent, event: event, sessionId: id, details: details)
    }

    private func raise(_ signal: Signal, session: Session, in context: Context) async throws -> AttentionEvent {
        try hook("running", name: "UserPromptSubmit", session: session, store: context.store)
        if signal == .inputHook {
            try hook("attention", name: "Notification", session: session, store: context.store, notification: "idle_prompt")
        } else {
            try hook("turn_complete", name: "Stop", session: session, store: context.store)
            if signal == .idleReminder {
                await manager.drain()
                // The owner's delayed OSC banner, without assuming a Notification hook arrived.
                session.engine.onDesktopNotification?("Claude Code", "Claude is waiting for your input")
            }
        }
        await manager.drain()
        return try XCTUnwrap(ledger.events.first { $0.destination == .terminal(session.id) })
    }

    private func rows(for session: Session) -> [AttentionItem] {
        let ids = Set(ledger.events.filter { $0.destination == .terminal(session.id) }.map(\.id))
        let current = AttentionCurrent(terminals: Dictionary(uniqueKeysWithValues: contexts.flatMap { $0.store.allSessions }.map {
            ($0.id, .init(episode: $0.attentionEpisode, failed: $0.hasCurrentAttentionFailure,
                         finished: $0.hasCurrentAttentionCompletion))
        }))
        return AttentionList.items(ledger: ledger.events, current: current, viewed: ledger.viewedAttentionIDs)
            .filter { ids.contains($0.id) }
    }

    private func assertWaiting(_ event: AttentionEvent, signal: Signal, session: Session,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(event.kind, signal.kind, file: file, line: line)
        XCTAssertFalse(ledger.isFocused(event), file: file, line: line)
        XCTAssertFalse(ledger.viewedAttentionIDs.contains(event.id), file: file, line: line)
        XCTAssertFalse(ledger.event(event.id)!.isRead, file: file, line: line)
        XCTAssertEqual(rows(for: session).map(\.id), [event.id], "\(signal)", file: file, line: line)
        XCTAssertEqual(rows(for: session).map(\.tier), [1], file: file, line: line)
        XCTAssertTrue(client.submitted.contains { $0.id == event.id && $0.sound }, file: file, line: line)
    }

    private func workspaceCycle(split: Bool, twoWindows: Bool) async throws {
        let context = makeContext()
        let a = try XCTUnwrap(context.store.active)
        try await render(context)
        let b = context.store.addWorkspace()
        let food = try XCTUnwrap(b.activeSession)
        food.customTitle = "Food planner"
        let foodPane = try XCTUnwrap(b.activePane)
        var targets = [food]
        if split {
            _ = try XCTUnwrap(context.store.splitPane(foodPane, orientation: .horizontal, in: b))
            targets.append(context.store.addTab(in: b))
            context.store.activateTab(food, in: b)
        }
        try await render(context)
        let container = try XCTUnwrap(context.host.workspaceRootView(for: b.id))
        let otherWindow = twoWindows ? makeContext(key: false) : nil
        if let otherWindow { try await render(otherWindow) }

        for signal in Signal.allCases {
            try await show(a, in: context)
            XCTAssertTrue(container.isHidden)
            XCTAssertTrue(context.host.workspaceRootView(for: b.id) === container)
            XCTAssertEqual(b.activeSession?.id, food.id, "Food planner stays ACTIVE in the hidden workspace")
            for session in targets {
                XCTAssertEqual(b.root.pane(containingSessionId: session.id)?.activeTabId, session.id)
                XCTAssertTrue(session.engine.view.window === context.window, "Hidden workspace stays mounted")
                XCTAssertFalse(session.engine.view.isHidden, "Its own tab selection remains active")
                XCTAssertTrue(session.engine.view.isHiddenOrHasHiddenAncestor)
            }

            var foreign: AttentionEvent?
            if let otherWindow, let session = otherWindow.store.active?.activeSession {
                foreign = try await raise(signal, session: session, in: otherWindow)
                assertWaiting(foreign!, signal: signal, session: session)
            }
            var first: [AttentionEvent] = []
            for session in targets {
                let event = try await raise(signal, session: session, in: context)
                first.append(event)
                assertWaiting(event, signal: signal, session: session)
            }
            ledger.validateAll() // The periodic/foreground pass must also leave B unseen.
            for (session, event) in zip(targets, first) { assertWaiting(event, signal: signal, session: session) }

            try await show(b, in: context)
            // No direct markAttentionViewed: the real host's reveal callback must clear both panes.
            try await eventually { first.allSatisfy { self.ledger.viewedAttentionIDs.contains($0.id) } }
            for (session, event) in zip(targets, first) {
                XCTAssertTrue(rows(for: session).isEmpty)
                XCTAssertNotNil(ledger.event(event.id), "Viewing retains Notifications history")
            }
            if let foreign, let session = otherWindow?.store.active?.activeSession {
                assertWaiting(foreign, signal: signal, session: session)
            }

            try await show(a, in: context)
            var next: [AttentionEvent] = []
            for (session, previous) in zip(targets, first) {
                session.engine.onDesktopNotification?("Claude Code", "Claude is waiting for your input")
                XCTAssertTrue(rows(for: session).isEmpty, "The viewed wait must not revive on B → A")
                let event = try await raise(signal, session: session, in: context)
                XCTAssertNotEqual(event.id, previous.id, "A new wait in hidden B needs a new row")
                next.append(event)
                assertWaiting(event, signal: signal, session: session)
            }

            if let otherWindow {
                context.window.key = false
                otherWindow.window.key = true
                // AppDelegate's foreground/key-window path uses this same ledger operation.
                ledger.markFocusedAttentionViewed()
                XCTAssertTrue(rows(for: otherWindow.store.active!.activeSession!).isEmpty)
                try await show(b, in: context)
                ledger.validateAll()
                for (session, event) in zip(targets, next) {
                    assertWaiting(event, signal: signal, session: session)
                }
                otherWindow.window.key = false
                context.window.key = true
                ledger.markFocusedAttentionViewed()
            } else {
                try await show(b, in: context)
            }
            try await eventually { next.allSatisfy { self.ledger.viewedAttentionIDs.contains($0.id) } }
            for session in targets { XCTAssertTrue(rows(for: session).isEmpty) }
        }
    }

    func testActiveTabInHiddenWorkspaceKeepsInputAndFinishedRowsAcrossSwitches() async throws {
        try await workspaceCycle(split: false, twoWindows: false)
    }

    func testActiveTabsInHiddenSplitWorkspaceClearOnlyWhenBothPanesAreViewed() async throws {
        try await workspaceCycle(split: true, twoWindows: false)
    }

    func testTwoWindowsKeepHiddenWorkspaceAndNonKeyWindowWaitsUnseen() async throws {
        try await workspaceCycle(split: false, twoWindows: true)
    }

    func testTwoWindowsWithSplitsKeepEachWorkspaceWaitUntilItsWindowIsKey() async throws {
        try await workspaceCycle(split: true, twoWindows: true)
    }
}
