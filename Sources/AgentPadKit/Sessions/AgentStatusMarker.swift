import Foundation

/// One foreground command launched by the tab, before the first prompt. Its
/// result travels on the terminal stream even when the shell omits OSC 133 D.
enum AgentLaunchExitMarker {
    static let prefix = "agentpad-launch-exit:"

    static func parse(_ title: String) -> (id: UUID, exit: Int)? {
        guard title.hasPrefix(prefix) else { return nil }
        let parts = title.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let exit = Int(parts[1]), (0...255).contains(exit) else { return nil }
        return (id, exit)
    }
}

/// Private terminal-title marker used as a remote-friendly fallback for agent
/// status. Unlike `AgentPadHook`, this rides the terminal byte stream itself, so
/// an ssh remote can report `claude running` without reaching AgentPad's local
/// unix socket.
///
/// Wire title shape:
///   agentpad-agent:<agent binary slug>:<HookEvent raw value>
///
/// It is delivered via OSC 2 and intercepted before it becomes a visible tab
/// title. Keep the format shell-friendly: remote wrapper snippets should be
/// able to emit it with plain `printf`.
enum AgentStatusMarker {
    private static let prefix = "agentpad-agent:"

    static func title(slug: String, event: HookEvent) -> String {
        "\(prefix)\(slug):\(event.rawValue)"
    }

    static func isMarkerTitle(_ raw: String) -> Bool {
        normalizedTitle(raw)?.hasPrefix(prefix) == true
    }

    @MainActor
    static func parseTitle(_ raw: String) -> (agent: AgentTemplate, event: HookEvent)? {
        guard let title = normalizedTitle(raw),
              title.hasPrefix(prefix)
        else { return nil }

        let payload = title.dropFirst(prefix.count)
        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let slug = String(parts[0])
        let eventName = String(parts[1])
        guard
            !slug.isEmpty,
            let agent = AgentTemplate.from(hookSlug: slug),
            let event = HookEvent(rawValue: eventName)
        else { return nil }

        return (agent, event)
    }
}
