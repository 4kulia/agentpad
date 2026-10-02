import XCTest
@testable import AgentPadKit

/// Unit tests for the pure helpers underlying `ToolCallActivityPill`.
/// The SwiftUI rendering itself is exercised manually (real Claude tab +
/// xushuhui mock per W2 design plan) — we test the data shaping
/// (counters, duration formatting, visibility predicate) so the chrome
/// row renders correct content without spinning up a SwiftUI host.
@MainActor
final class ToolCallActivityPillTests: XCTestCase {
    private func makeSession(agent: AgentTemplate = .claudeCode, activity: SessionActivityState = .running) -> Session {
        let session = Session(
            engine: TestEngine(),
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            agent: agent
        )
        session.activityState = activity
        return session
    }

    private func event(tool: String, state: ToolCallEventState, startedAt: Date = Date(), completedAt: Date? = nil) -> ToolCallEvent {
        ToolCallEvent(
            id: UUID(),
            toolUseId: nil,
            toolName: tool,
            identifier: "x",
            startedAt: startedAt,
            completedAt: completedAt,
            state: state
        )
    }

    // MARK: Counter aggregation

    func testToolCountsAggregatesByKind() {
        let session = makeSession()
        session.toolCallEvents = [
            event(tool: "Bash", state: .success),
            event(tool: "Bash", state: .running),
            event(tool: "Edit", state: .success),
            event(tool: "Edit", state: .failed),
            event(tool: "Write", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "Read", state: .success),
            event(tool: "WebFetch", state: .success),
        ]
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        XCTAssertEqual(counts.bash, 2)
        XCTAssertEqual(counts.edit, 3, "Edit + Write + MultiEdit aggregate together")
        XCTAssertEqual(counts.read, 3)
        XCTAssertEqual(counts.other, 1, "WebFetch / Glob / Grep / Task / unknown all bucket as other")
    }

    func testToolCountsMultiEditCountsAsEdit() {
        let session = makeSession()
        session.toolCallEvents = [event(tool: "MultiEdit", state: .success)]
        XCTAssertEqual(ToolCallActivityPill.toolCounts(in: session.toolCallEvents).edit, 1)
    }

    func testToolCountsBucketsPiLowercaseNames() {
        // Pi's lowercase tool names bucket the same as Claude's capitalized.
        let session = makeSession(agent: .pi)
        session.toolCallEvents = [
            event(tool: "bash", state: .success),
            event(tool: "edit", state: .success),
            event(tool: "write", state: .success),
            event(tool: "read", state: .success),
            event(tool: "find", state: .success),  // → other
        ]
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        XCTAssertEqual(counts.bash, 1)
        XCTAssertEqual(counts.edit, 2, "edit + write aggregate")
        XCTAssertEqual(counts.read, 1)
        XCTAssertEqual(counts.other, 1, "find buckets as other")
    }

    func testToolCountsEmptyEventsZero() {
        let session = makeSession()
        let counts = ToolCallActivityPill.toolCounts(in: session.toolCallEvents)
        XCTAssertEqual(counts.bash, 0)
        XCTAssertEqual(counts.edit, 0)
        XCTAssertEqual(counts.read, 0)
        XCTAssertEqual(counts.other, 0)
    }

    // MARK: Duration formatting

    func testFormatElapsedSubSecond() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(0.4), "0.4s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(0.95), "0.9s")
    }

    func testFormatElapsedSeconds() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(1.0), "1s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(12.4), "12s")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(59.7), "60s")
    }

    func testFormatElapsedMinutes() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(60), "1:00")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(125), "2:05")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(599), "9:59")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(3599), "59:59")
    }

    func testFormatElapsedHours() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(3600), "1:00:00")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(3661), "1:01:01")
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(45296), "12:34:56")
    }

    func testFormatElapsedDays() {
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(86400), "1d 0:00:00")
        // The reported "thousands of minutes" case: ~50h now reads as days.
        XCTAssertEqual(ToolCallActivityPill.formatElapsed(180000), "2d 2:00:00")
    }

    func testDurationLabelUsesCompletedAtWhenAvailable() {
        let start = Date(timeIntervalSinceNow: -10)
        let end = Date(timeIntervalSinceNow: -8)
        let resolved = event(tool: "Bash", state: .success, startedAt: start, completedAt: end)
        let label = ToolCallActivityPill.durationLabel(for: resolved)
        XCTAssertEqual(label, "2s")
    }

    func testDurationLabelUsesStableStatusForRunning() {
        let start = Date(timeIntervalSinceNow: -3)
        let running = event(tool: "Bash", state: .running, startedAt: start, completedAt: nil)
        XCTAssertEqual(
            ToolCallActivityPill.durationLabel(for: running),
            String(localized: "running", bundle: .agentPadResources)
        )
    }

    func testHistoryElapsedLabelUsesStableStatusWhileAnyToolRuns() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let events = [
            event(tool: "Read", state: .success, startedAt: start, completedAt: start.addingTimeInterval(2)),
            event(tool: "Bash", state: .running, startedAt: start.addingTimeInterval(3)),
        ]
        XCTAssertEqual(
            ToolCallActivityPill.historyElapsedLabel(for: events),
            String(localized: "running", bundle: .agentPadResources)
        )
    }

    func testHistoryElapsedLabelUsesFinalDurationAfterCompletion() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let events = [
            event(tool: "Read", state: .success, startedAt: start, completedAt: start.addingTimeInterval(2)),
            event(
                tool: "Bash",
                state: .success,
                startedAt: start.addingTimeInterval(3),
                completedAt: start.addingTimeInterval(8)
            ),
        ]
        XCTAssertEqual(ToolCallActivityPill.historyElapsedLabel(for: events), "8s")
    }

    // MARK: Accessibility

    func testRunningAccessibilityLabelDoesNotRepeatStatus() {
        let running = event(tool: "Bash", state: .running, completedAt: nil)
        XCTAssertEqual(
            ToolCallActivityPill.accessibilityLabel(for: running),
            "Bash, x, \(running.state.presentation.accessibleName)"
        )
    }

    func testCompletedAccessibilityLabelIncludesDurationAndState() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let completed = event(
            tool: "Bash",
            state: .success,
            startedAt: start,
            completedAt: start.addingTimeInterval(2)
        )
        XCTAssertEqual(
            ToolCallActivityPill.accessibilityLabel(for: completed),
            "Bash, x, 2s, \(completed.state.presentation.accessibleName)"
        )
    }

    // MARK: Tool kind → SF Symbol icon

    func testToolIconMappings() {
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Bash"), "terminal")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Edit"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Write"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("MultiEdit"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Read"), "doc.text")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Glob"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Grep"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("WebFetch"), "globe")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("WebSearch"), "globe")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("Task"), "rectangle.stack")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("UnknownTool"), "questionmark.app")
    }

    func testToolIconMatchesPiLowercaseNames() {
        // Pi reports its tool names lowercase (bash / read / edit / …); the
        // icon match is case-insensitive so they share Claude's icons, and
        // Pi's find / ls (no Claude equivalent) get their own.
        XCTAssertEqual(ToolCallActivityPill.toolIcon("bash"), "terminal")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("edit"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("write"), "pencil")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("read"), "doc.text")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("grep"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("find"), "magnifyingglass")
        XCTAssertEqual(ToolCallActivityPill.toolIcon("ls"), "list.bullet")
    }

    // MARK: Visibility predicate

    func testShowStripForClaudeAgentWithActivity() {
        let session = makeSession(agent: .claudeCode, activity: .running)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testShowStripForClaudeWithAttentionState() {
        let session = makeSession(agent: .claudeCode, activity: .attention)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testHideStripForClaudeIdle() {
        let session = makeSession(agent: .claudeCode, activity: .idle)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testHideStripForNonClaudeAgent() {
        let session = makeSession(agent: .codex, activity: .running)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testHideStripForTerminal() {
        let session = makeSession(agent: .terminal, activity: .running)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    func testShowStripForPiAgent() {
        // Pi feeds tool calls via its extension, so it gets the pill too.
        let session = makeSession(agent: .pi, activity: .running)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testShowStripForClaudeBaseCustomAgent() {
        // Custom agent based on Claude Code (per CLAUDE.md M5.uu) — gets the
        // strip because `fromCustom` inherits the base's `reportsToolCalls`,
        // even though its `id` differs from "claude-code".
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "claude-opus-custom", baseAgentId: "claude-code"))
        let session = makeSession(agent: custom, activity: .running)
        XCTAssertTrue(showToolCallActivityPill(for: session))
    }

    func testHideStripForNonReportingCustomAgent() {
        // A custom built on a non-reporting base (Codex) does NOT get the pill.
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "codex-fork", baseAgentId: "codex"))
        let session = makeSession(agent: custom, activity: .running)
        XCTAssertFalse(showToolCallActivityPill(for: session))
    }

    // MARK: Per-agent visibility toggle (Settings → Status Bar → Tool Calls)

    func testPerAgentToggleHidesOnlyThatAgent() {
        let model = AgentPadSettingsModel.shared
        let saved = model.hiddenToolCallAgents
        defer { model.hiddenToolCallAgents = saved }

        // Hiding Pi suppresses only Pi's pill; Claude still shows.
        model.hiddenToolCallAgents = ["pi"]
        XCTAssertFalse(showToolCallActivityPill(for: makeSession(agent: .pi, activity: .running)))
        XCTAssertTrue(showToolCallActivityPill(for: makeSession(agent: .claudeCode, activity: .running)))

        // Hiding Claude instead flips it — Pi shows, Claude hidden.
        model.hiddenToolCallAgents = ["claude-code"]
        XCTAssertFalse(showToolCallActivityPill(for: makeSession(agent: .claudeCode, activity: .running)))
        XCTAssertTrue(showToolCallActivityPill(for: makeSession(agent: .pi, activity: .running)))
    }

    func testPerAgentToggleFollowsBaseForCustom() {
        // A Claude-based custom is governed by the "claude-code" toggle, since
        // the gate keys on the base id.
        let model = AgentPadSettingsModel.shared
        let saved = model.hiddenToolCallAgents
        defer { model.hiddenToolCallAgents = saved }

        model.hiddenToolCallAgents = ["claude-code"]
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "claude-opus", baseAgentId: "claude-code"))
        XCTAssertFalse(showToolCallActivityPill(for: makeSession(agent: custom, activity: .running)))
    }
}
