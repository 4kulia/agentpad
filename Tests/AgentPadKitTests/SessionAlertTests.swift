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

    private func withUserShell(_ shell: String, body: () throws -> Void) rethrows {
        let previous = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell, 1)
        defer {
            if let previous { setenv("SHELL", previous, 1) }
            else { unsetenv("SHELL") }
        }
        try body()
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

    func testRunningSilentEndedFiresCompleted() async throws {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        guard let session = store.active?.activeSession else { return XCTFail("no session") }
        // `.running` promotes the shell tab to the agent (no alert); `.ended`
        // then fires an inbox-only completion — never attention/failure.
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
        XCTAssertTrue(alerts.isEmpty, "SessionEnd alone has no successful exit status")
        (session.engine as! TestEngine).emitCommandFinished(exit: 0, duration: 1)
        XCTAssertEqual(alerts, [.completed], "agent ended → one completion")
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


extension SessionAlertTests {
    func testManualBashAgentEndedCompletesWithoutCommandFinished() throws {
        try withUserShell("/bin/bash") {
            var alerts: [SessionAlertKind] = []
            let store = makeStore { alerts.append($1) }
            let session = try XCTUnwrap(store.active?.activeSession)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            XCTAssertEqual(engine.startedConfigs.last?.command, AgentPadShellIntegration.bashLauncherPath)
            XCTAssertNil(session.pendingAgentLaunch)

            for run in 1...2 {
                store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
                store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
                XCTAssertEqual(alerts, Array(repeating: .completed, count: run))
                XCTAssertFalse(session.awaitingAgentExitOutcome)
                XCTAssertEqual(session.notificationPhase, "exit")
                XCTAssertEqual(session.notificationEpisode, run)
                XCTAssertTrue(session.agent.isShell)
                XCTAssertEqual(session.activityState, .idle)
                XCTAssertNil(session.lastCommandExit, "ended does not supply an exit code")

                store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
                XCTAssertEqual(alerts.count, run, "a duplicate ended must not repeat completion")
            }
        }
    }

    func testRemoteAgentEndedCompletesBeforeSSHCloses() throws {
        for sshWorkspace in [false, true] {
            var alerts: [SessionAlertKind] = []
            let store = makeStore { alerts.append($1) }
            let workspace = sshWorkspace
                ? store.addWorkspace(sshRemoteHost: "build-box") : try XCTUnwrap(store.active)
            let session = try XCTUnwrap(workspace.activeSession)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            engine.emitTitle(RemoteLoginMarker.titlePrefix + "build-box")
            engine.emitTitle(AgentStatusMarker.title(slug: "claude", event: .running))
            engine.emitTitle(AgentStatusMarker.title(slug: "claude", event: .ended))

            XCTAssertEqual(alerts, [.completed])
            XCTAssertFalse(session.awaitingAgentExitOutcome)
            XCTAssertEqual(session.notificationPhase, "exit")
            XCTAssertEqual(session.notificationEpisode, 1)
            XCTAssertEqual(session.remoteHost, "build-box", "completion must not wait for SSH logout")
            XCTAssertNil(session.transientAgent)
            XCTAssertEqual(session.activityState, .idle)
            XCTAssertNil(session.lastCommandExit)

            engine.emitTitle(AgentStatusMarker.title(slug: "claude", event: .ended))
            engine.emitCommandFinished(exit: 0, duration: 1)
            engine.emitTitle(RemoteLoginMarker.logoutTitle)
            engine.emitCommandFinished(exit: 0, duration: 5)
            XCTAssertEqual(alerts, [.completed], "remote prompt and SSH exit must not repeat completion")
        }
    }

    func testBashAutoLaunchedAgentStillWaitsForItsExitStatus() throws {
        try withUserShell("/bin/bash") {
            var alerts: [SessionAlertKind] = []
            let store = makeStore { alerts.append($1) }
            let session = store.addTab(in: store.active!, template: .claudeCode)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            let launch = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_LAUNCH_ID"])
            store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
            store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
            XCTAssertTrue(alerts.isEmpty)
            XCTAssertTrue(session.awaitingAgentExitOutcome)

            engine.emitTitle("agentpad-launch-exit:\(launch):7")
            XCTAssertEqual(alerts, [.failure])
            XCTAssertFalse(session.awaitingAgentExitOutcome)
        }
    }

    func testAutoLaunchedAgentReportsItsOwnExitBeforeFirstPrompt() throws {
        for exit in [0, 7] {
            var alerts: [SessionAlertKind] = []
            let store = makeStore { alerts.append($1) }
            let session = store.addTab(in: store.active!, template: .claudeCode)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            let launch = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_LAUNCH_ID"])
            store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
            store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
            XCTAssertTrue(alerts.isEmpty)

            // An unrelated/old launch cannot pay this run's pending outcome.
            engine.emitTitle("agentpad-launch-exit:\(UUID()):0")
            engine.emitCommandFinished(exit: 0, duration: 0)
            XCTAssertTrue(alerts.isEmpty)

            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", AgentPadShellIntegration.agentLaunchBlock]
            process.environment = ["PATH": "/usr/bin:/bin", "AGENTPAD_AGENT": "(exit \(exit))", "AGENTPAD_LAUNCH_ID": launch]
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, Int32(exit))
            let marker = "agentpad-launch-exit:\(launch):\(exit)"
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}]2;\(marker)\u{7}")
            engine.emitTitle(marker)
            XCTAssertEqual(alerts, [exit == 0 ? .completed : .failure])
            XCTAssertFalse(session.awaitingAgentExitOutcome)
            XCTAssertEqual(session.lastCommandExit, exit)
            XCTAssertTrue(session.agent.isShell)

            // Late hooks, duplicate results and a first-prompt D do not replay.
            store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
            engine.emitTitle(marker)
            engine.emitCommandFinished(exit: exit, duration: 0)
            XCTAssertEqual(alerts.count, 1)
            engine.emitTitle(CommandMarker.titlePrefix + "true")
            engine.emitCommandFinished(exit: 0, duration: 1)
            XCTAssertEqual(alerts.count, 1, "the next shell command is not the agent's completion")
            engine.emitTitle(CommandMarker.titlePrefix + "false")
            engine.emitCommandFinished(exit: 1, duration: 1)
            XCTAssertEqual(alerts.last, .failure)
            XCTAssertEqual(alerts.count, 2)
        }
    }

    func testAutoLaunchedAgentWithoutLifecycleHooksStillFinishes() throws {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        let session = store.addTab(in: store.active!, template: .claudeCode)
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        let launch = try XCTUnwrap(engine.startedConfigs.last?.environment["AGENTPAD_LAUNCH_ID"])
        engine.emitTitle("agentpad-launch-exit:\(launch):127")
        XCTAssertEqual(alerts, [.failure])
        XCTAssertTrue(session.agent.isShell)
    }

    func testCompletionInputFailureKeepOriginalMeaning() {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        let session = store.active!.activeSession!
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .turnComplete, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .turnComplete, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id,
                             details: HookLifecycleDetails(notificationType: "permission_prompt", reason: .input))
        store.applyHookEvent(agent: .claudeCode, event: .turnFailure, sessionId: session.id)
        XCTAssertEqual(alerts, [.completed, .attention, .failure])
    }
    func testFailedAgentExitDoesNotDeliverPreliminarySuccess() async throws {
        var alerts: [SessionAlertKind] = []
        let store = makeStore { alerts.append($1) }
        let session = store.active!.activeSession!, engine = session.engine as! TestEngine
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .ended, sessionId: session.id)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(alerts.isEmpty)
        engine.emitCommandFinished(exit: 1, duration: 1)
        XCTAssertEqual(alerts, [.failure])
    }
    func testRunningAndCloseRetractTheInputEpisode() {
        var ended: [UUID] = []
        let store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() },
                                   onSessionWaitingEnded: { ended.append($0) })
        let session = store.active!.activeSession!
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        let first = session.notificationEpisode
        ended = []
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        XCTAssertEqual(ended, [session.id])
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
        XCTAssertGreaterThan(session.notificationEpisode, first)
        ended = []
        store.closeTab(session, in: store.active!)
        XCTAssertTrue(ended.contains(session.id))
    }
}
