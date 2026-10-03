import AppKit
import Sparkle

/// AgentPad: updates installed from inside the app — "Install and Relaunch".
///
/// Sparkle reads its feed and public key from Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`, written by scripts/build-app.sh). A bundle without them —
/// `swift run`, tests — has no in-app updater, and Check for Updates falls
/// back to the GitHub release check (`UpdateChecker`).
@MainActor
final class AgentPadUpdater {
    static let shared = AgentPadUpdater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    /// Shows Sparkle's own window: up to date, or the new version's notes
    /// with "Install Update". Installing quits AgentPad and relaunches it;
    /// agent tabs come back the way they do after any restart.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
