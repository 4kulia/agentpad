import Foundation

/// AgentPad: names the app used before the upstream name was replaced
/// (scripts/rebrand.py), still found on machines that ran an earlier build.
/// Each one is read for compatibility only; nothing new is written under it.
///
/// This file is excluded from rebrand.py, which would otherwise turn these
/// strings into the current names and silently drop the compatibility.
enum LegacyNames {
    /// Prefix of a bundled theme in settings.json, e.g. `kooky:dracula`.
    static let themePrefix = "kooky:"

    /// The closed-lid sleep helper and its sudoers rule. The helper is the
    /// same two-verb pmset wrapper, so an existing authorization keeps working
    /// instead of asking for the admin password again.
    static let sleepHelperPath = "/Library/PrivilegedHelperTools/kooky-sleepctl"
    static let sleepSudoersPath = "/etc/sudoers.d/kooky-sleepctl"

    /// fish integration file in the app's own support folder. Left beside the
    /// new one, it would register a second set of prompt handlers that call
    /// the old hook binary.
    static let fishVendorConfName = "kooky.fish"

    /// Markers of the ssh wrapper written by an earlier build into the app's
    /// own bin folder.
    static let sshWrapperMarkers = ["KOOKY_DISABLE_SSH_AGENT_MARKERS", "kooky-agent-markers"]
}
