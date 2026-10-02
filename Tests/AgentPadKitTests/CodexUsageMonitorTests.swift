import XCTest
@testable import AgentPadKit

final class CodexUsageMonitorTests: XCTestCase {
    /// A real-shaped `token_count` rollout line (trimmed).
    private let tokenCountLine = """
    {"timestamp":"2026-05-08T10:08:33.984Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":26994,"cached_input_tokens":8576,"output_tokens":12,"reasoning_output_tokens":0,"total_tokens":27006},"last_token_usage":{"input_tokens":97981,"cached_input_tokens":8576,"output_tokens":567,"total_tokens":98548},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":8.0,"window_minutes":300,"resets_at":1778248098},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1778746993},"credits":null,"plan_type":"plus","rate_limit_reached_type":null}}}
    """

    func testParseTokenCountLineExtractsEveryField() {
        let usage = CodexUsageMonitor.parseTokenCountLine(tokenCountLine)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.primaryUsedPercent, 8.0)
        XCTAssertEqual(usage?.primaryWindowMinutes, 300)
        XCTAssertEqual(usage?.primaryResetsAt, Date(timeIntervalSince1970: 1778248098))
        XCTAssertEqual(usage?.secondaryUsedPercent, 10.0)
        XCTAssertEqual(usage?.secondaryWindowMinutes, 10080)
        XCTAssertEqual(usage?.secondaryResetsAt, Date(timeIntervalSince1970: 1778746993))
        XCTAssertEqual(usage?.planType, "plus")
        XCTAssertEqual(usage?.contextUsedTokens, 98548)         // last turn = context occupancy
        XCTAssertEqual(usage?.contextWindow, 258400)
        XCTAssertEqual(usage?.hasQuota, true)
    }

    func testParseTokenCountAcceptsIntegerPercent() {
        // JSON `100` (no decimal) must parse as well as `100.0`.
        let line = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5}},"rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":10},"plan_type":"pro"}}}
        """
        let usage = CodexUsageMonitor.parseTokenCountLine(line)
        XCTAssertEqual(usage?.primaryUsedPercent, 100.0)
        XCTAssertEqual(usage?.planType, "pro")
    }

    func testParseIgnoresNonTokenCountLines() {
        let meta = """
        {"type":"session_meta","payload":{"cwd":"/Users/me/proj","session_id":"x"}}
        """
        let response = """
        {"type":"response_item","payload":{"type":"message","role":"assistant"}}
        """
        XCTAssertNil(CodexUsageMonitor.parseTokenCountLine(meta))
        XCTAssertNil(CodexUsageMonitor.parseTokenCountLine(response))
        XCTAssertNil(CodexUsageMonitor.parseTokenCountLine("not json"))
    }

    func testLatestUsageMergesAndHoldsRateLimits() {
        // Second token_count carries fresher context tokens but a null
        // rate_limits — the merged result keeps the first line's window
        // percentages and advances the context occupancy.
        let second = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":110000},"model_context_window":258400},"rate_limits":null}}
        """
        let tail = tokenCountLine + "\n" + second
        let usage = CodexUsageMonitor.latestUsage(inTail: tail, droppingPartialHead: false)
        XCTAssertEqual(usage?.primaryUsedPercent, 8.0)        // held from line 1
        XCTAssertEqual(usage?.secondaryUsedPercent, 10.0)     // held from line 1
        XCTAssertEqual(usage?.contextUsedTokens, 110000)      // advanced to line 2
    }

    func testMergeHoldsEachFieldIndependently() {
        // A later line carries fresh context tokens + an updated primary reset,
        // but no `used_percent` and no secondary block. Each field must hold its
        // own newest non-nil: percentages survive, reset/context advance.
        let second = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":110000}},"rate_limits":{"primary":{"window_minutes":300,"resets_at":999}}}}
        """
        let usage = CodexUsageMonitor.latestUsage(inTail: tokenCountLine + "\n" + second, droppingPartialHead: false)
        XCTAssertEqual(usage?.primaryUsedPercent, 8.0)                       // held (line 2 omitted it)
        XCTAssertEqual(usage?.primaryResetsAt, Date(timeIntervalSince1970: 999))  // advanced
        XCTAssertEqual(usage?.secondaryUsedPercent, 10.0)                    // held (line 2 had no secondary)
        XCTAssertEqual(usage?.contextUsedTokens, 110000)                    // advanced
    }

    func testLatestUsageDropsPartialHead() {
        // A tail cut mid-file starts with a fragment; dropping it must not
        // crash and must still parse the following complete line.
        let tail = "8.0,\"window_minutes\":300}}}\n" + tokenCountLine
        let usage = CodexUsageMonitor.latestUsage(inTail: tail, droppingPartialHead: true)
        XCTAssertEqual(usage?.contextUsedTokens, 98548)
        XCTAssertEqual(usage?.primaryUsedPercent, 8.0)
    }

    func testLatestUsageNilWhenNoTokenCount() {
        let tail = """
        {"type":"session_meta","payload":{"cwd":"/x"}}
        {"type":"response_item","payload":{"type":"message"}}
        """
        XCTAssertNil(CodexUsageMonitor.latestUsage(inTail: tail, droppingPartialHead: false))
    }

    func testSessionMetaCwdReadsFirstLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-test.jsonl")
        let contents = """
        {"type":"session_meta","payload":{"cwd":"/Users/me/project","session_id":"abc"}}
        \(tokenCountLine)
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexUsageMonitor.sessionMetaCwd(atPath: file.path), "/Users/me/project")
    }

    func testSessionMetaConversationIdPrefersCanonicalId() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-id.jsonl")
        try """
        {"type":"session_meta","payload":{"cwd":"/Users/me/project","id":"canonical-id","session_id":"legacy-id"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            CodexUsageMonitor.sessionMetaConversationId(atPath: file.path),
            "canonical-id"
        )
    }

    func testSessionMetaConversationIdFallsBackToSessionId() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-fallback-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-id.jsonl")
        try """
        {"type":"session_meta","payload":{"cwd":"/Users/me/project","session_id":"fallback-id"}}
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            CodexUsageMonitor.sessionMetaConversationId(atPath: file.path),
            "fallback-id"
        )
    }

    func testResolveRolloutMatchesCwd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-resolve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dayDir = CodexUsageMonitor.recentDayDirectories(under: root, days: 1).first!
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let mine = dayDir.appendingPathComponent("rollout-mine.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/me/proj\"}}\n\(tokenCountLine)"
            .write(to: mine, atomically: true, encoding: .utf8)
        let other = dayDir.appendingPathComponent("rollout-other.jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/me/elsewhere\"}}\n"
            .write(to: other, atomically: true, encoding: .utf8)

        let resolved = CodexUsageMonitor.resolveRollout(
            forCwd: URL(fileURLWithPath: "/Users/me/proj"),
            sessionsRoot: root
        )
        XCTAssertEqual(resolved?.lastPathComponent, "rollout-mine.jsonl")

        let unmatched = CodexUsageMonitor.resolveRollout(
            forCwd: URL(fileURLWithPath: "/Users/me/nowhere"),
            sessionsRoot: root
        )
        XCTAssertNil(unmatched)
    }

    func testResolveRolloutExcludesPreexistingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-exclude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dayDir = CodexUsageMonitor.recentDayDirectories(under: root, days: 1).first!
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let cwd = URL(fileURLWithPath: "/Users/me/proj")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/me/proj\"}}\n\(tokenCountLine)"
        // A prior run's rollout exists; snapshot it (mirrors the monitor's
        // launch-time capture, and shares its symlink-resolved path strings).
        try meta.write(to: dayDir.appendingPathComponent("rollout-prior.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = CodexUsageMonitor.recentRolloutPaths(under: root)
        // This session's own rollout appears afterwards.
        try meta.write(to: dayDir.appendingPathComponent("rollout-mine.jsonl"), atomically: true, encoding: .utf8)

        // Excluding the pre-launch snapshot → adopt "mine" (the new one).
        XCTAssertEqual(
            CodexUsageMonitor.resolveRollout(forCwd: cwd, sessionsRoot: root, excluding: snapshot)?.lastPathComponent,
            "rollout-mine.jsonl"
        )
        // Nothing new since the snapshot (everything pre-existed) → nil, so the
        // gauge stays empty instead of adopting a prior run's file.
        XCTAssertNil(CodexUsageMonitor.resolveRollout(
            forCwd: cwd, sessionsRoot: root, excluding: CodexUsageMonitor.recentRolloutPaths(under: root)))
    }

    func testResolveResumedRolloutMatchesPreexistingConversationId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Resuming is not restricted to the fresh-launch three-day scan: Codex
        // can reopen an old rollout and append to it in place.
        let dayDir = root.appendingPathComponent("2025/01/02")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try """
        {"type":"session_meta","payload":{"cwd":"/Users/me/proj","id":"wanted-id"}}
        \(tokenCountLine)
        """.write(
            to: dayDir.appendingPathComponent("rollout-2025-01-02T10-00-00-wanted-id.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"type":"session_meta","payload":{"cwd":"/Users/me/proj","id":"other-id"}}
        """.write(
            to: dayDir.appendingPathComponent("rollout-2025-01-02T11-00-00-other-id.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let preexisting = CodexUsageMonitor.recentRolloutPaths(under: root)
        XCTAssertTrue(preexisting.isEmpty)
        XCTAssertEqual(
            CodexUsageMonitor.resolveRollout(
                conversationId: "wanted-id",
                sessionsRoot: root
            )?.lastPathComponent,
            "rollout-2025-01-02T10-00-00-wanted-id.jsonl"
        )
        XCTAssertNil(
            CodexUsageMonitor.resolveRollout(
                conversationId: "missing-id",
                sessionsRoot: root
            )
        )
    }

    func testRecentRolloutPathsListsRolloutFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dayDir = CodexUsageMonitor.recentDayDirectories(under: root, days: 1).first!
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let roll = dayDir.appendingPathComponent("rollout-a.jsonl")
        try "x".write(to: roll, atomically: true, encoding: .utf8)
        // A non-rollout file is ignored.
        try "x".write(to: dayDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let paths = CodexUsageMonitor.recentRolloutPaths(under: root)
        // basename, not full path — the API resolves /var→/private/var symlinks.
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }, "rollout-a.jsonl")
        _ = roll
    }

    func testSessionsRootHonorsShellCodexHome() {
        XCTAssertEqual(
            CodexUsageMonitor.sessionsRoot(shellEnv: ["CODEX_HOME": "/tmp/custom-codex"]).path,
            "/tmp/custom-codex/sessions"
        )
        // Tilde from the shell expands; empty falls through to the default.
        XCTAssertEqual(
            CodexUsageMonitor.sessionsRoot(shellEnv: ["CODEX_HOME": "~/alt-codex"]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("alt-codex/sessions").path
        )
        XCTAssertEqual(
            CodexUsageMonitor.sessionsRoot(shellEnv: [:]).path,
            CodexUsageMonitor.defaultSessionsRoot().path
        )
    }

    func testSessionMetaCwdReadsLineBeyond64KB() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-bigmeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-big.jsonl")
        // base_instructions ~100 KB pushes the session_meta line past the old
        // 64 KB fixed read; cwd must still parse (whole line is read).
        let bigInstructions = String(repeating: "x", count: 100_000)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/Users/me/proj\",\"base_instructions\":\"\(bigInstructions)\"}}"
        try (meta + "\n" + tokenCountLine).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexUsageMonitor.sessionMetaCwd(atPath: file.path), "/Users/me/proj")
    }

    func testLatestUsageAtPathReadsTail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpad-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-test.jsonl")
        let contents = """
        {"type":"session_meta","payload":{"cwd":"/x"}}
        \(tokenCountLine)
        """
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let usage = CodexUsageMonitor.latestUsage(atPath: file.path)
        XCTAssertEqual(usage?.contextUsedTokens, 98548)
        XCTAssertEqual(usage?.primaryUsedPercent, 8.0)
    }
}

final class CodexUsagePillFormatterTests: XCTestCase {
    func testWindowLabel() {
        XCTAssertEqual(CodexUsagePill.windowLabel(300), "5h")
        XCTAssertEqual(CodexUsagePill.windowLabel(10080), "7d")
        XCTAssertEqual(CodexUsagePill.windowLabel(90), "90m")
        XCTAssertNil(CodexUsagePill.windowLabel(nil))
        XCTAssertNil(CodexUsagePill.windowLabel(0))
    }

    func testRemainingInverts() {
        XCTAssertEqual(CodexUsagePill.remaining(32), 68)
        XCTAssertEqual(CodexUsagePill.remaining(0), 100)
        XCTAssertEqual(CodexUsagePill.remaining(100), 0)
        XCTAssertEqual(CodexUsagePill.remaining(120), 0)   // used >100 clamps
        XCTAssertEqual(CodexUsagePill.remaining(-5), 100)  // defensive clamp
    }

    func testPercentTextRounds() {
        XCTAssertEqual(CodexUsagePill.percentText(8.0), "8%")
        XCTAssertEqual(CodexUsagePill.percentText(99.6), "100%")
        XCTAssertEqual(CodexUsagePill.percentText(0), "0%")
    }

    func testResetText() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            CodexUsagePill.resetText(base.addingTimeInterval(3 * 3600 + 12 * 60), now: base),
            "resets in 3h 12m"
        )
        XCTAssertEqual(
            CodexUsagePill.resetText(base.addingTimeInterval(45 * 60), now: base),
            "resets in 45m"
        )
        XCTAssertEqual(
            CodexUsagePill.resetText(base.addingTimeInterval(2 * 86400 + 4 * 3600), now: base),
            "resets in 2d 4h"
        )
        XCTAssertEqual(CodexUsagePill.resetText(base.addingTimeInterval(-10), now: base), "resets now")
        XCTAssertNil(CodexUsagePill.resetText(nil))
    }

    func testContextUsedPercentMatchesCodexFormula() {
        // Codex discounts a 12k baseline from both used and window:
        // (27204-12000)/(353400-12000) ≈ 4.45% → ~5% used (not the naive 8%).
        XCTAssertEqual(CodexUsagePill.contextUsedPercent(used: 27204, window: 353400), 5)
        // Empty conversation (only the baseline in context) reads as 0% used.
        XCTAssertEqual(CodexUsagePill.contextUsedPercent(used: 12000, window: 353400), 0)
        XCTAssertEqual(CodexUsagePill.contextUsedPercent(used: 5000, window: 353400), 0)
        // Full window → 100%.
        XCTAssertEqual(CodexUsagePill.contextUsedPercent(used: 353400, window: 353400), 100)
        // Degenerate window (≤ baseline) → 0, no divide-by-zero.
        XCTAssertEqual(CodexUsagePill.contextUsedPercent(used: 5000, window: 8000), 0)
    }

    func testTokensText() {
        XCTAssertEqual(CodexUsagePill.tokensText(950), "950")
        XCTAssertEqual(CodexUsagePill.tokensText(27006), "27k")
        XCTAssertEqual(CodexUsagePill.tokensText(989754), "989k")
        XCTAssertEqual(CodexUsagePill.tokensText(1_500_000), "1.5M")
    }
}
