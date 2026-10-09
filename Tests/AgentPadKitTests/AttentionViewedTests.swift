import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class AttentionViewedTests: XCTestCase {
    private final class Window: NSWindow {
        var key = true
        var testVisible = true
        var minimized = false
        override var isKeyWindow: Bool { key }
        override var isVisible: Bool { testVisible }
        override var isMiniaturized: Bool { minimized }
    }

    private func window() -> Window {
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ session: Session, kind: AttentionKind) -> AttentionEvent {
        AttentionEvent(source: "terminal", object: session.id.uuidString, episode: session.attentionEpisode,
                       kind: kind, destination: .terminal(session.id))
    }

    private func rows(_ ledger: AttentionLedger, session: Session) -> [AttentionItem] {
        AttentionList.items(ledger: ledger.events,
            current: .init(terminals: [session.id: .init(episode: session.attentionEpisode, failed: session.hasCurrentAttentionFailure)]),
            viewed: ledger.viewedAttentionIDs)
    }

    private func raise(_ kind: AttentionKind, session: Session, store: WorkspaceStore) {
        if kind == .input {
            store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
            store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        } else {
            (session.engine as! TestEngine).emitCommandFinished(exit: 1, duration: 0.1)
        }
    }

    func testOpeningTabClearsOnlyViewedEpisodeThroughRowAndDirectNavigation() async throws {
        for kind: AttentionKind in [.input, .failure] {
            let store = makeTestStore(), ledger = AttentionLedger(), window = window()
            defer { store.terminate(); window.contentView = nil; window.close() }
            let workspace = try XCTUnwrap(store.active), session = try XCTUnwrap(workspace.activeSession)
            let other = store.addTab(in: workspace)
            let pane = try XCTUnwrap(workspace.activePane)
            let host = TerminalTabHostView()
            host.onVisibilityChange = { ledger.markFocusedAttentionViewed() }
            window.contentView = host
            ledger.isFocused = { event in
                guard case .terminal(let id) = event.destination else { return false }
                return AttentionFocus.terminalVisible(id, in: store, window: window, appActive: true)
            }
            host.update(tabs: pane.tabs, activeTabId: other.id, grabsFocusOnMount: false)
            raise(kind, session: session, store: store)
            let first = event(session, kind: kind)
            ledger.upsert(first)
            XCTAssertEqual(rows(ledger, session: session).map(\.id), [first.id])

            let navigation = NotificationNavigation(ledger: ledger)
            navigation.ready = true
            navigation.validate = { _ in true }
            navigation.open = { _ in store.activateTab(session, in: workspace); return true }
            navigation.activate(first.id)
            XCTAssertEqual(rows(ledger, session: session).count, 1, "A route alone is not a visible tab")
            host.update(tabs: pane.tabs, activeTabId: session.id, grabsFocusOnMount: false)
            for _ in 0..<100 where !ledger.viewedAttentionIDs.contains(first.id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(rows(ledger, session: session).isEmpty)
            XCTAssertEqual(ledger.events.map(\.id), [first.id], "Viewing must retain Notifications history")
            XCTAssertTrue(kind == .input ? session.activityState == .attention : session.hasCurrentAttentionFailure)

            store.activateTab(other, in: workspace)
            host.update(tabs: pane.tabs, activeTabId: other.id, grabsFocusOnMount: false)
            ledger.upsert(first)
            XCTAssertTrue(rows(ledger, session: session).isEmpty, "A refresh cannot revive a viewed episode")
            raise(kind, session: session, store: store)
            let next = event(session, kind: kind)
            XCTAssertNotEqual(next.id, first.id)
            ledger.upsert(next)
            XCTAssertEqual(rows(ledger, session: session).map(\.id), [next.id])

            // Keyboard/tab-strip navigation reaches the same host without the row router.
            store.activateTab(session, in: workspace)
            host.update(tabs: pane.tabs, activeTabId: session.id, grabsFocusOnMount: false)
            let history = ledger.events
            for _ in 0..<100 where !ledger.viewedAttentionIDs.contains(next.id) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(rows(ledger, session: session).isEmpty)
            XCTAssertEqual(ledger.events, history, "Sidebar acknowledgement does not mutate Notifications")
        }
    }

    func testInactiveWindowHiddenWorkspaceAndHiddenViewDoNotCountAsViewed() throws {
        let store = makeTestStore(), ledger = AttentionLedger(), window = window()
        defer { store.terminate(); window.contentView = nil; window.close() }
        let workspace = try XCTUnwrap(store.active), session = try XCTUnwrap(workspace.activeSession)
        let view = session.engine.view
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.frame = window.contentView!.bounds
        var appActive = true
        ledger.isFocused = { _ in
            AttentionFocus.terminalVisible(session.id, in: store, window: window, appActive: appActive)
        }
        window.key = false
        raise(.input, session: session, store: store)
        let notice = event(session, kind: .input)
        ledger.upsert(notice)
        func remainsUnseen(file: StaticString = #filePath, line: UInt = #line) {
            ledger.validateAll()
            XCTAssertEqual(rows(ledger, session: session).map(\.id), [notice.id], file: file, line: line)
            XCTAssertFalse(ledger.event(notice.id)!.isRead, file: file, line: line)
        }
        store.activateTab(session, in: workspace)
        remainsUnseen()
        window.key = true; appActive = false
        remainsUnseen()
        appActive = true; window.testVisible = false
        remainsUnseen()
        window.testVisible = true; window.minimized = true
        remainsUnseen()
        window.minimized = false

        store.addWorkspace()
        store.activateTab(session, in: workspace)
        remainsUnseen() // The old view can still be mounted while the model points elsewhere.
        store.activateWorkspace(workspace)
        window.contentView?.isHidden = true
        remainsUnseen()
        window.contentView?.isHidden = false
        view.frame = .zero
        remainsUnseen()
        view.frame = window.contentView!.bounds
        workspace.zoomedPaneId = UUID()
        remainsUnseen()
        workspace.zoomedPaneId = nil
        ledger.validateAll()
        XCTAssertTrue(rows(ledger, session: session).isEmpty, "Visible selected tab in the active window counts")
    }

    func testAlreadyVisibleEpisodeIsAcknowledgedWithoutRemovingHistory() throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        ledger.isFocused = { _ in true }
        raise(.input, session: session, store: store)
        let notice = event(session, kind: .input)
        ledger.upsert(notice)
        XCTAssertTrue(rows(ledger, session: session).isEmpty)
        XCTAssertEqual(ledger.events.map(\.id), [notice.id])
    }

    func testSidebarProjectionUpdatesOnViewAndLeavesOtherReasonsVisible() throws {
        let store = makeTestStore(), ledger = AttentionLedger()
        let previousStores = AgentMonitor.shared.storesProvider
        AgentMonitor.shared.storesProvider = { [store] }
        defer { AgentMonitor.shared.storesProvider = previousStores; store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        raise(.failure, session: session, store: store)
        let failure = event(session, kind: .failure)
        let approval = AttentionEvent(source: "version", object: "approval", kind: .version, destination: .version(UUID()))
        ledger.upsert(failure); ledger.upsert(approval)
        let sidebar = AttentionSidebarModel(ledger: ledger)
        var changed = false
        withObservationTracking {
            XCTAssertEqual(sidebar.items.count, 2)
        } onChange: {
            MainActor.assumeIsolated { changed = true }
        }
        ledger.markAttentionViewed(failure)
        ledger.markAttentionViewed(approval)
        XCTAssertTrue(changed, "A viewed marker must update the observable sidebar immediately")
        XCTAssertEqual(sidebar.items.map(\.id), [approval.id])
        XCTAssertEqual(Set(ledger.events.map(\.id)), [failure.id, approval.id])
    }

    func testViewedMarkerSurvivesReloadAndReadAllDoesNotAcknowledgeTab() throws {
        let suite = "attention-viewed-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeTestStore()
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        raise(.failure, session: session, store: store)
        let notice = event(session, kind: .failure)
        let legacy = [notice.id: ["delivered": true, "read": true, "consumed": true, "hidden": false]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "AgentPad.notificationMetadata.v1")
        let metadata = NotificationDeliveryStore(defaults: defaults)
        XCTAssertEqual(metadata.markers[notice.id]?.delivered, true, "Old metadata must still decode")
        let ledger = AttentionLedger(metadata: metadata)
        ledger.upsert(notice)
        ledger.markAllRead()
        XCTAssertEqual(rows(ledger, session: session).count, 1, "Read in Notifications is not a tab view")
        let history = ledger.events
        ledger.markAttentionViewed(notice)
        XCTAssertTrue(rows(ledger, session: session).isEmpty)
        XCTAssertEqual(ledger.events, history)
        let restored = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults))
        restored.upsert(notice)
        XCTAssertTrue(rows(restored, session: session).isEmpty)
        XCTAssertEqual(restored.events, history)
    }

    func testExternalFocusAcknowledgesOnlyClickedEpisodeAndKeepsHistory() async {
        let monitor = ExternalSessionMonitor(), ledger = AttentionLedger()
        func session(pid: Int32 = 42, since: TimeInterval) -> ExternalAgentSession {
            ExternalAgentSession(pid: pid, sessionId: "same-conversation", kind: "interactive",
                cwd: URL(fileURLWithPath: "/tmp"), name: nil, status: .waiting(reason: nil),
                statusSince: Date(timeIntervalSince1970: since), startedAt: nil)
        }
        func rows() -> [String] {
            AttentionList.items(ledger: ledger.events, current: .init(), viewed: ledger.viewedAttentionIDs).map(\.id)
        }
        let first = session(since: 1), other = session(pid: 43, since: 1), next = session(since: 2)
        var notice = AttentionCoordinator.waitingEvent(first)
        notice.isRead = true // External sessions are initially read to suppress startup banners.
        ledger.upsert(notice)
        ledger.upsert(AttentionCoordinator.waitingEvent(other))
        XCTAssertEqual(rows().count, 2)
        let history = ledger.events
        monitor.focusTerminal = { _ in .noTerminalFound }
        let failed = await monitor.focus(first, ledger: ledger)
        XCTAssertEqual(failed, .noTerminalFound)
        XCTAssertEqual(rows().count, 2)
        monitor.focusTerminal = { _ in .focusedTab }
        _ = await monitor.focus(first, ledger: ledger)
        XCTAssertEqual(rows(), [AttentionCoordinator.waitingEvent(other).id])
        XCTAssertEqual(ledger.events, history)
        ledger.upsert(AttentionCoordinator.waitingEvent(first))
        XCTAssertEqual(rows().count, 1, "Polling the same wait cannot revive it")
        ledger.upsert(AttentionCoordinator.waitingEvent(next))
        XCTAssertEqual(rows().count, 2)

        // The focus result for the old snapshot must not acknowledge a newer wait.
        monitor.focusTerminal = { _ in .activatedAppOnly }
        _ = await monitor.focus(first, ledger: ledger)
        XCTAssertTrue(rows().contains(AttentionCoordinator.waitingEvent(next).id))
        _ = await monitor.focus(next, ledger: ledger)
        XCTAssertTrue(rows().contains(AttentionCoordinator.waitingEvent(next).id),
                      "Activating the app without switching to the tab is not a view")
        monitor.focusTerminal = { _ in .focusedTab }
        _ = await monitor.focus(next, ledger: ledger)
        XCTAssertEqual(rows(), [AttentionCoordinator.waitingEvent(other).id])
    }
}
