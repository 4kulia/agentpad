import Foundation

/// Private terminal-title marker the ssh wrapper emits when a plain
/// interactive `ssh` connection is established. Like `AgentStatusMarker`, it
/// rides the terminal byte stream (OSC 2) so an ssh remote can be surfaced
/// locally without reaching AgentPad's unix socket.
///
/// Wire title shape:
///   agentpad-remote-login:<destination>
///
/// where `<destination>` is the ssh argument verbatim (`user@host` if a user
/// was given, else bare `host`). Delivered via OSC 2 and intercepted before it
/// becomes a visible tab title.
enum RemoteLoginMarker {
    /// `internal` so the ssh wrapper emit interpolates the same constant the
    /// parse reads — one source of truth for the wire prefix.
    static let titlePrefix = "agentpad-remote-login:"

    /// Emitted by the wrapper AFTER ssh returns — the wrapper waits for ssh
    /// (no exec) precisely so it can send this. `remoteHost` is cleared by
    /// this marker and nothing else: clearing on OSC 133;D looked equivalent
    /// but wasn't — a remote shell with its own shell integration emits
    /// 133;D through the connection on every remote command, which read as
    /// "ssh exited" after the first remote command finished.
    static let logoutTitle = "agentpad-remote-logout"

    static func isLogoutTitle(_ raw: String) -> Bool {
        normalizedTitle(raw) == logoutTitle
    }

    /// Returns the SSH destination (`user@host` or bare `host`), or nil when
    /// `raw` isn't a remote-login marker (or its payload is empty). No separate
    /// `isMarkerTitle`: unlike `AgentStatusMarker` (whose `parseTitle` is
    /// `@MainActor` + returns a tuple), this is non-isolated and already returns
    /// the optional a caller branches on.
    static func parseTitle(_ raw: String) -> String? {
        guard let title = normalizedTitle(raw),
              title.hasPrefix(titlePrefix)
        else { return nil }

        let host = String(title.dropFirst(titlePrefix.count))
        return host.isEmpty ? nil : host
    }
}
