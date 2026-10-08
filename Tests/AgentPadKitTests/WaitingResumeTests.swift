import XCTest
@testable import AgentPadKit

/// AgentPad: a Claude tab that is waiting on the user goes back to running
/// once its main thread visibly moves on — and not while another main-thread
/// call, possibly the one being waited on, is still open.
@MainActor
final class WaitingResumeTests: XCTestCase {
    private var store: WorkspaceStore!
    private var session: Session!

    override func setUp() async throws {
        store = WorkspaceStore(
            persistence: InMemoryPersistence(),
            engineFactory: { TestEngine() },
            optionsProvider: { _ in nil },
            resumeProvider: { true }
        )
        session = try XCTUnwrap(store.active?.activeSession)
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
    }

    private func pre(_ id: String, mainThread: Bool = true) {
        store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: id, event: .pre,
                                 success: nil, toolUseId: id, sessionId: session.id, mainThread: mainThread)
    }

    private func post(_ id: String, mainThread: Bool = true) {
        store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: id, event: .post,
                                 success: true, toolUseId: id, sessionId: session.id, mainThread: mainThread)
    }

    private func waitForUser() {
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id)
    }

    func testAnsweredPermissionPromptResumes() {
        pre("b")
        waitForUser()
        XCTAssertEqual(session.activityState, .attention)
        post("b")
        XCTAssertEqual(session.activityState, .running)
    }

    /// The case from review: A runs while B waits for permission. A finishing
    /// says nothing about B.
    func testParallelCallFinishingKeepsWaiting() {
        pre("a")
        pre("b")
        waitForUser()
        post("a")
        XCTAssertEqual(session.activityState, .attention)
        post("b")
        XCTAssertEqual(session.activityState, .running)
    }

    func testNewCallWhileAnotherIsOpenKeepsWaiting() {
        pre("b")
        waitForUser()
        pre("c")
        XCTAssertEqual(session.activityState, .attention)
    }

    func testNewCallAfterAllFinishedResumes() {
        waitForUser()
        pre("c")
        XCTAssertEqual(session.activityState, .running)
    }

    func testSubagentCallsNeverResume() {
        pre("s", mainThread: false)
        waitForUser()
        post("s", mainThread: false)
        pre("t", mainThread: false)
        XCTAssertEqual(session.activityState, .attention)
    }

    private func batchResolved() {
        store.applyToolBatchResolved(sessionId: session.id)
    }

    /// A waiting call stays open however long the user takes: neither the
    /// strip's stall sweep nor its rolling cap may end the wait.
    func testLongWaitIsNotEndedByTheActivityStrip() {
        pre("a")
        pre("b")
        waitForUser()
        session.checkStalledToolCallEvents(now: Date().addingTimeInterval(2 * 60 * 60))
        for i in 0..<(Session.toolCallEventsCap + 10) { pre("sub\(i)", mainThread: false) }
        post("a")
        XCTAssertEqual(session.activityState, .attention)
    }

    /// Review case: the user denies B. A denied call reports no PostToolUse;
    /// the batch still resolves, and that ends the wait.
    func testDeniedPermissionResumesWhenTheBatchResolves() {
        pre("b")
        waitForUser()
        batchResolved()
        XCTAssertEqual(session.activityState, .running)
        // The denied call no longer blocks the next one.
        waitForUser()
        pre("c")
        post("c")
        XCTAssertEqual(session.activityState, .running)
    }

    /// A call whose end never came is forgotten at the next turn boundary.
    func testTurnBoundaryForgetsOpenCalls() {
        pre("lost")
        store.applyHookEvent(agent: .claudeCode, event: .idle, sessionId: session.id)
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        waitForUser()
        pre("c")
        XCTAssertEqual(session.activityState, .running)
    }

    func testBatchResolvedOutsideAWaitChangesNothing() {
        store.applyHookEvent(agent: .claudeCode, event: .idle, sessionId: session.id)
        batchResolved()
        XCTAssertEqual(session.activityState, .idle)
    }

    /// A call reported without a tool_use_id cannot be matched to its end;
    /// it keeps the tab waiting until its batch resolves.
    func testCallWithoutIdStaysOpenUntilTheBatchResolves() {
        store.applyToolCallEvent(agent: .claudeCode, toolName: "Bash", identifier: "b", event: .pre,
                                 success: nil, toolUseId: nil, sessionId: session.id, mainThread: true)
        pre("a")
        waitForUser()
        post("a")
        XCTAssertEqual(session.activityState, .attention)
        batchResolved()
        XCTAssertEqual(session.activityState, .running)
    }

    /// Another agent run in the same tab does not end Claude's open calls.
    func testOtherAgentsLifecycleKeepsClaudesOpenCalls() {
        pre("a")
        pre("b")
        store.applyHookEvent(agent: .codex, event: .ended, sessionId: session.id)
        waitForUser()
        post("a")
        XCTAssertEqual(session.activityState, .attention)
    }

    // MARK: Background work

    private func stop(subagents: Int, shells: Int) {
        store.applyHookEvent(agent: .claudeCode, event: subagents + shells > 0 ? .running : .attention,
                             sessionId: session.id,
                             details: HookLifecycleDetails(backgroundSubagents: subagents, backgroundShells: shells))
    }

    func testTurnEndingWithBackgroundWorkIsRunning() {
        stop(subagents: 1, shells: 1)
        XCTAssertEqual(session.activityState, .running)
        XCTAssertEqual(session.backgroundWork, Session.BackgroundWork(subagents: 1, shells: 1))
        XCTAssertEqual(AgentMonitor.state(of: session), .running)
    }

    func testIdleReminderDuringBackgroundWorkIsIgnored() {
        stop(subagents: 1, shells: 0)
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id,
                             details: HookLifecycleDetails(notificationType: "idle_prompt"))
        XCTAssertEqual(session.activityState, .running)
    }

    /// A background subagent asking for permission does need the user.
    func testPermissionPromptDuringBackgroundWorkStillWaits() {
        stop(subagents: 1, shells: 0)
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id,
                             details: HookLifecycleDetails(notificationType: "permission_prompt"))
        XCTAssertEqual(session.activityState, .attention)
        XCTAssertNil(session.backgroundWork)
    }

    func testFinalTurnWithoutBackgroundWorkWaitsAgain() {
        stop(subagents: 1, shells: 0)
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        stop(subagents: 0, shells: 0)
        XCTAssertEqual(session.activityState, .attention)
        XCTAssertNil(session.backgroundWork)
    }

    // MARK: Claude's own status

    private func claude(_ status: ExternalAgentSession.Status, since: Date) -> [ExternalAgentSession] {
        [ExternalAgentSession(pid: 1, sessionId: "conv-1", kind: "interactive", cwd: URL(fileURLWithPath: "/p"),
                              name: nil, status: status, statusSince: since, startedAt: nil)]
    }

    private func reconcile(_ status: ExternalAgentSession.Status, secondsAgo: TimeInterval) {
        store.reconcileWithClaudeStatus(claude(status, since: Date().addingTimeInterval(-secondsAgo)))
    }

    /// Review case: background work ended without waking the agent. Claude
    /// went idle; the tab must not stay "running · background" forever.
    func testIdleClaudeEndsStaleBackgroundWork() {
        session.conversationId = "conv-1"
        stop(subagents: 0, shells: 1)
        session.hookStateAt = Date().addingTimeInterval(-60)
        reconcile(.idle, secondsAgo: 5)
        XCTAssertEqual(session.activityState, .attention)
        XCTAssertNil(session.backgroundWork)
        XCTAssertEqual(session.attentionReason, .completion)
    }

    /// Review case: a prompt answered while another call still runs, or one
    /// granted to a background subagent. Claude is busy again; so is the tab.
    func testBusyClaudeEndsStaleWaiting() {
        session.conversationId = "conv-1"
        pre("a")
        pre("b")
        waitForUser()
        session.hookStateAt = Date().addingTimeInterval(-60)
        reconcile(.busy, secondsAgo: 5)
        XCTAssertEqual(session.activityState, .running)
    }

    /// Claude's status older than the last hook event is stale, not news.
    func testOlderClaudeStatusIsIgnored() {
        session.conversationId = "conv-1"
        waitForUser()
        reconcile(.busy, secondsAgo: 30)
        XCTAssertEqual(session.activityState, .attention)
    }

    /// A status that has not settled yet may still be catching up.
    func testFreshClaudeStatusWaitsToSettle() {
        session.conversationId = "conv-1"
        waitForUser()
        session.hookStateAt = Date().addingTimeInterval(-60)
        reconcile(.busy, secondsAgo: 0.5)
        XCTAssertEqual(session.activityState, .attention)
    }

    func testOtherConversationsAreIgnored() {
        session.conversationId = "conv-2"
        waitForUser()
        session.hookStateAt = Date().addingTimeInterval(-60)
        reconcile(.busy, secondsAgo: 5)
        XCTAssertEqual(session.activityState, .attention)
    }

    /// Review case: a hook processed after Claude already reported its new
    /// status must not block the correction forever.
    func testLongContradictionOverridesALateHook() {
        session.conversationId = "conv-1"
        stop(subagents: 1, shells: 0)
        let claudeIdleSince = Date().addingTimeInterval(-40)
        session.hookStateAt = Date().addingTimeInterval(-20)   // processed after Claude went idle
        store.reconcileWithClaudeStatus(claude(.idle, since: claudeIdleSince))
        XCTAssertEqual(session.activityState, .attention)
    }

    /// Review case: Stop(background) → permission prompt → answered → work
    /// ends. The end must still read as waiting on the user.
    func testBackgroundPermissionChainEndsWaiting() {
        session.conversationId = "conv-1"
        stop(subagents: 1, shells: 0)
        store.applyHookEvent(agent: .claudeCode, event: .attention, sessionId: session.id,
                             details: HookLifecycleDetails(notificationType: "permission_prompt"))
        session.hookStateAt = Date().addingTimeInterval(-60)
        reconcile(.busy, secondsAgo: 30)
        XCTAssertEqual(session.activityState, .running)
        reconcile(.idle, secondsAgo: 5)
        XCTAssertEqual(session.activityState, .attention)
    }

    func testDuplicateConversationIsLeftToHooks() {
        session.conversationId = "conv-1"
        waitForUser()
        session.hookStateAt = Date().addingTimeInterval(-60)
        let since = Date().addingTimeInterval(-5)
        store.reconcileWithClaudeStatus(claude(.busy, since: since) + [
            ExternalAgentSession(pid: 2, sessionId: "conv-1", kind: "interactive", cwd: URL(fileURLWithPath: "/p"),
                                 name: nil, status: .idle, statusSince: since, startedAt: nil),
        ])
        XCTAssertEqual(session.activityState, .attention)
    }
}
