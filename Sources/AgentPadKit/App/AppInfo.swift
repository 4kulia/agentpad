import Foundation

/// Single source of truth for product metadata — surfaced by the About panel,
/// Help menu, and window title. Bump `displayVersion` on every release so the
/// About panel matches the latest CHANGELOG `vX.Y` tag.
enum AgentPadApp {
    static let name = "AgentPad"
    static let displayVersion = "0.51.11"
    static let tagline = "All your coding-agent sessions in one window. A fork of kooky."
    static let author = "Corey Chiu"
    static let authorURL = URL(string: "https://coreychiu.com?utm_source=kooky")!
    static let copyrightYear = "2026"

    static let repositoryURL = URL(string: "https://github.com/4kulia/agentpad")!
    static let issuesURL = URL(string: "https://github.com/4kulia/agentpad/issues")!
    /// Mirrors `repositoryURL`; update both if the repo is ever renamed.
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/4kulia/agentpad/releases/latest")!
}
