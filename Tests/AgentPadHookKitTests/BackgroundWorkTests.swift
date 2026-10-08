import XCTest
@testable import AgentPadHookKit

/// Payloads modelled on Claude Code 2.1.287's real `Stop` and `Notification`
/// hook input (recorded in the stage 0 probe).
final class BackgroundWorkTests: XCTestCase {
    private func payload(_ event: String, agent: String = "claude") -> [String: String] {
        AgentPadHookKit.buildLifecyclePayload(agent: agent, event: event, surface: "S")
    }

    private func stdin(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testStopWithRunningBackgroundWorkReportsRunning() {
        var p = payload("attention")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &p, stdin: stdin([
            "hook_event_name": "Stop",
            "background_tasks": [
                ["id": "bcw7jeuwj", "type": "shell", "status": "running"],
                ["id": "a52e4d084c377ea63", "type": "subagent", "status": "running"],
                ["id": "old", "type": "shell", "status": "completed"],
            ],
        ]))
        XCTAssertEqual(p["event"], "running")
        XCTAssertEqual(p[AgentPadHookKit.backgroundSubagentsKey], "1")
        XCTAssertEqual(p[AgentPadHookKit.backgroundShellsKey], "1")
    }

    func testStopWithNothingRunningStaysAttention() {
        var p = payload("attention")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &p, stdin: stdin([
            "hook_event_name": "Stop", "background_tasks": [] as [Any],
        ]))
        XCTAssertEqual(p["event"], "attention")
        XCTAssertEqual(p["reason"], "completion")
    }

    func testNotificationCarriesItsType() {
        var p = payload("attention")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &p, stdin: stdin([
            "hook_event_name": "Notification", "notification_type": "idle_prompt",
        ]))
        XCTAssertEqual(p["event"], "attention")
        XCTAssertEqual(p[AgentPadHookKit.notificationTypeKey], "idle_prompt")
    }

    func testOtherAgentsAndUnreadableInputAreUnchanged() {
        var other = payload("attention", agent: "codex")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &other, stdin: stdin([
            "hook_event_name": "Stop", "background_tasks": [["type": "shell", "status": "running"]],
        ]))
        XCTAssertEqual(other, payload("attention", agent: "codex"))
        var empty = payload("attention")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &empty, stdin: Data("nope".utf8))
        XCTAssertEqual(empty, payload("attention"))
    }
}


extension BackgroundWorkTests {
    func testStopFailurePreservesFailureAndNotificationPreservesInput() {
        var failure = payload("turn_failure")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &failure, stdin: stdin(["hook_event_name": "StopFailure"]))
        XCTAssertEqual(failure["reason"], "failure")
        var input = payload("attention")
        AgentPadHookKit.applyClaudeLifecycleDetails(to: &input, stdin: stdin(["hook_event_name": "Notification", "notification_type": "permission_prompt"]))
        XCTAssertEqual(input["reason"], "input")
        XCTAssertEqual(input["notification_type"], "permission_prompt")
    }
}
