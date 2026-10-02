import Foundation

// AgentPad: Claude reports "attention" when it stops mid-turn to show a
// prompt — a permission request, a question — but nothing reports the answer.
// Tool calls on the main thread are the signal that the agent went on; the app
// decides from them when a waiting tab is running again
// (`WorkspaceStore.applyToolCallEvent`).

extension AgentPadHookKit {
    /// Payload key marking a tool event as made by the main thread.
    public static let mainThreadKey = "main_thread"

    /// `kind` of the payload saying the main thread's current batch of tool
    /// calls has resolved (Claude's `PostToolBatch`).
    public static let toolBatchKind = "tool_batch"

    public static func buildToolBatchPayload(agent: String, surface: String) -> [String: String] {
        ["kind": toolBatchKind, "agent": agent, "surface": surface]
    }

    /// Whether a tool event's hook stdin comes from the agent's main thread.
    ///
    /// Tool calls made inside a subagent carry `agent_id` and do not count: a
    /// background subagent keeps calling tools after the main thread has
    /// finished its turn, when the tab does need the user. Only Claude is
    /// covered — `agent_id` is its field.
    public static func isMainThreadToolEvent(agent: String, stdin data: Data) -> Bool {
        guard agent == "claude",
              !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if let subagent = parsed["agent_id"] as? String, !subagent.isEmpty { return false }
        return true
    }
}
