import XCTest
@testable import AgentPadKit

@MainActor
final class AgentAnswerSourceTests: XCTestCase {
    private var root: URL!
    private var store: WorkspaceStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-source-\(UUID())")
        store = makeTestStore(claudeProjectsRoot: root)
    }

    override func tearDown() async throws {
        store.terminate()
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func session(_ agent: AgentTemplate) throws -> Session {
        let session = try XCTUnwrap(store.active?.activeSession)
        session.agent = agent
        session.currentDirectory = root
        (session.engine as? TestEngine)?.foregroundPid = ProcessInfo.processInfo.processIdentifier
        return session
    }

    private func assertRefused(_ session: Session, _ problem: AgentAnswerTranscript.Problem,
                               inspector: AgentAnswerProvenance.Inspector = .init(),
                               file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertFalse(AgentAnswerWindow.available(session), file: file, line: line)
        XCTAssertEqual(AgentAnswerSource.problem(session, inspector: inspector), problem, file: file, line: line)
        do {
            _ = try await AgentAnswerSource.read(session: session, store: store, inspector: inspector) { _, _, _ in
                XCTFail("An unbound export must not read any journal", file: file, line: line)
                return "Another tab's private answer"
            }
            XCTFail("Expected refusal before Copy/Forward", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentAnswerTranscript.Problem, problem, file: file, line: line)
        }
    }

    func testParallelCodexMonitorsInSameDirectoryCannotAuthorizeExport() async throws {
        let first = try session(.codex)
        let workspace = try XCTUnwrap(store.active)
        let second = store.addTab(in: workspace, initialCwd: root)
        second.agent = .codex
        var children: [Process] = []
        defer {
            for child in children { child.terminate(); child.waitUntilExit() }
        }
        for tab in [first, second] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.standardInput = Pipe()
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            children.append(child)
            (tab.engine as? TestEngine)?.foregroundPid = child.processIdentifier
            XCTAssertNotNil(ChatSessionIdentity.Process.read(child.processIdentifier))
        }
        let monitor = CodexUsageMonitor()
        defer { monitor.stop(sessionId: first.id); monitor.stop(sessionId: second.id) }
        let reported = expectation(description: "Both monitors adopted the newest journal")
        reported.expectedFulfillmentCount = 2
        let store = try XCTUnwrap(store)
        func start(_ session: Session) {
            monitor.start(sessionId: session.id, cwd: root, sessionsRoot: root,
                conversationUpdate: { id in
                    store.applyConversationId(conversationId: id, sessionId: session.id)
                    reported.fulfill()
                }, update: { _ in })
        }
        start(first); start(second) // Both launch snapshots precede both journals.
        let day = try XCTUnwrap(CodexUsageMonitor.recentDayDirectories(under: root, days: 1).first)
        let firstID = UUID().uuidString.lowercased(), otherID = UUID().uuidString.lowercased()
        for (id, modified) in [(firstID, Date(timeIntervalSince1970: 1)), (otherID, Date(timeIntervalSince1970: 2))] {
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": root.path]]
            let answer: [String: Any] = ["type": "event_msg", "payload": ["type": "agent_message", "phase": "final_answer",
                "message": id == firstID ? "First tab's answer" : "Other tab's private answer"]]
            let lines = try [meta, answer].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            try SessionStoreFixtures.writeFile("rollout-\(id).jsonl", in: day, lines: lines, mtime: modified)
        }
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .codex, conversation: otherID, root: root), "Other tab's private answer")
        start(first); start(second) // Resolve immediately with the original exclusions.
        await fulfillment(of: [reported], timeout: 3)
        for tab in [first, second] {
            XCTAssertEqual(tab.conversationId, otherID, "the monitor's ambiguity is reproduced")
            XCTAssertNil(tab.answerBinding, "the heuristic ID must stay separate from export provenance")
            await assertRefused(tab, .unverified)
        }
        XCTAssertTrue(AgentAnswerTranscript.Problem.unverified.rawValue.contains("cannot verify"))
        XCTAssertTrue(AgentAnswerTranscript.Problem.unverified.rawValue.contains("terminal"))
    }

    func testCodexRefusesResumeHookAndStaleBindingEvenWithStableProcess() async throws {
        let tab = try session(.codex), id = UUID().uuidString.lowercased()
        tab.conversationId = id
        tab.resumedConversationId = id
        store.applyHookConversationId(conversationId: id, sessionId: tab.id)
        XCTAssertNil(tab.answerBinding, "Codex has no verified journal provider")
        await assertRefused(tab, .unverified)
        // Even an old/incorrectly populated runtime binding must not reopen
        // the actions: stable PID is not evidence of Codex journal ownership.
        let process = try XCTUnwrap(ChatSessionIdentity.Process.read(ProcessInfo.processInfo.processIdentifier))
        tab.answerBinding = .init(conversation: id, process: process)
        await assertRefused(tab, .unverified)
    }

    func testClaudeHookBindsExactProcessAndMonitorCannotReplaceIt() async throws {
        let tab = try session(.claudeCode), id = UUID().uuidString.lowercased()
        let fixture = AnswerProcessFixture()
        try fixture.bind(tab, conversation: id)
        store.applyConversationId(conversationId: UUID().uuidString.lowercased(), sessionId: tab.id)
        XCTAssertNil(AgentAnswerSource.problem(tab, inspector: fixture.inspector))
        let root = try XCTUnwrap(root)
        let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { agent, conversation, directory in
            XCTAssertEqual(agent, .claude)
            XCTAssertEqual(conversation, id)
            XCTAssertEqual(directory, root)
            return "The bound answer"
        }
        XCTAssertEqual(answer.text, "The bound answer")
        XCTAssertTrue(answer.isCurrent())
        let original = try XCTUnwrap(tab.answerBinding)
        let process = original.process
        tab.answerBinding = .init(conversation: id, process: .init(pid: process.pid, parent: process.parent,
            startedAtUs: process.startedAtUs + 1, terminal: process.terminal))
        await assertRefused(tab, .changed, inspector: fixture.inspector)
        XCTAssertFalse(answer.isCurrent(), "PID reuse invalidates the preview")
        tab.answerBinding = original
        (tab.engine as? TestEngine)?.foregroundPid = nil
        await assertRefused(tab, .changed, inspector: fixture.inspector)
        store.applyHookConversationId(conversationId: id, sessionId: tab.id)
        XCTAssertNil(tab.answerBinding, "a hook without a readable process establishes nothing")
        await assertRefused(tab, .hookIdentity)
    }

    func testClaudePersistedAndResumedIDsDoNotAuthorizeReadingBeforeHook() async throws {
        let tab = try session(.claudeCode), id = UUID().uuidString.lowercased()
        tab.conversationId = id
        await assertRefused(tab, .unbound)
        tab.resumedConversationId = id
        await assertRefused(tab, .unbound)
        store.applyConversationId(conversationId: id, sessionId: tab.id)
        await assertRefused(tab, .unbound)
    }

    func testProcessChangeDuringReadCannotReturnAnAnswer() async throws {
        let tab = try session(.claudeCode)
        let fixture = AnswerProcessFixture()
        try fixture.bind(tab, conversation: UUID().uuidString.lowercased())
        let entered = expectation(description: "journal read"), gate = Gate()
        gate.close(); defer { gate.open() }
        let task = Task {
            try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, _, _ in
                entered.fulfill(); gate.pass()
                return "Old process's answer"
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        (tab.engine as? TestEngine)?.foregroundPid = nil
        gate.open()
        do { _ = try await task.value; XCTFail("A changed source cannot be copied or previewed") }
        catch { XCTAssertEqual(error as? AgentAnswerTranscript.Problem, .changed) }
    }

    func testSecondClaudeDuringReadAndAfterPreviewDisablesExport() async throws {
        let tab = try session(.claudeCode), fixture = AnswerProcessFixture()
        try fixture.bind(tab, conversation: UUID().uuidString)
        let answer = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, _, _ in "Bound" }
        XCTAssertTrue(answer.isCurrent())
        do {
            _ = try await AgentAnswerSource.read(session: tab, store: store, inspector: fixture.inspector) { _, _, _ in
                fixture.add(99_999_973, parent: AnswerProcessFixture.shell, name: "claude", trusted: true)
                return "Must not escape"
            }
            XCTFail("New ambiguity during IO must refuse")
        } catch { XCTAssertEqual(error as? AgentAnswerTranscript.Problem, .changed) }
        XCTAssertFalse(answer.isCurrent(), "an already open Forward preview must also refuse")
        await assertRefused(tab, .changed, inspector: fixture.inspector)
    }
}
