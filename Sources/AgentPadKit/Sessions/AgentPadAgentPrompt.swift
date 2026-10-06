import Foundation

/// Context for a personal Claude tab. Team executors build their own prompt
/// and deliberately do not inherit the tab's integration environment.
enum AgentPadAgentPrompt {
    static var builtInURL: URL? { Bundle.agentPadResources.url(forResource: "agent-prompt", withExtension: "md") }
    static var overrideURL: URL { AgentPadShellIntegration.agentPadAppSupport("agent-prompt.md", isDirectory: false) }

    static func isEnabled(in settings: [String: Any]) -> Bool {
        ((settings["agents"] as? [String: Any])?["agentPadPrompt"] as? Bool) ?? true
    }

    static func environment(settings: [String: Any], builtIn: URL? = builtInURL, override: URL = overrideURL) -> [String: String] {
        let enabled = isEnabled(in: settings)
        // Explicit empty values also clear inherited settings in nested tabs.
        return ["AGENTPAD_AGENT_PROMPT_PATH": enabled ? builtIn?.path ?? "" : "",
                "AGENTPAD_AGENT_PROMPT_OVERRIDE": enabled ? override.path : ""]
    }
}
