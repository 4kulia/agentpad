import Foundation
import Observation

/// Points the file tree at an external session's folder. Those sessions have
/// no tab here, so AgentPad's own per-tab root can't express them. Cleared as
/// soon as the user goes back to one of our tabs.
@MainActor
@Observable
final class ExternalTreeRoot {
    private var storedURL: URL?
    private var storedLabel: String?
    /// The tab that was active when the folder was shown. Switching to any
    /// other tab or workspace — even one with the same folder, even while
    /// the sidebar is hidden — retires the override.
    private var shownOver: (workspace: UUID?, session: UUID?)?
    private weak var store: WorkspaceStore?

    private var isCurrent: Bool { shownOver != nil && matchesActiveTab }

    /// Retires the override the moment the active tab or workspace changes —
    /// observed directly, so it also happens while nothing reads `url`
    /// (sidebar hidden), and coming back to the original tab can't
    /// resurrect the external folder.
    private func watchActiveTab() {
        guard shownOver != nil, let store else { return }
        withObservationTracking {
            _ = store.active?.id
            _ = store.active?.activeSession?.id
        } onChange: { [weak self] in
            // onChange fires before the new value lands; look after it has.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.shownOver != nil else { return }
                    if self.matchesActiveTab { self.watchActiveTab() } else { self.clear() }
                }
            }
        }
    }

    private var matchesActiveTab: Bool {
        guard let shownOver, let store else { return false }
        return shownOver.workspace == store.active?.id && shownOver.session == store.active?.activeSession?.id
    }

    var url: URL? { isCurrent ? storedURL : nil }
    /// What to call it in the tree header.
    var label: String? { isCurrent ? storedLabel : nil }

    private struct Entry { weak var store: WorkspaceStore?; let root: ExternalTreeRoot }
    private static var roots: [ObjectIdentifier: Entry] = [:]

    static func `for`(_ store: WorkspaceStore) -> ExternalTreeRoot {
        for (key, entry) in roots where entry.store == nil { roots[key] = nil }
        let key = ObjectIdentifier(store)
        if let entry = roots[key], entry.store === store { return entry.root }
        let created = ExternalTreeRoot()
        created.store = store
        roots[key] = Entry(store: store, root: created)
        return created
    }

    func show(_ session: ExternalAgentSession) {
        storedURL = session.cwd.standardizedFileURL
        storedLabel = session.displayTitle
        shownOver = (store?.active?.id, store?.active?.activeSession?.id)
        watchActiveTab()
    }

    func clear() {
        storedURL = nil
        storedLabel = nil
        shownOver = nil
    }
}
