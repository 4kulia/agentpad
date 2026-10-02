import AppKit
import Quartz

/// The system Quick Look panel (Finder's Space) for one file.
@MainActor
final class QuickLookPanel: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPanel()
    private var url: URL?

    /// Whether a preview was requested; the app delegate only takes panel
    /// control while this is set.
    var hasItem: Bool { url != nil }

    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        if panel.isVisible {
            panel.reloadData()
        } else {
            // The panel asks the responder chain for a controller (the app
            // delegate, see AppDelegate+QuickLook), which installs the data source.
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        url = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

/// AgentPad file-tree preferences.
enum FileTreePreferences {
    static let showHiddenKey = "agentpad.files.showHidden"

    /// Dotfiles are shown by default (AgentPad's behaviour: `.env`, `.gitignore`
    /// matter to developers). Read from the listing thread; UserDefaults is
    /// thread-safe.
    static var showHidden: Bool {
        UserDefaults.standard.object(forKey: showHiddenKey) as? Bool ?? true
    }
}

/// Makes the app delegate the Quick Look panel's controller (Apple's
/// QLPreviewPanelController contract): the delegate sits in the responder
/// chain whatever has focus, including the terminal.
extension AppDelegate {
    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { QuickLookPanel.shared.hasItem }
    }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookPanel.shared.begin(panel) }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookPanel.shared.end(panel) }
    }
}
