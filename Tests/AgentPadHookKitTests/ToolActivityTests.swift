import XCTest
@testable import AgentPadHookKit

final class ToolActivityTests: XCTestCase {
    private let surface = "92121BF1-A501-4E8E-9E18-B89D172375E0"

    private func stdin(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testMainThreadToolEventReportsRunning() {
        let data = stdin(["hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "abc"])
        XCTAssertEqual(
            AgentPadHookKit.runningPayloadForToolEvent(agent: "claude", stdin: data, surface: surface),
            ["agent": "claude", "event": "running", "surface": surface]
        )
    }

    /// `agent_type` alone means the session was started with `--agent`; the
    /// call is still on the main thread.
    func testAgentTypeWithoutAgentIdIsStillMainThread() {
        let data = stdin(["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_type": "reviewer"])
        XCTAssertNotNil(AgentPadHookKit.runningPayloadForToolEvent(agent: "claude", stdin: data, surface: surface))
    }

    /// A background subagent outlives the main thread's turn; its tool calls
    /// must not pull a tab that is waiting for the user back to "running".
    func testSubagentToolEventReportsNothing() {
        let data = stdin([
            "hook_event_name": "PostToolUse", "tool_name": "Grep",
            "agent_id": "a1f3d90acde870b2d", "agent_type": "Explore",
        ])
        XCTAssertNil(AgentPadHookKit.runningPayloadForToolEvent(agent: "claude", stdin: data, surface: surface))
    }

    func testOtherAgentsReportNothing() {
        let data = stdin(["event": "PostToolUse", "toolName": "shell"])
        XCTAssertNil(AgentPadHookKit.runningPayloadForToolEvent(agent: "reasonix", stdin: data, surface: surface))
    }

    func testUnreadableStdinReportsNothing() {
        XCTAssertNil(AgentPadHookKit.runningPayloadForToolEvent(agent: "claude", stdin: Data(), surface: surface))
        XCTAssertNil(AgentPadHookKit.runningPayloadForToolEvent(agent: "claude", stdin: Data("not json".utf8), surface: surface))
    }
}
