import Foundation

// AgentPad: Claude ends a turn (`Stop`) while subagents or shell commands it
// started in the background are still running. `Stop` is still the foreground
// turn's completion: background work is separate metadata, not a reason to
// suppress the completion alert or keep the tab working.

extension AgentPadHookKit {
    public static let backgroundSubagentsKey = "background_subagents"
    public static let backgroundShellsKey = "background_shells"
    public static let notificationTypeKey = "notification_type"

    /// Enriches a Claude lifecycle payload from the hook's stdin: a `Stop`
    /// preserves its completion event and adds background work counts, and a
    /// `Notification` carries its type so the app can tell "idle" from a
    /// prompt. Other agents and unreadable stdin leave the payload unchanged.
    public static func applyClaudeLifecycleDetails(to payload: inout [String: String], stdin data: Data) {
        guard payload["agent"] == "claude",
              !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        switch parsed["hook_event_name"] as? String {
        case "Stop":
            payload["reason"] = "completion"
            let running = (parsed["background_tasks"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String == "running" }
            let subagents = running.filter { $0["type"] as? String == "subagent" }.count
            let shells = running.filter { $0["type"] as? String == "shell" }.count
            guard subagents + shells > 0 else { return }
            payload[backgroundSubagentsKey] = String(subagents)
            payload[backgroundShellsKey] = String(shells)
        case "StopFailure":
            payload["reason"] = "failure"
        case "Notification":
            payload["reason"] = "input"
            if let type = parsed["notification_type"] as? String, !type.isEmpty {
                payload[notificationTypeKey] = type
            }
        default:
            break
        }
    }
}
