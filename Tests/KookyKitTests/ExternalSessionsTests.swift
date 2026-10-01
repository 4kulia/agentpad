import XCTest
@testable import KookyKit

/// AgentPad: live Claude Code sessions from other terminals. Pins the parsing
/// of both sources, which sessions are dropped, ordering, and the AppleScript
/// the focuser sends. Focusing a real tab and SIGTERM-then-resume stay manual.
@MainActor
final class ExternalSessionsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func object(
        pid: Int = 4242, id: String = "s-1", cwd: String = "/Users/x/proj",
        status: String? = "idle", waitingFor: String? = nil, statusUpdatedAt: Double? = 1_790_000_000_000
    ) -> [String: Any] {
        var o: [String: Any] = ["pid": pid, "sessionId": id, "cwd": cwd, "name": "proj-1f", "startedAt": 1_789_000_000_000]
        if let status { o["status"] = status }
        if let waitingFor { o["waitingFor"] = waitingFor }
        if let statusUpdatedAt { o["statusUpdatedAt"] = statusUpdatedAt }
        return o
    }

    private func session(
        _ id: String, _ status: ExternalAgentSession.Status, since: TimeInterval?
    ) -> ExternalAgentSession {
        ExternalAgentSession(
            pid: 1, sessionId: id, kind: "interactive", cwd: URL(fileURLWithPath: "/p"), name: nil, status: status,
            statusSince: since.map { Date(timeIntervalSince1970: $0) }, startedAt: nil
        )
    }

    // MARK: Parsing

    func testParsesSessionFileFields() throws {
        let s = try XCTUnwrap(ExternalSessionParser.session(from: object(status: "waiting", waitingFor: "input needed")))
        XCTAssertEqual(s.pid, 4242)
        XCTAssertEqual(s.sessionId, "s-1")
        XCTAssertEqual(s.cwd.path, "/Users/x/proj")
        XCTAssertEqual(s.name, "proj-1f")
        XCTAssertEqual(s.status, .waiting(reason: "input needed"))
        XCTAssertEqual(s.statusSince, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(s.monitorState, .attention)
        XCTAssertFalse(s.canTakeOver)
    }

    func testStatusMapping() {
        XCTAssertEqual(ExternalAgentSession.Status(raw: "busy", waitingFor: nil), .busy)
        XCTAssertEqual(ExternalAgentSession.Status(raw: "shell", waitingFor: nil), .busy)
        XCTAssertEqual(ExternalAgentSession.Status(raw: "idle", waitingFor: nil), .idle)
        XCTAssertEqual(ExternalAgentSession.Status(raw: "compacting", waitingFor: nil), .other("compacting"))
        XCTAssertEqual(session("a", .other("x"), since: nil).monitorState, .idle)
    }

    func testRejectsRecordsMissingRequiredFields() {
        var noPid = object(); noPid.removeValue(forKey: "pid")
        var noId = object(); noId["sessionId"] = ""
        var relativeCwd = object(); relativeCwd["cwd"] = "proj"
        for bad in [noPid, noId, relativeCwd, object(pid: 0)] {
            XCTAssertNil(ExternalSessionParser.session(from: bad))
        }
    }

    func testMissingStatusIsUnknownAndNeverMovable() throws {
        var s = try XCTUnwrap(ExternalSessionParser.session(from: object(status: nil, statusUpdatedAt: nil)))
        s.processStart = 1
        XCTAssertEqual(s.status, .other("unknown"))
        XCTAssertNil(s.statusSince)
        XCTAssertFalse(s.canTakeOver)
    }

    func testOnlyVerifiedInteractiveIdleSessionsAreMovable() throws {
        var s = try XCTUnwrap(ExternalSessionParser.session(from: object()))
        XCTAssertFalse(s.canTakeOver, "not yet matched to a live process")
        s.processStart = 1
        XCTAssertTrue(s.canTakeOver)
        var background = object(); background["kind"] = "background"
        var b = try XCTUnwrap(ExternalSessionParser.session(from: background))
        b.processStart = 1
        XCTAssertFalse(b.canTakeOver)
    }

    func testRowIdentityIsTheProcessNotTheConversation() throws {
        let a = try XCTUnwrap(ExternalSessionParser.session(from: object(pid: 1, id: "same")))
        let b = try XCTUnwrap(ExternalSessionParser.session(from: object(pid: 2, id: "same")))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testParsesAgentsCommandOutput() throws {
        let data = try JSONSerialization.data(withJSONObject: [object(id: "a"), ["garbage": true], object(id: "b", status: "busy")])
        let sessions = try XCTUnwrap(ExternalSessionParser.sessions(fromAgentsJSON: data))
        XCTAssertEqual(sessions.map(\.sessionId), ["a", "b"])
        XCTAssertNil(ExternalSessionParser.sessions(fromAgentsJSON: Data("not json".utf8)))
    }

    func testReadsSessionDirectoryAndSkipsJunk() throws {
        try JSONSerialization.data(withJSONObject: object(id: "good"))
            .write(to: tempDir.appendingPathComponent("4242.json"))
        try Data("{broken".utf8).write(to: tempDir.appendingPathComponent("1.json"))
        try Data("x".utf8).write(to: tempDir.appendingPathComponent("4242.abc.key"))
        let sessions = try XCTUnwrap(ExternalSessionSource.readSessionFiles(in: tempDir))
        XCTAssertEqual(sessions.map(\.sessionId), ["good"])
        XCTAssertNil(ExternalSessionSource.readSessionFiles(in: tempDir.appendingPathComponent("missing")))
    }

    // MARK: Titles

    private func lines(_ objects: [[String: Any]]) throws -> [Data] {
        try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func testTitlePrefersRenameThenAITitleThenFirstPrompt() throws {
        let prompt: [String: Any] = ["type": "user", "message": ["content": "fix the login bug"]]
        let ai: [String: Any] = ["type": "ai-title", "aiTitle": "Login bug fix"]
        let rename: [String: Any] = ["type": "custom-title", "customTitle": "auth"]
        XCTAssertEqual(ExternalSessionParser.title(fromTranscriptLines: try lines([prompt])), "fix the login bug")
        XCTAssertEqual(ExternalSessionParser.title(fromTranscriptLines: try lines([prompt, ai])), "Login bug fix")
        XCTAssertEqual(ExternalSessionParser.title(fromTranscriptLines: try lines([prompt, ai, rename])), "auth")
    }

    func testLaterAITitleWinsAndInjectedPromptsAreSkipped() throws {
        let injected: [String: Any] = ["type": "user", "message": ["content": "<command-name>/model</command-name>"]]
        let first: [String: Any] = ["type": "ai-title", "aiTitle": "Old"]
        let second: [String: Any] = ["type": "ai-title", "aiTitle": "New"]
        XCTAssertNil(ExternalSessionParser.title(fromTranscriptLines: try lines([injected])))
        XCTAssertEqual(ExternalSessionParser.title(fromTranscriptLines: try lines([injected, first, second])), "New")
    }

    func testFindsTranscriptByFileNameAcrossProjectFolders() throws {
        let project = tempDir.appendingPathComponent("-Users-x-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("abc.jsonl")
        try Data().write(to: file)
        XCTAssertEqual(ExternalSessionSource.transcript(for: "abc", under: tempDir)?.lastPathComponent, file.lastPathComponent)
        XCTAssertNil(ExternalSessionSource.transcript(for: "zzz", under: tempDir))
    }

    func testIncrementalTitleReadsOnlyConsumeCompleteLines() throws {
        let root = tempDir.appendingPathComponent("projects/-p")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sid.jsonl")
        func line(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) + Data("\n".utf8) }
        try line(["type": "ai-title", "aiTitle": "First"]).write(to: file)
        let parts = try XCTUnwrap(ExternalSessionSource.titleParts(for: "sid", after: 0, under: tempDir.appendingPathComponent("projects")))
        XCTAssertEqual(parts.parts.best, "First")
        // A rename arrives in two writes; the first leaves half a line.
        let rename = try line(["type": "custom-title", "customTitle": "Renamed"])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: rename.prefix(10))
        let half = try XCTUnwrap(ExternalSessionSource.titleParts(for: "sid", after: parts.offset, under: tempDir.appendingPathComponent("projects")))
        XCTAssertNil(half.parts.custom)
        XCTAssertEqual(half.offset, parts.offset, "the partial line isn't consumed")
        try handle.write(contentsOf: rename.dropFirst(10))
        try handle.close()
        let whole = try XCTUnwrap(ExternalSessionSource.titleParts(for: "sid", after: half.offset, under: tempDir.appendingPathComponent("projects")))
        XCTAssertEqual(whole.parts.custom, "Renamed")
    }

    // MARK: Processes and ordering

    func testAncestorsWalkStopsAtLaunchdAndCycles() {
        let parents: [pid_t: pid_t] = [50: 40, 40: 30, 30: 1]
        XCTAssertEqual(ProcessInfoReader.ancestors(of: 50, parent: { parents[$0] }), [40, 30])
        let cycle: [pid_t: pid_t] = [5: 6, 6: 5]
        XCTAssertEqual(ProcessInfoReader.ancestors(of: 5, parent: { cycle[$0] }), [6, 5])
    }

    func testReaderSeesOurOwnProcess() throws {
        let info = try XCTUnwrap(ProcessInfoReader.info(of: getpid()))
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertGreaterThan(info.startTime, 0)
        XCTAssertTrue(ProcessInfoReader.isAlive(getpid()))
    }

    func testRecycledOrForeignPidDoesNotMatchTheSession() {
        let started = Date(timeIntervalSince1970: 1_000)
        func info(_ name: String, _ start: TimeInterval) -> ProcessInfoReader.Info {
            .init(ppid: 1, tty: nil, startTime: start, name: name)
        }
        XCTAssertTrue(ProcessInfoReader.matchesClaudeSession(info("claude", 998), startedAt: started))
        XCTAssertFalse(ProcessInfoReader.matchesClaudeSession(info("Safari", 998), startedAt: started))
        // Same name, but the process started long after the session did: a reused PID.
        XCTAssertFalse(ProcessInfoReader.matchesClaudeSession(info("claude", 5_000), startedAt: started))
        XCTAssertFalse(ProcessInfoReader.matchesClaudeSession(info("claude", 0), startedAt: started))
        XCTAssertFalse(ProcessInfoReader.matchesClaudeSession(info("claude", 998), startedAt: nil), "no start time, no proof")
    }

    func testTitlePartsMergeKeepsARenameAPartialReadMissed() {
        let earlier = ExternalSessionParser.TitleParts(custom: "auth", ai: "Login fix", firstPrompt: "fix login")
        let partial = ExternalSessionParser.TitleParts(custom: nil, ai: "Login fix v2", firstPrompt: "other")
        let merged = earlier.updated(with: partial)
        XCTAssertEqual(merged.best, "auth")
        XCTAssertEqual(merged.ai, "Login fix v2")
        XCTAssertEqual(merged.firstPrompt, "fix login")
    }

    func testOrderPutsLongestWaitingFirstThenRunningThenMostRecentIdle() {
        let sessions = [
            session("idle-old", .idle, since: 100),
            session("busy", .busy, since: 500),
            session("wait-new", .waiting(reason: nil), since: 900),
            session("idle-new", .idle, since: 800),
            session("wait-old", .waiting(reason: nil), since: 200),
        ]
        XCTAssertEqual(
            sessions.sorted(by: ExternalSessionMonitor.order).map(\.sessionId),
            ["wait-old", "wait-new", "busy", "idle-new", "idle-old"]
        )
    }

    func testRefreshDropsDeadProcessesAndOurOwnChildren() async {
        let monitor = ExternalSessionMonitor()
        func make(_ pid: pid_t, _ id: String) -> ExternalAgentSession {
            ExternalAgentSession(
                pid: pid, sessionId: id, kind: "interactive", cwd: URL(fileURLWithPath: "/p"), name: nil,
                status: .idle, statusSince: nil, startedAt: Date(timeIntervalSince1970: 43)
            )
        }
        let claude = ProcessInfoReader.Info(ppid: 1, tty: "ttys009", startTime: 42, name: "claude")
        let other = ProcessInfoReader.Info(ppid: 1, tty: nil, startTime: 42, name: "node")
        monitor.processInfo = { pid in [100: claude, 200: other][pid] }
        let snapshot = [make(100, "alive"), make(200, "recycled"), make(300, "dead")]
        monitor.snapshotProvider = { snapshot }
        await monitor.refresh()
        XCTAssertEqual(monitor.sessions.map(\.sessionId), ["alive"])
        XCTAssertEqual(monitor.sessions.first?.tty, "ttys009")
        XCTAssertEqual(monitor.sessions.first?.processStart, 42)
    }

    // MARK: Formatting and scripts

    func testFocusScriptsTargetTheTtyAndOnlyKnownTerminals() throws {
        let terminal = try XCTUnwrap(TerminalFocuser.script(for: TerminalFocuser.terminalBundleId, tty: "/dev/ttys034"))
        XCTAssertTrue(terminal.contains("tty of t is \"/dev/ttys034\""))
        let iterm = try XCTUnwrap(TerminalFocuser.script(for: TerminalFocuser.iTermBundleId, tty: "/dev/ttys001"))
        XCTAssertTrue(iterm.contains("tty of s is \"/dev/ttys001\""))
        XCTAssertNil(TerminalFocuser.script(for: "com.mitchellh.ghostty", tty: "/dev/ttys001"))
        // A quote in the tty can't break out of the AppleScript string.
        let hostile = try XCTUnwrap(TerminalFocuser.script(for: TerminalFocuser.terminalBundleId, tty: "/dev/x\" & do shell script \"rm"))
        XCTAssertFalse(hostile.contains("\" & do shell script \""))
    }
}
