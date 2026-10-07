import XCTest
@testable import AgentPadKit

final class AgentAnswerTranscriptTests: XCTestCase {
    private let id = "a0000000-0000-4000-8000-000000000001"
    private let other = "a0000000-0000-4000-8000-000000000002"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ rows: [[String: Any]], path: String, tail: String = "") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        data.append(contentsOf: tail.utf8)
        try data.write(to: file)
        return file
    }

    private func claude(_ message: String, _ blocks: [[String: Any]], uuid: String = UUID().uuidString) -> [String: Any] {
        ["type": "assistant", "sessionId": id, "uuid": uuid,
         "message": ["id": message, "role": "assistant", "content": blocks]]
    }
    private func text(_ text: String, kind: String = "text") -> [String: Any] { ["type": kind, "text": text] }

    func testClaudeKeepsEveryTextBlockOfLatestMessageAndMarkdown() throws {
        let first = "## Result\n\nA **complete** answer."
        let second = "```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let block = claude("last", [text(second)], uuid: "same-block")
        _ = try write([
            claude("old", [text("Old answer")]),
            claude("tool", [text("Working…"), ["type": "tool_use", "name": "Bash", "input": ["command": "do not copy"]]]),
            ["type": "user", "sessionId": id, "message": ["content": [["type": "tool_result", "content": "private output"]]]],
            claude("last", [["type": "thinking", "thinking": "private reasoning"], text(first)]),
            block, block,
            ["type": "user", "message": ["content": "Next question"]],
            ["type": "progress", "data": ["text": "not an answer"]]
        ], path: "project/\(id).jsonl", tail: "{\"type\":\"assistant\"")
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root), first + "\n\n" + second)
    }

    func testPlainClaudeTextAndUnknownAssistantContent() throws {
        var row = claude("answer", [])
        row["message"] = ["role": "assistant", "content": "Legacy **text**"]
        let file = try write([row], path: "p/\(id).jsonl")
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root), "Legacy **text**")
        let unknown = claude("new", [["type": "future_content", "value": "unknown"]])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: unknown)); try handle.close()
        XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root)) {
            XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .unknown)
        }
    }

    func testCodexFinalResponseExcludesCommentaryReasoningToolsAndEventDuplicates() throws {
        let answer = "# Done\n\n- First\n- Second\n\n```sh\necho ok\n```"
        _ = try write([
            ["type": "session_meta", "payload": ["id": id]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Old answer"]],
            ["type": "response_item", "payload": ["type": "reasoning", "summary": [text("hidden")]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": "hidden output"]],
            ["type": "event_msg", "payload": ["type": "agent_message", "phase": "final_answer", "message": answer]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final_answer", "content": [text(answer, kind: "output_text")]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary", "content": [text("Working on next task", kind: "output_text")]]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": [:]]]
        ], path: "2026/01/01/rollout-test-\(id).jsonl")
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .codex, conversation: id, root: root), answer)
    }

    func testCodexLegacyEventAndMultipleTextBlocks() throws {
        let path = "2026/01/01/rollout-test-\(id).jsonl"
        _ = try write([["type": "session_meta", "payload": ["session_id": id]],
                       ["type": "event_msg", "payload": ["type": "agent_message", "message": "Legacy answer"]]], path: path)
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .codex, conversation: id, root: root), "Legacy answer")
        _ = try write([["type": "session_meta", "payload": ["id": id]],
                       ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [text("One", kind: "output_text"), text("Two", kind: "output_text")]]]], path: path)
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .codex, conversation: id, root: root), "One\n\nTwo")
    }

    func testExactConversationOnlyAndNoNewestFileFallback() throws {
        let rows = [claude("one", [text("Own answer")])]
        _ = try write(rows, path: "project/\(id).jsonl")
        _ = try write([["type": "unexpected sibling"]], path: "project/\(other).jsonl")
        XCTAssertEqual(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root), "Own answer")
        for agent in [AgentAnswerTranscript.Agent.claude, .codex] {
            XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: agent, conversation: UUID().uuidString, root: root)) {
                XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .missing)
            }
            XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: agent, conversation: "../escape", root: root)) {
                XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .unbound)
            }
        }
    }

    func testMismatchedSessionMetadataAndSidechainRefused() throws {
        for agent in [AgentAnswerTranscript.Agent.claude, .codex] {
            var row: [String: Any]
            let path: String
            if agent == .claude { row = claude("answer", [text("foreign")]); row["sessionId"] = other; path = "p/\(id).jsonl" }
            else { row = ["type": "session_meta", "payload": ["id": other]]; path = "rollout-test-\(id).jsonl" }
            _ = try write([row], path: path)
            XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: agent, conversation: id, root: root)) {
                XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .changed)
            }
        }
        var row = claude("answer", [text("subagent")]); row["isSidechain"] = true
        _ = try write([row], path: "p/\(id).jsonl")
        XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root))
    }

    func testSymlinkCannotReadAnotherConversation() throws {
        let target = try write([claude("answer", [text("private sibling")])], path: "p/\(other).jsonl")
        let link = root.appendingPathComponent("p/\(id).jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root)) {
            XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .missing)
        }
    }

    func testNoAnswerAndUnsupportedJournalHaveDifferentMessages() throws {
        _ = try write([["type": "user", "sessionId": id, "message": ["content": "Question"]]], path: "p/\(id).jsonl")
        XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root)) {
            XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .noAnswer)
        }
        _ = try write([["type": "future_record"]], path: "p/\(id).jsonl")
        XCTAssertThrowsError(try AgentAnswerTranscript.read(agent: .claude, conversation: id, root: root)) {
            XCTAssertEqual($0 as? AgentAnswerTranscript.Problem, .unknown)
        }
    }

    func testUTF8LimitPreservesGraphemesAndUnabridgedCopy() {
        let exact = String(repeating: "я", count: 8192)
        XCTAssertEqual(AgentAnswerText.forSending(exact, maxBytes: 16384), exact)
        let long = String(repeating: "👨‍👩‍👧‍👦е\u{301}", count: 2000)
        let sent = AgentAnswerText.forSending(long, maxBytes: 16384)
        XCTAssertLessThanOrEqual(sent.utf8.count, 16384)
        XCTAssertTrue(sent.hasSuffix("\n\n[Truncated]"))
        XCTAssertTrue(long.hasPrefix(String(sent.dropLast("\n\n[Truncated]".count))))
        XCTAssertGreaterThan(long.utf8.count, sent.utf8.count)
    }
}
