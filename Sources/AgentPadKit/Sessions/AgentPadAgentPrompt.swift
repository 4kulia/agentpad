import Foundation

/// Context for a personal Claude/Codex tab. Team executors build their own prompt
/// and deliberately do not inherit the tab's integration environment.
enum AgentPadAgentPrompt {
    static var builtInURL: URL? { Bundle.agentPadResources.url(forResource: "agent-prompt", withExtension: "md") }
    static var overrideURL: URL { AgentPadShellIntegration.agentPadAppSupport("agent-prompt.md", isDirectory: false) }

    static func isEnabled(in settings: [String: Any]) -> Bool {
        ((settings["agents"] as? [String: Any])?["agentPadPrompt"] as? Bool) ?? true
    }

    static func isCodexEnabled(in settings: [String: Any]) -> Bool {
        ((settings["agents"] as? [String: Any])?["codexAgentPadPrompt"] as? Bool) ?? false
    }

    static func additionalInstruction(in settings: [String: Any]) -> String {
        ((settings["agents"] as? [String: Any])?["agentPadPromptAdditionalInstruction"] as? String) ?? ""
    }

    static func environment(settings: [String: Any], builtIn: URL? = builtInURL, override: URL = overrideURL) -> [String: String] {
        var text = ""
        if isEnabled(in: settings) {
            // Keep the existing file override compatible. Snapshot it with the
            // settings at tab creation, including when restoring a conversation.
            let base = (try? String(contentsOf: override, encoding: .utf8))
                ?? builtIn.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let additional = additionalInstruction(in: settings).trimmingCharacters(in: .whitespacesAndNewlines)
            text = base.trimmingCharacters(in: .newlines)
            if !additional.isEmpty {
                if !text.isEmpty { text += "\n\n" }
                text += "Additional owner instruction:\n" + additional
            }
        }
        // Explicit empty values also clear inherited settings in nested tabs.
        return ["AGENTPAD_AGENT_PROMPT_TEXT": text,
                "AGENTPAD_AGENT_PROMPT_CODEX_CONFIG": !text.isEmpty && isCodexEnabled(in: settings)
                    ? "developer_instructions=" + tomlString(text) : ""]
    }

    /// A TOML basic string, passed as one argv value (never shell-evaluated).
    /// Escape controls as well as quotes: a multiline owner instruction must
    /// not become another config key, shell command or positional prompt.
    private static func tomlString(_ text: String) -> String {
        let escaped = text.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x22: return "\\\""
            case 0x5C: return "\\\\"
            case 0...0x1F, 0x7F: return String(format: "\\u%04X", scalar.value)
            default: return String(scalar)
            }
        }.joined()
        return "\"" + escaped + "\""
    }
}
