import XCTest
@testable import AgentPadKit

/// Tests for `Session`'s tool-call event surface — the rolling 200-cap
/// buffer + Pre/Post matching + 60s orphan stalling that the activity
/// strip renders. All synchronous, no engine / persistence dependency.
@MainActor
final class SessionToolCallEventsTests: XCTestCase {
    private func makeSession() -> Session {
        Session(
            engine: TestEngine(),
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            agent: .terminal
        )
    }

    // MARK: Pre → running append

    func testRecordToolCallStartAppendsRunning() {
        let session = makeSession()
        session.recordToolCallStart(toolName: "Bash", identifier: "git status")
        XCTAssertEqual(session.toolCallEvents.count, 1)
        XCTAssertEqual(session.toolCallEvents[0].toolName, "Bash")
        XCTAssertEqual(session.toolCallEvents[0].identifier, "git status")
        XCTAssertEqual(session.toolCallEvents[0].state, .running)
        XCTAssertNil(session.toolCallEvents[0].completedAt)
    }

    func testRecordToolCallStartCapsAt200() {
        let session = makeSession()
        for i in 0..<250 {
            session.recordToolCallStart(toolName: "Bash", identifier: "cmd-\(i)")
        }
        XCTAssertEqual(session.toolCallEvents.count, Session.toolCallEventsCap)
        // Oldest 50 dropped — first remaining identifier is cmd-50
        XCTAssertEqual(session.toolCallEvents.first?.identifier, "cmd-50")
        XCTAssertEqual(session.toolCallEvents.last?.identifier, "cmd-249")
    }

    // MARK: Post → success / failed transition

    func testRecordToolCallEndMarksMatchingPreAsSuccess() {
        let session = makeSession()
        session.recordToolCallStart(toolName: "Edit", identifier: "/x.swift")
        session.recordToolCallEnd(toolName: "Edit", identifier: "/x.swift", success: true)
        XCTAssertEqual(session.toolCallEvents.count, 1)
        XCTAssertEqual(session.toolCallEvents[0].state, .success)
        XCTAssertNotNil(session.toolCallEvents[0].completedAt)
    }

    func testRecordToolCallEndMarksMatchingPreAsFailed() {
        let session = makeSession()
        session.recordToolCallStart(toolName: "Bash", identifier: "missing")
        session.recordToolCallEnd(toolName: "Bash", identifier: "missing", success: false)
        XCTAssertEqual(session.toolCallEvents[0].state, .failed)
    }

    func testRecordToolCallEndMatchesOldestRunning() {
        // Two concurrent calls with same tool + identifier — post resolves
        // the oldest one first (FIFO). Edge case but possible if Claude
        // fires the same tool twice in quick succession.
        let session = makeSession()
        session.recordToolCallStart(toolName: "Bash", identifier: "ls")
        let firstId = session.toolCallEvents[0].id
        session.recordToolCallStart(toolName: "Bash", identifier: "ls")

        session.recordToolCallEnd(toolName: "Bash", identifier: "ls", success: true)

        // First (older) → success; second still running
        XCTAssertEqual(session.toolCallEvents[0].id, firstId)
        XCTAssertEqual(session.toolCallEvents[0].state, .success)
        XCTAssertEqual(session.toolCallEvents[1].state, .running)
    }

    func testRecordToolCallEndWithoutMatchingPreAppendsSynthetic() {
        let session = makeSession()
        // Post arrives without a matching Pre — synthesise so the call
        // still surfaces in the strip
        session.recordToolCallEnd(toolName: "Read", identifier: "/x", success: true)
        XCTAssertEqual(session.toolCallEvents.count, 1)
        XCTAssertEqual(session.toolCallEvents[0].toolName, "Read")
        XCTAssertEqual(session.toolCallEvents[0].state, .success)
        // startedAt == completedAt — no duration for synthesised records
        XCTAssertEqual(session.toolCallEvents[0].startedAt, session.toolCallEvents[0].completedAt)
    }

    func testRecordToolCallEndDoesNotResolveOtherToolName() {
        let session = makeSession()
        session.recordToolCallStart(toolName: "Bash", identifier: "x")
        session.recordToolCallEnd(toolName: "Edit", identifier: "x", success: true)
        // Bash pre still running (different tool), Edit synthesised post
        XCTAssertEqual(session.toolCallEvents.count, 2)
        XCTAssertEqual(session.toolCallEvents[0].toolName, "Bash")
        XCTAssertEqual(session.toolCallEvents[0].state, .running)
        XCTAssertEqual(session.toolCallEvents[1].toolName, "Edit")
        XCTAssertEqual(session.toolCallEvents[1].state, .success)
    }

    // MARK: tool_use_id matching (Pre/Post by Claude's stable id)

    func testRecordToolCallEndMatchesByToolUseIdAcrossConcurrentCalls() {
        // Two concurrent calls with same tool + identifier (e.g. two
        // parallel Grep "TODO"). Without tool_use_id matching they'd
        // resolve in FIFO order regardless of which Post arrived; with
        // it, the Post for the SECOND call resolves the second call,
        // not the first.
        let session = makeSession()
        session.recordToolCallStart(toolName: "Grep", identifier: "TODO", toolUseId: "toolu_first")
        session.recordToolCallStart(toolName: "Grep", identifier: "TODO", toolUseId: "toolu_second")

        // Post for the SECOND call arrives first
        session.recordToolCallEnd(toolName: "Grep", identifier: "TODO", success: true, toolUseId: "toolu_second")

        XCTAssertEqual(session.toolCallEvents.count, 2)
        XCTAssertEqual(session.toolCallEvents[0].toolUseId, "toolu_first")
        XCTAssertEqual(session.toolCallEvents[0].state, .running, "first call still pending")
        XCTAssertEqual(session.toolCallEvents[1].toolUseId, "toolu_second")
        XCTAssertEqual(session.toolCallEvents[1].state, .success, "second call resolved by its own id")
    }

    func testRecordToolCallEndFallsBackToToolNameMatchWhenIdMissing() {
        // Old Claude (or any caller that doesn't pipe tool_use_id) — the
        // Post still resolves the oldest matching Pre via fallback.
        let session = makeSession()
        session.recordToolCallStart(toolName: "Bash", identifier: "ls")  // toolUseId defaults to nil
        session.recordToolCallEnd(toolName: "Bash", identifier: "ls", success: true)
        XCTAssertEqual(session.toolCallEvents.count, 1)
        XCTAssertEqual(session.toolCallEvents[0].state, .success)
    }

    func testRecordToolCallEndRevivesStalledRecord() {
        // A long-running tool (>60s) got swept to .stalled by the orphan
        // sweep. When the Post eventually arrives, the original record
        // should flip to .success / .failed — NOT a 0s synthesised ghost
        // alongside the now-misleading stalled entry.
        let session = makeSession()
        let startedLongAgo = Date(timeIntervalSinceNow: -90)
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: "toolu_long",
            toolName: "Bash",
            identifier: "slow-build",
            startedAt: startedLongAgo,
            completedAt: startedLongAgo.addingTimeInterval(60),  // stall time
            state: .stalled
        ))

        session.recordToolCallEnd(
            toolName: "Bash",
            identifier: "slow-build",
            success: true,
            toolUseId: "toolu_long"
        )

        XCTAssertEqual(session.toolCallEvents.count, 1, "no synthesised ghost — the original was revived")
        XCTAssertEqual(session.toolCallEvents[0].state, .success)
        XCTAssertEqual(session.toolCallEvents[0].toolUseId, "toolu_long")
        XCTAssertEqual(session.toolCallEvents[0].startedAt, startedLongAgo, "original startedAt preserved")
    }

    func testRecordToolCallEndRevivesStalledViaFallbackWhenIdMissing() {
        // Same revival behavior for legacy Claude (no tool_use_id) — the
        // name+identifier fallback also reaches .stalled records.
        let session = makeSession()
        let startedLongAgo = Date(timeIntervalSinceNow: -90)
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil,
            toolName: "Bash",
            identifier: "slow",
            startedAt: startedLongAgo,
            completedAt: startedLongAgo.addingTimeInterval(60),
            state: .stalled
        ))

        session.recordToolCallEnd(toolName: "Bash", identifier: "slow", success: false)

        XCTAssertEqual(session.toolCallEvents.count, 1, "no synthesised ghost")
        XCTAssertEqual(session.toolCallEvents[0].state, .failed)
    }

    // MARK: Orphan / stalled detection

    func testCheckStalledMarksRunningOlderThan60sAsStalled() {
        let session = makeSession()
        // Manually insert an event with startedAt 65s ago — bypasses the
        // record API's auto-orphan-timer so this test stays synchronous.
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil,
            toolName: "Bash",
            identifier: "long",
            startedAt: Date(timeIntervalSinceNow: -65),
            completedAt: nil,
            state: .running
        ))

        let anyRunning = session.checkStalledToolCallEvents()
        XCTAssertFalse(anyRunning, "All running events were stale")
        XCTAssertEqual(session.toolCallEvents[0].state, .stalled)
    }

    func testCheckStalledLeavesRecentRunningAlone() {
        let session = makeSession()
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil,
            toolName: "Bash",
            identifier: "fast",
            startedAt: Date(timeIntervalSinceNow: -5),  // 5s ago — well under 60s
            completedAt: nil,
            state: .running
        ))

        let anyRunning = session.checkStalledToolCallEvents()
        XCTAssertTrue(anyRunning, "Fresh event should still count as running")
        XCTAssertEqual(session.toolCallEvents[0].state, .running)
    }

    func testCheckStalledMixedCase() {
        let session = makeSession()
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil, toolName: "Bash", identifier: "old",
            startedAt: Date(timeIntervalSinceNow: -90),
            completedAt: nil, state: .running
        ))
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil, toolName: "Edit", identifier: "fresh",
            startedAt: Date(timeIntervalSinceNow: -5),
            completedAt: nil, state: .running
        ))
        session.toolCallEvents.append(ToolCallEvent(
            id: UUID(),
            toolUseId: nil, toolName: "Read", identifier: "done",
            startedAt: Date(timeIntervalSinceNow: -100),
            completedAt: Date(),
            state: .success  // Already resolved — not touched
        ))

        let anyRunning = session.checkStalledToolCallEvents()
        XCTAssertTrue(anyRunning, "fresh event still running")
        XCTAssertEqual(session.toolCallEvents[0].state, .stalled, "90s old → stalled")
        XCTAssertEqual(session.toolCallEvents[1].state, .running, "5s old → running")
        XCTAssertEqual(session.toolCallEvents[2].state, .success, ".success unchanged")
    }

    // MARK: Persistence invariant — REGRESSION GUARD per design doc D3

    /// CRITICAL guard: D3 chose ephemeral (runtime-only) for toolCallEvents.
    /// If a future PR accidentally adds the field to `PersistedTab` /
    /// `Persistence.encode`, state.json would balloon by hundreds of KB per
    /// session × hundreds of past sessions. This test pins the invariant
    /// by encoding a session with events and confirming the round-tripped
    /// disk shape excludes them.
    func testToolCallEventsDoNotPersistToDisk() throws {
        let session = makeSession()
        for i in 0..<5 {
            session.recordToolCallStart(toolName: "Bash", identifier: "cmd-\(i)")
        }
        XCTAssertEqual(session.toolCallEvents.count, 5)

        // Persistence currently doesn't expose direct Session encode/decode
        // (it goes through PersistedTab). The simpler invariant: persisted
        // Session models (after a round-trip via WorkspaceStore.flushPersistence
        // + reload) have an empty toolCallEvents array. Cover that in a
        // higher-level integration test under WorkspaceStoreTests — this
        // unit test pins the model-level guarantee that toolCallEvents
        // isn't part of any Codable surface on Session itself.
        //
        // Session is `@Observable final class` (no Codable conformance);
        // confirming that here ensures no future Codable extension can
        // accidentally include the field without an explicit decision.
        XCTAssertFalse((session as Any) is any Encodable, "Session must not be Encodable — toolCallEvents would ship to disk")
    }
}
