import AppKit
import SwiftUI

/// Keeps terminal NSViews mounted after their first visit. SwiftUI's `.id(tab.id)`
/// used to detach and reattach a Metal-backed view on every tab switch; the
/// AppKit reattachment is visible as a several-hundred-millisecond pause even
/// when the Ghostty surface already exists. Unvisited tabs stay lazy: their
/// view is attached only when first selected, preserving restored-tab startup
/// behaviour. CLI `open --no-focus` tabs are the exception: they mount hidden
/// immediately so their shell can start without becoming the active tab.
struct TerminalTabHost: NSViewRepresentable {
    let tabs: [Session]
    let activeTabId: UUID?
    let grabsFocusOnMount: Bool

    func makeNSView(context: Context) -> TerminalTabHostView {
        let host = TerminalTabHostView()
        host.update(tabs: tabs, activeTabId: activeTabId, grabsFocusOnMount: grabsFocusOnMount)
        return host
    }

    func updateNSView(_ nsView: TerminalTabHostView, context: Context) {
        nsView.update(tabs: tabs, activeTabId: activeTabId, grabsFocusOnMount: grabsFocusOnMount)
    }
}

@MainActor
final class TerminalTabHostView: NSView {
    private var mountedViews: [UUID: NSView] = [:]
    private var focusedTabID: UUID?
    private var viewCheckScheduled = false
    var onVisibilityChange: () -> Void = { AttentionLedger.shared.markFocusedAttentionViewed() }

    // Check after AppKit/SwiftUI has applied the tab or workspace switch.
    // Selecting a model in a hidden workspace must never acknowledge a wait.
    private func scheduleViewCheck() {
        guard !viewCheckScheduled else { return }
        viewCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewCheckScheduled = false
            self.onVisibilityChange()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleViewCheck()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        scheduleViewCheck()
    }

    override func layout() {
        super.layout()
        // A cross-pane/window move reparents the engine view before the old
        // host necessarily receives its model update. Only the current AppKit
        // owner may size it during that handoff.
        for view in mountedViews.values where view.superview === self {
            view.frame = bounds
        }
        scheduleViewCheck()
    }

    func update(tabs: [Session], activeTabId: UUID?, grabsFocusOnMount: Bool) {
        let tabIds = Set(tabs.map(\.id))
        let focusChanged = focusedTabID != activeTabId
        if focusChanged, let old = tabs.first(where: { $0.id == focusedTabID }) {
            (old.engine as? NativeTabEngine)?.rememberFocus()
        }
        focusedTabID = activeTabId
        for session in tabs where session.id == activeTabId || session.spawnsInBackground {
            let view = session.engine.view
            let isActive = session.id == activeTabId
            // Set mount-time gates before addSubview triggers
            // viewDidMoveToWindow on an already-windowed host.
            session.engine.grabsFocusOnMount = grabsFocusOnMount && isActive
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            view.isHidden = !isActive
            mountedViews[session.id] = view
            if view.superview !== self {
                addSubview(view)
            }
        }

        for session in tabs {
            guard let view = mountedViews[session.id], view.superview === self else { continue }
            session.engine.grabsFocusOnMount = grabsFocusOnMount && session.id == activeTabId
            view.isHidden = session.id != activeTabId
            view.frame = bounds
        }
        if let activeTabId,
           let active = tabs.first(where: { $0.id == activeTabId }),
           active.engine.view.superview === self {
            active.engine.renderNowIfNeeded()
            if focusChanged, grabsFocusOnMount, let engine = active.engine as? NativeTabEngine {
                DispatchQueue.main.async { [weak engine] in engine?.focus() }
            }
        }

        let removedIds = mountedViews.keys.filter { !tabIds.contains($0) }
        for id in removedIds {
            // addSubview reparents automatically. If a destination host has
            // already adopted this view, the stale source entry must only be
            // forgotten — removing it would detach the destination's terminal.
            if let view = mountedViews[id], view.superview === self {
                view.removeFromSuperview()
            }
            mountedViews[id] = nil
        }
        scheduleViewCheck()
    }
}
