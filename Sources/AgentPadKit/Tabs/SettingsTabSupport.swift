import AppKit
import SwiftUI

@MainActor
enum SettingsIconImport {
    static func apply(_ url: URL, agentID: String, model: AgentPadSettingsModel, screen: SettingsScreenState,
                      importIcon: (URL, String) throws -> String = { try AgentIconStore.importIcon(from: $0, agentId: $1) }) {
        guard let index = model.customAgents.firstIndex(where: { $0.id == agentID }) else { return }
        do {
            model.customAgents[index].iconAsset = try importIcon(url, agentID)
            screen.iconErrors[agentID] = nil
            model.scheduleSave()
        } catch { screen.iconErrors[agentID] = error.localizedDescription }
    }
}

/// NSScrollView's clip origin is navigation, not form data. The native host
/// survives moves; these offsets also restore each Settings section on reopen.
struct TabScrollPosition: NSViewRepresentable {
    let state: TabState
    let section: String
    final class Probe: NSView {
        weak var clip: NSClipView?
        var state: TabState?
        var section = ""
        var generation = UUID()
        var restoring = false
        func update(state: TabState, section: String) {
            if self.section == section, self.state === state, clip != nil { return }
            capture()
            NotificationCenter.default.removeObserver(self)
            self.state = state; self.section = section
            generation = UUID()
            let stamp = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == stamp, let scroll = self.enclosingScrollView else { return }
                self.clip = scroll.contentView
                let y = state.navigation.settingsScrollOffsets?[section] ?? 0
                self.restoring = true
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.restoring = false
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(self.boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            }
        }
        @objc private func boundsChanged(_ note: Notification) { capture() }
        func capture() {
            guard !restoring, let state, !state.isClosed, let clip, !section.isEmpty else { return }
            let y = max(0, Double(clip.bounds.minY))
            guard abs((state.navigation.settingsScrollOffsets?[section] ?? 0) - y) > 0.5 else { return }
            if state.navigation.settingsScrollOffsets == nil { state.navigation.settingsScrollOffsets = [:] }
            state.navigation.settingsScrollOffsets?[section] = y
            state.changed()
        }
        func stop() { capture(); generation = UUID(); NotificationCenter.default.removeObserver(self); clip = nil }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.update(state: state, section: section) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
}
