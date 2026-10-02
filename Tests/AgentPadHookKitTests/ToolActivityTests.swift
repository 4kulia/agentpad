import XCTest
@testable import AgentPadHookKit

final class ToolActivityTests: XCTestCase {
    private func stdin(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testMainThreadToolEvent() {
        let data = stdin(["hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "abc"])
        XCTAssertTrue(AgentPadHookKit.isMainThreadToolEvent(agent: "claude", stdin: data))
    }

    /// `agent_type` alone means the session was started with `--agent`; the
    /// call is still on the main thread.
    func testAgentTypeWithoutAgentIdIsStillMainThread() {
        let data = stdin(["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_type": "reviewer"])
        XCTAssertTrue(AgentPadHookKit.isMainThreadToolEvent(agent: "claude", stdin: data))
    }

    func testSubagentToolEventIsNotMainThread() {
        let data = stdin([
            "hook_event_name": "PostToolUse", "tool_name": "Grep",
            "agent_id": "a1f3d90acde870b2d", "agent_type": "Explore",
        ])
        XCTAssertFalse(AgentPadHookKit.isMainThreadToolEvent(agent: "claude", stdin: data))
    }

    func testOtherAgentsAreNotClassified() {
        let data = stdin(["event": "PostToolUse", "toolName": "shell"])
        XCTAssertFalse(AgentPadHookKit.isMainThreadToolEvent(agent: "reasonix", stdin: data))
    }

    func testUnreadableStdinIsNotMainThread() {
        XCTAssertFalse(AgentPadHookKit.isMainThreadToolEvent(agent: "claude", stdin: Data()))
        XCTAssertFalse(AgentPadHookKit.isMainThreadToolEvent(agent: "claude", stdin: Data("not json".utf8)))
    }
}
