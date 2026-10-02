import Foundation

// AgentPad: Claude reports "attention" when it stops mid-turn to show a
// prompt — a permission request, a question — but nothing reports the answer.
// The next lifecycle event is the end of the turn, so a tab kept reading
// "waiting" for as long as the agent went on working after the prompt. A tool
// call on the main thread is the missing signal: the agent is running again.

extension AgentPadHookKit {
    /// The `running` lifecycle payload to send alongside a tool event, or nil
    /// when the event says nothing about the tab's own state.
    ///
    /// Tool calls made inside a subagent carry `agent_id` and are left out: a
    /// background subagent keeps calling tools after the main thread has
    /// finished its turn, and the tab must then keep saying it needs the user.
    /// Only Claude is covered — `agent_id` is its field, and the other agents
    /// that send tool events report their own lifecycle around each call.
    public static func runningPayloadForToolEvent(
        agent: String,
        stdin data: Data,
        surface: String
    ) -> [String: String]? {
        guard agent == "claude",
              !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let subagent = parsed["agent_id"] as? String, !subagent.isEmpty { return nil }
        return buildLifecyclePayload(agent: agent, event: "running", surface: surface)
    }
}
