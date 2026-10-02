import Foundation

/// AgentPad fork: every on-disk name, URL scheme, and app name that would
/// otherwise collide with an installed upstream Kooky. Lives in AgentPadHookKit
/// so the app, the hook helper, and the CLI all read the same spelling.
public enum AppIdentity {
    public static let appName = "AgentPad"
    /// `~/Library/Application Support/<name>/` — socket, state, mirrored helpers.
    public static let supportDirectoryName = "agentpad"
    /// `~/<name>/settings.json`.
    public static let configDirectoryName = ".agentpad"
    public static let urlScheme = "agentpad"
}
