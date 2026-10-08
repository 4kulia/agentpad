import Foundation

// AgentPad: Claude ends a turn (`Stop`) while subagents or shell commands it
// started in the background are still running, then wakes itself when each
// one finishes. Such a tab is working, not waiting on the user. `Stop` lists
// that work in `background_tasks`; Claude Code's own session status reads
// "shell" at that point, which the external-session list already shows as busy.

extension AgentPadHookKit {
    public static let backgroundSubagentsKey = "background_subagents"
    public static let backgroundShellsKey = "background_shells"
    public static let notificationTypeKey = "notification_type"

    /// Adjusts a Claude lifecycle payload from the hook's stdin: a `Stop` with
    /// background work still running reports `running` plus its counts, and a
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
            payload["event"] = "running"
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
