import AppKit
import Sparkle

/// AgentPad: updates installed from inside the app — "Install and Relaunch".
///
/// Sparkle reads its feed and public key from Info.plist (`SUFeedURL`,
/// `SUPublicEDKey`, written by scripts/build-app.sh). A bundle without them —
/// `swift run`, tests — has no in-app updater, and Check for Updates falls
/// back to the GitHub release check (`UpdateChecker`).
@MainActor
final class AgentPadUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = AgentPadUpdater()

    private var controller: SPUStandardUpdaterController?
    private let focusID = UUID()

    private override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["SUFeedURL"] is String, info["SUPublicEDKey"] is String else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        UpdateAttention.shared.launched(version: info["CFBundleVersion"] as? String ?? "")
    }

    var isAvailable: Bool { controller != nil }

    /// Shows Sparkle's own window: up to date, or the new version's notes
    /// with "Install Update". Installing quits AgentPad and relaunches it;
    /// agent tabs come back the way they do after any restart.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        UpdateAttention.shared.beginCheck()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        UpdateAttention.shared.available(update.versionString, manual: state.userInitiated)
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if let view = NSApp.keyWindow?.contentView {
            AttentionFocus.places[focusID] = ([.update(update.versionString)], AttentionFocus.WeakView(view))
        }
        UpdateAttention.shared.viewed()
    }
    func standardUserDriverWillFinishUpdateSession() {
        AttentionFocus.places[focusID] = nil
        AttentionLedger.shared.validateAll()
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        UpdateAttention.shared.chose(choice == .install ? .install : choice == .skip ? .skip : .later)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard (error as NSError).code != SUError.noUpdateError.rawValue else { return }
        UpdateAttention.shared.failed()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue { UpdateAttention.shared.failed() }
    }
}
