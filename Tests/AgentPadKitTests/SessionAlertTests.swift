import XCTest
@testable import AgentPadKit

/// Pins the notification trigger logic in `WorkspaceStore`: a session entering
/// attention or a command failing fires a banner-worthy `onSessionAlert`; an
/// agent ending fires an inbox-only `.completed`; same-state attention re-fires
/// are deduped. Visibility gating + the actual banner live in `AppDelegate` /
/// `NotificationManager` (AppKit state, tested manually).
@MainActor
final class SessionAlertTests: XCTestCase {
    private func makeStore(
        onAlert: @escaping @MainActor (UUID, SessionAlertKind) -> Void
    ) -> WorkspaceStore {
        WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true },
            onSessionAlert: onAlert
        )
    }

    func testEnteringAttentionFiresAttentionAlert() {
        var alerts: [(UUID, SessionAlertKind)] = []
        let store = makeStore { alerts.append(($0, $1)) }
        guard let session = store.active?.activeSession else { return XCTFail("no session") }
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.0, session.id)
        XCTAssertEqual(alerts.first?.1, .attention)
    }

    func testRepeatedAttentionDoesNotRefire() {
        // The @Observable setter re-runs on same-value assignment (Claude
        // re-fires per turn); the guard must keep us from re-notifying.
        var count = 0
        let store = makeStore { _, _ in count += 1 }
        guard let session = store.active?.activeSession else { return XCTFail("no session") }
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        XCTAssertEqual(count, 1, "same-state attention must not re-fire")
    }

    func testRunningSilentEndedFiresCompleted() {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        guard let session = store.active?.activeSession else { return XCTFail("no session") }
        // `.running` promotes the shell tab to the agent (no alert); `.ended`
        // then fires an inbox-only completion — never attention/failure.
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
        XCTAssertEqual(alerts, [.completed], "agent ended → one inbox completion")
    }

    func testFailedCommandFiresFailureAlert() {
        var alerts: [(UUID, SessionAlertKind)] = []
        let store = makeStore { alerts.append(($0, $1)) }
        guard let session = store.active?.activeSession,
              let engine = session.engine as? TestEngine
        else { return XCTFail("no session/engine") }
        engine.emitCommandFinished(exit: 1, duration: 0.5)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.0, session.id)
        XCTAssertEqual(alerts.first?.1, .failure)
    }

    func testSuccessfulCommandFiresNoAlert() {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        guard let session = store.active?.activeSession,
              let engine = session.engine as? TestEngine
        else { return XCTFail("no session/engine") }
        engine.emitCommandFinished(exit: 0, duration: 0.5)
        XCTAssertTrue(alerts.isEmpty, "exit 0 is success — no alert")
    }

    func testUserInputClearsStaleFailureDot() {
        // A failed command leaves a red dot; typing the first character of the
        // next command clears it (libghostty exposes no command-START signal).
        let store = makeStore { _, _ in }
        guard let session = store.active?.activeSession,
              let engine = session.engine as? TestEngine
        else { return XCTFail("no session/engine") }
        engine.emitCommandFinished(exit: 1, duration: 0.1)
        XCTAssertEqual(session.lastCommandExit, 1)
        engine.onUserInput?()
        XCTAssertNil(session.lastCommandExit, "first keystroke clears the stale failure dot")
        XCTAssertNil(session.lastCommandDuration)
    }
}
